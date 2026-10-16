-- Phase A, A1: regulatory parameters (regulatory_parameter_definitions,
-- regulatory_parameters, regulatory_parameter_events and the reg_* / platform_reg_*
-- functions).
--
-- Covers: draft is never used until approved; maker-checker (self-approval and
-- non-admin approval refused); approved rows immutable except for end-dating
-- (shorten only) and retirement; overlap refused; class beats no class; a missing
-- value raises and there is no default; value validation per key type; event log;
-- tenant isolation; outsiders, anon, internal-function and no-delete denials.
--
-- Run against a fresh local stack only (`supabase db reset`). One transaction that
-- ROLLBACKs, so no fixture data is left behind. Any RAISE EXCEPTION is a real
-- assertion failure and makes psql exit non-zero.

\set ON_ERROR_STOP on

begin;

create function pg_temp.expect_error(p_sql text, p_needle text, p_label text)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm like '%' || p_needle || '%' then
      return;
    end if;
    raise exception 'FAIL: % raised the wrong error: %', p_label, sqlerrm;
  end;
  raise exception 'FAIL: % succeeded but should have failed with %', p_label, p_needle;
end $$;

-- Switches the session to a given user (authenticated role).
create function pg_temp.as_user(p_user uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $$;

do $$
declare
  v_ta uuid := gen_random_uuid();
  v_tb uuid := gen_random_uuid();
  v_admin1 uuid := gen_random_uuid();   -- company admin A (proposer)
  v_admin2 uuid := gen_random_uuid();   -- company admin A (approver)
  v_fin    uuid := gen_random_uuid();   -- finance, not admin
  v_out    uuid := gen_random_uuid();   -- no role at all
  v_admin_b uuid := gen_random_uuid();  -- company admin of tenant B

  v_wht uuid; v_wht2 uuid; v_wht3 uuid; v_stamp uuid; v_stamp_motor uuid;
  v_draft uuid; v_pct uuid; v_days uuid; v_fin_draft uuid; v_b uuid;
  v_row regulatory_parameters%rowtype;
  v_n integer;
  v_num numeric;
begin
  -------------------------------------------------------------------
  -- Fixtures (as the table owner)
  -------------------------------------------------------------------
  insert into tenants (id, name) values (v_ta, 'Reg Params Co A'), (v_tb, 'Reg Params Co B');

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, recovery_token
  )
  select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
         'regp-' || u.id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
         now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
  from (values (v_admin1), (v_admin2), (v_fin), (v_out), (v_admin_b)) as u(id);

  insert into app_users (id, tenant_id, name, email, is_company_admin) values
    (v_admin1,  v_ta, 'Reg Admin 1',  'regp-' || v_admin1  || '@test.local', true),
    (v_admin2,  v_ta, 'Reg Admin 2',  'regp-' || v_admin2  || '@test.local', true),
    (v_fin,     v_ta, 'Reg Finance',  'regp-' || v_fin     || '@test.local', false),
    (v_out,     v_ta, 'Reg Outsider', 'regp-' || v_out     || '@test.local', false),
    (v_admin_b, v_tb, 'Reg Admin B',  'regp-' || v_admin_b || '@test.local', true);

  insert into finance_team_members (tenant_id, user_id, role) values (v_ta, v_fin, 'finance');

  -------------------------------------------------------------------
  -- 1. Catalogue: keys only, no values; clients cannot edit it
  -------------------------------------------------------------------
  select count(*) into v_n from regulatory_parameter_definitions;
  if v_n < 15 then
    raise exception 'FAIL: expected the key catalogue to be seeded, found % keys', v_n;
  end if;
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'regulatory_parameter_definitions'
               and column_name in ('value_num', 'value_text', 'tenant_id')) then
    raise exception 'FAIL: the catalogue must carry no values and no tenant';
  end if;
  select count(*) into v_n from regulatory_parameters;
  if v_n <> 0 then
    raise exception 'FAIL: migration must not seed any parameter value (found %)', v_n;
  end if;

  perform pg_temp.as_user(v_admin1);
  perform pg_temp.expect_error(
    $q$insert into regulatory_parameter_definitions (key, category, description, value_type) values ('x.y', 'c', 'd', 'text')$q$,
    'permission denied', 'client insert into the catalogue');
  reset role;
  raise notice 'PASS: catalogue has keys only and no values; clients cannot edit it; no seed values';

  -------------------------------------------------------------------
  -- 2. A draft is created, but is invisible to resolution
  -------------------------------------------------------------------
  perform pg_temp.as_user(v_admin1);
  insert into regulatory_parameters (tenant_id, parameter_key, value_num, effective_from, source_ref)
  values (v_ta, 'tax.wht_agent_commission_percent', 6, date '2026-01-01', 'UNVERIFIED: accountant to confirm')
  returning id into v_wht;
  reset role;

  select * into v_row from regulatory_parameters where id = v_wht;
  if v_row.status <> 'draft' or v_row.created_by <> v_admin1 or v_row.approved_by is not null then
    raise exception 'FAIL: new row should be a draft created by admin1 (status %, created_by %)', v_row.status, v_row.created_by;
  end if;

  perform pg_temp.expect_error(
    format($q$select platform_reg_number(%L, 'tax.wht_agent_commission_percent', date '2026-06-01')$q$, v_ta),
    'REG_PARAM_MISSING', 'resolve a draft');
  raise notice 'PASS: a draft is not used by resolution (missing value raises, no default)';

  -------------------------------------------------------------------
  -- 3. Maker-checker
  -------------------------------------------------------------------
  perform pg_temp.as_user(v_admin1);
  perform pg_temp.expect_error(format('select reg_approve_parameter(%L)', v_wht), 'REG_SELF_APPROVAL', 'proposer approves own draft');
  reset role;

  perform pg_temp.as_user(v_fin);
  perform pg_temp.expect_error(format('select reg_approve_parameter(%L)', v_wht), 'REG_FORBIDDEN', 'non-admin approves');
  reset role;

  perform pg_temp.as_user(v_admin_b);
  perform pg_temp.expect_error(format('select reg_approve_parameter(%L)', v_wht), 'REG_NOT_FOUND', 'other tenant admin approves');
  reset role;

  perform pg_temp.as_user(v_admin2);
  select * into v_row from reg_approve_parameter(v_wht);
  reset role;
  if v_row.status <> 'approved' or v_row.approved_by <> v_admin2 or v_row.approved_at is null then
    raise exception 'FAIL: approval fields wrong (status %, approved_by %)', v_row.status, v_row.approved_by;
  end if;
  perform pg_temp.as_user(v_admin2);
  perform pg_temp.expect_error(format('select reg_approve_parameter(%L)', v_wht), 'REG_NOT_DRAFT', 'approve twice');
  reset role;
  raise notice 'PASS: self-approval, non-admin and other-tenant approval refused; a second admin approves once';

  -------------------------------------------------------------------
  -- 4. Resolution: effective window is [from, to)
  -------------------------------------------------------------------
  v_num := platform_reg_number(v_ta, 'tax.wht_agent_commission_percent', date '2026-01-01');
  if v_num <> 6 then raise exception 'FAIL: expected 6 on the start date, got %', v_num; end if;
  perform pg_temp.expect_error(
    format($q$select platform_reg_number(%L, 'tax.wht_agent_commission_percent', date '2025-12-31')$q$, v_ta),
    'REG_PARAM_MISSING', 'resolve before the effective date');
  perform pg_temp.expect_error(
    format($q$select platform_reg_number(%L, 'no.such_key', date '2026-06-01')$q$, v_ta),
    'REG_UNKNOWN_KEY', 'resolve unknown key');
  perform pg_temp.expect_error(
    format($q$select platform_reg_number(%L, 'tax.vat_standard_percent', date '2026-06-01')$q$, v_ta),
    'REG_PARAM_MISSING', 'key with no value');
  perform pg_temp.expect_error(
    format($q$select platform_reg_number(%L, 'tax.wht_agent_commission_percent', date '2026-06-01')$q$, v_tb),
    'REG_PARAM_MISSING', 'other tenant resolves the value');
  raise notice 'PASS: resolution honours the start date, unknown keys, unset keys and tenant';

  -------------------------------------------------------------------
  -- 5. Approved rows are immutable; only end-dating (shorten) and retirement
  -------------------------------------------------------------------
  perform pg_temp.as_user(v_admin2);
  perform pg_temp.expect_error(
    format('update regulatory_parameters set value_num = 7 where id = %L', v_wht),
    'REG_APPROVED_IMMUTABLE', 'edit approved value');
  perform pg_temp.expect_error(
    format($q$update regulatory_parameters set status = 'draft' where id = %L$q$, v_wht),
    'REG_STATUS_VIA_RPC', 'status change outside RPC');
  perform pg_temp.expect_error(
    format($q$update regulatory_parameters set effective_to = date '2027-01-01' where id = %L$q$, v_wht),
    'REG_APPROVED_IMMUTABLE', 'direct end-date edit');
  perform pg_temp.expect_error(
    format('select reg_end_parameter(%L, date %L)', v_wht, '2026-01-01'),
    'REG_END_DATE', 'end date not after start');
  reset role;
  raise notice 'PASS: approved value cannot be edited, re-statused or end-dated outside the RPCs';

  -------------------------------------------------------------------
  -- 6. Overlap refused; end-dating then a new row from the end date works
  -------------------------------------------------------------------
  perform pg_temp.as_user(v_admin1);
  insert into regulatory_parameters (tenant_id, parameter_key, value_num, effective_from, source_ref)
  values (v_ta, 'tax.wht_agent_commission_percent', 10, date '2026-07-01', 'UNVERIFIED: new rate')
  returning id into v_wht2;
  reset role;

  perform pg_temp.as_user(v_admin2);
  perform pg_temp.expect_error(format('select reg_approve_parameter(%L)', v_wht2), 'REG_OVERLAP', 'overlapping approval');

  perform reg_end_parameter(v_wht, date '2026-07-01');
  perform pg_temp.expect_error(
    format('select reg_end_parameter(%L, date %L)', v_wht, '2026-08-01'),
    'REG_END_DATE', 'extend an end date');
  perform pg_temp.expect_error(
    format('select reg_end_parameter(%L, date %L)', v_wht, '2026-07-01'),
    'REG_END_DATE', 'end date equal to current end date');
  perform reg_approve_parameter(v_wht2);
  reset role;

  if platform_reg_number(v_ta, 'tax.wht_agent_commission_percent', date '2026-06-30') <> 6 then
    raise exception 'FAIL: old rate should apply the day before the change';
  end if;
  if platform_reg_number(v_ta, 'tax.wht_agent_commission_percent', date '2026-07-01') <> 10 then
    raise exception 'FAIL: new rate should apply from the end date (exclusive end of the old row)';
  end if;
  raise notice 'PASS: overlap refused; end-date only shortens; a value change is a new row from a new date';

  -------------------------------------------------------------------
  -- 7. A class value beats the general value; other classes fall back
  -------------------------------------------------------------------
  perform pg_temp.as_user(v_admin1);
  insert into regulatory_parameters (tenant_id, parameter_key, applies_to, value_num, currency, effective_from, source_ref)
  values (v_ta, 'stamp_duty.policy', null, 3000, 'UGX', date '2026-01-01', 'UNVERIFIED: general')
  returning id into v_stamp;
  insert into regulatory_parameters (tenant_id, parameter_key, applies_to, value_num, currency, effective_from, source_ref)
  values (v_ta, 'stamp_duty.policy', 'motor', 5000, 'UGX', date '2026-01-01', 'UNVERIFIED: motor')
  returning id into v_stamp_motor;
  reset role;
  perform pg_temp.as_user(v_admin2);
  perform reg_approve_parameter(v_stamp);
  perform reg_approve_parameter(v_stamp_motor);   -- same key, different class: no overlap
  reset role;

  if platform_reg_number(v_ta, 'stamp_duty.policy', date '2026-03-01', 'motor') <> 5000 then
    raise exception 'FAIL: the motor class value should win';
  end if;
  if platform_reg_number(v_ta, 'stamp_duty.policy', date '2026-03-01', 'marine') <> 3000 then
    raise exception 'FAIL: an unlisted class should fall back to the general value';
  end if;
  if platform_reg_number(v_ta, 'stamp_duty.policy', date '2026-03-01') <> 3000 then
    raise exception 'FAIL: no class should use the general value';
  end if;
  raise notice 'PASS: class-specific value wins; other classes and no class fall back to the general one';

  -------------------------------------------------------------------
  -- 8. Value validation (each case is a draft that must be refused)
  -------------------------------------------------------------------
  perform pg_temp.as_user(v_admin1);
  perform pg_temp.expect_error(
    $q$insert into regulatory_parameters (tenant_id, parameter_key, value_num, effective_from, source_ref)
       values (get_my_tenant_id(), 'levy.training_percent', 101, date '2026-01-01', 'x')$q$,
    'REG_VALUE_INVALID', 'percentage above 100');
  perform pg_temp.expect_error(
    $q$insert into regulatory_parameters (tenant_id, parameter_key, value_num, effective_from, source_ref)
       values (get_my_tenant_id(), 'levy.training_percent', -1, date '2026-01-01', 'x')$q$,
    'REG_VALUE_INVALID', 'negative value');
  perform pg_temp.expect_error(
    $q$insert into regulatory_parameters (tenant_id, parameter_key, value_num, effective_from, source_ref)
       values (get_my_tenant_id(), 'stamp_duty.policy', 3000, date '2026-01-01', 'x')$q$,
    'REG_VALUE_INVALID', 'amount without currency');
  perform pg_temp.expect_error(
    $q$insert into regulatory_parameters (tenant_id, parameter_key, value_num, currency, effective_from, source_ref)
       values (get_my_tenant_id(), 'levy.training_percent', 1, 'UGX', date '2026-01-01', 'x')$q$,
    'REG_VALUE_INVALID', 'percentage carrying a currency');
  perform pg_temp.expect_error(
    $q$insert into regulatory_parameters (tenant_id, parameter_key, value_num, effective_from, source_ref)
       values (get_my_tenant_id(), 'remittance.deadline_working_days', 1.5, date '2026-01-01', 'x')$q$,
    'REG_VALUE_INVALID', 'fractional days');
  perform pg_temp.expect_error(
    $q$insert into regulatory_parameters (tenant_id, parameter_key, value_text, effective_from, source_ref)
       values (get_my_tenant_id(), 'levy.training_percent', 'abc', date '2026-01-01', 'x')$q$,
    'REG_VALUE_INVALID', 'text in a numeric key');
  perform pg_temp.expect_error(
    $q$insert into regulatory_parameters (tenant_id, parameter_key, applies_to, value_num, effective_from, source_ref)
       values (get_my_tenant_id(), 'tax.vat_standard_percent', 'motor', 18, date '2026-01-01', 'x')$q$,
    'REG_CLASS_NOT_ALLOWED', 'class on a key that does not vary by class');
  perform pg_temp.expect_error(
    $q$insert into regulatory_parameters (tenant_id, parameter_key, value_num, effective_from, source_ref)
       values (get_my_tenant_id(), 'no.such_key', 1, date '2026-01-01', 'x')$q$,
    'REG_UNKNOWN_KEY', 'unknown key');
  perform pg_temp.expect_error(
    $q$insert into regulatory_parameters (tenant_id, parameter_key, value_num, effective_from, source_ref, status, approved_by, approved_at)
       values (get_my_tenant_id(), 'levy.training_percent', 1, date '2026-01-01', 'x', 'approved', get_my_tenant_id(), now())$q$,
    'REG_STATUS', 'insert already approved');
  perform pg_temp.expect_error(
    $q$insert into regulatory_parameters (tenant_id, parameter_key, value_num, effective_from, source_ref)
       values (get_my_tenant_id(), 'levy.training_percent', 1, date '2026-01-01', '   ')$q$,
    'regulatory_parameters_source_check', 'blank source reference');
  perform pg_temp.expect_error(
    $q$insert into regulatory_parameters (tenant_id, parameter_key, value_num, effective_from, effective_to, source_ref)
       values (get_my_tenant_id(), 'levy.training_percent', 1, date '2026-02-01', date '2026-01-01', 'x')$q$,
    'regulatory_parameters_dates_check', 'end before start');
  reset role;
  raise notice 'PASS: value rules refuse bad percentages, negatives, currencies, fractions, text, classes, keys, status and blank sources';

  -------------------------------------------------------------------
  -- 9. Drafts are editable by their makers; retirement rules
  -------------------------------------------------------------------
  perform pg_temp.as_user(v_fin);
  insert into regulatory_parameters (tenant_id, parameter_key, value_num, effective_from, source_ref)
  values (v_ta, 'levy.training_percent', 0.5, date '2026-01-01', 'UNVERIFIED: finance draft')
  returning id into v_pct;
  update regulatory_parameters set value_num = 1 where id = v_pct;        -- draft edit is allowed
  perform pg_temp.expect_error(
    format($q$update regulatory_parameters set parameter_key = 'levy.authority_percent' where id = %L$q$, v_pct),
    'REG_KEY_IMMUTABLE', 'change a key');
  perform pg_temp.expect_error(
    format('select reg_retire_parameter(%L, %L)', v_pct, 'no'),
    'REG_REASON', 'retire with a short reason');
  perform reg_retire_parameter(v_pct, 'entered in error');                 -- proposer withdraws own draft
  reset role;

  select * into v_row from regulatory_parameters where id = v_pct;
  if v_row.status <> 'retired' or v_row.retired_reason <> 'entered in error' then
    raise exception 'FAIL: retired draft state wrong (status %, reason %)', v_row.status, v_row.retired_reason;
  end if;
  perform pg_temp.as_user(v_admin1);
  perform pg_temp.expect_error(
    format('update regulatory_parameters set value_num = 2 where id = %L', v_pct),
    'REG_RETIRED_IMMUTABLE', 'edit a retired row');
  perform pg_temp.expect_error(
    format('select reg_retire_parameter(%L, %L)', v_pct, 'again please'),
    'REG_RETIRED_IMMUTABLE', 'retire twice');
  reset role;

  -- A non-admin cannot retire an approved value; an admin can, and it stops resolving.
  perform pg_temp.as_user(v_fin);
  perform pg_temp.expect_error(
    format('select reg_retire_parameter(%L, %L)', v_stamp_motor, 'finance tries it'),
    'REG_FORBIDDEN', 'non-admin retires an approved value');
  reset role;
  perform pg_temp.as_user(v_admin2);
  perform reg_retire_parameter(v_stamp_motor, 'superseded by circular');
  reset role;
  if platform_reg_number(v_ta, 'stamp_duty.policy', date '2026-03-01', 'motor') <> 3000 then
    raise exception 'FAIL: after retiring the motor value, motor should fall back to the general value';
  end if;

  -- A draft can be retired by an admin who did not write it, but not by an unrelated non-admin.
  perform pg_temp.as_user(v_admin1);
  insert into regulatory_parameters (tenant_id, parameter_key, value_num, effective_from, source_ref)
  values (v_ta, 'retention.policy_years', 10, date '2026-01-01', 'UNVERIFIED: baseline')
  returning id into v_days;
  reset role;
  perform pg_temp.as_user(v_fin);
  perform pg_temp.expect_error(
    format('select reg_retire_parameter(%L, %L)', v_days, 'not my draft'),
    'REG_FORBIDDEN', 'non-admin withdraws someone else''s draft');
  reset role;
  raise notice 'PASS: draft edits, key immutability, retirement reasons and who may retire what';

  -------------------------------------------------------------------
  -- 10. Event log
  -------------------------------------------------------------------
  select count(*) into v_n from regulatory_parameter_events where parameter_id = v_wht and event = 'approved' and actor = v_admin2;
  if v_n <> 1 then raise exception 'FAIL: expected one approval event for the first WHT row, found %', v_n; end if;
  select count(*) into v_n from regulatory_parameter_events where parameter_id = v_wht and event = 'ended';
  if v_n <> 1 then raise exception 'FAIL: expected one end event for the first WHT row, found %', v_n; end if;
  select count(*) into v_n from regulatory_parameter_events where parameter_id = v_stamp_motor and event = 'retired' and detail = 'superseded by circular';
  if v_n <> 1 then raise exception 'FAIL: expected one retirement event with its reason, found %', v_n; end if;
  select count(*) into v_n from regulatory_parameter_events where parameter_id = v_pct and event = 'retired';
  if v_n <> 1 then raise exception 'FAIL: expected a retirement event for the withdrawn draft, found %', v_n; end if;
  raise notice 'PASS: approvals, end-dates and retirements are logged with actor and detail';

  -------------------------------------------------------------------
  -- 11. Visibility, lookup and tenant isolation
  -------------------------------------------------------------------
  perform pg_temp.as_user(v_fin);
  select count(*) into v_n from regulatory_parameters;
  if v_n = 0 then raise exception 'FAIL: finance should see its tenant''s parameters'; end if;
  select value_num into v_num from reg_get_parameter('tax.wht_agent_commission_percent', date '2026-08-01');
  if v_num <> 10 then raise exception 'FAIL: reg_get_parameter returned % instead of 10', v_num; end if;
  reset role;

  perform pg_temp.as_user(v_out);
  select count(*) into v_n from regulatory_parameters;
  if v_n <> 0 then raise exception 'FAIL: a user with no role must not see parameters (saw %)', v_n; end if;
  select count(*) into v_n from regulatory_parameter_events;
  if v_n <> 0 then raise exception 'FAIL: a user with no role must not see parameter events (saw %)', v_n; end if;
  perform pg_temp.expect_error(
    $q$select reg_get_parameter('tax.wht_agent_commission_percent', date '2026-08-01')$q$,
    'REG_FORBIDDEN', 'outsider lookup');
  perform pg_temp.expect_error(
    $q$insert into regulatory_parameters (tenant_id, parameter_key, value_num, effective_from, source_ref)
       values (get_my_tenant_id(), 'levy.training_percent', 1, date '2026-01-01', 'x')$q$,
    'row-level security', 'outsider insert');
  reset role;

  perform pg_temp.as_user(v_admin_b);
  select count(*) into v_n from regulatory_parameters;
  if v_n <> 0 then raise exception 'FAIL: tenant B must not see tenant A parameters (saw %)', v_n; end if;
  select count(*) into v_n from regulatory_parameter_events;
  if v_n <> 0 then raise exception 'FAIL: tenant B must not see tenant A events (saw %)', v_n; end if;
  perform pg_temp.expect_error(
    $q$select reg_get_parameter('tax.wht_agent_commission_percent', date '2026-08-01')$q$,
    'REG_PARAM_MISSING', 'tenant B lookup must not leak tenant A values');
  perform pg_temp.expect_error(
    format($q$insert into regulatory_parameters (tenant_id, parameter_key, value_num, effective_from, source_ref)
              values (%L, 'levy.training_percent', 1, date '2026-01-01', 'x')$q$, v_ta),
    'row-level security', 'tenant B writes into tenant A');
  reset role;
  raise notice 'PASS: finance and insurance-side readers see their own tenant; outsiders and other tenants see nothing';

  -- Tenant B keeps its own values, independent of tenant A.
  perform pg_temp.as_user(v_admin_b);
  insert into regulatory_parameters (tenant_id, parameter_key, value_num, effective_from, source_ref)
  values (v_tb, 'tax.wht_agent_commission_percent', 15, date '2026-01-01', 'UNVERIFIED: tenant B')
  returning id into v_b;
  reset role;
  if (select count(*) from regulatory_parameters where tenant_id = v_tb) <> 1 then
    raise exception 'FAIL: tenant B should hold exactly its own row';
  end if;
  if platform_reg_number(v_ta, 'tax.wht_agent_commission_percent', date '2026-08-01') <> 10 then
    raise exception 'FAIL: tenant A value changed when tenant B added one';
  end if;
  raise notice 'PASS: each tenant keeps its own values for the same key and date';

  -------------------------------------------------------------------
  -- 12. Denials: no delete, no client writes to events, internal resolvers, anon
  -------------------------------------------------------------------
  perform pg_temp.as_user(v_admin2);
  perform pg_temp.expect_error(
    format('delete from regulatory_parameters where id = %L', v_wht), 'permission denied', 'delete a parameter');
  perform pg_temp.expect_error(
    format($q$insert into regulatory_parameter_events (tenant_id, parameter_id, event) values (%L, %L, 'approved')$q$, v_ta, v_wht),
    'permission denied', 'client writes an event');
  perform pg_temp.expect_error(
    format($q$select platform_reg_number(%L, 'tax.wht_agent_commission_percent', date '2026-08-01')$q$, v_ta),
    'permission denied', 'client calls the internal resolver');
  perform pg_temp.expect_error(
    format($q$select platform_reg_resolve(%L, 'tax.wht_agent_commission_percent', date '2026-08-01')$q$, v_ta),
    'permission denied', 'client calls the internal resolver (row form)');
  reset role;

  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  set local role anon;
  perform pg_temp.expect_error('select count(*) from regulatory_parameters', 'permission denied', 'anon reads parameters');
  perform pg_temp.expect_error(
    $q$select reg_get_parameter('tax.wht_agent_commission_percent')$q$, 'permission denied', 'anon lookup');
  reset role;
  raise notice 'PASS: no deletes, no client event writes, resolvers internal, anon denied';

  -------------------------------------------------------------------
  -- 13. Read-only guard is attached (suspended tenants cannot change parameters)
  -------------------------------------------------------------------
  if not exists (select 1 from pg_trigger where tgrelid = 'public.regulatory_parameters'::regclass and tgname = 'tenant_read_only_guard') then
    raise exception 'FAIL: tenant_read_only_guard is not attached to regulatory_parameters';
  end if;
  raise notice 'PASS: tenant read-only guard attached';
end $$;

do $$ begin raise notice 'PASS: regulatory parameters (A1) tests'; end $$;

rollback;