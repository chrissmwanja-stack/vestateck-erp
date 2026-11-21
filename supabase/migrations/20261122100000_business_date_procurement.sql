-- =====================================================================
-- Business day: procurement tracking dates (follow-up to 20261122090000)
-- =====================================================================
--
-- 20261122090000 moved 27 functions and four column defaults to the platform
-- business day (Africa/Kampala) and left four procurement reporting functions
-- for a separate decision. They show a document's timestamp as a date with
-- "<timestamp column>_at::date", which is the UTC date: a purchase order generated
-- at 01:00 Kampala time showed the previous day, and the date-range filters in
-- get_request_tracking compared against those same UTC dates.
--
-- This migration replaces "<alias.>column_at::date" with
-- public.business_date(<alias.>column_at) in:
--   get_po_detail          (MR date)                                  1 site
--   get_po_pdf_data        (PO date)                                  1 site
--   get_procurement_info   (PO date)                                  1 site
--   get_request_tracking   (MR, PO, market-offer and closing dates)   4 sites
-- Each function is rewritten from its live definition by a mechanical text
-- replacement of only that expression. Logic, SECURITY DEFINER, search_path and
-- grants are unchanged (CREATE OR REPLACE keeps the ACL). The block fails if a
-- function is missing or overloaded, or if any UTC date use remains.
--
-- After this migration supabase/tests/test_platform_business_date.sql fails CI on
-- any public function that uses current_date or "<column>_at::date".
--
-- Prerequisite: 20261122090000 (creates public.business_date()).
-- =====================================================================

do $patch$
declare
  v_targets text[] := array[
    'get_po_detail', 'get_po_pdf_data', 'get_procurement_info', 'get_request_tracking'
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
    v_new := regexp_replace(v_def, '\mcurrent_date\M', 'public.business_today()', 'gi');
    v_new := regexp_replace(
      v_new, '\m((?:[a-z_][a-z0-9_]*\.)?[a-z_][a-z0-9_]*_at)::date',
      'public.business_date(\1)', 'gi');
    if v_new <> v_def then
      execute v_new;
    end if;
  end loop;

  if v_seen <> array_length(v_targets, 1) then
    raise exception 'business-date patch: expected % functions, found % (missing or overloaded)',
      array_length(v_targets, 1), v_seen;
  end if;

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
