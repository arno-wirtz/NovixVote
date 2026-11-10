-- Phase 5: secure voting.
--
-- Separation of concerns (see documentation/architecture/adr-0005-secure-voting.md):
--   vote_participation  WHO has voted (identity side). No ballot reference, no selections.
--   ballots             WHAT was submitted (ballot side). No user, voter, email, session or timestamp columns.
--   election_vote_keys  Per-election secret used only when voters may change their vote. Deleted when voting closes.
-- None of the three tables is readable or writable by API roles; everything goes through the SECURITY DEFINER functions below.
--
-- Election rules chosen by the person in charge (stored in elections.settings, frozen once the election leaves draft):
--   allow_blank_ballot  default false: a voter must select at least one option
--   allow_vote_change   default true:  a voter may replace their vote while the election is open

create table public.vote_participation (
  election_id uuid not null references public.elections (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  change_count integer not null default 0 check (change_count >= 0),
  primary key (election_id, user_id)
);

create table public.election_vote_keys (
  election_id uuid primary key references public.elections (id) on delete cascade,
  secret bytea not null check (octet_length(secret) = 32)
);

create table public.ballots (
  id uuid primary key default gen_random_uuid(),
  election_id uuid not null references public.elections (id) on delete cascade,
  slot bytea,                                              -- only in elections that allow vote changes; nulled when voting closes
  selections uuid[] not null check (cardinality(selections) <= 200),   -- ballot_options ids; ordered for ranked ballots, sorted otherwise
  receipt_hash bytea not null unique                       -- sha256 of the receipt the voter holds; proves inclusion, not the choice
);
create unique index ballots_slot_uq on public.ballots (election_id, slot) where slot is not null;
create index ballots_election_idx on public.ballots (election_id);

alter table public.vote_participation enable row level security;
alter table public.election_vote_keys enable row level security;
alter table public.ballots enable row level security;
revoke all on public.vote_participation, public.election_vote_keys, public.ballots from public, anon, authenticated;   -- no policies: default deny

-- ---------- election rules: two optional booleans in settings ----------
create or replace function public.validate_election(p_title text, p_description text, p_method text, p_seats int,
  p_opens timestamptz, p_closes timestamptz, p_settings jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_method public.voting_methods; v_threshold numeric; v_key text; v_out jsonb;
begin
  if p_title is null or char_length(btrim(p_title)) not between 3 and 120 then perform public.fail('NV422', 'Title must be 3-120 characters'); end if;
  if p_description is not null and char_length(p_description) > 2000 then perform public.fail('NV422', 'Description must be at most 2000 characters'); end if;
  select * into v_method from public.voting_methods where key = p_method and enabled;
  if not found then perform public.fail('NV422', 'Unknown voting method'); end if;
  if p_seats is null or p_seats not between 1 and 100 then perform public.fail('NV422', 'Seats must be between 1 and 100'); end if;
  if v_method.max_seats is not null and p_seats > v_method.max_seats then
    perform public.fail('NV422', format('This voting system elects exactly %s seat%s', v_method.max_seats, case when v_method.max_seats = 1 then '' else 's' end)); end if;
  if p_opens is not null and p_closes is not null and p_closes <= p_opens then perform public.fail('NV422', 'Closing time must be after opening time'); end if;
  p_settings := coalesce(p_settings, '{}'::jsonb);
  if jsonb_typeof(p_settings) <> 'object' then perform public.fail('NV422', 'Settings must be an object'); end if;
  for v_key in select jsonb_object_keys(p_settings) loop
    if v_key not in ('threshold_percent', 'allow_vote_change', 'allow_blank_ballot') then perform public.fail('NV422', 'Unknown setting: ' || left(v_key, 40)); end if;
  end loop;
  if p_settings ? 'threshold_percent' then
    if jsonb_typeof(p_settings -> 'threshold_percent') <> 'number' then perform public.fail('NV422', 'Threshold must be a number'); end if;
    v_threshold := (p_settings ->> 'threshold_percent')::numeric;
    if v_threshold < 0 or v_threshold > 100 then perform public.fail('NV422', 'Threshold must be between 0 and 100'); end if;
    if v_threshold > 0 and not v_method.supports_threshold then perform public.fail('NV422', 'This voting method has no electoral threshold'); end if;
  end if;
  v_out := case when v_method.supports_threshold then jsonb_build_object('threshold_percent', coalesce(v_threshold, 0)) else '{}'::jsonb end;
  foreach v_key in array array['allow_vote_change', 'allow_blank_ballot'] loop
    if p_settings ? v_key then
      if jsonb_typeof(p_settings -> v_key) <> 'boolean' then perform public.fail('NV422', v_key || ' must be true or false'); end if;
      v_out := v_out || jsonb_build_object(v_key, p_settings -> v_key);
    end if;
  end loop;
  return v_out;
end $$;
revoke all on function public.validate_election(text, text, text, int, timestamptz, timestamptz, jsonb) from public, anon, authenticated;

-- ---------- internal helpers ----------
-- Pseudonymous ballot slot for elections that allow vote changes: sha256(secret || election || user).
-- Only available while the election is open; the secret is destroyed when voting closes, after which slots cannot be recomputed.
create or replace function public.vote_slot(p_election uuid, p_user uuid) returns bytea
language plpgsql security definer set search_path = public as $$
declare v_secret bytea;
begin
  if not exists (select 1 from public.elections where id = p_election and status = 'open') then return null; end if;
  insert into public.election_vote_keys (election_id, secret)
  values (p_election, decode(replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''), 'hex'))
  on conflict (election_id) do nothing;
  select secret into v_secret from public.election_vote_keys where election_id = p_election;
  return sha256(v_secret || convert_to(p_election::text || ':' || p_user::text, 'UTF8'));
end $$;

-- When voting closes: destroy the key and strip the slots, so ballots can no longer be tied to anyone even by someone with database access.
create or replace function public.election_closed_cleanup() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  delete from public.election_vote_keys where election_id = new.id;
  update public.ballots set slot = null where election_id = new.id and slot is not null;
  return null;
end $$;
create trigger elections_close_cleanup after update of status on public.elections
  for each row when (old.status is distinct from new.status and new.status in ('closed', 'published'))
  execute function public.election_closed_cleanup();

revoke all on function public.vote_slot(uuid, uuid), public.election_closed_cleanup() from public, anon, authenticated;

-- ---------- casting a vote ----------
-- Atomic: participation, ballot and audit event commit together or not at all.
-- p_selections: ballot_options ids. For ranked ballots the order is the ranking; otherwise the order is discarded (stored sorted).
create or replace function public.cast_vote(p_election uuid, p_selections uuid[]) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); v_org uuid; e public.elections; v_type text; v_n int; v_known int;
  v_change boolean; v_blank boolean; v_sel uuid[]; v_token text; v_receipt bytea; v_slot bytea; v_rows int; v_changed boolean := false;
begin
  if v_uid is null then perform public.fail('28000', 'Not authenticated'); end if;
  perform public.advance_elections();
  select organisation_id into v_org from public.elections where id = p_election;
  if not found then perform public.fail('NV404', 'Election not found'); end if;
  -- Same lock the audit chain uses, taken first so lock order is always (organisation, election): no deadlocks with lifecycle moves.
  perform pg_advisory_xact_lock(hashtext(v_org::text));
  select * into e from public.elections where id = p_election for share;      -- a manual close waits until this vote has committed
  if not public.is_eligible_voter(p_election) then perform public.fail('NV403', 'You aren''t eligible to vote in this election'); end if;
  if e.status <> 'open' then
    perform public.fail('NV409', case when e.status in ('draft', 'scheduled') then 'Voting hasn''t opened yet' else 'Voting has closed' end); end if;

  v_change := coalesce((e.settings ->> 'allow_vote_change')::boolean, true);
  v_blank := coalesce((e.settings ->> 'allow_blank_ballot')::boolean, false);
  select ballot_type into v_type from public.voting_methods where key = e.voting_method;

  if p_selections is null then perform public.fail('NV422', 'Your selections are missing'); end if;
  v_n := cardinality(p_selections);
  if (select count(distinct x) from unnest(p_selections) x) <> v_n then perform public.fail('NV422', 'You can''t select the same option twice'); end if;
  select count(*) into v_known from public.ballot_options o where o.election_id = p_election and o.id = any (p_selections);
  if v_known <> v_n then perform public.fail('NV422', 'Your selections include something that isn''t on the ballot'); end if;
  if v_n = 0 and not v_blank then perform public.fail('NV422', 'Select at least one option to cast your vote'); end if;
  if v_type = 'candidate' and v_n > e.seats then
    perform public.fail('NV422', format('You can select at most %s %s', e.seats, case when e.seats = 1 then 'candidate' else 'candidates' end)); end if;
  if v_type = 'party_list' and v_n > 1 then perform public.fail('NV422', 'Choose one list'); end if;
  -- Only ranked ballots keep their order: the order in which someone ticked boxes must not become a fingerprint.
  v_sel := case when v_type = 'ranked' then p_selections
                else coalesce((select array_agg(x order by x) from unnest(p_selections) x), '{}'::uuid[]) end;

  v_token := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');   -- 64 hex characters, shown to the voter once
  v_receipt := sha256(convert_to(v_token, 'UTF8'));

  insert into public.vote_participation (election_id, user_id) values (p_election, v_uid) on conflict do nothing;
  get diagnostics v_rows = row_count;
  if v_rows = 1 then
    insert into public.ballots (election_id, slot, selections, receipt_hash)
    values (p_election, case when v_change then public.vote_slot(p_election, v_uid) end, v_sel, v_receipt);
  else
    if not v_change then perform public.fail('NV409', 'You have already voted in this election'); end if;
    v_slot := public.vote_slot(p_election, v_uid);
    update public.ballots set selections = v_sel, receipt_hash = v_receipt where election_id = p_election and slot = v_slot;
    get diagnostics v_rows = row_count;
    if v_rows <> 1 then raise exception 'vote record is missing' using errcode = 'XX000'; end if;
    update public.vote_participation set change_count = change_count + 1 where election_id = p_election and user_id = v_uid;
    v_changed := true;
  end if;

  -- No actor and no selections: the audit trail records that a ballot was accepted, never who cast it or what it contains.
  perform public.append_audit_event(e.organisation_id, null, 'vote.accepted', 'election', p_election::text, jsonb_build_object('changed', v_changed));
  return jsonb_build_object('receipt', v_token, 'changed', v_changed);
end $$;

-- The caller's own voting status. Their current selections are returned only while the election is open and vote changes are allowed.
create or replace function public.my_vote(p_election uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); e public.elections; v_voted boolean; v_can boolean; v_sel uuid[];
begin
  if v_uid is null then perform public.fail('28000', 'Not authenticated'); end if;
  perform public.advance_elections();
  select * into e from public.elections where id = p_election;
  if not found or not public.can_view_election(p_election) then perform public.fail('NV404', 'Election not found'); end if;
  v_voted := exists (select 1 from public.vote_participation where election_id = p_election and user_id = v_uid);
  v_can := e.status = 'open' and coalesce((e.settings ->> 'allow_vote_change')::boolean, true);
  if v_voted and v_can then
    select b.selections into v_sel from public.ballots b where b.election_id = p_election and b.slot = public.vote_slot(p_election, v_uid);
  end if;
  return jsonb_build_object('voted', v_voted, 'can_change', v_can, 'selections', to_jsonb(v_sel));
end $$;

-- Does a receipt belong to a ballot currently counted in this election? Reveals nothing about the choice.
create or replace function public.verify_receipt(p_election uuid, p_receipt text) returns boolean
language plpgsql security definer set search_path = public as $$
declare v text := lower(btrim(coalesce(p_receipt, '')));
begin
  if auth.uid() is null then perform public.fail('28000', 'Not authenticated'); end if;
  if v !~ '^[0-9a-f]{64}$' then return false; end if;
  return exists (select 1 from public.ballots where election_id = p_election and receipt_hash = sha256(convert_to(v, 'UTF8')));
end $$;

-- Aggregate turnout for people who can view results. Counts only; never who voted for what.
create or replace function public.election_turnout(p_election uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare e public.elections; v_voted int; v_eligible int;
begin
  select * into e from public.elections where id = p_election;
  if not found or not public.has_permission(e.organisation_id, 'results.view') then perform public.fail('NV404', 'Election not found'); end if;
  select count(*) into v_voted from public.vote_participation where election_id = p_election;
  if e.access = 'restricted' then select count(*) into v_eligible from public.election_voters where election_id = p_election; end if;
  return jsonb_build_object('voted', v_voted, 'eligible', v_eligible);
end $$;

do $$ declare f text; begin
  foreach f in array array['cast_vote(uuid, uuid[])', 'my_vote(uuid)', 'verify_receipt(uuid, text)', 'election_turnout(uuid)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop; end $$;
