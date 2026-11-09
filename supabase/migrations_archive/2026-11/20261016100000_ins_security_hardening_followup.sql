-- Follow-up to 20261016090000_ins_security_.hardening.sql (P0-2).
--
-- That migration is already applied to the live project, so it is not edited.
-- This migration adds the parts that were not in the applied version:
--
--   1. service_role had EXECUTE on the five trigger-only functions, because the
--      applied migration granted it back. Trigger firing does not need EXECUTE,
--      so the grant is removed from service_role as well.
--   2. search_path on fin_ledger_currency, ins_via_rpc, ins_touch_updated_at and
--      post_journal_entry is changed from `public, pg_temp` to
--      `pg_catalog, public, pg_temp`. pg_catalog comes first so built-ins cannot
--      be shadowed, and pg_temp stays last.
--
-- Idempotent. Restates no function body. Touches no data.

-- 1. Trigger-only functions: no execution by any client role, service_role included.
revoke all on function public.ins_claims_guard()      from public, anon, authenticated, service_role;
revoke all on function public.ins_clients_guard()     from public, anon, authenticated, service_role;
revoke all on function public.ins_insurers_guard()    from public, anon, authenticated, service_role;
revoke all on function public.ins_policies_guard()    from public, anon, authenticated, service_role;
revoke all on function public.ins_touch_updated_at()  from public, anon, authenticated, service_role;

-- 2. Pin search_path with pg_catalog first.
alter function public.fin_ledger_currency(uuid)
  set search_path = pg_catalog, public, pg_temp;
alter function public.ins_via_rpc()
  set search_path = pg_catalog, public, pg_temp;
alter function public.ins_touch_updated_at()
  set search_path = pg_catalog, public, pg_temp;
alter function public.post_journal_entry(uuid, text, uuid, date, text, jsonb)
  set search_path = pg_catalog, public, pg_temp;

-- 3. Fail the migration if the end state is not what was intended.
do $$
declare
  fn text;
begin
  foreach fn in array array[
    'public.ins_claims_guard()',
    'public.ins_clients_guard()',
    'public.ins_insurers_guard()',
    'public.ins_policies_guard()',
    'public.ins_touch_updated_at()'
  ] loop
    if has_function_privilege('anon', fn::regprocedure, 'EXECUTE')
       or has_function_privilege('authenticated', fn::regprocedure, 'EXECUTE')
       or has_function_privilege('service_role', fn::regprocedure, 'EXECUTE') then
      raise exception 'INS_HARDENING: % is still executable by a client or service role', fn;
    end if;
  end loop;

  foreach fn in array array[
    'public.fin_ledger_currency(uuid)',
    'public.ins_via_rpc()',
    'public.ins_touch_updated_at()',
    'public.post_journal_entry(uuid,text,uuid,date,text,jsonb)'
  ] loop
    if not exists (
      select 1 from pg_proc p
      where p.oid = fn::regprocedure
        and 'search_path=pg_catalog, public, pg_temp' = any (coalesce(p.proconfig, '{}'))
    ) then
      raise exception 'INS_HARDENING: % does not have search_path=pg_catalog, public, pg_temp', fn;
    end if;
  end loop;
end $$;
