-- Insurance Brokerage core (20261010100000_insurance_brokerage_core.sql,
-- 20261010110000_ins_tables_read_only_guard.sql).
--
-- Covers: the access tiers (member / manager / outsider), master data RLS,
-- client registration, draft policies and the RPC-only write discipline,
-- binding (journal lines, open items, party accounts, rounding, zero
-- commission, failed binds leaving nothing behind), the lock on bound
-- policies, renewals and the renewal pipeline, the structural guard triggers,
-- the claim state machine and its audit trail, the hand-off to the D4
-- settlement code, grants, anon, and tenant isolation.
--
-- "Known gap" probes at the end do NOT fail the run. Each one tries something
-- the schema currently allows but probably should not, prints a GAP notice if it
-- is still allowed, and rolls the probe back. When a gap is fixed the probe
-- prints PASS instead. The summary line counts them, the same convention as
-- security_authorization.sql.
--
-- Run against a fresh local stack only (`supabase start` / `supabase db reset`).
-- Everything runs in one transaction that ROLLBACKs, so no fixture data is left
-- behind; any RAISE EXCEPTION is a real assertion failure and makes psql exit
-- non-zero (same convention as the other files in this directory).

\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------

-- Runs a statement that must fail with an error whose text contains p_needle.
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

-- Runs a statement that must fail with the given SQLSTATE (for RLS denials,
-- whose message text is not stable).
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

-- Acts as a user for the rest of the transaction (role switching stays inline).
create function pg_temp.jwt(p_uid uuid)
returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
$$;

-- The RPCs set the transaction-local flag `ins.via_rpc` and it stays on for the
-- rest of the transaction. Clear it before probing the direct-write guards, so a
-- test does not pass or fail because an earlier RPC left the flag on.
create function pg_temp.flag_off()
returns void language sql as $$ select set_config('ins.via_rpc', 'off', true); $$;
create function pg_temp.flag_on()
returns void language sql as $$ select set_config('ins.via_rpc', 'on', true); $$;

-- Owner-side numeric reader, so assertions do not depend on the caller's RLS.
create function pg_temp.scalar(p_sql text)
returns numeric language plpgsql security definer set search_path = public, pg_temp as $$
declare v numeric;
begin
  execute p_sql into v;
  return v;
end $$;

create function pg_temp.je_net(p_je uuid, p_gl uuid) returns numeric
language sql security definer as $$
  select coalesce(sum(debit - credit), 0) from public.journal_entry_lines
  where journal_entry_id = p_je and gl_account_id = p_gl
$$;
create function pg_temp.je_bal(p_je uuid) returns numeric
language sql security definer as $$
  select coalesce(sum(debit - credit), 0) from public.journal_entry_lines where journal_entry_id = p_je
$$;
create function pg_temp.je_lines(p_je uuid) returns integer
language sql security definer as $$
  select count(*)::integer from public.journal_entry_lines where journal_entry_id = p_je
$$;
create function pg_temp.n_bind_journals(p_tenant uuid) returns integer
language sql security definer as $$
  select count(*)::integer from public.journal_entries
  where tenant_id = p_tenant and source_type = 'ins_policy_bind'
$$;
create function pg_temp.n_journals(p_tenant uuid) returns integer
language sql security definer as $$
  select count(*)::integer from public.journal_entries where tenant_id = p_tenant
$$;
create function pg_temp.n_ins_items(p_tenant uuid) returns integer
language sql security definer as $$
  select count(*)::integer from public.fin_open_items
  where tenant_id = p_tenant and source_type in ('ins_policy_premium', 'ins_policy_insurer')
$$;
create function pg_temp.n_items_for(p_policy uuid) returns integer
language sql security definer as $$
  select count(*)::integer from public.fin_open_items
  where source_id = p_policy and source_type in ('ins_policy_premium', 'ins_policy_insurer')
$$;

-- Thin wrappers over the RPCs, to keep the scenarios readable.
create function pg_temp.newpol(p_client uuid, p_insurer uuid, p_line uuid, p_from date, p_to date,
                               p_sum numeric, p_gross numeric, p_rate numeric)
returns public.ins_policies language sql as $$
  select * from public.ins_create_policy(p_client, p_insurer, p_line, p_from, p_to,
                                         p_sum, 'UGX', p_gross, p_rate, null, null)
$$;
create function pg_temp.newclaim(p_policy uuid, p_loss date, p_notified date, p_desc text, p_reserve numeric)
returns public.ins_claims language sql as $$
  select * from public.ins_create_claim(p_policy, p_loss, p_notified, p_desc, null, p_reserve)
$$;

do $$
declare
  v_ta uuid := gen_random_uuid();   -- tenant A: the insurance brokerage under test
  v_tb uuid := gen_random_uuid();   -- tenant B: isolation, and no insurer_payable rule
  u_mgr   uuid := gen_random_uuid();  -- A: insurance manager
  u_adm   uuid := gen_random_uuid();  -- A: insurance admin
  u_mem   uuid := gen_random_uuid();  -- A: insurance member
  u_out   uuid := gen_random_uuid();  -- A: no insurance role
  u_fin   uuid := gen_random_uuid();  -- A: finance team, no insurance role
  u_mgr_b uuid := gen_random_uuid();  -- B: insurance manager

  -- GL accounts (codes follow the insurance template)
  g_bank uuid; g_trust uuid; g_ar uuid; g_pay uuid; g_inc uuid; gb_ar uuid; gb_inc uuid;
  b_acc  uuid;                        -- an accounts row owned by tenant B

  -- tenant A masters and policies
  v_pl uuid; v_pl_off uuid; v_insr uuid; v_insr_off uuid;
  c1 ins_clients%rowtype; c2 ins_clients%rowtype;
  p1 ins_policies%rowtype;  p_r ins_policies%rowtype; p_z ins_policies%rowtype;
  p_d ins_policies%rowtype; p_near ins_policies%rowtype; p_ren ins_policies%rowtype;
  p_x ins_policies%rowtype;
  cl1 ins_claims%rowtype; cl2 ins_claims%rowtype; cl_ren ins_claims%rowtype;

  -- tenant B masters
  v_pl_b uuid; v_insr_b uuid; cb ins_clients%rowtype; pb ins_policies%rowtype;

  v_je uuid; v_n integer; v_n2 integer; v_num numeric;
  v_item record; v_item2 record; v_bal record; v_ev record;
  v_pcli uuid; v_pins uuid;
  v_j0 integer; v_i0 integer;
  v_trust_bank uuid; v_s fin_settlements%rowtype;
  v_probe text;
  v_gaps integer := 0;
begin
  -------------------------------------------------------------------
  -- Fixtures (as the table owner)
  -------------------------------------------------------------------
  insert into tenants (id, name) values (v_ta, 'Ins Core Brokerage A'), (v_tb, 'Ins Core Brokerage B');

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, recovery_token
  )
  select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
         'inscore-' || u.id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
         now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
  from (values (u_mgr), (u_adm), (u_mem), (u_out), (u_fin), (u_mgr_b)) as u(id);

  insert into app_users (id, tenant_id, name, email) values
    (u_mgr,   v_ta, 'Ins Manager A',  'inscore-' || u_mgr   || '@test.local'),
    (u_adm,   v_ta, 'Ins Admin A',    'inscore-' || u_adm   || '@test.local'),
    (u_mem,   v_ta, 'Ins Member A',   'inscore-' || u_mem   || '@test.local'),
    (u_out,   v_ta, 'Ins Outsider A', 'inscore-' || u_out   || '@test.local'),
    (u_fin,   v_ta, 'Ins Finance A',  'inscore-' || u_fin   || '@test.local'),
    (u_mgr_b, v_tb, 'Ins Manager B',  'inscore-' || u_mgr_b || '@test.local');

  insert into tenant_modules (tenant_id, module) values (v_ta, 'insurance'), (v_tb, 'insurance');
  insert into staff_roles (tenant_id, user_id, module, role) values
    (v_ta, u_mgr,   'insurance', 'manager'),
    (v_ta, u_adm,   'insurance', 'admin'),
    (v_ta, u_mem,   'insurance', 'member'),
    (v_tb, u_mgr_b, 'insurance', 'manager');
  insert into finance_team_members (tenant_id, user_id, role) values (v_ta, u_fin, 'finance');

  -- Tenant A mirrors the insurance template's mapping: ar_control 1100,
  -- insurer_payable 2010, commission_income 4000, client money in 1020.
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '1000', 'Operating Bank', 'asset') returning id into g_bank;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '1020', 'Client Money Bank (Premium Trust)', 'asset') returning id into g_trust;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '1100', 'Accounts Receivable Control', 'asset') returning id into g_ar;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '2010', 'Insurer Payable', 'liability') returning id into g_pay;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '4000', 'Commission Income', 'revenue') returning id into g_inc;
  insert into gl_posting_rules (tenant_id, account_role, gl_account_id) values
    (v_ta, 'bank', g_bank), (v_ta, 'client_money_bank', g_trust), (v_ta, 'ar_control', g_ar),
    (v_ta, 'insurer_payable', g_pay), (v_ta, 'commission_income', g_inc);

  -- Tenant B deliberately has no insurer_payable rule.
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_tb, '1100', 'Accounts Receivable Control', 'asset') returning id into gb_ar;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_tb, '4000', 'Commission Income', 'revenue') returning id into gb_inc;
  insert into gl_posting_rules (tenant_id, account_role, gl_account_id) values
    (v_tb, 'ar_control', gb_ar), (v_tb, 'commission_income', gb_inc);
  insert into accounts (tenant_id, account_code, name, account_type) values (v_tb, 'B-OTHER', 'Tenant B Party', 'client') returning id into b_acc;

  -- A closed period for the closed-period bind test.
  insert into accounting_periods (tenant_id, period_start, period_end, status)
  values (v_ta, date '2020-01-01', date '2020-01-31', 'closed');

  -- Tenant B masters and a draft policy, created through the real paths.
  perform pg_temp.jwt(u_mgr_b);
  set local role authenticated;
  insert into ins_product_lines (tenant_id, code, name) values (v_tb, 'MOTOR', 'Motor B') returning id into v_pl_b;
  insert into ins_insurers (tenant_id, code, name, default_commission_rate_pct) values (v_tb, 'BETA', 'Beta Assurance', 10) returning id into v_insr_b;
  cb := ins_register_client('Beta Client', 'corporate', null, null, null, 'medium');
  pb := pg_temp.newpol(cb.id, v_insr_b, v_pl_b, current_date, current_date + 365, 1000000, 100000, 10);
  reset role;

  -------------------------------------------------------------------
  -- 1. Access tiers
  -------------------------------------------------------------------
  set local role authenticated;
  perform pg_temp.jwt(u_mgr);
  perform pg_temp.assert(can_access_insurance() and can_manage_insurance(), 'manager must have both tiers');
  perform pg_temp.jwt(u_adm);
  perform pg_temp.assert(can_access_insurance() and can_manage_insurance(), 'admin must have both tiers');
  perform pg_temp.jwt(u_mem);
  perform pg_temp.assert(can_access_insurance() and not can_manage_insurance(), 'member has access but not the manager tier');
  perform pg_temp.jwt(u_out);
  perform pg_temp.assert(not can_access_insurance() and not can_manage_insurance(), 'a user with no role has neither tier');
  perform pg_temp.jwt(u_mgr_b);
  perform pg_temp.assert(can_manage_insurance(), 'tenant B manager manages tenant B');
  reset role;
  raise notice 'PASS: access tiers (manager and admin manage; member accesses; outsider has nothing)';

  -------------------------------------------------------------------
  -- 2. Master data: only managers write; members read; outsiders see nothing
  -------------------------------------------------------------------
  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  insert into ins_product_lines (tenant_id, code, name, class) values (v_ta, 'MOTOR', 'Motor', 'general') returning id into v_pl;
  insert into ins_product_lines (tenant_id, code, name, is_active) values (v_ta, 'OLDLINE', 'Retired line', false) returning id into v_pl_off;
  insert into ins_insurers (tenant_id, code, name, default_commission_rate_pct) values (v_ta, 'ALPHA', 'Alpha Assurance', 10) returning id into v_insr;
  insert into ins_insurers (tenant_id, code, name, is_active) values (v_ta, 'DORMANT', 'Dormant Insurer', false) returning id into v_insr_off;

  perform pg_temp.expect_error(
    format('insert into ins_insurers (tenant_id, code, name) values (%L, ''ALPHA'', ''Duplicate'')', v_ta),
    'ins_insurers_tenant_code_key', 'duplicate insurer code');
  perform pg_temp.expect_error(
    format('insert into ins_insurers (tenant_id, code, name) values (%L, ''bad code'', ''Bad'')', v_ta),
    'ins_insurers_code_check', 'insurer code format');
  perform pg_temp.expect_error(
    format('insert into ins_insurers (tenant_id, code, name, default_commission_rate_pct) values (%L, ''HIGH'', ''High'', 100)', v_ta),
    'ins_insurers_commission_check', 'insurer commission of 100');
  perform pg_temp.expect_error(
    format('insert into ins_product_lines (tenant_id, code, name, class) values (%L, ''ODD'', ''Odd'', ''marine'')', v_ta),
    'ins_product_lines_class_check', 'product line class');
  reset role;

  perform pg_temp.jwt(u_mem);
  set local role authenticated;
  perform pg_temp.expect_state(
    format('insert into ins_insurers (tenant_id, code, name) values (%L, ''MEMBR'', ''Member insurer'')', v_ta),
    '42501', 'member inserting an insurer');
  perform pg_temp.expect_state(
    format('insert into ins_product_lines (tenant_id, code, name) values (%L, ''MEMBR'', ''Member line'')', v_ta),
    '42501', 'member inserting a product line');
  update ins_insurers set name = 'Hacked' where id = v_insr;
  get diagnostics v_n = row_count;
  perform pg_temp.assert(v_n = 0, 'member must not update an insurer (RLS filters the row)');
  select count(*) into v_n from ins_insurers;
  select count(*) into v_n2 from ins_product_lines;
  perform pg_temp.assert(v_n = 2 and v_n2 = 2, 'member reads the masters');
  reset role;

  perform pg_temp.jwt(u_out);
  set local role authenticated;
  select count(*) into v_n from ins_insurers;
  select count(*) into v_n2 from ins_product_lines;
  perform pg_temp.assert(v_n = 0 and v_n2 = 0, 'outsider reads no masters');
  reset role;
  raise notice 'PASS: master data RLS and constraints';

  -------------------------------------------------------------------
  -- 3. Client registration
  -------------------------------------------------------------------
  perform pg_temp.jwt(u_mem);
  set local role authenticated;
  c1 := ins_register_client('Acme Holdings', 'corporate', 'TIN-100', 'acme@test.local', '+256700000001', 'low');
  c2 := ins_register_client('Jane Doe', 'individual', null, null, null, 'medium');
  perform pg_temp.assert(c1.tenant_id = v_ta and c1.client_type = 'corporate' and c1.risk_rating = 'low'
                         and c1.kyc_status = 'pending' and c1.party_account_id is null,
                         'registered client should be pending KYC with no party account yet');
  perform pg_temp.assert(c1.relationship_owner_id = u_mem, 'relationship owner defaults to the registrar');
  perform pg_temp.expect_error('select ins_register_client(''   '')', 'INS_REQUIRED', 'blank client name');
  perform pg_temp.expect_error('select ins_register_client(''Bad Co'', ''partnership'')', 'ins_clients_type_check', 'bad client type');
  perform pg_temp.expect_error('select ins_register_client(''Bad Co'', ''corporate'', null, null, null, ''extreme'')', 'ins_clients_risk_check', 'bad risk rating');
  reset role;
  perform pg_temp.assert(
    (select name from bd_clients where id = c1.client_id and tenant_id = v_ta) = 'Acme Holdings',
    'registration should create the BD client master row in the same tenant');
  perform pg_temp.assert(pg_temp.scalar(format('select count(*) from bd_clients where tenant_id = %L and name = ''Bad Co''', v_ta)) = 0,
    'rejected registrations must not leave a BD client behind');

  perform pg_temp.jwt(u_out);
  set local role authenticated;
  perform pg_temp.expect_error('select ins_register_client(''Nope'')', 'INS_FORBIDDEN', 'outsider registering a client');
  reset role;
  -- KYC approval is a manager decision: a member keeps the profile up to date
  -- but cannot verify a client, reset a verified one, or start one as verified.
  perform pg_temp.flag_off();
  perform pg_temp.jwt(u_mem);
  set local role authenticated;
  perform pg_temp.expect_state(format('update ins_clients set kyc_status = ''verified'' where id = %L', c2.id),
    '42501', 'a member verifying KYC');
  update ins_clients set risk_rating = 'high' where id = c2.id;
  get diagnostics v_n = row_count;
  perform pg_temp.assert(v_n = 1, 'a member can still edit other client profile fields');
  perform pg_temp.expect_state(
    format('insert into ins_clients (tenant_id, client_id, kyc_status) values (%L, %L, ''verified'')', v_ta, c2.client_id),
    '42501', 'a member registering a client as already verified');
  reset role;
  perform pg_temp.assert((select kyc_status from ins_clients where id = c2.id) = 'pending', 'KYC stays pending after the member attempts');

  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  update ins_clients set kyc_status = 'verified' where id = c2.id;
  get diagnostics v_n = row_count;
  perform pg_temp.assert(v_n = 1, 'a manager can verify KYC');
  reset role;
  perform pg_temp.assert((select kyc_status from ins_clients where id = c2.id) = 'verified', 'KYC is verified after the manager update');

  perform pg_temp.flag_off();
  perform pg_temp.jwt(u_mem);
  set local role authenticated;
  perform pg_temp.expect_state(format('update ins_clients set kyc_status = ''pending'' where id = %L', c2.id),
    '42501', 'a member resetting a verified client');
  reset role;
  perform pg_temp.assert((select kyc_status from ins_clients where id = c2.id) = 'verified', 'KYC stays verified after a member attempt to reset it');
  -- back to the state later sections expect
  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  update ins_clients set kyc_status = 'pending' where id = c2.id;
  reset role;

  raise notice 'PASS: client registration';

  -------------------------------------------------------------------
  -- 4. Draft policies and the RPC-only write path
  -------------------------------------------------------------------
  perform pg_temp.jwt(u_mem);
  set local role authenticated;
  perform pg_temp.expect_error(
    format('select pg_temp.newpol(%L, %L, %L, current_date, current_date, 1, 1, 1)', c1.id, v_insr, v_pl),
    'INS_DATES', 'expiry equal to inception');
  perform pg_temp.expect_error(
    format('select pg_temp.newpol(%L, %L, %L, current_date, current_date + 365, 1, -5, 1)', c1.id, v_insr, v_pl),
    'INS_AMOUNT', 'negative premium');
  perform pg_temp.expect_error(
    format('select pg_temp.newpol(%L, %L, %L, current_date, current_date + 365, 1, 1, 100)', c1.id, v_insr, v_pl),
    'INS_COMMISSION', 'commission of 100');
  perform pg_temp.expect_error(
    format('select pg_temp.newpol(%L, %L, %L, current_date, current_date + 365, 1, 1, 10)', gen_random_uuid(), v_insr, v_pl),
    'INS_NOT_FOUND: client', 'unknown client');
  perform pg_temp.expect_error(
    format('select pg_temp.newpol(%L, %L, %L, current_date, current_date + 365, 1, 1, 10)', cb.id, v_insr, v_pl),
    'INS_NOT_FOUND: client', 'client of another tenant');
  perform pg_temp.expect_error(
    format('select pg_temp.newpol(%L, %L, %L, current_date, current_date + 365, 1, 1, 10)', c1.id, v_insr_off, v_pl),
    'INS_NOT_FOUND: active insurer', 'inactive insurer');
  perform pg_temp.expect_error(
    format('select pg_temp.newpol(%L, %L, %L, current_date, current_date + 365, 1, 1, 10)', c1.id, v_insr, v_pl_off),
    'INS_NOT_FOUND: active product line', 'inactive product line');

  p1  := pg_temp.newpol(c1.id, v_insr, v_pl, current_date - 30, current_date + 335, 50000000, 1000000, 10);
  p_d := pg_temp.newpol(c2.id, v_insr, v_pl, current_date, current_date + 365, 5000000, 300000, 10);
  perform pg_temp.assert(p1.status = 'draft' and p1.tenant_id = v_ta and p1.commission_amount is null
                         and p1.net_premium_to_insurer is null and p1.bound_at is null and p1.journal_entry_id is null,
                         'a new policy is a draft with no bound fields');
  perform pg_temp.assert(p1.policy_no is not null and p_d.policy_no is not null and p1.policy_no <> p_d.policy_no,
                         'policy numbers are allocated and distinct');

  -- Members edit drafts directly (by design).
  update ins_policies set notes = 'edited by member', gross_premium = 1000000 where id = p1.id;
  get diagnostics v_n = row_count;
  perform pg_temp.assert(v_n = 1, 'a member can edit a draft');

  -- Direct inserts and status changes are refused.
  perform pg_temp.flag_off();
  perform pg_temp.expect_error(
    format('insert into ins_policies (tenant_id, policy_no, client_id, insurer_id, product_line_id, inception_date, expiry_date)
            values (%L, ''HAND-1'', %L, %L, %L, current_date, current_date + 30)', v_ta, c1.id, v_insr, v_pl),
    'INS_RPC_ONLY', 'direct policy insert');
  perform pg_temp.expect_error(
    format('update ins_policies set status = ''active'' where id = %L', p_d.id),
    'INS_STATUS_RPC_ONLY', 'direct activation of a draft');
  reset role;

  perform pg_temp.jwt(u_out);
  set local role authenticated;
  perform pg_temp.expect_error(
    format('select pg_temp.newpol(%L, %L, %L, current_date, current_date + 365, 1, 1, 10)', c1.id, v_insr, v_pl),
    'INS_FORBIDDEN', 'outsider creating a policy');
  reset role;
  raise notice 'PASS: draft policies, validation and the RPC-only write path';

  -------------------------------------------------------------------
  -- 5. Bind: one journal, two open items, party accounts (G 1,000,000 at 10%)
  -------------------------------------------------------------------
  perform pg_temp.jwt(u_mem);
  set local role authenticated;
  perform pg_temp.expect_error(format('select ins_bind_policy(%L)', p1.id), 'INS_FORBIDDEN', 'member binding a policy');
  reset role;

  v_j0 := pg_temp.n_bind_journals(v_ta);
  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  p1 := ins_bind_policy(p1.id);
  reset role;

  perform pg_temp.assert(p1.status = 'active' and p1.commission_amount = 100000 and p1.net_premium_to_insurer = 900000
                         and p1.bound_by = u_mgr and p1.bound_at is not null and p1.journal_entry_id is not null,
                         'bound policy should carry commission 100000, net 900000 and the bind stamps');
  v_je := p1.journal_entry_id;
  perform pg_temp.assert(pg_temp.n_bind_journals(v_ta) = v_j0 + 1, 'binding posts exactly one journal');
  perform pg_temp.assert(
    (select count(*) from journal_entries where id = v_je and tenant_id = v_ta and source_type = 'ins_policy_bind'
        and source_id = p1.id and entry_date = p1.inception_date) = 1,
    'journal should be tenant A, source ins_policy_bind, source id = the policy, dated on inception');
  perform pg_temp.assert(pg_temp.je_lines(v_je) = 3 and pg_temp.je_bal(v_je) = 0, 'journal has three lines and balances');
  perform pg_temp.assert(pg_temp.je_net(v_je, g_ar) = 1000000, 'Dr AR control for the gross premium');
  perform pg_temp.assert(pg_temp.je_net(v_je, g_pay) = -900000, 'Cr insurer payable for the net premium');
  perform pg_temp.assert(pg_temp.je_net(v_je, g_inc) = -100000, 'Cr commission income for the commission');

  select party_account_id into v_pcli from ins_clients where id = c1.id;
  select party_account_id into v_pins from ins_insurers where id = v_insr;
  perform pg_temp.assert(v_pcli is not null and v_pins is not null, 'bind creates both party accounts');
  perform pg_temp.assert((select account_type from accounts where id = v_pcli and tenant_id = v_ta) = 'client'
                         and (select name from accounts where id = v_pcli) = 'Acme Holdings',
                         'client party account is a client account named after the client');
  perform pg_temp.assert((select account_type from accounts where id = v_pins and tenant_id = v_ta) = 'vendor'
                         and (select name from accounts where id = v_pins) = 'Alpha Assurance',
                         'insurer party account is a vendor account named after the insurer');

  select * into v_item from fin_open_items where tenant_id = v_ta and source_type = 'ins_policy_premium' and source_id = p1.id;
  perform pg_temp.assert(v_item.side = 'receivable' and v_item.control_role = 'ar_control' and v_item.amount = 1000000
                         and v_item.party_account_id = v_pcli and v_item.document_no = p1.policy_no
                         and v_item.document_date = p1.inception_date and v_item.currency = 'UGX',
                         'premium open item: receivable, ar_control, gross, client party');
  select * into v_item2 from fin_open_items where tenant_id = v_ta and source_type = 'ins_policy_insurer' and source_id = p1.id;
  perform pg_temp.assert(v_item2.side = 'payable' and v_item2.control_role = 'insurer_payable' and v_item2.amount = 900000
                         and v_item2.party_account_id = v_pins and v_item2.document_no = p1.policy_no,
                         'insurer open item: payable, insurer_payable, net, insurer party');
  select * into v_bal from fin_open_item_balances where id = v_item.id;
  perform pg_temp.assert(v_bal.outstanding_amount = 1000000 and v_bal.settlement_status = 'open', 'premium item starts open');

  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  perform pg_temp.expect_error(format('select ins_bind_policy(%L)', p1.id), 'INS_NOT_DRAFT', 'binding twice');
  reset role;
  raise notice 'PASS: bind posts Dr AR / Cr insurer payable / Cr commission and creates two open items';

  -------------------------------------------------------------------
  -- 6. Rounding (G 100,001.00 at 12.5% -> C 12,500.13, N 87,500.87), party reuse
  -------------------------------------------------------------------
  perform pg_temp.jwt(u_mem);
  set local role authenticated;
  p_r := pg_temp.newpol(c1.id, v_insr, v_pl, current_date - 20, current_date + 345, 2000000, 100001.00, 12.5);
  reset role;
  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  p_r := ins_bind_policy(p_r.id);
  reset role;
  perform pg_temp.assert(p_r.commission_amount = 12500.13 and p_r.net_premium_to_insurer = 87500.87
                         and p_r.commission_amount + p_r.net_premium_to_insurer = p_r.gross_premium,
                         'commission rounds to 2dp and net is the remainder');
  perform pg_temp.assert(pg_temp.je_bal(p_r.journal_entry_id) = 0
                         and pg_temp.je_net(p_r.journal_entry_id, g_ar) = 100001.00
                         and pg_temp.je_net(p_r.journal_entry_id, g_pay) = -87500.87
                         and pg_temp.je_net(p_r.journal_entry_id, g_inc) = -12500.13,
                         'rounded journal balances to the cent');
  perform pg_temp.assert((select party_account_id from ins_clients where id = c1.id) = v_pcli
                         and (select party_account_id from ins_insurers where id = v_insr) = v_pins
                         and pg_temp.scalar(format('select count(*) from accounts where tenant_id = %L and name = ''Acme Holdings''', v_ta)) = 1,
                         'a second bind reuses the existing party accounts');
  raise notice 'PASS: rounding keeps the journal balanced and party accounts are reused';

  -------------------------------------------------------------------
  -- 7. Zero commission: two journal lines, no income line
  -------------------------------------------------------------------
  perform pg_temp.jwt(u_mem);
  set local role authenticated;
  p_z := pg_temp.newpol(c2.id, v_insr, v_pl, current_date - 10, current_date + 355, 1000000, 500000, 0);
  reset role;
  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  p_z := ins_bind_policy(p_z.id);
  reset role;
  perform pg_temp.assert(p_z.commission_amount = 0 and p_z.net_premium_to_insurer = 500000, 'zero commission binds with net = gross');
  perform pg_temp.assert(pg_temp.je_lines(p_z.journal_entry_id) = 2 and pg_temp.je_bal(p_z.journal_entry_id) = 0
                         and pg_temp.je_net(p_z.journal_entry_id, g_inc) = 0,
                         'zero commission posts two lines and nothing to commission income');
  perform pg_temp.assert(pg_temp.n_items_for(p_z.id) = 2, 'zero commission still creates both open items');
  raise notice 'PASS: zero commission';

  -------------------------------------------------------------------
  -- 8. Refused binds leave nothing behind
  -------------------------------------------------------------------
  v_j0 := pg_temp.n_bind_journals(v_ta);
  v_i0 := pg_temp.n_ins_items(v_ta);

  perform pg_temp.jwt(u_mem);
  set local role authenticated;
  p_x := pg_temp.newpol(c1.id, v_insr, v_pl, current_date, current_date + 365, 1000, 0, 10);
  reset role;
  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  perform pg_temp.expect_error(format('select ins_bind_policy(%L)', p_x.id), 'INS_PREMIUM_REQUIRED', 'binding a zero-premium policy');
  reset role;

  perform pg_temp.jwt(u_mem);
  set local role authenticated;
  p_x := pg_temp.newpol(c1.id, v_insr, v_pl, current_date, current_date + 365, 1000, 0.01, 99.99);
  reset role;
  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  perform pg_temp.expect_error(format('select ins_bind_policy(%L)', p_x.id), 'INS_COMMISSION_TOO_HIGH', 'commission leaving nothing for the insurer');
  reset role;

  -- Inception inside a closed accounting period.
  perform pg_temp.jwt(u_mem);
  set local role authenticated;
  p_x := pg_temp.newpol(c1.id, v_insr, v_pl, date '2020-01-15', date '2021-01-14', 1000000, 100000, 10);
  reset role;
  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  perform pg_temp.expect_error(format('select ins_bind_policy(%L)', p_x.id), 'closed accounting period', 'binding into a closed period');
  reset role;
  perform pg_temp.assert((select status from ins_policies where id = p_x.id) = 'draft'
                         and pg_temp.n_items_for(p_x.id) = 0, 'closed-period bind leaves the policy a draft with no open items');

  -- Tenant B has no insurer_payable rule.
  perform pg_temp.jwt(u_mgr_b);
  set local role authenticated;
  perform pg_temp.expect_error(format('select ins_bind_policy(%L)', pb.id), 'INS_POSTING_RULE_MISSING', 'binding without an insurer_payable rule');
  reset role;
  perform pg_temp.assert((select status from ins_policies where id = pb.id) = 'draft'
                         and (select party_account_id from ins_clients where id = cb.id) is null
                         and (select party_account_id from ins_insurers where id = v_insr_b) is null
                         and pg_temp.n_bind_journals(v_tb) = 0 and pg_temp.n_ins_items(v_tb) = 0,
                         'a missing posting rule stops the bind before any write');

  -- A policy in a non-ledger currency can be drafted but not bound.
  perform pg_temp.jwt(u_mem);
  set local role authenticated;
  p_x := ins_create_policy(c1.id, v_insr, v_pl, current_date - 1, current_date + 364, 1000, 'USD', 1000, 10, null, null);
  reset role;
  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  perform pg_temp.expect_error(format('select ins_bind_policy(%L)', p_x.id), 'INS_CURRENCY_UNSUPPORTED', 'binding a USD policy');
  reset role;
  perform pg_temp.assert((select status from ins_policies where id = p_x.id) = 'draft'
                         and pg_temp.n_items_for(p_x.id) = 0, 'a non-ledger currency bind leaves the policy a draft with no open items');

  perform pg_temp.assert(pg_temp.n_bind_journals(v_ta) = v_j0 and pg_temp.n_ins_items(v_ta) = v_i0,
                         'refused binds in tenant A posted no journal and created no open items');
  raise notice 'PASS: refused binds leave no journal, no open items, no party accounts';

  -------------------------------------------------------------------
  -- 9. Bound policies are locked; drafts are deletable by managers only
  -------------------------------------------------------------------
  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  update ins_policies set gross_premium = 1 where id = p1.id;
  get diagnostics v_n = row_count;
  perform pg_temp.assert(v_n = 0, 'RLS hides a bound policy from UPDATE');
  delete from ins_policies where id = p1.id;
  get diagnostics v_n = row_count;
  perform pg_temp.assert(v_n = 0, 'RLS hides a bound policy from DELETE');
  reset role;
  perform pg_temp.assert((select gross_premium from ins_policies where id = p1.id) = 1000000, 'bound premium is unchanged');

  -- The guard holds even for the table owner.
  perform pg_temp.flag_off();
  perform pg_temp.expect_error(format('update ins_policies set gross_premium = 1 where id = %L', p1.id), 'INS_POLICY_LOCKED', 'owner editing a bound premium');
  perform pg_temp.expect_error(format('update ins_policies set status = ''draft'' where id = %L', p1.id), 'INS_STATUS_RPC_ONLY', 'owner reverting status outside the RPCs');
  perform pg_temp.flag_on();
  perform pg_temp.expect_error(format('update ins_policies set status = ''draft'' where id = %L', p1.id), 'INS_STATUS_INVALID', 'reverting a bound policy to draft');
  perform pg_temp.flag_off();
  update ins_policies set notes = 'note added after bind' where id = p1.id;
  perform pg_temp.assert((select notes from ins_policies where id = p1.id) = 'note added after bind', 'notes stay editable after bind');

  -- Draft deletion.
  perform pg_temp.jwt(u_mem);
  set local role authenticated;
  p_x := pg_temp.newpol(c1.id, v_insr, v_pl, current_date, current_date + 365, 1000, 1000, 5);
  delete from ins_policies where id = p_x.id;
  get diagnostics v_n = row_count;
  perform pg_temp.assert(v_n = 0, 'a member cannot delete a draft');
  reset role;
  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  delete from ins_policies where id = p_x.id;
  get diagnostics v_n = row_count;
  perform pg_temp.assert(v_n = 1, 'a manager can delete a draft');
  reset role;
  raise notice 'PASS: bound policies are locked (even for the owner); draft deletion is manager-only';

  -------------------------------------------------------------------
  -- 10. Renewals and the renewal pipeline
  -------------------------------------------------------------------
  perform pg_temp.jwt(u_mem);
  set local role authenticated;
  p_near := pg_temp.newpol(c1.id, v_insr, v_pl, current_date - 300, current_date + 65, 10000000, 2000000, 15);
  perform pg_temp.expect_error(format('select ins_create_renewal_draft(%L)', p_near.id), 'INS_RENEWAL_STATE', 'renewing a draft');
  reset role;
  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  p_near := ins_bind_policy(p_near.id);
  reset role;

  perform pg_temp.jwt(u_mem);
  set local role authenticated;
  select * into v_bal from ins_renewal_pipeline where policy_id = p_near.id;
  perform pg_temp.assert(v_bal.policy_id is not null and v_bal.days_to_expiry = 65 and v_bal.renewal_draft_id is null
                         and v_bal.client_name = 'Acme Holdings' and v_bal.insurer_name = 'Alpha Assurance',
                         'a policy expiring in 65 days is in the pipeline with no renewal draft');
  perform pg_temp.assert(not exists (select 1 from ins_renewal_pipeline where policy_id = p1.id),
                         'a policy expiring in 335 days is outside the 120-day window');

  p_ren := ins_create_renewal_draft(p_near.id);
  perform pg_temp.assert(p_ren.status = 'draft' and p_ren.renewal_of_id = p_near.id
                         and p_ren.inception_date = p_near.expiry_date
                         and p_ren.expiry_date = p_near.expiry_date + (p_near.expiry_date - p_near.inception_date)
                         and p_ren.client_id = p_near.client_id and p_ren.insurer_id = p_near.insurer_id
                         and p_ren.product_line_id = p_near.product_line_id
                         and p_ren.gross_premium = p_near.gross_premium and p_ren.commission_rate_pct = p_near.commission_rate_pct
                         and p_ren.sum_insured = p_near.sum_insured and p_ren.policy_no <> p_near.policy_no,
                         'renewal copies the terms, starts on the old expiry and keeps the term length');
  perform pg_temp.assert((select renewal_draft_id from ins_renewal_pipeline where policy_id = p_near.id) = p_ren.id,
                         'the pipeline links the renewal draft');
  perform pg_temp.expect_error(format('select ins_create_renewal_draft(%L)', p_near.id), 'INS_RENEWAL_EXISTS', 'second renewal draft');
  perform pg_temp.expect_error(format('select ins_create_renewal_draft(%L)', p_ren.id), 'INS_RENEWAL_STATE', 'renewing the renewal draft');
  reset role;

  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  p_ren := ins_bind_policy(p_ren.id);
  reset role;
  perform pg_temp.assert(p_ren.status = 'active' and (select status from ins_policies where id = p_near.id) = 'renewed',
                         'binding the renewal marks the predecessor renewed');
  perform pg_temp.assert(pg_temp.n_items_for(p_ren.id) = 2 and pg_temp.n_items_for(p_near.id) = 2
                         and p_ren.journal_entry_id <> p_near.journal_entry_id,
                         'each term has its own journal and open items');
  perform pg_temp.jwt(u_mem);
  set local role authenticated;
  perform pg_temp.assert(not exists (select 1 from ins_renewal_pipeline where policy_id = p_near.id),
                         'a renewed policy leaves the pipeline');
  perform pg_temp.expect_error(format('select ins_create_renewal_draft(%L)', p_near.id), 'INS_RENEWAL_STATE', 'renewing an already renewed policy');
  reset role;
  raise notice 'PASS: renewals copy terms, bind marks the predecessor renewed, the pipeline follows';

  -------------------------------------------------------------------
  -- 11. Structural guards (as the table owner, flag cleared)
  -------------------------------------------------------------------
  perform pg_temp.flag_off();
  perform pg_temp.expect_error(
    format('update ins_clients set client_id = %L where id = %L', c2.client_id, c1.id), 'INS_IMMUTABLE', 'changing the BD client link');
  perform pg_temp.expect_error(
    format('update ins_clients set party_account_id = null where id = %L', c1.id), 'INS_PARTY_ACCOUNT_RPC_ONLY', 'unlinking a client party account');
  perform pg_temp.expect_error(
    format('update ins_insurers set party_account_id = null where id = %L', v_insr), 'INS_PARTY_ACCOUNT_RPC_ONLY', 'unlinking an insurer party account');
  perform pg_temp.flag_on();
  perform pg_temp.expect_error(
    format('update ins_clients set party_account_id = %L where id = %L', b_acc, c1.id), 'INS_CROSS_TENANT', 'client linked to another tenant''s account');
  perform pg_temp.expect_error(
    format('update ins_insurers set party_account_id = %L where id = %L', b_acc, v_insr), 'INS_CROSS_TENANT', 'insurer linked to another tenant''s account');
  perform pg_temp.flag_off();
  perform pg_temp.expect_error(
    format('insert into ins_clients (tenant_id, client_id) values (%L, %L)', v_ta, cb.client_id), 'INS_CROSS_TENANT', 'profile on another tenant''s BD client');
  perform pg_temp.flag_on();
  perform pg_temp.expect_error(
    format('insert into ins_policies (tenant_id, policy_no, client_id, insurer_id, product_line_id, inception_date, expiry_date)
            values (%L, ''X-1'', %L, %L, %L, current_date, current_date + 30)', v_ta, cb.id, v_insr, v_pl),
    'INS_CROSS_TENANT: client', 'policy for another tenant''s client');
  perform pg_temp.expect_error(
    format('insert into ins_policies (tenant_id, policy_no, client_id, insurer_id, product_line_id, inception_date, expiry_date)
            values (%L, ''X-2'', %L, %L, %L, current_date, current_date + 30)', v_ta, c1.id, v_insr_b, v_pl),
    'INS_CROSS_TENANT: insurer', 'policy with another tenant''s insurer');
  perform pg_temp.expect_error(
    format('insert into ins_policies (tenant_id, policy_no, client_id, insurer_id, product_line_id, inception_date, expiry_date)
            values (%L, ''X-3'', %L, %L, %L, current_date, current_date + 30)', v_ta, c1.id, v_insr, v_pl_b),
    'INS_CROSS_TENANT: product line', 'policy with another tenant''s product line');
  perform pg_temp.flag_off();
  raise notice 'PASS: guard triggers (immutable client link, RPC-only party accounts, same-tenant references)';

  -------------------------------------------------------------------
  -- 12. Claims: creation rules and the RPC-only write path
  -------------------------------------------------------------------
  perform pg_temp.jwt(u_mem);
  set local role authenticated;
  perform pg_temp.expect_error(
    format('select pg_temp.newclaim(%L, current_date, current_date, ''Loss'', 0)', p_d.id), 'INS_CLAIM_STATE', 'claim on a draft policy');
  perform pg_temp.expect_error(
    format('select pg_temp.newclaim(%L, current_date - 100, current_date, ''Loss'', 0)', p1.id), 'INS_LOSS_OUTSIDE_POLICY', 'loss before inception');
  perform pg_temp.expect_error(
    format('select pg_temp.newclaim(%L, current_date + 400, current_date + 400, ''Loss'', 0)', p1.id), 'INS_LOSS_OUTSIDE_POLICY', 'loss after expiry');
  perform pg_temp.expect_error(
    format('select pg_temp.newclaim(%L, current_date - 5, current_date, ''   '', 0)', p1.id), 'INS_REQUIRED', 'blank loss description');
  perform pg_temp.expect_error(
    format('select pg_temp.newclaim(%L, current_date - 5, current_date, ''Loss'', -1)', p1.id), 'INS_AMOUNT', 'negative reserve');
  perform pg_temp.expect_error(
    format('select pg_temp.newclaim(%L, current_date - 5, current_date - 6, ''Loss'', 0)', p1.id), 'ins_claims_notified_check', 'notified before the loss');
  perform pg_temp.expect_error(
    format('select pg_temp.newclaim(%L, current_date, current_date, ''Loss'', 0)', gen_random_uuid()), 'INS_NOT_FOUND: policy', 'unknown policy');

  cl1 := pg_temp.newclaim(p1.id, current_date - 10, current_date - 8, 'Collision on the Jinja road', 2000000);
  cl2 := pg_temp.newclaim(p1.id, current_date - 3, current_date - 2, 'Theft of insured goods', 500000);
  cl_ren := pg_temp.newclaim(p_near.id, current_date - 20, current_date - 19, 'Fire at premises (renewed policy)', 100000);
  perform pg_temp.assert(cl1.status = 'notified' and cl1.paid_amount = 0 and cl1.approved_amount is null and cl1.tenant_id = v_ta
                         and cl1.claim_no is not null and cl1.claim_no <> cl2.claim_no,
                         'a new claim is notified with no money moved');
  perform pg_temp.assert(cl_ren.status = 'notified', 'a claim can be raised against a renewed policy');
  reset role;
  perform pg_temp.assert((select count(*) from ins_claim_events where claim_id = cl1.id and from_status is null and to_status = 'notified') = 1,
                         'creating a claim records a notified event');

  perform pg_temp.jwt(u_mem);
  set local role authenticated;
  perform pg_temp.flag_off();
  perform pg_temp.expect_error(
    format('insert into ins_claims (tenant_id, claim_no, policy_id, loss_date, loss_description) values (%L, ''HAND-C'', %L, current_date - 1, ''x'')', v_ta, p1.id),
    'INS_RPC_ONLY', 'direct claim insert');
  perform pg_temp.expect_error(format('update ins_claims set status = ''approved'' where id = %L', cl1.id), 'INS_CLAIM_RPC_ONLY', 'direct status change');
  perform pg_temp.expect_error(format('update ins_claims set approved_amount = 9 where id = %L', cl1.id), 'INS_CLAIM_RPC_ONLY', 'direct approved amount');
  perform pg_temp.expect_error(format('update ins_claims set paid_amount = 0.5, approved_amount = 1 where id = %L', cl1.id), 'INS_CLAIM_RPC_ONLY', 'direct paid amount');
  perform pg_temp.expect_error(format('update ins_claims set settled_at = now() where id = %L', cl1.id), 'INS_CLAIM_RPC_ONLY', 'direct settled date');
  update ins_claims set reserve_amount = 2500000, insurer_claim_ref = 'INSR-77' where id = cl1.id;
  get diagnostics v_n = row_count;
  perform pg_temp.assert(v_n = 1, 'a member can still edit the reserve and the insurer reference');
  reset role;
  perform pg_temp.flag_off();
  perform pg_temp.expect_error(format('update ins_claims set claim_no = ''CHANGED'' where id = %L', cl1.id), 'INS_IMMUTABLE', 'changing a claim number');
  perform pg_temp.expect_error(format('update ins_claims set policy_id = %L where id = %L', p_z.id, cl1.id), 'INS_IMMUTABLE', 'moving a claim to another policy');

  perform pg_temp.jwt(u_out);
  set local role authenticated;
  perform pg_temp.expect_error(
    format('select pg_temp.newclaim(%L, current_date - 5, current_date, ''Loss'', 0)', p1.id), 'INS_FORBIDDEN', 'outsider notifying a claim');
  reset role;
  raise notice 'PASS: claim creation rules and the RPC-only write path';

  -------------------------------------------------------------------
  -- 13. Claim state machine, approvals and the audit trail
  -------------------------------------------------------------------
  v_j0 := pg_temp.n_journals(v_ta);

  perform pg_temp.jwt(u_mem);
  set local role authenticated;
  cl1 := ins_transition_claim(cl1.id, 'assessing', 'Assessor appointed');
  perform pg_temp.assert(cl1.status = 'assessing', 'a member can start assessing');
  perform pg_temp.expect_error(format('select ins_transition_claim(%L, ''approved'', null, 100)', cl1.id), 'INS_FORBIDDEN', 'member approving');
  perform pg_temp.expect_error(format('select ins_transition_claim(%L, ''repudiated'', ''no cover'')', cl1.id), 'INS_FORBIDDEN', 'member repudiating');
  perform pg_temp.expect_error(format('select ins_transition_claim(%L, ''assessing'')', cl1.id), 'INS_CLAIM_TRANSITION', 'assessing twice');
  reset role;

  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  perform pg_temp.expect_error(format('select ins_transition_claim(%L, ''approved'')', cl1.id), 'INS_AMOUNT', 'approving with no amount');
  perform pg_temp.expect_error(format('select ins_transition_claim(%L, ''approved'', null, 0)', cl1.id), 'INS_AMOUNT', 'approving zero');
  perform pg_temp.expect_error(format('select ins_transition_claim(%L, ''approved'', null, 60000000)', cl1.id), 'exceeds the policy sum insured', 'approving above the sum insured');
  perform pg_temp.expect_error(format('select ins_transition_claim(%L, ''settled'')', cl1.id), 'INS_CLAIM_TRANSITION', 'settling an unapproved claim');
  perform pg_temp.expect_error(format('select ins_transition_claim(%L, ''closed'')', cl1.id), 'INS_CLAIM_TRANSITION', 'closing an unsettled claim');
  cl1 := ins_transition_claim(cl1.id, 'approved', 'Approved after assessment', 1500000);
  perform pg_temp.assert(cl1.status = 'approved' and cl1.approved_amount = 1500000 and cl1.paid_amount = 0, 'approval records the approved amount');
  perform pg_temp.expect_error(format('select ins_transition_claim(%L, ''repudiated'', ''too late'')', cl1.id), 'INS_CLAIM_TRANSITION', 'repudiating an approved claim');
  cl1 := ins_transition_claim(cl1.id, 'settled');
  perform pg_temp.assert(cl1.status = 'settled' and cl1.paid_amount = 1500000 and cl1.settled_at is not null,
                         'settling sets paid = approved and stamps the settlement date');
  cl1 := ins_transition_claim(cl1.id, 'closed', 'File closed');
  perform pg_temp.assert(cl1.status = 'closed', 'a settled claim closes');
  perform pg_temp.expect_error(format('select ins_transition_claim(%L, ''assessing'')', cl1.id), 'INS_CLAIM_TRANSITION', 'reopening a closed claim');
  reset role;
  perform pg_temp.assert(pg_temp.n_journals(v_ta) = v_j0, 'claim settlement is a status change only: no journal is posted');

  select count(*) into v_n from ins_claim_events where claim_id = cl1.id;
  perform pg_temp.assert(v_n = 5, 'the claim has five audit events, got ' || v_n);
  perform pg_temp.assert(
    (select count(*) from ins_claim_events where claim_id = cl1.id and (
        (from_status is null and to_status = 'notified')
        or (from_status = 'notified' and to_status = 'assessing')
        or (from_status = 'assessing' and to_status = 'approved')
        or (from_status = 'approved' and to_status = 'settled')
        or (from_status = 'settled' and to_status = 'closed'))) = 5,
    'the events form the notified -> assessing -> approved -> settled -> closed chain');
  perform pg_temp.assert((select note from ins_claim_events where claim_id = cl1.id and to_status = 'approved') = 'Approved after assessment'
                         and (select actor_id from ins_claim_events where claim_id = cl1.id and to_status = 'assessing') = u_mem
                         and (select actor_id from ins_claim_events where claim_id = cl1.id and to_status = 'approved') = u_mgr,
                         'events carry the note and the acting user');

  -- Repudiation needs a reason.
  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  perform pg_temp.expect_error(format('select ins_transition_claim(%L, ''repudiated'')', cl2.id), 'INS_NOTE_REQUIRED', 'repudiating without a reason');
  cl2 := ins_transition_claim(cl2.id, 'repudiated', 'Loss not covered by the policy');
  perform pg_temp.assert(cl2.status = 'repudiated' and cl2.approved_amount is null and cl2.paid_amount = 0, 'repudiation moves no money');
  perform pg_temp.expect_error(format('select ins_transition_claim(%L, ''approved'', null, 10)', cl2.id), 'INS_CLAIM_TRANSITION', 'approving a repudiated claim');
  cl2 := ins_transition_claim(cl2.id, 'closed');
  perform pg_temp.assert(cl2.status = 'closed', 'a repudiated claim closes');
  reset role;
  raise notice 'PASS: claim state machine, manager-only decisions, amounts, audit trail, no cash posted';

  -------------------------------------------------------------------
  -- 14. Hand-off to the D4 subledger: settle the bound policy's open items
  -------------------------------------------------------------------
  perform pg_temp.jwt(u_fin);
  set local role authenticated;
  insert into fin_bank_accounts (tenant_id, name, kind, currency, gl_account_id)
  values (v_ta, 'TRUST-UGX', 'client_money', 'UGX', g_trust) returning id into v_trust_bank;
  -- The client pays the gross premium into client money.
  v_s := fin_record_settlement(v_trust_bank, 'in', v_pcli, 1000000, current_date,
           jsonb_build_array(jsonb_build_object('open_item_id', v_item.id, 'amount', 1000000)));
  -- The broker remits the net premium to the insurer from client money.
  v_s := fin_record_settlement(v_trust_bank, 'out', v_pins, 900000, current_date,
           jsonb_build_array(jsonb_build_object('open_item_id', v_item2.id, 'amount', 900000)));
  reset role;
  select * into v_bal from fin_open_item_balances where id = v_item.id;
  perform pg_temp.assert(v_bal.outstanding_amount = 0 and v_bal.settlement_status = 'settled', 'the premium receivable settles from client money');
  select * into v_bal from fin_open_item_balances where id = v_item2.id;
  perform pg_temp.assert(v_bal.outstanding_amount = 0 and v_bal.settlement_status = 'settled', 'the insurer payable settles from client money');
  select coalesce(sum(debit - credit), 0) into v_num from journal_entry_lines where tenant_id = v_ta and gl_account_id = g_trust;
  perform pg_temp.assert(v_num = 100000, 'client money should hold exactly the commission after both settlements, got ' || v_num);
  raise notice 'PASS: bind output settles through the D4 subledger (receipt of gross, remittance of net)';
  v_gaps := v_gaps + 1;
  raise notice 'GAP: % of commission remains in client-money GL 1020 after full settlement; there is no path to move it to the operating account (see docs/insurance-brokerage/ANALYSIS.md section 7)', v_num;

  -------------------------------------------------------------------
  -- 15. Grants, anon and tenant isolation
  -------------------------------------------------------------------
  perform pg_temp.assert(
    not has_function_privilege('anon', 'public.ins_register_client(text,text,text,text,text,text)', 'execute')
    and not has_function_privilege('anon', 'public.ins_create_policy(uuid,uuid,uuid,date,date,numeric,text,numeric,numeric,text,text)', 'execute')
    and not has_function_privilege('anon', 'public.ins_create_renewal_draft(uuid)', 'execute')
    and not has_function_privilege('anon', 'public.ins_bind_policy(uuid)', 'execute')
    and not has_function_privilege('anon', 'public.ins_create_claim(uuid,date,date,text,text,numeric)', 'execute')
    and not has_function_privilege('anon', 'public.ins_transition_claim(uuid,text,text,numeric)', 'execute'),
    'anon must not execute any insurance RPC');
  perform pg_temp.assert(
    has_function_privilege('authenticated', 'public.ins_bind_policy(uuid)', 'execute')
    and not has_function_privilege('authenticated', 'public.ins_ensure_client_account(uuid)', 'execute')
    and not has_function_privilege('authenticated', 'public.ins_ensure_insurer_account(uuid)', 'execute'),
    'clients run the RPCs but not the internal party-account helpers');
  perform pg_temp.assert(
    not has_table_privilege('anon', 'public.ins_policies', 'select')
    and not has_table_privilege('anon', 'public.ins_claims', 'select')
    and not has_table_privilege('anon', 'public.ins_insurers', 'select')
    and not has_table_privilege('anon', 'public.ins_clients', 'select')
    and not has_table_privilege('anon', 'public.ins_product_lines', 'select')
    and not has_table_privilege('anon', 'public.ins_claim_events', 'select')
    and not has_table_privilege('anon', 'public.ins_renewal_pipeline', 'select'),
    'anon must not read any insurance table or view');

  set local role anon;
  perform pg_temp.expect_error('select count(*) from ins_policies', 'permission denied', 'anon reading policies');
  perform pg_temp.expect_error(format('select ins_bind_policy(%L)', p_d.id), 'permission denied', 'anon binding a policy');
  reset role;

  -- The audit trail is read-only for clients. The baseline's default privileges
  -- give `authenticated` ALL on every new public table, so the migration's
  -- "grant select" does not restrict anything: RLS (a SELECT policy only) is the
  -- barrier, and that is what is asserted here, even for the top tier.
  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  perform pg_temp.assert((select count(*) from ins_claim_events where claim_id = cl1.id) = 5, 'a manager reads the claim events');
  perform pg_temp.expect_state(
    format('insert into ins_claim_events (tenant_id, claim_id, to_status) values (%L, %L, ''closed'')', v_ta, cl_ren.id),
    '42501', 'direct claim event insert');
  -- UPDATE and DELETE are revoked from authenticated (20261010120000), so the
  -- privilege check refuses before RLS: 42501, not a silent zero-row result.
  perform pg_temp.expect_state(
    format('update ins_claim_events set note = ''tampered'' where claim_id = %L', cl1.id),
    '42501', 'a manager editing a claim event');
  perform pg_temp.expect_state(
    format('delete from ins_claim_events where claim_id = %L', cl1.id),
    '42501', 'a manager deleting a claim event');
  reset role;
  perform pg_temp.assert(pg_temp.scalar(format('select count(*) from ins_claim_events where claim_id = %L and note = ''tampered''', cl1.id)) = 0
                         and pg_temp.scalar(format('select count(*) from ins_claim_events where claim_id = %L', cl1.id)) = 5,
                         'the claim event trail is intact after the write attempts');
  perform pg_temp.assert(
    not has_table_privilege('authenticated', 'public.ins_claim_events', 'insert')
    and not has_table_privilege('authenticated', 'public.ins_claim_events', 'update')
    and not has_table_privilege('authenticated', 'public.ins_claim_events', 'delete'),
    'authenticated holds no write privilege on the claim audit trail');

  -- Tenant B sees none of tenant A, and cannot act on it.
  perform pg_temp.jwt(u_mgr_b);
  set local role authenticated;
  perform pg_temp.assert((select count(*) from ins_policies where tenant_id = v_ta) = 0
                         and (select count(*) from ins_claims where tenant_id = v_ta) = 0
                         and (select count(*) from ins_claim_events where tenant_id = v_ta) = 0
                         and (select count(*) from ins_clients where tenant_id = v_ta) = 0
                         and (select count(*) from ins_insurers where tenant_id = v_ta) = 0
                         and (select count(*) from ins_product_lines where tenant_id = v_ta) = 0
                         and (select count(*) from ins_renewal_pipeline where tenant_id = v_ta) = 0,
                         'tenant B reads nothing of tenant A');
  perform pg_temp.assert((select count(*) from ins_policies) = 1, 'tenant B sees only its own policy');
  perform pg_temp.expect_state(format('select ins_bind_policy(%L)', p_d.id), '42501', 'tenant B binding tenant A''s policy');
  perform pg_temp.expect_error(format('select ins_create_renewal_draft(%L)', p1.id), 'INS_NOT_FOUND', 'tenant B renewing tenant A''s policy');
  perform pg_temp.expect_error(format('select pg_temp.newclaim(%L, current_date - 5, current_date, ''Loss'', 0)', p1.id), 'INS_NOT_FOUND: policy', 'tenant B claiming on tenant A''s policy');
  perform pg_temp.expect_error(format('select ins_transition_claim(%L, ''assessing'')', cl_ren.id), 'INS_NOT_FOUND: claim', 'tenant B moving tenant A''s claim');
  perform pg_temp.expect_error(
    format('select pg_temp.newpol(%L, %L, %L, current_date, current_date + 365, 1, 1, 10)', c1.id, v_insr, v_pl),
    'INS_NOT_FOUND', 'tenant B creating a policy from tenant A''s master data');
  update ins_policies set notes = 'cross-tenant' where id = p_d.id;
  get diagnostics v_n = row_count;
  perform pg_temp.assert(v_n = 0, 'tenant B cannot update tenant A''s draft');
  reset role;

  -- The outsider holds no insurance role at all.
  perform pg_temp.jwt(u_out);
  set local role authenticated;
  perform pg_temp.assert((select count(*) from ins_policies) = 0 and (select count(*) from ins_claims) = 0
                         and (select count(*) from ins_clients) = 0 and (select count(*) from ins_renewal_pipeline) = 0
                         and (select count(*) from ins_claim_events) = 0,
                         'a user with no insurance role reads nothing');
  perform pg_temp.expect_error(format('select ins_bind_policy(%L)', p_d.id), 'INS_FORBIDDEN', 'outsider binding');
  perform pg_temp.expect_error(format('select ins_create_renewal_draft(%L)', p1.id), 'INS_FORBIDDEN', 'outsider renewing');
  perform pg_temp.expect_error(format('select ins_transition_claim(%L, ''assessing'')', cl_ren.id), 'INS_FORBIDDEN', 'outsider moving a claim');
  reset role;
  raise notice 'PASS: grants, anon, tenant isolation and the no-role user';

  -------------------------------------------------------------------
  -- 16. Known-gap probes. Nothing here fails the run; each probe is rolled
  --     back. A GAP notice means the schema still allows it.
  -------------------------------------------------------------------

  -- G2. A member can repoint renewal_of_id on a draft, so a manager's bind would
  --     mark an unrelated policy renewed.
  v_probe := 'untouched';
  perform pg_temp.jwt(u_mem);
  set local role authenticated;
  begin
    p_x := pg_temp.newpol(c2.id, v_insr, v_pl, current_date, current_date + 365, 1000, 1000, 5);
    update ins_policies set renewal_of_id = p1.id where id = p_x.id;
    get diagnostics v_n = row_count;
    v_probe := case when v_n = 1 then 'allowed' else 'filtered' end;
    raise exception 'probe_done';
  exception when others then
    if sqlerrm <> 'probe_done' then v_probe := 'refused: ' || sqlerrm; end if;
  end;
  reset role;
  if v_probe = 'allowed' then
    v_gaps := v_gaps + 1;
    raise notice 'GAP: a member can set renewal_of_id on a draft; binding it would mark the target policy renewed without a real renewal';
  else
    raise notice 'PASS: renewal_of_id cannot be repointed on a draft (%)', v_probe;
  end if;

  -- G3. A member can move a claim's loss date outside the policy period after
  --     ins_create_claim validated it.
  v_probe := 'untouched';
  perform pg_temp.jwt(u_mem);
  set local role authenticated;
  begin
    update ins_claims set loss_date = p1.inception_date - 200 where id = cl_ren.id;
    get diagnostics v_n = row_count;
    v_probe := case when v_n = 1 then 'allowed' else 'filtered' end;
    raise exception 'probe_done';
  exception when others then
    if sqlerrm <> 'probe_done' then v_probe := 'refused: ' || sqlerrm; end if;
  end;
  reset role;
  if v_probe = 'allowed' then
    v_gaps := v_gaps + 1;
    raise notice 'GAP: a member can edit a claim''s loss_date to a date outside the policy period (ins_create_claim checks it, the update path does not)';
  else
    raise notice 'PASS: claim loss dates stay inside the policy period (%)', v_probe;
  end if;

  -- G4. Claims cannot be deleted: every claim has a creation event with
  --     ON DELETE RESTRICT, so DELETE was revoked from authenticated.
  v_probe := 'untouched';
  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  begin
    cl2 := pg_temp.newclaim(p1.id, current_date - 1, current_date, 'Probe claim', 0);
    delete from ins_claims where id = cl2.id;
    get diagnostics v_n = row_count;
    v_probe := case when v_n = 1 then 'deleted' else 'filtered' end;
    raise exception 'probe_done';
  exception when others then
    if sqlerrm <> 'probe_done' then v_probe := 'refused: ' || sqlerrm; end if;
  end;
  reset role;
  if v_probe like 'refused: permission denied%' then
    raise notice 'PASS: claims cannot be deleted by authenticated (%)', v_probe;
  else
    v_gaps := v_gaps + 1;
    raise notice 'GAP: a manager reached the claim DELETE path although the grant was revoked (%)', v_probe;
  end if;

  raise notice 'ins_core: all assertions passed, % known-gap notice(s)', v_gaps;
  raise notice 'ALL INS_CORE TESTS PASSED';
end
$$;

rollback;