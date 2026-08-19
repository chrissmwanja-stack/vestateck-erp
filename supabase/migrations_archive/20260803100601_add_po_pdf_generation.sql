-- Real PO PDF generation: client builds the PDF (jsPDF) from data fetched
-- via get_po_pdf_data(), uploads it to a private Storage bucket, then
-- records the path via record_po_pdf(). Regenerated fresh each time the
-- PDF icon is clicked (upsert), so it always reflects current PO/request
-- state rather than going stale.

alter table purchase_orders
  add column if not exists pdf_storage_path text,
  add column if not exists pdf_generated_at timestamptz;

insert into storage.buckets (id, name, public)
values ('po-documents', 'po-documents', false)
on conflict (id) do nothing;

-- Storage path convention: {tenant_id}/{po_number}.pdf
drop policy if exists "po_documents_tenant_select" on storage.objects;
create policy "po_documents_tenant_select" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'po-documents'
    and (storage.foldername(name))[1] = public.get_my_tenant_id()::text
  );

drop policy if exists "po_documents_tenant_insert" on storage.objects;
create policy "po_documents_tenant_insert" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'po-documents'
    and (storage.foldername(name))[1] = public.get_my_tenant_id()::text
  );

drop policy if exists "po_documents_tenant_update" on storage.objects;
create policy "po_documents_tenant_update" on storage.objects
  for update to authenticated
  using (
    bucket_id = 'po-documents'
    and (storage.foldername(name))[1] = public.get_my_tenant_id()::text
  );

-- Everything needed to render one PO's PDF: header fields + itemized
-- line items (jsonb array, empty array if none exist yet).
create or replace function get_po_pdf_data(p_purchase_order_id uuid)
returns table (
  purchase_order_id uuid,
  po_number text,
  initial_po_number text,
  company text,
  po_total numeric,
  currency text,
  po_date date,
  mr_number text,
  mr_title text,
  requester_name text,
  delivery_date date,
  organization_name text,
  line_items jsonb
)
language sql
security definer
set search_path = public
as $$
  select
    po.id,
    po.po_number,
    po.initial_po_number,
    po.vendor_name,
    po.amount,
    po.currency,
    po.generated_at::date,
    r.mr_number,
    r.item_description,
    requester.name,
    r.delivery_date,
    o.site_name,
    coalesce(
      (
        select jsonb_agg(jsonb_build_object(
          'material_service', rli.material_service,
          'cost_code', rli.cost_code,
          'place_of_use', rli.place_of_use,
          'quantity', rli.quantity,
          'unit_price', rli.unit_price,
          'total', rli.total,
          'currency', rli.currency
        ) order by rli.created_at)
        from request_line_items rli
        where rli.request_id = r.id
      ),
      '[]'::jsonb
    )
  from purchase_orders po
  join requests r on r.id = po.request_id
  join app_users requester on requester.id = r.requester_id
  left join organizations o on o.id = r.organization_id
  where po.id = p_purchase_order_id
    and r.tenant_id = get_my_tenant_id();
$$;

comment on function get_po_pdf_data is
  'Returns everything needed to render one PO PDF (header + itemized line items). Tenant-scoped.';

-- Records that a PDF was (re)generated for this PO. Deliberately not
-- restricted to Finance/has_po_access() -- generating a document view of
-- a PO you can already see via get_procurement_info isn't a privileged
-- action, same accessibility as the report itself.
create or replace function record_po_pdf(p_purchase_order_id uuid, p_storage_path text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update purchase_orders po
  set pdf_storage_path = p_storage_path,
      pdf_generated_at = now()
  from requests r
  where po.id = p_purchase_order_id
    and po.request_id = r.id
    and r.tenant_id = get_my_tenant_id();

  if not found then
    raise exception 'Purchase order not found or not accessible';
  end if;
end;
$$;

grant execute on function get_po_pdf_data to authenticated;
grant execute on function record_po_pdf to authenticated;

-- Extend get_procurement_info to surface pdf state per row.
drop function if exists get_procurement_info(uuid, text, text, text, text, text, text);

create or replace function get_procurement_info(
  p_organization_id uuid default null,
  p_initial_po_number text default null,
  p_company text default null,
  p_purchaser text default null,
  p_mr_number text default null,
  p_po_number text default null,
  p_po_status text default null
)
returns table (
  request_id uuid,
  purchase_order_id uuid,
  initial_po_number text,
  po_number text,
  po_total numeric,
  currency text,
  company text,
  requester_name text,
  mr_originator_name text,
  mr_title text,
  mr_number text,
  po_date date,
  delivery_date date,
  shared_with_supplier boolean,
  delivered_at timestamptz,
  completed_at timestamptz,
  po_status text,
  pdf_storage_path text,
  pdf_generated_at timestamptz
)
language sql
security definer
set search_path = public
as $$
  select
    r.id as request_id,
    po.id as purchase_order_id,
    po.initial_po_number,
    po.po_number,
    po.amount as po_total,
    po.currency,
    po.vendor_name as company,
    requester.name as requester_name,
    purchaser.name as mr_originator_name,
    r.item_description as mr_title,
    r.mr_number,
    po.generated_at::date as po_date,
    r.delivery_date,
    po.shared_with_supplier,
    po.delivered_at,
    po.completed_at,
    case
      when po.completed_at is not null then 'completed'
      when po.delivered_at is not null then 'delivered'
      when po.shared_with_supplier then 'shared'
      else 'pending'
    end as po_status,
    po.pdf_storage_path,
    po.pdf_generated_at
  from purchase_orders po
  join requests r on r.id = po.request_id
  join app_users requester on requester.id = r.requester_id
  left join request_offers ro on ro.request_id = r.id
  left join app_users purchaser on purchaser.id = ro.submitted_by
  where r.tenant_id = get_my_tenant_id()
    and (p_organization_id is null or r.organization_id = p_organization_id)
    and (p_initial_po_number is null or po.initial_po_number ilike '%' || p_initial_po_number || '%')
    and (p_company is null or po.vendor_name ilike '%' || p_company || '%')
    and (p_purchaser is null or purchaser.name ilike '%' || p_purchaser || '%')
    and (p_mr_number is null or r.mr_number ilike '%' || p_mr_number || '%')
    and (p_po_number is null or po.po_number ilike '%' || p_po_number || '%')
    and (
      p_po_status is null or p_po_status = 'All' or
      (case
        when po.completed_at is not null then 'completed'
        when po.delivered_at is not null then 'delivered'
        when po.shared_with_supplier then 'shared'
        else 'pending'
      end) = p_po_status
    )
  order by po.generated_at desc;
$$;

grant execute on function get_procurement_info to authenticated;
