-- Part A follow-up: TeamMembersAdmin.tsx's save() previously fired one
-- rpc() call per changed module (up to 8) plus one for finance,
-- sequentially, and threw on the first error. If (say) module 5 of 8
-- failed, modules 1-4 were already committed with no rollback, leaving
-- the member in a half-updated state with no visible indication of
-- which half applied.
--
-- set_member_access replaces that loop with a single SECURITY DEFINER
-- function that takes the *desired end state* (the full module set and
-- the finance role) and applies it as one write in one Postgres
-- transaction -- so it's all-or-nothing from the client's perspective.
-- Same auth boundary as the rest of the Team Members Admin RPCs
-- (is_tenant_admin(), tenant-scoped via get_my_tenant_id(), explicit
-- check that p_user_id belongs to the caller's tenant).
--
-- p_modules is a jsonb array of {"module": ..., "role": ...} objects
-- describing every module the member should have after the call --
-- anything not listed is removed, matching how the edit dialog already
-- represents its draft state. p_finance_role is '' or null to clear
-- finance access, otherwise 'finance' | 'cost_control'.

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
declare
  v_tenant uuid;
  v_finance_role text := nullif(p_finance_role, '');
begin
  if not is_tenant_admin() then
    raise exception 'not authorized to manage team access';
  end if;

  v_tenant := get_my_tenant_id();

  if not exists (select 1 from app_users where id = p_user_id and tenant_id = v_tenant) then
    raise exception 'user not found in this tenant';
  end if;

  if v_finance_role is not null and v_finance_role not in ('finance', 'cost_control') then
    raise exception 'invalid finance role: %', v_finance_role;
  end if;

  -- Modules: replace-all. Drop any grant not present in p_modules, then
  -- upsert everything that is. jsonb_array_elements() on an empty/absent
  -- array yields zero rows, so an empty p_modules correctly clears every
  -- module grant (the NOT IN against an empty set is vacuously true).
  delete from staff_roles
  where user_id = p_user_id
    and tenant_id = v_tenant
    and module not in (
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
    delete from finance_team_members where user_id = p_user_id and tenant_id = v_tenant;
  else
    delete from finance_team_members
    where user_id = p_user_id and tenant_id = v_tenant and role != v_finance_role;

    insert into finance_team_members (tenant_id, user_id, role)
    values (v_tenant, p_user_id, v_finance_role)
    on conflict (tenant_id, user_id, role) do nothing;
  end if;

  return query
  select
    u.id,
    u.full_name,
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

ALTER FUNCTION "public"."set_member_access"("uuid", "jsonb", "text") OWNER TO "postgres";
REVOKE ALL ON FUNCTION "public"."set_member_access"("uuid", "jsonb", "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_member_access"("uuid", "jsonb", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_member_access"("uuid", "jsonb", "text") TO "service_role";

COMMENT ON FUNCTION "public"."set_member_access"("uuid", "jsonb", "text") IS
  'Sets a team member''s full module grant set and finance role in a single transaction (all-or-nothing), replacing the previous pattern of one rpc() call per changed module from the client. p_modules is the complete desired module list, not a diff -- anything omitted is removed. Company/platform-admin-only, tenant-boundary checked. Returns the updated member row in the same shape as get_tenant_team_members().';