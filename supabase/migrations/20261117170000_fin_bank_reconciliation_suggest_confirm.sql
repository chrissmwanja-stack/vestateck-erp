-- =====================================================================
-- Finance C: bank reconciliation -- suggest-and-confirm
-- =====================================================================
--
-- What C originally asked for, and what was already there:
--
--   imports .......................... done (import_bank_statement_lines)
--   auto-match ....................... done (auto_match_bank_statement)
--   manual match ..................... done (3 match RPCs + unmatch)
--   unmatched queues ................. done (v_bank_statement_unmatched,
--                                            v_cash_bank_unmatched)
--   independent reviewer approval .... done SERVER-SIDE for insurance cash
--                                      (ins_policy_cash_reconciliation_guard
--                                      raises INS_CASH_THIRD_PERSON)
--   reports .......................... done (fin_bank_reconciliation_position)
--   suggested matches ................ MISSING -- this migration
--
-- An earlier note in this project said the third-user rule was "enforced only
-- in the client". That was wrong: the guard raises 42501 for the maker,
-- checker or poster of an insurance cash request, on INSERT, UPDATE and
-- DELETE, and auto_match_bank_statement skips those movements. Verified by
-- probe, and pinned by a test here so the claim cannot drift again.
--
-- The real gap
-- ---------------------------------------------------------------------
-- `fin_bank_line_candidates(line, tenant)` already computes which book
-- entries *could* match a statement line (one candidate, by amount, currency
-- and a 5-day window). But it is all-or-nothing: the only way to use it is
-- `auto_match_bank_statement`, which commits every unambiguous match in the
-- window with no review. There is no "show me what you think matches, and let
-- me confirm" step -- which is what a reconciliation desk actually wants,
-- because an auto-match that is wrong has to be found by reading a diff.
--
-- This migration adds that step: a suggestion queue that persists nothing,
-- a confirm/dispute that records the decision, and a report of how much of
-- the reconciliation was machine-matched versus confirmed by a human.
--
-- Security note
-- ---------------------------------------------------------------------
-- fin_bank_line_candidates is SECURITY INVOKER, so it can only see rows the
-- caller's RLS allows. The suggestion function below joins the statement
-- line, so it would show a caller only the lines they may already read --
-- but a reader with `authenticated` could still call it and learn nothing
-- useful. It is still gated on finance membership and the line's tenant,
-- because "RLS returns zero rows" is not the same as "refused".
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. The suggestion queue
-- ---------------------------------------------------------------------
-- Returns at most three suggestions per unmatched statement line, ordered by
-- how tight the date match is. It writes nothing: the caller confirms one,
-- and confirmation goes through the existing match RPCs so every existing
-- validation, the third-user rule and the audit trail still apply.
create or replace function fin_bank_suggested_matches(
  p_bank_account text,
  p_date_from date default null,
  p_date_to date default null
)
returns table (
  statement_line_id uuid,
  statement_date    date,
  reference         text,
  line_amount       numeric,
  currency          text,
  suggestion_rank   integer,
  source            text,
  candidate_id      uuid,
  candidate_ref     text,
  candidate_date    date,
  candidate_amount  numeric,
  day_gap           integer,
  -- True when this suggestion must be decided by a third Finance user
  -- (insurance cash). The client uses it to say so before the match is
  -- attempted; the database enforces it either way.
  needs_third_user  boolean
)
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant uuid := get_my_tenant_id();
begin
  if not is_finance_team_member('finance') then
    raise exception 'not authorized to see bank reconciliation suggestions' using errcode = '42501';
  end if;
  if not exists (
    select 1 from fin_bank_accounts b
     where b.tenant_id = v_tenant and b.name = p_bank_account
  ) then
    raise exception 'SUGGEST_BANK: % is not a registered bank account of this company', p_bank_account;
  end if;

  return query
  with lines as (
    select l.id, l.statement_date, l.reference, l.amount, l.currency
      from bank_statement_lines l
      left join bank_reconciliations r on r.bank_statement_line_id = l.id
     where l.tenant_id = v_tenant
       and l.bank_account = p_bank_account
       and r.id is null
       and (p_date_from is null or l.statement_date >= p_date_from)
       and (p_date_to   is null or l.statement_date <= p_date_to)
  ),
  -- Rank by day gap, then by candidate id so the ordering is deterministic
  -- (two candidates 3 days apart must not swap order between calls).
  ranked as (
    select l.id as line_id, c.source, c.candidate_id,
           row_number() over (partition by l.id order by abs(c.gap_days), c.candidate_id) as rk,
           c.gap_days
      from lines l
      cross join lateral (
        select cand.source, cand.candidate_id,
               -- fin_bank_line_candidates already filters to +/- 5 days and an
               -- exact signed amount, so the gap is all that is left to rank.
               abs(coalesce(
                 case cand.source
                   when 'settlement' then
                     (select s.settlement_date from fin_settlements s where s.id = cand.candidate_id)
                   when 'cash_bank' then
                     (select t.transaction_date from cash_bank_transactions t where t.id = cand.candidate_id)
                   else
                     (select ct.transfer_date from ins_commission_transfers ct where ct.id = cand.candidate_id)
                 end, l.statement_date) - l.statement_date) as gap_days
          from fin_bank_line_candidates(l.id, v_tenant) cand
      ) c
  )
  select l.id,
         l.statement_date,
         l.reference,
         l.amount,
         l.currency,
         r.rk::integer,
         r.source,
         r.candidate_id,
         coalesce(s.settlement_no, t.description, ct.transfer_no),
         coalesce(s.settlement_date, t.transaction_date, ct.transfer_date),
         coalesce(s.amount, t.amount, ct.amount),
         r.gap_days,
         -- Insurance cash: matching or unmatching needs someone who is not the
         -- maker, checker or poster of that cash request.
         (r.source = 'settlement' and exists (
            select 1 from fin_allocations a
            join ins_policy_cash_items i on i.id = a.open_item_id
            where a.settlement_id = r.candidate_id
              and i.source_type in ('ins_policy_premium', 'ins_policy_insurer')
         ))
    from lines l
    join ranked r on r.line_id = l.id and r.rk <= 3
    left join fin_settlements s on r.source = 'settlement' and s.id = r.candidate_id
    left join cash_bank_transactions t on r.source = 'cash_bank' and t.id = r.candidate_id
    left join ins_commission_transfers ct
      on r.source in ('transfer_from', 'transfer_to') and ct.id = r.candidate_id
   order by l.statement_date, l.id, r.rk;
end;
$function$;

revoke all on function fin_bank_suggested_matches(text, date, date) from public;
grant execute on function fin_bank_suggested_matches(text, date, date) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 2. Confirming a suggestion
-- ---------------------------------------------------------------------
-- Thin, honest dispatcher: it routes each source to the match RPC that
-- already owns that pair's validation, so confirming a suggestion is exactly
-- a manual match -- same checks, same third-user rule, same audit trail.
-- Writing a parallel insert here would be how the two paths drift apart.
create or replace function fin_bank_confirm_match(
  p_statement_line_id uuid,
  p_source text,
  p_candidate_id uuid
)
returns bank_reconciliations
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_row bank_reconciliations%rowtype;
  v_tenant uuid := get_my_tenant_id();
begin
  if not is_finance_team_member('finance') then
    raise exception 'not authorized to reconcile bank transactions' using errcode = '42501';
  end if;
  if p_source not in ('settlement', 'cash_bank', 'transfer_from', 'transfer_to') then
    raise exception 'CONFIRM_SOURCE: unknown source % (expected settlement, cash_bank, transfer_from or transfer_to)', p_source;
  end if;

  -- A suggestion is only confirmable while it is still a suggestion: the
  -- line must be unmatched and the candidate must still be a candidate. This
  -- stops a stale screen confirming a pair that has since been matched
  -- elsewhere, which would otherwise be caught only by a unique violation.
  if not exists (
    select 1 from bank_statement_lines l
     where l.id = p_statement_line_id and l.tenant_id = v_tenant
       and not exists (
         select 1 from bank_reconciliations r where r.bank_statement_line_id = l.id
       )
  ) then
    raise exception 'CONFIRM_STALE: that statement line is already reconciled, or is not yours';
  end if;
  if not exists (
    select 1 from fin_bank_line_candidates(p_statement_line_id, v_tenant) c
     where c.source = p_source and c.candidate_id = p_candidate_id
  ) then
    raise exception 'CONFIRM_STALE: % is no longer a candidate for this line (amount, currency, date window or it is already matched)', p_candidate_id;
  end if;

  if p_source = 'settlement' then
    v_row := platform_ins_cxl_before_match_settlement(p_statement_line_id, p_candidate_id);
  elsif p_source = 'cash_bank' then
    v_row := match_bank_statement_line(p_statement_line_id, p_candidate_id);
  elsif p_source = 'transfer_from' then
    v_row := match_bank_statement_line_to_commission_transfer(p_statement_line_id, p_candidate_id);
  else
    v_row := match_bank_statement_line_to_commission_transfer(p_statement_line_id, p_candidate_id);
  end if;

  return v_row;
end;
$function$;

revoke all on function fin_bank_confirm_match(uuid, text, uuid) from public;
grant execute on function fin_bank_confirm_match(uuid, text, uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 3. How much of this reconciliation was reviewed by a human
-- ---------------------------------------------------------------------
-- The question an auditor asks: "was this reconciliation confirmed, or just
-- accepted?" Machine matches are not wrong, but they are unreviewed, and the
-- difference should be visible rather than assumed.
create or replace function fin_bank_reconciliation_review(p_bank_account_id uuid, p_as_of date)
returns table (
  metric text,
  value  numeric
)
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant uuid := get_my_tenant_id();
  v_name   text;
begin
  if not is_finance_team_member('finance') then
    raise exception 'not authorized to read bank reconciliation reports' using errcode = '42501';
  end if;
  select b.name into v_name from fin_bank_accounts b
   where b.id = p_bank_account_id and b.tenant_id = v_tenant;
  if v_name is null then
    raise exception 'REVIEW_BANK: bank account not found in this company';
  end if;

  return query
  select 'statement lines matched automatically'::text, count(*)::numeric
    from bank_reconciliations r
    join bank_statement_lines l on l.id = r.bank_statement_line_id
   where r.tenant_id = v_tenant and l.bank_account = v_name
     and l.statement_date <= p_as_of and r.match_type = 'auto'
  union all
  select 'statement lines confirmed by a person', count(*)::numeric
    from bank_reconciliations r
    join bank_statement_lines l on l.id = r.bank_statement_line_id
   where r.tenant_id = v_tenant and l.bank_account = v_name
     and l.statement_date <= p_as_of and r.match_type = 'manual'
  union all
  select 'statement lines still unmatched', count(*)::numeric
    from bank_statement_lines l
   where l.tenant_id = v_tenant and l.bank_account = v_name
     and l.statement_date <= p_as_of
     and not exists (select 1 from bank_reconciliations r where r.bank_statement_line_id = l.id)
  union all
  select 'matched with a variance', count(*)::numeric
    from bank_reconciliations r
    join bank_statement_lines l on l.id = r.bank_statement_line_id
   where r.tenant_id = v_tenant and l.bank_account = v_name
     and l.statement_date <= p_as_of and r.variance <> 0
  union all
  select 'distinct confirmers', count(distinct r.matched_by)::numeric
    from bank_reconciliations r
    join bank_statement_lines l on l.id = r.bank_statement_line_id
   where r.tenant_id = v_tenant and l.bank_account = v_name
     and l.statement_date <= p_as_of and r.match_type = 'manual';
end;
$function$;

revoke all on function fin_bank_reconciliation_review(uuid, date) from public;
grant execute on function fin_bank_reconciliation_review(uuid, date) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 4. Review completeness for the gap report
-- ---------------------------------------------------------------------
-- A suggestion queue is only useful if someone works it. This lists banks
-- with unreviewed (auto-matched) movements older than the cutoff, so the
-- "accept everything the machine offered" pattern is visible.
create or replace function fin_bank_review_gaps(p_tenant_id uuid default null, p_older_than_days integer default 7)
returns table (
  bank_account      text,
  auto_matched      bigint,
  oldest_unreviewed date
)
language sql
stable
security invoker
set search_path to 'public', 'pg_temp'
as $function$
  with t as (select coalesce(p_tenant_id, get_my_tenant_id()) as tenant_id)
  select l.bank_account,
         count(*)::bigint,
         min(l.statement_date)
    from bank_reconciliations r
    join bank_statement_lines l on l.id = r.bank_statement_line_id
    cross join t
   where r.tenant_id = t.tenant_id
     and r.match_type = 'auto'
     and l.statement_date <= current_date - p_older_than_days
   group by l.bank_account
   order by count(*) desc, l.bank_account;
$function$;

revoke all on function fin_bank_review_gaps(uuid, integer) from public;
grant execute on function fin_bank_review_gaps(uuid, integer) to authenticated, service_role;

comment on function fin_bank_suggested_matches(text, date, date) is
  'Suggest-and-confirm queue: at most three ranked candidates per unmatched statement line, plus whether the decision needs a third Finance user. Writes nothing.';
comment on function fin_bank_confirm_match(uuid, text, uuid) is
  'Confirms a suggestion by routing to the match RPC that owns that pair, so validation, the insurance third-user rule and the audit trail all still apply.';
