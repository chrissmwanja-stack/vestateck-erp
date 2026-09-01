-- is_company_admin(): the anon-role revoke from 20260824100128 didn't close the gap
-- because Postgres also grants EXECUTE to PUBLIC by default on CREATE FUNCTION,
-- and anon inherits through PUBLIC. Revoke from PUBLIC explicitly.
REVOKE EXECUTE ON FUNCTION public.is_company_admin() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_company_admin() TO authenticated;

-- platform_has_admin(): anon has always had an explicit EXECUTE grant. Revoke it.
REVOKE EXECUTE ON FUNCTION public.platform_has_admin() FROM anon;
REVOKE EXECUTE ON FUNCTION public.platform_has_admin() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.platform_has_admin() TO authenticated;