-- delete_empty_tenant
--
-- Lets a platform admin remove a company that was created but never used --
-- typically one whose first-admin invite failed, leaving a tenant nobody can
-- sign in to and nothing in the console to clean it up with.
--
-- Safety model: the function refuses unless the tenant holds ONLY the starter
-- rows that create-tenant seeds (see v_seed below). Every other table with a
-- tenant_id FK blocks deletion if it has a row for this tenant, so a table
-- added in the future is protected by default (fail closed) instead of
-- silently cascade-deleted. Users (app_users) and invitations are therefore
-- blocking: revoke pending invites first. A company with real data should be
-- suspended, not deleted.
--
-- Also requires the caller to retype the company name (defence in depth; the
-- UI asks for it too) and writes a 'tenant.delete' audit event. The audit
-- table's tenant_id is ON DELETE SET NULL, so the event survives and keeps
-- the tenant id/name in target_id / before.

create or replace function public.delete_empty_tenant(
  p_tenant_id    uuid,
  p_confirm_name text,
  p_reason       text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tenant public.tenants;
  v_reason text := nullif(btrim(p_reason), '');
  v_has    boolean;
  r        record;
  -- Seeded at company creation or pure operator metadata; safe to cascade.
  v_seed   text[] := array[
    'gl_accounts', 'gl_posting_rules', 'departments', 'tenant_modules',
    'tenant_notes', 'tenant_feature_flags', 'platform_announcements',
    'platform_job_runs', 'platform_audit_events', 'doc_sequences',
    'workflow_stages'
  ];
begin
  perform require_platform_admin('Deleting a company');

  select * into v_tenant from tenants where id = p_tenant_id for update;
  if not found then
    raise exception 'tenant not found';
  end if;

  if btrim(coalesce(p_confirm_name, '')) is distinct from v_tenant.name then
    raise exception 'Confirmation name does not match the company name';
  end if;

  for r in
    select distinct c.conrelid::regclass::text as tbl
    from pg_constraint c
    join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any (c.conkey)
    where c.contype = 'f'
      and c.confrelid = 'public.tenants'::regclass
      and a.attname = 'tenant_id'
      and c.conrelid::regclass::text <> all (v_seed)
    order by 1
  loop
    execute format('select exists (select 1 from %s where tenant_id = $1)', r.tbl)
      into v_has using p_tenant_id;
    if v_has then
      if r.tbl = 'invitations' then
        raise exception 'This company still has invitations. Revoke them first, then delete.';
      elsif r.tbl = 'app_users' then
        raise exception 'This company has users, so it cannot be deleted. Suspend it instead.';
      end if;
      raise exception 'This company has data in "%" so it cannot be deleted. Suspend it instead.', r.tbl;
    end if;
  end loop;

  perform log_platform_event(
    'tenant.delete', null, 'tenant', p_tenant_id::text, v_reason,
    jsonb_build_object(
      'tenant_name', v_tenant.name,
      'status', v_tenant.status,
      'created_at', v_tenant.created_at
    ),
    null
  );

  delete from tenants where id = p_tenant_id;
end;
$$;

revoke execute on function public.delete_empty_tenant(uuid, text, text) from public;
revoke execute on function public.delete_empty_tenant(uuid, text, text) from anon;
grant  execute on function public.delete_empty_tenant(uuid, text, text) to authenticated;
