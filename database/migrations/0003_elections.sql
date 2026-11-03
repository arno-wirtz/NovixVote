-- Phase 2b: election model and lifecycle: draft -> scheduled -> open -> closed -> published.
-- Elections are written only through the functions below; status can only change via transition_election / advance_elections.

create type public.election_status as enum ('draft', 'scheduled', 'open', 'closed', 'published');
create type public.election_access as enum ('restricted', 'public');

-- Counting methods the platform can run. Rows must match methods registered in backend/app/domain/voting_methods.
create table public.voting_methods (
  key text primary key,
  name text not null,
  category text not null check (category in ('plurality', 'majority', 'proportional')),
  ballot_type text not null check (ballot_type in ('candidate', 'party_list')),
  supports_threshold boolean not null default false,
  enabled boolean not null default true
);
insert into public.voting_methods (key, name, category, ballot_type, supports_threshold) values
  ('plurality', 'Plurality (first-past-the-post)', 'plurality', 'candidate', false),
  ('d_hondt', 'D''Hondt (proportional)', 'proportional', 'party_list', true),
  ('sainte_lague', 'Sainte-Laguë (proportional)', 'proportional', 'party_list', true);
alter table public.voting_methods enable row level security;
revoke all on public.voting_methods from anon, authenticated;
grant select on public.voting_methods to authenticated;
create policy voting_methods_select on public.voting_methods for select to authenticated using (true);

create table public.elections (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  title text not null check (char_length(title) between 3 and 120),
  description text check (description is null or char_length(description) <= 2000),
  voting_method text not null references public.voting_methods (key),
  seats integer not null check (seats between 1 and 100),
  access public.election_access not null default 'restricted',
  status public.election_status not null default 'draft',
  opens_at timestamptz,
  closes_at timestamptz,
  settings jsonb not null default '{}'::jsonb check (jsonb_typeof(settings) = 'object'),
  created_by uuid not null references auth.users (id),
  status_changed_at timestamptz not null default now(),
  published_at timestamptz,
  published_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- >= (not >): an election opened and closed early in the same instant is a legitimate zero-length window.
  -- User-entered windows are validated strictly (closes_at > opens_at) in validate_election().
  constraint elections_window_valid check (opens_at is null or closes_at is null or closes_at >= opens_at),
  constraint elections_scheduled_has_window check (status = 'draft' or (opens_at is not null and closes_at is not null))
);
create index elections_org_status_idx on public.elections (organisation_id, status);
create trigger elections_updated before update on public.elections for each row execute function public.set_updated_at();

alter table public.elections enable row level security;
revoke all on public.elections from anon, authenticated;
grant select on public.elections to authenticated;
-- Members see published-lifecycle elections; drafts are visible only to people who can manage elections.
create policy elections_select on public.elections for select to authenticated
  using (public.is_org_member(organisation_id) and (status <> 'draft' or public.has_permission(organisation_id, 'election.manage')));

-- Validates fields and returns normalised settings. Internal.
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
revoke all on function public.validate_election(text, text, text, int, timestamptz, timestamptz, jsonb) from public, anon, authenticated;

create or replace function public.create_election(p_org uuid, p_title text, p_description text, p_method text, p_seats int,
  p_access public.election_access, p_opens timestamptz, p_closes timestamptz, p_settings jsonb)
returns public.elections language plpgsql security definer set search_path = public as $$
declare v_e public.elections; v_settings jsonb;
begin
  if auth.uid() is null then perform public.fail('28000', 'Not authenticated'); end if;
  if not public.has_permission(p_org, 'election.create') then perform public.fail('NV403', 'You can''t create elections in this workspace'); end if;
  v_settings := public.validate_election(p_title, p_description, p_method, p_seats, p_opens, p_closes, p_settings);
  insert into public.elections (organisation_id, title, description, voting_method, seats, access, opens_at, closes_at, settings, created_by)
  values (p_org, btrim(p_title), nullif(btrim(p_description), ''), p_method, p_seats, p_access, p_opens, p_closes, v_settings, auth.uid())
  returning * into v_e;
  perform public.append_audit_event(p_org, auth.uid(), 'election.created', 'election', v_e.id::text, jsonb_build_object('method', p_method));
  return v_e;
end $$;

create or replace function public.update_election(p_id uuid, p_title text, p_description text, p_method text, p_seats int,
  p_access public.election_access, p_opens timestamptz, p_closes timestamptz, p_settings jsonb)
returns public.elections language plpgsql security definer set search_path = public as $$
declare v_e public.elections; v_settings jsonb;
begin
  select * into v_e from public.elections where id = p_id for update;
  if not found or not public.has_permission(v_e.organisation_id, 'election.manage') then perform public.fail('NV404', 'Election not found'); end if;
  if v_e.status <> 'draft' then perform public.fail('NV409', 'Only draft elections can be edited. Move it back to draft first.'); end if;
  v_settings := public.validate_election(p_title, p_description, p_method, p_seats, p_opens, p_closes, p_settings);
  update public.elections set title = btrim(p_title), description = nullif(btrim(p_description), ''), voting_method = p_method, seats = p_seats,
         access = p_access, opens_at = p_opens, closes_at = p_closes, settings = v_settings where id = p_id returning * into v_e;
  perform public.append_audit_event(v_e.organisation_id, auth.uid(), 'election.updated', 'election', p_id::text, jsonb_build_object('method', p_method));
  return v_e;
end $$;

create or replace function public.delete_election(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_e public.elections;
begin
  select * into v_e from public.elections where id = p_id for update;
  if not found or not public.has_permission(v_e.organisation_id, 'election.manage') then perform public.fail('NV404', 'Election not found'); end if;
  if v_e.status <> 'draft' then perform public.fail('NV409', 'Only draft elections can be deleted'); end if;
  delete from public.elections where id = p_id;
  perform public.append_audit_event(v_e.organisation_id, auth.uid(), 'election.deleted', 'election', p_id::text, '{}');
end $$;

-- Manual lifecycle moves. Allowed: draft->scheduled, scheduled->draft, scheduled->open ("open now"),
-- open->closed ("close now"), closed->published. Time-based moves are done by advance_elections().
create or replace function public.transition_election(p_id uuid, p_to public.election_status)
returns public.elections language plpgsql security definer set search_path = public as $$
declare v_e public.elections; v_from public.election_status;
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
    if v_e.opens_at is null or v_e.closes_at is null then perform public.fail('NV422', 'Set opening and closing times before scheduling'); end if;
    if v_e.opens_at <= now() then perform public.fail('NV422', 'The opening time must be in the future'); end if;
    -- Phase 3 adds ballot checks here (positions/lists and candidates must exist).
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

-- Time-based transitions, idempotent and safe for anyone to trigger. Also call on a schedule in production:
--   select cron.schedule('advance-elections', '* * * * *', 'select public.advance_elections()');   -- pg_cron
create or replace function public.advance_elections() returns integer
language plpgsql security definer set search_path = public as $$
declare r record; n integer := 0;
begin
  for r in select id, organisation_id from public.elections where status = 'scheduled' and opens_at <= now() order by opens_at for update skip locked loop
    update public.elections set status = 'open', status_changed_at = now() where id = r.id;
    perform public.append_audit_event(r.organisation_id, null, 'election.status_changed', 'election', r.id::text,
                                      jsonb_build_object('from', 'scheduled', 'to', 'open', 'automatic', true));
    n := n + 1;
  end loop;
  for r in select id, organisation_id from public.elections where status = 'open' and closes_at <= now() order by closes_at for update skip locked loop
    update public.elections set status = 'closed', status_changed_at = now() where id = r.id;
    perform public.append_audit_event(r.organisation_id, null, 'election.status_changed', 'election', r.id::text,
                                      jsonb_build_object('from', 'open', 'to', 'closed', 'automatic', true));
    n := n + 1;
  end loop;
  return n;
end $$;

do $$ declare f text; begin
  foreach f in array array['create_election(uuid, text, text, text, int, public.election_access, timestamptz, timestamptz, jsonb)',
    'update_election(uuid, text, text, text, int, public.election_access, timestamptz, timestamptz, jsonb)',
    'delete_election(uuid)', 'transition_election(uuid, public.election_status)', 'advance_elections()'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop; end $$;
