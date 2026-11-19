-- D4e: the privilege surface of the three bank-adjustment tables.
--
-- 20261119230000 narrowed these to what the design says:
--   anon          - nothing at all (already true since 20261112090000; pinned
--                   here so it cannot regress silently);
--   authenticated - SELECT only. Writes are RPC-only, and the usual-account list
--                   is managed through bank_adjustment_add/remove_usual_account.
--
-- This is the regression test for that claim. It reads privileges, not rows, so
-- it needs no fixtures; it is still wrapped in a transaction and rolled back for
-- consistency with the other files here.
--
-- Run against a fresh local stack: psql "$DB" -v ON_ERROR_STOP=1 -f <this file>.

\set ON_ERROR_STOP on

begin;

do $$
declare
  v_tables text[] := array[
    'public.bank_adjustments',
    'public.bank_adjustment_events',
    'public.bank_adjustment_usual_accounts'
  ];
  v_t   text;
  v_bad text[] := array[]::text[];
  v_priv text;
begin
  foreach v_t in array v_tables loop
    -- anon must hold nothing, on the table or through PUBLIC.
    foreach v_priv in array array['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER'] loop
      if has_table_privilege('anon', v_t, v_priv) then
        v_bad := v_bad || format('%s: anon has %s', v_t, v_priv);
      end if;
    end loop;

    -- authenticated reads, and does not write.
    if not has_table_privilege('authenticated', v_t, 'SELECT') then
      v_bad := v_bad || format('%s: authenticated lost SELECT (the screens need it)', v_t);
    end if;
    foreach v_priv in array array['INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER'] loop
      if has_table_privilege('authenticated', v_t, v_priv) then
        v_bad := v_bad || format('%s: authenticated still has %s (writes are RPC-only)', v_t, v_priv);
      end if;
    end loop;

    -- MAINTAIN only exists on PostgreSQL 17+. Check it where it does.
    begin
      if has_table_privilege('authenticated', v_t, 'MAINTAIN') then
        v_bad := v_bad || format('%s: authenticated still has MAINTAIN', v_t);
      end if;
    exception when undefined_object then
      null;
    end;
  end loop;

  if array_length(v_bad, 1) > 0 then
    raise exception 'FAIL: the D4e privilege surface is wider than designed: %', array_to_string(v_bad, '; ');
  end if;
  raise notice 'PASS: anon has nothing and authenticated has SELECT only on the three D4e tables';
end $$;

-- The RPCs that replaced the client's table writes must still be callable, or
-- the tightening would have removed the only way in.
do $$
declare
  v_fns text[] := array[
    'public.create_bank_adjustment(uuid, uuid, text, uuid)',
    'public.approve_bank_adjustment(uuid)',
    'public.reject_bank_adjustment(uuid, text)',
    'public.request_bank_adjustment_reversal(uuid, text)',
    'public.bank_adjustment_add_usual_account(uuid)',
    'public.bank_adjustment_remove_usual_account(uuid)',
    'public.bank_adjustment_list_usual_accounts()'
  ];
  v_fn text;
begin
  foreach v_fn in array v_fns loop
    if not has_function_privilege('authenticated', v_fn::regprocedure, 'EXECUTE') then
      raise exception 'FAIL: authenticated lost EXECUTE on %', v_fn;
    end if;
    if has_function_privilege('anon', v_fn::regprocedure, 'EXECUTE') then
      raise exception 'FAIL: anon can EXECUTE %', v_fn;
    end if;
  end loop;
  raise notice 'PASS: the write RPCs remain executable by authenticated and not by anon';
end $$;

rollback;
