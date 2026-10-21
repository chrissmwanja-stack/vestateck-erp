-- Phase A, A3 slice 3d-3: the cancellation pipeline on a foreign policy
-- (platform_ins_cancellation_credit returns the original items at their booked rate,
-- the adjustment journal posts in the policy's currency at the cancellation-date
-- rate, recognition happens at the bound rate, and the 3d-2 guard is gone).
--
-- Covers: a fully uncollected USD policy is cancelled through the real
-- submit -> prepare -> approve flow; the client and insurer credit notes take the
-- items' currency, the control sides return the booked rate, the clearing sides take
-- the cancellation-date rate, and the differences book as realised gain or loss; the
-- recovery path creates its item with the booking entry; the clearing account nets to
-- zero in the currency and in base; the control accounts return to zero; the unearned
-- commission keeps the documented base residue (clawback at the cancellation rate
-- against a bind at the bound rate) that period-end revaluation will clear.
--
-- Run against a fresh local stack only (`supabase db reset`). One transaction that
-- ROLLBACKs. Any RAISE EXCEPTION is a real assertion failure.

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

create function pg_temp.net_of(p_account uuid, p_sources uuid[], out ccy_net numeric, out base_net numeric)
language sql as $$
  select coalesce(sum(l.debit - l.credit), 0), coalesce(sum(l.base_debit - l.base_credit), 0)
  from journal_entries e join journal_entry_lines l on l.journal_entry_id = e.id
  where e.source_id = any (p_sources) and l.gl_account_id = p_account
$$;

create function pg_temp.gl_net(p_account uuid, out ccy_net numeric, out base_net numeric)
language sql as $$
  select coalesce(sum(l.debit - l.credit), 0), coalesce(sum(l.base_debit - l.base_credit), 0)
  from journal_entry_lines l where l.gl_account_id = p_account
$$;

create function pg_temp.lines_of(p_source uuid) returns text language sql as $$
  select coalesce(string_agg(format('%s=%s/%s %s@%s base %s/%s', a.account_code, l.debit, l.credit, l.currency, l.fx_rate,
                                    l.base_debit, l.base_credit), ' | ' order by a.account_code, l.debit), '(none)')
  from journal_entries e
  join journal_entry_lines l on l.journal_entry_id = e.id
  join gl_accounts a on a.id = l.gl_account_id
  where e.source_id = p_source
$$;

-- Bind helper: motor policies need an issued certificate (Phase C item 2).
create function pg_temp.motor_cert(p_policy uuid) returns void
language plpgsql as $$
declare
  s text := substr(p_policy::text, 1, 8);
  r uuid; pol ins_policies%rowtype; line_code text;
begin
  if not can_manage_insurance() then return; end if;
  select * into pol from ins_policies where id = p_policy;
  if not found or pol.status <> 'draft' then return; end if;
  select code into line_code from ins_product_lines where id = pol.product_line_id;
  if line_code is distinct from 'MOTOR' then return; end if;
  if exists (select 1 from ins_certificate_stock where policy_id = p_policy and status = 'issued') then return; end if;
  r := ins_register_risk(pol.client_id, pol.product_line_id, 'vehicle', 'FC-test vehicle', null, 'CH' || s, null, null, null, null, 0);
  perform ins_load_certificate_range('CPB' || s || '-', 1, 1, 4);
  perform ins_issue_certificate('CPB' || s || '-0001', r, null);
  perform ins_link_policy_risk(p_policy, r);
  perform ins_attach_certificate(p_policy, 'CPB' || s || '-0001');
end $$;

do $$
declare
  ta    uuid := gen_random_uuid();
  mgr   uuid := gen_random_uuid();
  maker uuid := gen_random_uuid();
  chk   uuid := gen_random_uuid();
  approver uuid := gen_random_uuid();
  g_ops uuid; g_trust_usd uuid; g_ar uuid; g_pay uuid; g_unearned uuid; g_income uuid;
  g_clear uuid; g_ap uuid; g_gain uuid; g_loss uuid;
  reg_id uuid; fx_id uuid;
  b_trust_usd uuid;
  v_branch uuid; v_line uuid; v_insr uuid;
  c ins_clients%rowtype;
  p_usd ins_policies%rowtype;
  it_prem fin_open_items%rowtype; it_ins fin_open_items%rowtype;
  v_cxl ins_policy_cancellations%rowtype;
  terms jsonb;
  cn record;
  n_amount numeric; n_result numeric; n_fx numeric; n_src text;
  r record; n integer; key uuid;
begin
  -------------------------------------------------------------------
  -- Fixtures
  -------------------------------------------------------------------
  insert into tenants (id, name) values (ta, 'Foreign Cancellation Co');
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token)
  select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
         'fc-' || u.id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')), now(),
         '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
    from (values (mgr), (maker), (chk)) as u(id);
  insert into app_users (id, tenant_id, name, email) values
    (mgr,   ta, 'FC manager', 'fc-' || mgr   || '@test.local'),
    (maker, ta, 'FC maker',   'fc-' || maker || '@test.local'),
    (chk,   ta, 'FC checker', 'fc-' || chk   || '@test.local');
  insert into finance_team_members (tenant_id, user_id, role) values (ta, maker, 'finance'), (ta, chk, 'finance');
  insert into tenant_modules (tenant_id, module) values (ta, 'insurance');
  insert into staff_roles (tenant_id, user_id, module, role) values (ta, mgr, 'insurance', 'manager');

  insert into gl_accounts (tenant_id, account_code, name, account_type) values
    (ta,'1000','Operating UGX','asset'), (ta,'1021','Client money USD','asset'),
    (ta,'1100','AR','asset'), (ta,'2010','Insurer payable','liability'),
    (ta,'2020','Unearned commission','liability'), (ta,'4000','Commission income','revenue'),
    (ta,'1199','Cancellation clearing','asset'), (ta,'2000','Refund payables','liability'),
    (ta,'4900','Realised FX gain','revenue'), (ta,'5910','Realised FX loss','expense');
  select id into g_ops        from gl_accounts where tenant_id=ta and account_code='1000';
  select id into g_trust_usd  from gl_accounts where tenant_id=ta and account_code='1021';
  select id into g_ar         from gl_accounts where tenant_id=ta and account_code='1100';
  select id into g_pay        from gl_accounts where tenant_id=ta and account_code='2010';
  select id into g_unearned   from gl_accounts where tenant_id=ta and account_code='2020';
  select id into g_income     from gl_accounts where tenant_id=ta and account_code='4000';
  select id into g_clear      from gl_accounts where tenant_id=ta and account_code='1199';
  select id into g_ap         from gl_accounts where tenant_id=ta and account_code='2000';
  select id into g_gain       from gl_accounts where tenant_id=ta and account_code='4900';
  select id into g_loss       from gl_accounts where tenant_id=ta and account_code='5910';
  insert into gl_posting_rules (tenant_id, account_role, gl_account_id) values
    (ta,'bank',g_ops),(ta,'ar_control',g_ar),(ta,'insurer_payable',g_pay),
    (ta,'unearned_commission',g_unearned),(ta,'commission_income',g_income),(ta,'ap_control',g_ap),
    (ta,'fx_gain_realised',g_gain),(ta,'fx_loss_realised',g_loss);
  insert into fin_bank_accounts (tenant_id, name, kind, currency, gl_account_id) values
    (ta,'FC-TRUST-USD','client_money','USD',g_trust_usd) returning id into b_trust_usd;

  perform set_config('reg.via_rpc', 'on', true);
  perform set_config('fx.via_rpc', 'on', true);
  insert into regulatory_parameters (tenant_id, parameter_key, value_num, effective_from, source_ref)
    values (ta, 'fx.rate_max_age_days', 90, date '2000-01-01', 'UNVERIFIED: test fixture') returning id into reg_id;
  update regulatory_parameters set status = 'approved', approved_by = approver, approved_at = now() where id = reg_id;
  insert into fx_rates (tenant_id, currency, rate_date, rate, source) values (ta, 'USD', current_date - 1, 3700, 'fixture') returning id into fx_id;
  update fx_rates set status = 'approved', approved_by = approver, approved_at = now() where id = fx_id;
  insert into fx_rates (tenant_id, currency, rate_date, rate, source) values (ta, 'USD', current_date, 3800, 'fixture') returning id into fx_id;
  update fx_rates set status = 'approved', approved_by = approver, approved_at = now() where id = fx_id;
  perform set_config('reg.via_rpc', 'off', true);
  perform set_config('fx.via_rpc', 'off', true);

  perform pg_temp.jwt(mgr);
  insert into organizations (tenant_id, company_code, site_name) values (ta, 'KLA', 'Kampala') returning id into v_branch;
  reset role;
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  insert into ins_product_lines (tenant_id, code, name) values (ta, 'MOTOR', 'Motor') returning id into v_line;
  insert into ins_insurers (tenant_id, code, name, default_commission_rate_pct) values (ta, 'ALPHA', 'Alpha Assurance', 10) returning id into v_insr;
  reset role;

  -------------------------------------------------------------------
  -- A fully uncollected USD policy, bound yesterday at 3700.
  -------------------------------------------------------------------
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  declare cc ins_clients%rowtype;
  begin
    cc := ins_register_client('FC client', 'corporate', null, null, null, 'low');
    p_usd := ins_create_policy(cc.id, v_insr, v_line, current_date - 1, current_date + 335,
                               20000, 'USD', 10000, 10, v_branch, null, 'FC fleet', null);
    perform pg_temp.motor_cert(p_usd.id); p_usd := ins_bind_policy(p_usd.id);
  end;
  reset role;
  perform pg_temp.assert(p_usd.status = 'active', 'the USD policy binds');
  select * into it_prem from fin_open_items where source_type = 'ins_policy_premium' and source_id = p_usd.id;
  select * into it_ins  from fin_open_items where source_type = 'ins_policy_insurer'  and source_id = p_usd.id;
  perform pg_temp.assert(it_prem.fx_rate = 3700 and it_ins.fx_rate = 3700, 'the items carry the bound 3700');

  -------------------------------------------------------------------
  -- 1. The guard is gone: an insurance manager submits the cancellation.
  -------------------------------------------------------------------
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  terms := jsonb_build_array(jsonb_build_object(
    'insurer_id', v_insr::text, 'terms',
    jsonb_build_object('method', 'manual_review', 'contract_reference', 'Alpha agreed full cancellation terms',
                       'manual_return_premium', '10000')));
  key := gen_random_uuid();
  v_cxl := ins_submit_policy_cancellation(p_usd.id, current_date, terms, '[]'::jsonb, 'Insurer agreed full cancellation', key);
  reset role;
  perform pg_temp.assert(v_cxl.status = 'proposed', 'the proposal is open');

  -------------------------------------------------------------------
  -- 2. Finance prepares, an independent checker approves.
  -------------------------------------------------------------------
  perform pg_temp.jwt(maker);
  set local role authenticated;
  v_cxl := ins_prepare_policy_cancellation(v_cxl.id, g_clear);
  reset role;
  perform pg_temp.assert(v_cxl.status = 'prepared', 'the proposal is prepared');
  perform pg_temp.jwt(chk);
  set local role authenticated;
  v_cxl := ins_decide_policy_cancellation(v_cxl.id, 'approve', 'Reviewed the insurer cancellation terms', true);
  reset role;
  perform pg_temp.assert(v_cxl.status = 'posted', 'the cancellation posts');
  perform pg_temp.assert((select status from ins_policies where id = p_usd.id) = 'cancelled', 'the policy is cancelled');

  -------------------------------------------------------------------
  -- 3. The credit notes: item currency, control at the booked rate,
  --    clearing at the cancellation date, the difference realised.
  -------------------------------------------------------------------
  select n.amount, n.realised_result, n.fx_rate into n_amount, n_result, n_fx
    from fin_credit_notes n
    join fin_credit_applications a on a.credit_note_id = n.id
    join ins_policy_cash_items k on k.id = a.open_item_id
   where n.reference = v_cxl.cancellation_no and k.source_type = 'ins_policy_premium';
  perform pg_temp.assert(n_amount = 10000 and n_fx = 3800, format('the client note is USD 10,000 at 3800, got %s @ %s', n_amount, n_fx));
  perform pg_temp.assert(n_result = 1000000,
    format('crediting a 3700 receivable at 3800 is a 1,000,000 gain, got %s', n_result));
  select n.amount, n.realised_result into n_amount, n_result
    from fin_credit_notes n
    join fin_credit_applications a on a.credit_note_id = n.id
    join ins_policy_cash_items k on k.id = a.open_item_id
   where n.reference = v_cxl.cancellation_no and k.source_type = 'ins_policy_insurer';
  perform pg_temp.assert(n_amount = 9000 and n_result = -900000,
    format('the insurer note is USD 9,000 with a 900,000 loss, got %s / %s', n_amount, n_result));
  perform pg_temp.assert((select outstanding_amount from fin_open_item_balances where id = it_prem.id) = 0,
    'the premium item must be fully credited');
  perform pg_temp.assert((select outstanding_amount from fin_open_item_balances where id = it_ins.id) = 0,
    'the insurer item must be fully credited');
  -- Whole-account nets: this tenant holds only this policy, so its bind and the two
  -- credit notes are everything these accounts have seen.
  select * into r from pg_temp.gl_net(g_ar);
  perform pg_temp.assert(r.ccy_net = 0 and r.base_net = 0,
    format('AR must return to zero in USD and base, got %s / %s', r.ccy_net, r.base_net));
  select * into r from pg_temp.gl_net(g_pay);
  perform pg_temp.assert(r.ccy_net = 0 and r.base_net = 0,
    format('the insurer payable must return to zero in USD and base, got %s / %s', r.ccy_net, r.base_net));
  raise notice 'PASS: both credit notes return the items at the booked rate and realise the difference';

  -------------------------------------------------------------------
  -- 4. The clearing account nets to zero in the currency and in base.
  -------------------------------------------------------------------
  select * into r from pg_temp.gl_net(g_clear);
  perform pg_temp.assert(r.ccy_net = 0 and r.base_net = 0,
    format('the clearing account must net to zero in USD and base, got %s / %s', r.ccy_net, r.base_net));
  raise notice 'PASS: the clearing account nets to zero in the currency and in base';

  -------------------------------------------------------------------
  -- 5. The adjustment journal: recovery item with the booking entry,
  --    clawback in the policy currency, the documented unearned residue.
  -------------------------------------------------------------------
  -- The insurer's 10,000 return includes the 1,000 clawback, so the insurer is credited
  -- 9,000 and there is no recovery leg.
  perform pg_temp.assert(
    not exists (select 1 from ins_cancellation_insurer_adjustments
                 where cancellation_id = v_cxl.id and recovery_due > 0),
    'a full return with the clawback retained needs no recovery');
  perform pg_temp.assert(
    not exists (select 1 from fin_open_items where source_type = 'ins_cancellation_insurer_recovery'
                 and source_id in (select id from ins_cancellation_insurer_adjustments where cancellation_id = v_cxl.id)),
    'no recovery item must exist');
  perform pg_temp.assert(
    exists (select 1 from journal_entry_lines l where l.journal_entry_id = v_cxl.journal_entry_id
             and l.gl_account_id = g_unearned and l.debit = 1000 and l.currency = 'USD' and l.fx_rate = 3800),
    format('the clawback must debit unearned USD 1,000 at the cancellation rate: %s',
           (select string_agg(format('%s=%s/%s %s@%s', a.account_code, l.debit, l.credit, l.currency, l.fx_rate), ' | ')
            from journal_entry_lines l join gl_accounts a on a.id = l.gl_account_id
            where l.journal_entry_id = v_cxl.journal_entry_id)));
  select * into r from pg_temp.gl_net(g_unearned);
  perform pg_temp.assert(r.ccy_net = 0, format('unearned must net to zero in USD, got %s', r.ccy_net));
  perform pg_temp.assert(r.base_net = 100000,
    format('unearned keeps the documented 100,000 base residue (3e clears it), got %s', r.base_net));
  perform pg_temp.assert((select status from ins_commission_entries where policy_id = p_usd.id) = 'deferred',
    'the commission entry stays deferred');
  select * into r from pg_temp.gl_net(g_gain);
  perform pg_temp.assert(r.base_net = -1000000, format('the realised gain must be a 1,000,000 credit, got %s', r.base_net));
  select * into r from pg_temp.gl_net(g_loss);
  perform pg_temp.assert(r.base_net = 900000, format('the realised loss must be a 900,000 debit, got %s', r.base_net));
  raise notice 'PASS: clawback, no-recovery and the documented unearned residue are all booked';

  raise notice 'ALL PASS: foreign cancellation';
end
$$;

rollback;
