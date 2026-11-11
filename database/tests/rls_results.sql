\set ON_ERROR_STOP on
insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000000b1', 'rowner@t.io', now()), ('00000000-0000-0000-0000-0000000000b2', 'rvoter1@v.io', now()),
  ('00000000-0000-0000-0000-0000000000b3', 'rvoter2@v.io', now()), ('00000000-0000-0000-0000-0000000000b4', 'rmgr@t.io', now());

create or replace function public.t_open_election(p_org uuid, p_title text, p_method text, p_seats int, p_settings jsonb, p_labels text[]) returns uuid
language plpgsql as $$
declare e public.elections; l text;
begin
  e := public.create_election(p_org, p_title, null, p_method, p_seats, 'restricted', now() + interval '1 day', now() + interval '2 days', p_settings);
  foreach l in array p_labels loop perform public.add_ballot_option(e.id, l, null, '{}'); end loop;
  perform public.add_election_voters(e.id, '[{"email": "rvoter1@v.io"}, {"email": "rvoter2@v.io"}]');
  e := public.transition_election(e.id, 'scheduled');
  return e.id;
end $$;
grant execute on function public.t_open_election(uuid, text, text, int, jsonb, text[]) to authenticated;

do $$
declare o uuid := '00000000-0000-0000-0000-0000000000b1'; v1 uuid := '00000000-0000-0000-0000-0000000000b2';
        v2 uuid := '00000000-0000-0000-0000-0000000000b3'; m uuid := '00000000-0000-0000-0000-0000000000b4';
        org public.organisations; el uuid; empty_el uuid; a uuid; b uuid; ti jsonb; h text; run1 jsonb; run2 jsonb; chain jsonb; n int;
begin
  perform public.t_as(o);
  org := public.create_organisation('Iota Club', 'iota-club');
  perform public.create_invitation(org.id, 'rmgr@t.io', 'election_manager');
  perform public.t_as(m); perform public.respond_to_invitation((select id from public.my_invitations() limit 1), true);

  -- a plurality election that ends in a tie
  perform public.t_as(m);
  el := public.t_open_election(org.id, 'Tied vote', 'plurality', 1, '{}', array['Ana', 'Ben']);
  select id into a from public.ballot_options where election_id = el and label = 'Ana';
  select id into b from public.ballot_options where election_id = el and label = 'Ben';
  perform public.transition_election(el, 'open');
  perform public.t_as(v1); perform public.cast_vote(el, array[a]);
  perform public.t_as(v2); perform public.cast_vote(el, array[b]);

  -- counting only after voting has closed, only by people who can manage the election
  perform public.t_as(m);
  perform public.t_expect(format($q$select public.tally_input(%L)$q$, el), 'NV409');
  perform public.transition_election(el, 'closed');
  perform public.t_as(v1);
  perform public.t_expect(format($q$select public.tally_input(%L)$q$, el), 'NV404');
  perform public.t_expect(format($q$select public.list_tally_runs(%L)$q$, el), 'NV404');
  perform public.t_as(m);
  ti := public.tally_input(el);
  assert (ti ->> 'ballot_count')::int = 2 and jsonb_array_length(ti -> 'ballots') = 2 and jsonb_array_length(ti -> 'options') = 2, 'ballots handed over';
  assert not (ti::text ~ 'user|voter|email'), 'no identity in the ballot set';
  h := ti ->> 'hash'; assert length(h) = 64;

  -- recording a count: the hash ties it to the real ballots; counts are permanent
  perform public.t_expect(format($q$select public.record_tally_run(%L, %L, '{"complete": false}', null)$q$, el, repeat('0', 64)), 'NV409');
  perform public.t_expect(format($q$select public.record_tally_run(%L, %L, '{"winners": []}', null)$q$, el, h), 'NV422');
  perform public.t_expect(format($q$select public.record_tally_run(%L, %L, '{"complete": true}', '{"method": "lots"}')$q$, el, h), 'NV422');
  run1 := public.record_tally_run(el, h, '{"complete": false, "tied_for_last_seat": ["Ana", "Ben"]}', null);
  assert (run1 ->> 'run_number')::int = 1;
  perform public.t_expect(format($q$select public.approve_tally_run(%L)$q$, run1 ->> 'id'), 'NV403');                       -- manager can't approve
  perform public.t_as(o);
  perform public.t_expect(format($q$select public.approve_tally_run(%L)$q$, run1 ->> 'id'), 'NV422');                       -- unresolved tie
  perform public.t_expect(format($q$select public.transition_election(%L, 'published')$q$, el), 'NV409');                  -- ballots exist, no approved count
  perform public.t_as(m);
  run2 := public.record_tally_run(el, h, '{"complete": true, "winners": ["Ana"]}', '{"method": "lots", "note": "Returning officer drew lots", "order": ["Ana", "Ben"]}');
  assert (run2 ->> 'run_number')::int = 2;
  perform public.t_as(o);
  perform public.t_expect(format($q$select public.approve_tally_run(%L)$q$, run1 ->> 'id'), 'NV422');
  assert public.published_result(el) is null, 'nothing public before publication';
  perform public.approve_tally_run((run2 ->> 'id')::uuid);
  perform public.t_expect(format($q$select public.approve_tally_run(%L)$q$, run2 ->> 'id'), 'NV409');                       -- already approved
  assert jsonb_array_length(public.list_tally_runs(el)) = 2 and (public.list_tally_runs(el) -> 0 ->> 'approved')::boolean and (public.list_tally_runs(el) -> 0 ->> 'run_number')::int = 2, 'both runs kept';
  perform public.transition_election(el, 'published');
  perform public.t_as(m);
  perform public.t_expect(format($q$select public.record_tally_run(%L, %L, '{"complete": true}', null)$q$, el, h), 'NV409');   -- published: no more counts

  -- eligible voters (not even workspace members) see the approved result and nothing else
  perform public.t_as(v1);
  assert (public.published_result(el) ->> 'run_number')::int = 2 and (public.published_result(el) -> 'result' ->> 'complete')::boolean, 'voter sees the published result';
  perform public.t_expect('select count(*) from public.tally_runs', '42501');
  perform public.t_expect('select count(*) from public.tally_approvals', '42501');

  -- counts are append-only even for privileged callers
  perform public.t_admin();
  perform public.t_expect(format($q$update public.tally_runs set ballot_count = 0 where id = %L$q$, run2 ->> 'id'), 'P0001');
  perform public.t_expect('delete from public.tally_runs', 'P0001');
  perform public.t_expect('delete from public.tally_approvals', 'P0001');

  -- an election nobody voted in has nothing to count and can still be published
  perform public.t_as(m);
  empty_el := public.t_open_election(org.id, 'Quiet vote', 'plurality', 1, '{}', array['Cy', 'Di']);
  perform public.transition_election(empty_el, 'open'); perform public.transition_election(empty_el, 'closed');
  perform public.t_as(o); perform public.transition_election(empty_el, 'published');
  perform public.t_as(v1);
  assert public.published_result(empty_el) -> 'ballot_count' = '0'::jsonb, 'published with no ballots';

  -- audit trail: verifies, covers the new events, and can be read by owners only
  perform public.t_as(o);
  chain := public.verify_audit_chain(org.id);
  assert (chain ->> 'ok')::boolean and (chain ->> 'checked')::int > 10, 'audit chain verifies: ' || chain::text;
  perform public.t_as(m);
  perform public.t_expect(format($q$select public.verify_audit_chain(%L)$q$, org.id), 'NV404');
  perform public.t_admin();
  select count(*) into n from public.audit_events where organisation_id = org.id and event_type in ('tally.recorded', 'tally.approved'); assert n = 3, 'tally events audited, found ' || n;
end $$;
select 'rls_results: passed' as result;
