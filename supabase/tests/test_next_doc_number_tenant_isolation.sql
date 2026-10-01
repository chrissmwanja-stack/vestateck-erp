-- Tenant-isolation test for the document-numbering SECURITY DEFINER functions.
--
-- Guards 20261001150000_close_next_doc_number_tenant_isolation.sql:
--   next_doc_number, next_asset_tag, next_mr_number, next_ticket_number,
--   next_problem_number, next_material_catalog_code
-- must refuse a signed-in caller who names another tenant's id, while still
-- working for their own tenant (the SECURITY INVOKER numbering triggers call
-- them as the inserting user, so `authenticated` must keep EXECUTE).
--
-- Scenarios:
--   1. Metadata: guard helper is not client-executable; the six functions are.
--   2. Own tenant works and numbering increments.
--   3. Cross-tenant calls are denied (42501) and leave tenant B's counter untouched.
--   4. A platform admin who is not impersonating may act for any tenant.
--   5. A session with no user (owner / service role / cron) may act for any tenant.
--
-- Not covered here (add if the fixtures become available): active impersonation
-- of a user in another tenant, and a suspended-tenant caller.
--
-- Local/CI database only (see test_gl_posting_and_period_close.sql header).
-- Everything runs in one transaction that ROLLBACKs.

\set ON_ERROR_STOP on

begin;

do $$
declare
  v_tenant_a uuid := gen_random_uuid();
  v_tenant_b uuid := gen_random_uuid();
  v_user_a uuid := gen_random_uuid();
  v_admin uuid := gen_random_uuid();
  v_caught text;
  v_out text;
  v_out2 text;
  v_count int;
  v_fn text;
  v_role text;
  v_sibs text[] := array[
    'next_asset_tag', 'next_mr_number', 'next_ticket_number',
    'next_problem_number', 'next_material_catalog_code'
  ];
  v_year text := to_char(now(), 'YYYY');
begin
  -------------------------------------------------------------------
  -- Fixtures: two tenants, an ordinary user in A, a platform admin in A.
  -------------------------------------------------------------------
  insert into tenants (id, name) values
    (v_tenant_a, 'DocNo Test Tenant A'),
    (v_tenant_b, 'DocNo Test Tenant B');

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, recovery_token
  ) values
  (
    '00000000-0000-0000-0000-000000000000', v_user_a, 'authenticated', 'authenticated',
    'docno-test-' || v_user_a || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
    now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
  ),
  (
    '00000000-0000-0000-0000-000000000000', v_admin, 'authenticated', 'authenticated',
    'docno-admin-' || v_admin || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
    now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
  );

  insert into app_users (id, tenant_id, name, email) values
    (v_user_a, v_tenant_a, 'DocNo Ordinary User', 'docno-test-' || v_user_a || '@test.local'),
    (v_admin,  v_tenant_a, 'DocNo Platform Admin', 'docno-admin-' || v_admin || '@test.local');
  update app_users set is_platform_admin = true where id = v_admin;

  -------------------------------------------------------------------
  -- 1. Metadata.
  -------------------------------------------------------------------
  foreach v_role in array array['anon', 'authenticated', 'public'] loop
    if has_function_privilege(v_role, 'public.assert_tenant_access(uuid)', 'EXECUTE') then
      raise exception 'FAIL: role % can EXECUTE assert_tenant_access', v_role;
    end if;
  end loop;

  if not has_function_privilege('authenticated', 'public.next_doc_number(uuid,text,text,integer)', 'EXECUTE') then
    raise exception 'FAIL: authenticated lost EXECUTE on next_doc_number (numbering triggers would break)';
  end if;
  foreach v_fn in array v_sibs loop
    if not has_function_privilege('authenticated', format('public.%s(uuid)', v_fn), 'EXECUTE') then
      raise exception 'FAIL: authenticated lost EXECUTE on % (numbering triggers would break)', v_fn;
    end if;
  end loop;
  raise notice 'PASS: guard helper is internal; numbering functions stay executable by authenticated';

  -------------------------------------------------------------------
  -- 2 + 3. Ordinary tenant-A user.
  -------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object('sub', v_user_a)::text, true);
  set local role authenticated;

  -- 2a. Own tenant: works and increments.
  v_out  := next_doc_number(v_tenant_a, 'docno_test', 'TST');
  v_out2 := next_doc_number(v_tenant_a, 'docno_test', 'TST');
  if v_out is distinct from 'TST-' || v_year || '-0001' or v_out2 is distinct from 'TST-' || v_year || '-0002' then
    raise exception 'FAIL: own-tenant next_doc_number returned % then % (expected 0001 then 0002)', v_out, v_out2;
  end if;

  -- 2b. Own tenant: siblings run (empty tenant, so number 00001).
  foreach v_fn in array v_sibs loop
    execute format('select public.%I($1)', v_fn) into v_out using v_tenant_a;
    if v_out is null or v_out !~ '-00001$' then
      raise exception 'FAIL: own-tenant % returned % (expected a ...-00001 value)', v_fn, v_out;
    end if;
  end loop;
  raise notice 'PASS: own-tenant numbering works for all six functions';

  -- 3a. Cross-tenant next_doc_number.
  v_caught := null;
  begin
    perform next_doc_number(v_tenant_b, 'docno_test', 'TST');
  exception when others then v_caught := sqlstate;
  end;
  if v_caught is distinct from '42501' then
    raise exception 'FAIL: cross-tenant next_doc_number was not denied (sqlstate=%)', coalesce(v_caught, 'none: call succeeded');
  end if;

  -- 3b. Cross-tenant on a doc type tenant B has never used (would create a row).
  v_caught := null;
  begin
    perform next_doc_number(v_tenant_b, 'docno_test_fresh', 'TST');
  exception when others then v_caught := sqlstate;
  end;
  if v_caught is distinct from '42501' then
    raise exception 'FAIL: cross-tenant next_doc_number (new doc type) was not denied (sqlstate=%)', coalesce(v_caught, 'none: call succeeded');
  end if;

  -- 3c. Cross-tenant on every sibling.
  foreach v_fn in array v_sibs loop
    v_caught := null;
    begin
      execute format('select public.%I($1)', v_fn) using v_tenant_b;
    exception when others then v_caught := sqlstate;
    end;
    if v_caught is distinct from '42501' then
      raise exception 'FAIL: cross-tenant % was not denied (sqlstate=%)', v_fn, coalesce(v_caught, 'none: call succeeded');
    end if;
  end loop;

  -- 3d. NULL tenant id is not a bypass.
  v_caught := null;
  begin
    perform next_doc_number(null, 'docno_test', 'TST');
  exception when others then v_caught := sqlstate;
  end;
  if v_caught is distinct from '42501' then
    raise exception 'FAIL: next_doc_number(NULL tenant) was not denied (sqlstate=%)', coalesce(v_caught, 'none: call succeeded');
  end if;
  raise notice 'PASS: cross-tenant and NULL-tenant calls denied for all six functions';

  -- 3e. Anonymous callers: no user session. Denied either by missing EXECUTE or by
  --     the guard itself (both are 42501).
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  set local role anon;
  v_caught := null;
  begin
    perform next_doc_number(v_tenant_a, 'docno_test', 'TST');
  exception when others then v_caught := sqlstate;
  end;
  if v_caught is distinct from '42501' then
    raise exception 'FAIL: anon next_doc_number was not denied (sqlstate=%)', coalesce(v_caught, 'none: call succeeded');
  end if;
  v_caught := null;
  begin
    perform next_asset_tag(v_tenant_a);
  exception when others then v_caught := sqlstate;
  end;
  if v_caught is distinct from '42501' then
    raise exception 'FAIL: anon next_asset_tag was not denied (sqlstate=%)', coalesce(v_caught, 'none: call succeeded');
  end if;
  raise notice 'PASS: anon denied';

  -- Tenant B's counters must be untouched by everything above.
  reset role;
  select count(*) into v_count from doc_sequences where tenant_id = v_tenant_b;
  if v_count <> 0 then
    raise exception 'FAIL: denied calls still wrote % doc_sequences row(s) for tenant B', v_count;
  end if;
  select last_number into v_count from doc_sequences
   where tenant_id = v_tenant_a and doc_type = 'docno_test' and year = v_year;
  if v_count is distinct from 2 then
    raise exception 'FAIL: tenant A counter is % (expected 2)', v_count;
  end if;
  raise notice 'PASS: tenant B counters untouched; tenant A counter correct';

  -------------------------------------------------------------------
  -- 4. Platform admin, not impersonating: may act for any tenant.
  -------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  set local role authenticated;
  v_out := next_doc_number(v_tenant_b, 'docno_test', 'TST');
  if v_out is distinct from 'TST-' || v_year || '-0001' then
    raise exception 'FAIL: platform admin next_doc_number for tenant B returned % (expected 0001)', v_out;
  end if;
  raise notice 'PASS: non-impersonating platform admin may number for any tenant';

  -------------------------------------------------------------------
  -- 5. No user session (owner / service role / cron): allowed for any tenant.
  -------------------------------------------------------------------
  reset role;
  perform set_config('request.jwt.claims', '', true);
  v_out := next_doc_number(v_tenant_b, 'docno_test', 'TST');
  if v_out is distinct from 'TST-' || v_year || '-0002' then
    raise exception 'FAIL: owner-context next_doc_number for tenant B returned % (expected 0002)', v_out;
  end if;
  foreach v_fn in array v_sibs loop
    execute format('select public.%I($1)', v_fn) into v_out using v_tenant_b;
    if v_out is null then
      raise exception 'FAIL: owner-context % returned NULL', v_fn;
    end if;
  end loop;
  raise notice 'PASS: owner / service-role context unaffected';

  raise notice 'ALL NEXT_DOC_NUMBER TENANT-ISOLATION TESTS PASSED';
end $$;

rollback;
