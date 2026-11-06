-- Backfilled from production. This was applied directly to the live project
-- (recorded in supabase_migrations.schema_migrations as
-- 20261029053936 / add_keepalive_ping_function) without a file in the repo,
-- which left `supabase migrations list` showing a remote-only version and
-- would make `supabase db push` refuse to run. The statements below are
-- copied verbatim from the recorded migration. The follow-up
-- 20261106120000_production_hardening_tier0.sql tightens its grants.
create or replace function public.keepalive_ping()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Real read against the database so the ping counts as activity.
  perform 1 from public.tenants limit 1;
  return jsonb_build_object('ok', true, 'ts', now());
end;
$$;

revoke all on function public.keepalive_ping() from public;
grant execute on function public.keepalive_ping() to anon, authenticated;
