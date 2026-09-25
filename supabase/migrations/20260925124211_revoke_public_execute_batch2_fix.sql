-- The prior migration (20260925124135_revoke_anon_execute_batch2.sql) revoked
-- EXECUTE FROM anon specifically, but it turned out to be a no-op: these 5
-- functions were never granted to anon directly. They carry Postgres's
-- default "EXECUTE granted to PUBLIC" ACL entry from creation time instead
-- (proacl showed `=X/postgres` with no `anon=X` entry), and anon inherits
-- PUBLIC's privileges automatically regardless of any anon-specific revoke.
--
-- Revoking from PUBLIC is the actual fix. authenticated and service_role
-- keep their own separate explicit grants (already present in proacl) and
-- are unaffected -- verified via has_function_privilege() after applying.

revoke execute on function public.app_users_platform_admin_guard() from public;
revoke execute on function public.pmo_time_entry_apply_rate() from public;
revoke execute on function public.trg_audit_platform_settings() from public;
revoke execute on function public.trg_post_machine_fuel() from public;
revoke execute on function public.update_workflow_stage_approver_role(uuid, text) from public;