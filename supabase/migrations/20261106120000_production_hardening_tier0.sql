-- Production hardening, tier 0 (small, behaviour-neutral fixes).
--
-- Driven by the live Supabase advisors on 2026-11-06. Nothing here changes
-- what an application user can do; it closes advisor findings and puts one
-- object that only ever existed in production under version control.
--
-- 1. keepalive_ping() existed in production with no migration (a Studio
--    change; MIGRATION_POLICY rule 3 says commit the equivalent the same
--    day). The body below is copied from the live definition. It is called
--    by .github/workflows/supabase-keepalive.yml with the anon key, so it is
--    the one definer function besides health_check() and
--    get_platform_branding() that anon may execute. authenticated does not
--    need it, so that grant goes.
--
-- 2. documents_via_rpc() had no pinned search_path (advisor 0011).
--
-- 3. fx_rates_round_rate() is a trigger function. Postgres checks EXECUTE on
--    a trigger function when the trigger is created, never when it fires, so
--    revoking the client roles cannot affect inserts into fx_rates. The same
--    pattern is already used for documents_guard().
--
-- 4. doc_sequences and ins_notification_marks have RLS enabled and no policy.
--    That already denies every client role; the explicit deny policy states
--    the intent and clears advisor 0008. Only SECURITY DEFINER functions
--    (owner, which bypasses RLS) touch these tables.

-- 1. keepalive_ping ---------------------------------------------------------
create or replace function public.keepalive_ping()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  -- Real read against the database so the ping counts as activity.
  perform 1 from public.tenants limit 1;
  return jsonb_build_object('ok', true, 'ts', now());
end;
$$;

revoke all on function public.keepalive_ping() from public, anon, authenticated;
grant execute on function public.keepalive_ping() to anon, service_role;

-- 2. documents_via_rpc ------------------------------------------------------
alter function public.documents_via_rpc() set search_path = public, pg_temp;

-- 3. fx_rates_round_rate ----------------------------------------------------
revoke all on function public.fx_rates_round_rate() from public, anon, authenticated;

-- 4. explicit deny on internal tables --------------------------------------
drop policy if exists doc_sequences_no_client_access on public.doc_sequences;
create policy doc_sequences_no_client_access on public.doc_sequences
  for select to authenticated using (false);

drop policy if exists ins_notification_marks_no_client_access on public.ins_notification_marks;
create policy ins_notification_marks_no_client_access on public.ins_notification_marks
  for select to authenticated using (false);
