-- Defence in depth: stop granting table privileges to `anon`, and stop granting
-- the privileges RLS cannot police to `authenticated`.
--
-- Background. The squashed baseline's default privileges give `anon` and
-- `authenticated` full DML on every table in `public` (README, "Status"). RLS is
-- therefore the only barrier. It holds today, for two accidental reasons that
-- nobody should have to rely on:
--   * reads by `anon` fail only because `anon` cannot EXECUTE the policy helper
--     get_my_tenant_id() (permission denied, rather than an empty result);
--   * writes by `anon` fail only because each policy's tenant test is false.
-- One policy written without a tenant test, or one helper granted to `anon`,
-- would silently expose a table to unauthenticated callers.
--
-- Nothing legitimate uses `anon` table access: the public pages only call auth
-- endpoints and the RPCs get_platform_branding / health_check / keepalive_ping,
-- all of which are functions, not table grants.
--
-- `authenticated` additionally holds TRUNCATE, REFERENCES and TRIGGER. TRUNCATE
-- is never subject to RLS. PostgREST cannot issue it, so this is not an open
-- hole, but no client path needs it. SELECT/INSERT/UPDATE/DELETE stay, and RLS
-- remains the barrier for them. (MAINTAIN, new in PostgreSQL 17, is left alone
-- so this file also replays on older servers.)
--
-- Idempotent. Only REVOKEs: no table, column or data is touched.

revoke all on all tables    in schema public from anon;
revoke all on all sequences in schema public from anon;

revoke truncate, references, trigger on all tables in schema public from authenticated;

-- Objects created by later migrations (run as postgres).
alter default privileges for role postgres in schema public revoke all on tables    from anon;
alter default privileges for role postgres in schema public revoke all on sequences from anon;
alter default privileges for role postgres in schema public revoke truncate, references, trigger on tables from authenticated;
