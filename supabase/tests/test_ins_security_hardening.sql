-- Regression test for 20261016120000_ins_security_hardening.sql.
-- Run against a clean local stack after replaying migrations.

\set ON_ERROR_STOP on
begin;

create function pg_temp.assert(p_ok boolean, p_msg text)
returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAIL: %', p_msg;
  end if;
end $$;

select pg_temp.assert(
  not has_function_privilege('anon', 'public.ins_claims_guard()', 'EXECUTE'),
  'anon must not execute ins_claims_guard'
);
select pg_temp.assert(
  not has_function_privilege('authenticated', 'public.ins_claims_guard()', 'EXECUTE'),
  'authenticated must not execute ins_claims_guard'
);
select pg_temp.assert(
  not has_function_privilege('anon', 'public.ins_clients_guard()', 'EXECUTE'),
  'anon must not execute ins_clients_guard'
);
select pg_temp.assert(
  not has_function_privilege('authenticated', 'public.ins_clients_guard()', 'EXECUTE'),
  'authenticated must not execute ins_clients_guard'
);
select pg_temp.assert(
  not has_function_privilege('anon', 'public.ins_insurers_guard()', 'EXECUTE'),
  'anon must not execute ins_insurers_guard'
);
select pg_temp.assert(
  not has_function_privilege('authenticated', 'public.ins_insurers_guard()', 'EXECUTE'),
  'authenticated must not execute ins_insurers_guard'
);
select pg_temp.assert(
  not has_function_privilege('anon', 'public.ins_policies_guard()', 'EXECUTE'),
  'anon must not execute ins_policies_guard'
);
select pg_temp.assert(
  not has_function_privilege('authenticated', 'public.ins_policies_guard()', 'EXECUTE'),
  'authenticated must not execute ins_policies_guard'
);

select pg_temp.assert(
  (select proconfig @> array['search_path=pg_catalog, public, pg_temp']
   from pg_proc where oid = 'public.fin_ledger_currency(uuid)'::regprocedure),
  'fin_ledger_currency search_path must be pinned'
);
select pg_temp.assert(
  (select proconfig @> array['search_path=pg_catalog, public, pg_temp']
   from pg_proc where oid = 'public.ins_via_rpc()'::regprocedure),
  'ins_via_rpc search_path must be pinned'
);
select pg_temp.assert(
  (select proconfig @> array['search_path=pg_catalog, public, pg_temp']
   from pg_proc where oid = 'public.ins_touch_updated_at()'::regprocedure),
  'ins_touch_updated_at search_path must be pinned'
);
select pg_temp.assert(
  (select proconfig @> array['search_path=pg_catalog, public, pg_temp']
   from pg_proc where oid = 'public.post_journal_entry(uuid,text,uuid,date,text,jsonb)'::regprocedure),
  'post_journal_entry search_path must be pinned'
);

rollback;
