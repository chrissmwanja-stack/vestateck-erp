-- Workstream F functional test: calculate_statutory_deductions()
-- against a known, versioned rate table -- the actual math, not just
-- "the columns exist". See migration header in
-- 20260904090500_payroll_paye_nssf_workstream_f.sql: the seeded
-- 4-band PAYE schedule is explicitly UNCONFIRMED pending URA
-- verification, so this test uses its own fixed, made-up rate table
-- rather than depending on whatever seed_statutory_rate_table()
-- currently ships -- this test should keep passing even after that
-- schedule is corrected.
--
-- Run against a fresh local stack only (`supabase start` / db-shadow-
-- replay). Do NOT run against a linked/remote project.

\set ON_ERROR_STOP on

begin;

do $$
declare
  v_tenant_id uuid := gen_random_uuid();
  v_user_id uuid := gen_random_uuid();
  v_result record;

  -- Fixture rate table (NOT the real URA schedule -- see header):
  --   PAYE band 1: 0        - 235,000   @ 0%
  --   PAYE band 2: 235,000+ (top band)  @ 10%, base_tax 0
  --   NSSF employee: 5% flat on gross
  --   NSSF employer: 10% flat on gross
  c_band1_upper constant numeric := 235000;
  c_paye_rate constant numeric := 10;
  c_nssf_employee_rate constant numeric := 5;
  c_nssf_employer_rate constant numeric := 10;
begin
  insert into tenants (id, name) values (v_tenant_id, 'Statutory Test Co');

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, recovery_token
  ) values (
    '00000000-0000-0000-0000-000000000000', v_user_id, 'authenticated', 'authenticated',
    'stat-test-' || v_user_id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
    now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
  );

  insert into app_users (id, tenant_id, name, email)
  values (v_user_id, v_tenant_id, 'Statutory Test User', 'stat-test-' || v_user_id || '@test.local');

  insert into statutory_rate_tables (tenant_id, rate_type, effective_date, band_order, lower_bound, upper_bound, rate, base_tax)
  values
    (v_tenant_id, 'paye', current_date - 30, 1, 0, c_band1_upper, 0, 0),
    (v_tenant_id, 'paye', current_date - 30, 2, c_band1_upper, null, c_paye_rate, 0),
    (v_tenant_id, 'nssf_employee', current_date - 30, 1, 0, null, c_nssf_employee_rate, 0),
    (v_tenant_id, 'nssf_employer', current_date - 30, 1, 0, null, c_nssf_employer_rate, 0);

  perform set_config('request.jwt.claims', json_build_object('sub', v_user_id)::text, true);
  set local role authenticated;

  -------------------------------------------------------------------
  -- Case 1: gross below the taxable threshold -> PAYE = 0, NSSF still
  -- applies (NSSF has no threshold in this schema).
  -------------------------------------------------------------------
  select * into v_result from calculate_statutory_deductions(100000);

  if v_result.paye_amount != 0 then
    raise exception 'FAIL: gross 100,000 should be PAYE-free, got paye_amount = %', v_result.paye_amount;
  end if;
  if v_result.nssf_employee != round(100000 * c_nssf_employee_rate / 100, 2) then
    raise exception 'FAIL: nssf_employee expected %, got %', round(100000 * c_nssf_employee_rate / 100, 2), v_result.nssf_employee;
  end if;
  if v_result.nssf_employer != round(100000 * c_nssf_employer_rate / 100, 2) then
    raise exception 'FAIL: nssf_employer expected %, got %', round(100000 * c_nssf_employer_rate / 100, 2), v_result.nssf_employer;
  end if;
  raise notice 'PASS: below-threshold gross (100,000) -> paye=0, nssf_employee=%, nssf_employer=%', v_result.nssf_employee, v_result.nssf_employer;

  -------------------------------------------------------------------
  -- Case 2: gross above the threshold -> PAYE applies only to the
  -- amount above the band boundary, not the whole gross.
  -------------------------------------------------------------------
  select * into v_result from calculate_statutory_deductions(500000);

  if v_result.paye_amount != round((500000 - c_band1_upper) * c_paye_rate / 100, 2) then
    raise exception 'FAIL: gross 500,000 expected paye_amount %, got %',
      round((500000 - c_band1_upper) * c_paye_rate / 100, 2), v_result.paye_amount;
  end if;
  if v_result.nssf_employee != round(500000 * c_nssf_employee_rate / 100, 2) then
    raise exception 'FAIL: nssf_employee expected %, got %', round(500000 * c_nssf_employee_rate / 100, 2), v_result.nssf_employee;
  end if;
  if v_result.nssf_employer != round(500000 * c_nssf_employer_rate / 100, 2) then
    raise exception 'FAIL: nssf_employer expected %, got %', round(500000 * c_nssf_employer_rate / 100, 2), v_result.nssf_employer;
  end if;
  raise notice 'PASS: above-threshold gross (500,000) -> paye=%, nssf_employee=%, nssf_employer=%', v_result.paye_amount, v_result.nssf_employee, v_result.nssf_employer;

  -------------------------------------------------------------------
  -- Case 3: exactly on the band boundary -- boundary is inclusive to
  -- band 1 (p_gross <= upper_bound), so PAYE should still be 0 here.
  -- This is the classic off-by-one a band-table implementation gets
  -- wrong; worth locking down explicitly.
  -------------------------------------------------------------------
  select * into v_result from calculate_statutory_deductions(c_band1_upper);

  if v_result.paye_amount != 0 then
    raise exception 'FAIL: gross exactly at band boundary (%) should be PAYE-free, got paye_amount = %', c_band1_upper, v_result.paye_amount;
  end if;
  raise notice 'PASS: gross exactly at band boundary (%) -> paye=0', c_band1_upper;

  -------------------------------------------------------------------
  -- Case 4: tenant with no rate table rows at all -- must return
  -- zeros, not raise (generate_payroll_items() depends on this
  -- "skip, don't guess" contract to still create the line item).
  -------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid())::text, true);
  -- no app_users row for this fabricated sub -> get_my_tenant_id() is null
  -- -> the rate table lookups find nothing for a null tenant_id.

  select * into v_result from calculate_statutory_deductions(500000);
  if v_result.paye_amount != 0 or v_result.nssf_employee != 0 or v_result.nssf_employer != 0 then
    raise exception 'FAIL: unmapped tenant should get all-zero statutory amounts, got paye=%, nssf_employee=%, nssf_employer=%',
      v_result.paye_amount, v_result.nssf_employee, v_result.nssf_employer;
  end if;
  raise notice 'PASS: tenant with no rate table -> zeros, no exception';

  raise notice 'ALL STATUTORY DEDUCTION TESTS PASSED';
end $$;

rollback;
