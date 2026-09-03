-- Workstream A (finance GL), phase 1: real chart of accounts + journal
-- entries. Today "trial balance" and "ledger" (v_trial_balance,
-- v_account_ledger) are UNION ALL views stitched from supplier_invoices,
-- receivable_invoices, and cash_bank_transactions -- there is no
-- chart of accounts, no debit=credit enforcement, and `accounts` is
-- the vendor/client contact master, not a COA. This migration adds
-- the real thing underneath; a follow-up migration wires auto-posting
-- triggers, and a later one rebuilds v_trial_balance/v_account_ledger
-- on top of journal_entry_lines instead of the subledger union.
--
-- Design choice: one control-account mapping per tenant
-- (gl_control_accounts), not a per-category/per-cost-center posting
-- rule table. Real SMEs here run one AP control, one AR control, one
-- or two bank/cash accounts -- a generic rule engine would be
-- unused complexity today. If per-category posting is ever needed
-- (e.g. cost-center-specific expense accounts), that's an additive
-- table later; it doesn't require reshaping this one.

create table if not exists public.gl_accounts (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references public.tenants(id) on delete cascade,
    account_code text not null,
    name text not null,
    account_type text not null,
    is_control_account boolean not null default false,
    is_active boolean not null default true,
    created_at timestamp with time zone not null default now(),
    constraint gl_accounts_account_type_check
        check (account_type in ('asset', 'liability', 'equity', 'revenue', 'expense')),
    constraint gl_accounts_tenant_code_unique unique (tenant_id, account_code)
);

comment on table public.gl_accounts is
    'Real chart of accounts (asset/liability/equity/revenue/expense), '
    'distinct from public.accounts which is the vendor/client contact master.';

-- Per-tenant mapping of the control accounts auto-posting needs. One
-- row per tenant. All columns required once a tenant sets this up --
-- auto-posting triggers refuse to post (see next migration) until it
-- exists, rather than guessing or posting to a wrong account.
create table if not exists public.gl_control_accounts (
    tenant_id uuid primary key references public.tenants(id) on delete cascade,
    ap_control_account_id uuid not null references public.gl_accounts(id),
    ar_control_account_id uuid not null references public.gl_accounts(id),
    bank_account_id uuid not null references public.gl_accounts(id),
    cash_account_id uuid not null references public.gl_accounts(id),
    vat_input_account_id uuid not null references public.gl_accounts(id),
    vat_output_account_id uuid not null references public.gl_accounts(id),
    default_expense_account_id uuid not null references public.gl_accounts(id),
    default_revenue_account_id uuid not null references public.gl_accounts(id),
    updated_at timestamp with time zone not null default now()
);

create table if not exists public.journal_entries (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references public.tenants(id) on delete cascade,
    entry_date date not null,
    source_type text not null,
    source_id uuid,
    description text,
    status text not null default 'posted',
    posted_by uuid,
    created_at timestamp with time zone not null default now(),
    constraint journal_entries_source_type_check
        check (source_type in ('supplier_invoice', 'receivable_invoice', 'cash_bank_transaction', 'opening_balance', 'manual')),
    constraint journal_entries_status_check check (status in ('posted', 'void'))
);

-- One journal entry per source row -- a second insert trigger firing
-- for the same supplier_invoice (e.g. a future update-triggered
-- re-post) must not double-post. Partial index since manual entries
-- (source_id null) shouldn't be constrained by this.
create unique index if not exists journal_entries_source_unique
    on public.journal_entries (source_type, source_id)
    where source_id is not null;

create index if not exists journal_entries_tenant_date_idx
    on public.journal_entries (tenant_id, entry_date);

create table if not exists public.journal_entry_lines (
    id uuid primary key default gen_random_uuid(),
    journal_entry_id uuid not null references public.journal_entries(id) on delete cascade,
    tenant_id uuid not null references public.tenants(id) on delete cascade,
    gl_account_id uuid not null references public.gl_accounts(id),
    debit numeric not null default 0,
    credit numeric not null default 0,
    currency text not null default 'UGX',
    description text,
    constraint journal_entry_lines_debit_check check (debit >= 0),
    constraint journal_entry_lines_credit_check check (credit >= 0),
    -- A line is a debit OR a credit, never both, and never neither.
    constraint journal_entry_lines_one_side_check
        check ((debit > 0 and credit = 0) or (credit > 0 and debit = 0))
);

create index if not exists journal_entry_lines_entry_idx
    on public.journal_entry_lines (journal_entry_id);

create index if not exists journal_entry_lines_account_idx
    on public.journal_entry_lines (tenant_id, gl_account_id);

-- Debit = credit enforcement. Postgres has no native cross-row CHECK,
-- so this is a deferred constraint trigger: it fires once at the end
-- of the transaction (after all lines for an entry are inserted),
-- not per-row, so a multi-line entry doesn't fail on its first line.
create or replace function public.check_journal_entry_balanced()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_entry_id uuid;
  v_diff numeric;
begin
  v_entry_id := coalesce(new.journal_entry_id, old.journal_entry_id);

  select coalesce(sum(debit), 0) - coalesce(sum(credit), 0)
    into v_diff
    from journal_entry_lines
    where journal_entry_id = v_entry_id;

  if v_diff != 0 then
    raise exception 'journal entry % is not balanced (debit-credit = %)', v_entry_id, v_diff;
  end if;

  return null;
end;
$$;

drop trigger if exists trg_check_journal_entry_balanced on public.journal_entry_lines;
create constraint trigger trg_check_journal_entry_balanced
    after insert or update or delete on public.journal_entry_lines
    deferrable initially deferred
    for each row
    execute function public.check_journal_entry_balanced();

alter table public.gl_accounts enable row level security;
alter table public.gl_control_accounts enable row level security;
alter table public.journal_entries enable row level security;
alter table public.journal_entry_lines enable row level security;

-- gl_accounts: finance team manages the COA directly, same pattern as
-- public.accounts (accounts_select/insert/update/delete).
create policy "gl_accounts_select" on public.gl_accounts
    for select using (is_finance_team_member(null::text) and tenant_id = get_my_tenant_id());
create policy "gl_accounts_insert" on public.gl_accounts
    for insert with check (is_finance_team_member('finance'::text) and tenant_id = get_my_tenant_id());
create policy "gl_accounts_update" on public.gl_accounts
    for update using (is_finance_team_member('finance'::text) and tenant_id = get_my_tenant_id())
    with check (is_finance_team_member('finance'::text) and tenant_id = get_my_tenant_id());
create policy "gl_accounts_delete" on public.gl_accounts
    for delete using (is_finance_team_member('finance'::text) and tenant_id = get_my_tenant_id());

create policy "gl_control_accounts_select" on public.gl_control_accounts
    for select using (is_finance_team_member(null::text) and tenant_id = get_my_tenant_id());
create policy "gl_control_accounts_insert" on public.gl_control_accounts
    for insert with check (is_finance_team_member('finance'::text) and tenant_id = get_my_tenant_id());
create policy "gl_control_accounts_update" on public.gl_control_accounts
    for update using (is_finance_team_member('finance'::text) and tenant_id = get_my_tenant_id())
    with check (is_finance_team_member('finance'::text) and tenant_id = get_my_tenant_id());
create policy "gl_control_accounts_delete" on public.gl_control_accounts
    for delete using (is_finance_team_member('finance'::text) and tenant_id = get_my_tenant_id());

-- journal_entries / journal_entry_lines: read-only from the app's
-- perspective. Intentionally no insert/update/delete policy for
-- either table -- posting only happens through the SECURITY DEFINER
-- post_journal_entry() helper (next migration), which runs as table
-- owner and bypasses RLS. This keeps the ledger append-only and
-- un-editable from the client, same as an audit log.
create policy "journal_entries_select" on public.journal_entries
    for select using (is_finance_team_member(null::text) and tenant_id = get_my_tenant_id());

create policy "journal_entry_lines_select" on public.journal_entry_lines
    for select using (is_finance_team_member(null::text) and tenant_id = get_my_tenant_id());

grant select, insert, update, delete on public.gl_accounts to authenticated;
grant select, insert, update, delete on public.gl_control_accounts to authenticated;
grant select on public.journal_entries to authenticated;
grant select on public.journal_entry_lines to authenticated;

-- One-time per-tenant starter COA + control account mapping. Finance
-- admin calls this once when turning the GL on for their tenant.
-- Idempotent: no-ops if the tenant already has gl_accounts.
create or replace function public.seed_default_chart_of_accounts()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tenant_id uuid := get_my_tenant_id();
  v_ap uuid; v_ar uuid; v_bank uuid; v_cash uuid;
  v_vat_in uuid; v_vat_out uuid; v_expense uuid; v_revenue uuid;
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
    (v_tenant_id, '4000', 'Sales Revenue', 'revenue', false),
    (v_tenant_id, '5000', 'General Expense', 'expense', false);

  select id into v_bank from gl_accounts where tenant_id = v_tenant_id and account_code = '1000';
  select id into v_cash from gl_accounts where tenant_id = v_tenant_id and account_code = '1010';
  select id into v_ar from gl_accounts where tenant_id = v_tenant_id and account_code = '1100';
  select id into v_vat_in from gl_accounts where tenant_id = v_tenant_id and account_code = '1200';
  select id into v_ap from gl_accounts where tenant_id = v_tenant_id and account_code = '2000';
  select id into v_vat_out from gl_accounts where tenant_id = v_tenant_id and account_code = '2100';
  select id into v_revenue from gl_accounts where tenant_id = v_tenant_id and account_code = '4000';
  select id into v_expense from gl_accounts where tenant_id = v_tenant_id and account_code = '5000';

  insert into gl_control_accounts (
    tenant_id, ap_control_account_id, ar_control_account_id, bank_account_id, cash_account_id,
    vat_input_account_id, vat_output_account_id, default_expense_account_id, default_revenue_account_id
  ) values (
    v_tenant_id, v_ap, v_ar, v_bank, v_cash, v_vat_in, v_vat_out, v_expense, v_revenue
  );
end;
$$;

grant execute on function public.seed_default_chart_of_accounts() to authenticated;
