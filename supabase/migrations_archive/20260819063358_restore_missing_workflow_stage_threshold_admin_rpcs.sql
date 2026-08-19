-- Recreated locally on 2026-08-19 to close a migration-drift gap: this
-- version was applied directly to the live project (matches
-- supabase_migrations.schema_migrations.statements exactly) but the
-- corresponding file never made it into supabase/migrations/, so a
-- fresh clone + `supabase db reset` would not reproduce the live
-- schema. Restores get_tenant_workflow_stages() and
-- update_workflow_stage_threshold(), both platform-admin-gated RPCs
-- for the per-tenant approval-threshold editor added in
-- 20260818090000_workflow_stage_threshold_admin_rpcs.sql.
--
-- Note: this grants EXECUTE to `authenticated` only, but does not
-- revoke the implicit PUBLIC grant that CREATE FUNCTION applies by
-- default -- see 20260819064500_revoke_anon_execute_current_functions_part2.sql
-- for the follow-up that closes that gap for these two functions
-- along with several others added since the 2026-08-13 sweep.

create or replace function public.get_tenant_workflow_stages(p_tenant_id uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_result jsonb;
begin
  if not is_platform_admin() then
    raise exception 'Only platform admins can view workflow stage thresholds';
  end if;

  if not exists (select 1 from tenants where id = p_tenant_id) then
    raise exception 'tenant not found';
  end if;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', ws.id,
      'name', ws.name,
      'sequence_order', ws.sequence_order,
      'approver_role', ws.approver_role,
      'threshold_amount', ws.threshold_amount,
      'applies_to', ws.applies_to
    )
    order by ws.applies_to, ws.sequence_order
  ), '[]'::jsonb)
  into v_result
  from workflow_stages ws
  where ws.tenant_id = p_tenant_id;

  return v_result;
end;
$function$;

create or replace function public.update_workflow_stage_threshold(
  p_stage_id uuid,
  p_threshold_amount numeric
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_current numeric(14, 2);
begin
  if not is_platform_admin() then
    raise exception 'Only platform admins can edit workflow stage thresholds';
  end if;

  if p_threshold_amount is null or p_threshold_amount < 0 then
    raise exception 'threshold_amount must be a non-negative number';
  end if;

  select threshold_amount into v_current
  from workflow_stages
  where id = p_stage_id;

  if not found then
    raise exception 'workflow stage not found';
  end if;

  if v_current is null then
    raise exception 'this stage has no threshold branch to edit';
  end if;

  update workflow_stages
  set threshold_amount = p_threshold_amount
  where id = p_stage_id;
end;
$function$;

grant execute on function public.get_tenant_workflow_stages(uuid) to authenticated;
grant execute on function public.update_workflow_stage_threshold(uuid, numeric) to authenticated;