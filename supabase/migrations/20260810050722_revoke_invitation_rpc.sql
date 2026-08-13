-- Revoke invitation RPC
--
-- Matches the codebase's established pattern (writes go through
-- SECURITY DEFINER RPCs, not direct client UPDATEs) rather than adding
-- another edge function -- this is a pure DB state change with no need
-- for the Auth Admin API, unlike invite-user/accept-invite/create-tenant.
--
-- Authorization mirrors invite-user:
--   - platform admins can revoke any invitation
--   - tenant module admins can revoke 'member' invitations in their own
--     tenant only (never 'company_admin' invitations -- same asymmetry
--     invite-user enforces on creation)
--
-- Only 'pending' invitations can be revoked. Accepted invitations are
-- done; already-revoked ones are a no-op turned into an error so the
-- caller isn't misled into thinking something happened.

create or replace function revoke_invitation(p_invitation_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
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

  select is_platform_admin, tenant_id
  into v_caller_is_platform_admin, v_caller_tenant_id
  from app_users
  where id = auth.uid();

  if not (
    v_caller_is_platform_admin
    or (
      v_invitation.role_bundle = 'member'
      and v_invitation.tenant_id = v_caller_tenant_id
      and exists (
        select 1 from staff_roles
        where user_id = auth.uid()
          and tenant_id = v_invitation.tenant_id
          and role = 'admin'
      )
    )
  ) then
    raise exception 'Not authorized to revoke this invitation';
  end if;

  if v_invitation.status <> 'pending' then
    raise exception 'Only pending invitations can be revoked (this one is %)', v_invitation.status;
  end if;

  update invitations set status = 'revoked' where id = p_invitation_id;
end;
$$;

-- Functions default to PUBLIC EXECUTE on creation -- this project's
-- earlier security hardening pass specifically had to clean up 144
-- functions with stray anon EXECUTE grants. Lock this one down from
-- the start.
revoke execute on function revoke_invitation(uuid) from public;
revoke execute on function revoke_invitation(uuid) from anon;
grant execute on function revoke_invitation(uuid) to authenticated;