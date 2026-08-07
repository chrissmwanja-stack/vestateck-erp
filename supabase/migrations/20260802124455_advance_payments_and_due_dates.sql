-- Gap 1: Advance Payments
-- cash_bank_transactions requires a non-null reference to one of the three
-- invoice/slip tables, so a payment made before any invoice exists has
-- nowhere to go. Rather than loosening that constraint, advances get their
-- own table plus an applications table so one advance can later be matched
-- (in full or in part, across multiple invoices) once real invoices arrive.
create table public.advance_payments (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id),
  account_id uuid not null references public.accounts(id),
  direction text not null check (direction in ('payment', 'receipt')), -- payment = we paid a vendor early; receipt = a client paid us early
  amount numeric not null check (amount > 0),
  currency text not null default 'UGX',
  payment_method text not null check (payment_method in ('cash', 'bank')),
  bank_account text,
  payment_date date not null,
  description text,
  recorded_by uuid not null default auth.uid() references public.app_users(id),
  created_at timestamptz not null default now()
);

create table public.advance_payment_applications (
  id uuid primary key default gen_random_uuid(),
  advance_payment_id uuid not null references public.advance_payments(id),
  reference_type text not null check (reference_type in ('supplier_invoice', 'receivable_invoice')),
  reference_id uuid not null,
  applied_amount numeric not null check (applied_amount > 0),
  applied_at timestamptz not null default now(),
  applied_by uuid not null default auth.uid() references public.app_users(id)
);

alter table public.advance_payments enable row level security;
alter table public.advance_payment_applications enable row level security;

create policy advance_payments_select on public.advance_payments
  for select using (is_finance_team_member(null::text) and tenant_id = get_my_tenant_id());
create policy advance_payments_insert on public.advance_payments
  for insert with check (is_finance_team_member('finance') and tenant_id = get_my_tenant_id());
create policy advance_payments_update on public.advance_payments
  for update using (is_finance_team_member('finance') and tenant_id = get_my_tenant_id())
  with check (is_finance_team_member('finance') and tenant_id = get_my_tenant_id());
create policy advance_payments_delete on public.advance_payments
  for delete using (is_finance_team_member('finance') and tenant_id = get_my_tenant_id());

-- applications inherit tenant scoping via their parent advance_payment
create policy advance_payment_applications_select on public.advance_payment_applications
  for select using (
    is_finance_team_member(null::text)
    and exists (select 1 from public.advance_payments ap where ap.id = advance_payment_id and ap.tenant_id = get_my_tenant_id())
  );
create policy advance_payment_applications_insert on public.advance_payment_applications
  for insert with check (
    is_finance_team_member('finance')
    and exists (select 1 from public.advance_payments ap where ap.id = advance_payment_id and ap.tenant_id = get_my_tenant_id())
  );
create policy advance_payment_applications_delete on public.advance_payment_applications
  for delete using (
    is_finance_team_member('finance')
    and exists (select 1 from public.advance_payments ap where ap.id = advance_payment_id and ap.tenant_id = get_my_tenant_id())
  );

create view public.v_advance_payments with (security_invoker = true) as
select ap.id, ap.tenant_id, ap.account_id, a.account_code, a.name as account_name, ap.direction,
       ap.amount, ap.currency, ap.payment_date, ap.payment_method, ap.description,
       coalesce(applied.total_applied, 0) as total_applied,
       ap.amount - coalesce(applied.total_applied, 0) as remaining_amount
from public.advance_payments ap
join public.accounts a on a.id = ap.account_id
left join (
  select advance_payment_id, sum(applied_amount) as total_applied
  from public.advance_payment_applications
  group by advance_payment_id
) applied on applied.advance_payment_id = ap.id;

-- Gap 2: Payment Plan Report
-- Neither invoice table had a due date, so "when is this planned to be
-- paid" couldn't be computed. Adding a nullable due_date to both -- nullable
-- because existing/legacy invoices won't have one, and entry forms should
-- be able to make it optional at first.
alter table public.supplier_invoices add column due_date date;
alter table public.receivable_invoices add column due_date date;

create view public.v_payment_plan with (security_invoker = true) as
select si.tenant_id, 'supplier_invoice'::text as source_type, si.id as source_id, si.invoice_number,
       si.invoice_date, si.due_date, si.currency,
       si.amount_incl_vat - coalesce(paid.total_paid, 0) as outstanding_amount
from public.supplier_invoices si
left join (
  select reference_id, sum(amount) as total_paid
  from public.cash_bank_transactions
  where reference_type = 'supplier_invoice'
  group by reference_id
) paid on paid.reference_id = si.id
where si.due_date is not null
  and si.amount_incl_vat - coalesce(paid.total_paid, 0) > 0
union all
select ri.tenant_id, 'receivable_invoice', ri.id, ri.invoice_number, ri.invoice_date, ri.due_date, ri.currency,
       ri.amount_incl_vat
from public.receivable_invoices ri
where ri.due_date is not null
  and ri.status = 'open';
