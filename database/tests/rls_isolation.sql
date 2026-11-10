-- Phase 1 guarantees, re-verified against the final schema: tenant isolation, no direct writes, append-only audit.
\set ON_ERROR_STOP on
create or replace function public.t_as(u uuid) returns void language plpgsql as $$
begin perform set_config('role', 'authenticated', true); perform set_config('request.jwt.claim.sub', u::text, true); end $$;
create or replace function public.t_admin() returns void language plpgsql as $$
begin perform set_config('role', 'postgres', true); end $$;
create or replace function public.t_expect(q text, st text) returns void language plpgsql as $$
begin
  execute q;
  raise exception 'TEST: expected SQLSTATE % but statement succeeded: %', st, q;
exception when others then
  if sqlstate = st then return; end if;
  raise exception 'TEST: expected SQLSTATE % got % (%) for: %', st, sqlstate, sqlerrm, q;
end $$;
grant execute on function public.t_as(uuid), public.t_admin(), public.t_expect(text, text) to authenticated;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000000a', 'alice@test.io'), ('00000000-0000-0000-0000-00000000000b', 'bob@test.io');

do $$
declare n int; org_a public.organisations; org_b public.organisations;
begin
  perform public.t_as('00000000-0000-0000-0000-00000000000a');
  org_a := public.create_organisation('Alpha School', 'alpha-school');
  perform public.t_as('00000000-0000-0000-0000-00000000000b');
  org_b := public.create_organisation('Beta Club', 'beta-club');

  select count(*) into n from public.organisations; assert n = 1, 'bob sees exactly one org, saw ' || n;
  select count(*) into n from public.organisation_members; assert n = 1, 'bob sees only his membership';
  select count(*) into n from public.audit_events; assert n = 1, 'bob sees only his audit trail';

  perform public.t_expect($q$insert into public.organisations (name, slug, created_by) values ('Rogue', 'rogue', auth.uid())$q$, '42501');
  perform public.t_expect(format($q$insert into public.organisation_members values (%L, auth.uid(), 'owner')$q$, org_a.id), '42501');
  perform public.t_expect(format($q$update public.organisation_members set role = 'owner' where organisation_id = %L$q$, org_b.id), '42501');
  perform public.t_expect(format($q$delete from public.organisation_members where organisation_id = %L$q$, org_b.id), '42501');
  perform public.t_expect($q$select public.append_audit_event(null, null, 'x')$q$, '42501');

  -- Bob (not a member of Alpha) can't read or change anything of Alpha.
  select count(*) into n from public.audit_events where organisation_id = org_a.id; assert n = 0, 'no cross-tenant audit read';
  update public.organisations set name = 'Hacked' where id = org_a.id; get diagnostics n = row_count; assert n = 0, 'no cross-tenant update';

  -- Audit trail is append-only, even for privileged callers, and chained.
  perform public.t_admin();
  perform public.t_expect('delete from public.audit_events', 'P0001');
  perform public.t_expect($q$update public.audit_events set event_type = 'x'$q$, 'P0001');
  perform public.t_expect('truncate public.audit_events', 'P0001');
  select count(*) into n from public.audit_events where organisation_id = org_a.id and prev_hash is null and hash <> ''; assert n = 1, 'chain genesis';
end $$;
select 'rls_isolation: passed' as result;
