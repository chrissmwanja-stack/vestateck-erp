-- Harden tenant read_only enforcement
-- Addresses forensic item 1: new tables after 20260922 lacked guard, invitations exempt

-- Re-define apply function with tighter exempt list
-- Previous exempt: platform_audit_events, impersonation_sessions, impersonation_logs,
-- tenant_notes, notifications, invitations, app_users
-- New exempt: platform_audit_events, impersonation_sessions, impersonation_logs,
-- tenant_notes, notifications, app_users
-- (invitations REMOVED — ordinary company admin inviting during read_only should be blocked;
--  service_role (edge functions) already bypasses via platform_request_role() check, and
--  platform_admin bypasses via is_platform_admin() check, so operator can still invite if needed)

create or replace function public.apply_tenant_read_only_guard()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  r record;
  v_count integer := 0;
begin
  for r in
    select c.relname
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    join pg_attribute a on a.attrelid = c.oid and a.attname = 'tenant_id' and not a.attisdropped
    where n.nspname = 'public'
      and c.relkind = 'r'
      and c.relname not in (
        'platform_audit_events', 'impersonation_sessions', 'impersonation_logs', 'tenant_notes',
        'notifications',
        'app_users',
        'platform_digests',
        'platform_job_runs'
      )
  loop
    execute format('drop trigger if exists tenant_read_only_guard on public.%I', r.relname);
    execute format(
      'create trigger tenant_read_only_guard before insert or update or delete on public.%I '
      'for each row execute function public.tenant_read_only_guard()',
      r.relname
    );
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

revoke execute on function public.apply_tenant_read_only_guard() from public;
grant execute on function public.apply_tenant_read_only_guard() to authenticated;

-- Re-apply to all current tenant_id tables
select public.apply_tenant_read_only_guard();

comment on function public.apply_tenant_read_only_guard() is
  'Attaches tenant_read_only_guard trigger to every public table with tenant_id except platform/audit tables and notifications/app_users. Re-run after adding new tenant-scoped tables. Invitations is intentionally NOT exempt — read_only should block ordinary invites; service_role and platform_admin bypass via guard itself.';
