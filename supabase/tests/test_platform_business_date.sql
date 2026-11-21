-- Platform business day (20261122090000): one Africa/Kampala date rule.
-- Run only on a disposable local/test database; everything rolls back.
\set ON_ERROR_STOP on
begin;

-- 1. The helpers date an instant by the Kampala calendar day. ------------------
do $$
begin
  -- 20:59:59 UTC is 23:59:59 in Kampala: still the same day.
  assert public.business_date('2026-11-21 20:59:59+00'::timestamptz) = date '2026-11-21',
    'business_date at 20:59:59 UTC should still be 21 Nov';
  -- 21:00:00 UTC is 00:00:00 the next day in Kampala.
  assert public.business_date('2026-11-21 21:00:00+00'::timestamptz) = date '2026-11-22',
    'business_date at 21:00:00 UTC should be 22 Nov';
  -- Month and year boundaries.
  assert public.business_date('2026-11-30 22:00:00+00'::timestamptz) = date '2026-12-01',
    'month boundary';
  assert public.business_date('2026-12-31 21:30:00+00'::timestamptz) = date '2027-01-01',
    'year boundary';
  -- The offset input does not matter, only the instant.
  assert public.business_date('2026-11-05 02:59:00+03'::timestamptz) = date '2026-11-05',
    'a Kampala wall-clock time keeps its own date';
  assert public.business_date('2026-11-04 22:00:00+00'::timestamptz) = date '2026-11-05',
    'the 1 a.m. case: 22:00 UTC on the 4th is the 5th in Kampala';
end
$$;

-- 2. business_today() is the date of now() on the same clock. ------------------
do $$
begin
  assert public.business_today() = public.business_date(now()),
    'business_today() must equal business_date(now())';
end
$$;

-- 3. The insurance helpers are thin wrappers, so insurance and the platform
--    cannot disagree. -----------------------------------------------------------
do $$
declare
  ts timestamptz;
begin
  assert public.ins_local_today() = public.business_today(),
    'ins_local_today() must equal business_today()';
  foreach ts in array array[
    '2026-11-21 20:59:59+00', '2026-11-21 21:00:00+00', '2026-12-31 21:30:00+00',
    '2026-02-28 23:30:00+00'
  ]::timestamptz[]
  loop
    assert public.ins_local_date(ts) = public.business_date(ts),
      format('ins_local_date(%s) must equal business_date()', ts);
  end loop;
end
$$;

-- 4. Grants: the helpers run as the calling role (column defaults, invoker
--    functions), so authenticated and service_role must reach them and anon must not.
do $$
begin
  assert has_function_privilege('authenticated', 'public.business_today()', 'execute'), 'authenticated business_today';
  assert has_function_privilege('service_role',  'public.business_today()', 'execute'), 'service_role business_today';
  assert has_function_privilege('authenticated', 'public.business_date(timestamptz)', 'execute'), 'authenticated business_date';
  assert has_function_privilege('service_role',  'public.business_date(timestamptz)', 'execute'), 'service_role business_date';
  assert not has_function_privilege('anon', 'public.business_today()', 'execute'), 'anon must not run business_today';
  assert not has_function_privilege('anon', 'public.business_date(timestamptz)', 'execute'), 'anon must not run business_date';
end
$$;

-- 5. Ratchet: no public function may use the UTC date. -------------------------
--    current_date is the UTC date on Supabase. Use public.business_today().
--    "<column>_at::date" is a UTC cast. Use public.business_date(<column>_at).
do $$
declare
  v_current_date text;
  v_cast text;
begin
  select string_agg(p.proname, ', ' order by p.proname)
    into v_current_date
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.prokind = 'f'
    and regexp_replace(pg_get_functiondef(p.oid), '--[^\n]*', '', 'g') ~* '\mcurrent_date\M';
  assert v_current_date is null,
    'functions still using current_date (the UTC date): ' || coalesce(v_current_date, '');

  select string_agg(p.proname, ', ' order by p.proname)
    into v_cast
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.prokind = 'f'
    and regexp_replace(pg_get_functiondef(p.oid), '--[^\n]*', '', 'g') ~* '_at::date';
  assert v_cast is null,
    'functions still casting a timestamp column to a UTC date: ' || coalesce(v_cast, '');
end
$$;

-- 6. Ratchet: no column default may use the UTC date. --------------------------
do $$
declare
  v_cols text;
begin
  select string_agg(table_name || '.' || column_name, ', ' order by table_name, column_name)
    into v_cols
  from information_schema.columns
  where table_schema = 'public'
    and column_default ~* 'current_date|now\(\)::date|current_timestamp::date';
  assert v_cols is null, 'column defaults still on the UTC date: ' || coalesce(v_cols, '');
end
$$;

-- 7. The rewritten functions kept their security settings. ---------------------
--    CREATE OR REPLACE keeps the ACL; this checks the definer flag and that no
--    rewritten SECURITY DEFINER function lost its fixed search_path.
do $$
declare
  v_bad text;
begin
  select string_agg(p.proname, ', ' order by p.proname)
    into v_bad
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.prokind = 'f' and p.prosecdef
    and p.proname in (
      'acct_get_setting', 'approve_bank_adjustment', 'void_journal_entry', 'fx_get_rate',
      'reg_get_parameter', 'trg_post_payroll_run_approval', 'transition_maintenance_request',
      'get_po_detail', 'get_po_pdf_data', 'get_procurement_info', 'get_request_tracking')
    and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%');
  assert v_bad is null, 'SECURITY DEFINER functions without a fixed search_path: ' || coalesce(v_bad, '');
end
$$;

-- 8. The procurement tracking functions date documents by the Kampala day. --------
do $$
declare
  v_bad text;
begin
  select string_agg(p.proname, ', ' order by p.proname)
    into v_bad
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.prokind = 'f'
    and p.proname in ('get_po_detail', 'get_po_pdf_data', 'get_procurement_info', 'get_request_tracking')
    and pg_get_functiondef(p.oid) !~ 'public\.business_date\(';
  assert v_bad is null, 'procurement functions not using business_date(): ' || coalesce(v_bad, '');
end
$$;

rollback;
