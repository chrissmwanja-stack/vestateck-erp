-- Editing a stage's branching (next_stage_low_id/high_id, threshold_amount)
-- or deactivating it doesn't corrupt anything at the DB level -- the FK
-- constraints from requests/invoice_requests.current_stage_id back to
-- workflow_stages are all NO ACTION (not CASCADE), so a stage that's
-- anyone's current_stage_id can't be deleted out from under them, and
-- routing is only evaluated at the moment a request actually advances,
-- not stored -- so an edit takes effect for in-flight items going
-- forward. That's often the intended behavior, but an admin changing a
-- stage's routing has no way to know whether that's a quiet config
-- change or something that reroutes requests already sitting there.
--
-- This RPC lets the admin UI warn before saving: "N requests / M invoices
-- are currently at this stage" -- an FYI, not a block. requests/
-- invoice_requests SELECT RLS is "own or actionable" (see
-- requests_select_own_or_actionable), which undercounts for an admin who
-- didn't submit or isn't personally an approver on every open item, so a
-- SECURITY DEFINER count scoped by is_tenant_admin() is needed instead of
-- letting the frontend just query the tables directly.
create or replace function public.count_open_items_at_workflow_stage(p_stage_id uuid)
returns table(open_requests bigint, open_invoices bigint)
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_tenant uuid;
begin
  if not is_tenant_admin() then
    raise exception 'not authorized';
  end if;

  v_tenant := get_my_tenant_id();

  if not exists (select 1 from workflow_stages where id = p_stage_id and tenant_id = v_tenant) then
    raise exception 'stage not found in this tenant';
  end if;

  return query
  select
    (select count(*) from requests
     where current_stage_id = p_stage_id and tenant_id = v_tenant and status = 'open'),
    (select count(*) from invoice_requests
     where current_stage_id = p_stage_id and tenant_id = v_tenant and status = 'open');
end;
$$;

revoke all on function public.count_open_items_at_workflow_stage(uuid) from public;
grant execute on function public.count_open_items_at_workflow_stage(uuid) to authenticated;