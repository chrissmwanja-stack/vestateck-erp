-- D4e: the review report must not count an adjustment as something a person
-- confirmed.
--
-- 20261119235951 allows match_type = 'adjustment' so approve_bank_adjustment can
-- post at all (it was raising a check violation before that). The two review
-- functions count rows by match_type = 'manual' / 'auto' and treat everything
-- else as "unmatched":
--
--   fin_bank_reconciliation_review: 'statement lines confirmed by a person'
--     would silently omit adjustment-cleared lines, and 'statement lines still
--     unmatched' counts lines with NO reconciliation row, so a cleared line
--     would vanish from both totals and the counts would not add up to the
--     lines on the statement.
--   fin_bank_review_gaps: only looks at 'auto', so it is unaffected - it is
--     recreated here only so both functions in this area agree; its body is
--     unchanged apart from the comment.
--
-- A bank adjustment IS a person's decision, but a different kind of evidence
-- from confirming a suggested match, so it gets its own line rather than being
-- folded into either total. That keeps every statement line in exactly one
-- bucket: auto / confirmed by a person / cleared by an adjustment / unmatched.
--
-- Fix forward (rule 9): 20261117170000 is not edited. Same signatures, same
-- grants (re-stated at the end), and the added row is appended last so any
-- caller that reads these as an ordered list keeps the same first four rows.

create or replace function public.fin_bank_reconciliation_review(p_bank_account_id uuid, p_as_of date)
returns table (metric text, value numeric)
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_name   text;
begin
  if v_tenant is null then
    raise exception 'REVIEW_NO_TENANT: no company for this session' using errcode = '42501';
  end if;
  if p_as_of is null then
    raise exception 'REVIEW_AS_OF: an as-of date is required';
  end if;
  select b.name into v_name from public.fin_bank_accounts b
   where b.id = p_bank_account_id and b.tenant_id = v_tenant;
  if v_name is null then
    raise exception 'REVIEW_BANK: bank account not found in this company';
  end if;

  return query
  select 'statement lines matched automatically'::text, count(*)::numeric
    from public.bank_reconciliations r
    join public.bank_statement_lines l on l.id = r.bank_statement_line_id
   where r.tenant_id = v_tenant and l.bank_account = v_name
     and l.statement_date <= p_as_of and r.match_type = 'auto'
  union all
  select 'statement lines confirmed by a person', count(*)::numeric
    from public.bank_reconciliations r
    join public.bank_statement_lines l on l.id = r.bank_statement_line_id
   where r.tenant_id = v_tenant and l.bank_account = v_name
     and l.statement_date <= p_as_of and r.match_type = 'manual'
  union all
  select 'statement lines still unmatched', count(*)::numeric
    from public.bank_statement_lines l
   where l.tenant_id = v_tenant and l.bank_account = v_name
     and l.statement_date <= p_as_of
     and not exists (select 1 from public.bank_reconciliations r where r.bank_statement_line_id = l.id)
  union all
  select 'matched with a variance', count(*)::numeric
    from public.bank_reconciliations r
    join public.bank_statement_lines l on l.id = r.bank_statement_line_id
   where r.tenant_id = v_tenant and l.bank_account = v_name
     and l.statement_date <= p_as_of and r.variance <> 0
  union all
  select 'distinct confirmers', count(distinct r.matched_by)::numeric
    from public.bank_reconciliations r
    join public.bank_statement_lines l on l.id = r.bank_statement_line_id
   where r.tenant_id = v_tenant and l.bank_account = v_name
     and l.statement_date <= p_as_of and r.match_type = 'manual'
  union all
  -- Appended last so the first five metrics keep their position for any caller
  -- that reads them by index.
  select 'statement lines cleared by a bank adjustment', count(*)::numeric
    from public.bank_reconciliations r
    join public.bank_statement_lines l on l.id = r.bank_statement_line_id
   where r.tenant_id = v_tenant and l.bank_account = v_name
     and l.statement_date <= p_as_of and r.match_type = 'adjustment';
end;
$function$;

revoke all on function public.fin_bank_reconciliation_review(uuid, date) from public;
grant execute on function public.fin_bank_reconciliation_review(uuid, date) to authenticated, service_role;

comment on function public.fin_bank_reconciliation_review(uuid, date) is
  'Per-bank reconciliation review counts as of a date. Every statement line falls in exactly one of: matched automatically, confirmed by a person, cleared by a bank adjustment, or unmatched.';
