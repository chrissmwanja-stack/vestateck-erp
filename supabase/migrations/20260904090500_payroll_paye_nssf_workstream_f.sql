-- Workstream F: PAYE + NSSF statutory payroll deductions.
--
-- Root cause (see handoff notes): hr_payroll_items.net_pay was
-- basic_salary + allowances - deductions, where deductions was one
-- manual number HR typed in. No statutory computation existed.
--
-- Rate confirmation status as of this migration (Sep 2026):
--   NSSF: 5% employee / 10% employer of gross pay. Consistently
--   reported across multiple independent sources -- treated as
--   reliable.
--   PAYE: Uganda's Income Tax (Amendment) Act 2026 (effective 1 Jul
--   2026) is reported to have raised the monthly tax-free threshold
--   from UGX 235,000 to UGX 335,000, but secondary sources
--   materially disagree on the resulting band structure -- some
--   describe a straightforward 4-band 0/10/20/30% schedule, others
--   describe a 5-band schedule with an additional 25% band between
--   UGX 410,001 and 485,000. Neither could be confirmed against
--   ura.go.ug directly. The 4-band schedule seeded below is the
--   version that appeared most consistently across sources, but
--   THIS IS NOT CONFIRMED -- reconfirm against URA's official
--   published schedule (or the enacted Finance Act text) before
--   this is used for a live payroll run. That's exactly what
--   statutory_rate_tables/effective_date is for: correcting this
--   later is a data change, not a code deploy.

create table if not exists public.statutory_rate_tables (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references public.tenants(id) on delete cascade,
    rate_type text not null,
    effective_date date not null,
    -- PAYE: one row per band, band_order low-to-high, upper_bound null
    -- on the top band. NSSF: a single row per rate_type (nssf_employee /
    -- nssf_employer) with band bounds left null and `rate` holding the
    -- flat percentage.
    band_order integer not null default 1,
    lower_bound numeric not null default 0,
    upper_bound numeric,
    rate numeric not null,
    base_tax numeric not null default 0,
    created_at timestamp with time zone not null default now(),
    constraint statutory_rate_tables_rate_type_check
        check (rate_type in ('paye', 'nssf_employee', 'nssf_employer')),
    constraint statutory_rate_tables_rate_check check (rate >= 0 and rate <= 100),
    constraint statutory_rate_tables_bounds_check
        check (upper_bound is null or upper_bound > lower_bound)
);

create index if not exists statutory_rate_tables_lookup_idx
    on public.statutory_rate_tables (tenant_id, rate_type, effective_date);

comment on table public.statutory_rate_tables is
    'Versioned PAYE bands and NSSF rates, keyed by effective_date, so a Finance Act change is a data update rather than a code deploy. See migration header for current confirmation status.';
comment on column public.statutory_rate_tables.base_tax is
    'PAYE only: cumulative tax already due from all lower bands, so calculate_statutory_deductions() does not need to re-walk the whole table for every payslip.';

alter table public.statutory_rate_tables enable row level security;

-- Both finance (posting/remittance) and HR (payroll prep) need to
-- read the rate table; only finance manages it (writes below).
create policy "statutory_rate_tables_select" on public.statutory_rate_tables
    for select using ((is_finance_team_member(null::text) or is_hr_team_member(null::text)) and tenant_id = get_my_tenant_id());
create policy "statutory_rate_tables_insert" on public.statutory_rate_tables
    for insert with check (is_finance_team_member('finance') and tenant_id = get_my_tenant_id());
create policy "statutory_rate_tables_update" on public.statutory_rate_tables
    for update using (is_finance_team_member('finance') and tenant_id = get_my_tenant_id())
    with check (is_finance_team_member('finance') and tenant_id = get_my_tenant_id());
create policy "statutory_rate_tables_delete" on public.statutory_rate_tables
    for delete using (is_finance_team_member('finance') and tenant_id = get_my_tenant_id());

grant select, insert, update, delete on public.statutory_rate_tables to authenticated;

-- hr_payroll_items: add the three statutory columns and repurpose
-- `deductions` to mean "other deductions" only (loans, advances --
-- anything HR types in by hand). net_pay's generated formula now
-- subtracts PAYE and the employee NSSF share too; nssf_employer is
-- tracked for remittance reporting but never touches net_pay -- it's
-- an employer cost, not a deduction from the employee.
alter table public.hr_payroll_items
    add column if not exists paye_amount numeric not null default 0,
    add column if not exists nssf_employee numeric not null default 0,
    add column if not exists nssf_employer numeric not null default 0;

alter table public.hr_payroll_items
    add constraint hr_payroll_items_paye_amount_check check (paye_amount >= 0),
    add constraint hr_payroll_items_nssf_employee_check check (nssf_employee >= 0),
    add constraint hr_payroll_items_nssf_employer_check check (nssf_employer >= 0);

comment on column public.hr_payroll_items.deductions is
    'Other deductions only (loans, advances, etc) -- entered by hand. Statutory PAYE and NSSF are in their own columns and computed by calculate_statutory_deductions(), not folded in here.';

alter table public.hr_payroll_items drop column if exists net_pay;
alter table public.hr_payroll_items
    add column net_pay numeric generated always as (
        (basic_salary + allowances) - deductions - paye_amount - nssf_employee
    ) stored;

-- Statutory calculation. PAYE walks the versioned band table (as of
-- the given date) and applies base_tax + rate * (amount above the
-- band's lower bound); NSSF is a flat rate on gross (basic + allowances).
-- Returns zeros (rather than raising) when a tenant has no rate table
-- rows yet, same "skip, don't guess" posture as the GL posting
-- triggers -- generate_payroll_items() below still creates the line
-- item, just with statutory amounts to fill in manually until the
-- tenant's rate table is seeded.
create or replace function public.calculate_statutory_deductions(
    p_gross numeric,
    p_as_of_date date default current_date
)
returns table(paye_amount numeric, nssf_employee numeric, nssf_employer numeric)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tenant_id uuid := get_my_tenant_id();
  v_paye numeric := 0;
  v_nssf_employee_rate numeric;
  v_nssf_employer_rate numeric;
  v_band record;
begin
  select rt.rate, rt.base_tax, rt.lower_bound into v_band
  from statutory_rate_tables rt
  where rt.tenant_id = v_tenant_id
    and rt.rate_type = 'paye'
    and rt.effective_date <= p_as_of_date
    and p_gross > rt.lower_bound
    and (rt.upper_bound is null or p_gross <= rt.upper_bound)
  order by rt.effective_date desc, rt.band_order desc
  limit 1;

  if found then
    v_paye := v_band.base_tax + (p_gross - v_band.lower_bound) * v_band.rate / 100;
  end if;

  select rate into v_nssf_employee_rate
  from statutory_rate_tables
  where tenant_id = v_tenant_id and rate_type = 'nssf_employee' and effective_date <= p_as_of_date
  order by effective_date desc limit 1;

  select rate into v_nssf_employer_rate
  from statutory_rate_tables
  where tenant_id = v_tenant_id and rate_type = 'nssf_employer' and effective_date <= p_as_of_date
  order by effective_date desc limit 1;

  return query select
    round(coalesce(v_paye, 0), 2),
    round(p_gross * coalesce(v_nssf_employee_rate, 0) / 100, 2),
    round(p_gross * coalesce(v_nssf_employer_rate, 0) / 100, 2);
end;
$$;

grant execute on function public.calculate_statutory_deductions(numeric, date) to authenticated;

-- Re-generate payroll items: same employee/basic_salary pull as
-- before, now also computing PAYE/NSSF on (basic_salary + allowances)
-- at generation time. Allowances default to 0 at generation, matching
-- the existing flow where HR fills in allowances afterward via
-- update_payroll_item() -- see the trigger-style recompute there too.
create or replace function public.generate_payroll_items(p_run_id uuid)
returns setof public.hr_payroll_items
language plpgsql
security definer
set search_path = public
as $$
declare
  v_run hr_payroll_runs%rowtype;
  v_calc record;
begin
  if not is_hr_team_member() then
    raise exception 'not authorized to prepare payroll';
  end if;

  select * into v_run from hr_payroll_runs where id = p_run_id and tenant_id = get_my_tenant_id();
  if not found then
    raise exception 'payroll run not found';
  end if;
  if v_run.status != 'draft' then
    raise exception 'can only generate items while the run is in draft';
  end if;

  return query
  with new_employees as (
    select e.id as employee_id, cc.basic_salary
    from hr_employees e
    join hr_employee_current_compensation cc on cc.employee_id = e.id
    where e.tenant_id = get_my_tenant_id()
      and e.is_active
      and not exists (select 1 from hr_payroll_items i where i.payroll_run_id = p_run_id and i.employee_id = e.id)
  )
  insert into hr_payroll_items (payroll_run_id, employee_id, basic_salary, paye_amount, nssf_employee, nssf_employer)
  select
    p_run_id,
    ne.employee_id,
    ne.basic_salary,
    (calc).paye_amount,
    (calc).nssf_employee,
    (calc).nssf_employer
  from new_employees ne
  cross join lateral calculate_statutory_deductions(ne.basic_salary) as calc
  on conflict (payroll_run_id, employee_id) do nothing
  returning *;
end;
$$;

-- update_payroll_item now recomputes PAYE/NSSF whenever allowances
-- change (statutory deductions are computed on basic + allowances,
-- so an allowances edit that doesn't recompute them would silently
-- go stale).
create or replace function public.update_payroll_item(
    p_item_id uuid,
    p_allowances numeric,
    p_deductions numeric,
    p_note text default null
)
returns public.hr_payroll_items
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row hr_payroll_items%rowtype;
  v_basic numeric;
  v_calc record;
begin
  if not is_hr_team_member() then
    raise exception 'not authorized to edit payroll';
  end if;

  select i.basic_salary into v_basic
  from hr_payroll_items i
  join hr_payroll_runs r on r.id = i.payroll_run_id
  where i.id = p_item_id and r.tenant_id = get_my_tenant_id() and r.status = 'draft';

  if v_basic is null then
    raise exception 'payroll item not found, or run is no longer in draft';
  end if;

  select * into v_calc from calculate_statutory_deductions(v_basic + coalesce(p_allowances, 0));

  update hr_payroll_items i
  set allowances = p_allowances,
      deductions = p_deductions,
      note = p_note,
      paye_amount = v_calc.paye_amount,
      nssf_employee = v_calc.nssf_employee,
      nssf_employer = v_calc.nssf_employer
  where i.id = p_item_id
  returning i.* into v_row;

  return v_row;
end;
$$;

-- GL control accounts for payroll: Salaries/Wages Payable (net pay
-- owed to staff before disbursement), PAYE Payable, NSSF Payable
-- (employee + employer share both land here -- one remittance to
-- NSSF, split isn't a separate liability account NSSF cares about).
alter table public.gl_control_accounts
    add column if not exists salaries_payable_account_id uuid references public.gl_accounts(id),
    add column if not exists paye_payable_account_id uuid references public.gl_accounts(id),
    add column if not exists nssf_payable_account_id uuid references public.gl_accounts(id),
    add column if not exists salaries_expense_account_id uuid references public.gl_accounts(id);

-- Post payroll runs to the GL when they move to 'approved' -- this is
-- the point at which the amounts are final (HR can no longer edit
-- line items once out of draft), same principle as invoices posting
-- on insert. Dr Salaries Expense (gross, i.e. basic+allowances-other
-- deductions, employer's actual payroll cost before statutory
-- withholding) + Dr employer NSSF cost, Cr Salaries Payable (net pay
-- -- what's actually disbursed to staff), Cr PAYE Payable, Cr NSSF
-- Payable (employee + employer share combined).
--
-- The existing trg_post_cash_bank_transaction() TODO for
-- reference_type = 'payroll_run' is resolved here too: disbursement
-- now debits Salaries Payable (settling the liability this trigger
-- creates) instead of being skipped.
create or replace function public.trg_post_payroll_run_approval()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ctl gl_control_accounts%rowtype;
  v_totals record;
  v_lines jsonb;
begin
  if new.status != 'approved' or old.status = 'approved' then
    return new;
  end if;

  select * into v_ctl from gl_control_accounts where tenant_id = new.tenant_id;
  if not found or v_ctl.salaries_payable_account_id is null or v_ctl.paye_payable_account_id is null
     or v_ctl.nssf_payable_account_id is null or v_ctl.salaries_expense_account_id is null then
    -- Payroll control accounts not configured yet -- skip posting
    -- rather than guess. The run still approves normally.
    return new;
  end if;

  select
    coalesce(sum(basic_salary + allowances - deductions), 0) as gross_expense,
    coalesce(sum(nssf_employer), 0) as employer_nssf,
    coalesce(sum(net_pay), 0) as total_net_pay,
    coalesce(sum(paye_amount), 0) as total_paye,
    coalesce(sum(nssf_employee + nssf_employer), 0) as total_nssf
  into v_totals
  from hr_payroll_items
  where payroll_run_id = new.id;

  if v_totals.gross_expense = 0 then
    return new;  -- nothing to post (no line items)
  end if;

  v_lines := jsonb_build_array(
    jsonb_build_object('gl_account_id', v_ctl.salaries_expense_account_id, 'debit', v_totals.gross_expense)
  );
  if v_totals.employer_nssf > 0 then
    v_lines := v_lines || jsonb_build_object('gl_account_id', v_ctl.salaries_expense_account_id, 'debit', v_totals.employer_nssf);
  end if;
  if v_totals.total_net_pay > 0 then
    v_lines := v_lines || jsonb_build_object('gl_account_id', v_ctl.salaries_payable_account_id, 'credit', v_totals.total_net_pay);
  end if;
  if v_totals.total_paye > 0 then
    v_lines := v_lines || jsonb_build_object('gl_account_id', v_ctl.paye_payable_account_id, 'credit', v_totals.total_paye);
  end if;
  if v_totals.total_nssf > 0 then
    v_lines := v_lines || jsonb_build_object('gl_account_id', v_ctl.nssf_payable_account_id, 'credit', v_totals.total_nssf);
  end if;

  perform post_journal_entry(new.tenant_id, 'payroll_run', new.id, coalesce(new.approved_at::date, current_date),
    'Payroll run ' || new.period, v_lines);

  return new;
end;
$$;

drop trigger if exists trg_post_payroll_run_approval on public.hr_payroll_runs;
create trigger trg_post_payroll_run_approval
    after update on public.hr_payroll_runs
    for each row execute function public.trg_post_payroll_run_approval();

alter table public.journal_entries drop constraint if exists journal_entries_source_type_check;
alter table public.journal_entries add constraint journal_entries_source_type_check
    check (source_type in ('supplier_invoice', 'receivable_invoice', 'cash_bank_transaction', 'opening_balance', 'manual', 'payroll_run'));

-- Cash/bank disbursement now settles Salaries Payable instead of
-- being skipped for reference_type = 'payroll_run'.
create or replace function public.trg_post_cash_bank_transaction()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ctl gl_control_accounts%rowtype;
  v_cash_side uuid;
  v_other_side uuid;
  v_lines jsonb;
begin
  select * into v_ctl from gl_control_accounts where tenant_id = new.tenant_id;
  if not found then
    return new;
  end if;

  v_cash_side := case when new.payment_method = 'bank' then v_ctl.bank_account_id else v_ctl.cash_account_id end;

  v_other_side := case new.reference_type
    when 'supplier_invoice' then v_ctl.ap_control_account_id
    when 'receivable_invoice' then v_ctl.ar_control_account_id
    when 'expenditure_slip' then v_ctl.default_expense_account_id
    when 'payroll_run' then v_ctl.salaries_payable_account_id
    else null
  end;
  if v_other_side is null then
    return new;  -- e.g. payroll_run before salaries_payable_account_id is configured
  end if;

  if new.transaction_type = 'payment' then
    v_lines := jsonb_build_array(
      jsonb_build_object('gl_account_id', v_other_side, 'debit', new.amount),
      jsonb_build_object('gl_account_id', v_cash_side, 'credit', new.amount)
    );
  else -- 'receipt'
    v_lines := jsonb_build_array(
      jsonb_build_object('gl_account_id', v_cash_side, 'debit', new.amount),
      jsonb_build_object('gl_account_id', v_other_side, 'credit', new.amount)
    );
  end if;

  perform post_journal_entry(new.tenant_id, 'cash_bank_transaction', new.id, new.transaction_date,
    coalesce(new.description, initcap(new.transaction_type) || ' - ' || new.reference_type), v_lines);

  return new;
end;
$$;

-- Extend the starter COA seed with payroll control accounts, for
-- tenants seeding fresh going forward (already-seeded tenants add
-- these via Chart of Accounts admin, same as WHT Payable was).
create or replace function public.seed_default_chart_of_accounts()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tenant_id uuid := get_my_tenant_id();
  v_ap uuid; v_ar uuid; v_bank uuid; v_cash uuid;
  v_vat_in uuid; v_vat_out uuid; v_expense uuid; v_revenue uuid; v_wht uuid;
  v_salaries_payable uuid; v_paye_payable uuid; v_nssf_payable uuid; v_salaries_expense uuid;
begin
  if not is_finance_team_member('finance') then
    raise exception 'not authorized to set up the chart of accounts';
  end if;

  if exists (select 1 from gl_accounts where tenant_id = v_tenant_id) then
    raise exception 'chart of accounts already exists for this tenant';
  end if;

  insert into gl_accounts (tenant_id, account_code, name, account_type, is_control_account) values
    (v_tenant_id, '1000', 'Bank', 'asset', true),
    (v_tenant_id, '1010', 'Cash', 'asset', true),
    (v_tenant_id, '1100', 'Accounts Receivable Control', 'asset', true),
    (v_tenant_id, '1200', 'VAT Input', 'asset', true),
    (v_tenant_id, '2000', 'Accounts Payable Control', 'liability', true),
    (v_tenant_id, '2100', 'VAT Output', 'liability', true),
    (v_tenant_id, '2200', 'WHT Payable', 'liability', true),
    (v_tenant_id, '2300', 'Salaries Payable', 'liability', true),
    (v_tenant_id, '2310', 'PAYE Payable', 'liability', true),
    (v_tenant_id, '2320', 'NSSF Payable', 'liability', true),
    (v_tenant_id, '4000', 'Sales Revenue', 'revenue', false),
    (v_tenant_id, '5000', 'General Expense', 'expense', false),
    (v_tenant_id, '5100', 'Salaries Expense', 'expense', false);

  select id into v_bank from gl_accounts where tenant_id = v_tenant_id and account_code = '1000';
  select id into v_cash from gl_accounts where tenant_id = v_tenant_id and account_code = '1010';
  select id into v_ar from gl_accounts where tenant_id = v_tenant_id and account_code = '1100';
  select id into v_vat_in from gl_accounts where tenant_id = v_tenant_id and account_code = '1200';
  select id into v_ap from gl_accounts where tenant_id = v_tenant_id and account_code = '2000';
  select id into v_vat_out from gl_accounts where tenant_id = v_tenant_id and account_code = '2100';
  select id into v_wht from gl_accounts where tenant_id = v_tenant_id and account_code = '2200';
  select id into v_salaries_payable from gl_accounts where tenant_id = v_tenant_id and account_code = '2300';
  select id into v_paye_payable from gl_accounts where tenant_id = v_tenant_id and account_code = '2310';
  select id into v_nssf_payable from gl_accounts where tenant_id = v_tenant_id and account_code = '2320';
  select id into v_revenue from gl_accounts where tenant_id = v_tenant_id and account_code = '4000';
  select id into v_expense from gl_accounts where tenant_id = v_tenant_id and account_code = '5000';
  select id into v_salaries_expense from gl_accounts where tenant_id = v_tenant_id and account_code = '5100';

  insert into gl_control_accounts (
    tenant_id, ap_control_account_id, ar_control_account_id, bank_account_id, cash_account_id,
    vat_input_account_id, vat_output_account_id, default_expense_account_id, default_revenue_account_id,
    wht_payable_account_id, salaries_payable_account_id, paye_payable_account_id, nssf_payable_account_id,
    salaries_expense_account_id
  ) values (
    v_tenant_id, v_ap, v_ar, v_bank, v_cash, v_vat_in, v_vat_out, v_expense, v_revenue, v_wht,
    v_salaries_payable, v_paye_payable, v_nssf_payable, v_salaries_expense
  );
end;
$$;

-- PAYE/NSSF remittance schedule per period: what's owed to URA and
-- NSSF for each payroll run. Same 15th-of-following-month remittance
-- deadline URA/NSSF both use as filing/payment due date.
create or replace view public.v_paye_nssf_remittance with (security_invoker = true) as
select
  r.tenant_id,
  r.id as payroll_run_id,
  r.period,
  r.status,
  r.approved_at,
  count(i.id) as employee_count,
  coalesce(sum(i.basic_salary + i.allowances), 0) as total_gross,
  coalesce(sum(i.paye_amount), 0) as total_paye,
  coalesce(sum(i.nssf_employee), 0) as total_nssf_employee,
  coalesce(sum(i.nssf_employer), 0) as total_nssf_employer,
  coalesce(sum(i.nssf_employee + i.nssf_employer), 0) as total_nssf,
  coalesce(sum(i.net_pay), 0) as total_net_pay,
  (
    case when r.approved_at is not null
      then (date_trunc('month', r.approved_at::date) + interval '1 month' + interval '14 days')::date
      else null
    end
  ) as remittance_due_date
from public.hr_payroll_runs r
left join public.hr_payroll_items i on i.payroll_run_id = r.id
where r.status in ('approved', 'disbursed')
group by r.tenant_id, r.id, r.period, r.status, r.approved_at;

grant select on public.v_paye_nssf_remittance to authenticated;

-- Seed function: writes the current-as-of-Sep-2026 rate table for the
-- caller's tenant. Separate from seed_default_chart_of_accounts()
-- (finance sets up the COA once; HR/finance may need to re-run or
-- append to the rate table whenever a Finance Act changes it, so this
-- is callable repeatedly with a new effective_date rather than
-- one-time-only).
--
-- PAYE bands seeded here are the UNCONFIRMED 4-band schedule
-- described in the migration header -- reconfirm against URA before
-- relying on this for a live payroll run.
create or replace function public.seed_statutory_rate_table(p_effective_date date default current_date)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tenant_id uuid := get_my_tenant_id();
begin
  if not is_finance_team_member('finance') then
    raise exception 'not authorized to set up statutory rates';
  end if;

  insert into statutory_rate_tables (tenant_id, rate_type, effective_date, band_order, lower_bound, upper_bound, rate, base_tax) values
    (v_tenant_id, 'paye', p_effective_date, 1, 0, 335000, 0, 0),
    (v_tenant_id, 'paye', p_effective_date, 2, 335000, 410000, 10, 0),
    (v_tenant_id, 'paye', p_effective_date, 3, 410000, 10000000, 20, 7500),
    (v_tenant_id, 'paye', p_effective_date, 4, 10000000, null, 30, 1927500),
    (v_tenant_id, 'nssf_employee', p_effective_date, 1, 0, null, 5, 0),
    (v_tenant_id, 'nssf_employer', p_effective_date, 1, 0, null, 10, 0);
end;
$$;

grant execute on function public.seed_statutory_rate_table(date) to authenticated;