-- Phase 2a: invitations and role management.
-- All membership writes now go through audited SECURITY DEFINER functions; API roles can no longer write members directly.

-- Application errors use custom SQLSTATEs so the API can map them to HTTP codes and show our own (safe) messages.
--   NV403 forbidden · NV404 not found · NV409 conflict · NV422 invalid input
create or replace function public.fail(p_code text, p_msg text) returns void language plpgsql as $$
begin raise exception '%', p_msg using errcode = p_code; end $$;
revoke all on function public.fail(text, text) from public, anon, authenticated;

-- Profiles exist for every user (needed to embed member names/emails); backfill, then link memberships to profiles.
insert into public.profiles (id, email) select id, email from auth.users on conflict (id) do nothing;
alter table public.organisation_members
  add constraint organisation_members_profile_fk foreign key (user_id) references public.profiles (id) on delete cascade;

-- Membership writes only via functions below.
drop policy members_insert on public.organisation_members;
drop policy members_update on public.organisation_members;
drop policy members_delete on public.organisation_members;
revoke insert, update, delete on public.organisation_members from authenticated;

create type public.invitation_status as enum ('pending', 'accepted', 'declined', 'revoked', 'expired');

create table public.organisation_invitations (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  email text not null check (email = lower(email) and char_length(email) between 5 and 254 and email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  role public.org_role not null check (role <> 'owner'),
  status public.invitation_status not null default 'pending',
  invited_by uuid not null references auth.users (id),
  expires_at timestamptz not null default now() + interval '14 days',
  responded_at timestamptz,
  created_at timestamptz not null default now()
);
create unique index organisation_invitations_one_pending on public.organisation_invitations (organisation_id, email) where status = 'pending';
create index organisation_invitations_email_idx on public.organisation_invitations (email) where status = 'pending';

alter table public.organisation_invitations enable row level security;
revoke all on public.organisation_invitations from anon, authenticated;
grant select on public.organisation_invitations to authenticated;
create policy invitations_select on public.organisation_invitations for select to authenticated
  using (public.has_permission(organisation_id, 'members.manage'));

-- The caller's verified email (null if unconfirmed). Invitations are matched on this, never on client input.
create or replace function public.current_email() returns text language sql stable security definer set search_path = public as $$
  select lower(u.email) from auth.users u where u.id = auth.uid() and u.email_confirmed_at is not null $$;

-- Caller's role and permission keys in a workspace (no row if not an active member).
create or replace function public.my_membership(p_org uuid) returns table (role public.org_role, permissions text[])
language sql stable security definer set search_path = public as $$
  select m.role, coalesce(array_agg(rp.permission order by rp.permission) filter (where rp.permission is not null), '{}')
  from public.organisation_members m left join public.role_permissions rp on rp.role = m.role
  where m.organisation_id = p_org and m.user_id = auth.uid() and m.status = 'active' group by m.role $$;
revoke all on function public.my_membership(uuid) from public, anon;
grant execute on function public.my_membership(uuid) to authenticated;

-- Shared rule: may the caller (actor) manage a member whose role is `target_role`, setting `new_role`?
-- Owners: anything. Admins: only election managers and voters. Everyone else: nothing.
create or replace function public.can_manage_role(org uuid, target_role public.org_role, new_role public.org_role) returns boolean
language sql stable security definer set search_path = public as $$
  select case
    when public.has_org_role(org, array['owner']::public.org_role[]) then true
    when public.has_org_role(org, array['admin']::public.org_role[])
      then target_role in ('election_manager', 'voter') and new_role in ('election_manager', 'voter')
    else false end $$;
revoke all on function public.can_manage_role(uuid, public.org_role, public.org_role) from public, anon, authenticated;

create or replace function public.create_invitation(p_org uuid, p_email text, p_role public.org_role)
returns public.organisation_invitations language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_email text := lower(btrim(p_email)); v_inv public.organisation_invitations;
begin
  if v_uid is null then perform public.fail('28000', 'Not authenticated'); end if;
  if not public.has_permission(p_org, 'members.manage') then perform public.fail('NV403', 'You can''t invite members to this workspace'); end if;
  if p_role = 'owner' then perform public.fail('NV422', 'Invite the person with another role, then promote them to owner'); end if;
  if not public.can_manage_role(p_org, p_role, p_role) then perform public.fail('NV403', 'You can''t invite people with that role'); end if;
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' or char_length(v_email) > 254 then
    perform public.fail('NV422', 'Enter a valid email address'); end if;
  if exists (select 1 from public.organisation_members m join public.profiles p on p.id = m.user_id
             where m.organisation_id = p_org and lower(p.email) = v_email) then
    perform public.fail('NV409', 'That person is already a member'); end if;

  update public.organisation_invitations set status = 'expired', responded_at = now()
   where organisation_id = p_org and email = v_email and status = 'pending' and expires_at <= now();
  begin
    insert into public.organisation_invitations (organisation_id, email, role, invited_by)
    values (p_org, v_email, p_role, v_uid) returning * into v_inv;
  exception when unique_violation then
    perform public.fail('NV409', 'An invitation is already pending for that email');
  end;
  -- Audit metadata deliberately omits the email address.
  perform public.append_audit_event(p_org, v_uid, 'invitation.created', 'invitation', v_inv.id::text, jsonb_build_object('role', p_role));
  return v_inv;
end $$;

create or replace function public.revoke_invitation(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_inv public.organisation_invitations;
begin
  select * into v_inv from public.organisation_invitations where id = p_id for update;
  if not found or not public.has_permission(v_inv.organisation_id, 'members.manage') then perform public.fail('NV404', 'Invitation not found'); end if;
  if v_inv.status <> 'pending' then perform public.fail('NV409', 'That invitation is no longer pending'); end if;
  if not public.can_manage_role(v_inv.organisation_id, v_inv.role, v_inv.role) then perform public.fail('NV403', 'You can''t revoke this invitation'); end if;
  update public.organisation_invitations set status = 'revoked', responded_at = now() where id = p_id;
  perform public.append_audit_event(v_inv.organisation_id, auth.uid(), 'invitation.revoked', 'invitation', p_id::text, '{}');
end $$;

create or replace function public.my_invitations()
returns table (id uuid, organisation_id uuid, organisation_name text, role public.org_role, expires_at timestamptz, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select i.id, i.organisation_id, o.name, i.role, i.expires_at, i.created_at
  from public.organisation_invitations i join public.organisations o on o.id = i.organisation_id
  where i.status = 'pending' and i.expires_at > now() and i.email = public.current_email() order by i.created_at desc $$;

create or replace function public.respond_to_invitation(p_id uuid, p_accept boolean) returns void
language plpgsql security definer set search_path = public as $$
declare v_inv public.organisation_invitations; v_uid uuid := auth.uid();
begin
  if v_uid is null then perform public.fail('28000', 'Not authenticated'); end if;
  select * into v_inv from public.organisation_invitations where id = p_id for update;
  -- Same message for "doesn't exist" and "not yours": never reveal other people's invitations.
  if not found or v_inv.status <> 'pending' or v_inv.expires_at <= now() or v_inv.email is distinct from public.current_email() then
    perform public.fail('NV404', 'Invitation not found or no longer valid'); end if;
  if p_accept then
    if exists (select 1 from public.organisation_members where organisation_id = v_inv.organisation_id and user_id = v_uid) then
      perform public.fail('NV409', 'You''re already a member of this workspace'); end if;
    insert into public.organisation_members (organisation_id, user_id, role) values (v_inv.organisation_id, v_uid, v_inv.role);
  end if;
  update public.organisation_invitations set status = case when p_accept then 'accepted' else 'declined' end::public.invitation_status,
         responded_at = now() where id = p_id;
  perform public.append_audit_event(v_inv.organisation_id, v_uid, case when p_accept then 'invitation.accepted' else 'invitation.declined' end,
                                    'invitation', p_id::text, jsonb_build_object('role', v_inv.role));
end $$;

create or replace function public.change_member_role(p_org uuid, p_user uuid, p_role public.org_role) returns void
language plpgsql security definer set search_path = public as $$
declare v_target public.organisation_members; v_owners int;
begin
  if auth.uid() is null then perform public.fail('28000', 'Not authenticated'); end if;
  if not public.has_permission(p_org, 'members.manage') then perform public.fail('NV403', 'You can''t manage members of this workspace'); end if;
  perform 1 from public.organisation_members where organisation_id = p_org and role = 'owner' for update;  -- serialise owner changes
  select * into v_target from public.organisation_members where organisation_id = p_org and user_id = p_user;
  if not found then perform public.fail('NV404', 'Member not found'); end if;
  if not public.can_manage_role(p_org, v_target.role, p_role) then perform public.fail('NV403', 'You can''t change this member''s role'); end if;
  if v_target.role = p_role then return; end if;
  if v_target.role = 'owner' then
    select count(*) into v_owners from public.organisation_members where organisation_id = p_org and role = 'owner' and status = 'active';
    if v_owners <= 1 then perform public.fail('NV409', 'A workspace needs at least one owner'); end if;
  end if;
  update public.organisation_members set role = p_role where organisation_id = p_org and user_id = p_user;
  perform public.append_audit_event(p_org, auth.uid(), 'member.role_changed', 'member', p_user::text,
                                    jsonb_build_object('from', v_target.role, 'to', p_role));
end $$;

-- Removes a member, or lets a member leave (p_user = caller). The last owner can never leave or be removed.
create or replace function public.remove_member(p_org uuid, p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_target public.organisation_members; v_owners int; v_self boolean := (p_user = auth.uid());
begin
  if auth.uid() is null then perform public.fail('28000', 'Not authenticated'); end if;
  perform 1 from public.organisation_members where organisation_id = p_org and role = 'owner' for update;
  select * into v_target from public.organisation_members where organisation_id = p_org and user_id = p_user;
  if not found then perform public.fail('NV404', 'Member not found'); end if;
  if not v_self then
    if not public.has_permission(p_org, 'members.manage') then perform public.fail('NV403', 'You can''t manage members of this workspace'); end if;
    if not public.can_manage_role(p_org, v_target.role, v_target.role) then perform public.fail('NV403', 'You can''t remove this member'); end if;
  end if;
  if v_target.role = 'owner' then
    select count(*) into v_owners from public.organisation_members where organisation_id = p_org and role = 'owner' and status = 'active';
    if v_owners <= 1 then perform public.fail('NV409', 'A workspace needs at least one owner'); end if;
  end if;
  delete from public.organisation_members where organisation_id = p_org and user_id = p_user;
  perform public.append_audit_event(p_org, auth.uid(), case when v_self then 'member.left' else 'member.removed' end, 'member', p_user::text,
                                    jsonb_build_object('role', v_target.role));
end $$;

do $$ declare f text; begin
  foreach f in array array['create_invitation(uuid, text, public.org_role)', 'revoke_invitation(uuid)', 'my_invitations()',
    'respond_to_invitation(uuid, boolean)', 'change_member_role(uuid, uuid, public.org_role)', 'remove_member(uuid, uuid)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop; end $$;
