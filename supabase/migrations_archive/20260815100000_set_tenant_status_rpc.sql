-- Tenant status management for the Companies Console.
--
-- 'pending' -> 'active' already happens automatically the moment a
-- tenant's first admin accepts their invite (accept-invite/index.ts).
-- There was no path to 'suspended' at all, and no way to manually
-- flip a tenant back to 'active' if that auto-transition were ever
-- missed -- the tenants table has SELECT-only RLS policies, so a
-- platform admin couldn't even update the column directly from the
-- client. This adds the one write path, restricted to the two states
-- a platform admin should actually be choosing between: 'pending' is
-- a bootstrap-only state set by create-tenant/accept-invite, not
-- something to hand-set once a company already has departments and
-- an admin.
create or replace function public.set_tenant_status(p_tenant_id uuid, p_status text)
returns public.tenants
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_row public.tenants;
begin
  if not is_platform_admin() then
    raise exception 'Only platform admins can change a company''s status';
  end if;

  if p_status not in ('active', 'suspended') then
    raise exception 'status must be active or suspended (pending is set automatically)';
  end if;

  update tenants
  set status = p_status
  where id = p_tenant_id
  returning * into v_row;

  if v_row.id is null then
    raise exception 'tenant not found';
  end if;

  return v_row;
end;
$function$;