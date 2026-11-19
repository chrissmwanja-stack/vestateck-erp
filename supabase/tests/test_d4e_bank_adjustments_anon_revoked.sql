-- Regression test for 20261119150000_d4e_bank_adjustments_revoke_anon_execute.sql
-- and 20261119200000_d4e_guard_trigger_functions_revoke_anon_execute.sql.
-- Plain psql script in one transaction; RAISEs on the first failed assertion.
-- Local/CI database only.
begin;

do $$
declare
  v_fn regprocedure;
  v_fns regprocedure[] := array[
    'public.create_bank_adjustment(uuid, uuid, text, uuid)'::regprocedure,
    'public.request_bank_adjustment_reversal(uuid, text)'::regprocedure,
    'public.approve_bank_adjustment(uuid)'::regprocedure,
    'public.reject_bank_adjustment(uuid, text)'::regprocedure
  ];
begin
  foreach v_fn in array v_fns loop
    if has_function_privilege('anon', v_fn, 'EXECUTE') then
      raise exception 'FAIL: anon can still EXECUTE %', v_fn;
    end if;
    if not has_function_privilege('authenticated', v_fn, 'EXECUTE') then
      raise exception 'FAIL: authenticated lost EXECUTE on %', v_fn;
    end if;
    -- PUBLIC (grantee 0) must not hold it either; anon would inherit it.
    if exists (
      select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
      where p.oid = v_fn::oid and a.grantee = 0 and a.privilege_type = 'EXECUTE'
    ) then
      raise exception 'FAIL: PUBLIC still holds EXECUTE on %', v_fn;
    end if;
  end loop;
  raise notice 'PASS: bank-adjustment RPCs are not anon/PUBLIC-executable; authenticated keeps EXECUTE';
end $$;

-- The two SECURITY DEFINER trigger guards: no anon/PUBLIC/authenticated EXECUTE,
-- and the triggers that use them must still be attached.
do $$
declare
  v_fn regprocedure;
  v_fns regprocedure[] := array[
    'public.bank_adjustments_mutation_guard()'::regprocedure,
    'public.bank_reconciliation_adjustment_guard()'::regprocedure
  ];
begin
  foreach v_fn in array v_fns loop
    if has_function_privilege('anon', v_fn, 'EXECUTE') then
      raise exception 'FAIL: anon can EXECUTE trigger guard %', v_fn;
    end if;
    if exists (
      select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
      where p.oid = v_fn::oid and a.grantee = 0 and a.privilege_type = 'EXECUTE'
    ) then
      raise exception 'FAIL: PUBLIC holds EXECUTE on trigger guard %', v_fn;
    end if;
    if not exists (select 1 from pg_trigger t where t.tgfoid = v_fn::oid and not t.tgisinternal) then
      raise exception 'FAIL: no trigger uses guard % any more', v_fn;
    end if;
  end loop;
  raise notice 'PASS: bank-adjustment trigger guards are not anon/PUBLIC-executable and still attached';
end $$;

rollback;
