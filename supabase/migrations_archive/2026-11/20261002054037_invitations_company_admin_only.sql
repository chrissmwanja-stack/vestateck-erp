-- Invitations belong to the company admin, not to "any module admin".
--
-- Problem
--   invitations_select / invitations_insert and revoke_invitation() decide
--   "may this caller manage invitations?" with
--       exists (select 1 from staff_roles where user_id = auth.uid()
--               and tenant_id = ... and role = 'admin')
--   i.e. "admin of ANY module". That is the older admin model. Everywhere
--   else (get_tenant_team_members, set_member_access, departments,
--   organizations, the invite-user edge function, RequireTenantAdmin) the
--   rule is is_tenant_admin() = the company admin.
--
--   Two consequences, both wrong:
--     1. A module admin who is NOT a company admin (e.g. hr@test.local, who
--        holds staff_roles hr/admin) can read every pending invitation in the
--        tenant and INSERT a role_bundle='member' invitation directly through
--        PostgREST, choosing modules_and_roles and finance_role freely. The
--        invite-user edge function's "only company admins can invite" check
--        is bypassed, and accept-invite matches by email only and trusts the
--        row, so whoever signs in with that email receives those grants.
--     2. A company admin with no staff_roles row (company.admin@test.local)
--        sees an empty invitations list on /company-admin/users/invite and
--        gets "Not authorized" from revoke_invitation().
--
-- Fix
--   SELECT / INSERT policies and revoke_invitation() use is_tenant_admin().
--   Platform admins keep their existing is_platform_admin() path unchanged.
--   Edge functions use the service role and are unaffected. No UPDATE or
--   DELETE policy exists and none is added (status changes go through the
--   revoke_invitation / accept-invite paths only).
--
-- Grants are left unchanged (CREATE OR REPLACE keeps them).

begin;

drop policy if exists invitations_select on public.invitations;
create policy invitations_select on public.invitations
  for select
  using (
    public.is_platform_admin()
    or (
      tenant_id = public.get_my_tenant_id()
      and public.is_tenant_admin()
    )
  );

drop policy if exists invitations_insert on public.invitations;
create policy invitations_insert on public.invitations
  for insert
  with check (
    public.is_platform_admin()
    or (
      role_bundle = 'member'
      and tenant_id = public.get_my_tenant_id()
      and public.is_tenant_admin()
    )
  );

create or replace function public.revoke_invitation(p_invitation_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_invitation invitations%rowtype;
  v_caller_is_platform_admin boolean;
  v_caller_tenant_id uuid;
begin
  select * into v_invitation
  from invitations
  where id = p_invitation_id;

  if not found then
    raise exception 'Invitation not found';
  end if;

  v_caller_is_platform_admin := is_platform_admin();
  v_caller_tenant_id := get_my_tenant_id();

  if not (
    v_caller_is_platform_admin
    or (
      v_invitation.role_bundle = 'member'
      and v_invitation.tenant_id = v_caller_tenant_id
      and is_tenant_admin()
    )
  ) then
    raise exception 'Not authorized to revoke this invitation';
  end if;

  if v_invitation.status <> 'pending' then
    raise exception 'Only pending invitations can be revoked (this one is %)', v_invitation.status;
  end if;

  update invitations set status = 'revoked' where id = p_invitation_id;

  -- Only platform-level revokes are platform events; a company admin
  -- revoking their own member invite is tenant business.
  if v_caller_is_platform_admin then
    perform log_platform_event(
      'invitation.revoke', v_invitation.tenant_id, 'invitation', p_invitation_id::text, null,
      jsonb_build_object('email', v_invitation.email, 'role_bundle', v_invitation.role_bundle, 'status', 'pending'),
      jsonb_build_object('status', 'revoked')
    );
  end if;
end;
$function$;

commit;
