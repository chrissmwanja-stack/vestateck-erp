-- A3 rest: foreign-currency bank reconciliation.
--
-- Bank reconciliation was built functional-currency-only: the statement
-- importer defaulted every line to UGX, the manual cash matcher ignored
-- currencies, the candidate search could cross-match a USD line with a
-- UGX amount, and the reconciliation position summed a foreign bank GL
-- across currencies -- so a USD account's balance added its USD legs to
-- the UGX revaluation and realised-FX legs 3b/3e post onto it.
--
-- This slice pins each piece to the bank account's own currency:
--
--   1. import_bank_statement_lines refuses a line whose currency differs
--      from the registered account's (BANK_STMT_CURRENCY) and defaults an
--      omitted currency to the account's, not UGX. Unregistered names
--      keep the legacy default so old imports do not break.
--   2. match_bank_statement_line refuses a statement line and a cash/bank
--      transaction in different currencies (the settlement and transfer
--      matchers already checked).
--   3. fin_bank_line_candidates filters the cash/bank branch by currency,
--      which also fixes auto_match_bank_statement.
--   4. fin_bank_reconciliation_position reads a foreign account's GL in
--      the account's currency -- the balance the statement can reconcile
--      -- and reports the functional-currency legs (revaluation and
--      realised FX) separately as fx_gl_movements. Functional accounts
--      see exactly the five components they saw before.
--
-- Test: supabase/tests/test_foreign_bank_reconciliation.sql.

-- =============================================================================
-- 1. Statement imports are pinned to the registered account's currency.
-- =============================================================================
create or replace function public.import_bank_statement_lines(p_bank_account text, p_lines jsonb)
returns setof public.bank_statement_lines
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_tenant_id uuid := get_my_tenant_id();
  v_line jsonb;
  v_account fin_bank_accounts%rowtype;
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

  -- The registry is the source of truth for an account's currency. A name
  -- that is not registered keeps the legacy free-text behaviour.
  select * into v_account
    from fin_bank_accounts
   where tenant_id = v_tenant_id and name = btrim(p_bank_account);

  for v_line in select * from jsonb_array_elements(p_lines)
  loop
    if (v_line ->> 'statement_date') is null or (v_line ->> 'amount') is null then
      raise exception 'each line requires statement_date and amount';
    end if;

    if v_account.id is not null
       and coalesce(nullif(v_line ->> 'currency', ''), v_account.currency)
           is distinct from v_account.currency then
      raise exception 'BANK_STMT_CURRENCY: statement lines for % must be in %, got %',
        v_account.name, v_account.currency, nullif(v_line ->> 'currency', '');
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
      coalesce(nullif(v_line ->> 'currency', ''), v_account.currency, 'UGX'),
      auth.uid()
    )
    returning *;
  end loop;
end;
$function$;

revoke all on function public.import_bank_statement_lines(text, jsonb) from public, anon;
grant execute on function public.import_bank_statement_lines(text, jsonb) to authenticated, service_role;

-- =============================================================================
-- 2. A manual cash match refuses mixed currencies.
-- =============================================================================
create or replace function public.match_bank_statement_line(p_statement_line_id uuid, p_cash_bank_transaction_id uuid)
returns public.bank_reconciliations
language plpgsql
security definer
set search_path = public
as $function$
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

  if v_txn.currency is distinct from v_line.currency then
    raise exception 'statement line and transaction are in different currencies (% vs %)', v_line.currency, v_txn.currency;
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
$function$;

revoke all on function public.match_bank_statement_line(uuid, uuid) from public, anon;
grant execute on function public.match_bank_statement_line(uuid, uuid) to authenticated, service_role;

-- =============================================================================
-- 3. The candidate search is currency-true (auto-match follows it).
-- =============================================================================
create or replace function public.fin_bank_line_candidates(p_line_id uuid, p_tenant_id uuid)
returns table(source text, candidate_id uuid)
language sql
stable
set search_path to 'public'
as $function$
  select 'cash_bank'::text, t.id
  from bank_statement_lines l
  join cash_bank_transactions t
    on t.tenant_id = l.tenant_id
   and t.payment_method = 'bank'
   and t.bank_account = l.bank_account
   and t.currency = l.currency
  where l.id = p_line_id
    and l.tenant_id = p_tenant_id
    and (case when t.transaction_type = 'receipt' then t.amount else -t.amount end) = l.amount
    and abs(t.transaction_date - l.statement_date) <= 5
    and not exists (select 1 from bank_reconciliations r where r.cash_bank_transaction_id = t.id)
  union all
  select 'settlement'::text, s.id
  from bank_statement_lines l
  join fin_bank_accounts b
    on b.tenant_id = l.tenant_id
   and b.name = l.bank_account
  join fin_settlements s
    on s.tenant_id = l.tenant_id
   and s.bank_account_id = b.id
  where l.id = p_line_id
    and l.tenant_id = p_tenant_id
    and s.status = 'posted'
    and s.currency = l.currency
    and (case when s.direction = 'in' then s.amount else -s.amount end) = l.amount
    and abs(s.settlement_date - l.statement_date) <= 5
    and not exists (select 1 from bank_reconciliations r where r.settlement_id = s.id)
  union all
  -- The client-money side of a commission transfer: money leaves, so the line is negative.
  select 'transfer_from'::text, ct.id
  from bank_statement_lines l
  join fin_bank_accounts b
    on b.tenant_id = l.tenant_id
   and b.name = l.bank_account
  join ins_commission_transfers ct
    on ct.tenant_id = l.tenant_id
   and ct.from_bank_account_id = b.id
  where l.id = p_line_id
    and l.tenant_id = p_tenant_id
    and ct.status = 'posted'
    and ct.currency = l.currency
    and -ct.amount = l.amount
    and abs(ct.transfer_date - l.statement_date) <= 5
    and not exists (select 1 from bank_reconciliations r where r.commission_transfer_id = ct.id and r.transfer_side = 'from')
  union all
  -- The operating side: money arrives, so the line is positive.
  select 'transfer_to'::text, ct.id
  from bank_statement_lines l
  join fin_bank_accounts b
    on b.tenant_id = l.tenant_id
   and b.name = l.bank_account
  join ins_commission_transfers ct
    on ct.tenant_id = l.tenant_id
   and ct.to_bank_account_id = b.id
  where l.id = p_line_id
    and l.tenant_id = p_tenant_id
    and ct.status = 'posted'
    and ct.currency = l.currency
    and ct.amount = l.amount
    and abs(ct.transfer_date - l.statement_date) <= 5
    and not exists (select 1 from bank_reconciliations r where r.commission_transfer_id = ct.id and r.transfer_side = 'to');
$function$;

revoke all on function public.fin_bank_line_candidates(uuid, uuid) from public, anon;
grant execute on function public.fin_bank_line_candidates(uuid, uuid) to authenticated, service_role;

-- =============================================================================
-- 4. The reconciliation position reads a foreign GL in the account's own
--    currency and reports the functional side-effects separately.
-- =============================================================================
create or replace function public.fin_bank_reconciliation_position(p_bank_account_id uuid, p_as_of date default current_date)
returns table(line_order integer, component text, label text, amount numeric)
language plpgsql
stable
set search_path to 'public'
as $function$
declare
  v_tenant_id uuid := get_my_tenant_id();
  v_bank fin_bank_accounts%rowtype;
  v_functional text;
  v_foreign boolean;
  v_gl numeric;
  v_gl_fx numeric;
  v_book_all numeric;
  v_book_unmatched numeric;
  v_stmt_unmatched numeric;
begin
  select * into v_bank from fin_bank_accounts
   where id = p_bank_account_id and tenant_id = v_tenant_id;
  if not found then
    raise exception 'bank account not found';
  end if;

  v_functional := fin_ledger_currency(v_tenant_id);
  v_foreign := v_bank.currency is not null and v_bank.currency <> v_functional;

  if v_bank.gl_account_id is not null then
    -- On a foreign account only the legs booked in the account's own currency
    -- can reconcile to its statement; the revaluation and realised-FX legs
    -- (3b/3e) are functional-currency side-effects, reported separately below.
    select coalesce(sum(l.debit - l.credit) filter (where not v_foreign or l.currency = v_bank.currency), 0),
           coalesce(sum(l.base_debit - l.base_credit) filter (where v_foreign and l.currency <> v_bank.currency), 0)
      into v_gl, v_gl_fx
      from journal_entry_lines l
      join journal_entries e on e.id = l.journal_entry_id
     where l.tenant_id = v_tenant_id
       and l.gl_account_id = v_bank.gl_account_id
       and e.tenant_id = v_tenant_id
       and e.status = 'posted'
       and e.entry_date <= p_as_of;
  end if;

  with book as (
    select (case when s.direction = 'in' then s.amount else -s.amount end) as signed,
           exists (select 1 from bank_reconciliations r where r.settlement_id = s.id) as reconciled
      from fin_settlements s
     where s.tenant_id = v_tenant_id
       and s.bank_account_id = v_bank.id
       and s.status = 'posted'
       and s.settlement_date <= p_as_of
    union all
    select (case when t.transaction_type = 'receipt' then t.amount else -t.amount end),
           exists (select 1 from bank_reconciliations r where r.cash_bank_transaction_id = t.id)
      from cash_bank_transactions t
     where t.tenant_id = v_tenant_id
       and t.payment_method = 'bank'
       and t.bank_account = v_bank.name
       and t.transaction_date <= p_as_of
    union all
    select (case when ct.to_bank_account_id = v_bank.id then ct.amount else -ct.amount end),
           exists (
             select 1 from bank_reconciliations r
              where r.commission_transfer_id = ct.id
                and r.transfer_side = case when ct.to_bank_account_id = v_bank.id then 'to' else 'from' end)
      from ins_commission_transfers ct
     where ct.tenant_id = v_tenant_id
       and ct.status = 'posted'
       and ct.transfer_date <= p_as_of
       and (ct.from_bank_account_id = v_bank.id or ct.to_bank_account_id = v_bank.id)
  )
  select coalesce(sum(signed), 0),
         coalesce(sum(signed) filter (where not reconciled), 0)
    into v_book_all, v_book_unmatched
    from book;

  select coalesce(sum(l.amount), 0) into v_stmt_unmatched
    from bank_statement_lines l
   where l.tenant_id = v_tenant_id
     and l.bank_account = v_bank.name
     and l.statement_date <= p_as_of
     and not exists (select 1 from bank_reconciliations r where r.bank_statement_line_id = l.id);

  return query values
    (1, 'gl_balance', 'GL balance', v_gl),
    (2, 'unmatched_book_items', 'Book items not on the statement', v_book_unmatched),
    (3, 'unmatched_statement_lines', 'Statement lines with no book entry', v_stmt_unmatched),
    (4, 'expected_statement_balance', 'Expected statement closing balance',
        case when v_gl is null then null else v_gl - v_book_unmatched + v_stmt_unmatched end),
    (5, 'unexplained_difference', 'Unexplained difference (GL movement reconciliation cannot see)',
        case when v_gl is null then null else v_gl - v_book_all end);

  if v_foreign and v_gl_fx is not null then
    return query values
      (6, 'fx_gl_movements', 'FX revaluation and realised legs on the GL (functional currency)', v_gl_fx);
  end if;
end;
$function$;

revoke all on function public.fin_bank_reconciliation_position(uuid, date) from public, anon;
grant execute on function public.fin_bank_reconciliation_position(uuid, date) to authenticated, service_role;
