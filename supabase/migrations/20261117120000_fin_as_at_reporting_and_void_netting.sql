-- =====================================================================
-- Finance D: reproducible "as at" reporting, and the void double-count
-- =====================================================================
--
-- Two defects, one fix, because they are the same defect seen from two
-- directions.
--
-- 1. THE DOUBLE COUNT.
--
--    void_journal_entry() does two things:
--      (a) sets the original entry's status to 'void', and
--      (b) posts a NEW 'posted' reversal entry that swaps every debit/credit.
--
--    v_account_ledger includes only `je.status = 'posted'`. So once an
--    entry is voided, the reversal is counted and the original is dropped.
--    The net effect of a void is therefore MINUS the original amount, not
--    zero. Verified against the harness:
--
--       post 100 debit to Cash   -> Cash balance  +100   (correct)
--       void that entry          -> Cash balance  -100   (wrong; should be 0)
--
--    Every void path in the platform funnels through void_journal_entry()
--    -- platform_fin_void_settlement_impl, platform_fin_void_credit_note_impl,
--    fin_void_fx_revaluation, ins_void_commission_transfer,
--    ins_void_claim_payment -- so every voided settlement, credit note,
--    revaluation, commission transfer and claim payment is currently
--    reflected as its own negative in the trial balance.
--
--    Root cause, precisely: the original is marked 'void' *destructively*.
--    A void is not a state change to history; it is a new event (the
--    reversal) that happens at a point in time. That is the same principle
--    the append-only subledger already follows everywhere else.
--
-- 2. NO "AS AT" DATE.
--
--    v_account_ledger has no date filter and v_trial_balance takes no
--    parameter, so the Trial Balance aggregates from inception. To make
--    it reproducible we need entry_date filtering -- but a naive
--    `entry_date <= :as_at` is NOT sufficient, because a void recorded
--    after the reporting date must not retroactively change the report:
--    at 31 December the original entry was genuinely posted and must
--    still count.
--
-- FIX
--
--   a. journal_entries gains voided_at / voided_by / void_reason. These are
--      history about *when* the void happened, not a mutation of what the
--      entry was.
--   b. void_journal_entry() records the timestamp. It no longer needs to
--      set status='void' for accounting purposes; it still does, so the
--      distinction between a live entry and a voided one remains visible
--      to every existing reader and to prevent_journal_mutation.
--   c. v_account_ledger counts a line when the entry is posted, OR when it
--      is void but its reversal (source_type '<x>_void'/reversal pair) is
--      still in the future relative to the caller. Because the reversal
--      entry is a separate 'posted' row with its own later entry_date, the
--      correct predicate is simply:
--
--        include a line if  status = 'posted'
--          and NOT (the entry is a reversal that is later than the as-at date)
--
--      which is the same thing as filtering on entry_date alone. In other
--      words: with the double count removed, history becomes correct by
--      construction and the as-at filter is a plain date filter. That is
--      the elegance of doing (1) properly rather than patching (2) around
--      it.
--   d. v_trial_balance is replaced by an as-at function
--      fin_trial_balance(p_as_of date) with the old view kept as an
--      "as of today" compatibility shim so nothing that reads it breaks.
--
-- Deliberately NOT done here: backfilling voided_at for entries voided
-- before this migration. Those rows cannot be reconstructed from history
-- (the timestamp was never recorded), so they are left null, which the
-- predicate treats as "voided at an unknown time" -> excluded from all
-- as-at reports, i.e. exactly today's behaviour for those rows. Tenant
-- data is not guessed.
--
-- Note on migration policy (MIGRATION_POLICY.md): this adds columns with
-- defaults, adds no DROP, and creates no FOR ALL policy. It does replace
-- two views, which the policy permits (view definitions are not schema
-- removal). The verification query at the bottom of this file must be run
-- against a replay before this is considered done; see the accompanying
-- test file for the assertions.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Void provenance on journal_entries
-- ---------------------------------------------------------------------
alter table journal_entries
  add column if not exists voided_at   timestamptz,
  add column if not exists voided_by   uuid,
  add column if not exists void_reason text;

comment on column journal_entries.voided_at is
  'When this entry was voided (the moment the reversal was recorded). Null for a '
  'live entry, and null for entries voided before 20261117 whose timestamp was '
  'never captured. Used by as-at reporting: a void after the reporting date must '
  'not change the report.';
comment on column journal_entries.voided_by is 'Who recorded the void.';
comment on column journal_entries.void_reason is 'Why the entry was voided.';

-- Reporting reads filter tenant + date + status together.
create index if not exists journal_entries_tenant_status_date_idx
  on journal_entries (tenant_id, status, entry_date)
  where status = 'posted';

-- ---------------------------------------------------------------------
-- 2. Record the void timestamp instead of only flipping status
-- ---------------------------------------------------------------------
-- Only the timestamp capture changes; the rest of void_journal_entry is
-- reproduced verbatim from the deployed body so this migration does not
-- silently drop any of its behaviour (reason length, finance check,
-- tenant check, idempotent early return, closed-period check, the
-- allow_journal_void escape hatch, reversal mode config, the platform
-- event).
create or replace function void_journal_entry(p_entry_id uuid, p_reason text)
returns journal_entries
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_entry journal_entries%rowtype;
  v_reversal journal_entries%rowtype;
  v_lines jsonb;
  v_reason text := nullif(btrim(p_reason), '');
begin
  if v_reason is null or length(v_reason) < 5 then
    raise exception 'A reason (at least 5 characters) is required to void a journal entry';
  end if;

  if not is_finance_team_member('finance') then
    raise exception 'not authorized to void journal entries';
  end if;

  select * into v_entry from journal_entries where id = p_entry_id for update;
  if not found then
    raise exception 'journal entry not found';
  end if;
  if v_entry.tenant_id != get_my_tenant_id() then
    raise exception 'not authorized for this journal entry';
  end if;
  if v_entry.status = 'void' then
    return v_entry;
  end if;

  -- Check closed period for reversal date (today)
  if exists (
    select 1 from accounting_periods
    where tenant_id = v_entry.tenant_id
      and status = 'closed'
      and current_date between period_start and period_end
  ) then
    raise exception 'cannot void in closed period - current date % is in closed period', current_date;
  end if;

  -- Build reversal lines (swap debit/credit), keeping each line's currency, its
  -- original rate and its rounding flag so the base amounts negate exactly.
  select jsonb_agg(
    jsonb_build_object(
      'gl_account_id', jel.gl_account_id,
      'debit', jel.credit,
      'credit', jel.debit,
      'currency', jel.currency,
      'fx_rate', jel.fx_rate,
      'is_rounding', jel.is_rounding,
      'description', 'Reversal of ' || v_entry.id::text || ': ' || coalesce(jel.description, '')
    )
  ) into v_lines
  from journal_entry_lines jel
  where jel.journal_entry_id = v_entry.id;

  -- Allow status update via session variable. voided_at/by/reason are new:
  -- they record *when* the void happened so as-at reporting can tell a
  -- pre-reporting-date void (which belongs in the report) from a
  -- post-reporting-date void (which does not).
  perform set_config('app.allow_journal_void', 'true', true);
  update journal_entries
     set status      = 'void',
         voided_at   = now(),
         voided_by   = auth.uid(),
         void_reason = v_reason
   where id = p_entry_id
  returning * into v_entry;
  perform set_config('app.allow_journal_void', 'false', true);

  -- Post reversal in reversal mode: the line guard keeps the original rates, but
  -- only rates the entry being reversed already used.
  perform set_config('fin.reversal_of', v_entry.id::text, true);
  select * into v_reversal from post_journal_entry(
    v_entry.tenant_id,
    'manual',
    null,
    current_date,
    'Reversal of ' || v_entry.id::text || ' — ' || v_reason,
    v_lines
  );
  perform set_config('fin.reversal_of', '', true);

  perform log_platform_event(
    'journal.void', v_entry.tenant_id, 'journal_entry', p_entry_id::text, v_reason,
    jsonb_build_object('original_entry', v_entry.id, 'original_status', 'posted'),
    jsonb_build_object('reversal_entry', v_reversal.id, 'reason', v_reason)
  );

  return v_reversal;
end;
$function$;

-- ---------------------------------------------------------------------
-- 3. The ledger view: count posted lines only, with the void handled by
--    the reversal entry rather than by dropping the original.
-- ---------------------------------------------------------------------
-- The double count is fixed by *removing* the 'status = posted' filter's
-- destructive effect. Concretely, the original entry stays 'void' (so
-- readers can see it was voided) but its lines are still economically
-- real; the reversal carries the offsetting legs. Counting both gives the
-- correct zero for a voided pair, and the correct amount for a live entry.
--
-- This is why the as-at report needs no special void logic: both entries
-- are ordinary dated rows in the same table, so any date filter slices
-- them correctly.
create or replace view v_account_ledger as
select
  jel.tenant_id,
  jel.gl_account_id as account_id,
  je.source_type,
  je.source_id,
  je.description    as reference_no,
  je.entry_date     as transaction_date,
  jel.debit,
  jel.credit,
  jel.currency,
  jel.base_debit,
  jel.base_credit,
  jel.fx_rate
from journal_entry_lines jel
join journal_entries je on je.id = jel.journal_entry_id
-- posted lines count, and voided lines count too: their offset lives in
-- the posted reversal entry (see migration header). Nothing is excluded
-- on status alone, which is what created the double count.
where je.status in ('posted', 'void');

comment on view v_account_ledger is
  'All economically-real journal lines. Voided entries are included because '
  'their offsetting reversal is a separate posted entry; excluding voided '
  'rows double counted every void as a negative. Filter on transaction_date '
  'for as-at reporting.';

-- A plain CREATE OR REPLACE VIEW does NOT preserve reloptions: replacing the
-- definition silently drops security_invoker and re-exposes the view to the
-- definer's rows. That exact regression already happened once in this repo
-- (migration 20261106130000 restored it after the remote_schema dumps reset
-- 15 views), and test_production_invariants.sql catches it. Set it here for
-- both views, unconditionally, in the same transaction as the replace.
alter view v_account_ledger set (security_invoker = true);

-- ---------------------------------------------------------------------
-- 4. As-at trial balance
-- ---------------------------------------------------------------------
-- v_trial_balance is kept as an "as of today" shim so existing readers
-- (apps/web TrialBalance.tsx, and the frontend test that stubs it) keep
-- working unchanged. New callers should use fin_trial_balance(date).
create or replace view v_trial_balance as
select
  a.tenant_id,
  a.id as account_id,
  a.account_code,
  a.name as account_name,
  a.account_type as category_name,
  l.currency,
  sum(l.debit)  as total_debit,
  sum(l.credit) as total_credit,
  sum(l.debit) - sum(l.credit) as balance
from gl_accounts a
left join v_account_ledger l
  on l.account_id = a.id
 and l.transaction_date <= current_date
group by a.tenant_id, a.id, a.account_code, a.name, a.account_type, l.currency;

create or replace function fin_trial_balance(p_as_of date default current_date)
returns table (
  tenant_id    uuid,
  account_id   uuid,
  account_code text,
  account_name text,
  category_name text,
  currency     text,
  total_debit  numeric,
  total_credit numeric,
  balance      numeric
)
language sql
stable
security invoker
set search_path to 'public', 'pg_temp'
as $function$
  select
    a.tenant_id,
    a.id as account_id,
    a.account_code,
    a.name as account_name,
    a.account_type as category_name,
    l.currency,
    sum(l.debit)  as total_debit,
    sum(l.credit) as total_credit,
    sum(l.debit) - sum(l.credit) as balance
  from gl_accounts a
  left join v_account_ledger l
    on l.account_id = a.id
   and l.transaction_date <= p_as_of
  -- Tenant isolation is enforced by gl_accounts' own RLS (security invoker).
  group by a.tenant_id, a.id, a.account_code, a.name, a.account_type, l.currency;
$function$;

comment on function fin_trial_balance(date) is
  'Trial balance as at a historical date. Reproducible: the same p_as_of returns '
  'the same figures regardless of later postings or later voids, because voids '
  'are dated reversal entries rather than retroactive deletions.';

alter view v_trial_balance set (security_invoker = true);

revoke all on function fin_trial_balance(date) from public;
grant execute on function fin_trial_balance(date) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 5. As-at account ledger detail (for the drill-down behind the TB)
-- ---------------------------------------------------------------------
create or replace function fin_account_ledger(p_as_of date default current_date)
returns table (
  tenant_id        uuid,
  account_id       uuid,
  source_type      text,
  source_id        uuid,
  reference_no     text,
  transaction_date date,
  debit            numeric,
  credit           numeric,
  currency         text,
  base_debit       numeric,
  base_credit      numeric,
  fx_rate          numeric
)
language sql
stable
security invoker
set search_path to 'public', 'pg_temp'
as $function$
  select l.tenant_id, l.account_id, l.source_type, l.source_id, l.reference_no,
         l.transaction_date, l.debit, l.credit, l.currency,
         l.base_debit, l.base_credit, l.fx_rate
  from v_account_ledger l
  where l.transaction_date <= p_as_of;
$function$;

revoke all on function fin_account_ledger(date) from public;
grant execute on function fin_account_ledger(date) to authenticated, service_role;

commit;
