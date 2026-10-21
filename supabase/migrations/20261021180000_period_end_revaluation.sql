-- Phase A, A3 slice 3e (see docs/insurance-brokerage/CURRENCY_REVIEW.md): period-end
-- revaluation of foreign monetary balances.
--
-- Accounting policy (as recorded for the accountant): monetary items are revalued at the
-- closing rate; the difference to the booked value goes to profit and loss as unrealised
-- gain or loss; original rates are never overwritten. The revaluation is a memo journal:
-- the next run reverses the previous one first, so at most one live revaluation journal
-- exists per company and open items keep their booked rates throughout.
--
-- What this adds:
--   1. Posting roles 'fx_gain_unrealised' and 'fx_loss_unrealised'. The insurance template
--      gets revenue account 4901 and expense account 5911 with their rules, and existing
--      insurance companies are backfilled unless the code is already used for something
--      else (same convention as the realised accounts in slice 3b).
--   2. fx_revaluation_runs: one row per run, with the per-account detail. A run revalues
--      every foreign monetary balance it can see: control accounts with outstanding open
--      items, foreign bank account GLs, and the unearned-commission account (whose small
--      base residues from 3d-2/3d-3 are exactly what this slice was to clear). A balance
--      is revalued at the approved rate for the run date; unrealised = balance x closing
--      rate - booked base. Non-zero movements post one balanced journal in the functional
--      currency (a debit to the account and a credit to the gain for a positive move, a
--      debit to the loss and a credit to the account for a negative one).
--   3. fin_revalue_fx: the Finance RPC. All-or-nothing: every involved currency must have
--      an approved rate for the run date or nothing is written. Re-running the same date
--      while a run is live is refused (void it first). A company without foreign balances
--      gets a run with no journal.
--   4. fin_void_fx_revaluation: reverses the live run's journal exactly (reversal mode).
--
-- Still open in A3: foreign-currency bank reconciliation, then the UGX column defaults
-- and the 8-versus-10-decimal rate question before any non-UGX company is enabled.

-- =====================================================================
-- A. Posting roles
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
    'fx_rounding',
    'fx_gain_realised', 'fx_loss_realised',
    'fx_gain_unrealised', 'fx_loss_unrealised'
  ));

-- Kept identical to the CHECK above (a test holds the two together).
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
    'fx_gain_unrealised', 'fx_loss_unrealised'
  ]::text[];
$$;
revoke all on function public.platform_gl_posting_roles() from public, anon;
grant execute on function public.platform_gl_posting_roles() to authenticated;

-- =====================================================================
-- B. Insurance template and existing insurance companies
-- =====================================================================
insert into public.industry_template_items (template_key, kind, sort_order, name, payload)
select 'insurance', v.kind, v.sort_order, v.name, v.payload
from (values
  ('gl_account',   25, '4901',
     '{"name": "Unrealised Foreign Exchange Gain", "account_type": "revenue"}'::jsonb),
  ('gl_account',   26, '5911',
     '{"name": "Unrealised Foreign Exchange Loss", "account_type": "expense"}'::jsonb),
  ('posting_rule', 25, 'fx_gain_unrealised', '{"account_code": "4901"}'::jsonb),
  ('posting_rule', 26, 'fx_loss_unrealised', '{"account_code": "5911"}'::jsonb)
) as v(kind, sort_order, name, payload)
where exists (select 1 from public.industry_templates t where t.key = 'insurance')
on conflict (template_key, kind, name) do nothing;

do $$
declare
  t      record;
  v_gl   uuid;
  v_spec record;
begin
  for t in
    select distinct r.tenant_id
      from public.gl_posting_rules r
     where r.account_role = 'insurer_payable'
  loop
    for v_spec in
      select * from (values
        ('fx_gain_unrealised', '4901', 'Unrealised Foreign Exchange Gain', 'revenue', '%gain%'),
        ('fx_loss_unrealised', '5911', 'Unrealised Foreign Exchange Loss', 'expense', '%loss%')
      ) as s(role, code, name, account_type, name_like)
    loop
      if exists (select 1 from public.gl_posting_rules x
                  where x.tenant_id = t.tenant_id and x.account_role = v_spec.role) then
        continue;
      end if;
      select id into v_gl from public.gl_accounts
       where tenant_id = t.tenant_id and account_code = v_spec.code;
      if v_gl is null then
        insert into public.gl_accounts (tenant_id, account_code, name, account_type)
        values (t.tenant_id, v_spec.code, v_spec.name, v_spec.account_type)
        returning id into v_gl;
      elsif not exists (
        select 1 from public.gl_accounts
         where id = v_gl and account_type = v_spec.account_type and is_active
           and name ilike v_spec.name_like
      ) then
        raise notice 'period_end_revaluation: tenant % already uses account code % for something else; map % by hand',
          t.tenant_id, v_spec.code, v_spec.role;
        continue;
      end if;
      insert into public.gl_posting_rules (tenant_id, account_role, gl_account_id)
      values (t.tenant_id, v_spec.role, v_gl)
      on conflict (tenant_id, account_role) do nothing;
    end loop;
  end loop;
end
$$;

-- =====================================================================
-- C. The revaluation journal's source types
-- =====================================================================
alter table public.journal_entries drop constraint if exists journal_entries_source_type_check;
alter table public.journal_entries
  add constraint journal_entries_source_type_check
  check (((source_type = ANY (ARRAY['supplier_invoice'::text, 'receivable_invoice'::text, 'cash_bank_transaction'::text, 'opening_balance'::text, 'manual'::text, 'payroll_run'::text, 'machine_fuel_log'::text, 'machine_maintenance_request'::text, 'fin_settlement'::text, 'fin_settlement_void'::text, 'fin_credit_note'::text, 'fin_credit_note_void'::text, 'ins_policy_bind'::text, 'ins_commission_recognition'::text, 'ins_commission_recognition_reversal'::text, 'ins_commission_transfer'::text, 'ins_commission_transfer_void'::text, 'ins_claim_accrual'::text])) OR (source_type = 'ins_policy_cancellation'::text) OR (source_type = 'ins_cancellation_cash'::text) OR (source_type = 'fx_revaluation'::text) OR (source_type = 'fx_revaluation_void'::text)));

-- =====================================================================
-- D. The run table
-- =====================================================================
create table if not exists public.fx_revaluation_runs (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id),
  as_of date not null,
  status text not null default 'posted',
  detail jsonb not null default '[]'::jsonb,
  journal_entry_id uuid references public.journal_entries(id),
  void_journal_entry_id uuid references public.journal_entries(id),
  void_reason text,
  voided_by uuid,
  voided_at timestamptz,
  posted_by uuid,
  posted_at timestamptz not null default now(),
  accounting_policy_version integer not null default 1
);

comment on table public.fx_revaluation_runs is
  'Period-end FX revaluation runs. One live run per company: a new run reverses the previous journal first. detail carries one row per revalued account: currency, currency balance, booked base, closing rate, unrealised result.';

create unique index if not exists fx_revaluation_runs_live_unique
  on public.fx_revaluation_runs (tenant_id)
  where status = 'posted';

alter table public.fx_revaluation_runs enable row level security;

drop policy if exists "fx_revaluation_runs_select_finance" on public.fx_revaluation_runs;
create policy "fx_revaluation_runs_select_finance" on public.fx_revaluation_runs
  for select using (tenant_id = get_my_tenant_id() and is_finance_team_member(null::text));

grant select on public.fx_revaluation_runs to authenticated;

-- =====================================================================
-- E. The revaluation engine
-- =====================================================================
create or replace function public.platform_fx_revalue_impl(p_tenant_id uuid, p_as_of date)
returns fx_revaluation_runs
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_functional text;
  v_run        fx_revaluation_runs%rowtype;
  v_prior      fx_revaluation_runs%rowtype;
  v_je         journal_entries%rowtype;
  v_gain       uuid := null;
  v_loss       uuid := null;
  v_rate       numeric;
  v_target     numeric;
  v_unrealised numeric;
  v_lines      jsonb := '[]'::jsonb;
  v_detail     jsonb := '[]'::jsonb;
  r            record;
begin
  if p_tenant_id is null then
    raise exception 'tenant id is required';
  end if;
  if p_as_of is null or p_as_of > current_date then
    raise exception 'FX_REVAL_INPUT: a revaluation needs a run date that is not in the future';
  end if;
  if exists (
    select 1 from fx_revaluation_runs
     where tenant_id = p_tenant_id and as_of = p_as_of and status = 'posted'
  ) then
    raise exception 'FX_REVAL_EXISTS: a revaluation for % is already live; void it first', p_as_of;
  end if;

  v_functional := fin_ledger_currency(p_tenant_id);

  -- The previous live run's journal is reversed first, so exactly one revaluation
  -- journal is ever live.
  select * into v_prior
    from fx_revaluation_runs
   where tenant_id = p_tenant_id and status = 'posted' and journal_entry_id is not null
   order by posted_at desc
   limit 1
   for update;

  drop table if exists pg_temp.reval_rows;
  drop table if exists pg_temp.reval_final;
  create temp table reval_rows on commit drop as
    -- Control accounts with outstanding foreign open items (at their booked base).
    select get_posting_account(p_tenant_id, i.control_role) as gl_account_id,
           i.currency, true as from_items,
           sum(case when i.control_role in ('ap_control', 'insurer_payable', 'client_claim_payable')
                    then -b.outstanding_amount else b.outstanding_amount end) as ccy_balance,
           sum(case when i.control_role in ('ap_control', 'insurer_payable', 'client_claim_payable')
                    then -b.base_outstanding_amount else b.base_outstanding_amount end) as base_balance
      from fin_open_items i
      join fin_open_item_balances b on b.id = i.id
     where i.tenant_id = p_tenant_id
       and i.currency is distinct from v_functional
       and b.outstanding_amount > 0
       and i.control_role in ('ar_control', 'ap_control', 'insurer_payable', 'commission_receivable',
                              'insurer_claim_receivable', 'client_claim_payable')
     group by 1, 2
    union all
    -- Foreign bank account GLs.
    select l.gl_account_id, l.currency, false as from_items,
           sum(l.debit - l.credit),
           sum(l.base_debit - l.base_credit)
      from journal_entry_lines l
     where l.tenant_id = p_tenant_id
       and l.currency is distinct from v_functional
       and l.gl_account_id in (
         select b.gl_account_id from fin_bank_accounts b
          where b.tenant_id = p_tenant_id and b.gl_account_id is not null
            and b.currency is distinct from v_functional)
     group by 1, 2
    union all
    -- The unearned-commission account (per currency): the base residues that 3d left
    -- behind are what this run clears.
    select l.gl_account_id, l.currency, false as from_items,
           sum(l.debit - l.credit),
           sum(l.base_debit - l.base_credit)
      from journal_entry_lines l
     where l.tenant_id = p_tenant_id
       and l.currency is distinct from v_functional
       and l.gl_account_id = get_posting_account(p_tenant_id, 'unearned_commission')
     group by 1, 2;

  delete from reval_rows where gl_account_id is null;
  -- A bank GL can also appear through the control set in theory; merge duplicates.
  create temp table reval_final on commit drop as
    select gl_account_id, currency, bool_or(from_items) as from_items,
           sum(ccy_balance) as ccy_balance, sum(base_balance) as base_balance
      from reval_rows
     group by 1, 2;

  -- All-or-nothing: every involved currency must have an approved rate for the run
  -- date before anything is written.
  for r in select distinct currency from reval_final loop
    perform platform_fx_rate(p_tenant_id, r.currency, p_as_of);
  end loop;

  -- The previous live run's journal is reversed BEFORE the movements are measured:
  -- its lines are undone first, so the new journal books exactly what still differs
  -- from the closing rate instead of moving the same balance twice.
  if v_prior.id is not null then
    declare
      v_rev_lines jsonb;
    begin
      select jsonb_agg(jsonb_build_object(
               'gl_account_id', l.gl_account_id, 'debit', l.credit, 'credit', l.debit,
               'currency', l.currency, 'fx_rate', l.fx_rate, 'is_rounding', l.is_rounding,
               'description', 'Reversal of the revaluation at ' || v_prior.as_of))
        into v_rev_lines
        from journal_entry_lines l
       where l.journal_entry_id = v_prior.journal_entry_id;
      perform set_config('fin.reversal_of', v_prior.journal_entry_id::text, true);
      v_je := post_journal_entry(p_tenant_id, 'fx_revaluation_void', v_prior.id, p_as_of,
                                 'Reversal of the FX revaluation at ' || v_prior.as_of, v_rev_lines);
      perform set_config('fin.reversal_of', '', true);
      update fx_revaluation_runs
         set status = 'void', void_journal_entry_id = v_je.id,
             void_reason = 'superseded by the revaluation at ' || p_as_of, voided_at = now()
       where id = v_prior.id;
    end;
  end if;

  -- Measure again on the post-reversal balances.
  drop table if exists pg_temp.reval_rows;
  drop table if exists pg_temp.reval_final;
  create temp table reval_rows on commit drop as
    -- Control accounts with outstanding foreign open items (at their booked base).
    select get_posting_account(p_tenant_id, i.control_role) as gl_account_id,
           i.currency, true as from_items,
           sum(case when i.control_role in ('ap_control', 'insurer_payable', 'client_claim_payable')
                    then -b.outstanding_amount else b.outstanding_amount end) as ccy_balance,
           sum(case when i.control_role in ('ap_control', 'insurer_payable', 'client_claim_payable')
                    then -b.base_outstanding_amount else b.base_outstanding_amount end) as base_balance
      from fin_open_items i
      join fin_open_item_balances b on b.id = i.id
     where i.tenant_id = p_tenant_id
       and i.currency is distinct from v_functional
       and b.outstanding_amount > 0
       and i.control_role in ('ar_control', 'ap_control', 'insurer_payable', 'commission_receivable',
                              'insurer_claim_receivable', 'client_claim_payable')
     group by 1, 2
    union all
    -- Foreign bank account GLs.
    select l.gl_account_id, l.currency, false as from_items,
           sum(l.debit - l.credit),
           sum(l.base_debit - l.base_credit)
      from journal_entry_lines l
     where l.tenant_id = p_tenant_id
       and l.currency is distinct from v_functional
       and l.gl_account_id in (
         select b.gl_account_id from fin_bank_accounts b
          where b.tenant_id = p_tenant_id and b.gl_account_id is not null
            and b.currency is distinct from v_functional)
     group by 1, 2
    union all
    -- The unearned-commission account (per currency): the base residues that 3d left
    -- behind are what this run clears.
    select l.gl_account_id, l.currency, false as from_items,
           sum(l.debit - l.credit),
           sum(l.base_debit - l.base_credit)
      from journal_entry_lines l
     where l.tenant_id = p_tenant_id
       and l.currency is distinct from v_functional
       and l.gl_account_id = get_posting_account(p_tenant_id, 'unearned_commission')
     group by 1, 2;

  delete from reval_rows where gl_account_id is null;
  -- A bank GL can also appear through the control set in theory; merge duplicates.
  create temp table reval_final on commit drop as
    select gl_account_id, currency, bool_or(from_items) as from_items,
           sum(ccy_balance) as ccy_balance, sum(base_balance) as base_balance
      from reval_rows
     group by 1, 2;

  for r in
    select * from reval_final
     where round(ccy_balance * round((platform_fx_rate(p_tenant_id, currency, p_as_of)).rate, 8), 2)
           <> round(base_balance, 2)
     order by gl_account_id, currency
  loop
    v_rate := round((platform_fx_rate(p_tenant_id, r.currency, p_as_of)).rate, 8);
    v_target := round(r.ccy_balance * v_rate, 2);
    v_unrealised := v_target - round(r.base_balance, 2);
    if v_gain is null or v_loss is null then
      v_gain := get_posting_account(p_tenant_id, 'fx_gain_unrealised');
      v_loss := get_posting_account(p_tenant_id, 'fx_loss_unrealised');
      if v_gain is null or v_loss is null then
        raise exception 'FX_UNREALISED_ACCOUNT_MISSING: this company has no fx_gain_unrealised/fx_loss_unrealised accounts under posting rules';
      end if;
    end if;
    v_detail := v_detail || jsonb_build_object(
      'gl_account_id', r.gl_account_id, 'currency', r.currency,
      'currency_balance', r.ccy_balance, 'base_balance', round(r.base_balance, 2),
      'closing_rate', v_rate, 'unrealised_result', v_unrealised);
    -- The account moves towards its closing-rate value; the P&L side books the move.
    v_lines := v_lines || jsonb_build_object(
      'gl_account_id', r.gl_account_id,
      'debit',  greatest(v_unrealised, 0), 'credit', greatest(-v_unrealised, 0),
      'description', format('FX revaluation %s: %s at %s', r.currency, to_char(v_unrealised, 'FM9999999999999990.00'), v_rate));
    v_lines := v_lines || (case when v_unrealised > 0
      then jsonb_build_object('gl_account_id', v_gain, 'credit', v_unrealised,
                              'description', 'Unrealised exchange gain at ' || p_as_of)
      else jsonb_build_object('gl_account_id', v_loss, 'debit', -v_unrealised,
                              'description', 'Unrealised exchange loss at ' || p_as_of) end);
  end loop;

  insert into fx_revaluation_runs (tenant_id, as_of, status, detail, posted_by)
  values (p_tenant_id, p_as_of, 'posted', v_detail, auth.uid())
  returning * into v_run;

  if jsonb_array_length(v_lines) > 0 then
    v_je := post_journal_entry(p_tenant_id, 'fx_revaluation', v_run.id, p_as_of,
                               'FX revaluation at ' || p_as_of, v_lines);
    update fx_revaluation_runs set journal_entry_id = v_je.id where id = v_run.id returning * into v_run;
  end if;

  return v_run;
end;
$function$;
revoke all on function public.platform_fx_revalue_impl(uuid, date) from public, anon, authenticated;

-- =====================================================================
-- F. The Finance RPCs
-- =====================================================================
create or replace function public.fin_revalue_fx(p_as_of date)
returns fx_revaluation_runs
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant uuid := get_my_tenant_id();
begin
  if not is_finance_team_member('finance') then
    raise exception 'FX_REVAL_FORBIDDEN: only Finance can run a revaluation';
  end if;
  return platform_fx_revalue_impl(v_tenant, p_as_of);
end;
$function$;
revoke all on function public.fin_revalue_fx(date) from public, anon;
grant execute on function public.fin_revalue_fx(date) to authenticated;

create or replace function public.fin_void_fx_revaluation(p_run_id uuid, p_reason text)
returns fx_revaluation_runs
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant uuid := get_my_tenant_id();
  v_run    fx_revaluation_runs%rowtype;
  v_lines  jsonb;
  v_je     journal_entries%rowtype;
begin
  if not is_finance_team_member('finance') then
    raise exception 'FX_REVAL_FORBIDDEN: only Finance can void a revaluation';
  end if;
  if p_reason is null or length(btrim(p_reason)) < 5 then
    raise exception 'FX_REVAL_VOID: a reason of at least 5 characters is required';
  end if;

  select * into v_run from fx_revaluation_runs
   where id = p_run_id and tenant_id = v_tenant for update;
  if not found then
    raise exception 'FX_REVAL_VOID: revaluation run not found in this company';
  end if;
  if v_run.status <> 'posted' then
    raise exception 'FX_REVAL_VOID: the run at % is already void', v_run.as_of;
  end if;
  if v_run.journal_entry_id is null then
    -- Nothing was posted; just retire the row.
    update fx_revaluation_runs
       set status = 'void', void_reason = btrim(p_reason), voided_by = auth.uid(), voided_at = now()
     where id = v_run.id
    returning * into v_run;
    return v_run;
  end if;
  if exists (
    select 1 from fx_revaluation_runs
     where tenant_id = v_tenant and status = 'posted' and journal_entry_id is not null
       and posted_at > v_run.posted_at
  ) then
    raise exception 'FX_REVAL_VOID: a newer revaluation is live; void it first';
  end if;

  select jsonb_agg(jsonb_build_object(
           'gl_account_id', l.gl_account_id, 'debit', l.credit, 'credit', l.debit,
           'currency', l.currency, 'fx_rate', l.fx_rate, 'is_rounding', l.is_rounding,
           'description', 'Reversal of the revaluation at ' || v_run.as_of))
    into v_lines
    from journal_entry_lines l
   where l.journal_entry_id = v_run.journal_entry_id;

  perform set_config('fin.reversal_of', v_run.journal_entry_id::text, true);
  v_je := post_journal_entry(v_tenant, 'fx_revaluation_void', v_run.id, current_date,
                             'Void of the FX revaluation at ' || v_run.as_of || ': ' || btrim(p_reason), v_lines);
  perform set_config('fin.reversal_of', '', true);

  update fx_revaluation_runs
     set status = 'void', void_journal_entry_id = v_je.id, void_reason = btrim(p_reason),
         voided_by = auth.uid(), voided_at = now()
   where id = v_run.id
  returning * into v_run;

  return v_run;
end;
$function$;
revoke all on function public.fin_void_fx_revaluation(uuid, text) from public, anon;
grant execute on function public.fin_void_fx_revaluation(uuid, text) to authenticated;

-- The tenant tables drift test requires the read-only guard on the new run table.
select public.apply_tenant_read_only_guard();
