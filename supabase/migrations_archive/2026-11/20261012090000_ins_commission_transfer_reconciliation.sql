-- Bank reconciliation for insurance commission transfers (D4d extension).
--
-- A commission transfer moves money between two bank accounts, so the bank
-- statements show two lines: money out of the client-money account and money
-- into the operating account. Each side is matched on its own, one-to-one like
-- every other D4d match, so a transfer can be half reconciled.
--
--   1. bank_reconciliations gains commission_transfer_id and transfer_side
--      ('from' = the client-money statement line, 'to' = the operating line).
--      A row now matches a line to exactly one of: a cash/bank transaction, a
--      settlement, or one side of a commission transfer.
--   2. fin_bank_line_candidates offers transfer sides ('transfer_from' /
--      'transfer_to') with the same rule as settlements: same bank account,
--      same currency, signed amount equal (out negative, in positive), within
--      5 days, side not yet reconciled, transfer posted.
--   3. match_bank_statement_line_to_commission_transfer: manual match; the side
--      follows from the statement line's bank account.
--   4. auto_match_bank_statement matches a transfer side when it is the only
--      candidate, like any other source.
--   5. The position summary counts posted transfers as book items for both
--      banks, so a transfer no longer shows up as an unexplained difference.
--   6. The variance view and the possible-double-entry view include transfers.
--   7. ins_void_commission_transfer refuses while either side is reconciled
--      (unmatch first), the same rule as voiding a settlement.
--   8. Finance team members can read commission transfers (they reconcile the
--      bank), not only insurance users. Entries and events stay insurance-only.
--
-- Re-runnable: create or replace, if not exists, drop-then-add for constraints.

-- =====================================================================
-- 1. bank_reconciliations: a third kind of source
-- =====================================================================
alter table public.bank_reconciliations
  add column if not exists commission_transfer_id uuid
    references public.ins_commission_transfers (id) on delete restrict,
  add column if not exists transfer_side text;

alter table public.bank_reconciliations drop constraint if exists bank_reconciliations_one_source_check;
alter table public.bank_reconciliations
  add constraint bank_reconciliations_one_source_check
  check (num_nonnulls(cash_bank_transaction_id, settlement_id, commission_transfer_id) = 1);

alter table public.bank_reconciliations drop constraint if exists bank_reconciliations_transfer_side_check;
alter table public.bank_reconciliations
  add constraint bank_reconciliations_transfer_side_check
  check ((commission_transfer_id is null and transfer_side is null)
      or (commission_transfer_id is not null and transfer_side is not null and transfer_side in ('from', 'to')));

create unique index if not exists bank_reconciliations_transfer_side_unique
  on public.bank_reconciliations (commission_transfer_id, transfer_side)
  where commission_transfer_id is not null;

-- =====================================================================
-- 8. Finance can read transfers (insurance users still can)
-- =====================================================================
drop policy if exists ins_commission_transfers_select on public.ins_commission_transfers;
create policy ins_commission_transfers_select on public.ins_commission_transfers
  for select to authenticated
  using (tenant_id = get_my_tenant_id() and (can_access_insurance() or is_finance_team_member(null::text)));

-- =====================================================================
-- 2. Candidates
-- =====================================================================
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
$$;

revoke all on function public.fin_bank_line_candidates(uuid, uuid) from public, anon;
grant execute on function public.fin_bank_line_candidates(uuid, uuid) to authenticated, service_role;

-- =====================================================================
-- 3. Manual match
-- =====================================================================
create or replace function public.match_bank_statement_line_to_commission_transfer(
  p_statement_line_id uuid,
  p_transfer_id       uuid
)
returns public.bank_reconciliations
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_tenant_id uuid := get_my_tenant_id();
  v_line   bank_statement_lines%rowtype;
  v_tr     ins_commission_transfers%rowtype;
  v_from   text;
  v_to     text;
  v_side   text;
  v_signed numeric;
  v_row    bank_reconciliations%rowtype;
begin
  if not is_finance_team_member('finance') then
    raise exception 'not authorized to reconcile bank transactions';
  end if;

  select * into v_line from bank_statement_lines
   where id = p_statement_line_id and tenant_id = v_tenant_id;
  if not found then
    raise exception 'statement line not found';
  end if;

  -- Lock the transfer so a concurrent void cannot slip past the reconciled check.
  select * into v_tr from ins_commission_transfers
   where id = p_transfer_id and tenant_id = v_tenant_id
   for update;
  if not found then
    raise exception 'commission transfer not found';
  end if;
  if v_tr.status <> 'posted' then
    raise exception 'only posted commission transfers can be reconciled (% is %)', v_tr.transfer_no, v_tr.status;
  end if;

  select name into v_from from fin_bank_accounts where id = v_tr.from_bank_account_id and tenant_id = v_tenant_id;
  select name into v_to   from fin_bank_accounts where id = v_tr.to_bank_account_id   and tenant_id = v_tenant_id;

  v_side := case
    when v_line.bank_account = v_from then 'from'
    when v_line.bank_account = v_to   then 'to'
    else null end;
  if v_side is null then
    raise exception 'statement line is on % but transfer % moves money between % and %',
      v_line.bank_account, v_tr.transfer_no, v_from, v_to;
  end if;

  if v_tr.currency is distinct from v_line.currency then
    raise exception 'statement line and commission transfer are in different currencies (% vs %)',
      v_line.currency, v_tr.currency;
  end if;

  v_signed := case when v_side = 'to' then v_tr.amount else -v_tr.amount end;

  begin
    insert into bank_reconciliations (
      tenant_id, bank_statement_line_id, commission_transfer_id, transfer_side, match_type, variance, matched_by
    ) values (
      v_tenant_id, p_statement_line_id, p_transfer_id, v_side, 'manual', v_line.amount - v_signed, auth.uid()
    )
    returning * into v_row;
  exception when unique_violation then
    raise exception 'statement line or that side of the transfer is already reconciled';
  end;

  return v_row;
end;
$$;

revoke all on function public.match_bank_statement_line_to_commission_transfer(uuid, uuid) from public, anon;
grant execute on function public.match_bank_statement_line_to_commission_transfer(uuid, uuid) to authenticated, service_role;

-- =====================================================================
-- 4. Auto-match: transfers join the candidate pool
-- =====================================================================
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
      elsif v_source in ('transfer_from', 'transfer_to') then
        insert into bank_reconciliations (
          tenant_id, bank_statement_line_id, commission_transfer_id, transfer_side, match_type, variance, matched_by
        ) values (v_tenant_id, v_line.id, v_candidate, substr(v_source, 10), 'auto', 0, auth.uid());
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

-- =====================================================================
-- 5. Position summary: transfers are book items on both banks
-- =====================================================================
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
end;
$$;

revoke all on function public.fin_bank_reconciliation_position(uuid, date) from public, anon;
grant execute on function public.fin_bank_reconciliation_position(uuid, date) to authenticated, service_role;

-- =====================================================================
-- 6. Views
-- =====================================================================
-- New column commission_transfer_id is appended; existing columns keep their
-- order and types. Transfer rows report source 'commission_transfer'.
create or replace view public.v_bank_reconciliation_variance
with (security_invoker = true) as
select r.id as reconciliation_id,
       r.tenant_id,
       r.match_type,
       r.variance,
       r.matched_at,
       l.bank_account,
       l.statement_date,
       l.description as statement_description,
       l.amount as statement_amount,
       coalesce(t.transaction_date, s.settlement_date, ct.transfer_date) as transaction_date,
       coalesce(t.description, s.reference, s.notes, ct.notes, ct.transfer_no) as transaction_description,
       coalesce(t.amount, s.amount, ct.amount) as transaction_amount,
       coalesce(t.transaction_type,
         case
           when ct.id is not null then 'transfer'
           when s.direction = 'in' then 'receipt'
           else 'payment'
         end) as transaction_type,
       case
         when r.commission_transfer_id is not null then 'commission_transfer'
         when r.settlement_id is null then 'cash_bank'
         else 'settlement'
       end as source,
       r.cash_bank_transaction_id,
       r.settlement_id,
       r.commission_transfer_id
  from bank_reconciliations r
  join bank_statement_lines l on l.id = r.bank_statement_line_id
  left join cash_bank_transactions t on t.id = r.cash_bank_transaction_id
  left join fin_settlements s on s.id = r.settlement_id
  left join ins_commission_transfers ct on ct.id = r.commission_transfer_id
 where r.variance <> 0;

create or replace view public.v_bank_possible_double_entries
with (security_invoker = true) as
select l.id as statement_line_id,
       l.tenant_id,
       l.bank_account,
       l.statement_date,
       l.description,
       l.reference,
       l.amount,
       l.currency,
       c.cash_bank_transaction_ids,
       c.settlement_ids,
       c.transfer_ids
  from bank_statement_lines l
  left join bank_reconciliations r on r.bank_statement_line_id = l.id
  cross join lateral (
    select array_agg(x.candidate_id) filter (where x.source = 'cash_bank') as cash_bank_transaction_ids,
           array_agg(x.candidate_id) filter (where x.source = 'settlement') as settlement_ids,
           array_agg(x.candidate_id) filter (where x.source in ('transfer_from', 'transfer_to')) as transfer_ids
      from fin_bank_line_candidates(l.id, l.tenant_id) x(source, candidate_id)
  ) c
 where r.id is null
   and c.cash_bank_transaction_ids is not null
   and (c.settlement_ids is not null or c.transfer_ids is not null);

-- =====================================================================
-- 7. Voiding a transfer needs both sides unmatched
-- =====================================================================
-- Body identical to 20261011090000 except for the reconciled check.
create or replace function public.ins_void_commission_transfer(
  p_transfer_id uuid,
  p_reason      text,
  p_void_date   date default current_date
)
returns public.ins_commission_transfers
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tenant uuid := get_my_tenant_id();
  v_tr     ins_commission_transfers%rowtype;
  v_lines  jsonb;
  v_je     journal_entries;
begin
  if not can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: only insurance admins and managers can void a commission transfer' using errcode = '42501';
  end if;
  if p_reason is null or length(btrim(p_reason)) < 5 then
    raise exception 'INS_TRANSFER_VOID: a reason of at least 5 characters is required';
  end if;

  select * into v_tr from ins_commission_transfers where id = p_transfer_id and tenant_id = v_tenant for update;
  if not found then raise exception 'INS_TRANSFER_VOID: transfer not found in this company'; end if;
  if v_tr.status <> 'posted' then raise exception 'INS_TRANSFER_VOID: transfer % is already void', v_tr.transfer_no; end if;
  if exists (select 1 from bank_reconciliations r where r.commission_transfer_id = v_tr.id) then
    raise exception 'INS_TRANSFER_RECONCILED: transfer % is matched to a bank statement line; unmatch it in bank reconciliation first', v_tr.transfer_no;
  end if;
  if p_void_date is null or p_void_date < v_tr.transfer_date or p_void_date > current_date + 1 then
    raise exception 'INS_TRANSFER_VOID: the void date must be between the transfer date and today';
  end if;

  select jsonb_agg(jsonb_build_object(
           'gl_account_id', l.gl_account_id, 'debit', l.credit, 'credit', l.debit,
           'description', 'Reversal of ' || v_tr.transfer_no))
    into v_lines
    from journal_entry_lines l where l.journal_entry_id = v_tr.journal_entry_id;

  v_je := post_journal_entry(v_tenant, 'ins_commission_transfer_void', v_tr.id, p_void_date,
    'Void of commission transfer ' || v_tr.transfer_no || ': ' || btrim(p_reason), v_lines);

  insert into ins_commission_events (tenant_id, entry_id, event, amount, journal_entry_id, transfer_id)
  select v_tenant, e.id, 'transfer_voided', e.amount, v_je.id, v_tr.id
    from ins_commission_entries e where e.transfer_id = v_tr.id and e.tenant_id = v_tenant;

  update ins_commission_entries
     set status = 'earned', transfer_id = null, updated_at = now()
   where transfer_id = v_tr.id and tenant_id = v_tenant;

  update ins_commission_transfers
     set status = 'void', void_journal_entry_id = v_je.id, voided_at = now(),
         voided_by = auth.uid(), void_reason = btrim(p_reason)
   where id = v_tr.id
   returning * into v_tr;

  return v_tr;
end;
$$;

revoke all on function public.ins_void_commission_transfer(uuid, text, date) from public, anon;
grant execute on function public.ins_void_commission_transfer(uuid, text, date) to authenticated;

select public.apply_tenant_read_only_guard();