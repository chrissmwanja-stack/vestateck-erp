-- Insurance notifications (20261022110000).
-- Real authenticated RPCs for policies and claims; endorsement, cancellation and
-- cash-request rows are written directly as the table owner, with ins.via_rpc on,
-- because the posting RPCs need full accounting setup. If a guard or constraint
-- rejects one of those fixture rows, adjust the row; the assertions are about the
-- notification triggers, not the posting flow. Run only on a disposable local/test
-- database; the whole script rolls back.
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
  -- An active policy is a bound policy: ins_policies_bound_check demands the
  -- commission split and a bound_at. Fill them from the policy's own rate the
  -- way the bind path would, so the flip from draft is a valid activation.
  -- via_rpc is scoped to this helper: the claim guards read it off the
  -- transaction, and a leaked 'on' would let the later direct-write probes
  -- through.
  perform set_config('ins.via_rpc', 'on', true);
  update ins_policies set
    status = 'active',
    bound_at = coalesce(bound_at, now()),
    commission_amount = coalesce(commission_amount, round(gross_premium * commission_rate_pct / 100.0, 2)),
    net_premium_to_insurer = coalesce(net_premium_to_insurer, gross_premium - round(gross_premium * commission_rate_pct / 100.0, 2))
  where id = p_id;
  perform set_config('ins.via_rpc', 'off', true);
end $$;


create function pg_temp.cnt(p_type text, p_user uuid default null)
returns integer language sql as $$
  select count(*)::integer from notifications
  where type = p_type and (p_user is null or recipient_id = p_user) $$;

do $$
declare
  ta uuid := gen_random_uuid(); tb uuid := gen_random_uuid();
  mgr uuid := gen_random_uuid(); adm uuid := gen_random_uuid(); mem uuid := gen_random_uuid(); outsider uuid := gen_random_uuid();
  f1 uuid := gen_random_uuid(); f2 uuid := gen_random_uuid(); cc uuid := gen_random_uuid();
  assignee uuid := gen_random_uuid(); bmem uuid := gen_random_uuid(); bfin uuid := gen_random_uuid();
  line uuid; insurer uuid; line_b uuid; insurer_b uuid;
  c1 ins_clients%rowtype; cb ins_clients%rowtype;
  p_end ins_policies%rowtype; p_canc ins_policies%rowtype; p_claim ins_policies%rowtype;
  p7 ins_policies%rowtype; p30 ins_policies%rowtype; p60 ins_policies%rowtype; pfar ins_policies%rowtype;
  plap ins_policies%rowtype; plapold ins_policies%rowtype; pdraft ins_policies%rowtype; pout ins_policies%rowtype;
  pcanc ins_policies%rowtype; pb ins_policies%rowtype;
  e uuid; c uuid; cr uuid; bank uuid; cl ins_claims%rowtype; n integer; r integer; body text;
begin
  insert into tenants(id,name) values(ta,'Notify A'),(tb,'Notify B');
  insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data,aud,role,created_at,updated_at)
    select u,'notify-'||u||'@test.local','{}','{}','authenticated','authenticated',now(),now()
    from unnest(array[mgr,adm,mem,outsider,f1,f2,cc,assignee,bmem,bfin]) u;
  insert into app_users(id,tenant_id,name,email)
    select u,ta,'user','notify-'||u||'@test.local' from unnest(array[mgr,adm,mem,outsider,f1,f2,cc,assignee]) u;
  insert into app_users(id,tenant_id,name,email)
    select u,tb,'user','notify-'||u||'@test.local' from unnest(array[bmem,bfin]) u;
  insert into tenant_modules(tenant_id,module) values(ta,'insurance'),(tb,'insurance');
  insert into staff_roles(tenant_id,user_id,module,role) values
    (ta,mgr,'insurance','manager'),(ta,adm,'insurance','admin'),(ta,mem,'insurance','member'),(tb,bmem,'insurance','member');
  -- f1 and f2 are Finance checkers; cc is cost control and must never be notified.
  insert into finance_team_members(tenant_id,user_id,role) values
    (ta,f1,'finance'),(ta,f2,'finance'),(ta,cc,'cost_control'),(tb,bfin,'finance');

  perform pg_temp.jwt(mgr); set local role authenticated;
  insert into ins_product_lines(tenant_id,code,name) values(ta,'FIRE','Fire') returning id into line;
  insert into ins_insurers(tenant_id,code,name) values(ta,'ALPHA','Alpha') returning id into insurer;
  c1 := ins_register_client('Notify client','corporate',null,null,null,'low');
  p_end   := ins_create_policy(c1.id,insurer,line,current_date-30,current_date+335,50000000,'UGX',1000,10,null,null);
  p_canc  := ins_create_policy(c1.id,insurer,line,current_date-30,current_date+335,50000000,'UGX',1000,10,null,null);
  p_claim := ins_create_policy(c1.id,insurer,line,current_date-30,current_date+335,50000000,'UGX',1000,10,null,null);
  reset role;
  perform pg_temp.activate(p_end.id); perform pg_temp.activate(p_canc.id); perform pg_temp.activate(p_claim.id);

  -- ============ endorsements (direct rows; see the note at the top about guards) ============
  perform pg_temp.jwt(mem);
  perform set_config('ins.via_rpc','on',true);
  insert into ins_policy_endorsements(tenant_id,policy_id,request_key,reason,effective_date,insurer_terms,changes,proposed_by,calculation)
    values(ta,p_end.id,gen_random_uuid(),'Increase the sum insured',current_date,'[]','{}',mem,'{}') returning id into e;
  perform pg_temp.assert(pg_temp.cnt('ins_endorsement_proposed') = 2, 'a proposal reaches the two Finance checkers only');
  perform pg_temp.assert(pg_temp.cnt('ins_endorsement_proposed', cc) = 0, 'cost control is not notified');
  perform pg_temp.assert(pg_temp.cnt('ins_endorsement_proposed', bfin) = 0, 'another tenant is not notified');
  perform pg_temp.assert(pg_temp.cnt('ins_endorsement_proposed', mem) = 0, 'the proposer is not notified');
  perform pg_temp.assert((select link_path from notifications where type = 'ins_endorsement_proposed' limit 1) = '/insurance/policies/' || p_end.id, 'the notice links to the policy page');

  perform pg_temp.jwt(f1);
  update ins_policy_endorsements set status = 'prepared', prepared_by = f1, prepared_at = now() where id = e;
  perform pg_temp.assert(pg_temp.cnt('ins_endorsement_prepared') = 1 and pg_temp.cnt('ins_endorsement_prepared', f2) = 1, 'preparation reaches only the independent checker');

  perform pg_temp.jwt(f2);
  update ins_policy_endorsements set status = 'rejected', checked_by = f2, checked_at = now(), review_note = 'Schedule does not match the request' where id = e;
  perform pg_temp.assert(pg_temp.cnt('ins_endorsement_rejected') = 2 and pg_temp.cnt('ins_endorsement_rejected', mem) = 1 and pg_temp.cnt('ins_endorsement_rejected', f1) = 1, 'rejection reaches the proposer and the preparer');
  perform pg_temp.assert((select body from notifications where type = 'ins_endorsement_rejected' limit 1) like '%Schedule does not match%', 'rejection carries the reviewer note');

  -- ============ cancellations and their cash requests ============
  perform pg_temp.jwt(mem);
  insert into ins_policy_cancellations(tenant_id,policy_id,request_key,reason,effective_date,insurer_terms,charge_refunds,proposed_by,calculation)
    values(ta,p_canc.id,gen_random_uuid(),'Client changed insurer',current_date,'[]','[]',mem,'{}') returning id into c;
  perform pg_temp.assert(pg_temp.cnt('ins_cancellation_proposed') = 2, 'a cancellation proposal reaches the Finance checkers');

  insert into fin_bank_accounts(tenant_id,name,kind,currency) values(ta,'Notify operating','operating','UGX') returning id into bank;
  perform pg_temp.jwt(f1);
  insert into ins_cancellation_cash_requests(tenant_id,cancellation_id,kind,bank_account_id,amount,cash_date,reference,notes,request_key,maker_id)
    values(ta,c,'premium_receipt',bank,1500000,current_date,'REF-001','Client refund received',gen_random_uuid(),f1) returning id into cr;
  perform pg_temp.assert(pg_temp.cnt('ins_cancellation_cash_pending') = 1 and pg_temp.cnt('ins_cancellation_cash_pending', f2) = 1, 'a cash request reaches the other Finance checker, not its maker');
  perform pg_temp.assert((select body from notifications where type = 'ins_cancellation_cash_pending') like '%1,500,000.00%', 'the cash notice states the amount');
  perform pg_temp.jwt(f2);
  update ins_cancellation_cash_requests set status = 'rejected', checker_id = f2, checked_at = now(), decision_reason = 'Reference does not match' where id = cr;
  perform pg_temp.assert(pg_temp.cnt('ins_cancellation_cash_rejected', f1) = 1, 'the maker is told when the request is rejected');

  -- ============ claims ============
  perform pg_temp.jwt(mem); set local role authenticated;
  cl := ins_create_claim(p_claim.id,current_date-5,current_date-4,'Warehouse flooded',null,2000000);
  reset role;
  perform pg_temp.assert(pg_temp.cnt('ins_claim_registered') = 2 and pg_temp.cnt('ins_claim_registered', mgr) = 1 and pg_temp.cnt('ins_claim_registered', adm) = 1, 'a new claim reaches the insurance admin and manager');
  perform pg_temp.assert(pg_temp.cnt('ins_claim_registered', mem) = 0, 'the registrar is not notified of their own claim');

  perform pg_temp.jwt(mgr);
  perform set_config('ins.via_rpc','on',true);
  update ins_claims set assigned_to = assignee where id = cl.id;
  perform pg_temp.assert(pg_temp.cnt('ins_claim_assigned', assignee) = 1, 'the assignee is told');
  update ins_claims set status = 'assessing' where id = cl.id;
  perform pg_temp.assert(pg_temp.cnt('ins_claim_assessing') = 0, 'assessing is not announced');
  update ins_claims set status = 'approved', approved_amount = 1500000 where id = cl.id;
  perform pg_temp.assert(pg_temp.cnt('ins_claim_approved') = 2 and pg_temp.cnt('ins_claim_approved', assignee) = 1 and pg_temp.cnt('ins_claim_approved', mem) = 1, 'approval reaches the assignee and the registrar');
  update ins_claims set assigned_to = mgr where id = cl.id;
  perform pg_temp.assert(pg_temp.cnt('ins_claim_assigned', mgr) = 0, 'assigning a claim to yourself does not notify you');
  perform set_config('ins.via_rpc','off',true);

  -- ============ the writer never raises ============
  perform ins_notify(ta, array[mgr], '{}', 'probe', null, 'body', null);
  perform pg_temp.assert(pg_temp.cnt('probe') = 0, 'a failing notification insert is swallowed, not raised');
  perform pg_temp.expect_state(format('insert into notifications(tenant_id,recipient_id,type,title,body,link_path) values(%L,%L,%L,%L,%L,%L)',ta,mgr,'t','t','b','//evil.example'),'23514','protocol-relative link');
  perform pg_temp.expect_state(format('insert into notifications(tenant_id,recipient_id,type,title,body,link_path) values(%L,%L,%L,%L,%L,%L)',ta,mgr,'t','t','b','https://evil.example'),'23514','absolute link');

  -- ============ renewal sweep ============
  perform pg_temp.jwt(mgr); set local role authenticated;
  p7      := ins_create_policy(c1.id,insurer,line,current_date-360,current_date+5,1000000,'UGX',1000,10,null,null);
  p30     := ins_create_policy(c1.id,insurer,line,current_date-340,current_date+25,1000000,'UGX',1000,10,null,null);
  p60     := ins_create_policy(c1.id,insurer,line,current_date-310,current_date+55,1000000,'UGX',1000,10,null,null);
  pfar    := ins_create_policy(c1.id,insurer,line,current_date-270,current_date+95,1000000,'UGX',1000,10,null,null);
  plap    := ins_create_policy(c1.id,insurer,line,current_date-375,current_date-10,1000000,'UGX',1000,10,null,null);
  plapold := ins_create_policy(c1.id,insurer,line,current_date-410,current_date-45,1000000,'UGX',1000,10,null,null);
  pdraft  := ins_create_policy(c1.id,insurer,line,current_date-345,current_date+20,1000000,'UGX',1000,10,null,null);
  pout    := ins_create_policy(c1.id,insurer,line,current_date-350,current_date+15,1000000,'UGX',1000,10,null,null);
  pcanc   := ins_create_policy(c1.id,insurer,line,current_date-353,current_date+12,1000000,'UGX',1000,10,null,null);
  reset role;
  perform pg_temp.activate(p7.id); perform pg_temp.activate(p30.id); perform pg_temp.activate(p60.id);
  perform pg_temp.activate(pfar.id); perform pg_temp.activate(plap.id); perform pg_temp.activate(plapold.id);
  perform pg_temp.activate(pdraft.id); perform pg_temp.activate(pout.id); perform pg_temp.activate(pcanc.id);

  perform pg_temp.jwt(mem); set local role authenticated;
  perform ins_create_renewal_draft(pdraft.id);
  perform ins_record_renewal_outcome(pout.id,'lost','Went to another broker');
  reset role;
  perform pg_temp.jwt(mem);
  perform set_config('ins.via_rpc','on',true);
  insert into ins_policy_cancellations(tenant_id,policy_id,request_key,reason,effective_date,insurer_terms,charge_refunds,proposed_by,calculation)
    values(ta,pcanc.id,gen_random_uuid(),'Client changed insurer',current_date,'[]','[]',mem,'{}');
  perform set_config('ins.via_rpc','off',true);
  delete from notifications;  -- start the sweep checks from a clean bell

  perform pg_temp.jwt(outsider); set local role authenticated;
  perform pg_temp.assert(ins_renewal_notification_sweep() = 0, 'a user with no insurance role gets nothing');
  reset role;
  perform pg_temp.assert((select count(*) from ins_notification_marks) = 0, 'and leaves no markers');

  perform pg_temp.jwt(mem); set local role authenticated;
  r := ins_renewal_notification_sweep();
  reset role;
  -- The three earlier fixture policies expire in 335 days, outside the 60-day window.
  perform pg_temp.assert(r = 4, 'the sweep announces 4 policies (7, 30, 60 days and one lapsed); got ' || r);
  perform pg_temp.assert(pg_temp.cnt('ins_renewal_due', mgr) = 3 and pg_temp.cnt('ins_renewal_due', adm) = 3, 'managers and admins get one digest per window');
  perform pg_temp.assert(pg_temp.cnt('ins_policy_lapsed', mgr) = 1, 'and one lapsed digest');
  perform pg_temp.assert(pg_temp.cnt('ins_renewal_due', mem) = 0 and pg_temp.cnt('ins_policy_lapsed', mem) = 0, 'members get none');
  select string_agg(b.body, ' | ') into body from notifications b where b.recipient_id = mgr;
  perform pg_temp.assert(body like '%' || plap.policy_no || '%', 'the lapsed digest names the policy');
  perform pg_temp.assert(body not like '%' || plapold.policy_no || '%', 'a policy lapsed 45 days ago is not announced');
  perform pg_temp.assert(body not like '%' || pfar.policy_no || '%', 'a policy 95 days out is not announced');
  perform pg_temp.assert(body not like '%' || pdraft.policy_no || '%', 'a policy with a renewal draft is not announced');
  perform pg_temp.assert(body not like '%' || pout.policy_no || '%', 'a policy with a renewal outcome is not announced');
  perform pg_temp.assert(body not like '%' || pcanc.policy_no || '%', 'a policy being cancelled is not announced');
  perform pg_temp.assert(pg_temp.cnt('ins_renewal_due', bmem) = 0, 'another tenant is untouched');

  select count(*) into n from notifications;
  perform pg_temp.jwt(mem); set local role authenticated;
  r := ins_renewal_notification_sweep();
  reset role;
  perform pg_temp.assert(r = 0 and (select count(*) from notifications) = n, 'a second sweep is silent');

  -- a policy first seen inside the 7-day window is not told again at 30
  perform pg_temp.jwt(mem);
  perform set_config('ins.via_rpc','on',true);
  update ins_policies set expiry_date = current_date + 25 where id = p7.id;
  perform set_config('ins.via_rpc','off',true);
  perform pg_temp.jwt(mem); set local role authenticated;
  r := ins_renewal_notification_sweep();
  reset role;
  perform pg_temp.assert(r = 0, 'a policy already announced at 7 days is not announced again at 30');

  -- a tenant with nobody to tell leaves the markers alone
  perform pg_temp.jwt(bmem); set local role authenticated;
  insert into ins_product_lines(tenant_id,code,name) values(tb,'FIRE','Fire') returning id into line_b;
  insert into ins_insurers(tenant_id,code,name) values(tb,'BETA','Beta') returning id into insurer_b;
  cb := ins_register_client('Lonely client','corporate',null,null,null,'low');
  pb := ins_create_policy(cb.id,insurer_b,line_b,current_date-360,current_date+5,1000000,'UGX',1000,10,null,null);
  reset role;
  perform pg_temp.activate(pb.id);
  perform pg_temp.jwt(bmem); set local role authenticated;
  r := ins_renewal_notification_sweep();
  reset role;
  perform pg_temp.assert(r = 0 and (select count(*) from ins_notification_marks where tenant_id = tb) = 0, 'with no insurance admin or manager nothing is marked as sent');

  raise notice 'ALL INSURANCE NOTIFICATION TESTS PASSED';
end $$;

rollback;
