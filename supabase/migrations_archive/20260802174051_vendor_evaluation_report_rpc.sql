
-- Lock the raw view down (it inherits accounts RLS, i.e. finance-only) and
-- expose a SECURITY DEFINER RPC instead, so Purchasing & Logistics staff
-- (has_po_access -- PO-generating approvers) can see the report without
-- being granted raw SELECT on accounts (which holds banking/tax fields).
revoke select on public.v_vendor_evaluation from authenticated;

create or replace function public.get_vendor_evaluation()
returns table (
  vendor_account_id uuid,
  account_code text,
  vendor_name text,
  contact_name text,
  contact_phone text,
  contact_email text,
  is_active boolean,
  total_pos bigint,
  total_po_value numeric,
  delivered_pos bigint,
  avg_days_to_deliver numeric,
  on_time_delivery_pct numeric,
  fulfillment_accuracy_pct numeric,
  over_delivery_pct numeric,
  under_delivery_pct numeric
)
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if not (is_finance_team_member(null) or has_po_access()) then
    raise exception 'not authorized to view vendor evaluation data';
  end if;

  return query
  select
    v.vendor_account_id, v.account_code, v.vendor_name, v.contact_name,
    v.contact_phone, v.contact_email, v.is_active, v.total_pos, v.total_po_value,
    v.delivered_pos, v.avg_days_to_deliver, v.on_time_delivery_pct,
    v.fulfillment_accuracy_pct, v.over_delivery_pct, v.under_delivery_pct
  from v_vendor_evaluation v
  where v.tenant_id = get_my_tenant_id()
  order by v.total_pos desc nulls last, v.vendor_name;
end;
$$;

grant execute on function public.get_vendor_evaluation() to authenticated;
