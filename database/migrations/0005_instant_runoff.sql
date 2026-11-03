-- Phase 4: instant-runoff voting (majority/runoff, single winner) and per-method seat limits.
-- Adds a 'ranked' ballot type and voting_methods.max_seats. Functions below are re-created from 0003/0004 with two changes:
--   * validate_election enforces max_seats
--   * only list-based ('party_list') ballots may carry list members (previously: every non-'candidate' type)

alter table public.voting_methods add column max_seats integer check (max_seats is null or max_seats >= 1);
alter table public.voting_methods drop constraint voting_methods_ballot_type_check;
alter table public.voting_methods add constraint voting_methods_ballot_type_check check (ballot_type in ('candidate', 'ranked', 'party_list'));

insert into public.voting_methods (key, name, category, ballot_type, supports_threshold, max_seats) values
  ('irv', 'Instant-runoff (ranked choice)', 'majority', 'ranked', false, 1);

create or replace function public.validate_election(p_title text, p_description text, p_method text, p_seats int,
  p_opens timestamptz, p_closes timestamptz, p_settings jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_method public.voting_methods; v_threshold numeric; v_key text;
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
    if v_key <> 'threshold_percent' then perform public.fail('NV422', 'Unknown setting: ' || left(v_key, 40)); end if;
  end loop;
  if p_settings ? 'threshold_percent' then
    if jsonb_typeof(p_settings -> 'threshold_percent') <> 'number' then perform public.fail('NV422', 'Threshold must be a number'); end if;
    v_threshold := (p_settings ->> 'threshold_percent')::numeric;
    if v_threshold < 0 or v_threshold > 100 then perform public.fail('NV422', 'Threshold must be between 0 and 100'); end if;
    if v_threshold > 0 and not v_method.supports_threshold then perform public.fail('NV422', 'This voting method has no electoral threshold'); end if;
  end if;
  return case when v_method.supports_threshold then jsonb_build_object('threshold_percent', coalesce(v_threshold, 0)) else '{}'::jsonb end;
end $$;

create or replace function public.add_ballot_option(p_election uuid, p_label text, p_description text, p_members text[])
returns public.ballot_options language plpgsql security definer set search_path = public as $$
declare e public.elections; v_opt public.ballot_options; v_label text := btrim(coalesce(p_label, '')); v_members text[];
        v_type text;
begin
  e := public.lock_draft_election(p_election);
  if char_length(v_label) not between 1 and 120 then perform public.fail('NV422', 'Name must be 1-120 characters'); end if;
  if p_description is not null and char_length(p_description) > 500 then perform public.fail('NV422', 'Description must be at most 500 characters'); end if;
  select ballot_type into v_type from public.voting_methods where key = e.voting_method;
  v_members := public.normalise_members(p_members);
  if v_type <> 'party_list' and cardinality(v_members) > 0 then perform public.fail('NV422', 'Candidates don''t have list members. Use a list-based voting system for that'); end if;
  if (select count(*) from public.ballot_options where election_id = p_election) >= 200 then perform public.fail('NV422', 'A ballot can have at most 200 options'); end if;
  begin
    insert into public.ballot_options (election_id, label, description, members, sort_order)
    values (p_election, v_label, nullif(btrim(p_description), ''), v_members,
            coalesce((select max(sort_order) from public.ballot_options where election_id = p_election), 0) + 1) returning * into v_opt;
  exception when unique_violation then perform public.fail('NV409', 'That name is already on the ballot'); end;
  perform public.append_audit_event(e.organisation_id, auth.uid(), 'ballot.option_added', 'election', p_election::text, jsonb_build_object('option', v_opt.id));
  return v_opt;
end $$;

create or replace function public.update_ballot_option(p_id uuid, p_label text, p_description text, p_members text[])
returns public.ballot_options language plpgsql security definer set search_path = public as $$
declare v_opt public.ballot_options; e public.elections; v_label text := btrim(coalesce(p_label, '')); v_members text[]; v_type text;
begin
  select * into v_opt from public.ballot_options where id = p_id;
  if not found then perform public.fail('NV404', 'Ballot option not found'); end if;
  e := public.lock_draft_election(v_opt.election_id);
  if char_length(v_label) not between 1 and 120 then perform public.fail('NV422', 'Name must be 1-120 characters'); end if;
  if p_description is not null and char_length(p_description) > 500 then perform public.fail('NV422', 'Description must be at most 500 characters'); end if;
  select ballot_type into v_type from public.voting_methods where key = e.voting_method;
  v_members := public.normalise_members(p_members);
  if v_type <> 'party_list' and cardinality(v_members) > 0 then perform public.fail('NV422', 'Candidates don''t have list members. Use a list-based voting system for that'); end if;
  begin
    update public.ballot_options set label = v_label, description = nullif(btrim(p_description), ''), members = v_members where id = p_id returning * into v_opt;
  exception when unique_violation then perform public.fail('NV409', 'That name is already on the ballot'); end;
  perform public.append_audit_event(e.organisation_id, auth.uid(), 'ballot.option_updated', 'election', e.id::text, jsonb_build_object('option', p_id));
  return v_opt;
end $$;

create or replace function public.update_election(p_id uuid, p_title text, p_description text, p_method text, p_seats int,
  p_access public.election_access, p_opens timestamptz, p_closes timestamptz, p_settings jsonb)
returns public.elections language plpgsql security definer set search_path = public as $$
declare v_e public.elections; v_settings jsonb; v_type text;
begin
  select * into v_e from public.elections where id = p_id for update;
  if not found or not public.has_permission(v_e.organisation_id, 'election.manage') then perform public.fail('NV404', 'Election not found'); end if;
  if v_e.status <> 'draft' then perform public.fail('NV409', 'Only draft elections can be edited. Move it back to draft first.'); end if;
  v_settings := public.validate_election(p_title, p_description, p_method, p_seats, p_opens, p_closes, p_settings);
  if p_access = 'public' and exists (select 1 from public.election_voters where election_id = p_id) then
    perform public.fail('NV409', 'Remove the voter list before making the election public'); end if;
  if p_method <> v_e.voting_method then
    select ballot_type into v_type from public.voting_methods where key = p_method;
    if v_type <> 'party_list' and exists (select 1 from public.ballot_options where election_id = p_id and cardinality(members) > 0) then
      perform public.fail('NV409', 'Remove the candidates inside your lists before switching to a candidate-based voting system'); end if;
  end if;
  update public.elections set title = btrim(p_title), description = nullif(btrim(p_description), ''), voting_method = p_method, seats = p_seats,
         access = p_access, opens_at = p_opens, closes_at = p_closes, settings = v_settings where id = p_id returning * into v_e;
  perform public.append_audit_event(v_e.organisation_id, auth.uid(), 'election.updated', 'election', p_id::text, jsonb_build_object('method', p_method));
  return v_e;
end $$;

-- Function privileges are unchanged by CREATE OR REPLACE; re-asserted here so this file is self-evidently safe.
revoke all on function public.validate_election(text, text, text, int, timestamptz, timestamptz, jsonb) from public, anon, authenticated;
do $$ declare f text; begin
  foreach f in array array['add_ballot_option(uuid, text, text, text[])', 'update_ballot_option(uuid, text, text, text[])',
    'update_election(uuid, text, text, text, int, public.election_access, timestamptz, timestamptz, jsonb)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop; end $$;
