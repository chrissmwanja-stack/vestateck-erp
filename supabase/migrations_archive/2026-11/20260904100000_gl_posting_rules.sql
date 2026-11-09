-- Workstream A follow-up: replace the fixed-column gl_control_accounts
-- with a role-keyed gl_posting_rules table, per the original plan's
-- "per-tenant mapping of transaction type -> control accounts, so
-- posting isn't hardcoded per tenant's COA."
--
-- What this does and doesn't change:
--   - The SET of roles a transaction type can reference (ap_control,
--     vat_input, wht_payable, etc.) is still defined in code, inside
--     the trigger functions. That's real accounting logic -- which
--     lines a supplier invoice produces -- and isn't something an SME
--     bookkeeper should be redefining from a settings screen.
--   - What WAS hardcoded and is now data: which specific gl_account_id
--     fills each role, per tenant. Previously that meant one column
--     per role (add a role = ALTER TABLE + trigger rewrite). Now it's
--     one row per role (add a role = one more accepted account_role
--     value, no schema change).
--   - Net effect: adding a new role (e.g. a second expense category
--     mapped to a different account by transaction subtype) is still a
--     small trigger-function change, but no longer also a migration
--     and an admin-screen rewrite.
--
-- Safe to cut over cleanly, no dual-write/compat period needed:
-- zero tenants have ever called seed_default_chart_of_accounts(), so
-- gl_control_accounts has zero rows in production. This migration
-- drops it outright rather than carrying two representations forward.

create table if not exists public.gl_posting_rules (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references public.tenants(id) on delete cascade,
    account_role text not null,
    gl_account_id uuid not null references public.gl_accounts(id),
    created_at timestamp with time zone not null default now(),
    updated_at timestamp with time zone not null default now(),
    constraint gl_posting_rules_tenant_role_unique unique (tenant_id, account_role),
    constraint gl_posting_rules_account_role_check check (account_role in (
        'ap_control', 'ar_control', 'bank', 'cash',
        'vat_input', 'vat_output', 'wht_payable',
        'default_expense', 'default_revenue',
        'salaries_payable', 'paye_payable', 'nssf_payable', 'salaries_expense'
    ))
);

comment on table public.gl_posting_rules is
    'Per-tenant mapping of posting role -> gl_account_id. Replaces the fixed-column gl_control_accounts. The set of valid account_role values is enforced here and consumed by get_posting_account() -- adding a new role only needs a CHECK-constraint update and a trigger-function change, not a new column everywhere.';

create index if not exists gl_posting_rules_tenant_idx
    on public.gl_posting_rules (tenant_id, account_role);

alter table public.gl_posting_rules enable row level security;

create policy "gl_posting_rules_select" on public.gl_posting_rules
    for select using (is_finance_team_member(null::text) and tenant_id = get_my_tenant_id());
create policy "gl_posting_rules_insert" on public.gl_posting_rules
    for insert with check (is_finance_team_member('finance'::text) and tenant_id = get_my_tenant_id());
create policy "gl_posting_rules_update" on public.gl_posting_rules
    for update using (is_finance_team_member('finance'::text) and tenant_id = get_my_tenant_id())
    with check (is_finance_team_member('finance'::text) and tenant_id = get_my_tenant_id());
create policy "gl_posting_rules_delete" on public.gl_posting_rules
    for delete using (is_finance_team_member('finance'::text) and tenant_id = get_my_tenant_id());

grant select, insert, update, delete on public.gl_posting_rules to authenticated;

create trigger trg_touch_gl_posting_rules_updated_at
    before update on public.gl_posting_rules
    for each row execute function public.touch_updated_at();
-- NOTE: assumes a shared touch_updated_at() trigger function already
-- exists in this schema (the same pattern used by receivable_invoices/
-- supplier_invoices' touch_*_updated_at triggers) -- confirm the exact
-- function name in the live schema before applying; substitute if it's
-- named differently.

-- Single lookup point every trigger calls instead of selecting a fixed
-- column off gl_control_accounts. Returns null (not an exception) when
-- unmapped, so the "skip posting, don't guess" pattern in the trigger
-- functions keeps working unchanged.
create or replace function public.get_posting_account(p_tenant_id uuid, p_role text)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select gl_account_id from gl_posting_rules
  where tenant_id = p_tenant_id and account_role = p_role;
$$;

grant execute on function public.get_posting_account(uuid, text) to authenticated;

-- Re-point the three posting triggers at get_posting_account() instead
-- of a gl_control_accounts row. Same logic, same "skip if any required
-- role is unmapped" behavior -- just sourced from rows, not columns.
create or replace function public.trg_post_supplier_invoice()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_expense uuid; v_vat_in uuid; v_wht uuid; v_ap uuid;
  v_net numeric;
  v_ap_amount numeric;
  v_lines jsonb;
begin
  v_expense := get_posting_account(new.tenant_id, 'default_expense');
  v_ap := get_posting_account(new.tenant_id, 'ap_control');
  if v_expense is null or v_ap is null then
    -- Tenant hasn't set up (or hasn't finished setting up) their
    -- posting rules yet -- skip posting rather than fail the insert.
    return new;
  end if;

  if new.wht_amount > 0 then
    v_wht := get_posting_account(new.tenant_id, 'wht_payable');
    if v_wht is null then
      -- Can't post correctly without knowing where the withheld
      -- amount goes -- skip the whole entry.
      return new;
    end if;
  end if;

  v_net := new.amount_incl_vat - new.vat_amount;
  v_ap_amount := new.amount_incl_vat - new.wht_amount;

  v_lines := jsonb_build_array(
    jsonb_build_object('gl_account_id', v_expense, 'debit', v_net)
  );
  if new.vat_amount > 0 then
    v_vat_in := get_posting_account(new.tenant_id, 'vat_input');
    if v_vat_in is null then
      return new;
    end if;
    v_lines := v_lines || jsonb_build_object('gl_account_id', v_vat_in, 'debit', new.vat_amount);
  end if;
  if new.wht_amount > 0 then
    v_lines := v_lines || jsonb_build_object('gl_account_id', v_wht, 'credit', new.wht_amount);
  end if;
  if v_ap_amount > 0 then
    v_lines := v_lines || jsonb_build_object('gl_account_id', v_ap, 'credit', v_ap_amount);
  end if;

  perform post_journal_entry(new.tenant_id, 'supplier_invoice', new.id, new.invoice_date,
    'Supplier invoice ' || new.invoice_number, v_lines);

  return new;
end;
$$;

create or replace function public.trg_post_receivable_invoice()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ar uuid; v_revenue uuid; v_vat_out uuid;
  v_net numeric;
  v_lines jsonb;
begin
  v_ar := get_posting_account(new.tenant_id, 'ar_control');
  v_revenue := get_posting_account(new.tenant_id, 'default_revenue');
  if v_ar is null or v_revenue is null then
    return new;
  end if;

  v_net := new.amount_incl_vat - new.vat_amount;

  v_lines := jsonb_build_array(
    jsonb_build_object('gl_account_id', v_ar, 'debit', new.amount_incl_vat),
    jsonb_build_object('gl_account_id', v_revenue, 'credit', v_net)
  );
  if new.vat_amount > 0 then
    v_vat_out := get_posting_account(new.tenant_id, 'vat_output');
    if v_vat_out is null then
      return new;
    end if;
    v_lines := v_lines || jsonb_build_object('gl_account_id', v_vat_out, 'credit', new.vat_amount);
  end if;

  perform post_journal_entry(new.tenant_id, 'receivable_invoice', new.id, new.invoice_date,
    'Receivable invoice ' || new.invoice_number, v_lines);

  return new;
end;
$$;

create or replace function public.trg_post_cash_bank_transaction()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cash_side uuid;
  v_other_side uuid;
  v_other_role text;
  v_lines jsonb;
begin
  v_other_role := case new.reference_type
    when 'supplier_invoice' then 'ap_control'
    when 'receivable_invoice' then 'ar_control'
    when 'expenditure_slip' then 'default_expense'
    when 'payroll_run' then 'salaries_payable'
    else null
  end;
  if v_other_role is null then
    return new;
  end if;

  v_cash_side := get_posting_account(new.tenant_id, case when new.payment_method = 'bank' then 'bank' else 'cash' end);
  v_other_side := get_posting_account(new.tenant_id, v_other_role);
  if v_cash_side is null or v_other_side is null then
    return new;  -- e.g. this role not mapped yet
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

-- Fourth posting trigger found on hr_payroll_runs (approval, not
-- disbursement -- disbursement is trg_post_cash_bank_transaction()
-- above, already covered) that also reads gl_control_accounts
-- directly. Same re-point, same all-four-or-skip posture.
create or replace function public.trg_post_payroll_run_approval()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_salaries_expense uuid; v_salaries_payable uuid; v_paye_payable uuid; v_nssf_payable uuid;
  v_totals record;
  v_lines jsonb;
begin
  if new.status != 'approved' or old.status = 'approved' then
    return new;
  end if;

  v_salaries_expense := get_posting_account(new.tenant_id, 'salaries_expense');
  v_salaries_payable := get_posting_account(new.tenant_id, 'salaries_payable');
  v_paye_payable := get_posting_account(new.tenant_id, 'paye_payable');
  v_nssf_payable := get_posting_account(new.tenant_id, 'nssf_payable');
  if v_salaries_expense is null or v_salaries_payable is null
     or v_paye_payable is null or v_nssf_payable is null then
    -- Payroll roles not fully mapped yet -- skip posting rather than
    -- guess. The run still approves normally.
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
    jsonb_build_object('gl_account_id', v_salaries_expense, 'debit', v_totals.gross_expense)
  );
  if v_totals.employer_nssf > 0 then
    v_lines := v_lines || jsonb_build_object('gl_account_id', v_salaries_expense, 'debit', v_totals.employer_nssf);
  end if;
  if v_totals.total_net_pay > 0 then
    v_lines := v_lines || jsonb_build_object('gl_account_id', v_salaries_payable, 'credit', v_totals.total_net_pay);
  end if;
  if v_totals.total_paye > 0 then
    v_lines := v_lines || jsonb_build_object('gl_account_id', v_paye_payable, 'credit', v_totals.total_paye);
  end if;
  if v_totals.total_nssf > 0 then
    v_lines := v_lines || jsonb_build_object('gl_account_id', v_nssf_payable, 'credit', v_totals.total_nssf);
  end if;

  perform post_journal_entry(new.tenant_id, 'payroll_run', new.id, coalesce(new.approved_at::date, current_date),
    'Payroll run ' || new.period, v_lines);

  return new;
end;
$$;
-- Trigger itself (drop/create on hr_payroll_runs) is unchanged --
-- only the function body above needed to move off gl_control_accounts.

-- Re-point the chart-of-accounts seed function to insert
-- gl_posting_rules rows instead of one gl_control_accounts row.
create or replace function public.seed_default_chart_of_accounts()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tenant_id uuid := get_my_tenant_id();
  v_bank uuid; v_cash uuid; v_ar uuid; v_vat_in uuid;
  v_ap uuid; v_vat_out uuid; v_wht uuid;
  v_salaries_payable uuid; v_paye_payable uuid; v_nssf_payable uuid;
  v_revenue uuid; v_expense uuid; v_salaries_expense uuid;
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

  insert into gl_posting_rules (tenant_id, account_role, gl_account_id) values
    (v_tenant_id, 'bank', v_bank),
    (v_tenant_id, 'cash', v_cash),
    (v_tenant_id, 'ar_control', v_ar),
    (v_tenant_id, 'vat_input', v_vat_in),
    (v_tenant_id, 'ap_control', v_ap),
    (v_tenant_id, 'vat_output', v_vat_out),
    (v_tenant_id, 'wht_payable', v_wht),
    (v_tenant_id, 'salaries_payable', v_salaries_payable),
    (v_tenant_id, 'paye_payable', v_paye_payable),
    (v_tenant_id, 'nssf_payable', v_nssf_payable),
    (v_tenant_id, 'default_revenue', v_revenue),
    (v_tenant_id, 'default_expense', v_expense),
    (v_tenant_id, 'salaries_expense', v_salaries_expense);
end;
$$;

-- gl_control_accounts drops last, after nothing references it anymore.
-- Zero rows in production (see header) -- no backfill needed.
drop table if exists public.gl_control_accounts cascade;