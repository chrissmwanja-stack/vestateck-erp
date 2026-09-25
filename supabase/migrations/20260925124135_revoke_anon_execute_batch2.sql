-- Follow-up to 20260916090000_revoke_anon_execute_on_security_definer_rpcs.sql.
-- That migration covered 21 functions found in the Sep-14 deep-dive report.
-- This one addresses 5 more, found in the Sep-25 audit-notes report, that
-- still showed anon EXECUTE:
--
--   app_users_platform_admin_guard  (trigger function -- not RPC-callable
--                                     regardless, but the grant was dead
--                                     weight and confusing on inspection)
--   pmo_time_entry_apply_rate       (trigger function, same reasoning)
--   trg_audit_platform_settings     (trigger function, same reasoning)
--   trg_post_machine_fuel           (trigger function, same reasoning)
--   update_workflow_stage_approver_role
--       (real RPC; internally guarded by require_platform_admin(), so this
--        was not exploitable, but the grant should not have been anon in
--        the first place -- defense in depth)
--
-- Deliberately NOT touched here (confirmed via code inspection, both are
-- intentionally public and documented as such at the call site):
--   get_platform_branding  -- apps/web/src/lib/brandingContext.tsx: renders
--                              on the login page before any session exists
--   health_check           -- supabase/migrations/20260917082023_health_check_rpc.sql:
--                              anon grant is deliberate, for uptime monitoring
--
-- NOTE: this statement alone turned out to be a no-op -- see the next
-- migration, 20260925124211_revoke_public_execute_batch2_fix.sql, which
-- explains why and does the actual work. Kept as its own migration file so
-- the production migration ledger matches what apply_migration actually
-- recorded (it timestamps by apply time, not by filename).

revoke execute on function public.app_users_platform_admin_guard() from anon;
revoke execute on function public.pmo_time_entry_apply_rate() from anon;
revoke execute on function public.trg_audit_platform_settings() from anon;
revoke execute on function public.trg_post_machine_fuel() from anon;
revoke execute on function public.update_workflow_stage_approver_role(uuid, text) from anon;