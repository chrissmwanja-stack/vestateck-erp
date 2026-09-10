set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.auto_match_bank_statement(p_bank_account text, p_date_from date, p_date_to date)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_tenant_id uuid := get_my_tenant_id();
  v_line record;
  v_candidate_ids uuid[];
  v_matched_count integer := 0;
begin
  if not is_finance_team_member('finance') then
    raise exception 'not authorized to auto-match bank transactions';
  end if;

  for v_line in
    select l.*
    from bank_statement_lines l
    left join bank_reconciliations r on r.bank_statement_line_id = l.id
    where l.tenant_id = v_tenant_id
      and l.bank_account = p_bank_account
      and l.statement_date between p_date_from and p_date_to
      and r.id is null
  loop
    select array_agg(t.id) into v_candidate_ids
    from cash_bank_transactions t
    left join bank_reconciliations r on r.cash_bank_transaction_id = t.id
    where t.tenant_id = v_tenant_id
      and t.payment_method = 'bank'
      and t.bank_account = p_bank_account
      and r.id is null
      and (case when t.transaction_type = 'receipt' then t.amount else -t.amount end) = v_line.amount
      and abs(t.transaction_date - v_line.statement_date) <= 5;

    if array_length(v_candidate_ids, 1) = 1 then
      insert into bank_reconciliations (
        tenant_id, bank_statement_line_id, cash_bank_transaction_id, match_type, variance, matched_by
      ) values (
        v_tenant_id, v_line.id, v_candidate_ids[1], 'auto', 0, auth.uid()
      );
      v_matched_count := v_matched_count + 1;
    end if;
  end loop;

  return v_matched_count;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.calculate_statutory_deductions(p_gross numeric, p_as_of_date date DEFAULT CURRENT_DATE)
 RETURNS TABLE(paye_amount numeric, nssf_employee numeric, nssf_employer numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.generate_payroll_items(p_run_id uuid)
 RETURNS SETOF public.hr_payroll_items
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.get_posting_account(p_tenant_id uuid, p_role text)
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select gl_account_id from gl_posting_rules
  where tenant_id = p_tenant_id and account_role = p_role;
$function$
;

CREATE OR REPLACE FUNCTION public.grant_hr_team_member(p_user_id uuid, p_role text DEFAULT 'member'::text)
 RETURNS public.hr_team_members
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_row public.hr_team_members%rowtype;
begin
  if not has_module_role('hr', array['admin']) then
    raise exception 'not authorized to manage the HR team';
  end if;
  if not exists (select 1 from app_users where id = p_user_id and tenant_id = get_my_tenant_id()) then
    raise exception 'user not found in this tenant';
  end if;

  insert into hr_team_members (tenant_id, user_id, role)
  values (get_my_tenant_id(), p_user_id, p_role)
  on conflict (tenant_id, user_id) do update set role = excluded.role
  returning * into v_row;

  return v_row;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.grant_payroll_approver(p_user_id uuid)
 RETURNS public.payroll_approvers
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_row public.payroll_approvers%rowtype;
begin
  if not has_module_role('hr', array['admin']) then
    raise exception 'not authorized to manage payroll approvers';
  end if;
  if not exists (select 1 from app_users where id = p_user_id and tenant_id = get_my_tenant_id()) then
    raise exception 'user not found in this tenant';
  end if;

  insert into payroll_approvers (tenant_id, user_id, role, is_active)
  values (get_my_tenant_id(), p_user_id, 'approver', true)
  on conflict (tenant_id, user_id) do update set is_active = true
  returning * into v_row;

  return v_row;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.import_bank_statement_lines(p_bank_account text, p_lines jsonb)
 RETURNS SETOF public.bank_statement_lines
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_tenant_id uuid := get_my_tenant_id();
  v_line jsonb;
begin
  if not is_finance_team_member('finance') then
    raise exception 'not authorized to import bank statement lines';
  end if;

  if p_bank_account is null or btrim(p_bank_account) = '' then
    raise exception 'bank_account is required';
  end if;

  if p_lines is null or jsonb_array_length(p_lines) = 0 then
    raise exception 'at least one statement line is required';
  end if;

  for v_line in select * from jsonb_array_elements(p_lines)
  loop
    if (v_line ->> 'statement_date') is null or (v_line ->> 'amount') is null then
      raise exception 'each line requires statement_date and amount';
    end if;

    return query
    insert into bank_statement_lines (
      tenant_id, bank_account, statement_date, description, reference, amount, currency, imported_by
    ) values (
      v_tenant_id,
      btrim(p_bank_account),
      (v_line ->> 'statement_date')::date,
      nullif(v_line ->> 'description', ''),
      nullif(v_line ->> 'reference', ''),
      (v_line ->> 'amount')::numeric,
      coalesce(nullif(v_line ->> 'currency', ''), 'UGX'),
      auth.uid()
    )
    returning *;
  end loop;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.match_bank_statement_line(p_statement_line_id uuid, p_cash_bank_transaction_id uuid)
 RETURNS public.bank_reconciliations
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_tenant_id uuid := get_my_tenant_id();
  v_line bank_statement_lines%rowtype;
  v_txn cash_bank_transactions%rowtype;
  v_txn_signed numeric;
  v_row bank_reconciliations%rowtype;
begin
  if not is_finance_team_member('finance') then
    raise exception 'not authorized to reconcile bank transactions';
  end if;

  select * into v_line from bank_statement_lines where id = p_statement_line_id and tenant_id = v_tenant_id;
  if not found then
    raise exception 'statement line not found';
  end if;

  select * into v_txn from cash_bank_transactions where id = p_cash_bank_transaction_id and tenant_id = v_tenant_id;
  if not found then
    raise exception 'cash/bank transaction not found';
  end if;

  if v_txn.payment_method != 'bank' then
    raise exception 'only bank-method transactions can be reconciled against a statement';
  end if;

  if v_txn.bank_account is distinct from v_line.bank_account then
    raise exception 'statement line and transaction are on different bank accounts (% vs %)', v_line.bank_account, v_txn.bank_account;
  end if;

  v_txn_signed := case when v_txn.transaction_type = 'receipt' then v_txn.amount else -v_txn.amount end;

  insert into bank_reconciliations (
    tenant_id, bank_statement_line_id, cash_bank_transaction_id, match_type, variance, matched_by
  ) values (
    v_tenant_id, p_statement_line_id, p_cash_bank_transaction_id, 'manual', v_line.amount - v_txn_signed, auth.uid()
  )
  returning * into v_row;

  return v_row;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.notify_leave_status_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_recipient_id uuid;
begin
  if NEW.status = OLD.status then
    return NEW;
  end if;

  if NEW.status not in ('approved', 'rejected') then
    return NEW;
  end if;

  select user_id into v_recipient_id from hr_employees where id = NEW.employee_id;

  -- Employee may not have a linked portal account (user_id is nullable) --
  -- nothing to notify in that case.
  if v_recipient_id is null then
    return NEW;
  end if;

  insert into notifications (tenant_id, recipient_id, type, title, body)
  values (
    NEW.tenant_id,
    v_recipient_id,
    'leave_' || NEW.status,
    case
      when NEW.status = 'approved' then 'Your leave request has been approved'
      else 'Your leave request has been rejected'
    end,
    format(
      'Leave request %s (%s to %s, %s day%s) was %s.',
      coalesce(NEW.leave_no, NEW.id::text),
      NEW.start_date,
      NEW.end_date,
      NEW.days,
      case when NEW.days = 1 then '' else 's' end,
      NEW.status
    )
  );

  return NEW;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.seed_default_chart_of_accounts()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.seed_statutory_rate_table(p_effective_date date DEFAULT CURRENT_DATE)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.set_finance_role(p_user_id uuid, p_role text)
 RETURNS public.finance_team_members
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_row public.finance_team_members%rowtype;
begin
  if not is_tenant_admin() then
    raise exception 'not authorized to manage finance access';
  end if;
  if not exists (select 1 from app_users where id = p_user_id and tenant_id = get_my_tenant_id()) then
    raise exception 'user not found in this tenant';
  end if;

  delete from finance_team_members
  where user_id = p_user_id
    and tenant_id = get_my_tenant_id()
    and role != p_role;

  insert into finance_team_members (tenant_id, user_id, role)
  values (get_my_tenant_id(), p_user_id, p_role)
  on conflict (tenant_id, user_id, role) do nothing
  returning * into v_row;

  if v_row.id is null then
    select * into v_row from finance_team_members
    where user_id = p_user_id and tenant_id = get_my_tenant_id() and role = p_role;
  end if;

  return v_row;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.set_payroll_approver_active(p_user_id uuid, p_is_active boolean)
 RETURNS public.payroll_approvers
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_row public.payroll_approvers%rowtype;
begin
  if not has_module_role('hr', array['admin']) then
    raise exception 'not authorized to manage payroll approvers';
  end if;

  update payroll_approvers
  set is_active = p_is_active
  where user_id = p_user_id and tenant_id = get_my_tenant_id()
  returning * into v_row;

  if not found then
    raise exception 'payroll approver not found';
  end if;

  return v_row;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.set_staff_module_role(p_user_id uuid, p_module text, p_role text)
 RETURNS public.staff_roles
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_row public.staff_roles%rowtype;
begin
  if not is_tenant_admin() then
    raise exception 'not authorized to manage team access';
  end if;
  if not exists (select 1 from app_users where id = p_user_id and tenant_id = get_my_tenant_id()) then
    raise exception 'user not found in this tenant';
  end if;

  insert into staff_roles (tenant_id, user_id, module, role)
  values (get_my_tenant_id(), p_user_id, p_module, p_role)
  on conflict (tenant_id, user_id, module) do update set role = excluded.role
  returning * into v_row;

  return v_row;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.trg_post_cash_bank_transaction()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.trg_post_payroll_run_approval()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.trg_post_receivable_invoice()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.trg_post_supplier_invoice()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.unmatch_bank_reconciliation(p_reconciliation_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not is_finance_team_member('finance') then
    raise exception 'not authorized to undo a bank reconciliation match';
  end if;

  delete from bank_reconciliations
  where id = p_reconciliation_id and tenant_id = get_my_tenant_id();

  if not found then
    raise exception 'reconciliation match not found';
  end if;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.update_payroll_item(p_item_id uuid, p_allowances numeric, p_deductions numeric, p_note text DEFAULT NULL::text)
 RETURNS public.hr_payroll_items
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;


