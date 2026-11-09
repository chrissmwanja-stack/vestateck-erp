-- set_member_access() has raised
--     ERROR 42702: column reference "user_id" is ambiguous
--     DETAIL: It could refer to either a PL/pgSQL variable or a table column.
-- on every call since 20260821143000, so the Team Members "Save changes"
-- action never worked.
--
-- Cause: the function is declared RETURNS TABLE (user_id, name, email,
-- role_title, is_company_admin, modules, finance_role). In PL/pgSQL those
-- column names are OUT variables in scope for the whole body, and the body
-- uses unqualified `user_id` in
--     delete from staff_roles where user_id = ...
--     delete from finance_team_members where user_id = ...
--     on conflict (tenant_id, user_id, module)
--     on conflict (tenant_id, user_id, role)
-- all of which collide with the OUT variable.
--
-- Nothing caught it: no SQL test called the function, the component test
-- mocks the RPC, and company-admin-members-invitations.spec.ts was the first
-- test to run it against a real database.
--
-- Fix: same signature, same behaviour, same grants. `#variable_conflict
-- use_column` makes every ambiguous name resolve to the table column (it
-- also covers the ON CONFLICT targets, which cannot be alias-qualified), and
-- the deletes/selects are alias-qualified as well so the intent is explicit.
-- CREATE OR REPLACE keeps the existing owner and grants.

CREATE OR REPLACE FUNCTION "public"."set_member_access"(
    "p_user_id" "uuid",
    "p_modules" "jsonb",
    "p_finance_role" "text"
) RETURNS TABLE(
    "user_id" "uuid",
    "name" "text",
    "email" "text",
    "role_title" "text",
    "is_company_admin" boolean,
    "modules" "jsonb",
    "finance_role" "text"
)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
#variable_conflict use_column
declare
  v_tenant uuid;
  v_finance_role text := nullif(p_finance_role, '');
begin
  if not is_tenant_admin() then
    raise exception 'not authorized to manage team access';
  end if;

  v_tenant := get_my_tenant_id();

  if not exists (select 1 from app_users au where au.id = p_user_id and au.tenant_id = v_tenant) then
    raise exception 'user not found in this tenant';
  end if;

  if v_finance_role is not null and v_finance_role not in ('finance', 'cost_control') then
    raise exception 'invalid finance role: %', v_finance_role;
  end if;

  -- Modules: replace-all. Drop any grant not present in p_modules, then
  -- upsert everything that is. jsonb_array_elements() on an empty/absent
  -- array yields zero rows, so an empty p_modules correctly clears every
  -- module grant (the NOT IN against an empty set is vacuously true).
  delete from staff_roles sr
  where sr.user_id = p_user_id
    and sr.tenant_id = v_tenant
    and sr.module not in (
      select value ->> 'module' from jsonb_array_elements(coalesce(p_modules, '[]'::jsonb))
    );

  insert into staff_roles (tenant_id, user_id, module, role)
  select v_tenant, p_user_id, elem ->> 'module', elem ->> 'role'
  from jsonb_array_elements(coalesce(p_modules, '[]'::jsonb)) as elem
  on conflict (tenant_id, user_id, module) do update set role = excluded.role;

  -- Finance role: same "clear other role rows, then upsert" pattern as
  -- set_finance_role, since finance_team_members is keyed per-role, not
  -- per-user -- a naive upsert alone can't clear a stale different role.
  if v_finance_role is null then
    delete from finance_team_members ftm where ftm.user_id = p_user_id and ftm.tenant_id = v_tenant;
  else
    delete from finance_team_members ftm
    where ftm.user_id = p_user_id and ftm.tenant_id = v_tenant and ftm.role != v_finance_role;

    insert into finance_team_members (tenant_id, user_id, role)
    values (v_tenant, p_user_id, v_finance_role)
    on conflict (tenant_id, user_id, role) do nothing;
  end if;

  return query
  select
    u.id,
    u.name,
    u.email,
    u.role_title,
    u.is_company_admin,
    coalesce(
      (select jsonb_agg(jsonb_build_object('module', sr.module, 'role', sr.role))
       from staff_roles sr
       where sr.user_id = u.id and sr.tenant_id = u.tenant_id),
      '[]'::jsonb
    ) as modules,
    (select ftm.role from finance_team_members ftm
     where ftm.user_id = u.id and ftm.tenant_id = u.tenant_id
     order by case ftm.role when 'finance' then 0 else 1 end
     limit 1) as finance_role
  from app_users u
  where u.id = p_user_id and u.tenant_id = v_tenant;
end;
$$;
