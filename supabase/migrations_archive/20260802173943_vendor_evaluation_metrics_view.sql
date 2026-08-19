
create or replace view public.v_vendor_evaluation
with (security_invoker = true)
as
with po_agg as (
  select
    po.vendor_account_id,
    count(distinct po.id) as total_pos,
    sum(po.amount) as total_po_value,
    count(distinct po.id) filter (where po.delivered_at is not null) as delivered_pos,
    avg(extract(epoch from (po.delivered_at - po.generated_at)) / 86400.0)
      filter (where po.delivered_at is not null) as avg_days_to_deliver,
    count(distinct po.id) filter (
      where po.delivered_at is not null and r.delivery_date is not null
        and po.delivered_at::date <= r.delivery_date
    ) as on_time_pos,
    count(distinct po.id) filter (
      where po.delivered_at is not null and r.delivery_date is not null
    ) as pos_with_target_date
  from purchase_orders po
  join requests r on r.id = po.request_id
  where po.vendor_account_id is not null
  group by po.vendor_account_id
),
line_agg as (
  select
    po.vendor_account_id,
    count(*) filter (where lirs.receipt_status = 'full') as full_lines,
    count(*) filter (where lirs.receipt_status = 'partial') as partial_lines,
    count(*) filter (where lirs.receipt_status = 'over') as over_lines,
    count(*) filter (where lirs.receipt_status <> 'none') as received_lines,
    count(*) as total_lines
  from purchase_orders po
  join requests r on r.id = po.request_id
  join line_item_receipt_status lirs on lirs.request_id = r.id
  where po.vendor_account_id is not null
  group by po.vendor_account_id
)
select
  a.id as vendor_account_id,
  a.tenant_id,
  a.account_code,
  a.name as vendor_name,
  a.contact_name,
  a.contact_phone,
  a.contact_email,
  a.is_active,
  coalesce(po_agg.total_pos, 0) as total_pos,
  coalesce(po_agg.total_po_value, 0) as total_po_value,
  coalesce(po_agg.delivered_pos, 0) as delivered_pos,
  round(po_agg.avg_days_to_deliver, 1) as avg_days_to_deliver,
  case when coalesce(po_agg.pos_with_target_date, 0) > 0
    then round(100.0 * po_agg.on_time_pos / po_agg.pos_with_target_date, 1)
    else null
  end as on_time_delivery_pct,
  case when coalesce(line_agg.received_lines, 0) > 0
    then round(100.0 * line_agg.full_lines / line_agg.received_lines, 1)
    else null
  end as fulfillment_accuracy_pct,
  case when coalesce(line_agg.received_lines, 0) > 0
    then round(100.0 * line_agg.over_lines / line_agg.received_lines, 1)
    else null
  end as over_delivery_pct,
  case when coalesce(line_agg.received_lines, 0) > 0
    then round(100.0 * line_agg.partial_lines / line_agg.received_lines, 1)
    else null
  end as under_delivery_pct
from accounts a
left join po_agg on po_agg.vendor_account_id = a.id
left join line_agg on line_agg.vendor_account_id = a.id
where a.account_type in ('vendor', 'both');

grant select on public.v_vendor_evaluation to authenticated;
