\set ON_ERROR_STOP on
insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000000d1', 'owner@test.io', now()), ('00000000-0000-0000-0000-0000000000d2', 'admin@test.io', now()),
  ('00000000-0000-0000-0000-0000000000d3', 'voter@test.io', now()), ('00000000-0000-0000-0000-0000000000d4', 'mgr@test.io', now()),
  ('00000000-0000-0000-0000-0000000000d5', 'unconfirmed@test.io', null), ('00000000-0000-0000-0000-0000000000d6', 'stranger@test.io', now());

do $$
declare
  o uuid := '00000000-0000-0000-0000-0000000000d1'; a uuid := '00000000-0000-0000-0000-0000000000d2';
  v uuid := '00000000-0000-0000-0000-0000000000d3'; m uuid := '00000000-0000-0000-0000-0000000000d4';
  u uuid := '00000000-0000-0000-0000-0000000000d5'; s uuid := '00000000-0000-0000-0000-0000000000d6';
  org public.organisations; inv public.organisation_invitations; n int;
begin
  perform public.t_as(o);
  org := public.create_organisation('Gamma Co', 'gamma-co');

  -- Owner invites an admin; duplicates, bad emails and owner invites are rejected.
  inv := public.create_invitation(org.id, '  Admin@Test.io ', 'admin');
  assert inv.email = 'admin@test.io' and inv.status = 'pending', 'email normalised';
  perform public.t_expect(format($q$select public.create_invitation(%L, 'admin@test.io', 'voter')$q$, org.id), 'NV409');
  perform public.t_expect(format($q$select public.create_invitation(%L, 'not-an-email', 'voter')$q$, org.id), 'NV422');
  perform public.t_expect(format($q$select public.create_invitation(%L, 'x@test.io', 'owner')$q$, org.id), 'NV422');
  select count(*) into n from public.organisation_invitations; assert n = 1, 'owner sees invitation';

  -- A stranger sees and can do nothing.
  perform public.t_as(s);
  select count(*) into n from public.organisation_invitations; assert n = 0, 'stranger sees none';
  select count(*) into n from public.my_invitations(); assert n = 0, 'stranger has no invitations';
  perform public.t_expect(format($q$select public.respond_to_invitation(%L, true)$q$, inv.id), 'NV404');
  perform public.t_expect(format($q$select public.create_invitation(%L, 'z@test.io', 'voter')$q$, org.id), 'NV403');
  perform public.t_expect(format($q$select public.revoke_invitation(%L)$q$, inv.id), 'NV404');
  perform public.t_expect(format($q$select public.remove_member(%L, %L)$q$, org.id, o), 'NV403');

  -- Unconfirmed email can't claim an invitation addressed to it.
  perform public.t_as(o);
  perform public.create_invitation(org.id, 'unconfirmed@test.io', 'voter');
  perform public.t_as(u);
  select count(*) into n from public.my_invitations(); assert n = 0, 'unconfirmed email gets nothing';

  -- Invitee accepts and becomes admin; the invitation can't be reused.
  perform public.t_as(a);
  select count(*) into n from public.my_invitations(); assert n = 1, 'admin sees own invitation';
  perform public.respond_to_invitation(inv.id, true);
  perform public.t_expect(format($q$select public.respond_to_invitation(%L, true)$q$, inv.id), 'NV404');
  assert (select role from public.my_membership(org.id)) = 'admin', 'admin role';
  assert (select permissions from public.my_membership(org.id)) @> array['members.manage'], 'admin can manage members';
  assert not ((select permissions from public.my_membership(org.id)) @> array['results.approve']), 'admin cannot approve results';

  -- Admin may invite managers/voters only.
  perform public.create_invitation(org.id, 'voter@test.io', 'voter');
  perform public.create_invitation(org.id, 'mgr@test.io', 'election_manager');
  perform public.t_expect(format($q$select public.create_invitation(%L, 'a2@test.io', 'admin')$q$, org.id), 'NV403');
  perform public.t_as(v); perform public.respond_to_invitation((select id from public.my_invitations() limit 1), true);
  perform public.t_as(m); perform public.respond_to_invitation((select id from public.my_invitations() limit 1), true);

  -- Revocation: admin can't revoke an admin invitation; owner can; revoked can't be reused.
  perform public.t_as(o);
  inv := public.create_invitation(org.id, 'late@test.io', 'admin');
  perform public.t_as(a);
  perform public.t_expect(format($q$select public.revoke_invitation(%L)$q$, inv.id), 'NV403');
  perform public.t_as(o); perform public.revoke_invitation(inv.id);
  perform public.t_expect(format($q$select public.revoke_invitation(%L)$q$, inv.id), 'NV409');

  -- Voters can't manage; visibility follows permissions.
  perform public.t_as(v);
  perform public.t_expect(format($q$select public.change_member_role(%L, %L, 'admin')$q$, org.id, v), 'NV403');
  perform public.t_expect(format($q$select public.create_invitation(%L, 'q@test.io', 'voter')$q$, org.id), 'NV403');
  select count(*) into n from public.organisation_members; assert n = 1, 'voter sees only own membership row';
  perform public.t_as(m);
  select count(*) into n from public.organisation_members; assert n = 4, 'manager (members.read) sees all members';

  -- Admin role limits.
  perform public.t_as(a);
  perform public.change_member_role(org.id, v, 'election_manager');
  perform public.change_member_role(org.id, v, 'voter');
  perform public.t_expect(format($q$select public.change_member_role(%L, %L, 'admin')$q$, org.id, v), 'NV403');
  perform public.t_expect(format($q$select public.change_member_role(%L, %L, 'voter')$q$, org.id, o), 'NV403');
  perform public.t_expect(format($q$select public.change_member_role(%L, %L, 'voter')$q$, org.id, a), 'NV403');
  perform public.t_expect(format($q$select public.remove_member(%L, %L)$q$, org.id, o), 'NV403');
  perform public.t_expect(format($q$select public.change_member_role(%L, %L, 'voter')$q$, org.id, s), 'NV404');

  -- Owner rules: last owner can't demote or leave; with a second owner they can.
  perform public.t_as(o);
  perform public.t_expect(format($q$select public.change_member_role(%L, %L, 'admin')$q$, org.id, o), 'NV409');
  perform public.t_expect(format($q$select public.remove_member(%L, %L)$q$, org.id, o), 'NV409');
  perform public.change_member_role(org.id, a, 'owner');
  perform public.change_member_role(org.id, o, 'admin');       -- allowed: another owner exists
  perform public.t_as(a);
  perform public.t_expect(format($q$select public.remove_member(%L, %L)$q$, org.id, a), 'NV409');   -- now the last owner
  perform public.change_member_role(org.id, o, 'owner');
  perform public.remove_member(org.id, a);                      -- an owner may leave when another remains
  perform public.t_as(a);
  select count(*) into n from public.organisations; assert n = 0, 'former member sees nothing';

  -- Removal and leaving.
  perform public.t_as(m); perform public.remove_member(org.id, m);              -- manager leaves
  perform public.t_as(o); perform public.remove_member(org.id, v);              -- owner removes voter
  select count(*) into n from public.organisation_members where organisation_id = org.id; assert n = 1, 'only owner remains';

  -- Audit trail covers it all and never contains email addresses.
  perform public.t_admin();
  select count(*) into n from public.audit_events where organisation_id = org.id and event_type in
    ('invitation.created', 'invitation.accepted', 'invitation.revoked', 'member.role_changed', 'member.removed', 'member.left');
  assert n >= 12, 'membership events audited, found ' || n;
  select count(*) into n from public.audit_events where metadata::text like '%@%'; assert n = 0, 'no emails in audit metadata';
end $$;
select 'rls_members_invitations: passed' as result;
