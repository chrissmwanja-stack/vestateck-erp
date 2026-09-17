-- Lightweight health-check RPC for external uptime monitoring
-- (UptimeRobot, Better Stack, etc.). A ping against Supabase's own
-- /rest/v1/ root only proves PostgREST is up; it says nothing about
-- whether the database itself is reachable and answering queries. This
-- does one trivial read (current timestamp) so a monitor pinging
-- /rest/v1/rpc/health_check gets a real signal, not just "the edge is
-- alive."
--
-- Deliberately anon-executable (unlike the RPCs revoked in
-- 20260916061641) -- an uptime monitor has no login, and this leaks
-- nothing beyond "the DB answered a query right now."
create or replace function public.health_check()
returns jsonb
language sql
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'status', 'ok',
    'checked_at', now()
  );
$$;

grant execute on function public.health_check() to anon, authenticated;

comment on function public.health_check() is
  'Trivial DB-reachability check for external uptime monitoring. Returns {status, checked_at}. Intentionally anon-executable and side-effect-free.';
