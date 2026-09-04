-- Workstream C: bank reconciliation. Independent of Workstreams A/B/D --
-- builds directly against public.cash_bank_transactions as it exists
-- today (payment_method = 'bank' rows only; cash tills aren't
-- reconciled against a bank statement).
--
-- Two new tables:
--   bank_statement_lines -- one row per imported statement line (CSV
--     upload). Signed amount: positive = money in (deposit/credit),
--     negative = money out (withdrawal/debit) -- this matches how
--     banks publish statements and avoids a separate debit/credit
--     column pair.
--   bank_reconciliations -- the match between a statement line and a
--     cash_bank_transactions row. One-to-one both ways (a statement
--     line matches at most one transaction and vice versa) -- this
--     is the common case; split/partial matches aren't handled here
--     and would need a follow-up if they turn out to matter in
--     practice.
--
-- No dedup constraint on import: re-uploading the same CSV twice will
-- create duplicate statement lines. A hard uniqueness constraint on
-- (bank_account, statement_date, reference, amount) would be the fix,
-- but bank-provided `reference` values are inconsistently populated
-- (some banks omit them for cash deposits), so a false-duplicate
-- rejection would silently drop legitimate lines. Left as a known gap
-- -- surfaced in the UI instead (see BankReconciliation.tsx import
-- flow) rather than enforced in the schema.

create table if not exists public.bank_statement_lines (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references public.tenants(id) on delete cascade,
    bank_account text not null,
    statement_date date not null,
    description text,
    reference text,
    amount numeric not null,
    currency text not null default 'UGX',
    imported_by uuid,
    imported_at timestamp with time zone not null default now(),
    constraint bank_statement_lines_amount_nonzero_check check (amount != 0)
);

create index if not exists bank_statement_lines_tenant_account_date_idx
    on public.bank_statement_lines (tenant_id, bank_account, statement_date);

create table if not exists public.bank_reconciliations (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references public.tenants(id) on delete cascade,
    bank_statement_line_id uuid not null references public.bank_statement_lines(id) on delete cascade,
    cash_bank_transaction_id uuid not null references public.cash_bank_transactions(id) on delete cascade,
    match_type text not null default 'manual',
    -- Signed difference: statement amount minus the transaction's
    -- signed amount (receipt = +amount, payment = -amount). Zero for
    -- an exact match. auto_match_bank_statement() only ever creates
    -- exact (zero-variance) matches; a nonzero variance means a human
    -- force-matched two amounts that don't quite agree (bank charges,
    -- rounding, an FX difference) and it's worth a second look.
    variance numeric not null default 0,
    matched_by uuid,
    matched_at timestamp with time zone not null default now(),
    constraint bank_reconciliations_match_type_check check (match_type in ('manual', 'auto')),
    constraint bank_reconciliations_statement_line_unique unique (bank_statement_line_id),
    constraint bank_reconciliations_transaction_unique unique (cash_bank_transaction_id)
);

create index if not exists bank_reconciliations_tenant_idx
    on public.bank_reconciliations (tenant_id);

alter table public.bank_statement_lines enable row level security;
alter table public.bank_reconciliations enable row level security;

-- Same "read-only from the client, writes go through SECURITY DEFINER
-- RPCs" pattern as journal_entries -- see gl_core_schema.sql. Keeps
-- the match/unmatch/import operations auditable (matched_by, match_type)
-- rather than freely editable rows.
create policy "bank_statement_lines_select" on public.bank_statement_lines
    for select using (is_finance_team_member(null::text) and tenant_id = get_my_tenant_id());

create policy "bank_reconciliations_select" on public.bank_reconciliations
    for select using (is_finance_team_member(null::text) and tenant_id = get_my_tenant_id());

grant select on public.bank_statement_lines to authenticated;
grant select on public.bank_reconciliations to authenticated;

-- Bulk import. p_lines is a jsonb array of
-- {statement_date, description?, reference?, amount, currency?}.
create or replace function public.import_bank_statement_lines(
    p_bank_account text,
    p_lines jsonb
)
returns setof public.bank_statement_lines
language plpgsql
security definer
set search_path = public
as $$
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
$$;

grant execute on function public.import_bank_statement_lines(text, jsonb) to authenticated;

-- Manual match. Deliberately does NOT require the amounts to agree --
-- see bank_reconciliations.variance comment -- but does require both
-- rows to belong to the caller's tenant, the same bank_account, and
-- neither to already be matched (the two unique constraints on
-- bank_reconciliations enforce the "already matched" half; this
-- checks bank_account and tenant up front for a clearer error).
create or replace function public.match_bank_statement_line(
    p_statement_line_id uuid,
    p_cash_bank_transaction_id uuid
)
returns public.bank_reconciliations
language plpgsql
security definer
set search_path = public
as $$
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
$$;

grant execute on function public.match_bank_statement_line(uuid, uuid) to authenticated;

create or replace function public.unmatch_bank_reconciliation(p_reconciliation_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
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
$$;

grant execute on function public.unmatch_bank_reconciliation(uuid) to authenticated;

-- Naive auto-match pass: for each unmatched statement line in the
-- given account/date range, look for exactly one unmatched bank
-- transaction with the same signed amount and a transaction_date
-- within 5 days of the statement date. Exactly one candidate ->
-- auto-match; zero or multiple candidates -> leave it for a human
-- (ambiguous matches are exactly where a naive pass shouldn't guess).
create or replace function public.auto_match_bank_statement(
    p_bank_account text,
    p_date_from date,
    p_date_to date
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
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
$$;

grant execute on function public.auto_match_bank_statement(text, date, date) to authenticated;

-- Reporting views. security_invoker relies on the tables' own RLS,
-- same pattern as v_vat_report / v_wht_report.

create or replace view public.v_bank_statement_unmatched with (security_invoker = true) as
select l.*
from public.bank_statement_lines l
left join public.bank_reconciliations r on r.bank_statement_line_id = l.id
where r.id is null;

grant select on public.v_bank_statement_unmatched to authenticated;

create or replace view public.v_cash_bank_unmatched with (security_invoker = true) as
select t.*
from public.cash_bank_transactions t
left join public.bank_reconciliations r on r.cash_bank_transaction_id = t.id
where t.payment_method = 'bank' and r.id is null;

grant select on public.v_cash_bank_unmatched to authenticated;

-- Variance report: matched pairs where a human force-matched two
-- amounts that don't agree exactly (auto_match_bank_statement never
-- produces a nonzero variance -- see the column comment above).
create or replace view public.v_bank_reconciliation_variance with (security_invoker = true) as
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
  t.transaction_date,
  t.description as transaction_description,
  t.amount as transaction_amount,
  t.transaction_type
from public.bank_reconciliations r
join public.bank_statement_lines l on l.id = r.bank_statement_line_id
join public.cash_bank_transactions t on t.id = r.cash_bank_transaction_id
where r.variance != 0;

grant select on public.v_bank_reconciliation_variance to authenticated;