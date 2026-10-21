-- Phase A, A3 slice 3d-2: foreign-currency policy bind, commission transfers and
-- recognition (INS_CURRENCY_UNSUPPORTED is gone; the cancellation pipeline is
-- explicitly guarded until slice 3d-3).
--
-- Covers: a USD policy binds at the inception-date rate with items that carry the bind
-- entry; a functional policy binds exactly as before; paying the USD insurer earns the
-- commission at the rate the policy was bound at; transferring the commission to the
-- operating account books the trust side at the bound rate, the operating side at the
-- transfer-date rate and the difference as realised gain, netting the trust to zero;
-- voiding the settlement reverses the recognition exactly and re-defers the entry;
-- commission earned in another currency cannot be mixed into the transfer; the EUR
-- transfer works through its own accounts; claim recognition accrues in the policy's
-- currency; a cancellation proposal for a foreign policy is refused while a functional
-- one is accepted.
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

create function pg_temp.gl_net(p_account uuid) returns numeric
language sql as $$
  select coalesce(sum(l.debit - l.credit), 0) from journal_entry_lines l where l.gl_account_id = p_account
$$;

create function pg_temp.gl_net_ccy(p_account uuid, p_ccy text) returns numeric
language sql as $$
  select coalesce(sum(l.debit - l.credit), 0) from journal_entry_lines l where l.gl_account_id = p_account and l.currency = p_ccy
$$;

-- Net of one account over specific journal ids (recognition journals are sourced by
-- event id, so source-based nets do not find them).
create function pg_temp.je_of(p_je uuid, p_account uuid, out ccy_net numeric, out base_net numeric)
language sql as $$
  select coalesce(sum(l.debit - l.credit), 0), coalesce(sum(l.base_debit - l.base_credit), 0)
  from journal_entry_lines l where l.journal_entry_id = p_je and l.gl_account_id = p_account
$$;

create function pg_temp.jes_of(p_jes uuid[], p_account uuid, out ccy_net numeric, out base_net numeric)
language sql as $$
  select coalesce(sum(l.debit - l.credit), 0), coalesce(sum(l.base_debit - l.base_credit), 0)
  from journal_entry_lines l where l.journal_entry_id = any (p_jes) and l.gl_account_id = p_account
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
  r := ins_register_risk(pol.client_id, pol.product_line_id, 'vehicle', 'BT-test vehicle', null, 'CH' || s, null, null, null, null, 0);
  perform ins_load_certificate_range('CPB' || s || '-', 1, 1, 4);
  perform ins_issue_certificate('CPB' || s || '-0001', r, null);
  perform ins_link_policy_risk(p_policy, r);
  perform ins_attach_certificate(p_policy, 'CPB' || s || '-0001');
end $$;

do $$
declare
  ta    uuid := gen_random_uuid();
  mgr   uuid := gen_random_uuid();
  mgr2  uuid := gen_random_uuid();
  maker uuid := gen_random_uuid();
  chk   uuid := gen_random_uuid();
  approver uuid := gen_random_uuid();
  g_ops uuid; g_trust_ugx uuid; g_trust_usd uuid; g_ops_usd uuid; g_trust_eur uuid; g_ops_eur uuid;
  g_ar uuid; g_pay uuid; g_unearned uuid; g_income uuid; g_crecv uuid; g_cpay uuid;
  g_gain uuid; g_loss uuid; g_other uuid;
  reg_id uuid; fx_id uuid;
  b_trust_ugx uuid; b_trust_usd uuid; b_ops_usd uuid; b_trust_eur uuid; b_ops_eur uuid;
  v_branch uuid; v_line uuid; v_insr uuid;
  c ins_clients%rowtype;
  p_usd ins_policies%rowtype; p_eur ins_policies%rowtype; p_ugx ins_policies%rowtype;
  it_usd fin_open_items%rowtype; it_prem fin_open_items%rowtype;
  v_je journal_entries%rowtype;
  st fin_settlements%rowtype;
  tr ins_commission_transfers%rowtype;
  ce_usd uuid; ce_eur uuid;
  v_rec_je uuid;
  q ins_policy_cash_requests%rowtype;
  cl ins_claims%rowtype;
  r record; n integer;
begin
  -------------------------------------------------------------------
  -- Fixtures
  -------------------------------------------------------------------
  insert into tenants (id, name) values (ta, 'Bind Transfer Co');
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token)
  select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
         'bt-' || u.id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')), now(),
         '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
    from (values (mgr), (mgr2), (maker), (chk)) as u(id);
  insert into app_users (id, tenant_id, name, email) values
    (mgr,   ta, 'BT manager',  'bt-' || mgr   || '@test.local'),
    (mgr2,  ta, 'BT manager 2','bt-' || mgr2  || '@test.local'),
    (maker, ta, 'BT maker',    'bt-' || maker || '@test.local'),
    (chk,   ta, 'BT checker',  'bt-' || chk   || '@test.local');
  insert into finance_team_members (tenant_id, user_id, role) values (ta, maker, 'finance'), (ta, chk, 'finance');
  insert into tenant_modules (tenant_id, module) values (ta, 'insurance');
  insert into staff_roles (tenant_id, user_id, module, role) values (ta, mgr, 'insurance', 'manager'), (ta, mgr2, 'insurance', 'manager');

  insert into gl_accounts (tenant_id, account_code, name, account_type) values
    (ta,'1000','Operating UGX','asset'), (ta,'1020','Client money UGX','asset'),
    (ta,'1021','Client money USD','asset'), (ta,'1031','Operating USD','asset'),
    (ta,'1022','Client money EUR','asset'), (ta,'1032','Operating EUR','asset'),
    (ta,'1100','AR','asset'), (ta,'2010','Insurer payable','liability'),
    (ta,'2020','Unearned commission','liability'), (ta,'4000','Commission income','revenue'),
    (ta,'1130','Insurer claim receivable','asset'), (ta,'2310','Client claim payable','liability'),
    (ta,'4900','Realised FX gain','revenue'), (ta,'5910','Realised FX loss','expense'),
    (ta,'4999','Other income','revenue');
  select id into g_ops       from gl_accounts where tenant_id=ta and account_code='1000';
  select id into g_trust_ugx from gl_accounts where tenant_id=ta and account_code='1020';
  select id into g_trust_usd from gl_accounts where tenant_id=ta and account_code='1021';
  select id into g_ops_usd   from gl_accounts where tenant_id=ta and account_code='1031';
  select id into g_trust_eur from gl_accounts where tenant_id=ta and account_code='1022';
  select id into g_ops_eur   from gl_accounts where tenant_id=ta and account_code='1032';
  select id into g_ar        from gl_accounts where tenant_id=ta and account_code='1100';
  select id into g_pay       from gl_accounts where tenant_id=ta and account_code='2010';
  select id into g_unearned  from gl_accounts where tenant_id=ta and account_code='2020';
  select id into g_income    from gl_accounts where tenant_id=ta and account_code='4000';
  select id into g_crecv     from gl_accounts where tenant_id=ta and account_code='1130';
  select id into g_cpay      from gl_accounts where tenant_id=ta and account_code='2310';
  select id into g_gain      from gl_accounts where tenant_id=ta and account_code='4900';
  select id into g_loss      from gl_accounts where tenant_id=ta and account_code='5910';
  select id into g_other     from gl_accounts where tenant_id=ta and account_code='4999';
  insert into gl_posting_rules (tenant_id, account_role, gl_account_id) values
    (ta,'bank',g_ops),(ta,'client_money_bank',g_trust_ugx),(ta,'ar_control',g_ar),
    (ta,'insurer_payable',g_pay),(ta,'unearned_commission',g_unearned),(ta,'commission_income',g_income),
    (ta,'insurer_claim_receivable',g_crecv),(ta,'client_claim_payable',g_cpay),
    (ta,'fx_gain_realised',g_gain),(ta,'fx_loss_realised',g_loss);
  insert into fin_bank_accounts (tenant_id, name, kind, currency, gl_account_id) values
    (ta,'BT-TRUST-UGX','client_money','UGX',g_trust_ugx) returning id into b_trust_ugx;
  insert into fin_bank_accounts (tenant_id, name, kind, currency, gl_account_id) values
    (ta,'BT-TRUST-USD','client_money','USD',g_trust_usd) returning id into b_trust_usd;
  insert into fin_bank_accounts (tenant_id, name, kind, currency, gl_account_id) values
    (ta,'BT-OPS-USD','operating','USD',g_ops_usd) returning id into b_ops_usd;
  insert into fin_bank_accounts (tenant_id, name, kind, currency, gl_account_id) values
    (ta,'BT-TRUST-EUR','client_money','EUR',g_trust_eur) returning id into b_trust_eur;
  insert into fin_bank_accounts (tenant_id, name, kind, currency, gl_account_id) values
    (ta,'BT-OPS-EUR','operating','EUR',g_ops_eur) returning id into b_ops_eur;

  perform set_config('reg.via_rpc', 'on', true);
  perform set_config('fx.via_rpc', 'on', true);
  insert into regulatory_parameters (tenant_id, parameter_key, value_num, effective_from, source_ref)
    values (ta, 'fx.rate_max_age_days', 90, date '2000-01-01', 'UNVERIFIED: test fixture') returning id into reg_id;
  update regulatory_parameters set status = 'approved', approved_by = approver, approved_at = now() where id = reg_id;
  insert into fx_rates (tenant_id, currency, rate_date, rate, source) values (ta, 'USD', current_date - 1, 3700, 'fixture') returning id into fx_id;
  update fx_rates set status = 'approved', approved_by = approver, approved_at = now() where id = fx_id;
  insert into fx_rates (tenant_id, currency, rate_date, rate, source) values (ta, 'USD', current_date, 3800, 'fixture') returning id into fx_id;
  update fx_rates set status = 'approved', approved_by = approver, approved_at = now() where id = fx_id;
  insert into fx_rates (tenant_id, currency, rate_date, rate, source) values (ta, 'EUR', current_date - 1, 4900, 'fixture') returning id into fx_id;
  update fx_rates set status = 'approved', approved_by = approver, approved_at = now() where id = fx_id;
  insert into fx_rates (tenant_id, currency, rate_date, rate, source) values (ta, 'EUR', current_date, 5000, 'fixture') returning id into fx_id;
  update fx_rates set status = 'approved', approved_by = approver, approved_at = now() where id = fx_id;
  perform set_config('reg.via_rpc', 'off', true);
  perform set_config('fx.via_rpc', 'off', true);

  perform pg_temp.jwt(mgr);
  insert into organizations (tenant_id, company_code, site_name) values (ta, 'KLA', 'Kampala') returning id into v_branch;
  reset role;
  insert into ins_intermediaries (tenant_id, code, name, category, status) values
    (ta, 'AG-BT', 'BT Agent', 'independent_broker', 'active');
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  insert into ins_product_lines (tenant_id, code, name) values (ta, 'MOTOR', 'Motor') returning id into v_line;
  insert into ins_insurers (tenant_id, code, name, default_commission_rate_pct, claim_payment_mode) values (ta, 'ALPHA', 'Alpha Assurance', 10, 'via_broker') returning id into v_insr;
  reset role;

  -------------------------------------------------------------------
  -- Bind: one USD policy, one EUR policy, one UGX policy
  -------------------------------------------------------------------
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  declare cc ins_clients%rowtype;
  begin
    cc := ins_register_client('BT client', 'corporate', null, null, null, 'low');
    p_usd := ins_create_policy(cc.id, v_insr, v_line, current_date - 1, current_date + 335,
                               20000, 'USD', 10000, 10, v_branch, null, 'USD fleet', null);
    perform pg_temp.motor_cert(p_usd.id); p_usd := ins_bind_policy(p_usd.id);
    p_eur := ins_create_policy(cc.id, v_insr, v_line, current_date - 1, current_date + 335,
                               2000, 'EUR', 1000, 10, null, null, 'EUR fleet', null);
    perform pg_temp.motor_cert(p_eur.id); p_eur := ins_bind_policy(p_eur.id);
    p_ugx := ins_create_policy(cc.id, v_insr, v_line, current_date, current_date + 335,
                               8000000, 'UGX', 5000000, 10, null, null, 'UGX fleet', null);
    perform pg_temp.motor_cert(p_ugx.id); p_ugx := ins_bind_policy(p_ugx.id);
  end;
  reset role;
  perform pg_temp.assert(p_usd.status = 'active' and p_eur.status = 'active' and p_ugx.status = 'active',
    'all three policies bind');

  -------------------------------------------------------------------
  -- 1. The USD bind posts in USD at the inception-date rate, and the items
  --    carry the bind entry.
  -------------------------------------------------------------------
  select * into r from pg_temp.net_of(g_ar, array[p_usd.id]);
  perform pg_temp.assert(r.ccy_net = 10000 and r.base_net = 37000000,
    format('the USD bind must debit AR 10,000 USD at 3700: %s', pg_temp.lines_of(p_usd.id)));
  select * into it_prem from fin_open_items where source_type = 'ins_policy_premium' and source_id = p_usd.id;
  select * into it_usd  from fin_open_items where source_type = 'ins_policy_insurer'  and source_id = p_usd.id;
  perform pg_temp.assert(it_prem.currency = 'USD' and it_prem.fx_rate = 3700
                     and it_prem.journal_entry_id = p_usd.journal_entry_id,
    'the premium item must be USD at 3700 with the bind entry');
  perform pg_temp.assert(it_usd.currency = 'USD' and it_usd.fx_rate = 3700 and it_usd.amount = 9000
                     and it_usd.journal_entry_id = p_usd.journal_entry_id,
    'the insurer item must be USD 9,000 at 3700 with the bind entry');
  select * into r from pg_temp.net_of(g_unearned, array[p_usd.id]);
  perform pg_temp.assert(r.ccy_net = -1000 and r.base_net = -3700000,
    format('unearned commission must be a USD 1,000 credit at 3700: %s', pg_temp.lines_of(p_usd.id)));
  raise notice 'PASS: a USD policy binds at yesterday''s rate and its items carry the bind entry';

  -------------------------------------------------------------------
  -- 2. The functional policy binds exactly as before.
  -------------------------------------------------------------------
  select * into it_prem from fin_open_items where source_type = 'ins_policy_premium' and source_id = p_ugx.id;
  perform pg_temp.assert(it_prem.currency = 'UGX' and it_prem.fx_rate = 1 and it_prem.amount = 5000000,
    'the UGX premium item must stay UGX at rate 1');
  perform pg_temp.assert(
    not exists (select 1 from journal_entry_lines l join journal_entries e on e.id = l.journal_entry_id
                 where e.source_id = p_ugx.id and l.currency <> 'UGX'),
    format('the UGX bind must post UGX lines only: %s', pg_temp.lines_of(p_ugx.id)));
  raise notice 'PASS: a functional policy binds unchanged';

  -------------------------------------------------------------------
  -- 3. Funding and settling: paying the USD insurer earns the commission at
  --    the bound rate.
  -------------------------------------------------------------------
  -- Insurance policy cash moves through the maker/checker flow (the allocation guard
  -- demands it); remittances are capped by allocated collections, so collect first.
  perform pg_temp.jwt(maker);
  set local role authenticated;
  q := ins_submit_policy_cash_request(p_usd.id, 'receipt', b_trust_usd, 10000, current_date,
                                      gen_random_uuid(), 'BT-REC-USD', 'premium received');
  reset role;
  perform pg_temp.jwt(chk);
  set local role authenticated;
  q := ins_decide_policy_cash_request(q.id, 'approve');
  reset role;
  perform pg_temp.jwt(maker);
  set local role authenticated;
  q := ins_submit_policy_cash_request(p_usd.id, 'remittance', b_trust_usd, 9000, current_date,
                                      gen_random_uuid(), 'BT-REM-USD', 'pay the insurer');
  reset role;
  perform pg_temp.jwt(chk);
  set local role authenticated;
  q := ins_decide_policy_cash_request(q.id, 'approve');
  reset role;
  select * into st from fin_settlements where id = q.settlement_id;
  perform pg_temp.assert(st.realised_result = -900000,
    format('paying at today''s 3800 against the booked 3700 is a 900,000 loss, got %s', st.realised_result));
  select id into ce_usd from ins_commission_entries where policy_id = p_usd.id;
  perform pg_temp.assert((select status from ins_commission_entries where id = ce_usd) = 'earned',
    'paying the insurer must earn the commission');
  select journal_entry_id into v_rec_je from ins_commission_events
   where entry_id = ce_usd and event = 'recognised' and journal_entry_id is not null;
  perform pg_temp.assert(v_rec_je is not null, 'the recognition must be journalled');
  select * into r from pg_temp.je_of(v_rec_je, g_unearned);
  perform pg_temp.assert(r.ccy_net = 1000 and r.base_net = 3700000,
    format('recognition must debit unearned USD 1,000 at 3700: %s',
           (select string_agg(format('%s=%s/%s %s@%s', a.account_code, l.debit, l.credit, l.currency, l.fx_rate), ' | ')
            from journal_entry_lines l join gl_accounts a on a.id = l.gl_account_id where l.journal_entry_id = v_rec_je)));
  perform pg_temp.assert(exists (
    select 1 from journal_entry_lines l
     where l.journal_entry_id = v_rec_je and l.gl_account_id = g_income and l.credit = 1000
       and l.currency = 'USD' and l.fx_rate = 3700),
    format('the income side must sit at the bound rate: %s',
           (select string_agg(format('%s=%s/%s %s@%s', a.account_code, l.debit, l.credit, l.currency, l.fx_rate), ' | ')
            from journal_entry_lines l join gl_accounts a on a.id = l.gl_account_id where l.journal_entry_id = v_rec_je)));
  raise notice 'PASS: paying the USD insurer earns the commission at the bound rate';

  -------------------------------------------------------------------
  -- 4. Transferring the commission nets the trust and books the rate move.
  -------------------------------------------------------------------
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  tr := ins_transfer_earned_commission(b_trust_usd, b_ops_usd, current_date,
                                                       array[ce_usd], 'move earned commission');
  reset role;
  perform pg_temp.assert(tr.currency = 'USD' and tr.amount = 1000, 'the transfer carries the commission');
  select * into r from pg_temp.net_of(g_ops_usd, array[tr.id]);
  perform pg_temp.assert(r.ccy_net = 1000 and r.base_net = 3800000,
    format('the operating side must be USD 1,000 at the transfer-date 3800: %s', pg_temp.lines_of(tr.id)));
  select * into r from pg_temp.net_of(g_trust_usd, array[tr.id]);
  perform pg_temp.assert(r.ccy_net = -1000 and r.base_net = -3700000,
    format('the trust side must be credited at the bound 3700: %s', pg_temp.lines_of(tr.id)));
  perform pg_temp.assert(exists (
    select 1 from journal_entry_lines l join journal_entries e on e.id = l.journal_entry_id
     where e.source_id = tr.id and l.gl_account_id = g_gain and l.credit = 100000 and l.currency = 'UGX'),
    format('the 3800-vs-3700 move on USD 1,000 is a UGX 100,000 realised gain: %s', pg_temp.lines_of(tr.id)));
  perform pg_temp.assert(pg_temp.gl_net_ccy(g_trust_usd, 'USD') = 0,
    'the USD trust must net to zero in its currency (the base difference is unrealised until 3e)');
  perform pg_temp.assert((select status from ins_commission_entries where id = ce_usd) = 'transferred',
    'the entry must be transferred');
  raise notice 'PASS: the transfer books both rates and nets the trust in its currency';

  -------------------------------------------------------------------
  -- 5. Voiding the transfer, then the settlement, reverses both exactly.
  -------------------------------------------------------------------
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  tr := ins_void_commission_transfer(tr.id, 'Returning the commission to the trust', current_date);
  reset role;
  perform pg_temp.assert(tr.status = 'void', 'the transfer must be void');
  select * into r from pg_temp.jes_of(
    (select array[journal_entry_id, void_journal_entry_id] from ins_commission_transfers where id = tr.id), g_ops_usd);
  perform pg_temp.assert(r.ccy_net = 0 and r.base_net = 0, 'the transfer and its void must net to zero');
  perform pg_temp.assert((select status from ins_commission_entries where id = ce_usd) = 'earned',
    'voiding the transfer must re-earn the entry');
  perform pg_temp.jwt(maker);
  set local role authenticated;
  st := fin_void_settlement(st.id, 'Insurer returned the payment', current_date);
  reset role;
  perform pg_temp.assert(st.status = 'void', 'the settlement must be void');
  select journal_entry_id into v_rec_je from ins_commission_events
   where entry_id = ce_usd and event = 'recognition_reversed' and journal_entry_id is not null;
  perform pg_temp.assert(v_rec_je is not null, 'the recognition reversal journal must be known');
  select * into r from pg_temp.jes_of(
    (select array_agg(journal_entry_id) from ins_commission_events where entry_id = ce_usd and journal_entry_id is not null),
    g_income);
  perform pg_temp.assert(r.base_net = 0, 'the recognition and its reversal must net to zero in base');
  perform pg_temp.assert((select status from ins_commission_entries where id = ce_usd) = 'deferred',
    'the entry must be deferred again');
  perform pg_temp.assert(pg_temp.gl_net_ccy(g_trust_usd, 'USD') = 10000,
    format('both voids must put the money back into the trust, got %s', pg_temp.gl_net_ccy(g_trust_usd, 'USD')));
  raise notice 'PASS: voiding the transfer and the settlement reverses both exactly';

  -------------------------------------------------------------------
  -- 6. Commission in another currency cannot be mixed into the transfer.
  -------------------------------------------------------------------
  select * into it_usd from fin_open_items where source_type = 'ins_policy_insurer' and source_id = p_eur.id;
  perform pg_temp.jwt(maker);
  set local role authenticated;
  q := ins_submit_policy_cash_request(p_eur.id, 'receipt', b_trust_eur, 1000, current_date,
                                      gen_random_uuid(), 'BT-REC-EUR', 'premium received');
  reset role;
  perform pg_temp.jwt(chk);
  set local role authenticated;
  q := ins_decide_policy_cash_request(q.id, 'approve');
  reset role;
  perform pg_temp.jwt(maker);
  set local role authenticated;
  q := ins_submit_policy_cash_request(p_eur.id, 'remittance', b_trust_eur, 900, current_date,
                                      gen_random_uuid(), 'BT-REM-EUR', 'pay the insurer');
  reset role;
  perform pg_temp.jwt(chk);
  set local role authenticated;
  q := ins_decide_policy_cash_request(q.id, 'approve');
  reset role;
  select * into st from fin_settlements where id = q.settlement_id;
  select id into ce_eur from ins_commission_entries where policy_id = p_eur.id;
  perform pg_temp.assert((select status from ins_commission_entries where id = ce_eur) = 'earned',
    'the EUR commission must be earned');
  -- Re-earn the USD entry (the settlement void deferred it).
  perform pg_temp.jwt(maker);
  set local role authenticated;
  q := ins_submit_policy_cash_request(p_usd.id, 'remittance', b_trust_usd, 9000, current_date,
                                      gen_random_uuid(), 'BT-REM-USD-2', 'pay the insurer again');
  reset role;
  perform pg_temp.jwt(chk);
  set local role authenticated;
  q := ins_decide_policy_cash_request(q.id, 'approve');
  reset role;
  perform pg_temp.assert((select status from ins_commission_entries where id = ce_usd) = 'earned',
    'the second remittance must re-earn the USD commission');
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  perform pg_temp.expect_error(
    format('select ins_transfer_earned_commission(%L::uuid, %L::uuid, current_date, array[%L::uuid, %L::uuid], null)',
           b_trust_usd, b_ops_usd, ce_usd, ce_eur),
    'INS_TRANSFER_CURRENCY', 'mixing USD and EUR commission in one transfer');
  reset role;
  perform pg_temp.assert((select status from ins_commission_entries where id = ce_usd) = 'earned'
                     and (select status from ins_commission_entries where id = ce_eur) = 'earned',
    'a refused transfer must not move any entry');
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  tr := ins_transfer_earned_commission(b_trust_eur, b_ops_eur, current_date,
                                                       array[ce_eur], 'move the EUR commission');
  reset role;
  select * into r from pg_temp.net_of(g_ops_eur, array[tr.id]);
  perform pg_temp.assert(r.ccy_net = 100 and r.base_net = 500000,
    format('the EUR operating side must be EUR 100 at 5000: %s', pg_temp.lines_of(tr.id)));
  perform pg_temp.assert(exists (
    select 1 from journal_entry_lines l join journal_entries e on e.id = l.journal_entry_id
     where e.source_id = tr.id and l.gl_account_id = g_gain and l.credit = 10000 and l.currency = 'UGX'),
    format('the EUR 4900-to-5000 move on EUR 100 is a UGX 10,000 gain: %s', pg_temp.lines_of(tr.id)));
  raise notice 'PASS: currencies cannot be mixed, and the EUR transfer works through its own accounts';

  -------------------------------------------------------------------
  -- 7. Claim recognition accrues in the policy's currency.
  -------------------------------------------------------------------
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  cl := ins_create_claim(p_usd.id, current_date, current_date, 'Windscreen, fleet vehicle BT-1', 'INS-REF-BT-1', 0);
  reset role;
  perform pg_temp.jwt(mgr2);
  set local role authenticated;
  cl := ins_transition_claim(cl.id, 'assessing', null);
  cl := ins_transition_claim(cl.id, 'approved', 'Insurer approved the windscreen claim in full.', 2000);
  cl := ins_recognise_claim_receivable(cl.id, 'INS-CONF-BT-1');
  reset role;
  select * into r from pg_temp.net_of(g_crecv, array[cl.id]);
  perform pg_temp.assert(r.ccy_net = 2000 and r.base_net = 7600000,
    format('the accrual must debit the claim receivable USD 2,000 at 3800: %s', pg_temp.lines_of(cl.id)));
  select * into it_prem from fin_open_items where source_type = 'ins_claim_insurer' and source_id = cl.id;
  perform pg_temp.assert(it_prem.currency = 'USD' and it_prem.fx_rate = 3800
                     and it_prem.journal_entry_id = (select id from journal_entries where source_id = cl.id and source_type = 'ins_claim_accrual' limit 1),
    'the claim items must be USD at the accrual rate, naming the accrual entry');
  raise notice 'PASS: claim recognition accrues in the policy currency with its own booking entry';

  -------------------------------------------------------------------
  -- 8. The cancellation pipeline accepts foreign policies (slice 3d-3
  --    lifted the 3d-2 guard; see test_foreign_cancellation.sql for the
  --    full posting).
  -------------------------------------------------------------------
  insert into ins_policy_cancellations (tenant_id, policy_id, request_key, reason, effective_date, insurer_terms, charge_refunds, proposed_by, calculation)
  values (ta, p_usd.id, gen_random_uuid(), 'test foreign cancellation', current_date, '[]'::jsonb, '[]'::jsonb, maker, '{}'::jsonb);
  insert into ins_policy_cancellations (tenant_id, policy_id, request_key, reason, effective_date, insurer_terms, charge_refunds, proposed_by, calculation)
  values (ta, p_ugx.id, gen_random_uuid(), 'test functional cancellation', current_date, '[]'::jsonb, '[]'::jsonb, maker, '{}'::jsonb);
  raise notice 'PASS: foreign and functional cancellation proposals are both accepted';

  raise notice 'ALL PASS: foreign bind, transfer and recognition';
end
$$;

rollback;
