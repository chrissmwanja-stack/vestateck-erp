-- Phase 1, step 2 (decision D6 in PHASE0_COUPLING_AUDIT.md).
--
-- accept-invite used to give every company admin an 'admin' staff_roles row on
-- ALL hard-coded modules, entitled or not. It now grants roles only on the
-- modules the tenant is entitled to (tenant_modules). To keep "entitle a module
-- later and the company admin can use it immediately" working, set_tenant_modules()
-- now also gives the tenant's company admins an 'admin' role on each module that
-- is NEWLY entitled by the call.
--
-- Only newly entitled modules are granted (a re-save of an unchanged set does not
-- re-add a role someone removed). Un-entitling leaves staff_roles rows in place;
-- they are inert because has_module_role() needs both. Otherwise identical to the
-- 20260922160000 definition (same signature, audit event, return value).

create or replace function public.set_tenant_modules(p_tenant_id uuid, p_modules text[])
returns setof text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_before text[];
  v_after  text[];
  v_new    text[];
begin
  perform require_platform_admin('Changing a company''s modules');

  if not exists (select 1 from tenants where id = p_tenant_id) then
    raise exception 'tenant not found';
  end if;

  select coalesce(array_agg(module order by module), '{}')
    into v_before
  from tenant_modules where tenant_id = p_tenant_id;

  delete from tenant_modules
  where tenant_id = p_tenant_id
    and module != all(coalesce(p_modules, array[]::text[]));

  with ins as (
    insert into tenant_modules (tenant_id, module, enabled_by)
    select p_tenant_id, m, auth.uid()
    from unnest(coalesce(p_modules, array[]::text[])) as m
    on conflict (tenant_id, module) do nothing
    returning module
  )
  select coalesce(array_agg(module order by module), '{}') into v_new from ins;

  -- Company admins get admin on modules newly entitled to their company.
  if coalesce(array_length(v_new, 1), 0) > 0 then
    insert into staff_roles (tenant_id, user_id, module, role)
    select p_tenant_id, u.id, m, 'admin'
    from app_users u
    cross join unnest(v_new) as m
    where u.tenant_id = p_tenant_id and u.is_company_admin
    on conflict (tenant_id, user_id, module) do nothing;
  end if;

  select coalesce(array_agg(module order by module), '{}')
    into v_after
  from tenant_modules where tenant_id = p_tenant_id;

  if v_before is distinct from v_after then
    perform log_platform_event(
      'tenant.modules.set', p_tenant_id, 'tenant', p_tenant_id::text, null,
      jsonb_build_object('modules', to_jsonb(v_before)),
      jsonb_build_object('modules', to_jsonb(v_after))
    );
  end if;

  return query select module from tenant_modules where tenant_id = p_tenant_id order by module;
end;
$$;