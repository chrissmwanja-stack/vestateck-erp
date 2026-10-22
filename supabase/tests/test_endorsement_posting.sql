-- Endorsements, slice E2: Finance posting of prepared proposals (UGX first).
-- (ins_prepare_policy_endorsement, ins_decide_policy_endorsement, the
-- endorsement commission entries and their recognition, the credit notes and
-- clawbacks on returns, and the statement/cash integration.)
--
-- Covers: the Finance maker/checker shell (preparation, independent approval,
-- self-approval and state rules, stale recalculation, the reviewed-calculation
-- exception, retry idempotency after posting, END- numbering), the additional
-- side (journal legs, client and insurer items, a new deferred commission
-- entry earned by the endorsement's own insurer item and only by it), the
-- return side (credit notes at the booked rates capped at each item's
-- outstanding, recovery items for the excess, clawbacks from the deferred
-- pool first and from earned commission income afterwards, recorded in the
-- clawback ledger), the clearing account netting to zero, descriptive-only
-- endorsements that post nothing, the interim cancellation block, the
-- currency guard, and the statement view netting posted deltas.
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

-- A policy cash request through the real maker/checker path (the bind items
-- refuse generic settlements without an approved request).
create function pg_temp.policy_cash(p_policy uuid, p_kind text, p_bank uuid, p_amount numeric)
returns public.fin_settlements language plpgsql security definer set search_path=public,pg_temp as $$
declare
  q ins_policy_cash_requests%rowtype; s fin_settlements%rowtype;
  maker uuid; checker uuid; claims text := current_setting('request.jwt.claims', true);
begin
  select id into maker from app_users where name = 'EP Fin Maker';
  select id into checker from app_users where name = 'EP Fin Check';
  perform pg_temp.jwt(maker);
  q := ins_submit_policy_cash_request(p_policy, p_kind, p_bank, p_amount, current_date, gen_random_uuid());
  perform pg_temp.jwt(checker);
  q := ins_decide_policy_cash_request(q.id, 'approve');
  select * into s from fin_settlements where id = q.settlement_id;
  perform set_config('request.jwt.claims', claims, true);
  return s;
exception when others then
  perform set_config('request.jwt.claims', claims, true);
  raise;
end $$;

-- A generic settlement against one open item (the way money moves outside the
-- bind-item cash request layer).
create function pg_temp.pay(p_bank uuid, p_dir text, p_party uuid, p_item uuid, p_amount numeric)
returns public.fin_settlements language sql as $$
  select public.fin_record_settlement(p_bank, p_dir, p_party, p_amount, current_date,
    jsonb_build_array(jsonb_build_object('open_item_id', p_item, 'amount', p_amount)),
    'test', 'endorsement posting test');
$$;

do $$
declare
  ta   uuid := gen_random_uuid();
  tb   uuid := gen_random_uuid();
  mgr  uuid := gen_random_uuid();  -- insurance manager: proposes
  fin1 uuid := gen_random_uuid();  -- finance maker: prepares
  fin2 uuid := gen_random_uuid();  -- finance checker: decides
  mem  uuid := gen_random_uuid();  -- insurance member: no money rights
  out_ uuid := gen_random_uuid();
  ub   uuid := gen_random_uuid();
  v_branch uuid; v_line uuid; v_alpha uuid; v_client uuid;
  v_ar uuid; v_payable uuid; v_unearned uuid; v_income uuid; v_clearing uuid; v_bank_gl uuid; v_bank uuid;
  pa ins_policies%rowtype; pb ins_policies%rowtype; pc ins_policies%rowtype;
  e1 ins_policy_endorsements%rowtype; e2 ins_policy_endorsements%rowtype;
  q jsonb; n integer; amt numeric; st text; v_client_end uuid;
  v_item uuid; v_entry uuid; v_client_item uuid;
begin
  perform set_config('test.approver', fin1::text, true);

  -------------------------------------------------------------------
  -- Fixtures: two tenants. Tenant A gets two bound UGX policies
  -- (gross 1,000,000 / 400,000 at 10% commission) and a full chart
  -- of posting accounts.
  -------------------------------------------------------------------
  insert into tenants (id, name) values (ta, 'Endorse Post Co'), (tb, 'Endorse Post Other');
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token)
  select '00000000-0000-0000-0000-000000000000', x.id, 'authenticated', 'authenticated',
         'ep-' || x.id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')), now(),
         '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
    from (values (mgr), (fin1), (fin2), (mem), (out_), (ub)) as x(id);
  insert into app_users (id, tenant_id, name, email) values
    (mgr,  ta, 'EP Manager',  'ep-' || mgr  || '@test.local'),
    (fin1, ta, 'EP Fin Maker','ep-' || fin1 || '@test.local'),
    (fin2, ta, 'EP Fin Check','ep-' || fin2 || '@test.local'),
    (mem,  ta, 'EP Member',   'ep-' || mem  || '@test.local'),
    (out_, ta, 'EP Outsider', 'ep-' || out_ || '@test.local'),
    (ub,   tb, 'EP Other',    'ep-' || ub   || '@test.local');
  insert into tenant_modules (tenant_id, module) values (ta, 'insurance'), (tb, 'insurance');
  insert into staff_roles (tenant_id, user_id, module, role) values (ta, mgr, 'insurance', 'manager');
  insert into finance_team_members (tenant_id, user_id, role) values (ta, fin1, 'finance'), (ta, fin2, 'finance');

  -- Chart of accounts + posting rules (bind and endorsement posting need them).
  insert into gl_accounts (tenant_id, account_code, name, account_type) values
    (ta,'1100','AR','asset'), (ta,'2010','Insurer payable','liability'),
    (ta,'2020','Unearned commission','liability'), (ta,'4000','Commission income','revenue'),
    (ta,'2090','Endorsement clearing','liability'), (ta,'1000','Trust bank','asset');
  select id into v_ar        from gl_accounts where tenant_id = ta and account_code = '1100';
  select id into v_payable   from gl_accounts where tenant_id = ta and account_code = '2010';
  select id into v_unearned  from gl_accounts where tenant_id = ta and account_code = '2020';
  select id into v_income    from gl_accounts where tenant_id = ta and account_code = '4000';
  select id into v_clearing  from gl_accounts where tenant_id = ta and account_code = '2090';
  select id into v_bank_gl   from gl_accounts where tenant_id = ta and account_code = '1000';
  insert into gl_posting_rules (tenant_id, account_role, gl_account_id) values
    (ta,'ar_control',v_ar),(ta,'insurer_payable',v_payable),
    (ta,'unearned_commission',v_unearned),(ta,'commission_income',v_income);
  insert into fin_bank_accounts (id, tenant_id, name, kind, currency, gl_account_id, is_active)
  values (gen_random_uuid(), ta, 'Trust UGX', 'client_money', 'UGX', v_bank_gl, true)
  returning id into v_bank;

  -- One USD policy will prove the E2 currency guard: approved rate fixtures
  -- first (the foreign-bind recipe).
  declare reg_id uuid; fx_id uuid;
  begin
    perform set_config('reg.via_rpc', 'on', true);
    perform set_config('fx.via_rpc', 'on', true);
    insert into regulatory_parameters (tenant_id, parameter_key, value_num, effective_from, source_ref)
      values (ta, 'fx.rate_max_age_days', 90, date '2000-01-01', 'UNVERIFIED: test fixture')
      returning id into reg_id;
    update regulatory_parameters set status = 'approved', approved_by = fin1, approved_at = now() where id = reg_id;
    insert into fx_rates (tenant_id, currency, rate_date, rate, source) values (ta, 'USD', current_date - 45, 3600, 'fixture')
      returning id into fx_id;
    update fx_rates set status = 'approved', approved_by = fin1, approved_at = now() where id = fx_id;
    insert into fx_rates (tenant_id, currency, rate_date, rate, source) values (ta, 'USD', current_date - 1, 3700, 'fixture')
      returning id into fx_id;
    update fx_rates set status = 'approved', approved_by = fin1, approved_at = now() where id = fx_id;
    insert into fx_rates (tenant_id, currency, rate_date, rate, source) values (ta, 'USD', current_date, 3800, 'fixture')
      returning id into fx_id;
    update fx_rates set status = 'approved', approved_by = fin1, approved_at = now() where id = fx_id;
    perform set_config('reg.via_rpc', 'off', true);
    perform set_config('fx.via_rpc', 'off', true);
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
    cc := ins_register_client('EP client', 'corporate', null, null, null, 'low');
    v_client := cc.id;
    pa := ins_create_policy(cc.id, v_alpha, v_line, current_date - 45, current_date + 320,
                            50000000, 'UGX', 1000000, 10, v_branch, null, 'EP fleet', null);
    perform pg_temp.motor_cert(pa.id); pa := ins_bind_policy(pa.id);
    pb := ins_create_policy(cc.id, v_alpha, v_line, current_date - 45, current_date + 320,
                            20000000, 'UGX', 400000, 10, v_branch, null, 'EP second', null);
    perform pg_temp.motor_cert(pb.id); pb := ins_bind_policy(pb.id);
    pc := ins_create_policy(cc.id, v_alpha, v_line, current_date - 45, current_date + 320,
                            30000000, 'USD', 10000, 10, v_branch, null, 'EP foreign', null);
    perform pg_temp.motor_cert(pc.id); pc := ins_bind_policy(pc.id);
  end;
  reset role;
  perform pg_temp.assert(pa.status = 'active' and pb.status = 'active' and pc.status = 'active',
    'all three policies bind (the USD one at the inception-date rate)');
  -- The bind items this slice credits against and pays through.
  select id into v_client_item from fin_open_items
   where tenant_id = ta and source_type = 'ins_policy_premium' and source_id = pa.id;
  perform pg_temp.assert(v_client_item is not null, 'the bind premium item exists');

  -------------------------------------------------------------------
  -- 1. The Finance maker/checker shell.
  -------------------------------------------------------------------
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  e1 := ins_propose_policy_endorsement(pa.id, current_date,
    jsonb_build_array(jsonb_build_object('insurer_id', v_alpha::text, 'agreed_delta', '100000')),
    '{}'::jsonb, 'Fleet expansion agreed with Alpha', gen_random_uuid());
  perform pg_temp.expect_error(
    format('select ins_prepare_policy_endorsement(%L::uuid, %L::uuid)', e1.id, v_clearing),
    'INS_CASH_FORBIDDEN', 'a non-Finance user preparing');
  perform pg_temp.expect_error(
    format('select ins_decide_policy_endorsement(%L::uuid, ''approve'', ''Checker approves the expansion'')', e1.id),
    'INS_CASH_FORBIDDEN', 'a non-Finance user deciding');

  perform pg_temp.jwt(fin1);
  e1 := ins_prepare_policy_endorsement(e1.id, v_clearing);
  perform pg_temp.assert(e1.status = 'prepared' and (e1.calculation ->> 'premium_delta')::numeric = 100000,
    'preparation stores the fresh calculation');
  perform pg_temp.assert((e1.accounting_mappings ->> 'clearing')::uuid = v_clearing,
    'preparation stores the posting mappings');
  perform pg_temp.jwt(fin2);
  perform pg_temp.expect_error(
    format('select ins_prepare_policy_endorsement(%L::uuid, %L::uuid)', e1.id, v_clearing),
    'INS_ENDORSEMENT_STATE', 'a second maker re-preparing someone else''s case');
  perform pg_temp.jwt(fin1);

  perform pg_temp.jwt(fin2);
  set local role authenticated;
  perform pg_temp.expect_error(
    format('select ins_decide_policy_endorsement(%L::uuid, ''approve'', ''no'')', e1.id),
    'INS_ENDORSEMENT_INPUT', 'a too-short review note');
  perform pg_temp.expect_error(
    format('select ins_propose_policy_endorsement(%L::uuid, current_date, ''[]''::jsonb, ''{}''::jsonb, ''Proposer cannot decide'', %L::uuid)',
           pa.id, gen_random_uuid()),
    'INS_ENDORSEMENT_EXISTS', 'a second live proposal still refused');
  -- The proposer may neither prepare nor decide their own case.
  perform pg_temp.jwt(fin1);
  perform pg_temp.expect_error(
    format('select ins_decide_policy_endorsement(%L::uuid, ''approve'', ''Maker approves their own preparation'')', e1.id),
    'INS_ENDORSEMENT_SELF_APPROVAL', 'the maker deciding their own preparation');
  raise notice 'PASS: the Finance maker/checker shell holds';

  -------------------------------------------------------------------
  -- 2. The additional side: journal legs, items, a new deferred
  --    commission entry earned by its own insurer item and only by it.
  -------------------------------------------------------------------
  perform pg_temp.jwt(fin2);
  set local role authenticated;
  e1 := ins_decide_policy_endorsement(e1.id, 'approve', 'Checker approves the fleet expansion');
  reset role;  -- ledger reads: commission entries are hidden from finance-only readers
  perform pg_temp.assert(e1.status = 'posted' and e1.endorsement_no ~ '^END-[0-9]{4}-[0-9]{4}$',
    format('the endorsement is posted and numbered (%s)', coalesce(e1.endorsement_no, 'null')));
  perform pg_temp.assert(e1.journal_entry_id is not null and e1.premium_item_id is not null,
    'the posting names its journal and the new premium item');
  -- Journal legs: Dr AR 100,000 / Cr payable 90,000 / Cr unearned 10,000.
  perform pg_temp.assert((select sum((l.debit - l.credit) * case a.account_code when '1100' then 1 else 0 end)
                            from journal_entry_lines l join gl_accounts a on a.id = l.gl_account_id
                           where l.journal_entry_id = e1.journal_entry_id) = 100000,
    'the AR control is debited 100,000');
  perform pg_temp.assert((select sum(l.credit) from journal_entry_lines l join gl_accounts a on a.id = l.gl_account_id
                           where l.journal_entry_id = e1.journal_entry_id and a.account_code = '2010') = 90000,
    'the insurer payable is credited the 90,000 net');
  perform pg_temp.assert((select sum(l.credit) from journal_entry_lines l join gl_accounts a on a.id = l.gl_account_id
                           where l.journal_entry_id = e1.journal_entry_id and a.account_code = '2020') = 10000,
    'unearned commission is credited the 10,000');
  -- Items + registry + the new deferred entry tied to its own item.
  select id into v_item from fin_open_items
   where tenant_id = ta and source_type = 'ins_policy_endorsement_insurer' and document_no = e1.endorsement_no;
  perform pg_temp.assert(v_item is not null, 'the endorsement insurer item exists');
  select id into v_entry from ins_commission_entries
   where policy_id = pa.id and source_open_item_id = v_item;
  perform pg_temp.assert(v_entry is not null, 'the endorsement''s commission entry names its own insurer item');
  perform pg_temp.assert((select amount from ins_commission_entries where id = v_entry) = 10000
     and (select status from ins_commission_entries where id = v_entry) = 'deferred',
    'the endorsement commission is 10,000 and deferred');
  perform pg_temp.assert((select ce.amount from ins_commission_entries ce
                            where ce.policy_id = pa.id and ce.source_open_item_id is null) = 100000,
    'the policy''s own bind entry is untouched');
  raise notice 'PASS: the additional side posts the three legs with its own deferred entry';

  -- Recognition: paying the endorsement's insurer item earns its entry, and
  -- only that entry -- the bind entry waits for its own item.
  perform pg_temp.pay(v_bank, 'out', (select party_account_id from fin_open_items where id = v_item), v_item, 90000);
  -- The client settles the endorsement premium too (a generic receipt against
  -- the endorsement's own client item).
  select id into v_client_end from fin_open_items
   where tenant_id = ta and source_type = 'ins_policy_endorsement'
     and document_no = e1.endorsement_no and side = 'receivable';
  perform pg_temp.pay(v_bank, 'in', (select party_account_id from fin_open_items where id = v_client_end), v_client_end, 100000);
  perform pg_temp.assert((select status from ins_commission_entries where id = v_entry) = 'earned',
    'paying the endorsement item earns the endorsement commission');
  perform pg_temp.assert((select status from ins_commission_entries
                            where policy_id = pa.id and source_open_item_id is null) = 'deferred',
    'the bind entry stays deferred while its own item is unpaid');
  perform pg_temp.assert((select sum(l.debit) from journal_entry_lines l join gl_accounts a on a.id = l.gl_account_id
                           join journal_entries j on j.id = l.journal_entry_id
                          where j.source_type = 'ins_commission_recognition'
                            and a.account_code = '2020'
                            and l.description like '%' || pa.policy_no || '%') = 10000,
    'the recognition journal debits unearned 10,000 at the bound rate');
  raise notice 'PASS: recognition earns the endorsement entry off its own item only';

  -------------------------------------------------------------------
  -- 3. The return side: credit notes at booked rates, capped at the
  --    outstanding, clawbacks deferred-first, clearing nets to zero.
  -------------------------------------------------------------------
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  e2 := ins_propose_policy_endorsement(pa.id, current_date,
    jsonb_build_array(jsonb_build_object('insurer_id', v_alpha::text, 'agreed_delta', '-30000')),
    '{}'::jsonb, 'Two vehicles left the fleet', gen_random_uuid());
  perform pg_temp.jwt(fin1);
  e2 := ins_prepare_policy_endorsement(e2.id, v_clearing);
  perform pg_temp.jwt(fin2);
  e2 := ins_decide_policy_endorsement(e2.id, 'approve', 'Checker approves the fleet reduction');
  reset role;
  perform pg_temp.assert(e2.status = 'posted' and (e2.credit_note_ids)::text <> '[]',
    'the return posts with credit notes');
  -- The client side: 30,000 credited against the original premium item.
  perform pg_temp.assert((select sum((cn ->> 'amount')::numeric) from jsonb_array_elements(e2.credit_note_ids) cn
                           where cn ->> 'side' = 'receivable') = 30000,
    'the client credit note is 30,000');
  -- The insurer side: 27,000 off the payable. The clawback: 3,000 from the
  -- bind entry's deferred pool.
  perform pg_temp.assert((select sum((cn ->> 'amount')::numeric) from jsonb_array_elements(e2.credit_note_ids) cn
                           where cn ->> 'side' = 'payable') = 27000,
    'the insurer credit note is the 27,000 net');
  perform pg_temp.assert((select sum(amount) from ins_endorsement_clawbacks
                           where endorsement_id = e2.id) = 3000,
    'the clawback ledger records 3,000');
  perform pg_temp.assert((select sum(l.debit) from journal_entry_lines l join gl_accounts a on a.id = l.gl_account_id
                           where l.journal_entry_id = e2.journal_entry_id and a.account_code = '2020') = 3000,
    'the clawback debits unearned commission (the deferred pool first)');
  -- The clearing account nets to zero across the endorsement's own journals
  -- (the credit notes' journals ride their note rows).
  perform pg_temp.assert((select coalesce(sum(l.debit - l.credit), 0)
                            from journal_entry_lines l
                           where l.gl_account_id = v_clearing
                             and (l.journal_entry_id = e2.journal_entry_id
                                  or l.journal_entry_id in (select n.journal_entry_id from fin_credit_notes n
                                                             where n.id in (select (c2 ->> 'note_id')::uuid
                                                                            from jsonb_array_elements(e2.credit_note_ids) c2)))) = 0,
    'the clearing account nets to zero across the credit notes and the clawback');
  -- The credit note rides the original item at its booked rate.
  perform pg_temp.assert((select count(*) from fin_credit_applications a
                            where a.credit_note_id in (select (c2 ->> 'note_id')::uuid from jsonb_array_elements(e2.credit_note_ids) c2)
                              and a.open_item_id = v_client_item) = 1,
    'the client credit note is applied to the original premium item');
  raise notice 'PASS: returns credit at the booked rates and claw back the deferred pool first';

  -- A second return claws what is left of the deferred pool.
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  e2 := ins_propose_policy_endorsement(pa.id, current_date,
    jsonb_build_array(jsonb_build_object('insurer_id', v_alpha::text, 'agreed_delta', '-5000')),
    '{}'::jsonb, 'One more vehicle left', gen_random_uuid());
  perform pg_temp.jwt(fin1);
  e2 := ins_prepare_policy_endorsement(e2.id, v_clearing);
  perform pg_temp.jwt(fin2);
  e2 := ins_decide_policy_endorsement(e2.id, 'approve', 'Checker approves the second reduction');
  reset role;
  perform pg_temp.assert((select sum(amount) from ins_endorsement_clawbacks
                           where endorsement_id = e2.id) = 500,
    'the second clawback takes its 500 from what is still deferred');
  raise notice 'PASS: recurring endorsements claw from the honest remaining pool';

  -------------------------------------------------------------------
  -- 4. The earned claw: once the bind commission is earned, a return
  --    debits commission income, not unearned.
  -------------------------------------------------------------------
  select id into v_item from fin_open_items i
   where i.tenant_id = ta and i.source_type = 'ins_policy_insurer' and i.source_id = pa.id;
  -- Collect from the client, then remit the insurer item's remaining
  -- outstanding through the approved policy cash path.
  perform pg_temp.policy_cash(pa.id, 'receipt', v_bank, 875000);
  perform pg_temp.policy_cash(pa.id, 'remittance', v_bank,
                              (select outstanding_amount from fin_open_item_balances where id = v_item));
  perform pg_temp.assert((select status from ins_commission_entries
                            where policy_id = pa.id and source_open_item_id is null) = 'earned',
    'paying the bind insurer item earns the bind commission');
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  set local role authenticated;
  e2 := ins_propose_policy_endorsement(pa.id, current_date,
    jsonb_build_array(jsonb_build_object('insurer_id', v_alpha::text, 'agreed_delta', '-10000')),
    '{}'::jsonb, 'Final vehicle removed from the fleet', gen_random_uuid());
  perform pg_temp.jwt(fin1);
  e2 := ins_prepare_policy_endorsement(e2.id, v_clearing);
  perform pg_temp.jwt(fin2);
  e2 := ins_decide_policy_endorsement(e2.id, 'approve', 'Checker approves the removal');
  reset role;
  perform pg_temp.assert((select sum(l.debit) from journal_entry_lines l join gl_accounts a on a.id = l.gl_account_id
                           where l.journal_entry_id = e2.journal_entry_id and a.account_code = '4000') = 1000,
    'the earned claw debits commission income');
  raise notice 'PASS: earned commission is clawed back through income, honestly';

  -------------------------------------------------------------------
  -- 5. A descriptive-only endorsement posts nothing but its number.
  -------------------------------------------------------------------
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  e2 := ins_propose_policy_endorsement(pa.id, current_date, '[]'::jsonb,
    jsonb_build_object('risk_description', 'Fleet schedule updated with new number plates'),
    'Number plates changed at the registry', gen_random_uuid());
  perform pg_temp.jwt(fin1);
  e2 := ins_prepare_policy_endorsement(e2.id, v_clearing);
  perform pg_temp.jwt(fin2);
  e2 := ins_decide_policy_endorsement(e2.id, 'approve', 'Checker records the descriptive change');
  perform pg_temp.assert(e2.status = 'posted' and e2.endorsement_no is not null
     and e2.journal_entry_id is null and e2.premium_item_id is null
     and (e2.credit_note_ids)::text = '[]',
    'a descriptive endorsement is numbered but posts nothing');
  raise notice 'PASS: descriptive endorsements post nothing but their number';

  -------------------------------------------------------------------
  -- 6. Retry idempotency after posting, and the stale guard.
  -------------------------------------------------------------------
  perform pg_temp.jwt(fin2);
  set local role authenticated;
  e2 := ins_decide_policy_endorsement(e2.id, 'approve', 'Checker records the descriptive change');
  perform pg_temp.assert(e2.status = 'posted', 'the posted approve retry is idempotent');
  perform pg_temp.expect_error(
    format('select ins_decide_policy_endorsement(%L::uuid, ''approve'', ''A different note this time'')', e2.id),
    'INS_ENDORSEMENT_RETRY_CONFLICT', 'a retry with a different payload');
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  e2 := ins_propose_policy_endorsement(pb.id, current_date,
    jsonb_build_array(jsonb_build_object('insurer_id', v_alpha::text, 'agreed_delta', '500000')),
    '{}'::jsonb, 'Vehicle added to the second policy', gen_random_uuid());
  perform pg_temp.jwt(fin1);
  e2 := ins_prepare_policy_endorsement(e2.id, v_clearing);
  perform pg_temp.assert(exists (select 1 from jsonb_array_elements(e2.calculation -> 'shares') sh
                                  where (sh ->> 'requires_review')::boolean),
    'a share delta bigger than the whole share premium demands review');
  -- The world moved under the preparation: the stored calculation no longer
  -- matches what the guard re-derives.
  reset role;
  update ins_policy_endorsements set calculation = calculation || '{"premium_delta":999}'::jsonb where id = e2.id;
  perform pg_temp.jwt(fin2);
  set local role authenticated;
  perform pg_temp.expect_error(
    format('select ins_decide_policy_endorsement(%L::uuid, ''approve'', ''Checker approves on stale numbers'')', e2.id),
    'INS_ENDORSEMENT_STALE', 'deciding on a stale calculation');
  raise notice 'PASS: posted retries are idempotent and stale calculations refuse to post';

  -------------------------------------------------------------------
  -- 7. The reviewed-calculation exception, withdraw-after-prepare,
  --    the interim cancellation block, and the currency guard.
  -------------------------------------------------------------------
  perform pg_temp.jwt(fin1);
  -- Re-preparation (the maker's own case) refreshes the numbers.
  e2 := ins_prepare_policy_endorsement(e2.id, v_clearing);
  perform pg_temp.jwt(fin2);
  perform pg_temp.expect_error(
    format('select ins_decide_policy_endorsement(%L::uuid, ''approve'', ''Approving without accepting the review flag'')', e2.id),
    'INS_ENDORSEMENT_EXCEPTION', 'a reviewed calculation without explicit acceptance');
  e2 := ins_decide_policy_endorsement(e2.id, 'approve', 'Checker accepts the reviewed calculation', true);
  perform pg_temp.assert(e2.status = 'posted', 'the explicit acceptance posts the reviewed case');

  perform pg_temp.jwt(mgr);
  set local role authenticated;
  e2 := ins_propose_policy_endorsement(pb.id, current_date,
    jsonb_build_array(jsonb_build_object('insurer_id', v_alpha::text, 'agreed_delta', '1000')),
    '{}'::jsonb, 'Withdrawable preparation', gen_random_uuid());
  perform pg_temp.jwt(fin1);
  e2 := ins_prepare_policy_endorsement(e2.id, v_clearing);
  perform pg_temp.jwt(mgr);
  perform ins_withdraw_policy_endorsement(e2.id, 'Client changed their mind after preparation');
  select status into st from ins_policy_endorsements where id = e2.id;
  perform pg_temp.assert(st = 'withdrawn', 'the proposer may still withdraw a prepared case');

  -- Through the RPC the cancellation preview refuses first (the posted credit
  -- notes need Finance review); either way a posted-endorsement policy cannot
  -- be cancelled until slice E4.
  perform pg_temp.expect_error(
    format('select ins_submit_policy_cancellation(%L::uuid, current_date,
              jsonb_build_array(jsonb_build_object(''insurer_id'', %L::text, ''terms'',
                jsonb_build_object(''method'', ''manual_review'', ''contract_reference'', ''Alpha agreed cancellation terms'',
                                   ''manual_return_premium'', ''500000''))),
              ''[]''::jsonb, ''Insurer agreed to cancel the policy'', %L::uuid)',
           pa.id, v_alpha::text, gen_random_uuid()),
    'INS_CANCELLATION_REVIEW_REQUIRED', 'cancelling a policy with posted endorsements');
  -- And the cross-guard trigger holds for paths that skip the RPC.
  reset role;
  perform pg_temp.expect_error(
    format('insert into ins_policy_cancellations (tenant_id, policy_id, request_key, reason, effective_date, insurer_terms, charge_refunds, proposed_by, calculation)
            values (%L::uuid, %L::uuid, %L::uuid, ''Raw insert over posted endorsements'', current_date, ''[]''::jsonb, ''[]''::jsonb, %L::uuid, ''{}''::jsonb)',
           ta, pa.id, gen_random_uuid(), fin1),
    'INS_ENDORSEMENT_POSTED', 'a raw cancellation over posted endorsements');
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  raise notice 'PASS: the exception, withdraw-after-prepare and cancellation block hold';

  -------------------------------------------------------------------
  -- 8. Statements and the review position net the posted endorsements.
  -------------------------------------------------------------------
  q := ins_endorsement_review_position(pa.id);
  perform pg_temp.assert((q ->> 'posted_endorsements')::integer = 5,
    format('five posted endorsements on the first policy, got %s', q ->> 'posted_endorsements'));
  perform pg_temp.assert((q ->> 'current_gross_premium')::numeric = 1000000 + 100000 - 30000 - 5000 - 10000,
    'the current premium is bound plus the posted deltas');
  select billed_amount into amt from ins_client_statement where policy_id = pa.id;
  perform pg_temp.assert(amt = 1000000 + 100000 - 30000 - 5000 - 10000,
    format('the statement bills bound plus posted deltas, got %s', coalesce(amt::text, 'null')));
  perform pg_temp.assert(abs((select balance_amount from ins_client_statement where policy_id = pa.id)
     - ((select billed_amount from ins_client_statement where policy_id = pa.id)
        - 975000)) < 0.01,
    'the statement nets the endorsement receipt (and the bind receipt) against the billing');
  raise notice 'PASS: statements and the review position net the posted endorsements';

  -------------------------------------------------------------------
  -- 9. The currency guard (E2 posts in the functional currency only).
  -------------------------------------------------------------------
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  e2 := ins_propose_policy_endorsement(pc.id, current_date,
    jsonb_build_array(jsonb_build_object('insurer_id', v_alpha::text, 'agreed_delta', '1000')),
    '{}'::jsonb, 'Endorsing the USD fleet', gen_random_uuid());
  perform pg_temp.jwt(fin1);
  e2 := ins_prepare_policy_endorsement(e2.id, v_clearing);
  perform pg_temp.jwt(fin2);
  perform pg_temp.expect_error(
    format('select ins_decide_policy_endorsement(%L::uuid, ''approve'', ''Checker approves a foreign endorsement early'')', e2.id),
    'INS_ENDORSEMENT_CURRENCY', 'posting a foreign-currency endorsement');
  raise notice 'PASS: foreign-currency posting waits for slice E3';

  -------------------------------------------------------------------
  -- 10. Access and tenant gates on the new surface.
  -------------------------------------------------------------------
  perform pg_temp.jwt(mem);
  perform pg_temp.expect_error(
    format('select ins_prepare_policy_endorsement(%L::uuid, %L::uuid)',
           (select id from ins_policy_endorsements where policy_id = pc.id limit 1), v_clearing),
    'INS_CASH_FORBIDDEN', 'a non-Finance user preparing');
  reset role;
  perform pg_temp.jwt(mem);
  set local role authenticated;
  perform pg_temp.expect_error(
    format('select ins_decide_policy_endorsement(%L::uuid, ''approve'', ''Member tries to approve something'')',
           (select id from ins_policy_endorsements where policy_id = pa.id order by proposed_at limit 1)),
    'INS_CASH_FORBIDDEN', 'a member-only user deciding');
  reset role;
  perform pg_temp.jwt(ub);
  set local role authenticated;
  select count(*) into n from ins_policy_endorsements where tenant_id = ta;
  perform pg_temp.assert(n = 0, 'tenant B sees none of tenant A endorsements');
  select count(*) into n from ins_endorsement_clawbacks where tenant_id = ta;
  perform pg_temp.assert(n = 0, 'tenant B sees none of tenant A clawbacks');
  reset role;
  raise notice 'PASS: preparation and decisions stay Finance, and tenants stay apart';

  raise notice 'ALL PASS: endorsement posting (E2)';
end
$$;

rollback;
