
-- A petty cash float is a fixed imprest ceiling held by a custodian against
-- a specific cost center. Expenditure slips can optionally be tagged
-- against a float (petty_cash_float_id below); untagged slips behave
-- exactly as before -- ordinary one-off cash/bank spend.
create table public.petty_cash_floats (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id),
  cost_center_id uuid not null references public.cost_centers(id),
  custodian_user_id uuid not null references public.app_users(id),
  float_name text not null,
  ceiling_amount numeric not null check (ceiling_amount > 0),
  currency text not null default 'UGX',
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger touch_petty_cash_float_updated_at_trigger
  before update on public.petty_cash_floats
  for each row execute function public.touch_updated_at();

-- Replenishment tops a float back up (typically to its ceiling, but the
-- amount is free-form in case of partial top-ups). Distinct from
-- cash_bank_transactions because this isn't "paying an invoice" -- it's
-- refilling a custodian's cash box, usually funded by a bank withdrawal.
create table public.petty_cash_replenishments (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id),
  petty_cash_float_id uuid not null references public.petty_cash_floats(id),
  amount numeric not null check (amount > 0),
  replenished_date date not null,
  funded_from text not null check (funded_from = any (array['cash'::text, 'bank'::text])),
  bank_account text,
  description text,
  recorded_by uuid not null default auth.uid() references public.app_users(id),
  created_at timestamptz not null default now()
);

-- Optional link from an expenditure slip to the float it was drawn against.
alter table public.expenditure_slips
  add column petty_cash_float_id uuid references public.petty_cash_floats(id);

-- Running balance per float: total replenished minus total spent against
-- it via tagged expenditure slips. No enforcement against going negative --
-- the UI warns but does not block, per the "petty cash needs pragmatic
-- float, not a hard wall" decision.
create view public.petty_cash_float_balances as
select
  f.id as petty_cash_float_id,
  f.tenant_id,
  f.cost_center_id,
  f.custodian_user_id,
  f.float_name,
  f.ceiling_amount,
  f.currency,
  f.is_active,
  coalesce(r.total_replenished, 0) as total_replenished,
  coalesce(s.total_spent, 0) as total_spent,
  coalesce(r.total_replenished, 0) - coalesce(s.total_spent, 0) as current_balance
from public.petty_cash_floats f
left join (
  select petty_cash_float_id, sum(amount) as total_replenished
  from public.petty_cash_replenishments
  group by petty_cash_float_id
) r on r.petty_cash_float_id = f.id
left join (
  select petty_cash_float_id, sum(amount) as total_spent
  from public.expenditure_slips
  where petty_cash_float_id is not null
  group by petty_cash_float_id
) s on s.petty_cash_float_id = f.id;

alter table public.petty_cash_floats enable row level security;
alter table public.petty_cash_replenishments enable row level security;

-- Same finance-team pattern as accounts/organizations/etc: any finance role
-- can view, only 'finance' role can create/edit/delete.
create policy petty_cash_floats_select on public.petty_cash_floats
  for select using (is_finance_team_member(null) and tenant_id = get_my_tenant_id());
create policy petty_cash_floats_insert on public.petty_cash_floats
  for insert with check (is_finance_team_member('finance') and tenant_id = get_my_tenant_id());
create policy petty_cash_floats_update on public.petty_cash_floats
  for update using (is_finance_team_member('finance') and tenant_id = get_my_tenant_id())
  with check (is_finance_team_member('finance') and tenant_id = get_my_tenant_id());
create policy petty_cash_floats_delete on public.petty_cash_floats
  for delete using (is_finance_team_member('finance') and tenant_id = get_my_tenant_id());

create policy petty_cash_replenishments_select on public.petty_cash_replenishments
  for select using (is_finance_team_member(null) and tenant_id = get_my_tenant_id());
create policy petty_cash_replenishments_insert on public.petty_cash_replenishments
  for insert with check (is_finance_team_member('finance') and tenant_id = get_my_tenant_id());
create policy petty_cash_replenishments_update on public.petty_cash_replenishments
  for update using (is_finance_team_member('finance') and tenant_id = get_my_tenant_id())
  with check (is_finance_team_member('finance') and tenant_id = get_my_tenant_id());
create policy petty_cash_replenishments_delete on public.petty_cash_replenishments
  for delete using (is_finance_team_member('finance') and tenant_id = get_my_tenant_id());

-- Defaults trigger, mirroring set_supplier_invoice_defaults/set_receivable_invoice_defaults
create or replace function public.set_petty_cash_defaults()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  new.tenant_id := get_my_tenant_id();
  return new;
end;
$$;

create trigger set_petty_cash_float_defaults_trigger
  before insert on public.petty_cash_floats
  for each row execute function public.set_petty_cash_defaults();

create trigger set_petty_cash_replenishment_defaults_trigger
  before insert on public.petty_cash_replenishments
  for each row execute function public.set_petty_cash_defaults();
