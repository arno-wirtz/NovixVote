\set ON_ERROR_STOP on
insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000000f1', 'gowner@t.io', now()), ('00000000-0000-0000-0000-0000000000f2', 'gmgr@t.io', now()),
  ('00000000-0000-0000-0000-0000000000f3', 'gmember@t.io', now()), ('00000000-0000-0000-0000-0000000000f4', 'roll@voters.io', now()),
  ('00000000-0000-0000-0000-0000000000f5', 'stranger@voters.io', now()), ('00000000-0000-0000-0000-0000000000f6', 'other@t.io', now()),
  ('00000000-0000-0000-0000-0000000000f7', 'unconfirmed@voters.io', null);

-- Setup: workspace (owner, election manager, plain member) + an unrelated workspace.
do $$
declare o uuid := '00000000-0000-0000-0000-0000000000f1'; m uuid := '00000000-0000-0000-0000-0000000000f2';
        v uuid := '00000000-0000-0000-0000-0000000000f3'; x uuid := '00000000-0000-0000-0000-0000000000f6'; org public.organisations;
begin
  perform public.t_as(o); org := public.create_organisation('Epsilon Guild', 'epsilon-guild');
  perform public.create_invitation(org.id, 'gmgr@t.io', 'election_manager'); perform public.create_invitation(org.id, 'gmember@t.io', 'voter');
  perform public.t_as(m); perform public.respond_to_invitation((select id from public.my_invitations() limit 1), true);
  perform public.t_as(v); perform public.respond_to_invitation((select id from public.my_invitations() limit 1), true);
  perform public.t_as(x); perform public.create_organisation('Zeta Other', 'zeta-other');
end $$;

-- ===== ballot options =====
do $$
declare m uuid := '00000000-0000-0000-0000-0000000000f2'; v uuid := '00000000-0000-0000-0000-0000000000f3'; x uuid := '00000000-0000-0000-0000-0000000000f6';
        org uuid := (select id from public.organisations where slug = 'epsilon-guild');
        lst public.elections; cand public.elections; a public.ballot_options; b public.ballot_options; n int;
begin
  perform public.t_as(m);
  lst := public.create_election(org, 'List election', null, 'd_hondt', 5, 'restricted', null, null, '{}');
  cand := public.create_election(org, 'Candidate election', null, 'plurality', 1, 'restricted', null, null, '{}');

  perform public.t_expect(format($q$select public.add_ballot_option(%L, '  ', null, '{}')$q$, lst.id), 'NV422');
  perform public.t_expect(format($q$select public.add_ballot_option(%L, repeat('x', 121), null, '{}')$q$, lst.id), 'NV422');
  perform public.t_expect(format($q$select public.add_ballot_option(%L, 'Greens', repeat('d', 501), '{}')$q$, lst.id), 'NV422');
  perform public.t_expect(format($q$select public.add_ballot_option(%L, 'Greens', null, array['Ann', 'ann'])$q$, lst.id), 'NV422');
  perform public.t_expect(format($q$select public.add_ballot_option(%L, 'Greens', null, array['Ann', ' '])$q$, lst.id), 'NV422');
  perform public.t_expect(format($q$select public.add_ballot_option(%L, 'Ana', null, array['Not allowed'])$q$, cand.id), 'NV422');  -- candidates have no members

  a := public.add_ballot_option(lst.id, '  Greens ', '  Climate first ', array[' Ann ', 'Bob']);
  assert a.label = 'Greens' and a.description = 'Climate first' and a.members = array['Ann', 'Bob'] and a.sort_order = 1, 'normalised option';
  b := public.add_ballot_option(lst.id, 'Reds', null, '{}'); assert b.sort_order = 2;
  perform public.t_expect(format($q$select public.add_ballot_option(%L, 'GREENS', null, '{}')$q$, lst.id), 'NV409');   -- case-insensitive duplicate

  perform public.t_expect(format($q$select public.reorder_ballot_options(%L, array[%L]::uuid[])$q$, lst.id, a.id), 'NV422');          -- incomplete
  perform public.t_expect(format($q$select public.reorder_ballot_options(%L, array[%L, %L]::uuid[])$q$, lst.id, a.id, a.id), 'NV422'); -- duplicate id
  perform public.t_expect(format($q$select public.reorder_ballot_options(%L, array[%L, %L]::uuid[])$q$, lst.id, a.id, gen_random_uuid()), 'NV422');
  perform public.reorder_ballot_options(lst.id, array[b.id, a.id]);
  assert (select array_agg(label order by sort_order) from public.ballot_options where election_id = lst.id) = array['Reds', 'Greens'], 'reordered';

  a := public.update_ballot_option(a.id, 'Greens United', 'x', array['Ann']);
  assert a.label = 'Greens United' and a.members = array['Ann'], 'updated';
  perform public.t_expect(format($q$select public.update_ballot_option(%L, 'reds', null, '{}')$q$, a.id), 'NV409');
  perform public.delete_ballot_option(b.id);
  assert (select count(*) from public.ballot_options where election_id = lst.id) = 1, 'deleted';

  -- switching a list election to a candidate method is refused while lists contain candidates
  perform public.t_expect(format($q$select public.update_election(%L, 'List election', null, 'plurality', 5, 'restricted', null, null, '{}')$q$, lst.id), 'NV409');

  -- cap of 200 options
  for n in 1..200 loop perform public.add_ballot_option(cand.id, 'Candidate ' || n, null, '{}'); end loop;
  perform public.t_expect(format($q$select public.add_ballot_option(%L, 'One too many', null, '{}')$q$, cand.id), 'NV422');

  -- plain members and outsiders: drafts are invisible, writes impossible
  perform public.t_as(v);
  select count(*) into n from public.ballot_options; assert n = 0, 'member does not see draft ballots';
  perform public.t_expect(format($q$select public.add_ballot_option(%L, 'Sneaky', null, '{}')$q$, lst.id), 'NV404');
  perform public.t_expect(format($q$select public.delete_ballot_option(%L)$q$, a.id), 'NV404');
  perform public.t_expect(format($q$insert into public.ballot_options (election_id, label, sort_order) values (%L, 'direct', 9)$q$, lst.id), '42501');
  perform public.t_as(x);
  select count(*) into n from public.ballot_options; assert n = 0, 'other tenant sees nothing';
  perform public.t_expect(format($q$select public.add_ballot_option(%L, 'Sneaky', null, '{}')$q$, lst.id), 'NV404');
end $$;

-- ===== voter list =====
do $$
declare m uuid := '00000000-0000-0000-0000-0000000000f2'; v uuid := '00000000-0000-0000-0000-0000000000f3'; x uuid := '00000000-0000-0000-0000-0000000000f6';
        org uuid := (select id from public.organisations where slug = 'epsilon-guild'); lst uuid := (select id from public.elections where title = 'List election');
        pub public.elections; r jsonb; n int; page jsonb;
begin
  perform public.t_as(m);
  perform public.t_expect(format($q$select public.add_election_voters(%L, '{"email": "a@b.io"}')$q$, lst), 'NV422');
  perform public.t_expect(format($q$select public.add_election_voters(%L, (select jsonb_agg(jsonb_build_object('email', 'u' || g || '@v.io')) from generate_series(1, 1001) g))$q$, lst), 'NV422');

  r := public.add_election_voters(lst, jsonb_build_array(
    jsonb_build_object('email', ' Roll@Voters.io ', 'name', 'Rita Roll'), jsonb_build_object('email', 'roll@voters.io'),
    jsonb_build_object('email', 'bad'), jsonb_build_object('email', 'x@y.io', 'name', repeat('n', 121)), to_jsonb('just a string'::text),
    jsonb_build_object('email', 'unconfirmed@voters.io'), jsonb_build_object('email', 'zed@voters.io')));
  assert (r ->> 'added')::int = 3 and (r ->> 'duplicates')::int = 1 and (r ->> 'invalid_count')::int = 3 and (r ->> 'total')::int = 3, 'import summary ' || r::text;
  assert jsonb_array_length(r -> 'invalid') = 3 and (r -> 'invalid' -> 0 ->> 'row')::int = 3, 'invalid rows reported with row numbers';
  assert (select name from public.election_voters where email = 'roll@voters.io') = 'Rita Roll', 'email normalised, name kept';

  page := public.election_voter_page(lst, 2, 0, null);
  assert (page ->> 'total')::int = 3 and jsonb_array_length(page -> 'items') = 2 and (page -> 'items' -> 0 ->> 'email') = 'roll@voters.io', 'paging sorted by email';
  page := public.election_voter_page(lst, 50, 0, 'RITA'); assert (page ->> 'total')::int = 1 and (page ->> 'all_total')::int = 3, 'search by name';
  assert (public.election_voter_page(lst, 50, 0, '100%') ->> 'total')::int = 0, 'wildcard characters are literal';

  pub := public.create_election(org, 'Public poll', null, 'plurality', 1, 'public', null, null, '{}');
  perform public.t_expect(format($q$select public.add_election_voters(%L, '[{"email": "a@b.io"}]')$q$, pub.id), 'NV409');
  perform public.t_expect(format($q$select public.update_election(%L, 'List election', null, 'd_hondt', 5, 'public', null, null, '{}')$q$, lst), 'NV409');  -- voters exist

  select count(*) into n from public.election_voters; assert n = 3, 'manager sees the roll';
  perform public.t_as(v);
  select count(*) into n from public.election_voters; assert n = 0, 'plain member cannot see the roll';
  perform public.t_expect(format($q$select public.election_voter_page(%L)$q$, lst), 'NV404');
  perform public.t_expect(format($q$select public.add_election_voters(%L, '[{"email": "a@b.io"}]')$q$, lst), 'NV404');
  perform public.t_expect(format($q$select public.remove_election_voter(%L)$q$, (select id from public.election_voters where email = 'zed@voters.io' limit 1)), 'NV404');
  perform public.t_as(x);
  select count(*) into n from public.election_voters; assert n = 0, 'other tenant cannot see the roll';
  perform public.t_expect(format($q$select public.election_voter_page(%L)$q$, lst), 'NV404');
  perform public.t_as(m);
  perform public.remove_election_voter((select id from public.election_voters where email = 'zed@voters.io'));
  assert (select count(*) from public.election_voters) = 2, 'voter removed';
end $$;

-- ===== readiness, scheduling gate, eligibility and visibility =====
do $$
declare m uuid := '00000000-0000-0000-0000-0000000000f2'; v uuid := '00000000-0000-0000-0000-0000000000f3';
        roll uuid := '00000000-0000-0000-0000-0000000000f4'; stranger uuid := '00000000-0000-0000-0000-0000000000f5';
        unconf uuid := '00000000-0000-0000-0000-0000000000f7'; x uuid := '00000000-0000-0000-0000-0000000000f6';
        org uuid := (select id from public.organisations where slug = 'epsilon-guild');
        e public.elections; pub public.elections; n int;
begin
  perform public.t_as(m);
  e := public.create_election(org, 'Gate test', null, 'plurality', 1, 'restricted', now() + interval '1 day', now() + interval '2 days', '{}');
  assert (select count(*) from public.election_readiness(e.id) where not ok) = 2, 'ballot and voters outstanding';
  assert (select bool_and(ok) from public.election_readiness(e.id) where key in ('window', 'future')), 'schedule ok';
  perform public.t_expect(format($q$select public.transition_election(%L, 'scheduled')$q$, e.id), 'NV422');
  perform public.add_ballot_option(e.id, 'Ana', null, '{}');
  perform public.t_expect(format($q$select public.transition_election(%L, 'scheduled')$q$, e.id), 'NV422');          -- still one option, no voters
  perform public.add_ballot_option(e.id, 'Ben', null, '{}');
  perform public.t_expect(format($q$select public.transition_election(%L, 'scheduled')$q$, e.id), 'NV422');          -- voters missing
  perform public.add_election_voters(e.id, '[{"email": "roll@voters.io"}, {"email": "unconfirmed@voters.io"}]');
  assert not exists (select 1 from public.election_readiness(e.id) where not ok), 'ready';

  -- drafts are invisible to people on the roll; nobody outside is eligible while drafting
  perform public.t_as(roll);
  select count(*) into n from public.elections where id = e.id; assert n = 0, 'draft invisible to roll voter';
  assert not public.is_eligible_voter(e.id), 'not eligible while draft';
  perform public.t_as(v);
  perform public.t_expect(format($q$select * from public.election_readiness(%L)$q$, e.id), 'NV404');           -- readiness is for managers

  perform public.t_as(m);
  e := public.transition_election(e.id, 'scheduled');
  perform public.t_expect(format($q$select public.add_ballot_option(%L, 'Late entry', null, '{}')$q$, e.id), 'NV409');   -- ballot locked
  perform public.add_election_voters(e.id, '[{"email": "late@voters.io"}]');                                              -- roll still open while scheduled

  -- eligibility and visibility once scheduled
  perform public.t_as(roll);
  assert public.is_eligible_voter(e.id), 'roll voter eligible';
  select count(*) into n from public.elections where id = e.id; assert n = 1, 'roll voter (not a member) sees the election';
  select count(*) into n from public.ballot_options where election_id = e.id; assert n = 2, 'and its ballot';
  select count(*) into n from public.election_voters; assert n = 0, 'but never the roll';
  select count(*) into n from public.organisation_members; assert n = 0, 'nor workspace members';
  assert public.election_organisation_name(e.id) = 'Epsilon Guild', 'organisation name shown to eligible voters';
  assert exists (select 1 from public.my_eligible_elections() where title = 'Gate test'), 'listed in my elections';
  perform public.t_expect(format($q$select public.transition_election(%L, 'open')$q$, e.id), 'NV404');   -- eligible voters manage nothing

  perform public.t_as(stranger);
  assert not public.is_eligible_voter(e.id), 'stranger not eligible';
  select count(*) into n from public.elections where id = e.id; assert n = 0, 'stranger cannot see a restricted election';
  select count(*) into n from public.ballot_options where election_id = e.id; assert n = 0, 'nor its ballot';
  assert not exists (select 1 from public.my_eligible_elections()), 'nothing listed for stranger';
  perform public.t_as(unconf);
  assert not public.is_eligible_voter(e.id), 'unconfirmed email is not eligible';
  assert not exists (select 1 from public.my_eligible_elections()), 'nothing listed for unconfirmed email';
  perform public.t_as(v);
  select count(*) into n from public.elections where id = e.id; assert n = 1, 'workspace members see scheduled elections';
  assert not public.is_eligible_voter(e.id), 'membership alone does not make you eligible for a restricted election';

  -- voter list locks when voting opens
  perform public.t_as(m);
  e := public.transition_election(e.id, 'open');
  perform public.t_expect(format($q$select public.add_election_voters(%L, '[{"email": "toolate@voters.io"}]')$q$, e.id), 'NV409');
  perform public.t_expect(format($q$select public.remove_election_voter(%L)$q$, (select id from public.election_voters where election_id = e.id limit 1)), 'NV409');

  -- public elections: reachable by any confirmed account once scheduled, never listed, drafts hidden
  pub := public.create_election(org, 'Open poll', null, 'plurality', 1, 'public', now() + interval '1 day', now() + interval '2 days', '{}');
  perform public.t_as(stranger);
  select count(*) into n from public.elections where id = pub.id; assert n = 0, 'public draft hidden';
  perform public.t_as(m);
  perform public.add_ballot_option(pub.id, 'Yes', null, '{}'); perform public.add_ballot_option(pub.id, 'No', null, '{}');
  assert not exists (select 1 from public.election_readiness(pub.id) where key = 'voters'), 'public elections need no voter list';
  pub := public.transition_election(pub.id, 'scheduled');
  perform public.t_as(stranger);
  assert public.is_eligible_voter(pub.id), 'any confirmed account is eligible for a public election';
  select count(*) into n from public.elections where id = pub.id; assert n = 1, 'visible by link';
  assert not exists (select 1 from public.my_eligible_elections() where title = 'Open poll'), 'public elections are not listed';
  perform public.t_as(unconf);
  assert not public.is_eligible_voter(pub.id), 'unconfirmed account is not eligible for a public election either';

  -- other tenant
  perform public.t_as(x);
  perform public.t_expect(format($q$select * from public.election_readiness(%L)$q$, e.id), 'NV404');
  perform public.t_expect(format($q$select public.add_election_voters(%L, '[{"email": "a@b.io"}]')$q$, e.id), 'NV404');

  -- audit
  perform public.t_admin();
  select count(*) into n from public.audit_events where event_type in ('ballot.option_added', 'ballot.option_updated', 'ballot.option_removed', 'ballot.reordered', 'voters.added', 'voters.removed');
  assert n >= 10, 'ballot and voter changes audited, found ' || n;
  select count(*) into n from public.audit_events where metadata::text ~ '@(t|voters)\.io'; assert n = 0, 'no email addresses in audit metadata';
end $$;
select 'rls_ballot_voters: passed' as result;
