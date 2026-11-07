-- Fix: ins_snapshot_bind_config() (20261107235903, redefined in 20261107235905)
-- was created without a revoke, so PUBLIC (and therefore anon) held EXECUTE.
-- It is a trigger function (BEFORE UPDATE on ins_policies): nobody calls it
-- directly, and triggers do not need EXECUTE at fire time. Same treatment as
-- ins_policies_guard. test_ins_authz_catalog.sql caught it.
-- Rule for new ins_ functions: revoke from public, anon (and, for trigger
-- functions, authenticated and service_role) in the same migration.
revoke all on function public.ins_snapshot_bind_config() from public, anon, authenticated, service_role;