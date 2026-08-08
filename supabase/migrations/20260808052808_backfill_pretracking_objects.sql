-- Backfill objects that predate migration tracking: notifications table +
-- get_my_tenant_id, am_i_finance, get_my_procurement_orders functions.
-- All idempotent (IF NOT EXISTS / CREATE OR REPLACE) -- safe no-op against
-- the existing live schema. See git commit for full context/comments.

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id),
  recipient_id uuid not null references public.app_users(id),
  type text not null,
  title text not null,
  body text not null,
  request_id uuid references public.requests(id),
  purchase_order_id uuid references public.purchase_orders(id),
  read_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists idx_notifications_tenant on public.notifications(tenant_id);
create index if not exists idx_notifications_recipient on public.notifications(recipient_id);

alter table public.notifications enable row level security;

drop policy if exists notifications_select_own on public.notifications;
create policy notifications_select_own on public.notifications
  for select
  using (recipient_id = auth.uid());

drop policy if exists notifications_mark_read_own on public.notifications;
create policy notifications_mark_read_own on public.notifications
  for update
  using (recipient_id = auth.uid())
  with check (recipient_id = auth.uid());

create or replace function public.get_my_tenant_id()
returns uuid
language sql
stable security definer
set search_path = public
as $$
  select tenant_id from app_users where id = auth.uid();
$$;

create or replace function public.am_i_finance()
returns boolean
language sql
stable security definer
set search_path = public
as $$
  select has_po_access();
$$;

create or replace function public.get_my_procurement_orders()
returns table (
  id uuid,
  po_number text,
  item_description text,
  vendor_name text,
  amount numeric,
  request_id uuid,
  shared_with_supplier boolean,
  delivered_at timestamptz,
  completed_at timestamptz,
  request_status text
)
language plpgsql
security definer
as $$
BEGIN
  RETURN QUERY
  SELECT
    po.id,
    po.po_number,
    req.item_description,
    po.vendor_name,
    po.amount,
    po.request_id,
    COALESCE(po.shared_with_supplier, false)::boolean AS shared_with_supplier,
    po.delivered_at,
    po.completed_at,
    req.status AS request_status
  FROM public.purchase_orders po
  INNER JOIN public.requests req ON req.id = po.request_id
  INNER JOIN public.request_offers ro ON ro.request_id = req.id
  WHERE ro.submitted_by = auth.uid()
    AND req.status = 'closed'
  ORDER BY po.generated_at DESC;
END;
$$;
