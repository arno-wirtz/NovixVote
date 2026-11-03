\set ON_ERROR_STOP on
insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000000a1', 'irvowner@t.io', now());

do $$
declare o uuid := '00000000-0000-0000-0000-0000000000a1'; org public.organisations; e public.elections; l public.elections; n int;
begin
  perform public.t_as(o);
  org := public.create_organisation('Eta Society', 'eta-society');

  -- single-winner method: exactly one seat, no threshold, ranked ballot of plain candidates
  perform public.t_expect(format($q$select public.create_election(%L, 'Chair', null, 'irv', 2, 'restricted', null, null, '{}')$q$, org.id), 'NV422');
  perform public.t_expect(format($q$select public.create_election(%L, 'Chair', null, 'irv', 1, 'restricted', null, null, '{"threshold_percent": 5}')$q$, org.id), 'NV422');
  e := public.create_election(org.id, 'Chair', null, 'irv', 1, 'restricted', null, null, '{}');
  assert e.settings = '{}'::jsonb, 'no settings for irv';
  perform public.add_ballot_option(e.id, 'Ana', null, '{}'); perform public.add_ballot_option(e.id, 'Ben', null, '{}');
  perform public.t_expect(format($q$select public.add_ballot_option(%L, 'Cara', null, array['Not allowed'])$q$, e.id), 'NV422');   -- ranked ballots have no list members
  assert (select noun from (select case when 'The ballot has at least 2 candidates' = label then 'candidates' end noun from public.election_readiness(e.id) where key = 'ballot') x) = 'candidates', 'readiness says candidates';

  -- updating an irv draft to more seats is refused; changing method keeps the same guard
  perform public.t_expect(format($q$select public.update_election(%L, 'Chair', null, 'irv', 3, 'restricted', null, null, '{}')$q$, e.id), 'NV422');
  e := public.update_election(e.id, 'Chair', null, 'plurality', 3, 'restricted', null, null, '{}'); assert e.voting_method = 'plurality';
  e := public.update_election(e.id, 'Chair', null, 'irv', 1, 'restricted', null, null, '{}'); assert e.voting_method = 'irv';

  -- a list election whose lists have candidates cannot be switched to a ranked (candidate) method; without members it can
  l := public.create_election(org.id, 'List vote', null, 'd_hondt', 5, 'restricted', null, null, '{}');
  perform public.add_ballot_option(l.id, 'Greens', null, array['Ann']);
  perform public.t_expect(format($q$select public.update_election(%L, 'List vote', null, 'irv', 1, 'restricted', null, null, '{}')$q$, l.id), 'NV409');
  perform public.update_ballot_option((select id from public.ballot_options where election_id = l.id), 'Greens', null, '{}');
  l := public.update_election(l.id, 'List vote', null, 'irv', 1, 'restricted', null, null, '{}'); assert l.voting_method = 'irv';

  select count(*) into n from public.voting_methods where key in ('plurality', 'd_hondt', 'sainte_lague', 'irv'); assert n = 4;
  perform public.t_expect($q$insert into public.voting_methods (key, name, category, ballot_type) values ('x', 'x', 'plurality', 'candidate')$q$, '42501');
end $$;
select 'rls_instant_runoff: passed' as result;
