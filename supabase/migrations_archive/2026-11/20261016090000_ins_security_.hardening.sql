-- P0-2: close the small security findings the Supabase advisors report on the
-- insurance and finance objects (found 2026-10-16 against 57c6473 / live
-- project xownbroirovedkmqyybc).
--
--   1. Four insurance guard trigger functions from 20261010100000 were still
--      executable by PUBLIC/anon (and authenticated). They are trigger-only
--      functions, so they are not usefully callable over /rest/v1/rpc, but
--      every later guard (ins_policy_child_guard, ins_cancelled_policy_guard,
--      ...) already has no client grants. This brings the older ones in line.
--      ins_touch_updated_at() is a plain trigger function with the same
--      PUBLIC grant; it is closed the same way.
--      Trigger functions need no EXECUTE grant to fire: Postgres checks that
--      privilege only when the trigger is created.
--
--   2. Three functions had a mutable search_path (advisor:
--      function_search_path_mutable): fin_ledger_currency, ins_via_rpc,
--      ins_touch_updated_at. post_journal_entry had search_path=public without
--      pg_temp. All four now use `public, pg_temp`, the idiom used by every
--      other definer function in this schema. ALTER FUNCTION is used so no
--      function body is restated.
--
-- Not changed: grants on fin_ledger_currency() and ins_via_rpc(); RLS policies
-- and guard triggers call them as the invoking user.
-- Idempotent. No data is touched.

-- 1. Trigger-only functions: no client execution.
revoke all on function public.ins_claims_guard()      from public, anon, authenticated;
revoke all on function public.ins_clients_guard()     from public, anon, authenticated;
revoke all on function public.ins_insurers_guard()    from public, anon, authenticated;
revoke all on function public.ins_policies_guard()    from public, anon, authenticated;
revoke all on function public.ins_touch_updated_at()  from public, anon, authenticated;

grant execute on function public.ins_claims_guard()      to service_role;
grant execute on function public.ins_clients_guard()     to service_role;
grant execute on function public.ins_insurers_guard()    to service_role;
grant execute on function public.ins_policies_guard()    to service_role;
grant execute on function public.ins_touch_updated_at()  to service_role;

-- 2. Pin search_path.
alter function public.fin_ledger_currency(uuid)       set search_path = public, pg_temp;
alter function public.ins_via_rpc()                   set search_path = public, pg_temp;
alter function public.ins_touch_updated_at()          set search_path = public, pg_temp;
alter function public.post_journal_entry(uuid, text, uuid, date, text, jsonb)
                                                      set search_path = public, pg_temp;

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
       or has_function_privilege('authenticated', fn::regprocedure, 'EXECUTE') then
      raise exception 'INS_HARDENING: % is still executable by a client role', fn;
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
        and 'search_path=public, pg_temp' = any (coalesce(p.proconfig, '{}'))
    ) then
      raise exception 'INS_HARDENING: % does not have search_path=public, pg_temp', fn;
    end if;
  end loop;
end $$;