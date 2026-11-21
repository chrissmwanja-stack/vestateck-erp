-- =====================================================================
-- Platform business day: one date rule for insurance and shared finance
-- =====================================================================
--
-- DR-46 put the business day (Africa/Kampala, UTC+3, no daylight saving) in two
-- INSURANCE-named helpers, ins_local_date() and ins_local_today(). Shared finance,
-- payroll, regulatory, FX, maintenance and sustainability code could not call
-- them without depending on the insurance module, so 27 functions and four column
-- defaults still used current_date, which is the UTC date on Supabase. Between
-- 00:00 and 03:00 Kampala time those disagree with the insurance reports, with the
-- Kampala-dated frontend (apps/web/src/lib/businessDate.ts) and with each other
-- (for example the trial balance as-at date, void_journal_entry's closed-period
-- test and a payroll posting date versus a receipt posted a minute earlier).
--
-- This migration:
--   1. Adds the neutral platform helpers
--        public.business_date(timestamptz)  the business-day calendar date of an instant
--        public.business_today()            today's business-day date
--      The time zone lives in these two functions only. A per-company zone later
--      means changing them (and BUSINESS_TIME_ZONE in businessDate.ts).
--   2. Re-points ins_local_date() / ins_local_today() at the platform helpers. Same
--      signatures, volatility, search_path and grants, so every existing caller
--      keeps working and insurance and the rest of the platform cannot drift apart.
--   3. Replaces current_date with public.business_today() in the 27 functions
--      listed below, and "<timestamp column>_at::date" with
--      public.business_date(<timestamp column>_at) (one site: the payroll posting
--      trigger). Each function is rewritten from its live definition by a
--      mechanical text replacement of only those two expressions. Logic, security
--      settings, search_path and grants are untouched (CREATE OR REPLACE keeps
--      the ACL). Definitions are not copied into this file on purpose: the
--      replacement is verified by the assertions at the end of the block, and a
--      reviewer can diff the live definitions before and after.
--   4. Moves the four non-insurance CURRENT_DATE column defaults to
--      public.business_today(). (The three insurance defaults moved in
--      20261121150000.)
--
-- Functions (27):
--   accounting settings:  acct_assert_reviewed, acct_get_policy_version,
--                         acct_get_setting, acct_setting_min_effective_date,
--                         acct_settings_overview
--   bank adjustments:     approve_bank_adjustment, bank_adjustment_can_self_approve,
--                         bank_adjustment_unusual_account_usage
--   finance reports:      fin_account_ledger, fin_bank_reconciliation_position,
--                         fin_bank_review_gaps, fin_trial_balance
--   journals and FX:      void_journal_entry, fin_void_fx_revaluation,
--                         platform_fx_revalue_impl, fx_get_rate, fx_rates_guard
--   regulatory:           reg_approve_parameter, reg_assign_approver,
--                         reg_get_parameter, calculate_statutory_deductions,
--                         seed_statutory_rate_table, transition_filing
--   payroll:              trg_post_payroll_run_approval
--   maintenance:          machine_maintenance_overdue_sweep,
--                         transition_maintenance_request
--   sustainability:       sustainability_cert_expiry_sweep_impl
--
-- Column defaults (4): goods_issues.issue_date, pmo_cost_entries.entry_date,
--   pmo_time_entries.entry_date, sustainability_metrics.recorded_date.
--
-- NOT changed here (separate decision): four procurement reporting functions that
-- show a document's timestamp as a date with "<col>_at::date" (get_po_detail,
-- get_po_pdf_data, get_procurement_info, get_request_tracking). They are display
-- and filter dates, not posting or validation dates. The SQL test in
-- supabase/tests/test_platform_business_date.sql lists them as the only allowed
-- remaining sites, so any new use of current_date or "_at::date" fails CI.
--
-- Prerequisite: 20261121140000 (creates ins_local_date / ins_local_today).
-- =====================================================================

-- 1. Platform helpers ---------------------------------------------------

create or replace function public.business_date(p_ts timestamptz)
returns date
language sql
immutable
parallel safe
set search_path to 'pg_catalog'
as $$
  select (p_ts at time zone 'Africa/Kampala')::date
$$;

create or replace function public.business_today()
returns date
language sql
stable
parallel safe
set search_path to 'pg_catalog', 'public'
as $$
  select public.business_date(now())
$$;

revoke all on function public.business_date(timestamptz) from public, anon;
revoke all on function public.business_today() from public, anon;
grant execute on function public.business_date(timestamptz) to authenticated, service_role;
grant execute on function public.business_today() to authenticated, service_role;

-- 2. Insurance helpers delegate to the platform helpers -------------------

create or replace function public.ins_local_date(p_ts timestamptz)
returns date
language sql
immutable
parallel safe
set search_path to 'pg_catalog'
as $$
  select public.business_date(p_ts)
$$;

create or replace function public.ins_local_today()
returns date
language sql
stable
parallel safe
set search_path to 'pg_catalog', 'public'
as $$
  select public.business_today()
$$;

-- 3. Rewrite the 27 functions from their live definitions --------------------

do $patch$
declare
  v_targets text[] := array[
    'acct_assert_reviewed', 'acct_get_policy_version', 'acct_get_setting',
    'acct_setting_min_effective_date', 'acct_settings_overview',
    'approve_bank_adjustment', 'bank_adjustment_can_self_approve',
    'bank_adjustment_unusual_account_usage',
    'fin_account_ledger', 'fin_bank_reconciliation_position',
    'fin_bank_review_gaps', 'fin_trial_balance',
    'void_journal_entry', 'fin_void_fx_revaluation', 'platform_fx_revalue_impl',
    'fx_get_rate', 'fx_rates_guard',
    'reg_approve_parameter', 'reg_assign_approver', 'reg_get_parameter',
    'calculate_statutory_deductions', 'seed_statutory_rate_table', 'transition_filing',
    'trg_post_payroll_run_approval',
    'machine_maintenance_overdue_sweep', 'transition_maintenance_request',
    'sustainability_cert_expiry_sweep_impl'
  ];
  r record;
  v_def text;
  v_new text;
  v_seen int := 0;
  v_bad text;
begin
  for r in
    select p.oid, p.proname
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prokind = 'f' and p.proname = any (v_targets)
    order by p.proname
  loop
    v_seen := v_seen + 1;
    v_def := pg_get_functiondef(r.oid);
    -- current_date / CURRENT_DATE as a whole word (also inside "DEFAULT CURRENT_DATE").
    v_new := regexp_replace(v_def, '\mcurrent_date\M', 'public.business_today()', 'gi');
    -- <alias.>column_at::date, the timestamp-to-UTC-date cast.
    v_new := regexp_replace(
      v_new, '\m((?:[a-z_][a-z0-9_]*\.)?[a-z_][a-z0-9_]*_at)::date',
      'public.business_date(\1)', 'gi');
    if v_new <> v_def then
      execute v_new;
    end if;
  end loop;

  -- Every target must exist exactly once (an overload would be missed silently).
  if v_seen <> array_length(v_targets, 1) then
    raise exception 'business-date patch: expected % functions, found % (missing or overloaded)',
      array_length(v_targets, 1), v_seen;
  end if;

  -- And none may still use the UTC date.
  select string_agg(p.proname, ', ')
    into v_bad
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.prokind = 'f' and p.proname = any (v_targets)
    and regexp_replace(pg_get_functiondef(p.oid), '--[^\n]*', '', 'g')
        ~* '\mcurrent_date\M|_at::date';
  if v_bad is not null then
    raise exception 'business-date patch: still on the UTC date: %', v_bad;
  end if;
end
$patch$;

-- 4. Non-insurance column defaults ---------------------------------------

alter table public.goods_issues           alter column issue_date    set default public.business_today();
alter table public.pmo_cost_entries       alter column entry_date    set default public.business_today();
alter table public.pmo_time_entries       alter column entry_date    set default public.business_today();
alter table public.sustainability_metrics alter column recorded_date set default public.business_today();
