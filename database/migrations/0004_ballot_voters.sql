-- Phase 3: ballot builder (candidates / party lists), voter lists, eligibility, and the "ballot ready" gate for scheduling.
--
-- Eligibility model (see documentation/architecture/adr-0003):
--   restricted election: eligible = the person's CONFIRMED email is on the election's voter list (no workspace membership needed)
--   public election:     eligible = any signed-in account with a confirmed email (reached by link only, never listed)
-- The voter list is identity data: visible to election managers only, never joined to ballots (ballots arrive in phase 5).

create or replace function public.can_manage_election(p_election uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.elections e where e.id = p_election and public.has_permission(e.organisation_id, 'election.manage')) $$;

create table public.election_voters (
  id uuid primary key default gen_random_uuid(),
  election_id uuid not null references public.elections (id) on delete cascade,
  email text not null check (email = lower(email) and char_length(email) between 5 and 254 and email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  name text check (name is null or char_length(name) <= 120),
  added_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  unique (election_id, email)
);

create or replace function public.is_eligible_voter(p_election uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.elections e
    where e.id = p_election and e.status <> 'draft' and public.current_email() is not null
      and (e.access = 'public' or exists (select 1 from public.election_voters v where v.election_id = e.id and v.email = public.current_email()))) $$;

-- Who may see an election and its ballot: managers (incl. drafts), other members once it is scheduled, and eligible voters.
create or replace function public.can_view_election(p_election uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.elections e where e.id = p_election and (
    public.can_manage_election(e.id)
    or (e.status <> 'draft' and public.is_org_member(e.organisation_id))
    or public.is_eligible_voter(e.id))) $$;

drop policy elections_select on public.elections;
create policy elections_select on public.elections for select to authenticated using (public.can_view_election(id));

create table public.ballot_options (
  id uuid primary key default gen_random_uuid(),
  election_id uuid not null references public.elections (id) on delete cascade,
  label text not null check (char_length(label) between 1 and 120),
  description text check (description is null or char_length(description) <= 500),
  members text[] not null default '{}' check (cardinality(members) <= 100),   -- ordered candidates of a list (first = top of list)
  sort_order integer not null,
  created_at timestamptz not null default now()
);
create unique index ballot_options_label_uq on public.ballot_options (election_id, lower(label));
create index ballot_options_order_idx on public.ballot_options (election_id, sort_order);

alter table public.election_voters enable row level security;
alter table public.ballot_options enable row level security;
revoke all on public.election_voters, public.ballot_options from anon, authenticated;
grant select on public.election_voters, public.ballot_options to authenticated;
create policy voters_select on public.election_voters for select to authenticated using (public.can_manage_election(election_id));
create policy ballot_options_select on public.ballot_options for select to authenticated using (public.can_view_election(election_id));

-- ---------- internal helpers ----------
create or replace function public.lock_draft_election(p_id uuid) returns public.elections
language plpgsql security definer set search_path = public as $$
declare e public.elections;
begin
  if auth.uid() is null then perform public.fail('28000', 'Not authenticated'); end if;
  select * into e from public.elections where id = p_id for update;
  if not found or not public.has_permission(e.organisation_id, 'election.manage') then perform public.fail('NV404', 'Election not found'); end if;
  if e.status <> 'draft' then perform public.fail('NV409', 'The ballot can only be changed while the election is a draft'); end if;
  return e;
end $$;

create or replace function public.normalise_members(p_members text[]) returns text[]
language plpgsql immutable as $$
declare v text[] := '{}'; m text;
begin
  foreach m in array coalesce(p_members, '{}') loop
    m := btrim(m);
    if m = '' or char_length(m) > 120 then perform public.fail('NV422', 'Each list candidate needs a name of 1-120 characters'); end if;
    if lower(m) = any (select lower(x) from unnest(v) x) then perform public.fail('NV422', 'A list can''t contain the same candidate twice'); end if;
    v := v || m;
  end loop;
  if cardinality(v) > 100 then perform public.fail('NV422', 'A list can have at most 100 candidates'); end if;
  return v;
end $$;

revoke all on function public.lock_draft_election(uuid), public.normalise_members(text[]) from public, anon, authenticated;

-- ---------- ballot options ----------
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
  if v_type = 'candidate' and cardinality(v_members) > 0 then perform public.fail('NV422', 'Candidates don''t have list members. Use a list-based voting system for that'); end if;
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
  if v_type = 'candidate' and cardinality(v_members) > 0 then perform public.fail('NV422', 'Candidates don''t have list members. Use a list-based voting system for that'); end if;
  begin
    update public.ballot_options set label = v_label, description = nullif(btrim(p_description), ''), members = v_members where id = p_id returning * into v_opt;
  exception when unique_violation then perform public.fail('NV409', 'That name is already on the ballot'); end;
  perform public.append_audit_event(e.organisation_id, auth.uid(), 'ballot.option_updated', 'election', e.id::text, jsonb_build_object('option', p_id));
  return v_opt;
end $$;

create or replace function public.delete_ballot_option(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_opt public.ballot_options; e public.elections;
begin
  select * into v_opt from public.ballot_options where id = p_id;
  if not found then perform public.fail('NV404', 'Ballot option not found'); end if;
  e := public.lock_draft_election(v_opt.election_id);
  delete from public.ballot_options where id = p_id;
  perform public.append_audit_event(e.organisation_id, auth.uid(), 'ballot.option_removed', 'election', e.id::text, jsonb_build_object('option', p_id));
end $$;

create or replace function public.reorder_ballot_options(p_election uuid, p_ids uuid[]) returns void
language plpgsql security definer set search_path = public as $$
declare e public.elections;
begin
  e := public.lock_draft_election(p_election);
  if p_ids is null or cardinality(p_ids) <> (select count(*) from public.ballot_options where election_id = p_election)
     or (select count(distinct x) from unnest(p_ids) x) <> cardinality(p_ids)
     or exists (select 1 from unnest(p_ids) x where not exists (select 1 from public.ballot_options o where o.id = x and o.election_id = p_election)) then
    perform public.fail('NV422', 'The new order must list every ballot option exactly once');
  end if;
  update public.ballot_options o set sort_order = t.ord from unnest(p_ids) with ordinality as t(id, ord) where o.id = t.id;
  perform public.append_audit_event(e.organisation_id, auth.uid(), 'ballot.reordered', 'election', p_election::text, '{}');
end $$;

-- ---------- voter list ----------
create or replace function public.add_election_voters(p_election uuid, p_voters jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare e public.elections; r record; v_email text; v_name text; v_added int := 0; v_dupes int := 0; v_invalid int := 0;
        v_invalid_rows jsonb := '[]'::jsonb; v_n int; v_total int; v_reason text;
begin
  if auth.uid() is null then perform public.fail('28000', 'Not authenticated'); end if;
  select * into e from public.elections where id = p_election for update;
  if not found or not public.has_permission(e.organisation_id, 'election.manage') then perform public.fail('NV404', 'Election not found'); end if;
  if e.status not in ('draft', 'scheduled') then perform public.fail('NV409', 'The voter list is locked once voting has opened'); end if;
  if e.access <> 'restricted' then perform public.fail('NV409', 'Public elections don''t use a voter list'); end if;
  if p_voters is null or jsonb_typeof(p_voters) <> 'array' then perform public.fail('NV422', 'Voters must be a list'); end if;
  if jsonb_array_length(p_voters) > 1000 then perform public.fail('NV422', 'Add at most 1,000 voters at a time'); end if;

  for r in select t.value, t.ord from jsonb_array_elements(p_voters) with ordinality as t(value, ord) loop
    v_reason := null; v_email := null; v_name := null;
    if jsonb_typeof(r.value) <> 'object' then v_reason := 'Not a voter entry';
    else
      v_email := lower(btrim(coalesce(r.value ->> 'email', '')));
      v_name := nullif(btrim(coalesce(r.value ->> 'name', '')), '');
      if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' or char_length(v_email) > 254 then v_reason := 'Not a valid email address';
      elsif v_name is not null and char_length(v_name) > 120 then v_reason := 'Name is longer than 120 characters'; end if;
    end if;
    if v_reason is not null then
      v_invalid := v_invalid + 1;
      if v_invalid <= 50 then v_invalid_rows := v_invalid_rows || jsonb_build_object('row', r.ord, 'email', left(coalesce(v_email, ''), 254), 'reason', v_reason); end if;
    else
      insert into public.election_voters (election_id, email, name, added_by) values (p_election, v_email, v_name, auth.uid()) on conflict (election_id, email) do nothing;
      get diagnostics v_n = row_count;
      if v_n = 1 then v_added := v_added + 1; else v_dupes := v_dupes + 1; end if;
    end if;
  end loop;

  select count(*) into v_total from public.election_voters where election_id = p_election;
  if v_total > 10000 then perform public.fail('NV422', 'An election can have at most 10,000 voters'); end if;
  perform public.append_audit_event(e.organisation_id, auth.uid(), 'voters.added', 'election', p_election::text,
                                    jsonb_build_object('added', v_added, 'duplicates', v_dupes, 'invalid', v_invalid));
  return jsonb_build_object('added', v_added, 'duplicates', v_dupes, 'invalid_count', v_invalid, 'invalid', v_invalid_rows, 'total', v_total);
end $$;

create or replace function public.remove_election_voter(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v public.election_voters; e public.elections;
begin
  select * into v from public.election_voters where id = p_id;
  if not found then perform public.fail('NV404', 'Voter not found'); end if;
  select * into e from public.elections where id = v.election_id for update;
  if not public.has_permission(e.organisation_id, 'election.manage') then perform public.fail('NV404', 'Voter not found'); end if;
  if e.status not in ('draft', 'scheduled') then perform public.fail('NV409', 'The voter list is locked once voting has opened'); end if;
  delete from public.election_voters where id = p_id;
  perform public.append_audit_event(e.organisation_id, auth.uid(), 'voters.removed', 'election', e.id::text, '{}');
end $$;

create or replace function public.election_voter_page(p_election uuid, p_limit int default 50, p_offset int default 0, p_search text default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_s text := lower(btrim(coalesce(p_search, ''))); v_items jsonb; v_total int; v_all int;
begin
  if not public.can_manage_election(p_election) then perform public.fail('NV404', 'Election not found'); end if;
  select count(*) into v_all from public.election_voters where election_id = p_election;
  select count(*) into v_total from public.election_voters
   where election_id = p_election and (v_s = '' or strpos(email, v_s) > 0 or strpos(lower(coalesce(name, '')), v_s) > 0);
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'email', email, 'name', name, 'created_at', created_at) order by email), '[]'::jsonb) into v_items
    from (select * from public.election_voters where election_id = p_election and (v_s = '' or strpos(email, v_s) > 0 or strpos(lower(coalesce(name, '')), v_s) > 0)
          order by email limit greatest(1, least(coalesce(p_limit, 50), 200)) offset greatest(0, coalesce(p_offset, 0))) x;
  return jsonb_build_object('total', v_total, 'all_total', v_all, 'items', v_items);
end $$;

-- ---------- readiness (single source of truth for the UI checklist AND the scheduling gate) ----------
create or replace function public.election_readiness(p_election uuid) returns table (key text, ok boolean, label text, problem text)
language plpgsql stable security definer set search_path = public as $$
declare e public.elections; v_type text; v_noun text;
begin
  select * into e from public.elections where id = p_election;
  if not found or not public.has_permission(e.organisation_id, 'election.manage') then perform public.fail('NV404', 'Election not found'); end if;
  select ballot_type into v_type from public.voting_methods where voting_methods.key = e.voting_method;
  v_noun := case when v_type = 'party_list' then 'lists' else 'candidates' end;
  return query select 'window', e.opens_at is not null and e.closes_at is not null, 'Opening and closing times are set', 'Set opening and closing times before scheduling';
  return query select 'future', coalesce(e.opens_at > now(), false), 'The opening time is in the future', 'The opening time must be in the future';
  return query select 'ballot', (select count(*) from public.ballot_options o where o.election_id = e.id) >= 2,
                      'The ballot has at least 2 ' || v_noun, 'Add at least 2 ' || v_noun || ' to the ballot before scheduling';
  if e.access = 'restricted' then
    return query select 'voters', exists (select 1 from public.election_voters v where v.election_id = e.id), 'The voter list has at least one voter', 'Add eligible voters before scheduling';
  end if;
end $$;

create or replace function public.election_organisation_name(p_election uuid) returns text
language sql stable security definer set search_path = public as $$
  select o.name from public.elections e join public.organisations o on o.id = e.organisation_id where e.id = p_election and public.can_view_election(e.id) $$;

-- Restricted elections the caller is on the voter list of (public elections are reachable by link only and never listed).
create or replace function public.my_eligible_elections()
returns table (id uuid, organisation_name text, title text, status public.election_status, opens_at timestamptz, closes_at timestamptz)
language sql stable security definer set search_path = public as $$
  select e.id, o.name, e.title, e.status, e.opens_at, e.closes_at
  from public.elections e join public.organisations o on o.id = e.organisation_id
  where e.status <> 'draft' and e.access = 'restricted' and public.current_email() is not null
    and exists (select 1 from public.election_voters v where v.election_id = e.id and v.email = public.current_email())
  order by case e.status when 'open' then 0 when 'scheduled' then 1 else 2 end, e.opens_at desc $$;

-- ---------- scheduling gate + draft-edit guards (replace the phase 2 definitions) ----------
create or replace function public.transition_election(p_id uuid, p_to public.election_status)
returns public.elections language plpgsql security definer set search_path = public as $$
declare v_e public.elections; v_from public.election_status; v_r record;
begin
  if auth.uid() is null then perform public.fail('28000', 'Not authenticated'); end if;
  perform public.advance_elections();
  select * into v_e from public.elections where id = p_id for update;
  if not found or not public.has_permission(v_e.organisation_id, 'election.read') then perform public.fail('NV404', 'Election not found'); end if;
  if not public.has_permission(v_e.organisation_id, case when p_to = 'published' then 'results.approve' else 'election.manage' end) then
    perform public.fail('NV403', case when p_to = 'published' then 'Only people who can approve results may publish' else 'You can''t manage elections in this workspace' end);
  end if;
  v_from := v_e.status;
  if (v_from, p_to) not in (('draft','scheduled'), ('scheduled','draft'), ('scheduled','open'), ('open','closed'), ('closed','published')) then
    perform public.fail('NV409', format('An election can''t move from %s to %s', v_from, p_to)); end if;

  if v_from = 'draft' and p_to = 'scheduled' then
    for v_r in select * from public.election_readiness(p_id) loop
      if not v_r.ok then perform public.fail('NV422', v_r.problem); end if;
    end loop;
  elsif v_from = 'scheduled' and p_to = 'draft' then
    if v_e.opens_at <= now() then perform public.fail('NV409', 'Voting is about to open and can''t be unscheduled'); end if;
  elsif v_from = 'scheduled' and p_to = 'open' then
    if v_e.closes_at <= now() then perform public.fail('NV422', 'The closing time has already passed'); end if;
    v_e.opens_at := least(v_e.opens_at, now());
  elsif v_from = 'open' and p_to = 'closed' then
    v_e.closes_at := least(v_e.closes_at, now());
  end if;

  update public.elections set status = p_to, opens_at = v_e.opens_at, closes_at = v_e.closes_at, status_changed_at = now(),
         published_at = case when p_to = 'published' then now() else published_at end,
         published_by = case when p_to = 'published' then auth.uid() else published_by end
   where id = p_id returning * into v_e;
  perform public.append_audit_event(v_e.organisation_id, auth.uid(), 'election.status_changed', 'election', p_id::text,
                                    jsonb_build_object('from', v_from, 'to', p_to, 'automatic', false));
  return v_e;
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
    if v_type = 'candidate' and exists (select 1 from public.ballot_options where election_id = p_id and cardinality(members) > 0) then
      perform public.fail('NV409', 'Remove the candidates inside your lists before switching to a candidate-based voting system'); end if;
  end if;
  update public.elections set title = btrim(p_title), description = nullif(btrim(p_description), ''), voting_method = p_method, seats = p_seats,
         access = p_access, opens_at = p_opens, closes_at = p_closes, settings = v_settings where id = p_id returning * into v_e;
  perform public.append_audit_event(v_e.organisation_id, auth.uid(), 'election.updated', 'election', p_id::text, jsonb_build_object('method', p_method));
  return v_e;
end $$;

do $$ declare f text; begin
  foreach f in array array['add_ballot_option(uuid, text, text, text[])', 'update_ballot_option(uuid, text, text, text[])', 'delete_ballot_option(uuid)',
    'reorder_ballot_options(uuid, uuid[])', 'add_election_voters(uuid, jsonb)', 'remove_election_voter(uuid)',
    'election_voter_page(uuid, int, int, text)', 'election_readiness(uuid)', 'election_organisation_name(uuid)', 'my_eligible_elections()',
    'is_eligible_voter(uuid)', 'can_view_election(uuid)', 'can_manage_election(uuid)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop; end $$;
