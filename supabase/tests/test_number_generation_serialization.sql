-- Regression test for 20261002100000_serialize_per_tenant_number_generation.sql.
--
-- The five max()+1 numbering functions (next_asset_tag, next_mr_number,
-- next_ticket_number, next_problem_number, next_material_catalog_code) must take a
-- transaction-scoped advisory lock keyed on (number kind, tenant) BEFORE they read
-- max(), and only AFTER assert_tenant_access has authorised the caller.
--
-- A single-transaction SQL test cannot race two sessions, so this file proves the
-- mechanism instead: it inspects pg_locks for the locks this backend holds.
--   1. Metadata: the lock helper is internal; the numbering functions stay
--      executable by `authenticated` (the SECURITY INVOKER triggers need that).
--   2. Each of the five functions takes exactly one advisory lock whose key is
--      hashtextextended('number_sequence:<kind>:<tenant>', 0), re-takes it
--      harmlessly in the same transaction, and still returns ...-00001 on an
--      empty tenant (numbering behaviour unchanged).
--   3. Different tenants and different kinds take different locks (no needless
--      cross-blocking).
--   4. next_doc_number takes NO advisory lock (atomic upsert on doc_sequences).
--   5. An unauthorised caller is refused (42501) BEFORE any lock is taken, so it
--      cannot hold or queue on another tenant's lock.
--   6. The lock is transaction-scoped (pg_advisory_xact_lock, not the session-level
--      variant), so it cannot outlive the inserting transaction (checked
--      structurally in section 1).
--
-- The real two-session race (second caller blocks until the first commits, then
-- gets the next number instead of a unique_violation) was verified by hand against
-- a throwaway Postgres 16; see the migration header for the mechanism.
--
-- Local/CI database only (see test_gl_posting_and_period_close.sql header).
-- Everything runs in one transaction that ROLLBACKs. No row fixtures are needed:
-- the functions only read, and the tenant ids below are random.

\set ON_ERROR_STOP on

begin;

do $$
declare
  v_tenant_a uuid := gen_random_uuid();
  v_tenant_b uuid := gen_random_uuid();
  v_stranger uuid := gen_random_uuid();
  v_kinds jsonb := jsonb_build_object(
    'next_asset_tag',            'asset_tag',
    'next_mr_number',            'mr_number',
    'next_ticket_number',        'ticket_number',
    'next_problem_number',       'problem_number',
    'next_material_catalog_code','material_catalog_code'
  );
  v_fn text;
  v_kind text;
  v_role text;
  v_out text;
  v_caught text;
  v_expected bigint;
  v_before int;
  v_after int;
  v_src text;
  -- Advisory locks held by this backend whose 64-bit key matches. classid/objid
  -- are the high/low 32 bits of a bigint key (objsubid = 1).
  held int;
begin
  -------------------------------------------------------------------
  -- 1. Metadata.
  -------------------------------------------------------------------
  foreach v_role in array array['anon', 'authenticated', 'public'] loop
    if has_function_privilege(v_role, 'public.lock_number_sequence(uuid,text)', 'EXECUTE') then
      raise exception 'FAIL: role % can EXECUTE lock_number_sequence', v_role;
    end if;
  end loop;

  for v_fn in select jsonb_object_keys(v_kinds) loop
    if not has_function_privilege('authenticated', format('public.%s(uuid)', v_fn), 'EXECUTE') then
      raise exception 'FAIL: authenticated lost EXECUTE on % (numbering triggers would break)', v_fn;
    end if;
    -- Structural guard: the xact-scoped lock, taken after the tenant check.
    select pg_get_functiondef(format('public.%s(uuid)', v_fn)::regprocedure) into v_src;
    if position('assert_tenant_access' in v_src) = 0
       or position('lock_number_sequence' in v_src) = 0
       or position('assert_tenant_access' in v_src) > position('lock_number_sequence' in v_src) then
      raise exception 'FAIL: % must call assert_tenant_access before lock_number_sequence', v_fn;
    end if;
    if position('max(' in v_src) < position('lock_number_sequence' in v_src) then
      raise exception 'FAIL: % reads max() before taking the lock', v_fn;
    end if;
  end loop;

  select pg_get_functiondef('public.lock_number_sequence(uuid,text)'::regprocedure) into v_src;
  if position('pg_advisory_xact_lock' in v_src) = 0 or position('pg_advisory_lock(' in v_src) > 0 then
    raise exception 'FAIL: lock_number_sequence must use the transaction-scoped pg_advisory_xact_lock';
  end if;
  raise notice 'PASS: helper is internal; numbering functions stay executable; lock-before-read ordering';

  -------------------------------------------------------------------
  -- 2. Each function takes exactly one lock with the expected key.
  --    (Owner context: no user session, so assert_tenant_access passes.)
  -------------------------------------------------------------------
  for v_fn, v_kind in select key, value from jsonb_each_text(v_kinds) loop
    select count(*) into v_before from pg_locks where locktype = 'advisory' and pid = pg_backend_pid();

    execute format('select public.%I($1)', v_fn) into v_out using v_tenant_a;
    if v_out is null or v_out !~ '-00001$' then
      raise exception 'FAIL: % returned % on an empty tenant (expected ...-00001)', v_fn, v_out;
    end if;

    select count(*) into v_after from pg_locks where locktype = 'advisory' and pid = pg_backend_pid();
    if v_after <> v_before + 1 then
      raise exception 'FAIL: % took % new advisory lock(s), expected exactly 1', v_fn, v_after - v_before;
    end if;

    v_expected := hashtextextended('number_sequence:' || v_kind || ':' || v_tenant_a::text, 0);
    select count(*) into held from pg_locks
     where locktype = 'advisory' and pid = pg_backend_pid() and granted
       and objsubid = 1
       and ((classid::text::bigint << 32) | objid::text::bigint) = v_expected;
    if held <> 1 then
      raise exception 'FAIL: % did not hold the (kind=%, tenant) advisory lock', v_fn, v_kind;
    end if;

    -- Same transaction, same key: re-entrant, no extra lock, no self-deadlock.
    execute format('select public.%I($1)', v_fn) into v_out using v_tenant_a;
    select count(*) into v_after from pg_locks where locktype = 'advisory' and pid = pg_backend_pid();
    if v_after <> v_before + 1 then
      raise exception 'FAIL: second % call in the same transaction changed the lock count', v_fn;
    end if;
  end loop;
  raise notice 'PASS: each max()+1 function holds exactly its (kind, tenant) advisory lock; numbering unchanged';

  -------------------------------------------------------------------
  -- 3. Different tenant => different lock (no cross-tenant blocking).
  -------------------------------------------------------------------
  select count(*) into v_before from pg_locks where locktype = 'advisory' and pid = pg_backend_pid();
  perform public.next_mr_number(v_tenant_b);
  select count(*) into v_after from pg_locks where locktype = 'advisory' and pid = pg_backend_pid();
  if v_after <> v_before + 1 then
    raise exception 'FAIL: tenant B did not take its own lock (before %, after %)', v_before, v_after;
  end if;
  raise notice 'PASS: different tenants and different kinds take different locks';

  -------------------------------------------------------------------
  -- 4. next_doc_number is an atomic upsert and must not take an advisory lock.
  -------------------------------------------------------------------
  select count(*) into v_before from pg_locks where locktype = 'advisory' and pid = pg_backend_pid();
  perform public.next_doc_number(v_tenant_a, 'numlock_test', 'NLT');
  select count(*) into v_after from pg_locks where locktype = 'advisory' and pid = pg_backend_pid();
  if v_after <> v_before then
    raise exception 'FAIL: next_doc_number unexpectedly took an advisory lock';
  end if;
  raise notice 'PASS: next_doc_number unchanged (no advisory lock)';

  -------------------------------------------------------------------
  -- 5. Unauthorised caller is refused before any lock is taken.
  --    (A signed-in user with no app_users row has no effective tenant.)
  -------------------------------------------------------------------
  select count(*) into v_before from pg_locks where locktype = 'advisory' and pid = pg_backend_pid();

  perform set_config('request.jwt.claims', json_build_object('sub', v_stranger)::text, true);
  set local role authenticated;

  for v_fn, v_kind in select key, value from jsonb_each_text(v_kinds) loop
    v_caught := null;
    begin
      execute format('select public.%I($1)', v_fn) using gen_random_uuid();
    exception when others then v_caught := sqlstate;
    end;
    if v_caught is distinct from '42501' then
      raise exception 'FAIL: unauthorised % call was not denied (sqlstate=%)', v_fn, coalesce(v_caught, 'none: call succeeded');
    end if;
  end loop;

  reset role;
  perform set_config('request.jwt.claims', '', true);

  select count(*) into v_after from pg_locks where locktype = 'advisory' and pid = pg_backend_pid();
  if v_after <> v_before then
    raise exception 'FAIL: denied callers still took % advisory lock(s)', v_after - v_before;
  end if;
  raise notice 'PASS: unauthorised callers are refused before any lock is taken';
end;
$$;

rollback;
