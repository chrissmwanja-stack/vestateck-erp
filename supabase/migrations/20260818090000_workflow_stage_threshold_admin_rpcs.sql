-- The 5,000,000 UGX approval-branch threshold has always been per-tenant,
-- per-stage data (workflow_stages.threshold_amount) -- every downstream
-- consumer (get_my_approval_queue, extend_approval_queue_with_po_and_threshold,
-- etc.) already reads it dynamically off that column rather than a literal.
-- The gap was never in the read path: it's that every seeding path
-- (0001_init_core_schema, 0013_invoice_approval_routing's 'invoices'
-- variant, seed_tenant_defaults_by_template, tenant_module_entitlements)
-- writes 5000000.00 once at tenant creation and nothing ever lets a
-- platform admin change it afterward -- workflow_stages has a SELECT
-- policy (workflow_stages_select_tenant) but no UPDATE policy at all, so
-- even a platform admin's client-side write would be silently blocked
-- by RLS.
--
-- Two RPCs, following the get_company_analytics() pattern already used
-- by the Companies Console drill-down (single jsonb blob for the read,
-- is_platform_admin() gate on both):
--   - get_tenant_workflow_stages: stages for a tenant, split by
--     applies_to, for CompanyDetail to render.
--   - update_workflow_stage_threshold: updates one stage's
--     threshold_amount. Deliberately refuses to touch a stage whose
--     threshold_amount is currently null -- those stages (Cost Control
--     Engineer, Finance, etc.) aren't threshold branch points by design,
--     and this RPC only edits the value of an existing branch, not the
--     workflow shape itself. Rejects negative amounts; zero is allowed
--     (makes every request take the high branch, which is a legitimate
--     tenant choice, not a data error).
--
-- No RLS UPDATE policy is added on workflow_stages directly -- same
-- reasoning as the material_catalog delete decision: workflow_stages.id
-- is FK'd from requests.current_stage_id and from itself
-- (next_stage_low_id/next_stage_high_id), so open row-level write access
-- would let a client repoint the workflow graph, not just tune a number.
-- Routing all writes through a function that only ever sets
-- threshold_amount keeps that graph immutable from the client.

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
