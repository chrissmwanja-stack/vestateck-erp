-- Claim approval history (20261123000000).
-- Real authenticated RPCs. Run only on a disposable local/test database; the whole script rolls back.
-- The policy is moved to 'active' directly (as the owner, with ins.via_rpc on) instead of binding
-- it, so this test needs no accounting setup.
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

-- Everything here runs in one transaction, so now() is frozen and every event and history
-- row a claim gets would share one timestamp. The register's same-instant tie-break follows
-- the chain "which row leads to the next", which cannot order a cycle such as
-- assessing -> approved -> assessing: every row then has a successor and the pick falls to a
-- random uuid. In production each transition is its own transaction with its own time, so
-- this only ever bites a single-transaction script like this one. tick() ages every row the
-- claim has so far by one second, so each step is strictly later than the one before it.
-- SECURITY DEFINER (the owner) with triggers bypassed, because the history is immutable.
create function pg_temp.tick(p_claim uuid)
returns void language plpgsql security definer as $$
begin
  perform set_config('session_replication_role', 'replica', true);
  update ins_claim_events           set created_at   = created_at   - interval '1 second' where claim_id = p_claim;
  update ins_claim_approval_history set effective_at = effective_at - interval '1 second',
                                        created_at   = created_at   - interval '1 second' where claim_id = p_claim;
  update ins_claim_reserve_history  set revised_at   = revised_at   - interval '1 second' where claim_id = p_claim;
  perform set_config('session_replication_role', 'origin', true);
end $$;

create function pg_temp.activate(p_id uuid)
returns void language plpgsql as $$
begin
  perform set_config('ins.via_rpc', 'on', true);
  update ins_policies set status = 'approved' where id = p_id and status = 'draft';
  update ins_policies set
    status = 'active',
    bound_at = coalesce(bound_at, now()),
    commission_amount = coalesce(commission_amount, round(gross_premium * commission_rate_pct / 100.0, 2)),
    net_premium_to_insurer = coalesce(net_premium_to_insurer, gross_premium - round(gross_premium * commission_rate_pct / 100.0, 2))
  where id = p_id;
  perform set_config('ins.via_rpc', 'off', true);
end $$;

do $$
declare
  ta uuid := gen_random_uuid(); tb uuid := gen_random_uuid();
  manager uuid := gen_random_uuid(); member uuid := gen_random_uuid(); other_mgr uuid := gen_random_uuid();
  line uuid; insurer uuid;
  c1 ins_clients%rowtype;
  p ins_policies%rowtype;
  cl ins_claims%rowtype;
  h ins_claim_approval_history%rowtype;
  n integer;
  d_yesterday date := current_date - 1;
begin
  insert into tenants(id,name) values(ta,'Approval history A'),(tb,'Approval history B');
  insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data,aud,role,created_at,updated_at)
    select u,'apprhist-'||u||'@test.local','{}','{}','authenticated','authenticated',now(),now() from unnest(array[manager,member,other_mgr]) u;
  insert into app_users(id,tenant_id,name,email) values
    (manager,ta,'Manager','apprhist-'||manager||'@test.local'),
    (member,ta,'Member','apprhist-'||member||'@test.local'),
    (other_mgr,tb,'Other manager','apprhist-'||other_mgr||'@test.local');
  insert into tenant_modules(tenant_id,module) values(ta,'insurance'),(tb,'insurance');
  insert into staff_roles(tenant_id,user_id,module,role) values
    (ta,manager,'insurance','manager'),(ta,member,'insurance','member'),(tb,other_mgr,'insurance','manager');

  perform pg_temp.jwt(manager); set local role authenticated;
  insert into ins_product_lines(tenant_id,code,name) values(ta,'FIRE','Fire') returning id into line;
  insert into ins_insurers(tenant_id,code,name) values(ta,'ALPHA','Alpha') returning id into insurer;
  c1 := ins_register_client('Approval history client','corporate',null,null,null,'low');
  p := ins_create_policy(c1.id,insurer,line,current_date-30,current_date+335,50000000,'UGX',1000,10,null,null);
  reset role;
  perform pg_temp.activate(p.id);

  -- ---- First approval writes an initial row ----
  perform pg_temp.jwt(member); set local role authenticated;
  cl := ins_create_claim(p.id,current_date-4,current_date-3,'Warehouse flooded',null,2000000);
  perform ins_transition_claim(cl.id,'assessing',null,null);
  reset role;
  perform pg_temp.jwt(manager); set local role authenticated;
  cl := ins_transition_claim(cl.id,'approved','Approved for the higher slab',2000000);
  perform pg_temp.tick(cl.id);
  select * into h from ins_claim_approval_history where claim_id = cl.id;
  perform pg_temp.assert(h.kind='initial' and h.previous_amount is null and h.new_amount=2000000
                         and h.reason='Approved for the higher slab' and h.note='Approved for the higher slab',
                         'first approval writes an initial row with the manager''s exact note');
  perform pg_temp.assert(h.revised_by=manager,'the initial row records who made it');
  perform pg_temp.assert(h.note is not null and h.effective_at is not null,'the initial row has an actor and an effective time');
  select count(*) into n from ins_claim_approval_history where claim_id = cl.id;
  perform pg_temp.assert(n=1,'only one history row so far');

  -- ---- Register at today shows the approved amount as at ----
  perform pg_temp.assert((select approved_amount=2000000 and status_as_at='approved'
                            from ins_report_claims_register(public.ins_local_today())
                           where claim_id=cl.id),
                        'register at today shows the approved-as-at amount');
  perform pg_temp.assert((select approved_amount is null and status_as_at='notified' and outstanding_amount=2000000
                            from ins_report_claims_register(d_yesterday)
                           where claim_id=cl.id),
                        'register at yesterday shows no approved amount (the approval had not happened yet)');

  -- ---- Un-approval without a reason is refused ----
  perform pg_temp.expect_error(format('select ins_transition_claim(%L, ''assessing'', null)', cl.id),
                              'INS_NOTE_REQUIRED', 'un-approval without a reason');

  -- ---- Un-approval writes a cleared row and clears the decision ----
  cl := ins_transition_claim(cl.id,'assessing','Too high, reassessing');
  perform pg_temp.tick(cl.id);
  perform pg_temp.assert(cl.approved_amount is null and cl.payment_mode is null,
                         'un-approval clears the decision');
  select * into h from ins_claim_approval_history where claim_id = cl.id and kind = 'cleared';
  perform pg_temp.assert(h.previous_amount=2000000 and h.new_amount is null and h.reason='Too high, reassessing'
                         and h.note='Too high, reassessing',
                         'un-approval records a cleared row with the amount being cleared');
  select count(*) into n from ins_claim_approval_history where claim_id = cl.id;
  perform pg_temp.assert(n=2,'an initial and a cleared row');
  perform pg_temp.assert((select approved_amount is null and outstanding_amount=2000000
                            from ins_report_claims_register(public.ins_local_today())
                           where claim_id=cl.id),
                        'register at today after un-approval shows no approved amount and outstanding = reserve');

  -- ---- Re-approval without a reason is refused ----
  perform pg_temp.expect_error(format('select ins_transition_claim(%L, ''approved'', null, 1500000)', cl.id),
                              'INS_NOTE_REQUIRED', 're-approval without a reason');

  -- ---- Re-approval writes a revision row ----
  cl := ins_transition_claim(cl.id,'approved','Re-approved with corrected amount',1500000);
  perform pg_temp.tick(cl.id);
  select * into h from ins_claim_approval_history where claim_id = cl.id and kind = 'revision';
  perform pg_temp.assert(h.previous_amount=2000000 and h.new_amount=1500000
                         and h.reason='Re-approved with corrected amount',
                         're-approval writes a revision row carrying the prior amount and the new one');
  select count(*) into n from ins_claim_approval_history where claim_id = cl.id;
  perform pg_temp.assert(n=3,'initial, cleared and revision');
  perform pg_temp.assert((select approved_amount=1500000 and status_as_at='approved'
                            from ins_report_claims_register(public.ins_local_today())
                           where claim_id=cl.id),
                        'register at today shows the re-approved amount');
  perform pg_temp.assert((select approved_amount is null
                            from ins_report_claims_register(d_yesterday)
                           where claim_id=cl.id),
                        'register at yesterday still shows nothing approved');

  -- ---- Blank note on a first approval uses the system reason ----
  reset role;
  perform pg_temp.jwt(member); set local role authenticated;
  cl := ins_create_claim(p.id,current_date-2,current_date-1,'Second loss',null,1000000);
  perform ins_transition_claim(cl.id,'assessing',null,null);
  reset role;
  perform pg_temp.jwt(manager); set local role authenticated;
  cl := ins_transition_claim(cl.id,'approved',null,1000000);
  select * into h from ins_claim_approval_history where claim_id = cl.id;
  perform pg_temp.assert(h.reason='Approved by claims manager' and h.note is null,
                         'blank note on first approval falls back to the system reason with a null note');

  -- ---- History is immutable and RPC-only ----
  -- From the client's seat, direct writes are refused by table privileges:
  -- authenticated has only SELECT on this table, so the guard trigger never fires.
  perform set_config('ins.via_rpc', 'off', true);
  perform pg_temp.expect_error(format('insert into ins_claim_approval_history(tenant_id,claim_id,kind,previous_amount,new_amount,reason) values(%L,%L,%L,1,2,%L)',ta,cl.id,'revision','Direct insert attempt'),
                              'permission denied', 'direct history insert (client)');
  perform pg_temp.expect_error(format('update ins_claim_approval_history set reason=%L where claim_id=%L','Edited',cl.id),
                              'permission denied', 'direct history update (client)');
  perform pg_temp.expect_error(format('delete from ins_claim_approval_history where claim_id=%L',cl.id),
                              'permission denied', 'direct history delete (client)');
  -- As the table owner, the guard trigger must refuse what privileges allow:
  -- writes that do not come through ins_transition_claim(), and never an update or delete.
  reset role;
  perform set_config('ins.via_rpc', 'off', true);
  perform pg_temp.expect_error(format('insert into ins_claim_approval_history(tenant_id,claim_id,kind,previous_amount,new_amount,reason) values(%L,%L,%L,1,2,%L)',ta,cl.id,'revision','Direct insert attempt'),
                              'INS_RPC_ONLY', 'direct history insert (privileged, not via RPC)');
  perform set_config('ins.via_rpc', 'on', true);
  perform pg_temp.expect_error(format('update ins_claim_approval_history set reason=%L where claim_id=%L','Edited',cl.id),
                              'INS_APPROVAL_HISTORY_IMMUTABLE', 'direct history update (privileged)');
  perform pg_temp.expect_error(format('delete from ins_claim_approval_history where claim_id=%L',cl.id),
                              'INS_APPROVAL_HISTORY_IMMUTABLE', 'direct history delete (privileged)');
  perform set_config('ins.via_rpc', 'off', true);
  -- The event history is untouched: the status transitions are all still recorded.
  select count(*) into n from ins_claim_events where claim_id = cl.id;
  perform pg_temp.assert(n >= 3, 'the claim event trail survives with the history');

  -- ---- Isolation ----
  reset role;
  perform pg_temp.jwt(other_mgr); set local role authenticated;
  select count(*) into n from ins_claim_approval_history;
  perform pg_temp.assert(n=0,'another tenant sees no approval history');
  select count(*) into n from ins_report_claims_register(public.ins_local_today(),'all');
  perform pg_temp.assert(n=0,'another tenant sees no register rows');

  raise notice 'PASS: claim approval history and as-at reporting';
end $$;

rollback;
