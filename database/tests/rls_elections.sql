\set ON_ERROR_STOP on
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000e1', 'eowner@test.io'), ('00000000-0000-0000-0000-0000000000e2', 'emgr@test.io'),
  ('00000000-0000-0000-0000-0000000000e3', 'evoter@test.io'), ('00000000-0000-0000-0000-0000000000e4', 'eother@test.io');

-- Setup: workspace with owner, an election manager and a voter; a separate workspace for isolation checks.
do $$
declare o uuid := '00000000-0000-0000-0000-0000000000e1'; m uuid := '00000000-0000-0000-0000-0000000000e2';
        v uuid := '00000000-0000-0000-0000-0000000000e3'; x uuid := '00000000-0000-0000-0000-0000000000e4'; org public.organisations;
begin
  perform public.t_as(o); org := public.create_organisation('Delta Union', 'delta-union');
  perform public.create_invitation(org.id, 'emgr@test.io', 'election_manager'); perform public.create_invitation(org.id, 'evoter@test.io', 'voter');
  perform public.t_as(m); perform public.respond_to_invitation((select id from public.my_invitations() limit 1), true);
  perform public.t_as(v); perform public.respond_to_invitation((select id from public.my_invitations() limit 1), true);
  perform public.t_as(x); perform public.create_organisation('Other Org', 'other-org');
end $$;

do $$
declare o uuid := '00000000-0000-0000-0000-0000000000e1'; m uuid := '00000000-0000-0000-0000-0000000000e2';
        v uuid := '00000000-0000-0000-0000-0000000000e3'; x uuid := '00000000-0000-0000-0000-0000000000e4';
        org uuid := (select id from public.organisations where slug = 'delta-union'); e public.elections; n int;
begin
  -- Creation permissions and validation.
  perform public.t_as(v);
  perform public.t_expect(format($q$select public.create_election(%L, 'Board 2026', null, 'plurality', 1, 'restricted', null, null, '{}')$q$, org), 'NV403');
  perform public.t_as(m);
  perform public.t_expect(format($q$select public.create_election(%L, 'ab', null, 'plurality', 1, 'restricted', null, null, '{}')$q$, org), 'NV422');
  perform public.t_expect(format($q$select public.create_election(%L, 'Board 2026', null, 'borda', 1, 'restricted', null, null, '{}')$q$, org), 'NV422');
  perform public.t_expect(format($q$select public.create_election(%L, 'Board 2026', null, 'plurality', 0, 'restricted', null, null, '{}')$q$, org), 'NV422');
  perform public.t_expect(format($q$select public.create_election(%L, 'Board 2026', null, 'plurality', 1, 'restricted', now() + interval '2 day', now() + interval '1 day', '{}')$q$, org), 'NV422');
  perform public.t_expect(format($q$select public.create_election(%L, 'Board 2026', null, 'plurality', 1, 'restricted', null, null, '{"threshold_percent": 5}')$q$, org), 'NV422');
  perform public.t_expect(format($q$select public.create_election(%L, 'Board 2026', null, 'd_hondt', 5, 'restricted', null, null, '{"threshold_percent": 101}')$q$, org), 'NV422');
  perform public.t_expect(format($q$select public.create_election(%L, 'Board 2026', null, 'd_hondt', 5, 'restricted', null, null, '{"evil": true}')$q$, org), 'NV422');
  perform public.t_expect(format($q$select public.create_election(%L, 'Board 2026', null, 'd_hondt', 5, 'restricted', null, null, '{"threshold_percent": "5"}')$q$, org), 'NV422');

  e := public.create_election(org, '  Council 2026 ', '  ', 'd_hondt', 9, 'restricted', null, null, '{"threshold_percent": 5}');
  assert e.status = 'draft' and e.title = 'Council 2026' and e.description is null and e.settings = '{"threshold_percent": 5}', 'draft normalised';
  assert (public.create_election(org, 'Chair 2026', null, 'plurality', 1, 'public', null, null, '{}')).settings = '{}', 'plurality settings empty';

  -- Direct writes are impossible; drafts are hidden from voters and other workspaces.
  perform public.t_expect(format($q$update public.elections set status = 'published' where id = %L$q$, e.id), '42501');
  perform public.t_expect(format($q$insert into public.elections (organisation_id, title, voting_method, seats, created_by) values (%L, 'x1x', 'plurality', 1, auth.uid())$q$, org), '42501');
  select count(*) into n from public.elections; assert n = 2, 'manager sees drafts';
  perform public.t_as(v); select count(*) into n from public.elections; assert n = 0, 'voter does not see drafts';
  perform public.t_expect(format($q$select public.transition_election(%L, 'scheduled')$q$, e.id), 'NV403');
  perform public.t_as(x); select count(*) into n from public.elections; assert n = 0, 'other tenant sees nothing';
  perform public.t_expect(format($q$select public.transition_election(%L, 'scheduled')$q$, e.id), 'NV404');
  perform public.t_expect(format($q$select public.update_election(%L, 'Hijack', null, 'plurality', 1, 'public', null, null, '{}')$q$, e.id), 'NV404');
  perform public.t_expect(format($q$select public.delete_election(%L)$q$, e.id), 'NV404');

  -- Lifecycle rules.
  perform public.t_as(m);
  perform public.t_expect(format($q$select public.transition_election(%L, 'scheduled')$q$, e.id), 'NV422');        -- no dates yet
  e := public.update_election(e.id, 'Council 2026', 'Annual council', 'sainte_lague', 11, 'restricted',
                              now() - interval '1 hour', now() + interval '1 day', '{"threshold_percent": 3.5}');
  assert e.voting_method = 'sainte_lague' and e.settings = '{"threshold_percent": 3.5}', 'draft editable';
  perform public.t_expect(format($q$select public.transition_election(%L, 'scheduled')$q$, e.id), 'NV422');        -- opens in the past
  e := public.update_election(e.id, 'Council 2026', 'Annual council', 'sainte_lague', 11, 'restricted',
                              now() + interval '1 day', now() + interval '2 day', '{"threshold_percent": 3.5}');
  perform public.t_expect(format($q$select public.transition_election(%L, 'scheduled')$q$, e.id), 'NV422');        -- ballot not ready yet
  perform public.add_ballot_option(e.id, 'List A', null, '{}'); perform public.add_ballot_option(e.id, 'List B', null, '{}');
  perform public.t_expect(format($q$select public.transition_election(%L, 'scheduled')$q$, e.id), 'NV422');        -- no voters yet
  perform public.add_election_voters(e.id, '[{"email": "someone@voters.io"}]');
  perform public.t_expect(format($q$select public.transition_election(%L, 'open')$q$, e.id), 'NV409');            -- draft -> open
  perform public.t_expect(format($q$select public.transition_election(%L, 'published')$q$, e.id), 'NV403');      -- manager: no approval right
  perform public.t_as(o);
  perform public.t_expect(format($q$select public.transition_election(%L, 'published')$q$, e.id), 'NV409');      -- owner: draft -> published is not a legal move
  perform public.t_as(m);
  e := public.transition_election(e.id, 'scheduled'); assert e.status = 'scheduled', 'scheduled';
  perform public.t_expect(format($q$select public.update_election(%L, 'Council 2026', null, 'plurality', 1, 'public', null, null, '{}')$q$, e.id), 'NV409');
  perform public.t_expect(format($q$select public.delete_election(%L)$q$, e.id), 'NV409');
  perform public.t_as(v); select count(*) into n from public.elections; assert n = 1, 'voter sees scheduled election';
  perform public.t_as(m);
  e := public.transition_election(e.id, 'draft'); assert e.status = 'draft', 'unscheduled';
  e := public.transition_election(e.id, 'scheduled');
  e := public.transition_election(e.id, 'open'); assert e.status = 'open' and e.opens_at <= now(), 'opened now';
  e := public.transition_election(e.id, 'closed'); assert e.status = 'closed' and e.closes_at <= now(), 'closed early';
  perform public.t_expect(format($q$select public.transition_election(%L, 'published')$q$, e.id), 'NV403');       -- manager can't approve
  perform public.t_as(o);
  e := public.transition_election(e.id, 'published');
  assert e.status = 'published' and e.published_by = o and e.published_at is not null, 'published by approver';
  perform public.t_expect(format($q$select public.transition_election(%L, 'draft')$q$, e.id), 'NV409');
  perform public.t_expect(format($q$select public.transition_election(%L, 'open')$q$, e.id), 'NV409');

  -- Draft deletion.
  perform public.t_as(m);
  perform public.delete_election((select id from public.elections where title = 'Chair 2026'));
end $$;

-- Time-based transitions need real time to pass, so each step is its own transaction.
do $$
declare m uuid := '00000000-0000-0000-0000-0000000000e2'; org uuid := (select id from public.organisations where slug = 'delta-union'); e public.elections;
begin
  perform public.t_as(m);
  e := public.create_election(org, 'Timed vote', null, 'plurality', 1, 'restricted', now() + interval '2 seconds', now() + interval '4 seconds', '{}');
  perform public.add_ballot_option(e.id, 'Ana', null, '{}'); perform public.add_ballot_option(e.id, 'Ben', null, '{}');
  perform public.add_election_voters(e.id, '[{"email": "timed@voters.io"}]');
  e := public.transition_election(e.id, 'scheduled');
  perform public.t_expect(format($q$select public.update_election(%L, 'Timed vote', null, 'plurality', 1, 'restricted', null, null, '{}')$q$, e.id), 'NV409');
end $$;
select pg_sleep(2.5);
do $$
declare m uuid := '00000000-0000-0000-0000-0000000000e2'; e public.elections;
begin
  perform public.t_as(m);
  assert public.advance_elections() = 1, 'one election advanced';
  select * into e from public.elections where title = 'Timed vote'; assert e.status = 'open', 'auto-opened, was ' || e.status;
  assert public.advance_elections() = 0, 'idempotent';
  perform public.t_expect(format($q$select public.transition_election(%L, 'draft')$q$, e.id), 'NV409');
end $$;
select pg_sleep(2);
do $$
declare m uuid := '00000000-0000-0000-0000-0000000000e2'; e public.elections; n int;
begin
  perform public.t_as(m);
  select * into e from public.elections where title = 'Timed vote'; assert public.advance_elections() >= 1;
  select * into e from public.elections where title = 'Timed vote'; assert e.status = 'closed', 'auto-closed, was ' || e.status;
  perform public.t_admin();
  select count(*) into n from public.audit_events where event_type = 'election.status_changed' and (metadata ->> 'automatic')::boolean; assert n = 2, 'automatic moves audited';
end $$;
select 'rls_elections: passed' as result;
