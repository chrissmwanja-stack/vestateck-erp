-- =====================================================================
-- Prerequisites for 20261108030000_ins_import_opening_position.sql.
--
-- ins_import_post_opening_position needs three things that did not exist:
--   A. a posting role 'opening_balance_clearing' (the CHECK on
--      gl_posting_rules and platform_gl_posting_roles() did not allow it, so
--      no tenant could ever map it and the RPC always raised
--      INS_POSTING_RULE_MISSING);
--   B. the journal source type 'ins_import_opening' (journal_entries_source_
--      type_check rejected the opening journal);
--   C. a clearing account in the insurance template (3900, equity), mapped for
--      new tenants by apply_template and backfilled for existing insurance
--      tenants the same way 20261021180000 did for the unrealised-FX roles.
-- The two role lists stay identical (a test holds them together).
-- =====================================================================

-- A. Posting role --------------------------------------------------------
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
    'fx_rounding',
    'fx_gain_realised', 'fx_loss_realised',
    'fx_gain_unrealised', 'fx_loss_unrealised',
    'opening_balance_clearing'
  ));

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
    'fx_rounding',
    'fx_gain_realised', 'fx_loss_realised',
    'fx_gain_unrealised', 'fx_loss_unrealised',
    'opening_balance_clearing'
  ]::text[];
$$;
revoke all on function public.platform_gl_posting_roles() from public, anon;
grant execute on function public.platform_gl_posting_roles() to authenticated;

-- B. Journal source type -------------------------------------------------
alter table public.journal_entries drop constraint if exists journal_entries_source_type_check;
alter table public.journal_entries
  add constraint journal_entries_source_type_check check (
    source_type = any (array[
      'supplier_invoice'::text, 'receivable_invoice'::text, 'cash_bank_transaction'::text,
      'opening_balance'::text, 'manual'::text, 'payroll_run'::text,
      'machine_fuel_log'::text, 'machine_maintenance_request'::text,
      'fin_settlement'::text, 'fin_settlement_void'::text,
      'fin_credit_note'::text, 'fin_credit_note_void'::text,
      'ins_policy_bind'::text, 'ins_commission_recognition'::text,
      'ins_commission_recognition_reversal'::text, 'ins_commission_transfer'::text,
      'ins_commission_transfer_void'::text, 'ins_claim_accrual'::text,
      'ins_policy_cancellation'::text, 'ins_cancellation_cash'::text,
      'fx_revaluation'::text, 'fx_revaluation_void'::text,
      'ins_policy_endorsement'::text, 'ins_import_opening'::text
    ])
  );

-- C. Template account + rule, and existing insurance tenants -------------
insert into public.industry_template_items (template_key, kind, sort_order, name, payload)
select 'insurance', v.kind, v.sort_order, v.name, v.payload
from (values
  ('gl_account',   30, '3900',
     '{"name": "Opening Balance Clearing", "account_type": "equity"}'::jsonb),
  ('posting_rule', 30, 'opening_balance_clearing', '{"account_code": "3900"}'::jsonb)
) as v(kind, sort_order, name, payload)
where exists (select 1 from public.industry_templates t where t.key = 'insurance')
on conflict (template_key, kind, name) do nothing;

do $$
declare
  t    record;
  v_gl uuid;
begin
  for t in
    select distinct r.tenant_id
      from public.gl_posting_rules r
     where r.account_role = 'insurer_payable'
  loop
    if exists (select 1 from public.gl_posting_rules x
                where x.tenant_id = t.tenant_id and x.account_role = 'opening_balance_clearing') then
      continue;
    end if;
    select id into v_gl from public.gl_accounts
     where tenant_id = t.tenant_id and account_code = '3900';
    if v_gl is null then
      insert into public.gl_accounts (tenant_id, account_code, name, account_type)
      values (t.tenant_id, '3900', 'Opening Balance Clearing', 'equity')
      returning id into v_gl;
    elsif not exists (
      select 1 from public.gl_accounts
       where id = v_gl and account_type = 'equity' and is_active
         and name ilike '%clearing%'
    ) then
      raise notice 'ins_import_opening_prerequisites: tenant % already uses account code 3900 for something else; map opening_balance_clearing by hand',
        t.tenant_id;
      continue;
    end if;
    insert into public.gl_posting_rules (tenant_id, account_role, gl_account_id)
    values (t.tenant_id, 'opening_balance_clearing', v_gl)
    on conflict (tenant_id, account_role) do nothing;
  end loop;
end
$$;