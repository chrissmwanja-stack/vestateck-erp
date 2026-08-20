-- Supabase's security advisor flags platform_has_admin() as
-- anon-executable (WARN level). That's intentional, not a gap:
-- BootstrapAdminPage.tsx calls it before any user is authenticated,
-- to decide whether to show the one-time "claim first platform admin"
-- form or redirect. The function only returns a boolean (whether any
-- platform admin exists anywhere) -- no tenant, user, or other
-- sensitive data is exposed. The actual admin claim is re-verified
-- server-side in the bootstrap-admin edge function at submit time,
-- so this anon-callable check can't be raced or spoofed into
-- granting anything by itself.
COMMENT ON FUNCTION "public"."platform_has_admin"() IS
  'Returns true once any platform admin exists. Used to gate the /bootstrap-admin claim flow -- intentionally anon-executable since it runs pre-auth on a fresh install; only exposes a boolean, and the actual claim is re-checked server-side in bootstrap-admin at submit time.';