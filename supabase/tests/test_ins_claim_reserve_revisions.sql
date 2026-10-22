-- Claim reserve revisions and history (20261022090000).
-- Real authenticated RPCs. Run only on a disposable local/test database; the whole script rolls back.
-- The policy is moved to 'active' directly (as the owner, with ins.via_rpc on) instead of binding it,
-- so this test needs no accounting setup. If a status guard rejects that shortcut, bind it instead.
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

create function pg_temp.activate(p_id uuid)
returns void language plpgsql as $$
begin
  perform set_config('ins.via_rpc', 'on', true);
  update ins_policies set status = 'active' where id = p_id;
end $$;

do $$
declare
  ta uuid := gen_random_uuid(); tb uuid := gen_random_uuid();
  manager uuid := gen_random_uuid(); member uuid := gen_random_uuid(); other_mgr uuid := gen_random_uuid();
  line uuid; insurer uuid; line_b uuid; insurer_b uuid;
  c1 ins_clients%rowtype; cb ins_clients%rowtype;
  p ins_policies%rowtype; pb ins_policies%rowtype;
  cl ins_claims%rowtype; clb ins_claims%rowtype;
  n integer; h ins_claim_reserve_history%rowtype;
begin
  insert into tenants(id,name) values(ta,'Reserve A'),(tb,'Reserve B');
  insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data,aud,role,created_at,updated_at)
    select u,'reserve-'||u||'@test.local','{}','{}','authenticated','authenticated',now(),now() from unnest(array[manager,member,other_mgr]) u;
  insert into app_users(id,tenant_id,name,email) values
    (manager,ta,'Manager','reserve-'||manager||'@test.local'),
    (member,ta,'Member','reserve-'||member||'@test.local'),
    (other_mgr,tb,'Other manager','reserve-'||other_mgr||'@test.local');
  insert into tenant_modules(tenant_id,module) values(ta,'insurance'),(tb,'insurance');
  insert into staff_roles(tenant_id,user_id,module,role) values
    (ta,manager,'insurance','manager'),(ta,member,'insurance','member'),(tb,other_mgr,'insurance','manager');

  perform pg_temp.jwt(manager); set local role authenticated;
  insert into ins_product_lines(tenant_id,code,name) values(ta,'FIRE','Fire') returning id into line;
  insert into ins_insurers(tenant_id,code,name) values(ta,'ALPHA','Alpha') returning id into insurer;
  c1 := ins_register_client('Reserve client','corporate',null,null,null,'low');
  p := ins_create_policy(c1.id,insurer,line,current_date-30,current_date+335,50000000,'UGX',1000,10,null,null);
  reset role;
  perform pg_temp.activate(p.id);

  perform pg_temp.jwt(other_mgr); set local role authenticated;
  insert into ins_product_lines(tenant_id,code,name) values(tb,'FIRE','Fire') returning id into line_b;
  insert into ins_insurers(tenant_id,code,name) values(tb,'BETA','Beta') returning id into insurer_b;
  cb := ins_register_client('Other client','corporate',null,null,null,'low');
  pb := ins_create_policy(cb.id,insurer_b,line_b,current_date-30,current_date+335,50000000,'UGX',1000,10,null,null);
  reset role;
  perform pg_temp.activate(pb.id);
  perform pg_temp.jwt(other_mgr); set local role authenticated;
  clb := ins_create_claim(pb.id,current_date-5,current_date-4,'Other tenant loss',null,1000000);
  reset role;

  -- ---- Registering a claim records the initial reserve ----
  perform pg_temp.jwt(member); set local role authenticated;
  cl := ins_create_claim(p.id,current_date-5,current_date-4,'Warehouse flooded',null,2000000);
  select * into h from ins_claim_reserve_history where claim_id = cl.id;
  perform pg_temp.assert(h.kind = 'initial' and h.previous_amount is null and h.new_amount = 2000000, 'a new claim gets an initial history row');
  select count(*) into n from ins_claim_reserve_history where claim_id = cl.id;
  perform pg_temp.assert(n = 1, 'only one history row so far');

  -- ---- Direct edits are refused ----
  perform pg_temp.expect_state(format('update ins_claims set reserve_amount = 1 where id = %L',cl.id),'42501','direct reserve update');
  perform pg_temp.expect_state(format('insert into ins_claim_reserve_history(tenant_id,claim_id,kind,previous_amount,new_amount,reason) values(%L,%L,%L,1,2,%L)',ta,cl.id,'revision','Direct insert attempt'),'42501','direct history insert');
  perform pg_temp.expect_state(format('delete from ins_claim_reserve_history where claim_id = %L',cl.id),'42501','direct history delete');
  -- Other claim fields remain editable directly, as before.
  update ins_claims set insurer_claim_ref = 'INS-REF-1' where id = cl.id;
  get diagnostics n = row_count;
  perform pg_temp.assert(n = 1, 'the insurer reference is still editable');

  -- ---- Validation ----
  perform pg_temp.expect_error(format('select ins_revise_claim_reserve(%L,-1,%L)',cl.id,'Negative amount'),'INS_AMOUNT','negative reserve');
  perform pg_temp.expect_error(format('select ins_revise_claim_reserve(%L,null,%L)',cl.id,'Missing amount'),'INS_AMOUNT','null reserve');
  perform pg_temp.expect_error(format('select ins_revise_claim_reserve(%L,3000000,%L)',cl.id,'no'),'INS_RESERVE_REASON','reason too short');
  perform pg_temp.expect_error(format('select ins_revise_claim_reserve(%L,2000000,%L)',cl.id,'Same amount again'),'INS_RESERVE_UNCHANGED','no change');
  perform pg_temp.expect_error(format('select ins_revise_claim_reserve(%L,50000001,%L)',cl.id,'Above the sum insured'),'INS_AMOUNT','above sum insured');
  perform pg_temp.expect_error(format('select ins_revise_claim_reserve(%L,3000000,%L)',clb.id,'Another tenant claim'),'INS_NOT_FOUND','another tenant claim');

  -- ---- A revision updates the claim and the history ----
  cl := ins_revise_claim_reserve(cl.id,3500000.456,'  Surveyor found more damage  ');
  perform pg_temp.assert(cl.reserve_amount = 3500000.46, 'the reserve is rounded to 2dp and applied');
  select * into h from ins_claim_reserve_history where claim_id = cl.id and kind = 'revision';
  perform pg_temp.assert(h.previous_amount = 2000000 and h.new_amount = 3500000.46 and h.reason = 'Surveyor found more damage', 'the revision records previous, new and a trimmed reason');
  perform pg_temp.assert(h.revised_by = member, 'the revision records who made it');
  cl := ins_revise_claim_reserve(cl.id,0,'Insurer confirmed a lower estimate');
  perform pg_temp.assert(cl.reserve_amount = 0, 'a reserve can be revised down to zero');
  select count(*) into n from ins_claim_reserve_history where claim_id = cl.id;
  perform pg_temp.assert(n = 3, 'initial plus two revisions');

  -- ---- Only open claims can be revised ----
  perform ins_transition_claim(cl.id,'assessing',null,null);
  cl := ins_revise_claim_reserve(cl.id,1000000,'Reserve while assessing');
  reset role; perform pg_temp.jwt(manager); set local role authenticated;
  perform ins_transition_claim(cl.id,'repudiated','Not covered under the policy wording',null);
  perform pg_temp.expect_error(format('select ins_revise_claim_reserve(%L,5,%L)',cl.id,'After repudiation'),'INS_CLAIM_STATE','repudiated claim');

  -- ---- Isolation ----
  reset role; perform pg_temp.jwt(other_mgr); set local role authenticated;
  select count(*) into n from ins_claim_reserve_history;
  perform pg_temp.assert(n = 1, 'another tenant sees only its own history');
  select count(*) into n from ins_claim_reserve_history where claim_id = cl.id;
  perform pg_temp.assert(n = 0, 'another tenant cannot read this claim''s history');

  raise notice 'PASS: claim reserve revisions and history';
end $$;

rollback;
