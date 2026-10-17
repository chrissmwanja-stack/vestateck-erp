-- Insured-risk register, certificate stock and the motor bind gate.
-- Real authenticated RPCs. Run only on a disposable local/test database; the
-- whole script rolls back.
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

create function pg_temp.expect_state(p_sql text, p_state text, p_label text)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlstate = p_state then
      return;
    end if;
    raise exception 'FAIL: % raised sqlstate % (%), expected %', p_label, sqlstate, sqlerrm, p_state;
  end;
  raise exception 'FAIL: % succeeded but should have failed with sqlstate %', p_label, p_state;
end $$;

create function pg_temp.assert(p_ok boolean, p_msg text)
returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_msg; end if;
end $$;

create function pg_temp.jwt(p_uid uuid)
returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
$$;

do $$
declare
  ta uuid := gen_random_uuid(); tb uuid := gen_random_uuid(); manager uuid := gen_random_uuid(); outsider uuid := gen_random_uuid();
  other_mgr uuid := gen_random_uuid();
  ar_gl uuid; pay_gl uuid; unearned_gl uuid; income_gl uuid;
  line_motor uuid; line_prop uuid; insurer uuid; c ins_clients%rowtype;
  r_vehicle uuid; r_other uuid; r_prop uuid; p ins_policies%rowtype; p_no_cert ins_policies%rowtype; p_prop ins_policies%rowtype;
  c2 ins_clients%rowtype; r_foreign uuid;
  n integer; st text;
begin
  insert into tenants(id,name) values(ta,'Risk register test A'),(tb,'Risk register test B');
  insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data,aud,role,created_at,updated_at)
    select u,'risk-'||u||'@test.local','{}','{}','authenticated','authenticated',now(),now()
    from unnest(array[manager,outsider,other_mgr]) u;
  insert into app_users(id,tenant_id,name,email)
    select u,case when u=other_mgr then tb else ta end,'Risk test actor','risk-'||u||'@test.local'
    from unnest(array[manager,outsider,other_mgr]) u;
  insert into tenant_modules(tenant_id,module) values(ta,'insurance'),(tb,'insurance');
  insert into staff_roles(tenant_id,user_id,module,role) values(ta,manager,'insurance','manager'),(tb,other_mgr,'insurance','manager');
  insert into gl_accounts(tenant_id,account_code,name,account_type) values(ta,'1100','AR','asset') returning id into ar_gl;
  insert into gl_accounts(tenant_id,account_code,name,account_type) values(ta,'2010','Insurer payable','liability') returning id into pay_gl;
  insert into gl_accounts(tenant_id,account_code,name,account_type) values(ta,'2020','Unearned commission','liability') returning id into unearned_gl;
  insert into gl_accounts(tenant_id,account_code,name,account_type) values(ta,'4000','Commission income','revenue') returning id into income_gl;
  insert into gl_posting_rules(tenant_id,account_role,gl_account_id) values
    (ta,'ar_control',ar_gl),(ta,'insurer_payable',pay_gl),(ta,'unearned_commission',unearned_gl),(ta,'commission_income',income_gl);

  perform pg_temp.jwt(manager); set local role authenticated;
  insert into ins_product_lines(tenant_id,code,name) values(ta,'MOTOR','Motor') returning id into line_motor;
  insert into ins_product_lines(tenant_id,code,name) values(ta,'PROP','Property') returning id into line_prop;
  insert into ins_insurers(tenant_id,code,name) values(ta,'ALPHA','Alpha') returning id into insurer;
  c := ins_register_client('Risk client','corporate',null,null,null,'low');

  -- Register: a motor risk must be a vehicle with a chassis number.
  perform pg_temp.expect_error(format('select ins_register_risk(%L,%L,%L,%L)', c.id, line_motor, 'property', 'Office'),
    'INS_RISK_TYPE', 'motor risk must be a vehicle');
  perform pg_temp.expect_error(format('select ins_register_risk(%L,%L,%L,%L)', c.id, line_motor, 'vehicle', 'Pickup'),
    'INS_RISK_INPUT', 'vehicle needs chassis');
  r_vehicle := ins_register_risk(c.id, line_motor, 'vehicle', 'Pickup', 'UAL 123A', 'CH-001', 'EN-001', 'Toyota', 'Hilux', 2019, 80000000);
  r_other := ins_register_risk(c.id, line_motor, 'vehicle', 'Second pickup', null, 'CH-002', null, null, null, null, 0);
  perform pg_temp.expect_error(format('select ins_register_risk(%L,%L,%L,%L,null,%L)', c.id, line_motor, 'vehicle', 'Dup', 'CH-001'),
    'INS_DUPLICATE', 'duplicate chassis');
  r_prop := ins_register_risk(c.id, line_prop, 'property', 'Warehouse, Plot 4', null, null, null, null, null, null, 250000000);
  perform pg_temp.assert(r_prop is not null, 'property risk registered without chassis');

  -- Stock: load a range, reject a duplicate range, issue, and void.
  n := ins_load_certificate_range('MC-', 1, 5, 4);
  perform pg_temp.assert(n = 5, 'five certificates loaded');
  perform pg_temp.expect_error('select ins_load_certificate_range(''MC-'', 4, 6, 4)', 'INS_DUPLICATE', 'overlapping range');
  perform pg_temp.expect_error('select ins_load_certificate_range(''MC-'', 10, 9999, 4)', 'INS_INPUT', 'range too large');
  perform pg_temp.expect_error(format('select ins_issue_certificate(%L,%L,%L)', 'MC-0001', r_prop, 'Kampala'),
    'INS_CERTIFICATE_RISK', 'certificate to a non-vehicle risk');
  perform ins_issue_certificate('MC-0001', r_vehicle, 'Kampala branch');
  perform pg_temp.expect_error(format('select ins_issue_certificate(%L,%L,%L)', 'MC-0001', r_vehicle, 'Entebbe'),
    'INS_CERTIFICATE_STATE', 'issue an already issued certificate');
  perform ins_void_certificate('MC-0002', 'spoiled', 'Printer jam');
  perform pg_temp.expect_error('select ins_void_certificate(''MC-0002'', ''voided'', ''again'')',
    'INS_CERTIFICATE_STATE', 'void a spoiled certificate');
  perform pg_temp.expect_error('select ins_void_certificate(''MC-0003'', ''voided'', '' '')',
    'INS_INPUT', 'void needs a reason');

  -- Policies: one motor draft (gets the certificate), one motor draft (no certificate).
  p := ins_create_policy(c.id,insurer,line_motor,current_date,current_date+365,80000000,'UGX',1000,10,null,null);
  p_no_cert := ins_create_policy(c.id,insurer,line_motor,current_date,current_date+365,80000000,'UGX',1000,10,null,null);
  p_prop := ins_create_policy(c.id,insurer,line_prop,current_date,current_date+365,250000000,'UGX',1000,10,null,null);

  perform pg_temp.expect_error(format('select ins_attach_certificate(%L,%L)', p.id, 'MC-0001'),
    'INS_CERTIFICATE_RISK', 'attach before the risk is linked');
  perform ins_link_policy_risk(p.id, r_vehicle);
  perform ins_link_policy_risk(p.id, r_vehicle);
  c2 := ins_register_client('Other risk client','corporate',null,null,null,'low');
  r_foreign := ins_register_risk(c2.id, line_prop, 'property', 'Other client warehouse', null, null, null, null, null, null, 1000000);
  perform pg_temp.expect_error(format('select ins_link_policy_risk(%L,%L)', p.id, r_foreign),
    'INS_RISK_CLIENT', 'linking a risk must use the policy client');
  perform ins_link_policy_risk(p_prop.id, r_prop);
  perform ins_attach_certificate(p.id, 'MC-0001');
  perform pg_temp.expect_error(format('select ins_attach_certificate(%L,%L)', p_no_cert.id, 'MC-0001'),
    'INS_CERTIFICATE_STATE', 'a certificate cannot serve two policies');

  -- Motor gate: no certificate, no bind. Nothing is posted.
  perform ins_link_policy_risk(p_no_cert.id, r_other);
  perform pg_temp.expect_error(format('select ins_bind_policy(%L)', p_no_cert.id),
    'INS_MOTOR_CERTIFICATE_REQUIRED', 'motor bind without certificate');
  select status into st from ins_policies where id = p_no_cert.id;
  perform pg_temp.assert(st = 'draft', 'failed motor bind leaves the policy in draft');

  -- Motor bind with a certificate succeeds and marks it used.
  p := ins_bind_policy(p.id);
  perform pg_temp.assert(p.status = 'active', 'motor policy with certificate binds');
  select status into st from ins_certificate_stock where serial_no = 'MC-0001' and tenant_id = ta;
  perform pg_temp.assert(st = 'used', 'certificate becomes used at bind');
  perform pg_temp.expect_error(format('select ins_unlink_policy_risk(%L,%L)', p.id, r_vehicle),
    'INS_NOT_DRAFT', 'bound policy cannot be unlinked');
  perform pg_temp.expect_error('select ins_void_certificate(''MC-0001'', ''voided'', ''x'')',
    'INS_CERTIFICATE_STATE', 'a used certificate cannot be voided');

  -- Non-motor policies are not gated.
  p_prop := ins_bind_policy(p_prop.id);
  perform pg_temp.assert(p_prop.status = 'active', 'property policy binds without a certificate');

  -- Cross-tenant: another tenant's manager cannot see or change this register.
  reset role;
  perform pg_temp.jwt(other_mgr); set local role authenticated;
  select count(*) into n from ins_risks;
  perform pg_temp.assert(n = 0, 'other tenant cannot read risks');
  select count(*) into n from ins_certificate_stock;
  perform pg_temp.assert(n = 0, 'other tenant cannot read certificate stock');
  perform pg_temp.expect_error(format('select ins_set_risk_status(%L,%L)', r_vehicle, 'inactive'),
    'INS_NOT_FOUND', 'other tenant cannot change a risk');

  -- Direct writes are blocked even for the tenant's own manager.
  reset role;
  perform pg_temp.jwt(manager); set local role authenticated;
  perform pg_temp.expect_state(format('insert into ins_risks(tenant_id,client_id,product_line_id,risk_type,description) values (%L,%L,%L,''other'',''x'')', ta, c.id, line_prop),
    '42501', 'direct insert into ins_risks');
  perform pg_temp.expect_state('update ins_certificate_stock set status = ''voided''', '42501', 'direct stock update');

  raise notice 'PASS: insurance risk register, certificate stock and motor bind gate';
end $$;

rollback;
