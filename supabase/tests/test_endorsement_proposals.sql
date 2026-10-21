-- Endorsements, slice E1: proposals (no posting).
-- (ins_preview_policy_endorsement, ins_propose_policy_endorsement,
-- ins_withdraw_policy_endorsement, ins_endorsement_review_position,
-- the cross-pipeline guards and the renewal block.)
--
-- Covers: the pro-rata and agreed-delta calculations (commission at the
-- bound rate, remaining-days basis, per-currency policy currency), the
-- idempotent propose with payload-conflict refusal, one live endorsement
-- per policy, the endorsement/cancellation cross-guards in both
-- directions, the renewal block, the validation battery (future date,
-- unknown insurer, duplicate insurer, unknown or invalid change fields,
-- a nothing-changes endorsement), withdraw rules (proposer, open case,
-- reason), the review position (bound vs current), and the access and
-- tenant gates.
--
-- Run against a fresh local stack only (`supabase db reset`). One transaction
-- that ROLLBACKs. Any RAISE EXCEPTION is a real assertion failure.

\set ON_ERROR_STOP on

begin;

-- Test fixture: a motor policy needs an issued certificate before it binds.
create function pg_temp.motor_cert(p_policy uuid) returns void
language plpgsql as $$
declare pol ins_policies%rowtype; line_code text; r uuid; s text := replace(p_policy::text, '-', '');
begin
  if not can_manage_insurance() then return; end if;
  select * into pol from ins_policies where id = p_policy;
  if not found or pol.status <> 'draft' then return; end if;
  select code into line_code from ins_product_lines where id = pol.product_line_id;
  if line_code is distinct from 'MOTOR' then return; end if;
  if exists (select 1 from ins_certificate_stock where policy_id = p_policy and status = 'issued') then return; end if;
  r := ins_register_risk(pol.client_id, pol.product_line_id, 'vehicle', 'Test vehicle', null, 'CH' || s, null, null, null, null, 0);
  perform ins_load_certificate_range('C' || s || '-', 1, 1, 4);
  perform ins_issue_certificate('C' || s || '-0001', r, null);
  perform ins_link_policy_risk(p_policy, r);
  perform ins_attach_certificate(p_policy, 'C' || s || '-0001');
end $$;

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
  ta   uuid := gen_random_uuid();
  tb   uuid := gen_random_uuid();
  mgr  uuid := gen_random_uuid();
  mem  uuid := gen_random_uuid();
  out_ uuid := gen_random_uuid();
  mgr2 uuid := gen_random_uuid();
  ub   uuid := gen_random_uuid();
  v_branch uuid; v_line uuid; v_alpha uuid;
  pa ins_policies%rowtype; pb ins_policies%rowtype;
  e1 ins_policy_endorsements%rowtype; e2 ins_policy_endorsements%rowtype;
  cxl ins_policy_cancellations%rowtype;
  q jsonb; n integer; st text;
begin
  perform set_config('test.approver', mgr::text, true);

  -------------------------------------------------------------------
  -- Fixtures: two insurance tenants. Tenant A gets three bound UGX
  -- policies (inception D-45, expiry D+320: a 365-day term with 320
  -- days remaining at today's effective date).
  -------------------------------------------------------------------
  insert into tenants (id, name) values (ta, 'Endorse Co'), (tb, 'Endorse Other');
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token)
  select '00000000-0000-0000-0000-000000000000', x.id, 'authenticated', 'authenticated',
         'end-' || x.id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')), now(),
         '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
    from (values (mgr), (mgr2), (mem), (out_), (ub)) as x(id);
  insert into app_users (id, tenant_id, name, email) values
    (mgr, ta, 'END Manager',  'end-' || mgr || '@test.local'),
    (mem, ta, 'END Member',   'end-' || mem || '@test.local'),
    (mgr2, ta, 'END Manager II','end-' || mgr2 || '@test.local'),
    (out_, ta, 'END Outsider','end-' || out_ || '@test.local'),
    (ub,  tb, 'END Other',    'end-' || ub  || '@test.local');
  insert into tenant_modules (tenant_id, module) values (ta, 'insurance'), (tb, 'insurance');
  insert into staff_roles (tenant_id, user_id, module, role) values
    (ta, mgr, 'insurance', 'manager'),
    (ta, mgr2, 'insurance', 'manager'),
    (ta, mem, 'insurance', 'member'),
    (tb, ub,  'insurance', 'manager');

  -- Bind needs the posting rules (the journal legs of the premium).
  declare
    g_ar uuid; g_pay uuid; g_unearned uuid; g_income uuid;
  begin
    insert into gl_accounts (tenant_id, account_code, name, account_type) values
      (ta,'1100','AR','asset'), (ta,'2010','Insurer payable','liability'),
      (ta,'2020','Unearned commission','liability'), (ta,'4000','Commission income','revenue');
    select id into g_ar from gl_accounts where tenant_id = ta and account_code = '1100';
    select id into g_pay from gl_accounts where tenant_id = ta and account_code = '2010';
    select id into g_unearned from gl_accounts where tenant_id = ta and account_code = '2020';
    select id into g_income from gl_accounts where tenant_id = ta and account_code = '4000';
    insert into gl_posting_rules (tenant_id, account_role, gl_account_id) values
      (ta,'ar_control',g_ar),(ta,'insurer_payable',g_pay),
      (ta,'unearned_commission',g_unearned),(ta,'commission_income',g_income);
  end;

  perform pg_temp.jwt(mgr);
  insert into organizations (tenant_id, company_code, site_name) values (ta, 'KLA', 'Kampala') returning id into v_branch;
  reset role;
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  insert into ins_product_lines (tenant_id, code, name) values (ta, 'MOTOR', 'Motor') returning id into v_line;
  insert into ins_insurers (tenant_id, code, name, default_commission_rate_pct) values (ta, 'ALPHA', 'Alpha Assurance', 10) returning id into v_alpha;
  reset role;

  perform pg_temp.jwt(mgr);
  set local role authenticated;
  declare cc ins_clients%rowtype;
  begin
    cc := ins_register_client('END client', 'corporate', null, null, null, 'low');
    pa := ins_create_policy(cc.id, v_alpha, v_line, current_date - 45, current_date + 320,
                            50000000, 'UGX', 1000000, 10, v_branch, null, 'END fleet', null);
    perform pg_temp.motor_cert(pa.id); pa := ins_bind_policy(pa.id);
    pb := ins_create_policy(cc.id, v_alpha, v_line, current_date - 45, current_date + 320,
                            20000000, 'UGX', 400000, 10, v_branch, null, 'END second', null);
    perform pg_temp.motor_cert(pb.id); pb := ins_bind_policy(pb.id);
  end;
  reset role;
  perform pg_temp.assert(pa.status = 'active' and pb.status = 'active', 'both policies bind');

  -------------------------------------------------------------------
  -- 1. The pro-rata calculation: remaining-days basis, commission at
  --    the policy's bound 10%.
  -------------------------------------------------------------------
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  q := ins_preview_policy_endorsement(pa.id, current_date,
    jsonb_build_array(jsonb_build_object('insurer_id', v_alpha::text, 'method', 'pro_rata', 'annual_delta', '100000')),
    '{}'::jsonb);
  perform pg_temp.assert((q ->> 'premium_delta')::numeric = 87671.23,
    format('pro-rata delta is 100000 x 320/365, got %s', q ->> 'premium_delta'));
  perform pg_temp.assert((q ->> 'commission_delta')::numeric = 8767.12,
    format('the commission delta rides the bound 10%%, got %s', q ->> 'commission_delta'));
  perform pg_temp.assert((q ->> 'remaining_days')::integer = 320 and (q ->> 'total_days')::integer = 365,
    'the pro-rata basis is the remaining days of the term');
  perform pg_temp.assert((q -> 'shares' -> 0 ->> 'basis') = 'pro_rata', 'the basis is recorded');

  -- An agreed delta wins as-is; a return is signed and carries its commission clawback.
  q := ins_preview_policy_endorsement(pa.id, current_date,
    jsonb_build_array(jsonb_build_object('insurer_id', v_alpha::text, 'agreed_delta', '-50000')),
    '{}'::jsonb);
  perform pg_temp.assert((q ->> 'premium_delta')::numeric = -50000 and (q ->> 'commission_delta')::numeric = -5000,
    format('the agreed return delta is taken as-is with its clawback, got %s / %s',
           q ->> 'premium_delta', q ->> 'commission_delta'));
  perform pg_temp.assert((q -> 'shares' -> 0 ->> 'basis') = 'agreed', 'the agreed basis is recorded');
  raise notice 'PASS: the calculation prices pro-rata and agreed deltas at the bound rate';

  -------------------------------------------------------------------
  -- 2. Propose: durable, with the stored quote, idempotent by key.
  -------------------------------------------------------------------
  e1 := ins_propose_policy_endorsement(pa.id, current_date,
    jsonb_build_array(jsonb_build_object('insurer_id', v_alpha::text, 'method', 'pro_rata', 'annual_delta', '100000')),
    jsonb_build_object('risk_description', 'Fleet grew to 26 vehicles'),
    'Fleet expansion approved by Alpha', gen_random_uuid());
  perform pg_temp.assert(e1.status = 'proposed' and e1.endorsement_no is null,
    'the proposal starts live and unnumbered (the number is stamped at posting)');
  perform pg_temp.assert((e1.calculation ->> 'premium_delta')::numeric = 87671.23,
    'the calculation is stored with the proposal');
  perform pg_temp.assert((e1.calculation -> 'changes' -> 0 ->> 'field') = 'risk_description',
    'the descriptive change rides with the proposal');
  perform pg_temp.assert((select count(*) from ins_policy_endorsement_events
                            where endorsement_id = e1.id and event = 'proposed') = 1,
    'the proposal is journalled');

  e2 := ins_propose_policy_endorsement(pa.id, current_date,
    jsonb_build_array(jsonb_build_object('insurer_id', v_alpha::text, 'method', 'pro_rata', 'annual_delta', '100000')),
    jsonb_build_object('risk_description', 'Fleet grew to 26 vehicles'),
    'Fleet expansion approved by Alpha', e1.request_key);
  perform pg_temp.assert(e2.id = e1.id, 'the same request key returns the same proposal');
  perform pg_temp.expect_error(
    format('select ins_propose_policy_endorsement(%L::uuid, current_date, ''[]''::jsonb, ''{}''::jsonb, ''Different payload entirely'', %L::uuid)',
           pa.id, e1.request_key),
    'INS_ENDORSEMENT_RETRY_CONFLICT', 'a different payload under the same key');
  perform pg_temp.expect_error(
    format('select ins_propose_policy_endorsement(%L::uuid, current_date, ''[]''::jsonb, ''{}''::jsonb, ''Another live proposal'', %L::uuid)',
           pa.id, gen_random_uuid()),
    'INS_ENDORSEMENT_EXISTS', 'a second live proposal on the same policy');
  raise notice 'PASS: proposals are durable, idempotent and one-per-policy';

  -------------------------------------------------------------------
  -- 3. Cross-pipeline: a live endorsement blocks a cancellation and
  --    vice versa; withdrawing frees the policy.
  -------------------------------------------------------------------
  -- The cross-guard fires at insert time, after the cancellation preview, so
  -- the probe carries terms the preview accepts.
  perform pg_temp.expect_error(
    format('select ins_submit_policy_cancellation(%L::uuid, current_date,
              jsonb_build_array(jsonb_build_object(''insurer_id'', %L::text, ''terms'',
                jsonb_build_object(''method'', ''manual_review'', ''contract_reference'', ''Alpha agreed cancellation terms'',
                                   ''manual_return_premium'', ''500000''))),
              ''[]''::jsonb, ''Insurer agreed to cancel the policy'', %L::uuid)',
           pa.id, v_alpha::text, gen_random_uuid()),
    'INS_ENDORSEMENT_LIVE', 'a cancellation while an endorsement is live');
  perform public.ins_withdraw_policy_endorsement(e1.id, 'Client changed their mind');
  select status into st from ins_policy_endorsements where id = e1.id;
  perform pg_temp.assert(st = 'withdrawn', 'the endorsement is withdrawn');

  cxl := ins_submit_policy_cancellation(pa.id, current_date,
    jsonb_build_array(jsonb_build_object('insurer_id', v_alpha::text, 'terms',
      jsonb_build_object('method', 'manual_review', 'contract_reference', 'Alpha agreed cancellation terms',
                         'manual_return_premium', '500000'))),
    '[]'::jsonb, 'Insurer agreed to cancel the policy', gen_random_uuid());
  perform pg_temp.expect_error(
    format('select ins_propose_policy_endorsement(%L::uuid, current_date, ''[]''::jsonb, ''{}''::jsonb, ''Endorsing a dying policy'', %L::uuid)',
           pa.id, gen_random_uuid()),
    'INS_ENDORSEMENT_CXL_LIVE', 'an endorsement while a cancellation is in flight');
  -- The cross-guard also stands as a table trigger, for paths that skip the RPC.
  reset role;
  perform pg_temp.expect_error(
    format('insert into ins_policy_endorsements (tenant_id, policy_id, effective_date, request_key, reason, insurer_terms, changes, proposed_by, calculation)
            values (%L::uuid, %L::uuid, current_date, %L::uuid, ''Direct insert while cancellation live'', ''[]''::jsonb, ''{}''::jsonb, %L::uuid, ''{}''::jsonb)',
           ta, pa.id, gen_random_uuid(), mgr),
    'INS_CANCELLATION_LIVE', 'a raw insert while a cancellation is in flight');
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  perform public.ins_withdraw_policy_cancellation(cxl.id, 'Cancellation called off by the insurer');
  raise notice 'PASS: endorsements and cancellations cannot be live together';

  -------------------------------------------------------------------
  -- 4. Withdraw rules: proposer only, open case, real reason.
  -------------------------------------------------------------------
  e1 := ins_propose_policy_endorsement(pa.id, current_date,
    jsonb_build_array(jsonb_build_object('insurer_id', v_alpha::text, 'agreed_delta', '25000')),
    '{}'::jsonb, 'Third vehicle added to the schedule', gen_random_uuid());
  perform pg_temp.jwt(mgr2);
  perform pg_temp.expect_error(
    format('select ins_withdraw_policy_endorsement(%L::uuid, ''Someone else tries to withdraw'')', e1.id),
    'INS_ENDORSEMENT_WITHDRAW', 'a non-proposer withdraw');
  perform pg_temp.jwt(mgr);
  perform pg_temp.expect_error(
    format('select ins_withdraw_policy_endorsement(%L::uuid, ''no'')', e1.id),
    'INS_ENDORSEMENT_WITHDRAW', 'a too-short reason');
  perform public.ins_withdraw_policy_endorsement(e1.id, 'Superseded by a better quote');
  raise notice 'PASS: withdrawals stay with the proposer and need a real reason';

  -------------------------------------------------------------------
  -- 5. The validation battery.
  -------------------------------------------------------------------
  perform pg_temp.expect_error(
    format('select ins_preview_policy_endorsement(%L::uuid, current_date + 1, ''[]''::jsonb, ''{}''::jsonb)', pa.id),
    'INS_ENDORSEMENT_INPUT', 'a future effective date');
  perform pg_temp.expect_error(
    format('select ins_preview_policy_endorsement(%L::uuid, current_date,
              jsonb_build_array(jsonb_build_object(''insurer_id'', %L::text, ''agreed_delta'', ''1000'')), ''{}''::jsonb)',
           pb.id, gen_random_uuid()::text),
    'INS_ENDORSEMENT_INPUT', 'an insurer that is not on the policy');
  perform pg_temp.expect_error(
    format('select ins_preview_policy_endorsement(%L::uuid, current_date,
              jsonb_build_array(
                jsonb_build_object(''insurer_id'', %L::text, ''agreed_delta'', ''1000''),
                jsonb_build_object(''insurer_id'', %L::text, ''agreed_delta'', ''2000'')), ''{}''::jsonb)',
           pb.id, v_alpha::text, v_alpha::text),
    'INS_ENDORSEMENT_INPUT', 'the same insurer twice');
  perform pg_temp.expect_error(
    format('select ins_preview_policy_endorsement(%L::uuid, current_date,
              jsonb_build_array(jsonb_build_object(''insurer_id'', %L::text, ''method'', ''magic'')), ''{}''::jsonb)',
           pb.id, v_alpha::text),
    'INS_ENDORSEMENT_INPUT', 'an unknown rating method');
  perform pg_temp.expect_error(
    format('select ins_preview_policy_endorsement(%L::uuid, current_date, ''[]''::jsonb,
              jsonb_build_object(''gross_premium'', 999))', pa.id),
    'INS_ENDORSEMENT_INPUT', 'a field that is not endorsable');
  perform pg_temp.expect_error(
    format('select ins_preview_policy_endorsement(%L::uuid, current_date, ''[]''::jsonb,
              jsonb_build_object(''sum_insured'', -5))', pa.id),
    'INS_ENDORSEMENT_INPUT', 'a non-positive sum insured');
  perform pg_temp.expect_error(
    format('select ins_preview_policy_endorsement(%L::uuid, current_date, ''[]''::jsonb, ''{}''::jsonb)', pa.id),
    'INS_ENDORSEMENT_INPUT', 'an endorsement that changes nothing');

  -- A descriptive-only endorsement is legitimate (zero premium delta).
  q := ins_preview_policy_endorsement(pa.id, current_date, '[]'::jsonb,
    jsonb_build_object('sum_insured', 60000000, 'notes', 'Sum insured aligned with the fleet schedule'));
  perform pg_temp.assert((q ->> 'premium_zero')::boolean = true
     and (q ->> 'premium_delta')::numeric = 0, 'a zero-premium endorsement is allowed');
  perform pg_temp.assert(exists (
     select 1 from jsonb_array_elements(q -> 'changes') ch
      where ch ->> 'field' = 'sum_insured' and (ch ->> 'before')::numeric = 50000000
        and (ch ->> 'after')::numeric = 60000000),
    'the sum-insured change records before and after');
  raise notice 'PASS: the validation battery holds, and descriptive-only endorsements work';

  -------------------------------------------------------------------
  -- 6. A live endorsement blocks a renewal; withdrawing frees it.
  -------------------------------------------------------------------
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  e1 := ins_propose_policy_endorsement(pb.id, current_date,
    jsonb_build_array(jsonb_build_object('insurer_id', v_alpha::text, 'agreed_delta', '10000')),
    '{}'::jsonb, 'Second vehicle added', gen_random_uuid());
  perform pg_temp.expect_error(
    format('select ins_create_renewal_draft(%L::uuid)', pb.id),
    'INS_ENDORSEMENT_LIVE', 'a renewal while an endorsement is live');
  perform public.ins_withdraw_policy_endorsement(e1.id, 'Renewal decided instead');
  declare rd ins_policies%rowtype;
  begin
    rd := ins_create_renewal_draft(pb.id);
    perform pg_temp.assert(rd.status = 'draft' and rd.renewal_of_id = pb.id, 'the renewal starts once the endorsement is withdrawn');
  end;
  raise notice 'PASS: a live endorsement blocks a renewal and frees it on withdraw';

  -------------------------------------------------------------------
  -- 7. The review position: bound values, computed current values.
  -------------------------------------------------------------------
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  q := ins_endorsement_review_position(pb.id);
  perform pg_temp.assert((q ->> 'posted_endorsements')::integer = 0
     and (q ->> 'current_gross_premium')::numeric = (q ->> 'bound_gross_premium')::numeric
     and (q ->> 'cancellation_in_flight')::boolean = false,
    'with nothing posted, current equals bound');
  e1 := ins_propose_policy_endorsement(pb.id, current_date,
    jsonb_build_array(jsonb_build_object('insurer_id', v_alpha::text, 'agreed_delta', '10000')),
    '{}'::jsonb, 'Vehicle added after all', gen_random_uuid());
  q := ins_endorsement_review_position(pb.id);
  perform pg_temp.assert(jsonb_array_length(q -> 'live_endorsements') = 1,
    'the live proposal shows in the position');
  perform public.ins_withdraw_policy_endorsement(e1.id, 'Checking the position was enough');
  raise notice 'PASS: the review position computes current from bound plus posted';

  -------------------------------------------------------------------
  -- 8. Access and tenant gates.
  -------------------------------------------------------------------
  perform pg_temp.jwt(mem);
  set local role authenticated;
  perform pg_temp.expect_error(
    format('select ins_preview_policy_endorsement(%L::uuid, current_date, ''[]''::jsonb, ''{}''::jsonb)', pa.id),
    'INS_FORBIDDEN', 'a member-only user reading the calculation');
  perform pg_temp.expect_error(
    format('select ins_propose_policy_endorsement(%L::uuid, current_date, ''[]''::jsonb, ''{}''::jsonb, ''Member cannot propose'', %L::uuid)',
           pa.id, gen_random_uuid()),
    'INS_FORBIDDEN', 'a member-only user proposing');
  reset role;
  perform pg_temp.jwt(out_);
  set local role authenticated;
  perform pg_temp.expect_error(
    format('select ins_propose_policy_endorsement(%L::uuid, current_date, ''[]''::jsonb, ''{}''::jsonb, ''Outsider'', %L::uuid)',
           pa.id, gen_random_uuid()),
    'INS_FORBIDDEN', 'an outsider proposing');
  reset role;
  perform pg_temp.jwt(ub);
  set local role authenticated;
  select count(*) into n from ins_policy_endorsements where tenant_id = ta;
  perform pg_temp.assert(n = 0, format('tenant B must see none of tenant A endorsements, got %s', n));
  reset role;
  raise notice 'PASS: proposals stay insurance-manager/finance and tenant-scoped';

  raise notice 'ALL PASS: endorsement proposals (E1)';
end
$$;

rollback;
