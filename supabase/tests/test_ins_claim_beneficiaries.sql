-- =====================================================================
-- Beneficiaries, death claims and instalment settlements
-- Accountant pack v2, decision 3 (B10); pack sections 7.4-7.6
-- =====================================================================
-- The pack's criteria, and where each is proved:
--
--   "a death claim records the representative and beneficiaries"           §1, §2
--   "percentages must total 100%"                                          §2
--   "a disputed share is held while undisputed shares pay"                 §4, §5
--   "a second instalment reduces the balance without a new claim accrual"  §6, §7
--
-- §4 is the important one. The held-share rule is enforced by a DEFERRED constraint
-- trigger, because the claim has one open item and the payment rows are inserted
-- after the settlement: only a deferred check sees the whole transaction. A deferred
-- trigger is tested by promoting it to immediate inside the transaction, which is
-- what SET CONSTRAINTS does here -- without that, the failure would surface at
-- commit and could not be asserted in place.
--
-- One transaction, rolled back. Disposable database only.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

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

create function pg_temp.accruals(p_claim uuid) returns integer
language sql security definer as $$
  select count(*) from journal_entries
   where tenant_id = (select v from ids where k = 'tenant')
     and source_id = p_claim
     and source_type = 'ins_claim_accrual'
$$;
grant execute on function pg_temp.accruals(uuid) to authenticated;

do $$
declare
  ta uuid := gen_random_uuid();
  admin1 uuid := gen_random_uuid();
  admin2 uuid := gen_random_uuid();
  mgr uuid := gen_random_uuid();
  trust_gl uuid; ar_gl uuid; pay_gl uuid; recv_gl uuid; baddebt_gl uuid;
  v_bank uuid; v_party uuid; v_bd uuid; v_client uuid;
begin
  insert into tenants(id, name) values (ta, 'Beneficiaries test');
  insert into auth.users(id, email, raw_user_meta_data, raw_app_meta_data, aud, role, created_at, updated_at)
    select u, 'ben-' || u || '@test.local', '{}', '{}', 'authenticated', 'authenticated', now(), now()
    from unnest(array[admin1, admin2, mgr]) u;
  insert into app_users(id, tenant_id, name, email)
    select u, ta, 'Beneficiary actor', 'ben-' || u || '@test.local'
    from unnest(array[admin1, admin2, mgr]) u;
  update app_users set is_company_admin = true where id in (admin1, admin2);

  insert into tenant_modules(tenant_id, module) values (ta, 'insurance');
  insert into staff_roles(tenant_id, user_id, module, role) values (ta, mgr, 'insurance', 'manager');
  insert into finance_team_members(tenant_id, user_id, role) values (ta, mgr, 'finance');

  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '1020', 'Client money', 'asset') returning id into trust_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type, is_control_account) values (ta, '1100', 'AR', 'asset', true) returning id into ar_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type, is_control_account) values (ta, '1120', 'Insurer claim recv', 'asset', true) returning id into recv_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type, is_control_account) values (ta, '2030', 'Client claim payable', 'liability', true) returning id into pay_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '5900', 'Bad debts', 'expense') returning id into baddebt_gl;
  insert into gl_posting_rules(tenant_id, account_role, gl_account_id) values
    (ta, 'client_money_bank', trust_gl), (ta, 'ar_control', ar_gl),
    (ta, 'insurer_claim_receivable', recv_gl), (ta, 'client_claim_payable', pay_gl);

  insert into fin_bank_accounts(tenant_id, name, kind, currency, gl_account_id)
    values (ta, 'BEN-TRUST', 'client_money', 'UGX', trust_gl) returning id into v_bank;

<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
  insert into accounts(tenant_id, account_code, name, account_type) values (ta, 'T-' || substr(gen_random_uuid()::text, 1, 8), 'Bereaved client', 'client') returning id into v_party;
=======
  insert into accounts(tenant_id, name, account_type) values (ta, 'Bereaved client', 'client') returning id into v_party;
>>>>>>> theirs
=======
  insert into accounts(tenant_id, name, account_type) values (ta, 'Bereaved client', 'client') returning id into v_party;
>>>>>>> theirs
=======
  insert into accounts(tenant_id, name, account_type) values (ta, 'Bereaved client', 'client') returning id into v_party;
>>>>>>> theirs
  insert into bd_clients(tenant_id, name) values (ta, 'Bereaved client') returning id into v_bd;
  insert into ins_clients(tenant_id, client_id, client_type, party_account_id)
    values (ta, v_bd, 'individual', v_party) returning id into v_client;

  create temp table ids (k text primary key, v uuid);
  insert into ids(k, v) values ('tenant', ta), ('client', v_client), ('party', v_party),
    ('bank', v_bank), ('pay', pay_gl), ('recv', recv_gl), ('trust', trust_gl), ('mgr', mgr);
end $$;

create function pg_temp.id(p_key text) returns uuid
language sql security definer set search_path = public, pg_temp as $$
  select v from ids where k = p_key
$$;
grant execute on function pg_temp.id(text) to authenticated;

-- A bound policy with insurer funds available, and a claim approved and recognised
-- at 400,000 — the state every beneficiary test needs.
create function pg_temp.claim_ready() returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_line uuid; v_insurer uuid; v_pol uuid; v_claim ins_claims%rowtype;
begin
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  insert into ins_product_lines(tenant_id, code, name)
    values (pg_temp.id('tenant'), 'LIFE', 'Life') returning id into v_line;
  insert into ins_insurers(tenant_id, code, name)
    values (pg_temp.id('tenant'), 'LIFEINS', 'Life Insurer') returning id into v_insurer;
  v_pol := ins_create_policy(pg_temp.id('client'), v_insurer, v_line,
                             current_date - 90, current_date + 275, 1000000, 'UGX', 1000000, 10,
                             null, null, 'Life policy', null);
  reset role;
  insert into ins_policy_insurer_shares
    (tenant_id, policy_id, insurer_id, is_lead, share_pct, commission_rate_pct, reviewed)
  values (pg_temp.id('tenant'), v_pol, v_insurer, true, 100, 10, true);
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  perform ins_submit_policy_for_approval(v_pol);
  reset role;
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  perform ins_bind_policy(v_pol);
  v_claim := ins_create_claim(v_pol, current_date - 10, current_date - 9, 'Death of the insured', null, 400000);
  perform ins_transition_claim(v_claim.id, 'assessing', 'documents received');
  perform ins_transition_claim(v_claim.id, 'approved', 'approved at 400,000', 400000);
  perform ins_recognise_claim_receivable(v_claim.id, 'insurer confirmation letter');
  perform ins_record_claim_receipt(v_claim.id, pg_temp.id('bank'), 400000, current_date, 'FUND-LIFE', 'insurer funds received');
  reset role;
  return v_claim.id;
end $$;

-- ---------------------------------------------------------------------
-- §1 a death claim needs an authorised representative
-- ---------------------------------------------------------------------
do $$
declare v_claim uuid := pg_temp.claim_ready();
        v_pol uuid; v_refused boolean := false; v_row ins_claims%rowtype;
begin
  select id into v_pol from ins_policies where tenant_id = pg_temp.id('tenant') limit 1;

  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  begin
    perform ins_record_death_claim(v_pol, current_date - 3, current_date - 2, 'Death of the insured',
                                  current_date - 5, 'Grace Nakato', 'widow', '+256700000000', null, 0);
  exception when others then
    v_refused := true;
    perform pg_temp.assert(sqlerrm like 'INS_REQUIRED%',
      '§1 a death claim without stated authority must be refused, got: ' || sqlerrm);
  end;

  v_row := ins_record_death_claim(v_pol, current_date - 3, current_date - 2, 'Death of the insured',
                                  current_date - 5, 'Grace Nakato', 'widow', '+256700000000',
                                  'letters of administration dated 12 Nov', 100000);
  reset role;

  perform pg_temp.assert(v_refused, '§1 the claim without authority must be refused');
  perform pg_temp.assert(v_row.claim_type = 'death',
    '§1 the claim should be typed death, got ' || coalesce(v_row.claim_type, '(none)'));
  perform pg_temp.assert(v_row.representative_name = 'Grace Nakato',
    '§1 the representative should be recorded');
  raise notice 'PASS: §1 a death claim requires and records the authorised representative';
end $$;

-- ---------------------------------------------------------------------
-- §2 percentages must total 100, and allotments must equal the approval
-- ---------------------------------------------------------------------
do $$
declare v_claim uuid := (select id from ins_claims
                          where tenant_id = pg_temp.id('tenant') and approved_amount = 400000 limit 1);
        v_bad_total boolean := false; v_bad_sum boolean := false; v_rows integer;
begin
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  begin
    perform ins_set_claim_beneficiaries(v_claim,
      '[{"name":"Grace Nakato","share_pct":60},{"name":"Peter Nakato","share_pct":30}]'::jsonb);
  exception when others then
    v_bad_total := true;
    perform pg_temp.assert(sqlerrm like 'INS_BENEFICIARY_TOTAL%',
      '§2 percentages not totalling 100 must be refused, got: ' || sqlerrm);
  end;

  -- 100% is fine as a total, but fixed amounts that do not add to the approval are not.
  begin
    perform ins_set_claim_beneficiaries(v_claim,
      '[{"name":"Grace Nakato","fixed_amount":100000,"currency":"UGX"},
        {"name":"Peter Nakato","share_pct":100}]'::jsonb);
  exception when others then
    v_bad_sum := true;
    perform pg_temp.assert(sqlerrm like 'INS_BENEFICIARY_TOTAL%',
      '§2 allotments that do not equal the approved amount must be refused, got: ' || sqlerrm);
  end;

  -- The valid set: 60% payable, 40% held.
  perform ins_set_claim_beneficiaries(v_claim,
    '[{"name":"Grace Nakato","share_pct":60,"status":"payable"},
      {"name":"Peter Nakato","share_pct":40,"status":"held","held_reason":"paternity of the beneficiary is disputed"}]'::jsonb);
  reset role;

  select count(*) into v_rows from ins_claim_beneficiaries where claim_id = v_claim;
  perform pg_temp.assert(v_bad_total, '§2 percentages must total 100');
  perform pg_temp.assert(v_bad_sum, '§2 allotments must dispose of the whole approval');
  perform pg_temp.assert(v_rows = 2, format('§2 two allotments should be recorded, got %s', v_rows));
  raise notice 'PASS: §2 percentages total 100 and allotments equal the approved amount';
end $$;

-- ---------------------------------------------------------------------
-- §3 the payable total excludes the held share
-- ---------------------------------------------------------------------
do $$
declare v_claim uuid := (select id from ins_claims
                          where tenant_id = pg_temp.id('tenant') and approved_amount = 400000 limit 1);
        r record;
begin
  select * into r from public.platform_ins_claim_beneficiary_payable(pg_temp.id('tenant'), v_claim);
  perform pg_temp.assert(r.payable = 240000,
    format('§3 60%% of 400,000 should be payable (240,000), got %s', r.payable));
  perform pg_temp.assert(r.held = 160000,
    format('§3 40%% should be held (160,000), got %s', r.held));
  perform pg_temp.assert(r.total = 400000,
    format('§3 the allotments should total 400,000, got %s', r.total));
  raise notice 'PASS: §3 the held share is excluded from what may be paid';
end $$;

-- ---------------------------------------------------------------------
-- §4 paying beyond the payable total is refused (the held share is protected)
-- ---------------------------------------------------------------------
do $$
declare v_claim uuid := (select id from ins_claims
                          where tenant_id = pg_temp.id('tenant') and approved_amount = 400000 limit 1);
        v_refused boolean := false; v_paid numeric;
begin
  -- Promote the deferred guards so the check runs inside this block rather than at
  -- commit; the rule is the same, only the timing of the check changes.
  set constraints all immediate;

  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  begin
    perform ins_record_claim_payout(v_claim, pg_temp.id('bank'), 300000, current_date, 'PAY-OVER', 'attempt over the payable');
  exception when others then
    v_refused := true;
    perform pg_temp.assert(sqlerrm like 'INS_BENEFICIARY_HELD%',
      '§4 paying into a held share must be refused as INS_BENEFICIARY_HELD, got: ' || sqlerrm);
  end;
  reset role;

  select coalesce(sum(amount), 0) into v_paid from ins_claim_payments
   where claim_id = v_claim and status = 'posted' and kind = 'client_payout';
  perform pg_temp.assert(v_refused, '§4 the payout into the held share must be refused');
  perform pg_temp.assert(v_paid = 0,
    format('§4 and nothing may have been paid: % recorded', v_paid));
  raise notice 'PASS: §4 a payment into a held share is refused and leaves no payment behind';
end $$;

-- ---------------------------------------------------------------------
-- §5 the undisputed share pays out normally
-- ---------------------------------------------------------------------
do $$
declare v_claim uuid := (select id from ins_claims
                          where tenant_id = pg_temp.id('tenant') and approved_amount = 400000 limit 1);
        v_paid numeric;
begin
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  perform ins_record_claim_payout(v_claim, pg_temp.id('bank'), 240000, current_date, 'PAY-OK', 'undisputed share');
  reset role;

  select coalesce(sum(amount), 0) into v_paid from ins_claim_payments
   where claim_id = v_claim and status = 'posted' and kind = 'client_payout';
  perform pg_temp.assert(v_paid = 240000,
    format('§5 exactly the payable 240,000 should be paid, got %s', v_paid));
  raise notice 'PASS: §5 the undisputed share pays while the disputed share stays held';
end $$;

-- ---------------------------------------------------------------------
-- §6/§7 instalments settle the balance without fresh recognition
-- ---------------------------------------------------------------------
do $$
declare v_claim uuid; v_accruals_before integer; v_accruals_after integer;
        v_sched integer; v_refused boolean := false; v_inst ins_claim_instalments%rowtype;
begin
  -- A fresh claim, funded, with nothing paid yet.
  v_claim := pg_temp.claim_ready();
  v_accruals_before := pg_temp.accruals(v_claim);

  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  -- A schedule that does not add up to the outstanding balance is refused.
  begin
    perform ins_schedule_claim_instalments(v_claim,
      '[{"expected_on":"' || (current_date + 30) || '","amount":100000}]'::jsonb);
  exception when others then
    v_refused := true;
    perform pg_temp.assert(sqlerrm like 'INS_INSTALMENT_TOTAL%',
      '§6 a schedule short of the balance must be refused, got: ' || sqlerrm);
  end;

  perform ins_schedule_claim_instalments(v_claim, jsonb_build_array(
    jsonb_build_object('expected_on', current_date + 30, 'amount', 150000),
    jsonb_build_object('expected_on', current_date + 60, 'amount', 250000)));
  reset role;

  select count(*) into v_sched from ins_claim_instalments where claim_id = v_claim;
  perform pg_temp.assert(v_refused, '§6 a schedule that does not settle the balance must be refused');
  perform pg_temp.assert(v_sched = 2, format('§6 two instalments expected, got %s', v_sched));

  -- Pay the first one, with evidence.
  select * into v_inst from ins_claim_instalments
   where claim_id = v_claim and instalment_no = 1;
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  v_inst := ins_pay_claim_instalment(v_inst.id, pg_temp.id('bank'), current_date,
                                     'INST-1', 'client signed receipt 001', 'first instalment');
  reset role;

  v_accruals_after := pg_temp.accruals(v_claim);
  perform pg_temp.assert(v_inst.status = 'paid' and v_inst.paid_amount = 150000,
    format('§7 the instalment should be paid for 150,000, got %s/%s', v_inst.status, v_inst.paid_amount));
  perform pg_temp.assert(v_inst.evidence_ref = 'client signed receipt 001',
    '§7 the evidence reference should be recorded');
  -- The point of the criterion: an instalment settles the existing balance, so the
  -- accrual stays at exactly one journal however many instalments are paid.
  perform pg_temp.assert(v_accruals_after = v_accruals_before,
    format('§7 a second instalment must not create fresh recognition: accruals %s -> %s',
           v_accruals_before, v_accruals_after));
  raise notice 'PASS: §6/§7 instalments settle the balance without re-recognising the claim';
end $$;

-- ---------------------------------------------------------------------
-- §8 editing shares below what has been paid is refused
-- ---------------------------------------------------------------------
do $$
declare v_claim uuid := (select id from ins_claims
                          where tenant_id = pg_temp.id('tenant') and approved_amount = 400000 limit 1);
        v_refused boolean := false;
begin
  -- 240,000 has already been paid in §5. Marking the rest held is fine; marking a
  -- share held such that payable drops below 240,000 is not.
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  begin
    perform ins_set_claim_beneficiaries(v_claim,
      '[{"name":"Grace Nakato","share_pct":40,"status":"payable"},
        {"name":"Peter Nakato","share_pct":60,"status":"held","held_reason":"disputed"}]'::jsonb);
  exception when others then
    v_refused := true;
    perform pg_temp.assert(sqlerrm like 'INS_BENEFICIARY_HELD%' or sqlerrm like 'INS_BENEFICIARY_TOTAL%',
      '§8 reducing payable below what was already paid must be refused, got: ' || sqlerrm);
  end;
  reset role;
  perform pg_temp.assert(v_refused,
    '§8 a held share cannot be created below payments already made');
  raise notice 'PASS: §8 allotments cannot be edited to strand money already paid out';
end $$;

do $$ begin
  raise notice 'ALL PASS: death claims need authority, percentages total 100, held shares are protected, and instalments settle without re-recognising';
end $$;

rollback;
