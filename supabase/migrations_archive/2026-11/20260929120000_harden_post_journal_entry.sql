-- Harden post_journal_entry()
-- Drafted against live definition (project xownbroirovedkmqyybc, PG 17.6).
-- NOT applied. Review, rename to your migration naming convention, run in a branch first.
--
-- Findings this addresses:
--   1. Function is SECURITY DEFINER, EXECUTE granted to `authenticated`, takes p_tenant_id
--      and never checks it. journal_entries / journal_entry_lines have only SELECT
--      policies, so this function is the ONLY client path to insert journals.
--   2. journal_entry_lines.gl_account_id FK references gl_accounts(id) only, so a line can
--      point at another tenant's GL account.
--
-- Callers (all SECURITY DEFINER, so they keep working after the REVOKE because the
-- function owner retains EXECUTE):
--   trg_post_cash_bank_transaction, trg_post_machine_fuel, trg_post_payroll_run_approval,
--   trg_post_receivable_invoice, trg_post_supplier_invoice, transition_maintenance_request
--
-- NOTE: we deliberately do NOT require can_access_finance() inside this function.
-- Machine fuel and maintenance transitions post journals on behalf of non-finance users.

begin;

-- 1. Primary fix: no direct client execution.
revoke execute on function public.post_journal_entry(uuid, text, uuid, date, text, jsonb)
  from public, anon, authenticated;

-- service_role and postgres keep their existing grants.

-- 2. Defense in depth inside the body (covers any future re-grant or a definer caller
--    that passes a foreign tenant id).
create or replace function public.post_journal_entry(
  p_tenant_id uuid,
  p_source_type text,
  p_source_id uuid,
  p_entry_date date,
  p_description text,
  p_lines jsonb
)
returns journal_entries
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_entry journal_entries%rowtype;
  v_line jsonb;
  v_bad_accounts int;
begin
  if p_tenant_id is null then
    raise exception 'tenant id is required';
  end if;

  -- When called inside a user session (auth.uid() present), the tenant must be the
  -- caller's effective tenant. get_my_tenant_id() already honours active impersonation.
  -- Service-role / cron contexts have no auth.uid() and are skipped.
  if auth.uid() is not null
     and p_tenant_id is distinct from public.get_my_tenant_id() then
    raise exception 'not authorized to post journals for this tenant'
      using errcode = '42501';
  end if;

  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'journal must have at least one line';
  end if;

  -- Every referenced GL account must belong to this tenant.
  select count(*) into v_bad_accounts
  from jsonb_array_elements(p_lines) l
  left join gl_accounts ga
    on ga.id = (l ->> 'gl_account_id')::uuid
   and ga.tenant_id = p_tenant_id
  where ga.id is null;

  if v_bad_accounts > 0 then
    raise exception 'one or more GL accounts do not belong to this tenant'
      using errcode = '42501';
  end if;

  if exists (
    select 1 from accounting_periods
    where tenant_id = p_tenant_id
      and status = 'closed'
      and p_entry_date between period_start and period_end
  ) then
    raise exception 'cannot post to %: this date falls in a closed accounting period', p_entry_date;
  end if;

  insert into journal_entries (tenant_id, entry_date, source_type, source_id, description, posted_by)
  values (p_tenant_id, p_entry_date, p_source_type, p_source_id, p_description, auth.uid())
  returning * into v_entry;

  for v_line in select * from jsonb_array_elements(p_lines)
  loop
    insert into journal_entry_lines (journal_entry_id, tenant_id, gl_account_id, debit, credit, description)
    values (
      v_entry.id,
      p_tenant_id,
      (v_line ->> 'gl_account_id')::uuid,
      coalesce((v_line ->> 'debit')::numeric, 0),
      coalesce((v_line ->> 'credit')::numeric, 0),
      v_line ->> 'description'
    );
  end loop;

  return v_entry;
end;
$function$;

-- CREATE OR REPLACE keeps existing ACL, but restate it so the end state is explicit.
revoke execute on function public.post_journal_entry(uuid, text, uuid, date, text, jsonb)
  from public, anon, authenticated;

commit;

-- ---------------------------------------------------------------------------
-- Verification (run after applying)
-- ---------------------------------------------------------------------------
-- a) ACL should no longer list authenticated:
--   select proacl from pg_proc where oid = 'public.post_journal_entry(uuid,text,uuid,date,text,jsonb)'::regprocedure;
--
-- b) As an ordinary authenticated user this must now fail with "permission denied":
--   set local role authenticated;
--   select public.post_journal_entry('<any-tenant-uuid>', 'test', gen_random_uuid(), current_date, 'x', '[]'::jsonb);
--
-- c) Regression: trigger a real posting (create a supplier invoice, approve a payroll run,
--    log machine fuel, transition a maintenance request) as a normal tenant user and
--    confirm a balanced journal appears.
--
-- ---------------------------------------------------------------------------
-- Rollback
-- ---------------------------------------------------------------------------
--   grant execute on function public.post_journal_entry(uuid,text,uuid,date,text,jsonb) to authenticated;
--   (and re-create the original body if you want to drop the new checks)