-- Renewal outcomes and bulk renewal drafts (20261022080000).
-- Real authenticated RPCs. Run only on a disposable local/test database; the whole script rolls back.
-- Policies are moved to 'active' directly (as the owner, with ins.via_rpc on) instead of binding them,
-- so this test needs no accounting setup. If a status guard rejects that shortcut, bind them instead.
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
  p1 ins_policies%rowtype; p2 ins_policies%rowtype; p3 ins_policies%rowtype; p4 ins_policies%rowtype; pb ins_policies%rowtype;
  o ins_renewal_outcomes%rowtype; d ins_policies%rowtype;
  res jsonb; n integer;
begin
  insert into tenants(id,name) values(ta,'Renewal outcomes A'),(tb,'Renewal outcomes B');
  insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data,aud,role,created_at,updated_at)
    select u,'renewout-'||u||'@test.local','{}','{}','authenticated','authenticated',now(),now() from unnest(array[manager,member,other_mgr]) u;
  insert into app_users(id,tenant_id,name,email) values
    (manager,ta,'Manager','renewout-'||manager||'@test.local'),
    (member,ta,'Member','renewout-'||member||'@test.local'),
    (other_mgr,tb,'Other manager','renewout-'||other_mgr||'@test.local');
  insert into tenant_modules(tenant_id,module) values(ta,'insurance'),(tb,'insurance');
  insert into staff_roles(tenant_id,user_id,module,role) values
    (ta,manager,'insurance','manager'),(ta,member,'insurance','member'),(tb,other_mgr,'insurance','manager');

  perform pg_temp.jwt(manager); set local role authenticated;
  insert into ins_product_lines(tenant_id,code,name) values(ta,'FIRE','Fire') returning id into line;
  insert into ins_insurers(tenant_id,code,name) values(ta,'ALPHA','Alpha') returning id into insurer;
  c1 := ins_register_client('Renewal client','corporate',null,null,null,'low');
  p1 := ins_create_policy(c1.id,insurer,line,current_date-300,current_date+65,80000000,'UGX',1000,10,null,null);
  p2 := ins_create_policy(c1.id,insurer,line,current_date-300,current_date+65,80000000,'UGX',1000,10,null,null);
  p3 := ins_create_policy(c1.id,insurer,line,current_date-300,current_date+65,80000000,'UGX',1000,10,null,null);
  p4 := ins_create_policy(c1.id,insurer,line,current_date-300,current_date+65,80000000,'UGX',1000,10,null,null);
  reset role;
  perform pg_temp.activate(p1.id); perform pg_temp.activate(p2.id); perform pg_temp.activate(p3.id);
  -- p4 stays a draft on purpose.

  -- Other tenant, for isolation.
  perform pg_temp.jwt(other_mgr); set local role authenticated;
  insert into ins_product_lines(tenant_id,code,name) values(tb,'FIRE','Fire') returning id into line_b;
  insert into ins_insurers(tenant_id,code,name) values(tb,'BETA','Beta') returning id into insurer_b;
  cb := ins_register_client('Other tenant client','corporate',null,null,null,'low');
  pb := ins_create_policy(cb.id,insurer_b,line_b,current_date-300,current_date+65,80000000,'UGX',1000,10,null,null);
  reset role;
  perform pg_temp.activate(pb.id);

  -- ---- Recording an outcome ----
  perform pg_temp.jwt(member); set local role authenticated;
  perform pg_temp.expect_error(format('select ins_record_renewal_outcome(%L,%L,%L)',p1.id,'won','Because I said so'),'INS_OUTCOME_INVALID','unknown outcome');
  perform pg_temp.expect_error(format('select ins_record_renewal_outcome(%L,%L,%L)',p1.id,'lost','no'),'INS_OUTCOME_REASON','reason too short');
  perform pg_temp.expect_error(format('select ins_record_renewal_outcome(%L,%L,%L)',p4.id,'lost','Moved to another broker'),'INS_RENEWAL_STATE','draft policy has no outcome');
  perform pg_temp.expect_error(format('select ins_record_renewal_outcome(%L,%L,%L)',pb.id,'lost','Moved to another broker'),'INS_NOT_FOUND','another tenant''s policy');
  o := ins_record_renewal_outcome(p1.id,'lost','Moved to another broker on price');
  perform pg_temp.assert(o.outcome = 'lost' and o.reason = 'Moved to another broker on price', 'a member can record an outcome');
  o := ins_record_renewal_outcome(p1.id,'declined','  Client closing the business  ');
  perform pg_temp.assert(o.outcome = 'declined' and o.reason = 'Client closing the business', 'recording again replaces the outcome and trims the reason');
  select count(*) into n from ins_renewal_outcomes where policy_id = p1.id;
  perform pg_temp.assert(n = 1, 'one outcome per policy');

  -- ---- Direct writes are refused, for everyone ----
  perform pg_temp.expect_state(format('insert into ins_renewal_outcomes(tenant_id,policy_id,outcome,reason) values(%L,%L,%L,%L)',ta,p2.id,'lost','Direct insert attempt'),'42501','direct insert');
  perform pg_temp.expect_state(format('delete from ins_renewal_outcomes where policy_id = %L',p1.id),'42501','direct delete');
  reset role; perform pg_temp.jwt(manager); set local role authenticated;
  perform pg_temp.expect_state(format('update ins_renewal_outcomes set reason = %L where policy_id = %L','Edited directly',p1.id),'42501','direct update');

  -- ---- The pipeline shows the outcome; another tenant sees nothing ----
  select count(*) into n from ins_renewal_pipeline where policy_id = p1.id and renewal_outcome = 'declined';
  perform pg_temp.assert(n = 1, 'the pipeline carries the outcome');
  select count(*) into n from ins_renewal_pipeline where policy_id = p2.id and renewal_outcome is null;
  perform pg_temp.assert(n = 1, 'a policy without an outcome shows none');
  reset role; perform pg_temp.jwt(other_mgr); set local role authenticated;
  select count(*) into n from ins_renewal_outcomes;
  perform pg_temp.assert(n = 0, 'another tenant cannot read outcomes');
  perform pg_temp.expect_error(format('select ins_clear_renewal_outcome(%L)',p1.id),'INS_NOT_FOUND','another tenant cannot clear');
  reset role; perform pg_temp.jwt(manager); set local role authenticated;

  -- ---- A policy with an outcome cannot be renewed until it is cleared ----
  perform pg_temp.expect_error(format('select ins_create_renewal_draft(%L)',p1.id),'INS_RENEWAL_CLOSED','renewal blocked by an outcome');
  reset role; perform pg_temp.jwt(member); set local role authenticated;
  perform pg_temp.expect_state(format('select ins_clear_renewal_outcome(%L)',p1.id),'42501','a member cannot clear an outcome');
  reset role; perform pg_temp.jwt(manager); set local role authenticated;
  perform ins_clear_renewal_outcome(p1.id);
  perform pg_temp.expect_error(format('select ins_clear_renewal_outcome(%L)',p1.id),'INS_NOT_FOUND','clearing twice');
  d := ins_create_renewal_draft(p1.id);
  perform pg_temp.assert(d.status = 'draft' and d.renewal_of_id = p1.id, 'renewal works once the outcome is cleared');

  -- An open renewal draft blocks recording an outcome.
  perform pg_temp.expect_error(format('select ins_record_renewal_outcome(%L,%L,%L)',p1.id,'lost','Changed our mind later'),'INS_RENEWAL_EXISTS','outcome blocked by an open draft');

  -- ---- Bulk drafts ----
  perform ins_record_renewal_outcome(p3.id,'lapsed','No response after three reminders');
  perform pg_temp.expect_error('select ins_create_renewal_drafts(''{}''::uuid[])','INS_BULK_EMPTY','empty selection');
  perform pg_temp.expect_error(format('select ins_create_renewal_drafts(array(select gen_random_uuid() from generate_series(1,101)))'),'INS_BULK_LIMIT','more than 100');
  -- p1 already has a draft, p2 is fine, p3 has an outcome, p4 is a draft policy, pb belongs to another tenant, one id is unknown.
  res := ins_create_renewal_drafts(array[p1.id,p2.id,p3.id,p4.id,pb.id,gen_random_uuid(),p2.id]);
  perform pg_temp.assert(jsonb_array_length(res) = 6, 'one result per distinct policy');
  perform pg_temp.assert((select (e->>'ok')::boolean from jsonb_array_elements(res) e where e->>'policy_id' = p2.id::text), 'the eligible policy got a draft');
  perform pg_temp.assert((select e->>'draft_id' is not null from jsonb_array_elements(res) e where e->>'policy_id' = p2.id::text), 'the result names the new draft');
  perform pg_temp.assert((select e->>'error' like 'INS_RENEWAL_EXISTS%' from jsonb_array_elements(res) e where e->>'policy_id' = p1.id::text), 'an existing draft is reported, not fatal');
  perform pg_temp.assert((select e->>'error' like 'INS_RENEWAL_CLOSED%' from jsonb_array_elements(res) e where e->>'policy_id' = p3.id::text), 'a closed renewal is reported');
  perform pg_temp.assert((select e->>'error' like 'INS_RENEWAL_STATE%' from jsonb_array_elements(res) e where e->>'policy_id' = p4.id::text), 'a draft policy is reported');
  perform pg_temp.assert((select e->>'error' like 'INS_NOT_FOUND%' from jsonb_array_elements(res) e where e->>'policy_id' = pb.id::text), 'another tenant''s policy is reported as not found');
  select count(*) into n from ins_policies where renewal_of_id = p2.id and status = 'draft';
  perform pg_temp.assert(n = 1, 'exactly one draft was created for the eligible policy');
  select count(*) into n from ins_policies where renewal_of_id = pb.id;
  perform pg_temp.assert(n = 0, 'nothing was created for another tenant''s policy');

  raise notice 'PASS: renewal outcomes and bulk renewal drafts';
end $$;

rollback;
