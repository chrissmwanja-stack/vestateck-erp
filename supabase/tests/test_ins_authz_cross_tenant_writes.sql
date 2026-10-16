-- P0-6 second pass: cross-tenant denials for insurance write RPCs that take a
-- record id, and the list RPC that returns bank accounts.
--
-- Tenant B's user holds BOTH the insurance manager role and the finance role,
-- so every role check passes and the only thing left to stop the call is the
-- tenant check. Each call must fail with INS_NOT_FOUND and leave tenant A's rows
-- unchanged. A positive control (tenant A's own user) shows the fixtures are valid.
--
-- Run only on a disposable local/test database; every fixture rolls back.

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
  ta uuid := gen_random_uuid();
  tb uuid := gen_random_uuid();
  mgr_a uuid := gen_random_uuid();
  mgr_b uuid := gen_random_uuid();
  bank_a uuid; bank_b uuid;
  line_id uuid; insurer uuid;
  c ins_clients%rowtype; p ins_policies%rowtype;
  claim_id uuid := gen_random_uuid();
  pay_id uuid := gen_random_uuid();
  cx_id uuid := gen_random_uuid();
  req_id uuid := gen_random_uuid();
  n integer;
  st text;
begin
  insert into tenants(id, name) values (ta, 'Cross-write A'), (tb, 'Cross-write B');
  insert into auth.users(id, email, raw_user_meta_data, raw_app_meta_data, aud, role, created_at, updated_at)
    select u, 'xw-'||u||'@test.local', '{}', '{}', 'authenticated', 'authenticated', now(), now()
    from unnest(array[mgr_a, mgr_b]) u;
  insert into app_users(id, tenant_id, name, email) values
    (mgr_a, ta, 'Cross-write manager A', 'xw-'||mgr_a||'@test.local'),
    (mgr_b, tb, 'Cross-write manager B', 'xw-'||mgr_b||'@test.local');
  insert into tenant_modules(tenant_id, module) values (ta, 'insurance'), (tb, 'insurance');
  insert into staff_roles(tenant_id, user_id, module, role) values
    (ta, mgr_a, 'insurance', 'manager'), (tb, mgr_b, 'insurance', 'manager');
  insert into finance_team_members(tenant_id, user_id, role) values
    (ta, mgr_a, 'finance'), (tb, mgr_b, 'finance');

  insert into fin_bank_accounts(tenant_id, name, kind, currency) values (ta, 'XW-A-OPERATING', 'operating', 'UGX') returning id into bank_a;
  insert into fin_bank_accounts(tenant_id, name, kind, currency) values (tb, 'XW-B-OPERATING', 'operating', 'UGX') returning id into bank_b;

  -- Tenant A fixtures: a policy (through the app RPCs), a claim, a payment,
  -- a cancellation and a cancellation cash request.
  perform pg_temp.jwt(mgr_a); set local role authenticated;
  insert into ins_product_lines(tenant_id, code, name) values (ta, 'MOTOR', 'Motor') returning id into line_id;
  insert into ins_insurers(tenant_id, code, name) values (ta, 'ALPHA', 'Alpha') returning id into insurer;
  c := ins_register_client('Cross-write client', 'corporate', null, null, null, 'low');
  p := ins_create_policy(c.id, insurer, line_id, current_date, current_date + 365, 50000, 'UGX', 1000, 10, null, null);
  reset role;

  -- Direct rows as superuser (guards bypassed with the same flag the RPCs use).
  perform set_config('ins.via_rpc', 'on', true);
  -- Claims need an active policy. Binding needs posting roles this test does not
  -- set up, and bind is covered by test_ins_core.sql, so the fixture marks it active.
  update ins_policies
     set status = 'active', bound_at = now(),
         commission_amount = round(gross_premium * 10 / 100, 2),
         net_premium_to_insurer = gross_premium - round(gross_premium * 10 / 100, 2)
   where id = p.id;
  insert into ins_claims(id, tenant_id, claim_no, policy_id, status, loss_date, loss_description, reserve_amount, paid_amount, payment_mode)
  values (claim_id, ta, 'XW-CLM-1', p.id, 'notified', current_date - 5, 'Cross-write fixture loss', 0, 0, 'insurer_direct');
  insert into ins_claim_payments(id, tenant_id, claim_id, kind, amount, payment_date, status)
  values (pay_id, ta, claim_id, 'insurer_direct', 100, current_date, 'posted');
  insert into ins_policy_cancellations(id, tenant_id, policy_id, request_key, reason, effective_date, insurer_terms, charge_refunds, proposed_by, status, calculation)
  values (cx_id, ta, p.id, gen_random_uuid(), 'Cross-write fixture cancellation', current_date, '[]'::jsonb, '[]'::jsonb, mgr_a, 'proposed', '{}'::jsonb);
  insert into ins_cancellation_cash_requests(id, tenant_id, cancellation_id, kind, bank_account_id, amount, cash_date, reference, notes, request_key, status, maker_id)
  values (req_id, ta, cx_id, 'refund', bank_a, 10, current_date, 'XW-REF', 'Cross-write fixture', gen_random_uuid(), 'pending', mgr_a);
  perform set_config('ins.via_rpc', 'off', true);

  -- Positive control: tenant A's own manager can read tenant A's cancellation context.
  perform pg_temp.jwt(mgr_a); set local role authenticated;
  perform ins_policy_cancellation_context(p.id, 0);
  reset role;

  -- The list RPC: tenant B sees only tenant B's bank accounts.
  perform pg_temp.jwt(mgr_b); set local role authenticated;
  select count(*) into n from ins_policy_cash_bank_accounts() where id = bank_a;
  reset role;
  perform pg_temp.assert(n = 0, 'list: tenant B saw tenant A''s bank account in ins_policy_cash_bank_accounts');

  -- Cross-tenant writes and reads by tenant B against tenant A's records.
  perform pg_temp.jwt(mgr_b); set local role authenticated;
  perform pg_temp.expect_error(format('select ins_record_claim_receipt(%L, %L, 1, current_date, %L, %L)', claim_id, bank_b, 'XW', 'XW'),
    'INS_NOT_FOUND', 'receipt against another tenant''s claim');
  perform pg_temp.expect_error(format('select ins_record_claim_payout(%L, %L, 1, current_date, %L, %L)', claim_id, bank_b, 'XW', 'XW'),
    'INS_NOT_FOUND', 'payout against another tenant''s claim');
  perform pg_temp.expect_error(format('select ins_void_claim_payment(%L, %L)', pay_id, 'Cross-tenant void attempt'),
    'INS_NOT_FOUND', 'void of another tenant''s claim payment');
  perform pg_temp.expect_error(format('select ins_policy_cancellation_context(%L, 0)', p.id),
    'INS_NOT_FOUND', 'cancellation context for another tenant''s policy');
  -- This read returns "not available" with no data instead of an error. Check that
  -- it leaks nothing about tenant A's cancellation or its cash requests.
  declare v jsonb;
  begin
    v := ins_cancellation_cash_context(p.id, bank_b, 0);
    perform pg_temp.assert(v->>'available' = 'false' and not (v ? 'requests') and not (v ? 'cancellation_no'),
      format('cancellation cash context leaked tenant A data to tenant B: %s', v));
  end;
  perform pg_temp.expect_error(format('select ins_decide_cancellation_cash(%L, %L, %L)', req_id, 'approve', 'Cross-tenant decision'),
    'INS_NOT_FOUND', 'decision on another tenant''s cancellation cash request');
  perform pg_temp.expect_error(format('select ins_submit_cancellation_cash_void(%L, %L, %L)', req_id, 'Cross-tenant void', gen_random_uuid()),
    'INS_NOT_FOUND', 'void of another tenant''s cancellation cash request');
  perform pg_temp.expect_error(format('select ins_submit_cancellation_cash(%L, %L, null, %L, null, 1, current_date, %L, %L, %L)',
      cx_id, 'refund', bank_b, 'XW', 'XW', gen_random_uuid()),
    'INS_NOT_FOUND', 'cancellation cash against another tenant''s cancellation');
  reset role;

  -- Nothing belonging to tenant A changed.
  select count(*) into n from ins_claim_payments where id = pay_id and status = 'posted';
  perform pg_temp.assert(n = 1, 'tenant A payment was voided or changed by a cross-tenant call');
  select status into st from ins_cancellation_cash_requests where id = req_id;
  perform pg_temp.assert(st = 'pending', format('tenant A cash request changed to %s by a cross-tenant call', st));
  select status into st from ins_claims where id = claim_id;
  perform pg_temp.assert(st = 'notified', format('tenant A claim changed to %s by a cross-tenant call', st));

  raise notice 'PASS: cross-tenant write denials for claims, cancellation cash and the bank list';
end $$;

rollback;
