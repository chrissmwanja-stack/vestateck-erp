-- A product line decides whether its policies need a certificate before binding
-- (ins_product_lines.requires_certificate, with MOTOR always on). Real authenticated RPCs.
-- Run only on a disposable local/test database; the whole script rolls back.
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
  ta uuid := gen_random_uuid(); tb uuid := gen_random_uuid();
  manager uuid := gen_random_uuid(); member uuid := gen_random_uuid(); other_mgr uuid := gen_random_uuid();
  ar_gl uuid; pay_gl uuid; unearned_gl uuid; income_gl uuid;
  line_mot uuid; line_motor uuid; line_fire uuid; insurer uuid; c ins_clients%rowtype;
  r_vehicle uuid; p1 ins_policies%rowtype; p2 ins_policies%rowtype; p3 ins_policies%rowtype; p4 ins_policies%rowtype;
  n integer; st text; flag boolean;
begin
  insert into tenants(id,name) values(ta,'Certificate line test A'),(tb,'Certificate line test B');
  insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data,aud,role,created_at,updated_at)
    select u,'certline-'||u||'@test.local','{}','{}','authenticated','authenticated',now(),now()
    from unnest(array[manager,member,other_mgr]) u;
  insert into app_users(id,tenant_id,name,email)
    select u,case when u=other_mgr then tb else ta end,'Certificate line test actor','certline-'||u||'@test.local'
    from unnest(array[manager,member,other_mgr]) u;
  insert into tenant_modules(tenant_id,module) values(ta,'insurance'),(tb,'insurance');
  insert into staff_roles(tenant_id,user_id,module,role) values
    (ta,manager,'insurance','manager'),(ta,member,'insurance','member'),(tb,other_mgr,'insurance','manager');
  insert into gl_accounts(tenant_id,account_code,name,account_type) values(ta,'1100','AR','asset') returning id into ar_gl;
  insert into gl_accounts(tenant_id,account_code,name,account_type) values(ta,'2010','Insurer payable','liability') returning id into pay_gl;
  insert into gl_accounts(tenant_id,account_code,name,account_type) values(ta,'2020','Unearned commission','liability') returning id into unearned_gl;
  insert into gl_accounts(tenant_id,account_code,name,account_type) values(ta,'4000','Commission income','revenue') returning id into income_gl;
  insert into gl_posting_rules(tenant_id,account_role,gl_account_id) values
    (ta,'ar_control',ar_gl),(ta,'insurer_payable',pay_gl),(ta,'unearned_commission',unearned_gl),(ta,'commission_income',income_gl);

  perform pg_temp.jwt(manager); set local role authenticated;
  -- A motor line the company coded MOT: no flag yet. MOTOR with the flag explicitly off. A fire line.
  insert into ins_product_lines(tenant_id,code,name) values(ta,'MOT','Cars') returning id into line_mot;
  insert into ins_product_lines(tenant_id,code,name,requires_certificate) values(ta,'MOTOR','Motor fleet',false) returning id into line_motor;
  insert into ins_product_lines(tenant_id,code,name) values(ta,'FIRE','Fire') returning id into line_fire;
  insert into ins_insurers(tenant_id,code,name) values(ta,'ALPHA','Alpha') returning id into insurer;
  c := ins_register_client('Certificate line client','corporate',null,null,null,'low');

  select requires_certificate into flag from ins_product_lines where id = line_mot;
  perform pg_temp.assert(flag is false, 'a new line starts with no certificate requirement');

  -- Flag off, code is not MOTOR: no gate. This is the gap the flag closes, so it must be visible.
  r_vehicle := ins_register_risk(c.id, line_mot, 'property', 'Showroom');
  perform pg_temp.assert(r_vehicle is not null, 'unflagged MOT line accepts a property risk');
  p1 := ins_create_policy(c.id,insurer,line_mot,current_date,current_date+365,80000000,'UGX',1000,10,null,null);
  p1 := ins_bind_policy(p1.id);
  perform pg_temp.assert(p1.status = 'active', 'unflagged MOT line binds with no certificate');

  -- Only a manager can change the setting. A member's update changes nothing; another company's manager cannot reach it.
  reset role; perform pg_temp.jwt(member); set local role authenticated;
  update ins_product_lines set requires_certificate = true where id = line_mot;
  get diagnostics n = row_count;
  perform pg_temp.assert(n = 0, 'a member cannot switch the setting');
  reset role; perform pg_temp.jwt(other_mgr); set local role authenticated;
  update ins_product_lines set requires_certificate = true where id = line_mot;
  get diagnostics n = row_count;
  perform pg_temp.assert(n = 0, 'another company cannot switch the setting');

  reset role; perform pg_temp.jwt(manager); set local role authenticated;
  update ins_product_lines set requires_certificate = true where id = line_mot;
  get diagnostics n = row_count;
  perform pg_temp.assert(n = 1, 'a manager can switch the setting on');

  -- Flag on: the vehicle rules and the certificate gate now apply to the MOT line.
  perform pg_temp.expect_error(format('select ins_register_risk(%L,%L,%L,%L)', c.id, line_mot, 'property', 'Office'),
    'INS_RISK_TYPE', 'flagged line needs a vehicle risk');
  perform pg_temp.expect_error(format('select ins_register_risk(%L,%L,%L,%L)', c.id, line_mot, 'vehicle', 'Pickup'),
    'INS_RISK_INPUT', 'flagged line needs a chassis number');
  p2 := ins_create_policy(c.id,insurer,line_mot,current_date,current_date+365,80000000,'UGX',1000,10,null,null);
  perform pg_temp.expect_error(format('select ins_bind_policy(%L)', p2.id),
    'INS_MOTOR_CERTIFICATE_REQUIRED', 'flagged line bind without certificate');
  select status into st from ins_policies where id = p2.id;
  perform pg_temp.assert(st = 'draft', 'a refused bind leaves the policy in draft');

  -- Full path on the flagged line: risk, certificate, link, attach, bind. The certificate is consumed.
  r_vehicle := ins_register_risk(c.id, line_mot, 'vehicle', 'Pickup', 'UAL 123A', 'CH-CERTLINE-1', null, 'Toyota', 'Hilux', 2019, 80000000);
  perform ins_load_certificate_range('CL-', 1, 1, 4);
  perform ins_issue_certificate('CL-0001', r_vehicle, 'Kampala');
  perform ins_link_policy_risk(p2.id, r_vehicle);
  perform ins_attach_certificate(p2.id, 'CL-0001');
  p2 := ins_bind_policy(p2.id);
  perform pg_temp.assert(p2.status = 'active', 'flagged line binds with a certificate');
  select status into st from ins_certificate_stock where serial_no = 'CL-0001' and tenant_id = ta;
  perform pg_temp.assert(st = 'used', 'the certificate is consumed at bind');

  -- MOTOR stays gated even with the flag off: the code is never silently opened.
  p3 := ins_create_policy(c.id,insurer,line_motor,current_date,current_date+365,80000000,'UGX',1000,10,null,null);
  perform pg_temp.expect_error(format('select ins_bind_policy(%L)', p3.id),
    'INS_MOTOR_CERTIFICATE_REQUIRED', 'MOTOR bind without certificate, flag off');

  -- A line with no requirement is not gated.
  p4 := ins_create_policy(c.id,insurer,line_fire,current_date,current_date+365,50000000,'UGX',1000,10,null,null);
  p4 := ins_bind_policy(p4.id);
  perform pg_temp.assert(p4.status = 'active', 'fire line binds with no certificate');

  -- Switching the setting off opens the line again.
  update ins_product_lines set requires_certificate = false where id = line_mot;
  p1 := ins_create_policy(c.id,insurer,line_mot,current_date,current_date+365,80000000,'UGX',1000,10,null,null);
  p1 := ins_bind_policy(p1.id);
  perform pg_temp.assert(p1.status = 'active', 'a line with the setting switched off binds with no certificate');

  raise notice 'PASS: product line certificate requirement';
end $$;

rollback;
