-- Pre-launch insurance hardening.
--
-- These are fix-forward changes: do not edit migrations that may already have
-- been applied. Trigger functions are invoked by PostgreSQL triggers and do not
-- need direct API EXECUTE grants. Keep helper functions' name resolution stable
-- even if a writable schema is added to a session search_path.

begin;

-- Trigger-only guards must not be exposed as callable PostgREST RPCs.
revoke all on function public.ins_claims_guard() from public, anon, authenticated, service_role;
revoke all on function public.ins_clients_guard() from public, anon, authenticated, service_role;
revoke all on function public.ins_insurers_guard() from public, anon, authenticated, service_role;
revoke all on function public.ins_policies_guard() from public, anon, authenticated, service_role;

-- Pin search_path on functions identified by the Supabase security advisor.
-- pg_catalog is first; pg_temp is deliberately last.
alter function public.fin_ledger_currency(uuid)
  set search_path = pg_catalog, public, pg_temp;

alter function public.ins_via_rpc()
  set search_path = pg_catalog, public, pg_temp;

alter function public.ins_touch_updated_at()
  set search_path = pg_catalog, public, pg_temp;

-- Keep the existing restricted EXECUTE ACL; this only hardens name resolution.
alter function public.post_journal_entry(uuid, text, uuid, date, text, jsonb)
  set search_path = pg_catalog, public, pg_temp;

commit;
