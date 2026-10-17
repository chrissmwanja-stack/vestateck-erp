-- Policy reversal regression suite. Local/test stack only; transaction rolls back.
\set ON_ERROR_STOP on

begin;

-- Test fixture: a motor policy needs an issued certificate before it binds.
-- No-op unless the caller manages insurance, the policy is a draft on the MOTOR line,
-- and no certificate is attached yet.
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

-- Test-only fixture adapter: exercise the real maker/checker RPCs. The second
-- Finance identity is created inside this rolled-back test, never in a migration.
create function pg_temp.policy_cash_settle(p_bank uuid,p_dir text,p_party uuid,p_item uuid,p_amount numeric)
returns public.fin_settlements language plpgsql security definer set search_path=public,pg_temp as $$
declare i fin_open_items%rowtype; checker uuid; claims text := current_setting('request.jwt.claims',true);
  q ins_policy_cash_requests%rowtype; s fin_settlements%rowtype;
begin
  select * into i from fin_open_items where id=p_item;
  if i.source_type not in ('ins_policy_premium','ins_policy_insurer') then
    return fin_record_settlement(p_bank,p_dir,p_party,p_amount,current_date,
      jsonb_build_array(jsonb_build_object('open_item_id',p_item,'amount',p_amount)));
  end if;
  if p_party<>i.party_account_id then raise exception 'test fixture party mismatch'; end if;
  select id into checker from app_users where tenant_id=i.tenant_id
    and email='policy-cash-checker-'||i.tenant_id||'@test.local';
  if checker is null then
    checker := gen_random_uuid();
    insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data,aud,role,created_at,updated_at)
      values(checker,'policy-cash-checker-'||i.tenant_id||'@test.local','{}','{}','authenticated','authenticated',now(),now());
    insert into app_users(id,tenant_id,name,email) values(checker,i.tenant_id,'Cash checker fixture','policy-cash-checker-'||i.tenant_id||'@test.local')
      on conflict(id) do update set tenant_id=excluded.tenant_id,email=excluded.email;
    insert into finance_team_members(tenant_id,user_id,role) values(i.tenant_id,checker,'finance');
  end if;
  q := ins_submit_policy_cash_request(i.source_id,case p_dir when 'in' then 'receipt' else 'remittance' end,
    p_bank,p_amount,current_date,gen_random_uuid());
  perform pg_temp.jwt(checker);
  q := ins_decide_policy_cash_request(q.id,'approve');
  select * into s from fin_settlements where id=q.settlement_id;
  perform set_config('request.jwt.claims',claims,true);
  return s;
exception when others then
  perform set_config('request.jwt.claims',claims,true);
  raise;
end $$;

create function pg_temp.pay(p_bank uuid,p_dir text,p_party uuid,p_item uuid,p_amount numeric)
returns public.fin_settlements language sql as $$
 select * from pg_temp.policy_cash_settle(p_bank,p_dir,p_party,p_item,p_amount) $$;

-- Reproduce the historical income-at-bind journal using the original bind implementation.
create or replace function pg_temp.legacy_bind(p_policy_id uuid)
returns public.ins_policies
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_pol        ins_policies%rowtype;
  v_client     ins_clients%rowtype;
  v_client_nm  text;
  v_comm       numeric(18,2);
  v_net        numeric(18,2);
  v_ar_acc     uuid;
  v_ins_acc    uuid;
  v_ar_gl      uuid;
  v_payable_gl uuid;
  v_comm_gl    uuid;
  v_lines      jsonb;
  v_je         journal_entries;
  v_desc       text;
begin
  if not can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: only insurance admins and managers can bind policies' using errcode = '42501';
  end if;

  select * into v_pol from ins_policies where id = p_policy_id for update;
  if not found then
    raise exception 'INS_NOT_FOUND: policy';
  end if;
  perform assert_tenant_access(v_pol.tenant_id);

  if v_pol.status <> 'draft' then
    raise exception 'INS_NOT_DRAFT: policy % is already %', v_pol.policy_no, v_pol.status;
  end if;
  if v_pol.gross_premium <= 0 then
    raise exception 'INS_PREMIUM_REQUIRED: enter the gross premium before binding';
  end if;

  v_comm := round(v_pol.gross_premium * v_pol.commission_rate_pct / 100, 2);
  v_net  := v_pol.gross_premium - v_comm;
  if v_net <= 0 then
    raise exception 'INS_COMMISSION_TOO_HIGH: commission would leave nothing to remit to the insurer';
  end if;

  -- Posting roles from the tenant's chart. Missing roles stop the bind.
  v_ar_gl      := get_posting_account(v_pol.tenant_id, 'ar_control');
  v_payable_gl := get_posting_account(v_pol.tenant_id, 'insurer_payable');
  v_comm_gl    := get_posting_account(v_pol.tenant_id, 'commission_income');
  if v_ar_gl is null or v_payable_gl is null or (v_comm > 0 and v_comm_gl is null) then
    raise exception 'INS_POSTING_RULE_MISSING: the chart of accounts needs ar_control, insurer_payable and commission_income';
  end if;

  select * into v_client from ins_clients where id = v_pol.client_id;
  select name into v_client_nm from bd_clients where id = v_client.client_id;
  v_ar_acc  := ins_ensure_client_account(v_pol.client_id);
  v_ins_acc := ins_ensure_insurer_account(v_pol.insurer_id);

  v_desc := 'Bind ' || v_pol.policy_no || ' (' || coalesce(v_client_nm, 'client') || ')';
  v_lines := jsonb_build_array(
    jsonb_build_object('gl_account_id', v_ar_gl, 'debit', v_pol.gross_premium, 'description', v_desc),
    jsonb_build_object('gl_account_id', v_payable_gl, 'credit', v_net, 'description', v_desc)
  );
  if v_comm > 0 then
    v_lines := v_lines || jsonb_build_array(
      jsonb_build_object('gl_account_id', v_comm_gl, 'credit', v_comm, 'description', v_desc)
    );
  end if;

  -- Booked on the inception date, so the period-close check applies to it.
  v_je := post_journal_entry(v_pol.tenant_id, 'ins_policy_bind', v_pol.id, v_pol.inception_date, v_desc, v_lines);

  perform fin_create_open_item(
    v_pol.tenant_id, v_ar_acc, 'ar_control', 'ins_policy_premium', v_pol.id,
    v_pol.policy_no, v_pol.inception_date, v_pol.inception_date, v_pol.gross_premium,
    'Premium due: ' || v_pol.policy_no
  );
  perform fin_create_open_item(
    v_pol.tenant_id, v_ins_acc, 'insurer_payable', 'ins_policy_insurer', v_pol.id,
    v_pol.policy_no, v_pol.inception_date, v_pol.inception_date, v_net,
    'Net premium payable to insurer: ' || v_pol.policy_no
  );

  perform set_config('ins.via_rpc', 'on', true);
  update ins_policies
     set status = 'active',
         commission_amount = v_comm,
         net_premium_to_insurer = v_net,
         bound_at = now(),
         bound_by = auth.uid(),
         journal_entry_id = v_je.id
   where id = v_pol.id
  returning * into v_pol;

  if v_pol.renewal_of_id is not null then
    update ins_policies set status = 'renewed'
     where id = v_pol.renewal_of_id and tenant_id = v_pol.tenant_id and status = 'active';
  end if;

  return v_pol;
end;
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
  g_bank uuid; g_trust uuid; g_ar uuid; g_pay uuid; g_inc uuid; g_unear uuid; gb_ar uuid; gb_inc uuid;
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
  rev ins_policy_reversals%rowtype; again ins_policy_reversals%rowtype;
  req uuid := gen_random_uuid(); cn fin_credit_notes%rowtype;
  s_out fin_settlements%rowtype; tr ins_commission_transfers%rowtype;
  v_oper_bank uuid; item_a uuid; item_b uuid; cnt integer;
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
  -- insurer_payable 2010, unearned_commission 2020, commission_income 4000, client money in 1020.
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '1000', 'Operating Bank', 'asset') returning id into g_bank;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '1020', 'Client Money Bank (Premium Trust)', 'asset') returning id into g_trust;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '1100', 'Accounts Receivable Control', 'asset') returning id into g_ar;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '2010', 'Insurer Payable', 'liability') returning id into g_pay;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '4000', 'Commission Income', 'revenue') returning id into g_inc;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '2020', 'Unearned Commission', 'liability') returning id into g_unear;
  insert into gl_posting_rules (tenant_id, account_role, gl_account_id) values
    (v_ta, 'bank', g_bank), (v_ta, 'client_money_bank', g_trust), (v_ta, 'ar_control', g_ar),
    (v_ta, 'insurer_payable', g_pay), (v_ta, 'commission_income', g_inc), (v_ta, 'unearned_commission', g_unear);

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
  perform pg_temp.jwt(u_mgr);
  set local role authenticated;
  insert into ins_product_lines(tenant_id,code,name) values(v_ta,'MOTOR','Motor') returning id into v_pl;
  insert into ins_insurers(tenant_id,code,name) values(v_ta,'ALPHA','Alpha') returning id into v_insr;
  c1:=ins_register_client('Reversal test client');
  p1:=pg_temp.newpol(c1.id,v_insr,v_pl,current_date-10,current_date+355,5000000,1000000,10);
  perform pg_temp.motor_cert(p1.id); p1:=ins_bind_policy(p1.id);
  reset role;
  insert into accounting_periods(tenant_id,period_start,period_end,status) values(v_ta,current_date-10,current_date-10,'closed');
  -- Use the template's real control flag, not permissive test fixtures.
  update gl_accounts set is_control_account=true where id=g_unear;
  perform pg_temp.jwt(u_fin);
  set local role authenticated;
  perform pg_temp.expect_error(format('select fin_raise_credit_note(''ar_control'',%L,1000000,current_date,%L,%L::jsonb,''normal note'')',
    (select party_account_id from ins_clients where id=c1.id),g_unear,
    jsonb_build_array(jsonb_build_object('open_item_id',(select id from fin_open_items where source_id=p1.id and source_type='ins_policy_premium'),'amount',1000000))),
    'CREDIT_NOTE_OFFSET','ordinary credit notes cannot bypass control offsets');
  reset role;
  perform pg_temp.jwt(u_mem); set local role authenticated;
  perform pg_temp.expect_state(format('select ins_reverse_policy(%L,''Correct premium'',false,%L)',p1.id,req),'42501','member reversal');
  reset role;
  perform pg_temp.jwt(u_mgr_b); set local role authenticated;
  perform pg_temp.expect_error(format('select ins_reverse_policy(%L,''Correct premium'',false,%L)',p1.id,req),'INS_NOT_FOUND','cross-tenant reversal');
  reset role;
  perform pg_temp.jwt(u_mgr); set local role authenticated;
  perform pg_temp.assert((ins_policy_reversal_eligibility(p1.id)->>'eligible')::boolean,'eligible untouched policy');
  rev:=ins_reverse_policy(p1.id,'Correct premium',false,req);
  again:=ins_reverse_policy(p1.id,'Correct premium',false,req);
  perform pg_temp.assert(rev.id=again.id,'equivalent retry returns original result');
  perform pg_temp.expect_error(format('select ins_reverse_policy(%L,''Correct premium'',true,%L)',p1.id,req),'INS_REVERSAL_DUPLICATE','conflicting retry');
  reset role;
  perform pg_temp.assert(rev.accounting_treatment='deferred' and rev.reversal_date=current_date
    and rev.replacement_policy_id is null and rev.outcome='posted','current-date reversal-only record');
  perform pg_temp.assert((select status from ins_policies where id=p1.id)='reversed','original inactive');
  perform pg_temp.assert(not exists(select gl_account_id from journal_entry_lines
    where journal_entry_id in(p1.journal_entry_id,rev.premium_journal_entry_id,rev.insurer_journal_entry_id)
    group by gl_account_id having sum(debit-credit)<>0),'aggregate inverse by account');
  perform pg_temp.assert(not exists(select 1 from fin_open_item_balances where source_id=p1.id and outstanding_amount<>0),'both items consumed');
  perform pg_temp.assert(not exists(select 1 from ins_commission_ledger where policy_id=p1.id),'reversed commission excluded from ledger');
  set constraints all immediate;
  set constraints all deferred;
  raise notice 'PASS: balances, current date, role/tenant denial, idempotent retry and note isolation';

  perform pg_temp.jwt(u_fin); set local role authenticated;
  perform pg_temp.expect_error(format('select fin_void_credit_note(%L,''Undo one side'')',rev.premium_credit_note_id),'INS_REVERSAL_NOTE_LOCKED','premium note cannot void');
  perform pg_temp.expect_error(format('select fin_void_credit_note(%L,''Undo one side'')',rev.insurer_credit_note_id),'INS_REVERSAL_NOTE_LOCKED','insurer note cannot void');
  perform pg_temp.expect_error(format('select void_journal_entry(%L,''Undo one side'')',rev.premium_journal_entry_id),'INS_REVERSAL_JOURNAL_LOCKED','independent journal void');
  reset role;
  perform pg_temp.jwt(u_mgr); set local role authenticated;
  perform pg_temp.expect_error(format('select pg_temp.newclaim(%L,current_date,current_date,''Late claim'',0)',p1.id),'INS_POLICY_UNAVAILABLE','claim after reversal');
  perform pg_temp.expect_error(format('select ins_create_renewal_draft(%L)',p1.id),'INS_RENEWAL_STATE','renewal after reversal');
  p_d:=pg_temp.newpol(c1.id,v_insr,v_pl,current_date,current_date+365,5000000,200000,10);
  perform pg_temp.motor_cert(p_d.id); p_d:=ins_bind_policy(p_d.id);
  rev:=ins_reverse_policy(p_d.id,'Replacement requested',true,gen_random_uuid());
  reset role;
  perform pg_temp.assert((select status='draft' and journal_entry_id is null from ins_policies where id=rev.replacement_policy_id),'replacement stays draft');
  perform pg_temp.assert(pg_temp.n_items_for(rev.replacement_policy_id)=0,'replacement has no bound items');
  raise notice 'PASS: immutable note/journal links, post-reversal claims and optional draft';

  -- Any claim and either direction of renewal chain blocks.
  perform pg_temp.jwt(u_mgr); set local role authenticated;
  p_x:=pg_temp.newpol(c1.id,v_insr,v_pl,current_date,current_date+365,5000000,200000,10); perform pg_temp.motor_cert(p_x.id); p_x:=ins_bind_policy(p_x.id);
  cl1:=pg_temp.newclaim(p_x.id,current_date,current_date,'Existing claim',0);
  perform pg_temp.expect_error(format('select ins_reverse_policy(%L,''Has a claim'',false,%L)',p_x.id,gen_random_uuid()),'INS_REVERSAL_CLAIM','claim blocker');
  p_x:=pg_temp.newpol(c1.id,v_insr,v_pl,current_date,current_date+365,5000000,200000,10); perform pg_temp.motor_cert(p_x.id); p_x:=ins_bind_policy(p_x.id);
  p_ren:=ins_create_renewal_draft(p_x.id);
  perform pg_temp.expect_error(format('select ins_reverse_policy(%L,''Has a renewal'',false,%L)',p_x.id,gen_random_uuid()),'INS_REVERSAL_RENEWAL','renewal blocker');
  p_x:=pg_temp.newpol(c1.id,v_insr,v_pl,current_date,current_date+365,5000000,200000,0); perform pg_temp.motor_cert(p_x.id); p_x:=ins_bind_policy(p_x.id);
  rev:=ins_reverse_policy(p_x.id,'Zero commission correction',false,gen_random_uuid());
  perform pg_temp.assert(rev.accounting_treatment='none','zero commission represented explicitly');
  reset role;
  raise notice 'PASS: claims, renewals, zero commission';
  perform pg_temp.jwt(u_mgr); set local role authenticated;
  p_x:=pg_temp.newpol(c1.id,v_insr,v_pl,current_date,current_date+365,5000000,200000,10);
  p_x:=pg_temp.legacy_bind(p_x.id);
  rev:=ins_reverse_policy(p_x.id,'Legacy journal correction',false,gen_random_uuid());
  perform pg_temp.assert(rev.accounting_treatment='legacy','legacy detected from historical bind journal');
  reset role;
  raise notice 'PASS: legacy income-at-bind accounting';


  -- Effective payment blocks, fully voided movement allows reversal.
  perform pg_temp.jwt(u_mgr); set local role authenticated;
  p_x:=pg_temp.newpol(c1.id,v_insr,v_pl,current_date,current_date+365,5000000,1000000,10); perform pg_temp.motor_cert(p_x.id); p_x:=ins_bind_policy(p_x.id);
  reset role;
  select party_account_id into v_pcli from ins_clients where id=c1.id;
  select party_account_id into v_pins from ins_insurers where id=v_insr;
  select id into item_a from fin_open_items where source_id=p_x.id and source_type='ins_policy_premium';
  select id into item_b from fin_open_items where source_id=p_x.id and source_type='ins_policy_insurer';
  perform pg_temp.jwt(u_fin); set local role authenticated;
  insert into fin_bank_accounts(tenant_id,name,kind,currency,gl_account_id) values(v_ta,'REV-TRUST','client_money','UGX',g_trust) returning id into v_trust_bank;
  insert into fin_bank_accounts(tenant_id,name,kind,currency,gl_account_id) values(v_ta,'REV-OPER','operating','UGX',g_bank) returning id into v_oper_bank;
  v_s:=pg_temp.pay(v_trust_bank,'in',v_pcli,item_a,1000000);
  s_out:=pg_temp.pay(v_trust_bank,'out',v_pins,item_b,900000);
  reset role;
  perform pg_temp.jwt(u_mgr); set local role authenticated;
  perform pg_temp.expect_error(format('select ins_reverse_policy(%L,''Paid policy'',false,%L)',p_x.id,gen_random_uuid()),'INS_REVERSAL_MOVEMENT','posted allocations block');
  tr:=ins_transfer_earned_commission(v_trust_bank,v_oper_bank,current_date);
  perform ins_void_commission_transfer(tr.id,'Undo test transfer');
  reset role;
  perform pg_temp.jwt(u_fin); set local role authenticated;
  perform fin_void_settlement(s_out.id,'Undo insurer payment');
  perform fin_void_settlement(v_s.id,'Undo premium receipt');
  reset role;
  perform pg_temp.jwt(u_mgr); set local role authenticated;
  rev:=ins_reverse_policy(p_x.id,'All movements voided',false,gen_random_uuid());
  reset role;
  perform pg_temp.assert(rev.outcome='posted','voided payment, recognition and transfer not permanent blockers');
  raise notice 'PASS: effective movement vs fully voided lifecycle';

  -- Reissue validation failure rolls back both notes and reversal row.
  perform pg_temp.jwt(u_mgr); set local role authenticated;
  p_x:=pg_temp.newpol(c1.id,v_insr,v_pl,current_date,current_date+365,5000000,200000,10); perform pg_temp.motor_cert(p_x.id); p_x:=ins_bind_policy(p_x.id);
  update ins_insurers set is_active=false where id=v_insr;
  reset role;
  cnt:=pg_temp.n_journals(v_ta);
  perform pg_temp.jwt(u_mgr); set local role authenticated;
  perform pg_temp.expect_error(format('select ins_reverse_policy(%L,''Invalid replacement'',true,%L)',p_x.id,gen_random_uuid()),'INS_NOT_FOUND: active insurer','replacement validation rollback');
  reset role;
  perform pg_temp.assert(pg_temp.n_journals(v_ta)=cnt and not exists(select 1 from ins_policy_reversals where original_policy_id=p_x.id)
    and (select status from ins_policies where id=p_x.id)='active','failed reissue leaves nothing behind');
  update ins_insurers set is_active=true where id=v_insr;
  perform pg_temp.jwt(u_fin); set local role authenticated;
  cn:=fin_raise_credit_note('ar_control',v_pcli,20000,current_date,g_inc,
    jsonb_build_array(jsonb_build_object('open_item_id',
      (select id from fin_open_items where source_id=p_x.id and source_type='ins_policy_premium'),'amount',20000)), 'Ordinary adjustment');
  reset role;
  perform pg_temp.jwt(u_mgr); set local role authenticated;
  perform pg_temp.expect_error(format('select ins_reverse_policy(%L,''Credited policy'',false,%L)',p_x.id,gen_random_uuid()),
    'INS_REVERSAL_MOVEMENT','posted credit application blocks reversal');
  reset role;

  insert into accounting_periods(tenant_id,period_start,period_end,status) values(v_ta,current_date,current_date,'closed');
  perform pg_temp.jwt(u_mgr); set local role authenticated;
  perform pg_temp.expect_error(format('select ins_reverse_policy(%L,''Closed period'',false,%L)',p_x.id,gen_random_uuid()),'INS_REVERSAL_PERIOD','current period blocker');
  reset role;
  perform pg_temp.assert(not has_function_privilege('authenticated',
    'public.platform_fin_raise_policy_credit_note_impl(uuid,text,uuid,numeric,date,uuid,jsonb,text,text,uuid)','execute')
    and not has_function_privilege('anon','public.ins_reverse_policy(uuid,text,boolean,uuid)','execute'),'internal helper and anonymous call revoked');
  raise notice 'PASS: rollback, closed period and internal-only exemption';
end $$;
rollback;
