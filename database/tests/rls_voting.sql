\set ON_ERROR_STOP on
insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000000c1', 'vowner@t.io', now()), ('00000000-0000-0000-0000-0000000000c2', 'vroll1@v.io', now()),
  ('00000000-0000-0000-0000-0000000000c3', 'vroll2@v.io', now()), ('00000000-0000-0000-0000-0000000000c4', 'vstranger@v.io', now());

-- Helper: a scheduled-then-opened election with two options and the two roll voters. Returns the election id.
create or replace function public.t_open_election(p_org uuid, p_title text, p_method text, p_seats int, p_settings jsonb, p_labels text[]) returns uuid
language plpgsql as $$
declare e public.elections; l text;
begin
  e := public.create_election(p_org, p_title, null, p_method, p_seats, 'restricted', now() + interval '1 day', now() + interval '2 days', p_settings);
  foreach l in array p_labels loop perform public.add_ballot_option(e.id, l, null, '{}'); end loop;
  perform public.add_election_voters(e.id, '[{"email": "vroll1@v.io"}, {"email": "vroll2@v.io"}]');
  e := public.transition_election(e.id, 'scheduled');
  return e.id;
end $$;
grant execute on function public.t_open_election(uuid, text, text, int, jsonb, text[]) to authenticated;

do $$
declare o uuid := '00000000-0000-0000-0000-0000000000c1'; r1 uuid := '00000000-0000-0000-0000-0000000000c2';
        r2 uuid := '00000000-0000-0000-0000-0000000000c3'; s uuid := '00000000-0000-0000-0000-0000000000c4';
        org public.organisations; strict uuid; flex uuid; ranked uuid; a uuid; b uuid; c uuid; r jsonb; r2j jsonb; n int;
begin
  perform public.t_as(o);
  org := public.create_organisation('Theta Club', 'theta-club');

  -- ===== rules are validated and stored as the person in charge chose them =====
  perform public.t_expect(format($q$select public.create_election(%L, 'Bad rules', null, 'plurality', 1, 'restricted', null, null, '{"allow_vote_change": "yes"}')$q$, org.id), 'NV422');
  assert (public.create_election(org.id, 'Rules stored', null, 'plurality', 1, 'restricted', null, null,
          '{"allow_vote_change": false, "allow_blank_ballot": true}')).settings = '{"allow_vote_change": false, "allow_blank_ballot": true}', 'rules stored';

  -- ===== strict election: one vote, no blank, no changes =====
  strict := public.t_open_election(org.id, 'Strict vote', 'plurality', 1, '{"allow_vote_change": false}', array['Ana', 'Ben']);
  select id into a from public.ballot_options where election_id = strict and label = 'Ana';
  select id into b from public.ballot_options where election_id = strict and label = 'Ben';
  perform public.t_as(r1);
  perform public.t_expect(format($q$select public.cast_vote(%L, array[%L]::uuid[])$q$, strict, a), 'NV409');       -- not open yet
  perform public.t_as(o); perform public.transition_election(strict, 'open');

  perform public.t_as(s);
  perform public.t_expect(format($q$select public.cast_vote(%L, array[%L]::uuid[])$q$, strict, a), 'NV403');       -- not on the voter list
  perform public.t_as(o);
  perform public.t_expect(format($q$select public.cast_vote(%L, array[%L]::uuid[])$q$, strict, a), 'NV403');       -- owner is not on the list either
  perform public.t_as(r1);
  perform public.t_expect(format($q$select public.cast_vote(%L, '{}'::uuid[])$q$, strict), 'NV422');              -- blank not allowed by default
  perform public.t_expect(format($q$select public.cast_vote(%L, array[%L, %L]::uuid[])$q$, strict, a, b), 'NV422'); -- more than the seats
  perform public.t_expect(format($q$select public.cast_vote(%L, array[%L, %L]::uuid[])$q$, strict, a, a), 'NV422'); -- duplicate
  perform public.t_expect(format($q$select public.cast_vote(%L, array[%L]::uuid[])$q$, strict, gen_random_uuid()), 'NV422'); -- not on this ballot
  r := public.cast_vote(strict, array[a]);
  assert length(r ->> 'receipt') = 64 and not (r ->> 'changed')::boolean, 'vote accepted';
  perform public.t_expect(format($q$select public.cast_vote(%L, array[%L]::uuid[])$q$, strict, b), 'NV409');       -- changes switched off
  assert public.verify_receipt(strict, r ->> 'receipt') and not public.verify_receipt(strict, repeat('0', 64)) and not public.verify_receipt(strict, 'nope'), 'receipt check';
  assert (public.my_vote(strict) ->> 'voted')::boolean and not (public.my_vote(strict) ->> 'can_change')::boolean
         and public.my_vote(strict) -> 'selections' = 'null'::jsonb, 'secret ballot: choice is not retrievable';

  -- API roles can't touch the voting tables at all
  perform public.t_expect('select count(*) from public.ballots', '42501');
  perform public.t_expect('select count(*) from public.vote_participation', '42501');
  perform public.t_expect('select count(*) from public.election_vote_keys', '42501');
  perform public.t_expect(format($q$insert into public.ballots (election_id, selections, receipt_hash) values (%L, '{}', '\x00')$q$, strict), '42501');

  perform public.t_as(r2); perform public.cast_vote(strict, array[b]);
  perform public.t_as(o);
  assert (public.election_turnout(strict) ->> 'voted')::int = 2 and (public.election_turnout(strict) ->> 'eligible')::int = 2, 'turnout';
  perform public.t_as(r1);
  perform public.t_expect(format($q$select public.election_turnout(%L)$q$, strict), 'NV404');                      -- voters don't see turnout
  perform public.t_admin();
  assert (select count(*) from public.ballots where election_id = strict) = 2, 'two ballots';
  assert (select count(*) from public.vote_participation where election_id = strict) = 2, 'two participants';
  assert (select count(*) from public.ballots where election_id = strict and slot is not null) = 0, 'no slot when changes are off';
  perform public.t_as(o); perform public.transition_election(strict, 'closed');
  perform public.t_as(r2);
  perform public.t_expect(format($q$select public.cast_vote(%L, array[%L]::uuid[])$q$, strict, a), 'NV409');       -- closed

  -- ===== flexible election: blank allowed, votes can be changed while open =====
  flex := public.t_open_election(org.id, 'Flexible vote', 'plurality', 2, '{"allow_vote_change": true, "allow_blank_ballot": true}', array['Cy', 'Di']);
  select id into a from public.ballot_options where election_id = flex and label = 'Cy';
  select id into b from public.ballot_options where election_id = flex and label = 'Di';
  perform public.t_as(o); perform public.transition_election(flex, 'open');
  perform public.t_as(r1);
  r := public.cast_vote(flex, '{}'::uuid[]);                                                                       -- blank is allowed here
  r2j := public.cast_vote(flex, array[b, a]);
  assert (r2j ->> 'changed')::boolean and r ->> 'receipt' <> r2j ->> 'receipt', 'vote changed, new receipt';
  assert not public.verify_receipt(flex, r ->> 'receipt') and public.verify_receipt(flex, r2j ->> 'receipt'), 'only the latest receipt counts';
  assert public.my_vote(flex) -> 'selections' = to_jsonb(case when a < b then array[a, b] else array[b, a] end), 'voter sees own vote; order not kept';
  assert (public.my_vote(flex) ->> 'can_change')::boolean, 'can change';
  perform public.t_as(r2);
  assert public.my_vote(flex) -> 'selections' = 'null'::jsonb and not (public.my_vote(flex) ->> 'voted')::boolean, 'other voters see nothing of it';
  perform public.cast_vote(flex, array[a]);
  perform public.t_admin();
  assert (select count(*) from public.ballots where election_id = flex) = 2, 'one ballot per voter after changes';
  assert (select count(*) from public.ballots where election_id = flex and slot is not null) = 2 and (select count(*) from public.election_vote_keys where election_id = flex) = 1, 'slots while open';
  perform public.t_as(o); perform public.transition_election(flex, 'closed');
  perform public.t_admin();
  assert (select count(*) from public.ballots where election_id = flex and slot is not null) = 0, 'slots removed on close';
  assert (select count(*) from public.election_vote_keys where election_id = flex) = 0, 'key destroyed on close';
  perform public.t_as(r1);
  assert (public.my_vote(flex) ->> 'voted')::boolean and public.my_vote(flex) -> 'selections' = 'null'::jsonb and not (public.my_vote(flex) ->> 'can_change')::boolean, 'no linkage after close';
  perform public.t_expect(format($q$select public.cast_vote(%L, array[%L]::uuid[])$q$, flex, a), 'NV409');

  -- ===== ranked ballots keep their order =====
  ranked := public.t_open_election(org.id, 'Ranked vote', 'irv', 1, '{}', array['Eve', 'Fay']);
  select id into a from public.ballot_options where election_id = ranked and label = 'Eve';
  select id into b from public.ballot_options where election_id = ranked and label = 'Fay';
  perform public.t_as(o); perform public.transition_election(ranked, 'open');
  perform public.t_as(r1); perform public.cast_vote(ranked, array[b, a]);
  perform public.t_admin();
  assert (select selections from public.ballots where election_id = ranked) = array[b, a], 'ranking kept';

  -- ===== structure and audit =====
  assert not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'ballots'
                     and column_name ~ 'user|voter|email|account|auth|time|_at'), 'ballots carry no identity or timing columns';
  select count(*) into n from public.audit_events where event_type = 'vote.accepted'; assert n >= 6, 'accepted votes audited, found ' || n;
  select count(*) into n from public.audit_events where event_type = 'vote.accepted' and actor_id is not null; assert n = 0, 'no voter in vote audit events';
  select count(*) into n from public.audit_events where event_type = 'vote.accepted' and metadata::text ~ '[0-9a-f]{8}-[0-9a-f]{4}'; assert n = 0, 'no ids in vote audit metadata';
end $$;
select 'rls_voting: passed' as result;
