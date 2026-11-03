-- NovixVote foundation: identity, workspaces (organisations), memberships, roles, permissions, audit trail.
-- Tenant isolation is enforced by Row Level Security; helper functions are SECURITY DEFINER to avoid policy recursion.

create type public.org_role as enum ('owner', 'admin', 'election_manager', 'voter');
create type public.member_status as enum ('active', 'suspended');

create or replace function public.set_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;

-- ---------- profiles ----------
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  email text,
  display_name text check (display_name is null or char_length(display_name) between 1 and 80),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger profiles_updated before update on public.profiles for each row execute function public.set_updated_at();

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, display_name)
  values (new.id, new.email, nullif(left(new.raw_user_meta_data ->> 'display_name', 80), ''));
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

-- ---------- organisations ----------
create table public.organisations (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 2 and 80),
  slug text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' and char_length(slug) between 3 and 48),
  created_by uuid not null references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger organisations_updated before update on public.organisations for each row execute function public.set_updated_at();

create table public.organisation_members (
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  role public.org_role not null,
  status public.member_status not null default 'active',
  created_at timestamptz not null default now(),
  primary key (organisation_id, user_id)
);
create index organisation_members_user_idx on public.organisation_members (user_id);

-- ---------- permissions ----------
create table public.permissions (key text primary key, description text not null);
create table public.role_permissions (
  role public.org_role not null,
  permission text not null references public.permissions (key),
  primary key (role, permission)
);

insert into public.permissions (key, description) values
  ('org.read', 'View the workspace'), ('org.update', 'Edit workspace settings'),
  ('members.read', 'View members'), ('members.manage', 'Invite, change and remove members'),
  ('election.read', 'View elections'), ('election.create', 'Create elections'), ('election.manage', 'Edit and run elections'),
  ('ballot.manage', 'Edit ballots and candidates'), ('results.view', 'View results'),
  ('results.approve', 'Approve results for publication'), ('audit.read', 'Read the audit trail'),
  ('vote.cast', 'Cast a ballot when eligible');

insert into public.role_permissions (role, permission)
select r.role::public.org_role, p from (values
  ('owner', 'org.read'), ('owner', 'org.update'), ('owner', 'members.read'), ('owner', 'members.manage'),
  ('owner', 'election.read'), ('owner', 'election.create'), ('owner', 'election.manage'), ('owner', 'ballot.manage'),
  ('owner', 'results.view'), ('owner', 'results.approve'), ('owner', 'audit.read'),
  ('admin', 'org.read'), ('admin', 'org.update'), ('admin', 'members.read'), ('admin', 'members.manage'),
  ('admin', 'election.read'), ('admin', 'election.create'), ('admin', 'election.manage'), ('admin', 'ballot.manage'),
  ('admin', 'results.view'), ('admin', 'audit.read'),
  ('election_manager', 'org.read'), ('election_manager', 'members.read'), ('election_manager', 'election.read'),
  ('election_manager', 'election.create'), ('election_manager', 'election.manage'), ('election_manager', 'ballot.manage'),
  ('election_manager', 'results.view'),
  ('voter', 'org.read'), ('voter', 'election.read'), ('voter', 'vote.cast')
) as r(role, p);

-- ---------- helper functions (bypass RLS deliberately; they only answer yes/no for auth.uid()) ----------
create or replace function public.is_org_member(org uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.organisation_members m
                 where m.organisation_id = org and m.user_id = auth.uid() and m.status = 'active') $$;

create or replace function public.has_org_role(org uuid, roles public.org_role[]) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.organisation_members m
                 where m.organisation_id = org and m.user_id = auth.uid() and m.status = 'active' and m.role = any (roles)) $$;

create or replace function public.has_permission(org uuid, perm text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.organisation_members m
                 join public.role_permissions rp on rp.role = m.role
                 where m.organisation_id = org and m.user_id = auth.uid() and m.status = 'active' and rp.permission = perm) $$;

create or replace function public.shares_org_with(other uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.organisation_members a join public.organisation_members b
                 on a.organisation_id = b.organisation_id
                 where a.user_id = auth.uid() and a.status = 'active' and b.user_id = other and b.status = 'active') $$;

-- ---------- tamper-evident audit trail (per-organisation hash chain) ----------
create table public.audit_events (
  id bigint generated always as identity primary key,
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  actor_id uuid references auth.users (id) on delete set null,
  event_type text not null,
  entity_type text,
  entity_id text,
  metadata jsonb not null default '{}'::jsonb,  -- never store passwords, tokens or ballot selections here
  prev_hash text,
  hash text not null,
  created_at timestamptz not null default clock_timestamp()
);
create index audit_events_org_idx on public.audit_events (organisation_id, id);

create or replace function public.audit_events_immutable() returns trigger language plpgsql as $$
begin raise exception 'audit_events is append-only'; end $$;
create trigger audit_no_update_delete before update or delete on public.audit_events
  for each row execute function public.audit_events_immutable();
create trigger audit_no_truncate before truncate on public.audit_events
  for each statement execute function public.audit_events_immutable();

-- Internal only: not executable by API roles.
create or replace function public.append_audit_event(
  p_org uuid, p_actor uuid, p_type text, p_entity_type text default null, p_entity_id text default null,
  p_metadata jsonb default '{}'::jsonb) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_prev text; v_now timestamptz := clock_timestamp(); v_hash text; v_id bigint;
begin
  perform pg_advisory_xact_lock(hashtext(p_org::text));  -- serialise the chain per organisation
  select hash into v_prev from public.audit_events where organisation_id = p_org order by id desc limit 1;
  v_hash := encode(sha256(convert_to(
    coalesce(v_prev, '') || '|' || p_org || '|' || coalesce(p_actor::text, '') || '|' || p_type || '|' ||
    coalesce(p_entity_type, '') || '|' || coalesce(p_entity_id, '') || '|' || p_metadata::text || '|' ||
    v_now::text, 'UTF8')), 'hex');
  insert into public.audit_events (organisation_id, actor_id, event_type, entity_type, entity_id, metadata, prev_hash, hash, created_at)
  values (p_org, p_actor, p_type, p_entity_type, p_entity_id, p_metadata, v_prev, v_hash, v_now) returning id into v_id;
  return v_id;
end $$;
revoke all on function public.append_audit_event(uuid, uuid, text, text, text, jsonb) from public, anon, authenticated;

-- ---------- atomic workspace creation (the only way to create an organisation) ----------
create or replace function public.create_organisation(p_name text, p_slug text) returns public.organisations
language plpgsql security definer set search_path = public as $$
declare v_org public.organisations; v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Not authenticated' using errcode = '28000'; end if;
  insert into public.organisations (name, slug, created_by) values (btrim(p_name), p_slug, v_uid) returning * into v_org;
  insert into public.organisation_members (organisation_id, user_id, role) values (v_org.id, v_uid, 'owner');
  perform public.append_audit_event(v_org.id, v_uid, 'organisation.created', 'organisation', v_org.id::text,
                                    jsonb_build_object('slug', v_org.slug));
  return v_org;
end $$;
revoke all on function public.create_organisation(text, text) from public, anon;
grant execute on function public.create_organisation(text, text) to authenticated;

-- ---------- Row Level Security ----------
alter table public.profiles enable row level security;
alter table public.organisations enable row level security;
alter table public.organisation_members enable row level security;
alter table public.permissions enable row level security;
alter table public.role_permissions enable row level security;
alter table public.audit_events enable row level security;

-- Least privilege at the grant level too.
revoke all on all tables in schema public from anon, authenticated;
grant select on public.profiles, public.organisations, public.organisation_members,
                public.permissions, public.role_permissions, public.audit_events to authenticated;
grant update (display_name) on public.profiles to authenticated;
grant update (name) on public.organisations to authenticated;
grant insert (organisation_id, user_id, role), update (role, status), delete on public.organisation_members to authenticated;

create policy profiles_select on public.profiles for select to authenticated
  using (id = auth.uid() or public.shares_org_with(id));
create policy profiles_update_own on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

create policy organisations_select on public.organisations for select to authenticated
  using (public.is_org_member(id));
create policy organisations_update on public.organisations for update to authenticated
  using (public.has_permission(id, 'org.update')) with check (public.has_permission(id, 'org.update'));

create policy members_select on public.organisation_members for select to authenticated
  using (user_id = auth.uid() or public.has_permission(organisation_id, 'members.read'));
-- Owners manage anyone; admins manage non-owner/non-admin roles only (no privilege escalation).
create policy members_insert on public.organisation_members for insert to authenticated
  with check (public.has_org_role(organisation_id, array['owner']::public.org_role[])
              or (public.has_org_role(organisation_id, array['admin']::public.org_role[]) and role in ('election_manager', 'voter')));
create policy members_update on public.organisation_members for update to authenticated
  using (public.has_org_role(organisation_id, array['owner']::public.org_role[])
         or (public.has_org_role(organisation_id, array['admin']::public.org_role[]) and role in ('election_manager', 'voter')))
  with check (public.has_org_role(organisation_id, array['owner']::public.org_role[])
              or (public.has_org_role(organisation_id, array['admin']::public.org_role[]) and role in ('election_manager', 'voter')));
create policy members_delete on public.organisation_members for delete to authenticated
  using ((public.has_org_role(organisation_id, array['owner']::public.org_role[])
          or (public.has_org_role(organisation_id, array['admin']::public.org_role[]) and role in ('election_manager', 'voter')))
         and not (role = 'owner' and user_id = auth.uid()));  -- an owner cannot orphan the workspace by self-removal

create policy permissions_select on public.permissions for select to authenticated using (true);
create policy role_permissions_select on public.role_permissions for select to authenticated using (true);
create policy audit_select on public.audit_events for select to authenticated
  using (public.has_permission(organisation_id, 'audit.read'));
