-- D4d-1: reconcile fin_settlements against bank statement lines.
--
-- Decisions (confirmed):
--   A. Extend bank_reconciliations (no separate settlement-reconciliation table).
--   B. fin_void_settlement refuses while the settlement is reconciled (unmatch first).
--   C. Statement lines with no book entry are only reported here (posting is D4e).
--   D. Matching stays one-to-one.
--
-- Statement lines carry the bank account as text (bank_statement_lines.bank_account),
-- which is fin_bank_accounts.name. Settlements point at fin_bank_accounts.id, so every
-- settlement match resolves the name through fin_bank_accounts.

-- ---------------------------------------------------------------------------
-- 1. bank_reconciliations: a row matches a line to EITHER a cash/bank
--    transaction OR a settlement.
-- ---------------------------------------------------------------------------
alter table public.bank_reconciliations
  alter column cash_bank_transaction_id drop not null;

alter table public.bank_reconciliations
  add column if not exists settlement_id uuid
  references public.fin_settlements (id) on delete restrict;

alter table public.bank_reconciliations
  add constraint bank_reconciliations_settlement_unique unique (settlement_id);

alter table public.bank_reconciliations
  add constraint bank_reconciliations_one_source_check
  check ((cash_bank_transaction_id is null) <> (settlement_id is null));

-- ---------------------------------------------------------------------------
-- 2. Candidate lookup shared by auto-match and the double-entry view.
--    Rule: same bank account, same currency (settlements), signed amount equal
--    (in positive, out negative; receipts positive, payments negative), within
--    5 days, not already reconciled, settlement must be posted.
-- ---------------------------------------------------------------------------
create or replace function public.fin_bank_line_candidates(p_line_id uuid, p_tenant_id uuid)
returns table (source text, candidate_id uuid)
language sql
stable
security invoker
set search_path to 'public'
as $$
  select 'cash_bank'::text, t.id
  from bank_statement_lines l
  join cash_bank_transactions t
    on t.tenant_id = l.tenant_id
   and t.payment_method = 'bank'
   and t.bank_account = l.bank_account
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
    and not exists (select 1 from bank_reconciliations r where r.settlement_id = s.id);
$$;

revoke all on function public.fin_bank_line_candidates(uuid, uuid) from public, anon;
grant execute on function public.fin_bank_line_candidates(uuid, uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. Manual match of a statement line to a settlement.
-- ---------------------------------------------------------------------------
create or replace function public.match_bank_statement_line_to_settlement(
  p_statement_line_id uuid,
  p_settlement_id uuid
)
returns public.bank_reconciliations
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_tenant_id uuid := get_my_tenant_id();
  v_line bank_statement_lines%rowtype;
  v_set fin_settlements%rowtype;
  v_bank_name text;
  v_signed numeric;
  v_row bank_reconciliations%rowtype;
begin
  if not is_finance_team_member('finance') then
    raise exception 'not authorized to reconcile bank transactions';
  end if;

  select * into v_line from bank_statement_lines
   where id = p_statement_line_id and tenant_id = v_tenant_id;
  if not found then
    raise exception 'statement line not found';
  end if;

  -- Lock the settlement so a concurrent void cannot slip past the reconciled check.
  select * into v_set from fin_settlements
   where id = p_settlement_id and tenant_id = v_tenant_id
   for update;
  if not found then
    raise exception 'settlement not found';
  end if;

  if v_set.status <> 'posted' then
    raise exception 'only posted settlements can be reconciled (% is %)', v_set.settlement_no, v_set.status;
  end if;

  select b.name into v_bank_name from fin_bank_accounts b
   where b.id = v_set.bank_account_id and b.tenant_id = v_tenant_id;

  if v_bank_name is distinct from v_line.bank_account then
    raise exception 'statement line and settlement are on different bank accounts (% vs %)',
      v_line.bank_account, v_bank_name;
  end if;

  if v_set.currency is distinct from v_line.currency then
    raise exception 'statement line and settlement are in different currencies (% vs %)',
      v_line.currency, v_set.currency;
  end if;

  v_signed := case when v_set.direction = 'in' then v_set.amount else -v_set.amount end;

  begin
    insert into bank_reconciliations (
      tenant_id, bank_statement_line_id, settlement_id, match_type, variance, matched_by
    ) values (
      v_tenant_id, p_statement_line_id, p_settlement_id, 'manual', v_line.amount - v_signed, auth.uid()
    )
    returning * into v_row;
  exception when unique_violation then
    raise exception 'statement line or settlement is already reconciled';
  end;

  return v_row;
end;
$$;

revoke all on function public.match_bank_statement_line_to_settlement(uuid, uuid) from public, anon;
grant execute on function public.match_bank_statement_line_to_settlement(uuid, uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. Auto-match searches both pools together. Exactly one candidate in total
--    matches. Two or more (including one from each pool) is left for a human;
--    the cross-pool case shows up in v_bank_possible_double_entries.
--    Signature and return type are unchanged.
-- ---------------------------------------------------------------------------
create or replace function public.auto_match_bank_statement(
  p_bank_account text,
  p_date_from date,
  p_date_to date
)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_tenant_id uuid := get_my_tenant_id();
  v_line record;
  v_count integer;
  v_source text;
  v_candidate uuid;
  v_matched_count integer := 0;
begin
  if not is_finance_team_member('finance') then
    raise exception 'not authorized to auto-match bank transactions';
  end if;

  for v_line in
    select l.id
    from bank_statement_lines l
    left join bank_reconciliations r on r.bank_statement_line_id = l.id
    where l.tenant_id = v_tenant_id
      and l.bank_account = p_bank_account
      and l.statement_date between p_date_from and p_date_to
      and r.id is null
    order by l.statement_date, l.imported_at, l.id
  loop
    select count(*), min(c.source), (array_agg(c.candidate_id))[1]
      into v_count, v_source, v_candidate
      from fin_bank_line_candidates(v_line.id, v_tenant_id) c;

    if v_count = 1 then
      if v_source = 'settlement' then
        insert into bank_reconciliations (
          tenant_id, bank_statement_line_id, settlement_id, match_type, variance, matched_by
        ) values (v_tenant_id, v_line.id, v_candidate, 'auto', 0, auth.uid());
      else
        insert into bank_reconciliations (
          tenant_id, bank_statement_line_id, cash_bank_transaction_id, match_type, variance, matched_by
        ) values (v_tenant_id, v_line.id, v_candidate, 'auto', 0, auth.uid());
      end if;
      v_matched_count := v_matched_count + 1;
    end if;
  end loop;

  return v_matched_count;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Void guard (decision B). The check lives in the impl so every caller is covered.
-- ---------------------------------------------------------------------------
create or replace function public.platform_fin_void_settlement_impl(
  p_tenant_id uuid,
  p_settlement_id uuid,
  p_reason text,
  p_void_date date default current_date
)
returns public.fin_settlements
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_set   fin_settlements%rowtype;
  v_lines jsonb;
  v_je    journal_entries%rowtype;
begin
  if p_tenant_id is null then raise exception 'tenant id is required'; end if;
  if p_reason is null or length(btrim(p_reason)) < 5 then
    raise exception 'SETTLEMENT_VOID: a reason of at least 5 characters is required';
  end if;

  select * into v_set from fin_settlements where id = p_settlement_id and tenant_id = p_tenant_id for update;
  if not found then raise exception 'SETTLEMENT_VOID: settlement not found in this company'; end if;

  if exists (
    select 1 from bank_reconciliations r
     where r.settlement_id = v_set.id and r.tenant_id = p_tenant_id
  ) then
    raise exception 'SETTLEMENT_VOID: settlement % is reconciled to a bank statement line; unmatch it first', v_set.settlement_no;
  end if;

  if v_set.status <> 'posted' then raise exception 'SETTLEMENT_VOID: settlement % is already void', v_set.settlement_no; end if;
  if v_set.journal_entry_id is null then raise exception 'SETTLEMENT_VOID: settlement % has no posted journal', v_set.settlement_no; end if;
  if p_void_date is null or p_void_date < v_set.settlement_date or p_void_date > current_date + 1 then
    raise exception 'SETTLEMENT_VOID: the void date must be between the settlement date and today';
  end if;

  select jsonb_agg(jsonb_build_object(
           'gl_account_id', l.gl_account_id,
           'debit', l.credit,
           'credit', l.debit,
           'description', 'Reversal of ' || v_set.settlement_no))
    into v_lines
    from journal_entry_lines l
   where l.journal_entry_id = v_set.journal_entry_id;

  v_je := post_journal_entry(p_tenant_id, 'fin_settlement_void', v_set.id, p_void_date,
                             'Void of settlement ' || v_set.settlement_no || ': ' || btrim(p_reason), v_lines);

  update fin_settlements
     set status = 'void', void_journal_entry_id = v_je.id, voided_at = now(),
         voided_by = auth.uid(), void_reason = btrim(p_reason)
   where id = v_set.id
   returning * into v_set;

  return v_set;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Views.
-- ---------------------------------------------------------------------------
-- Existing columns keep their names, order and types; new ones are appended.
create or replace view public.v_bank_reconciliation_variance
with (security_invoker = true) as
select
  r.id as reconciliation_id,
  r.tenant_id,
  r.match_type,
  r.variance,
  r.matched_at,
  l.bank_account,
  l.statement_date,
  l.description as statement_description,
  l.amount as statement_amount,
  coalesce(t.transaction_date, s.settlement_date) as transaction_date,
  coalesce(t.description, s.reference, s.notes) as transaction_description,
  coalesce(t.amount, s.amount) as transaction_amount,
  coalesce(t.transaction_type, case when s.direction = 'in' then 'receipt' else 'payment' end) as transaction_type,
  case when r.settlement_id is null then 'cash_bank' else 'settlement' end as source,
  r.cash_bank_transaction_id,
  r.settlement_id
from bank_reconciliations r
join bank_statement_lines l on l.id = r.bank_statement_line_id
left join cash_bank_transactions t on t.id = r.cash_bank_transaction_id
left join fin_settlements s on s.id = r.settlement_id
where r.variance <> 0;

-- Unmatched statement lines that have a candidate in BOTH pools: a possible
-- double entry (the same bank movement recorded as a cash/bank transaction
-- and as a settlement). Auto-match leaves these for a human.
create or replace view public.v_bank_possible_double_entries
with (security_invoker = true) as
select
  l.id as statement_line_id,
  l.tenant_id,
  l.bank_account,
  l.statement_date,
  l.description,
  l.reference,
  l.amount,
  l.currency,
  c.cash_bank_transaction_ids,
  c.settlement_ids
from bank_statement_lines l
left join bank_reconciliations r on r.bank_statement_line_id = l.id
cross join lateral (
  select
    array_agg(x.candidate_id) filter (where x.source = 'cash_bank') as cash_bank_transaction_ids,
    array_agg(x.candidate_id) filter (where x.source = 'settlement') as settlement_ids
  from fin_bank_line_candidates(l.id, l.tenant_id) x
) c
where r.id is null
  and c.cash_bank_transaction_ids is not null
  and c.settlement_ids is not null;

-- ---------------------------------------------------------------------------
-- 7. Reconciliation position for one bank account as of a date.
--    Statement lines carry no running balance, so the result is compared by eye
--    with the bank's printed closing balance.
--      gl_balance                    GL balance of the account's GL account
--      unmatched_book_items          signed settlements / bank cash txns not on the statement
--      unmatched_statement_lines     signed statement lines with no book entry
--      expected_statement_balance    gl - unmatched book + unmatched statement
--      unexplained_difference        GL balance minus every book item reconciliation can see:
--                                    manual journals, opening balances, anything posted straight
--                                    to the bank GL account. Reported, never netted.
--    gl_balance and unexplained_difference are null when the account has no GL account.
-- ---------------------------------------------------------------------------
create or replace function public.fin_bank_reconciliation_position(
  p_bank_account_id uuid,
  p_as_of date default current_date
)
returns table (line_order integer, component text, label text, amount numeric)
language plpgsql
stable
security invoker
set search_path to 'public'
as $$
declare
  v_tenant_id uuid := get_my_tenant_id();
  v_bank fin_bank_accounts%rowtype;
  v_gl numeric;
  v_book_all numeric;
  v_book_unmatched numeric;
  v_stmt_unmatched numeric;
begin
  select * into v_bank from fin_bank_accounts
   where id = p_bank_account_id and tenant_id = v_tenant_id;
  if not found then
    raise exception 'bank account not found';
  end if;

  if v_bank.gl_account_id is not null then
    select coalesce(sum(l.debit - l.credit), 0) into v_gl
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
end;
$$;

revoke all on function public.fin_bank_reconciliation_position(uuid, date) from public, anon;
grant execute on function public.fin_bank_reconciliation_position(uuid, date) to authenticated, service_role;