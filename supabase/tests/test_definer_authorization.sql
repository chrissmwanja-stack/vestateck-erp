-- Adversarial authorization test for privileged SECURITY DEFINER functions.
--
-- Guards the lock-down in 20260928120000: internal helpers that take a
-- tenant id (or mutate shared state) must NOT be callable by ordinary
-- signed-in users or anonymous callers, even for their own tenant.
-- Scenarios: cross-tenant journal posting, non-finance journal posting,
-- vendor-account creation in another tenant, PO completion, and the
-- trigger-rebuild helper. Also asserts the owner role can still call the
-- helpers, so the SECURITY DEFINER triggers that depend on them keep working.
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
  v_caught text;
  v_sig text;
  v_sigs text[] := array[
    'public.post_journal_entry(uuid,text,uuid,date,text,jsonb)',
    'public.resolve_or_create_vendor_account(uuid,text)',
    'public.try_complete_po(uuid)',
    'public.apply_tenant_read_only_guard()'
  ];
  v_role text;
begin
  -------------------------------------------------------------------
  -- Fixtures: two tenants, one ordinary (non-finance) user in tenant A.
  -------------------------------------------------------------------
  insert into tenants (id, name) values (v_tenant_a, 'AuthZ Test Tenant A'), (v_tenant_b, 'AuthZ Test Tenant B');

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, recovery_token
  ) values (
    '00000000-0000-0000-0000-000000000000', v_user_a, 'authenticated', 'authenticated',
    'authz-test-' || v_user_a || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
    now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
  );
  insert into app_users (id, tenant_id, name, email)
  values (v_user_a, v_tenant_a, 'AuthZ Ordinary User', 'authz-test-' || v_user_a || '@test.local');

  -------------------------------------------------------------------
  -- 1. Metadata: no client role may hold EXECUTE on any of the helpers.
  -------------------------------------------------------------------
  foreach v_sig in array v_sigs loop
    foreach v_role in array array['anon', 'authenticated', 'public'] loop
      if has_function_privilege(v_role, v_sig, 'EXECUTE') then
        raise exception 'FAIL: role % can EXECUTE %', v_role, v_sig;
      end if;
    end loop;
  end loop;
  raise notice 'PASS: anon/authenticated/public have no EXECUTE on the 4 internal helpers';

  -------------------------------------------------------------------
  -- 2. Behavioural: an ordinary tenant-A user is refused (SQLSTATE 42501).
  -------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object('sub', v_user_a)::text, true);
  set local role authenticated;

  -- 2a. Cross-tenant journal: tenant A user -> tenant B ledger.
  v_caught := null;
  begin
    perform post_journal_entry(v_tenant_b, 'manual', gen_random_uuid(), current_date, 'cross-tenant',
      '[]'::jsonb);
  exception when others then v_caught := sqlstate;
  end;
  if v_caught is distinct from '42501' then
    raise exception 'FAIL: cross-tenant post_journal_entry was not denied (sqlstate=%)', coalesce(v_caught, 'none: call succeeded');
  end if;

  -- 2b. Non-finance user posting into their OWN tenant.
  v_caught := null;
  begin
    perform post_journal_entry(v_tenant_a, 'manual', gen_random_uuid(), current_date, 'non-finance', '[]'::jsonb);
  exception when others then v_caught := sqlstate;
  end;
  if v_caught is distinct from '42501' then
    raise exception 'FAIL: non-finance post_journal_entry (own tenant) was not denied (sqlstate=%)', coalesce(v_caught, 'none: call succeeded');
  end if;
  raise notice 'PASS: post_journal_entry denied for cross-tenant and non-finance callers';

  -- 2c. Vendor account creation in another tenant.
  v_caught := null;
  begin
    perform resolve_or_create_vendor_account(v_tenant_b, 'Injected Vendor Ltd');
  exception when others then v_caught := sqlstate;
  end;
  if v_caught is distinct from '42501' then
    raise exception 'FAIL: cross-tenant resolve_or_create_vendor_account was not denied (sqlstate=%)', coalesce(v_caught, 'none: call succeeded');
  end if;
  raise notice 'PASS: resolve_or_create_vendor_account denied';

  -- 2d. PO completion escalation.
  v_caught := null;
  begin
    perform try_complete_po(gen_random_uuid());
  exception when others then v_caught := sqlstate;
  end;
  if v_caught is distinct from '42501' then
    raise exception 'FAIL: try_complete_po was not denied (sqlstate=%)', coalesce(v_caught, 'none: call succeeded');
  end if;
  raise notice 'PASS: try_complete_po denied';

  -- 2e. Read-only guard rebuild.
  v_caught := null;
  begin
    perform apply_tenant_read_only_guard();
  exception when others then v_caught := sqlstate;
  end;
  if v_caught is distinct from '42501' then
    raise exception 'FAIL: apply_tenant_read_only_guard was not denied (sqlstate=%)', coalesce(v_caught, 'none: call succeeded');
  end if;
  raise notice 'PASS: apply_tenant_read_only_guard denied';

  -- 2f. Anonymous callers.
  set local role anon;
  v_caught := null;
  begin
    perform post_journal_entry(v_tenant_a, 'manual', gen_random_uuid(), current_date, 'anon', '[]'::jsonb);
  exception when others then v_caught := sqlstate;
  end;
  if v_caught is distinct from '42501' then
    raise exception 'FAIL: anon post_journal_entry was not denied (sqlstate=%)', coalesce(v_caught, 'none: call succeeded');
  end if;
  raise notice 'PASS: anon denied';

  -------------------------------------------------------------------
  -- 3. Owner role still works, so the SECURITY DEFINER triggers that
  --    call these helpers are unaffected. try_complete_po on an unknown
  --    PO is a documented no-op ("unknown PO ... return").
  -------------------------------------------------------------------
  reset role;
  perform try_complete_po(gen_random_uuid());
  raise notice 'PASS: owner role can still execute the helpers';

  raise notice 'ALL DEFINER AUTHORIZATION TESTS PASSED';
end $$;

rollback;
