-- While risks are linked to a draft policy, its client and product line are locked
-- (ins_policies_link_lock_trg). Unlinking the risks lifts the lock and releases the certificate.
-- Real authenticated RPCs and table updates. Run only on a disposable local/test database;
-- the whole script rolls back.
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
  ta uuid := gen_random_uuid(); manager uuid := gen_random_uuid(); member uuid := gen_random_uuid();
  line_fire uuid; line_other uuid; line_motor uuid; insurer uuid;
  c1 ins_clients%rowtype; c2 ins_clients%rowtype;
  p ins_policies%rowtype; pm ins_policies%rowtype; r_prop uuid; r_veh uuid;
  n integer; got uuid; cert_policy uuid; cert_status text;
begin
  insert into tenants(id,name) values(ta,'Link lock test');
  insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data,aud,role,created_at,updated_at)
    select u,'linklock-'||u||'@test.local','{}','{}','authenticated','authenticated',now(),now() from unnest(array[manager,member]) u;
  insert into app_users(id,tenant_id,name,email)
    select u,ta,'Link lock actor','linklock-'||u||'@test.local' from unnest(array[manager,member]) u;
  insert into tenant_modules(tenant_id,module) values(ta,'insurance');
  insert into staff_roles(tenant_id,user_id,module,role) values(ta,manager,'insurance','manager'),(ta,member,'insurance','member');

  perform pg_temp.jwt(manager); set local role authenticated;
  insert into ins_product_lines(tenant_id,code,name) values(ta,'FIRE','Fire') returning id into line_fire;
  insert into ins_product_lines(tenant_id,code,name) values(ta,'MARINE','Marine') returning id into line_other;
  insert into ins_product_lines(tenant_id,code,name) values(ta,'MOTOR','Motor') returning id into line_motor;
  insert into ins_insurers(tenant_id,code,name) values(ta,'ALPHA','Alpha') returning id into insurer;
  c1 := ins_register_client('Link lock client one','corporate',null,null,null,'low');
  c2 := ins_register_client('Link lock client two','corporate',null,null,null,'low');
  p := ins_create_policy(c1.id,insurer,line_fire,current_date,current_date+365,80000000,'UGX',1000,10,null,null);

  -- No risks linked: a draft created for the wrong client or line can still be corrected.
  update ins_policies set client_id = c2.id where id = p.id;
  update ins_policies set product_line_id = line_other where id = p.id;
  update ins_policies set client_id = c1.id, product_line_id = line_fire where id = p.id;
  select client_id into got from ins_policies where id = p.id;
  perform pg_temp.assert(got = c1.id, 'a draft with no linked risks can change client and product line');

  -- A risk is linked: client and product line are locked, for a manager and for a member alike.
  r_prop := ins_register_risk(c1.id, line_fire, 'property', 'Warehouse');
  perform ins_link_policy_risk(p.id, r_prop);
  perform pg_temp.expect_error(format('update ins_policies set client_id = %L where id = %L', c2.id, p.id),
    'INS_POLICY_LINKED', 'client locked while risks are linked');
  perform pg_temp.expect_error(format('update ins_policies set product_line_id = %L where id = %L', line_other, p.id),
    'INS_POLICY_LINKED', 'product line locked while risks are linked');
  reset role; perform pg_temp.jwt(member); set local role authenticated;
  perform pg_temp.expect_error(format('update ins_policies set client_id = %L where id = %L', c2.id, p.id),
    'INS_POLICY_LINKED', 'a member cannot bypass the lock');
  reset role; perform pg_temp.jwt(manager); set local role authenticated;

  -- Other draft fields stay editable while risks are linked.
  update ins_policies set notes = 'still editable' where id = p.id;
  get diagnostics n = row_count;
  perform pg_temp.assert(n = 1, 'notes can be edited while risks are linked');

  -- Unlinking lifts the lock.
  perform ins_unlink_policy_risk(p.id, r_prop);
  update ins_policies set client_id = c2.id where id = p.id;
  get diagnostics n = row_count;
  perform pg_temp.assert(n = 1, 'the client can change once the risks are unlinked');

  -- A certificate cannot be left behind: unlinking releases it, then the product line can change.
  pm := ins_create_policy(c1.id,insurer,line_motor,current_date,current_date+365,80000000,'UGX',1000,10,null,null);
  r_veh := ins_register_risk(c1.id, line_motor, 'vehicle', 'Pickup', 'UAL 555L', 'CH-LINKLOCK-1', null, 'Toyota', 'Hilux', 2019, 80000000);
  perform ins_load_certificate_range('LL-', 1, 1, 4);
  perform ins_issue_certificate('LL-0001', r_veh, 'Kampala');
  perform ins_link_policy_risk(pm.id, r_veh);
  perform ins_attach_certificate(pm.id, 'LL-0001');
  perform pg_temp.expect_error(format('update ins_policies set product_line_id = %L where id = %L', line_fire, pm.id),
    'INS_POLICY_LINKED', 'product line locked while a certificate is attached through its risk');
  perform ins_unlink_policy_risk(pm.id, r_veh);
  select policy_id, status into cert_policy, cert_status from ins_certificate_stock where serial_no = 'LL-0001' and tenant_id = ta;
  perform pg_temp.assert(cert_policy is null and cert_status = 'issued', 'unlinking releases the certificate and keeps it issued');
  update ins_policies set product_line_id = line_fire where id = pm.id;
  get diagnostics n = row_count;
  perform pg_temp.assert(n = 1, 'the product line can change once the certificate is released');

  raise notice 'PASS: policy client and product line lock';
end $$;

rollback;
