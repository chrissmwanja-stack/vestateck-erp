-- A draft policy cannot be moved onto an inactive insurer or product line
-- (ins_policies_active_refs_trg), but a draft whose insurer or line is already inactive can
-- still have its other fields edited. Real authenticated table updates. Run only on a
-- disposable local/test database; the whole script rolls back.
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
  line_a uuid; line_off uuid; ins_a uuid; ins_b uuid; ins_off uuid;
  c1 ins_clients%rowtype; p ins_policies%rowtype; n integer;
begin
  insert into tenants(id,name) values(ta,'Active refs test');
  insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data,aud,role,created_at,updated_at)
    select u,'activerefs-'||u||'@test.local','{}','{}','authenticated','authenticated',now(),now() from unnest(array[manager,member]) u;
  insert into app_users(id,tenant_id,name,email)
    select u,ta,'Active refs actor','activerefs-'||u||'@test.local' from unnest(array[manager,member]) u;
  insert into tenant_modules(tenant_id,module) values(ta,'insurance');
  insert into staff_roles(tenant_id,user_id,module,role) values(ta,manager,'insurance','manager'),(ta,member,'insurance','member');

  perform pg_temp.jwt(manager); set local role authenticated;
  insert into ins_product_lines(tenant_id,code,name) values(ta,'FIRE','Fire') returning id into line_a;
  insert into ins_product_lines(tenant_id,code,name,is_active) values(ta,'OLD','Retired line',false) returning id into line_off;
  insert into ins_insurers(tenant_id,code,name) values(ta,'ALPHA','Alpha') returning id into ins_a;
  insert into ins_insurers(tenant_id,code,name) values(ta,'BETA','Beta') returning id into ins_b;
  insert into ins_insurers(tenant_id,code,name,is_active) values(ta,'GONE','Retired insurer',false) returning id into ins_off;
  c1 := ins_register_client('Active refs client','corporate',null,null,null,'low');
  p := ins_create_policy(c1.id,ins_a,line_a,current_date,current_date+365,80000000,'UGX',1000,10,null,null);

  -- Moving to an inactive insurer or product line is refused, for a manager and for a member.
  perform pg_temp.expect_error(format('update ins_policies set insurer_id = %L where id = %L', ins_off, p.id),
    'INS_NOT_FOUND: active insurer', 'draft cannot move to an inactive insurer');
  perform pg_temp.expect_error(format('update ins_policies set product_line_id = %L where id = %L', line_off, p.id),
    'INS_NOT_FOUND: active product line', 'draft cannot move to an inactive product line');
  reset role; perform pg_temp.jwt(member); set local role authenticated;
  perform pg_temp.expect_error(format('update ins_policies set insurer_id = %L where id = %L', ins_off, p.id),
    'INS_NOT_FOUND: active insurer', 'a member cannot bypass the check');
  reset role; perform pg_temp.jwt(manager); set local role authenticated;

  -- Moving to another active insurer still works.
  update ins_policies set insurer_id = ins_b where id = p.id;
  get diagnostics n = row_count;
  perform pg_temp.assert(n = 1, 'a draft can move to another active insurer');

  -- A draft whose insurer is deactivated afterwards can still have other fields edited.
  update ins_insurers set is_active = false where id = ins_b;
  update ins_policies set gross_premium = 2000, notes = 'edited after insurer retired' where id = p.id;
  get diagnostics n = row_count;
  perform pg_temp.assert(n = 1, 'other fields stay editable when the current insurer is inactive');

  raise notice 'PASS: policy active insurer and product line check';
end $$;

rollback;
