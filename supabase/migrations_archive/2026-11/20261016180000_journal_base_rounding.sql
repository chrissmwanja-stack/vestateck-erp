-- Phase A, A3 slice 2b (see docs/insurance-brokerage/ROADMAP.md): base-currency
-- rounding on foreign journals.
--
-- Problem (found by test): base amounts are rounded per line, so a journal that
-- balances exactly in its own currency (1.00 = 0.33 + 0.67 at 1.5) can differ by a
-- cent in base currency, and 20261016150000 refuses it with JOURNAL_BASE_UNBALANCED.
-- Any multi-line foreign journal can hit this.
--
-- Decision (accountant answers, ROADMAP): rounding differences go to a dedicated
-- account, not to FX gain and loss.
--
-- What this adds:
--   * posting role 'fx_rounding': the company's rounding account. Set under
--     posting rules like the other roles. The insurance template gets an expense
--     account 5900 'Foreign Exchange Rounding' with the rule, and existing
--     insurance companies get the same unless 5900 is already used for something
--     else (then the company is left alone and notified). The code 5900 is a
--     default chosen here for the accountant to confirm; it is editable per company.
--     A company with no fx_rounding role is refused loudly the first time a foreign
--     journal needs rounding.
--   * journal_entry_lines.is_rounding: marks the line the system adds. A caller
--     cannot set it; a trigger forces it from an internal flag.
--   * check_journal_entry_balanced, extended:
--       1. An entry whose lines all share one currency must balance in that
--          currency, as before, with the same message.
--       2. An entry mixing currencies is no longer required to balance as a raw sum
--          across currencies (that sum is meaningless: USD 10 is not UGX 10). It
--          must balance in base currency instead.
--       3. A base difference is added to the fx_rounding account as a line in the
--          functional currency, only when it is within the most per-line rounding
--          can produce: half a cent per foreign line, rounded up to the cent. That
--          is arithmetic, not a policy figure. A larger difference is a real error
--          and still raises JOURNAL_BASE_UNBALANCED. An entry with no foreign line
--          never gets a rounding line.
--       4. If a rounding line is needed and the company has no fx_rounding role the
--          entry is refused (JOURNAL_ROUNDING_ACCOUNT_MISSING). Nothing is
--          defaulted.
--
-- No existing company's postings change: they have no foreign lines, so rule 1
-- applies exactly as before and no rounding line can arise.

-- =====================================================================
-- A. Posting role
-- =====================================================================
alter table public.gl_posting_rules drop constraint if exists gl_posting_rules_account_role_check;
alter table public.gl_posting_rules
  add constraint gl_posting_rules_account_role_check
  check (account_role in (
    'ap_control', 'ar_control', 'bank', 'cash', 'vat_input', 'vat_output', 'wht_payable',
    'default_expense', 'default_revenue', 'salaries_payable', 'paye_payable', 'nssf_payable',
    'salaries_expense',
    'client_money_bank', 'insurer_payable', 'commission_receivable', 'commission_income',
    'wht_receivable', 'unearned_commission',
    'insurer_claim_receivable', 'client_claim_payable',
    'fx_rounding'
  ));

-- The role list is kept in two places that a test holds identical: the CHECK above
-- and this function (used when applying industry templates).
create or replace function public.platform_gl_posting_roles()
returns text[]
language sql
immutable
set search_path = public, pg_temp
as $$
  select array[
    'ap_control', 'ar_control', 'bank', 'cash', 'vat_input', 'vat_output', 'wht_payable',
    'default_expense', 'default_revenue', 'salaries_payable', 'paye_payable', 'nssf_payable',
    'salaries_expense',
    'client_money_bank', 'insurer_payable', 'commission_receivable', 'commission_income',
    'wht_receivable',
    'unearned_commission',
    'insurer_claim_receivable', 'client_claim_payable',
    'fx_rounding'
  ]::text[];
$$;
revoke all on function public.platform_gl_posting_roles() from public, anon;
grant execute on function public.platform_gl_posting_roles() to authenticated;

-- =====================================================================
-- B. Marking the system's rounding line
-- =====================================================================
alter table public.journal_entry_lines
  add column if not exists is_rounding boolean not null default false;

comment on column public.journal_entry_lines.is_rounding is
  'True only for the line the system adds to absorb base-currency rounding. Set by an internal trigger, never by the caller.';

create or replace function public.journal_lines_rounding_flag()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.is_rounding := coalesce(current_setting('fin.rounding_line', true), '') = 'on';
  return new;
end;
$$;

revoke all on function public.journal_lines_rounding_flag() from public, anon, authenticated;

drop trigger if exists journal_entry_lines_rounding_flag on public.journal_entry_lines;
create trigger journal_entry_lines_rounding_flag
  before insert on public.journal_entry_lines
  for each row execute function public.journal_lines_rounding_flag();

-- =====================================================================
-- C. Balance check with base rounding
-- =====================================================================
create or replace function public.check_journal_entry_balanced()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_entry_id   uuid;
  v_tenant     uuid;
  v_diff       numeric;
  v_base       numeric;
  v_currencies integer;
  v_foreign    integer;
  v_tolerance  numeric;
  v_account    uuid;
begin
  v_entry_id := coalesce(new.journal_entry_id, old.journal_entry_id);
  v_tenant   := coalesce(new.tenant_id, old.tenant_id);

  select coalesce(sum(debit), 0) - coalesce(sum(credit), 0),
         coalesce(sum(base_debit), 0) - coalesce(sum(base_credit), 0),
         count(distinct currency),
         count(*) filter (where fx_rate <> 1)
    into v_diff, v_base, v_currencies, v_foreign
    from journal_entry_lines
   where journal_entry_id = v_entry_id;

  -- One currency on every line: balance in that currency, message unchanged.
  if v_currencies <= 1 and v_diff <> 0 then
    raise exception 'journal entry % is not balanced (debit-credit = %)', v_entry_id, v_diff;
  end if;

  if v_base <> 0 then
    -- Most that per-line rounding to 2 places can leave: half a cent per foreign line.
    v_tolerance := ceil(v_foreign * 0.5) * 0.01;
    if v_foreign = 0 or abs(v_base) > v_tolerance then
      raise exception 'JOURNAL_BASE_UNBALANCED: journal entry % does not balance in base currency (difference %)', v_entry_id, v_base;
    end if;

    select gl_account_id into v_account
      from gl_posting_rules
     where tenant_id = v_tenant and account_role = 'fx_rounding';
    if v_account is null then
      raise exception 'JOURNAL_ROUNDING_ACCOUNT_MISSING: journal entry % differs by % in base currency from rounding, and this company has no fx_rounding account under posting rules', v_entry_id, v_base;
    end if;

    perform set_config('fin.rounding_line', 'on', true);
    insert into journal_entry_lines
      (journal_entry_id, tenant_id, gl_account_id, debit, credit, currency, description)
    values
      (v_entry_id, v_tenant, v_account,
       greatest(-v_base, 0), greatest(v_base, 0),
       fin_ledger_currency(v_tenant), 'Base-currency rounding');
    perform set_config('fin.rounding_line', 'off', true);
  end if;

  return null;
end;
$$;

-- =====================================================================
-- D. Insurance template and existing insurance companies
-- =====================================================================
-- The platform keeps every posting role mapped in the insurance template, as the
-- earlier role migrations did.
insert into public.industry_template_items (template_key, kind, sort_order, name, payload)
select 'insurance', v.kind, v.sort_order, v.name, v.payload
from (values
  ('gl_account',   22, '5900',
     '{"name": "Foreign Exchange Rounding", "account_type": "expense"}'::jsonb),
  ('posting_rule', 22, 'fx_rounding', '{"account_code": "5900"}'::jsonb)
) as v(kind, sort_order, name, payload)
where exists (select 1 from public.industry_templates t where t.key = 'insurance')
on conflict (template_key, kind, name) do nothing;

-- Existing insurance companies (identified, as before, by the insurer_payable rule).
do $$
declare
  t    record;
  v_gl uuid;
begin
  for t in
    select distinct r.tenant_id
      from public.gl_posting_rules r
     where r.account_role = 'insurer_payable'
       and not exists (
         select 1 from public.gl_posting_rules x
          where x.tenant_id = r.tenant_id and x.account_role = 'fx_rounding')
  loop
    select id into v_gl from public.gl_accounts
     where tenant_id = t.tenant_id and account_code = '5900';
    if v_gl is null then
      insert into public.gl_accounts (tenant_id, account_code, name, account_type)
      values (t.tenant_id, '5900', 'Foreign Exchange Rounding', 'expense')
      returning id into v_gl;
    elsif not exists (
      select 1 from public.gl_accounts
       where id = v_gl and account_type = 'expense' and is_active
         and name ilike '%rounding%'
    ) then
      raise notice 'journal_base_rounding: tenant % already uses account code 5900 for something else; map fx_rounding by hand', t.tenant_id;
      continue;
    end if;
    insert into public.gl_posting_rules (tenant_id, account_role, gl_account_id)
    values (t.tenant_id, 'fx_rounding', v_gl)
    on conflict (tenant_id, account_role) do nothing;
  end loop;
end
$$;