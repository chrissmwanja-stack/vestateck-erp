-- Phase A, A3 slice 3b (see docs/insurance-brokerage/CURRENCY_REVIEW.md): realised
-- foreign-exchange gain and loss at settlement.
--
-- Accounting rule (accountant answers, ROADMAP): a monetary item is settled at the
-- rate it was recognised at; the difference between that and the actual settlement
-- rate goes to profit and loss; original rates are never overwritten.
--
-- What this adds:
--   1. Posting roles 'fx_gain_realised' and 'fx_loss_realised'. The insurance template
--      gets revenue account 4900 "Realised Foreign Exchange Gain" and expense account
--      5910 "Realised Foreign Exchange Loss" with their rules, and existing insurance
--      companies get the same unless the code is already used for something else (then
--      the company is left alone and notified). The codes are defaults chosen here for
--      the accountant to confirm; they are editable per company.
--   2. A per-line rate source in the posting gateway. A line may carry
--      'rate_from_entry' (a journal entry id) and 'fx_rate'. The line guard then keeps
--      that rate only if that entry (same company) has a line in the same currency at
--      exactly that rate (JOURNAL_LINE_RATE otherwise). This is how the settled side of
--      a settlement uses the original rate while the cash side uses the settlement-date
--      rate. It applies to that one line only, through an internal setting
--      (fin.rate_from) that the gateway sets and clears around the insert; no client can
--      call the gateway.
--   3. platform_fx_settlement: the calculation. Given the amount, the original rate and
--      the settlement date it returns the settlement rate, the base amounts at both rates
--      (rounded exactly as the ledger rounds line base amounts) and the result (positive
--      is a gain, negative a loss).
--   4. platform_fx_realised_line: the journal line that books a result, in the
--      functional currency, on the gain or loss account. Nothing is defaulted: a company
--      without the role is refused (FX_REALISED_ACCOUNT_MISSING).
--   5. trg_post_cash_bank_transaction now settles at the invoice's original rate. For a
--      payment against a supplier invoice or a receipt against a receivable invoice in a
--      foreign currency, the invoice side is booked at the rate the invoice was booked
--      at, the cash side at the settlement-date rate, and the difference as realised gain
--      or loss. This removes the base-currency residue that slice 3a documented.
--      Also: a transaction whose currency differs from its invoice's is refused
--      (CASH_CURRENCY_MISMATCH), and a payroll payment in a foreign currency is refused
--      (CASH_PAYROLL_CURRENCY), because payroll is accrued in the functional currency.
--      Functional-currency transactions are unchanged.
--
-- Not in this migration: insurance settlements (fin_settlements), credit notes and the
-- currency guards; those are slices 3c and 3d and will use the functions added here.

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
    'fx_gain_realised', 'fx_loss_realised'
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
    'fx_gain_realised', 'fx_loss_realised'
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
  ('gl_account',   23, '4900',
     '{"name": "Realised Foreign Exchange Gain", "account_type": "revenue"}'::jsonb),
  ('gl_account',   24, '5910',
     '{"name": "Realised Foreign Exchange Loss", "account_type": "expense"}'::jsonb),
  ('posting_rule', 23, 'fx_gain_realised', '{"account_code": "4900"}'::jsonb),
  ('posting_rule', 24, 'fx_loss_realised', '{"account_code": "5910"}'::jsonb)
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
        ('fx_gain_realised', '4900', 'Realised Foreign Exchange Gain', 'revenue', '%gain%'),
        ('fx_loss_realised', '5910', 'Realised Foreign Exchange Loss', 'expense', '%loss%')
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
        raise notice 'realised_fx: tenant % already uses account code % for something else; map % by hand',
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
-- C. Line guard: a per-line rate source
-- =====================================================================
create or replace function public.journal_lines_fx_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_date       date;
  v_functional text;
  v_currency   text;
  v_orig       text := nullif(current_setting('fin.reversal_of', true), '');
  v_from       text := nullif(current_setting('fin.rate_from', true), '');
begin
  select entry_date into v_date
    from journal_entries
   where id = new.journal_entry_id and tenant_id = new.tenant_id;
  if v_date is null then
    raise exception 'JOURNAL_LINE: entry % does not belong to this company', new.journal_entry_id;
  end if;

  v_functional := fin_ledger_currency(new.tenant_id);
  v_currency   := coalesce(nullif(btrim(new.currency), ''), v_functional);
  new.currency := v_currency;

  if v_currency = v_functional then
    new.fx_rate := 1;
  elsif v_from is not null or v_orig is not null then
    -- A reversal, or a line that settles an earlier entry: keep the supplied rate only
    -- if that entry has a line in the same currency at exactly that rate.
    if not exists (
      select 1 from journal_entry_lines
       where journal_entry_id = coalesce(v_from, v_orig)::uuid
         and tenant_id = new.tenant_id
         and currency = v_currency
         and fx_rate = new.fx_rate
    ) then
      raise exception 'JOURNAL_LINE_RATE: a line can only use a % rate that the entry it refers to already used', v_currency;
    end if;
  else
    new.fx_rate := (platform_fx_rate(new.tenant_id, v_currency, v_date)).rate;
  end if;
  return new;
end;
$$;
revoke all on function public.journal_lines_fx_guard() from public, anon, authenticated;

-- =====================================================================
-- D. Gateway: honour 'rate_from_entry' on a line
-- =====================================================================
create or replace function public.post_journal_entry(
  p_tenant_id uuid,
  p_source_type text,
  p_source_id uuid,
  p_entry_date date,
  p_description text,
  p_lines jsonb
)
returns journal_entries
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $function$
declare
  v_entry journal_entries%rowtype;
  v_line jsonb;
  v_bad_accounts int;
  v_reversal boolean := nullif(current_setting('fin.reversal_of', true), '') is not null;
  v_rate numeric;
  v_rounding boolean;
  v_from text;
begin
  if p_tenant_id is null then
    raise exception 'tenant id is required';
  end if;

  -- When called inside a user session (auth.uid() present), the tenant must be the
  -- caller's effective tenant. get_my_tenant_id() already honours active impersonation.
  -- Service-role / cron contexts have no auth.uid() and are skipped.
  if auth.uid() is not null
     and p_tenant_id is distinct from public.get_my_tenant_id() then
    raise exception 'not authorized to post journals for this tenant'
      using errcode = '42501';
  end if;

  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'journal must have at least one line';
  end if;

  -- Every referenced GL account must belong to this tenant.
  select count(*) into v_bad_accounts
  from jsonb_array_elements(p_lines) l
  left join gl_accounts ga
    on ga.id = (l ->> 'gl_account_id')::uuid
   and ga.tenant_id = p_tenant_id
  where ga.id is null;

  if v_bad_accounts > 0 then
    raise exception 'one or more GL accounts do not belong to this tenant'
      using errcode = '42501';
  end if;

  if exists (
    select 1 from accounting_periods
    where tenant_id = p_tenant_id
      and status = 'closed'
      and p_entry_date between period_start and period_end
  ) then
    raise exception 'cannot post to %: this date falls in a closed accounting period', p_entry_date;
  end if;

  insert into journal_entries (tenant_id, entry_date, source_type, source_id, description, posted_by)
  values (p_tenant_id, p_entry_date, p_source_type, p_source_id, p_description, auth.uid())
  returning * into v_entry;

  for v_line in select * from jsonb_array_elements(p_lines)
  loop
    -- The rate is set by the line guard from the approved rate table. Two internal
    -- exceptions, both checked by the guard against an earlier entry: a reversal
    -- (fin.reversal_of, set by void_journal_entry) and a single line that names the
    -- entry it settles ('rate_from_entry' with 'fx_rate').
    v_from     := nullif(v_line ->> 'rate_from_entry', '');
    v_rate     := case when v_reversal or v_from is not null
                       then coalesce((v_line ->> 'fx_rate')::numeric, 1) else 1 end;
    v_rounding := v_reversal and coalesce((v_line ->> 'is_rounding')::boolean, false);

    if v_rounding then
      perform set_config('fin.rounding_line', 'on', true);
    end if;
    if v_from is not null then
      perform set_config('fin.rate_from', v_from, true);
    end if;

    insert into journal_entry_lines
      (journal_entry_id, tenant_id, gl_account_id, debit, credit, description, currency, fx_rate)
    values (
      v_entry.id,
      p_tenant_id,
      (v_line ->> 'gl_account_id')::uuid,
      coalesce((v_line ->> 'debit')::numeric, 0),
      coalesce((v_line ->> 'credit')::numeric, 0),
      v_line ->> 'description',
      nullif(btrim(v_line ->> 'currency'), ''),
      v_rate
    );

    if v_rounding then
      perform set_config('fin.rounding_line', 'off', true);
    end if;
    if v_from is not null then
      perform set_config('fin.rate_from', '', true);
    end if;
  end loop;

  return v_entry;
end;
$function$;

revoke execute on function public.post_journal_entry(uuid, text, uuid, date, text, jsonb)
  from public, anon, authenticated;

-- =====================================================================
-- E. The settlement calculation and the realised line
-- =====================================================================
-- Result is positive for a gain and negative for a loss, from the company's side.
-- p_settles_debit is true when the settled item is a liability being paid (its line is
-- a debit, e.g. a supplier invoice paid), false when it is a receivable being collected
-- (its line is a credit, e.g. a receivable invoice receipt).
create or replace function public.platform_fx_settlement(
  p_tenant_id     uuid,
  p_currency      text,
  p_amount        numeric,
  p_original_rate numeric,
  p_on            date,
  p_settles_debit boolean
)
returns table (
  settlement_rate numeric,
  base_original   numeric,
  base_settlement numeric,
  result          numeric
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_rate numeric;
  v_orig numeric;
  v_sett numeric;
begin
  if p_amount is null or p_amount < 0 or p_original_rate is null or p_original_rate <= 0 then
    raise exception 'FX_ARGUMENT: a settlement needs a non-negative amount and a positive original rate';
  end if;
  v_rate := (platform_fx_rate(p_tenant_id, p_currency, p_on)).rate;
  v_orig := round(p_amount * p_original_rate, 2);
  v_sett := round(p_amount * v_rate, 2);
  return query select v_rate, v_orig, v_sett,
                      case when p_settles_debit then v_orig - v_sett else v_sett - v_orig end;
end;
$$;
revoke all on function public.platform_fx_settlement(uuid, text, numeric, numeric, date, boolean) from public, anon, authenticated;

-- The journal line that books a realised result: null when there is none, otherwise a
-- line in the functional currency on the gain account (credit) or loss account (debit).
create or replace function public.platform_fx_realised_line(
  p_tenant_id   uuid,
  p_result      numeric,
  p_description text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_account uuid;
  v_role    text;
begin
  if p_result is null or p_result = 0 then
    return null;
  end if;
  v_role := case when p_result > 0 then 'fx_gain_realised' else 'fx_loss_realised' end;
  select gl_account_id into v_account
    from gl_posting_rules
   where tenant_id = p_tenant_id and account_role = v_role;
  if v_account is null then
    raise exception 'FX_REALISED_ACCOUNT_MISSING: this company has no % account under posting rules', v_role;
  end if;
  return jsonb_build_object(
    'gl_account_id', v_account,
    'debit',  case when p_result < 0 then -p_result else 0 end,
    'credit', case when p_result > 0 then  p_result else 0 end,
    'currency', fin_ledger_currency(p_tenant_id),
    'description', coalesce(p_description,
                            case when p_result > 0 then 'Realised exchange gain' else 'Realised exchange loss' end)
  );
end;
$$;
revoke all on function public.platform_fx_realised_line(uuid, numeric, text) from public, anon, authenticated;

-- =====================================================================
-- F. Cash/bank transactions settle at the invoice's original rate
-- =====================================================================
create or replace function public.trg_post_cash_bank_transaction()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_cash_side    uuid;
  v_other_side   uuid;
  v_other_role   text;
  v_lines        jsonb;
  v_functional   text;
  v_ccy          text;
  v_invoice_ccy  text;
  v_invoice_found boolean := false;
  v_orig_entry   uuid;
  v_orig_rate    numeric;
  v_settle       record;
  v_other_line   jsonb;
  v_cash_line    jsonb;
  v_fx_line      jsonb;
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

  v_functional := fin_ledger_currency(new.tenant_id);
  v_ccy := coalesce(nullif(btrim(new.currency), ''), v_functional);

  -- Payroll is accrued in the functional currency only.
  if new.reference_type = 'payroll_run' and v_ccy <> v_functional then
    raise exception 'CASH_PAYROLL_CURRENCY: payroll is accrued in %, so a payroll payment cannot be in %', v_functional, v_ccy;
  end if;

  -- An invoice is settled in the currency it was issued in.
  if new.reference_type = 'supplier_invoice' then
    select true, coalesce(nullif(btrim(currency), ''), v_functional) into v_invoice_found, v_invoice_ccy
      from supplier_invoices where id = new.reference_id and tenant_id = new.tenant_id;
  elsif new.reference_type = 'receivable_invoice' then
    select true, coalesce(nullif(btrim(currency), ''), v_functional) into v_invoice_found, v_invoice_ccy
      from receivable_invoices where id = new.reference_id and tenant_id = new.tenant_id;
  end if;
  if v_invoice_found and v_invoice_ccy <> v_ccy then
    raise exception 'CASH_CURRENCY_MISMATCH: this % is in %, so the transaction must be in %, not %',
      replace(new.reference_type, '_', ' '), v_invoice_ccy, v_invoice_ccy, v_ccy;
  end if;

  -- Foreign settlement of an invoice that was booked: take the invoice's original rate.
  if v_invoice_found and v_ccy <> v_functional then
    select e.id, l.fx_rate into v_orig_entry, v_orig_rate
      from journal_entries e
      join journal_entry_lines l on l.journal_entry_id = e.id
     where e.tenant_id = new.tenant_id
       and e.source_type = new.reference_type
       and e.source_id = new.reference_id
       and e.status <> 'void'
       and l.gl_account_id = v_other_side
       and l.currency = v_ccy
     order by e.created_at
     limit 1;
  end if;

  v_other_line := jsonb_build_object('gl_account_id', v_other_side, 'currency', new.currency);
  v_cash_line  := jsonb_build_object('gl_account_id', v_cash_side,  'currency', new.currency);
  if new.transaction_type = 'payment' then
    v_other_line := v_other_line || jsonb_build_object('debit', new.amount);
    v_cash_line  := v_cash_line  || jsonb_build_object('credit', new.amount);
  else -- 'receipt'
    v_other_line := v_other_line || jsonb_build_object('credit', new.amount);
    v_cash_line  := v_cash_line  || jsonb_build_object('debit', new.amount);
  end if;

  if v_orig_entry is not null then
    v_other_line := v_other_line || jsonb_build_object('rate_from_entry', v_orig_entry, 'fx_rate', v_orig_rate);
    select * into v_settle from platform_fx_settlement(
      new.tenant_id, v_ccy, new.amount, v_orig_rate, new.transaction_date, new.transaction_type = 'payment');
    v_fx_line := platform_fx_realised_line(new.tenant_id, v_settle.result);
  end if;

  v_lines := jsonb_build_array(v_other_line, v_cash_line);
  if v_fx_line is not null then
    v_lines := v_lines || v_fx_line;
  end if;

  perform post_journal_entry(new.tenant_id, 'cash_bank_transaction', new.id, new.transaction_date,
    coalesce(new.description, initcap(new.transaction_type) || ' - ' || new.reference_type), v_lines);

  return new;
end;
$function$;
