-- Drop two unused, surprising authorization helpers.
--
--   is_company_admin()     reads the flag on effective_user_id() and is FALSE for a
--                          platform admin, while is_tenant_admin() is TRUE for one.
--   is_any_module_admin()  passes for a platform-admin bypass or role='admin' in ANY
--                          module (the old department-write gate, replaced by
--                          is_tenant_admin() in 20261001120000).
--
-- Why drop rather than keep
--   AUTHORIZATION_ARCHITECTURE.md section 3.2 found that no policy, function, view or
--   edge function calls either. They are still EXECUTE-able by `authenticated`, and
--   their semantics are the two most likely to be picked up by mistake in a new
--   policy ("any module admin" quietly meaning "any module admin in the tenant").
--   Company configuration uses is_tenant_admin(); module permission uses
--   has_module_role(). Nothing is lost.
--
-- Not affected
--   The app_users.is_company_admin COLUMN stays: it is what is_tenant_admin() reads and
--   what invite-user / accept-invite / set_member_access write.
--
-- Safety
--   Plain DROP FUNCTION, deliberately without CASCADE: if any policy, view or other
--   object still depended on either helper this migration would fail instead of
--   silently taking that object with it. Verified against production on 2026-10-02:
--   no function body, policy, view or pg_depend entry references either helper.

begin;

drop function if exists public.is_company_admin();
drop function if exists public.is_any_module_admin();

commit;
