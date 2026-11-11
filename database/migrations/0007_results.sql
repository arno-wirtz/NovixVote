-- Phase 6: counting, tie-break recording, result approval and publication, audit verification.
--
-- Counting itself is done by the framework-free engine in backend/app/domain/voting_methods. The database does three things the engine can't:
--   1. hands the closed ballot set to an authorised counter (shuffled, anonymous, with a hash of the exact set),
--   2. refuses to record a count that wasn't made from the ballots it holds (the hash must match), and keeps every count forever,
--   3. refuses to publish an election that has ballots until an authorised person has approved a complete count of those ballots.
-- Nothing here is readable or writable directly by API roles; everything goes through the SECURITY DEFINER functions below.

create table public.tally_runs (
  id uuid primary key default gen_random_uuid(),
  election_id uuid not null references public.elections (id) on delete cascade,
  run_number integer not null check (run_number > 0),
  input_hash text not null check (input_hash ~ '^[0-9a-f]{64}$'),   -- sha256 of the canonical ballot set that was counted
  ballot_count integer not null check (ballot_count >= 0),
  tie_break jsonb check (tie_break is null or jsonb_typeof(tie_break) = 'object'),   -- documented tie-break procedure, when one was applied
  result jsonb not null check (jsonb_typeof(result) = 'object' and jsonb_typeof(result -> 'complete') = 'boolean'),
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  unique (election_id, run_number)
);

create table public.tally_approvals (
  run_id uuid primary key references public.tally_runs (id) on delete cascade,
  election_id uuid not null unique references public.elections (id) on delete cascade,   -- one approved count per election
  approved_by uuid references auth.users (id) on delete set null,
  approved_at timestamptz not null default now()
);

create or replace function public.tally_immutable() returns trigger language plpgsql as $$
begin raise exception '% is append-only', tg_table_name using errcode = 'P0001'; end $$;
create trigger tally_runs_immutable before update or delete on public.tally_runs for each row execute function public.tally_immutable();
create trigger tally_approvals_immutable before update or delete on public.tally_approvals for each row execute function public.tally_immutable();

alter table public.tally_runs enable row level security;
alter table public.tally_approvals enable row level security;
revoke all on public.tally_runs, public.tally_approvals from public, anon, authenticated;   -- no policies: default deny

-- Canonical hash of the ballot set: one line per ballot (option ids, comma separated, ranked order kept), lines sorted bytewise.
-- The backend computes the same value from the ballots it receives; the two must agree.
create or replace function public.ballot_set_hash(p_election uuid) returns text
language sql stable security definer set search_path = public as $$
  select encode(sha256(convert_to(coalesce(string_agg(l, E'\n' order by l collate "C"), ''), 'UTF8')), 'hex')
  from (select array_to_string(selections, ',') as l from public.ballots where election_id = p_election) x $$;
revoke all on function public.ballot_set_hash(uuid) from public, anon, authenticated;

-- The ballots to count: shuffled, with no identity and no order information. Only after voting has closed.
create or replace function public.tally_input(p_election uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare e public.elections; v_ballots jsonb; v_options jsonb; v_count int;
begin
  if auth.uid() is null then perform public.fail('28000', 'Not authenticated'); end if;
  perform public.advance_elections();
  select * into e from public.elections where id = p_election;
  if not found or not public.has_permission(e.organisation_id, 'election.manage') then perform public.fail('NV404', 'Election not found'); end if;
  if e.status not in ('closed', 'published') then perform public.fail('NV409', 'Votes can only be counted after voting has closed'); end if;
  select count(*), coalesce(jsonb_agg(to_jsonb(selections) order by random()), '[]'::jsonb) into v_count, v_ballots
    from public.ballots where election_id = p_election;
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'label', label) order by sort_order), '[]'::jsonb) into v_options
    from public.ballot_options where election_id = p_election;
  return jsonb_build_object('method', e.voting_method, 'seats', e.seats, 'settings', e.settings, 'options', v_options,
                            'ballots', v_ballots, 'ballot_count', v_count, 'hash', public.ballot_set_hash(p_election));
end $$;

-- Stores a count. Counts are never edited or deleted: a recount (or a count with a recorded tie-break) is a new run.
create or replace function public.record_tally_run(p_election uuid, p_hash text, p_result jsonb, p_tie_break jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare e public.elections; v_n int; v_id uuid; v_count int;
begin
  if auth.uid() is null then perform public.fail('28000', 'Not authenticated'); end if;
  select * into e from public.elections where id = p_election for update;
  if not found or not public.has_permission(e.organisation_id, 'election.manage') then perform public.fail('NV404', 'Election not found'); end if;
  if e.status = 'published' then perform public.fail('NV409', 'Results are already published'); end if;
  if e.status <> 'closed' then perform public.fail('NV409', 'Votes can only be counted after voting has closed'); end if;
  if p_result is null or jsonb_typeof(p_result) <> 'object' or jsonb_typeof(p_result -> 'complete') is distinct from 'boolean' then
    perform public.fail('NV422', 'The count result is malformed'); end if;
  if pg_column_size(p_result) > 2000000 then perform public.fail('NV422', 'The count result is too large'); end if;
  if p_tie_break is not null and (jsonb_typeof(p_tie_break) <> 'object' or char_length(btrim(coalesce(p_tie_break ->> 'note', ''))) = 0) then
    perform public.fail('NV422', 'Describe how the tie was broken (for example, who drew lots and how)'); end if;
  if p_hash is distinct from public.ballot_set_hash(p_election) then
    perform public.fail('NV409', 'The count was not made from the ballots held for this election'); end if;
  select count(*) into v_count from public.ballots where election_id = p_election;
  select coalesce(max(run_number), 0) + 1 into v_n from public.tally_runs where election_id = p_election;
  insert into public.tally_runs (election_id, run_number, input_hash, ballot_count, tie_break, result, created_by)
  values (p_election, v_n, p_hash, v_count, p_tie_break, p_result, auth.uid()) returning id into v_id;
  perform public.append_audit_event(e.organisation_id, auth.uid(), 'tally.recorded', 'election', p_election::text,
    jsonb_build_object('run', v_n, 'ballots', v_count, 'complete', (p_result ->> 'complete')::boolean, 'tie_break', p_tie_break is not null));
  return jsonb_build_object('id', v_id, 'run_number', v_n);
end $$;

-- Approves the latest count. Requires results.approve (owners), a complete count (no unresolved tie) and the current ballot set.
create or replace function public.approve_tally_run(p_run uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r public.tally_runs; e public.elections;
begin
  if auth.uid() is null then perform public.fail('28000', 'Not authenticated'); end if;
  select * into r from public.tally_runs where id = p_run;
  if not found then perform public.fail('NV404', 'Count not found'); end if;
  select * into e from public.elections where id = r.election_id for update;
  if not public.has_permission(e.organisation_id, 'election.read') then perform public.fail('NV404', 'Count not found'); end if;
  if not public.has_permission(e.organisation_id, 'results.approve') then perform public.fail('NV403', 'Only people who can approve results may approve a count'); end if;
  if e.status <> 'closed' then perform public.fail('NV409', 'Only a closed election can have its count approved'); end if;
  if not (r.result ->> 'complete')::boolean then perform public.fail('NV422', 'This count has an unresolved tie. Record how the tie was broken and count again'); end if;
  if r.run_number <> (select max(run_number) from public.tally_runs where election_id = r.election_id) then
    perform public.fail('NV409', 'Only the latest count can be approved'); end if;
  if r.input_hash <> public.ballot_set_hash(r.election_id) then perform public.fail('NV409', 'The ballots have changed since this count'); end if;
  begin
    insert into public.tally_approvals (run_id, election_id, approved_by) values (p_run, r.election_id, auth.uid());
  exception when unique_violation then perform public.fail('NV409', 'A count has already been approved for this election'); end;
  perform public.append_audit_event(e.organisation_id, auth.uid(), 'tally.approved', 'election', e.id::text, jsonb_build_object('run', r.run_number));
end $$;

-- Publishing needs an approved count whenever ballots exist. An election nobody voted in has nothing to count and can be published as is.
create or replace function public.require_approved_tally() returns trigger language plpgsql as $$
begin
  if exists (select 1 from public.vote_participation where election_id = new.id)
     and not exists (select 1 from public.tally_approvals where election_id = new.id) then
    raise exception 'Count and approve the results before publishing' using errcode = 'NV409';
  end if;
  return new;
end $$;
create trigger elections_publish_gate before update of status on public.elections
  for each row when (old.status is distinct from new.status and new.status = 'published')
  execute function public.require_approved_tally();
revoke all on function public.require_approved_tally(), public.tally_immutable() from public, anon, authenticated;

create or replace function public.list_tally_runs(p_election uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare e public.elections;
begin
  select * into e from public.elections where id = p_election;
  if not found or not public.has_permission(e.organisation_id, 'results.view') then perform public.fail('NV404', 'Election not found'); end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'run_number', r.run_number, 'created_at', r.created_at, 'input_hash', r.input_hash,
            'ballot_count', r.ballot_count, 'tie_break', r.tie_break, 'result', r.result, 'approved', a.run_id is not null, 'approved_at', a.approved_at)
            order by r.run_number desc)
          from public.tally_runs r left join public.tally_approvals a on a.run_id = r.id where r.election_id = p_election), '[]'::jsonb);
end $$;

-- What eligible voters and members may see: only the approved count of a published election. NULL until then.
create or replace function public.published_result(p_election uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare e public.elections; r public.tally_runs; a public.tally_approvals;
begin
  select * into e from public.elections where id = p_election;
  if not found or not public.can_view_election(p_election) then perform public.fail('NV404', 'Election not found'); end if;
  if e.status <> 'published' then return null; end if;
  select * into a from public.tally_approvals where election_id = p_election;
  if not found then return jsonb_build_object('ballot_count', 0, 'result', null); end if;     -- published with no ballots
  select * into r from public.tally_runs where id = a.run_id;
  return jsonb_build_object('run_number', r.run_number, 'approved_at', a.approved_at, 'input_hash', r.input_hash, 'ballot_count', r.ballot_count,
                            'tie_break', r.tie_break, 'result', r.result);
end $$;

-- Recomputes the workspace audit hash chain. The chain hashes timestamp text, so this relies on every session using the same timezone setting
-- (true for a normal deployment: the database default, UTC on Supabase). Don't change the database timezone on a live system.
create or replace function public.verify_audit_chain(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r record; v_prev text; v_n int := 0; v_bad bigint; v_expect text;
begin
  if not public.has_permission(p_org, 'audit.read') then perform public.fail('NV404', 'Workspace not found'); end if;
  for r in select * from public.audit_events where organisation_id = p_org order by id loop
    v_n := v_n + 1;
    v_expect := encode(sha256(convert_to(
      coalesce(v_prev, '') || '|' || p_org || '|' || coalesce(r.actor_id::text, '') || '|' || r.event_type || '|' ||
      coalesce(r.entity_type, '') || '|' || coalesce(r.entity_id, '') || '|' || r.metadata::text || '|' || r.created_at::text, 'UTF8')), 'hex');
    if r.prev_hash is distinct from v_prev or r.hash <> v_expect then v_bad := r.id; exit; end if;
    v_prev := r.hash;
  end loop;
  return jsonb_build_object('ok', v_bad is null, 'checked', v_n, 'first_bad_id', v_bad);
end $$;

do $$ declare f text; begin
  foreach f in array array['tally_input(uuid)', 'record_tally_run(uuid, text, jsonb, jsonb)', 'approve_tally_run(uuid)', 'list_tally_runs(uuid)',
                           'published_result(uuid)', 'verify_audit_chain(uuid)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop; end $$;
