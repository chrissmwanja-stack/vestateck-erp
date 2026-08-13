-- Closes the gap where create-tenant produced an empty shell: a company
-- created via the Companies console got zero departments and zero
-- workflow_stages, so its first admin had nowhere to route requests and
-- the entire approval pipeline was non-functional.
--
-- This adds one SECURITY DEFINER RPC, seed_tenant_defaults(tenant_id,
-- industry_template), called by the create-tenant edge function right
-- after the tenant row is inserted. It is idempotent (guards on "does
-- this tenant already have departments/workflow_stages") so it's safe
-- to call more than once for the same tenant.
--
-- Two templates for now, matching the department set already used
-- elsewhere in the app (see ModuleTree.tsx's 8 peer portals) and the
-- workflow_stages already seeded for the test tenant in
-- 0001_init_core_schema.sql (same 7 stages, same 5,000,000 threshold):
--   'general'      - 8 core departments, no industry-specific modules
--   'construction' - the 8 core + Machine Operations + Sustainability
--
-- The approval pipeline itself is NOT configurable per tenant yet (that
-- is a deliberately deferred feature) -- every tenant gets the same
-- 7-stage workflow. The Companies console explains this pipeline to the
-- admin at creation time rather than letting them customize it.

create or replace function public.seed_tenant_defaults(
  p_tenant_id uuid,
  p_industry_template text
)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_dept_cost_control uuid;
  v_dept_procurement uuid;
  v_dept_finance uuid;
  v_dept_pmo uuid;
  v_dept_it uuid;
  v_dept_hr uuid;
  v_dept_law uuid;
  v_dept_bd uuid;
  v_stage_cce uuid;
  v_stage_ccm uuid;
  v_stage_offer uuid;
  v_stage_chief uuid;
  v_stage_finance uuid;
  v_stage_pm uuid;
  v_stage_dgm uuid;
begin
  if not is_platform_admin() then
    raise exception 'Only platform admins can seed tenant defaults';
  end if;

  -- Idempotency guards -- do nothing if this tenant already has either.
  if exists (select 1 from departments where tenant_id = p_tenant_id)
     or exists (select 1 from workflow_stages where tenant_id = p_tenant_id) then
    return;
  end if;

  -- ── Departments ──────────────────────────────────────────────────
  insert into departments (tenant_id, name) values (p_tenant_id, 'Cost Control')
    returning id into v_dept_cost_control;
  insert into departments (tenant_id, name) values (p_tenant_id, 'Procurement & Logistics')
    returning id into v_dept_procurement;
  insert into departments (tenant_id, name) values (p_tenant_id, 'Finance & Financial Reporting')
    returning id into v_dept_finance;
  insert into departments (tenant_id, name) values (p_tenant_id, 'Project Management Office')
    returning id into v_dept_pmo;
  insert into departments (tenant_id, name) values (p_tenant_id, 'IT Support')
    returning id into v_dept_it;
  insert into departments (tenant_id, name) values (p_tenant_id, 'Human Resources')
    returning id into v_dept_hr;
  insert into departments (tenant_id, name) values (p_tenant_id, 'Law & Compliance')
    returning id into v_dept_law;
  insert into departments (tenant_id, name) values (p_tenant_id, 'Business Development')
    returning id into v_dept_bd;

  if p_industry_template = 'construction' then
    insert into departments (tenant_id, name) values (p_tenant_id, 'Machine Operations');
    insert into departments (tenant_id, name) values (p_tenant_id, 'Sustainability & Business Excellence');
  end if;

  -- ── Workflow stages (same pipeline for every template) ──────────
  -- Cost Control Engineer -> Cost Control Manager -> Procurement Offer
  -- Entry -> Control Chief/Manager -> threshold check ->
  --   below: Finance -> PO
  --   above: Project Manager -> Deputy GM -> Finance -> PO
  insert into workflow_stages (tenant_id, name, sequence_order, approver_role)
    values (p_tenant_id, 'Cost Control Engineer', 1, 'Cost Control Engineer')
    returning id into v_stage_cce;
  insert into workflow_stages (tenant_id, name, sequence_order, approver_role)
    values (p_tenant_id, 'Cost Control Manager', 2, 'Cost Control Manager')
    returning id into v_stage_ccm;
  insert into workflow_stages (tenant_id, name, sequence_order, approver_role)
    values (p_tenant_id, 'Procurement: Offer Entry', 3, 'Procurement/Logistics Expert')
    returning id into v_stage_offer;
  insert into workflow_stages (tenant_id, name, sequence_order, approver_role, threshold_amount)
    values (p_tenant_id, 'Control Chief/Manager', 4, 'Procurement & Logistics Chief', 5000000.00)
    returning id into v_stage_chief;
  insert into workflow_stages (tenant_id, name, sequence_order, approver_role)
    values (p_tenant_id, 'Finance', 5, 'Finance Officer')
    returning id into v_stage_finance;
  insert into workflow_stages (tenant_id, name, sequence_order, approver_role)
    values (p_tenant_id, 'Project Manager', 6, 'Project Manager')
    returning id into v_stage_pm;
  insert into workflow_stages (tenant_id, name, sequence_order, approver_role)
    values (p_tenant_id, 'Deputy General Manager', 7, 'Deputy General Manager')
    returning id into v_stage_dgm;

  update workflow_stages set next_stage_low_id = v_stage_ccm where id = v_stage_cce;
  update workflow_stages set next_stage_low_id = v_stage_offer where id = v_stage_ccm;
  update workflow_stages set next_stage_low_id = v_stage_chief where id = v_stage_offer;
  update workflow_stages
    set next_stage_low_id = v_stage_finance, next_stage_high_id = v_stage_pm
    where id = v_stage_chief;
  update workflow_stages set next_stage_low_id = v_stage_dgm where id = v_stage_pm;
  update workflow_stages set next_stage_low_id = v_stage_finance where id = v_stage_dgm;
end;
$function$;

revoke execute on function public.seed_tenant_defaults(uuid, text) from public, anon;
grant execute on function public.seed_tenant_defaults(uuid, text) to authenticated;