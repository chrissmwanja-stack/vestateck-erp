-- =====================================================================
-- Commission recognition: tenant default, per-policy override.
--
-- What this pins: ins.commission_recognition used to be snapshotted at bind and
-- read by nothing -- recognition was hard-wired to "when the insurer is paid",
-- so configuring "on placement" changed a field and not the ledger. This is the
-- proof that each implemented mode actually moves money differently.
--
--   §1  the tenant setting is chosen through the real workflow, and the
--       registry now accepts at_placement because a reader landed with it
--   §2  at_placement on a NET remittance: commission earned at bind, income
--       credited, unearned nets to zero, no recognition journal later
--   §3  a per-policy override beats the tenant setting
--   §4  the override is refused on a bound policy (frozen at bind)
--   §5  the unimplemented modes are refused by name, at the setting and at the
--       policy
--   §6  voiding a settlement does NOT un-earn a placement commission; it does
--       still un-earn a settlement-earned one
--   §7  the snapshot states the effective mode and where it came from
--   §8  gross still wins over an override of on_insurer_settlement
--
-- One transaction, rolled back. Run against a disposable database.
-- =====================================================================
\set ON_ERROR_STOP on
begin;

create function pg_temp.assert(p_ok boolean, p_msg text)
returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_msg; end if;
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

create function pg_temp.jwt(p_uid uuid)
returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
$$;

-- submit -> approve by someone else -> bind, exactly as the app does it.
create function pg_temp.approve_and_bind(p_id uuid) returns public.ins_policies
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  p public.ins_policies;
  v_tenant uuid;
  v_claims text := current_setting('request.jwt.claims', true);
  v_appr uuid;
begin
  select tenant_id into v_tenant from public.ins_policies where id = p_id;
  v_appr := ('a9900000-0000-4000-8000-' || substr(replace(v_tenant::text, '-', ''), 1, 12))::uuid;
  perform public.ins_submit_policy_for_approval(p_id);
  insert into auth.users(id, email, raw_user_meta_data, raw_app_meta_data, aud, role, created_at, updated_at)
    values (v_appr, 'approver-' || v_appr || '@test.local', '{}', '{}', 'authenticated', 'authenticated', now(), now())
    on conflict (id) do nothing;
  insert into public.app_users(id, tenant_id, name, email)
    values (v_appr, v_tenant, 'Test policy approver', 'approver-' || v_appr || '@test.local')
    on conflict (id) do nothing;
  insert into public.staff_roles(tenant_id, user_id, module, role)
    select v_tenant, v_appr, 'insurance', 'manager'
    where not exists (select 1 from public.staff_roles
                      where tenant_id = v_tenant and user_id = v_appr and module = 'insurance');
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_appr, 'role', 'authenticated')::text, true);
  perform public.ins_decide_policy(p_id, 'approved');
  perform set_config('request.jwt.claims', coalesce(v_claims, ''), true);
  p := public.ins_bind_policy(p_id);
  return p;
end $$;

-- A single-insurer policy needs a reviewed lead share before it binds.
create function pg_temp.one_share(p_policy uuid, p_insurer uuid, p_rate numeric)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into ins_policy_insurer_shares
    (tenant_id, policy_id, insurer_id, is_lead, share_pct, commission_rate_pct, reviewed)
  select tenant_id, p_policy, p_insurer, true, 100, p_rate, true
    from ins_policies where id = p_policy;
end $$;

-- Records a remittance through the maker/checker cash-request flow, which is
-- the only way an insurer payable may move.
create function pg_temp.settle_out(p_policy uuid, p_bank uuid, p_party uuid, p_amount numeric, p_maker uuid)
returns public.fin_settlements
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_claims text := current_setting('request.jwt.claims', true);
  v_checker uuid;
  q ins_policy_cash_requests%rowtype;
  s fin_settlements%rowtype;
begin
  select u.id into v_checker
    from app_users u
    join finance_team_members f on f.user_id = u.id and f.tenant_id = u.tenant_id
   where u.tenant_id = (select tenant_id from ins_policies where id = p_policy)
     and u.id <> p_maker
   limit 1;

  perform set_config('request.jwt.claims',
    json_build_object('sub', p_maker, 'role', 'authenticated')::text, true);
  q := public.ins_submit_policy_cash_request(p_policy, 'remittance', p_bank, p_amount,
        current_date, gen_random_uuid(), 'remit', 'test remittance');

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_checker, 'role', 'authenticated')::text, true);
  q := public.ins_decide_policy_cash_request(q.id, 'approve', null);

  select * into s from fin_settlements where id = q.settlement_id;
  perform set_config('request.jwt.claims', coalesce(v_claims, ''), true);
  return s;
end $$;

do $$
declare
  ta uuid := gen_random_uuid();
  admin1 uuid := gen_random_uuid();
  admin2 uuid := gen_random_uuid();
  mgr uuid := gen_random_uuid();
  maker uuid := gen_random_uuid();
  checker uuid := gen_random_uuid();
  ar_gl uuid; pay_gl uuid; unearned_gl uuid; income_gl uuid;
  bank_gl uuid; trust_gl uuid; comm_recv_gl uuid;
  c ins_clients%rowtype; p ins_policies%rowtype;
  pol_place uuid; pol_override uuid; pol_settle uuid; pol_gross uuid;
  v_setting uuid; v_line uuid; v_insurer uuid; v_bank uuid;
  v_comm numeric; v_net numeric; v_amt numeric; v_snapshot jsonb;
  v_settlement uuid; v_item uuid;
begin
  insert into tenants(id, name) values (ta, 'Commission recognition test');
  insert into auth.users(id, email, raw_user_meta_data, raw_app_meta_data, aud, role, created_at, updated_at)
    select u, 'recog-' || u || '@test.local', '{}', '{}', 'authenticated', 'authenticated', now(), now()
    from unnest(array[admin1, admin2, mgr, maker, checker]) u;
  insert into app_users(id, tenant_id, name, email)
    select u, ta, 'Recognition actor', 'recog-' || u || '@test.local'
    from unnest(array[admin1, admin2, mgr, maker, checker]) u;
  update app_users set is_company_admin = true where id in (admin1, admin2);

  insert into tenant_modules(tenant_id, module) values (ta, 'insurance');
  insert into staff_roles(tenant_id, user_id, module, role) values (ta, mgr, 'insurance', 'manager');
  insert into finance_team_members(tenant_id, user_id, role)
    values (ta, mgr, 'finance'), (ta, maker, 'finance'), (ta, checker, 'finance');

  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '1000', 'Operating', 'asset') returning id into bank_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '1020', 'Client money', 'asset') returning id into trust_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '1100', 'AR', 'asset') returning id into ar_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '1210', 'Commission receivable', 'asset') returning id into comm_recv_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '2010', 'Insurer payable', 'liability') returning id into pay_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '2020', 'Unearned commission', 'liability') returning id into unearned_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '4000', 'Commission income', 'revenue') returning id into income_gl;
  insert into gl_posting_rules(tenant_id, account_role, gl_account_id) values
    (ta, 'bank', bank_gl), (ta, 'client_money_bank', trust_gl), (ta, 'ar_control', ar_gl),
    (ta, 'insurer_payable', pay_gl), (ta, 'unearned_commission', unearned_gl),
    (ta, 'commission_income', income_gl), (ta, 'commission_receivable', comm_recv_gl);

  insert into fin_bank_accounts(tenant_id, name, kind, currency, gl_account_id)
    values (ta, 'RECOG-TRUST', 'client_money', 'UGX', trust_gl) returning id into v_bank;

  -- -------------------------------------------------------------------
  -- §1 the tenant setting is chosen through the real workflow
  -- -------------------------------------------------------------------
  perform pg_temp.jwt(admin1);
  set local role authenticated;
  v_setting := (public.acct_setting_propose(
    'ins.commission_recognition', 'at_placement', current_date,
    'Broker recognises commission when the policy is placed (test fixture).')).id;
  reset role;
  perform pg_temp.jwt(admin2);
  set local role authenticated;
  perform public.acct_setting_record_review(v_setting, 'Reviewed by counsel', 'LEGAL-REF-2');
  perform public.acct_setting_approve(v_setting);
  reset role;

  perform pg_temp.assert(
    (select value from company_accounting_settings
      where tenant_id = ta and setting_key = 'ins.commission_recognition'
        and status = 'approved') = 'at_placement',
    '§1 at_placement was approved through the real workflow');
  perform pg_temp.assert(
    'at_placement' = any (select unnest(implemented_values) from accounting_setting_definitions
                           where key = 'ins.commission_recognition'),
    '§1 the registry treats at_placement as implemented, because a reader shipped with it');
  perform pg_temp.assert(
    not ('on_premium_collection' = any (select unnest(implemented_values) from accounting_setting_definitions
                                         where key = 'ins.commission_recognition')),
    '§1 on_premium_collection is still not selectable -- nothing reads it');

  perform pg_temp.jwt(mgr);
  set local role authenticated;
  insert into ins_product_lines(tenant_id, code, name) values (ta, 'GEN', 'General') returning id into v_line;
  insert into ins_insurers(tenant_id, code, name) values (ta, 'ALPHA', 'Alpha Assurance') returning id into v_insurer;

  -- -------------------------------------------------------------------
  -- §2 at_placement on a NET remittance
  -- -------------------------------------------------------------------
  -- The tenant setting applies: commission earned at bind, income credited now,
  -- unearned empty. This is the whole point of the item.
  c := ins_register_client('Placement client', 'corporate', null, null, null, 'low');
  p := ins_create_policy(c.id, v_insurer, v_line, current_date, current_date + 365,
                         5000000, 'UGX', 1000000, 10, null, null, 'Earn at placement', null);
  pol_place := p.id;
  perform pg_temp.one_share(pol_place, v_insurer, 10);
  p := pg_temp.approve_and_bind(pol_place);
  reset role;

  v_comm := round(1000000 * 10 / 100, 2);
  v_net  := 1000000 - v_comm;

  perform pg_temp.assert(p.status = 'active', '§2 the policy bound');
  perform pg_temp.assert(
    (select status from ins_commission_entries where policy_id = pol_place) = 'earned',
    '§2 at_placement earns the commission at bind');
  perform pg_temp.assert(
    (select earned_by from ins_commission_entries where policy_id = pol_place) = 'placement',
    '§2 it is recorded as earned by placement, not by a settlement');
  perform pg_temp.assert(
    (select earned_on from ins_commission_entries where policy_id = pol_place) = p.inception_date,
    '§2 it is earned on the inception date');

  -- Account balances, not single-entry lines: the net bind credits income
  -- directly, so unearned must never have been touched.
  select coalesce(sum(l.credit - l.debit), 0) into v_amt
    from journal_entry_lines l join journal_entries je on je.id = l.journal_entry_id
   where je.tenant_id = ta and l.gl_account_id = unearned_gl;
  perform pg_temp.assert(v_amt = 0,
    format('§2 nothing sits in unearned commission (got %s)', v_amt));

  select coalesce(sum(l.credit - l.debit), 0) into v_amt
    from journal_entry_lines l join journal_entries je on je.id = l.journal_entry_id
   where je.tenant_id = ta and l.gl_account_id = income_gl;
  perform pg_temp.assert(v_amt = v_comm,
    format('§2 commission income holds %s at bind (got %s)', v_comm, v_amt));

  -- Paying the insurer must not earn it a second time.
  perform pg_temp.jwt(maker);
  set local role authenticated;
  perform public.ins_submit_policy_cash_request(pol_place, 'receipt', v_bank, 1000000,
    current_date, gen_random_uuid(), 'receipt', 'client pays');
  reset role;
  perform pg_temp.jwt(checker);
  set local role authenticated;
  perform public.ins_decide_policy_cash_request(
    (select id from ins_policy_cash_requests where policy_id = pol_place and kind = 'receipt' and status = 'pending'),
    'approve', null);
  reset role;

  v_settlement := (pg_temp.settle_out(pol_place, v_bank, v_insurer, v_net, maker)).id;
  reset role;

  perform pg_temp.assert(
    (select count(*) from ins_commission_events
      where entry_id = (select id from ins_commission_entries where policy_id = pol_place)
        and event = 'recognised') = 1,
    '§2 exactly one recognition event: paying the insurer does not earn it again');
  select coalesce(sum(l.credit - l.debit), 0) into v_amt
    from journal_entry_lines l join journal_entries je on je.id = l.journal_entry_id
   where je.tenant_id = ta and l.gl_account_id = income_gl;
  perform pg_temp.assert(v_amt = v_comm,
    format('§2 commission income is unchanged by the remittance (got %s)', v_amt));

  -- -------------------------------------------------------------------
  -- §6 voiding the settlement must NOT un-earn a placement commission
  -- -------------------------------------------------------------------
  -- This is the case a naive implementation gets wrong: the void path reverses
  -- earned entries, and would post an income reversal for commission the bind
  -- earned. Snapshot the journals first so the assertion is about this void.
  declare
    v_reversals_before integer;
    v_reversals_after  integer;
  begin
    select count(*) into v_reversals_before from journal_entries
     where tenant_id = ta and source_type = 'ins_commission_recognition_reversal';

    perform pg_temp.jwt(checker);
    set local role authenticated;
    perform public.fin_void_settlement(v_settlement, 'test void');
    reset role;

    select count(*) into v_reversals_after from journal_entries
     where tenant_id = ta and source_type = 'ins_commission_recognition_reversal';

    perform pg_temp.assert(v_reversals_after = v_reversals_before,
      format('§6 voiding a settlement posted %s commission reversal(s) on a placement commission',
             v_reversals_after - v_reversals_before));
    perform pg_temp.assert(
      (select status from ins_commission_entries where policy_id = pol_place) = 'earned',
      '§6 the placement commission stays earned after the settlement is voided');
  end;

  -- -------------------------------------------------------------------
  -- §3 a per-policy override beats the tenant setting
  -- -------------------------------------------------------------------
  -- The tenant says at_placement. This policy says otherwise, and the ledger
  -- must follow the policy.
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  c := ins_register_client('Override client', 'corporate', null, null, null, 'low');
  p := ins_create_policy(c.id, v_insurer, v_line, current_date, current_date + 365,
                         3000000, 'UGX', 600000, 10, null, null, 'Override: wait for settlement', null);
  pol_override := p.id;
  perform public.ins_set_policy_commission_recognition(pol_override, 'on_insurer_settlement');
  perform pg_temp.one_share(pol_override, v_insurer, 10);
  reset role;

  perform pg_temp.assert(
    public.ins_commission_recognition_mode(pol_override) = 'on_insurer_settlement',
    '§3 the resolver reports the policy override, not the tenant setting');

  p := pg_temp.approve_and_bind(pol_override);
  reset role;
  perform pg_temp.assert(
    (select status from ins_commission_entries where policy_id = pol_override) = 'deferred',
    '§3 the override keeps the commission deferred at bind');

  select accounting_config_snapshot into v_snapshot from ins_policies where id = pol_override;
  perform pg_temp.assert(v_snapshot ->> 'commission_recognition_effective' = 'on_insurer_settlement',
    '§3 the snapshot records the override as the mode in force');
  perform pg_temp.assert(v_snapshot ->> 'commission_recognition_source' = 'policy_override',
    '§3 the snapshot says the mode came from the policy');

  -- -------------------------------------------------------------------
  -- §4 the override is frozen once the policy is bound
  -- -------------------------------------------------------------------
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  perform pg_temp.expect_error(
    format($q$select public.ins_set_policy_commission_recognition(%L, 'at_placement')$q$, pol_override),
    'INS_FINANCIAL_IMMUTABLE',
    '§4 changing the mode on a bound policy');
  reset role;

  -- -------------------------------------------------------------------
  -- §5 the unimplemented modes are refused by name
  -- -------------------------------------------------------------------
  -- Both at the policy...
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  c := ins_register_client('Refusal client', 'corporate', null, null, null, 'low');
  p := ins_create_policy(c.id, v_insurer, v_line, current_date, current_date + 365,
                         1000000, 'UGX', 200000, 10, null, null, 'Refusal fixture', null);
  perform pg_temp.expect_error(
    format($q$select public.ins_set_policy_commission_recognition(%L, 'on_premium_collection')$q$, p.id),
    'INS_COMMISSION_RECOGNITION_UNIMPLEMENTED',
    '§5 a policy override of on_premium_collection');
  perform pg_temp.expect_error(
    format($q$select public.ins_set_policy_commission_recognition(%L, 'whenever')$q$, p.id),
    'INS_COMMISSION_RECOGNITION_MODE',
    '§5 an unknown mode');
  reset role;

  -- ...and at the tenant setting, where the registry is the gate.
  perform pg_temp.jwt(admin1);
  set local role authenticated;
  perform pg_temp.expect_error(
    $q$select public.acct_setting_propose('ins.commission_recognition', 'over_policy_term', current_date, 'attempting an unimplemented value')$q$,
    'ACCT_SETTING_VALUE_NOT_ALLOWED',
    '§5 choosing over_policy_term, which nothing implements');
  reset role;

  -- -------------------------------------------------------------------
  -- §8 gross wins over an override of on_insurer_settlement
  -- -------------------------------------------------------------------
  -- Under gross there is nothing to defer, so a policy that asks to wait for
  -- settlement would be asking for a state the posting cannot represent. Gross
  -- pins at_placement and the snapshot says which rule decided.
  perform pg_temp.jwt(admin1);
  set local role authenticated;
  declare
    v_gross_setting uuid;
  begin
    -- Effective tomorrow: a setting cannot be backdated over entries already
    -- posted today (ACCT_SETTING_BACKDATED). The policy below incepts tomorrow
    -- for the same reason.
    v_gross_setting := (public.acct_setting_propose(
      'ins.insurer_remittance_basis', 'gross_premium', current_date + 1,
      'Broker remits the full premium (test fixture).')).id;
    reset role;
    perform pg_temp.jwt(admin2);
    set local role authenticated;
    perform public.acct_setting_record_review(v_gross_setting, 'Reviewed by counsel', 'LEGAL-REF-3');
    perform public.acct_setting_approve(v_gross_setting);
    reset role;
  end;

  perform pg_temp.jwt(mgr);
  set local role authenticated;
  c := ins_register_client('Gross override client', 'corporate', null, null, null, 'low');
  p := ins_create_policy(c.id, v_insurer, v_line, current_date + 1, current_date + 366,
                         2000000, 'UGX', 500000, 10, null, null, 'Gross beats the override', null);
  pol_gross := p.id;
  perform public.ins_set_policy_commission_recognition(pol_gross, 'on_insurer_settlement');
  perform pg_temp.one_share(pol_gross, v_insurer, 10);
  reset role;

  p := pg_temp.approve_and_bind(pol_gross);
  reset role;

  perform pg_temp.assert(
    (select status from ins_commission_entries where policy_id = pol_gross) = 'earned',
    '§8 gross earned the commission at placement despite the override');
  select accounting_config_snapshot into v_snapshot from ins_policies where id = pol_gross;
  perform pg_temp.assert(v_snapshot ->> 'commission_recognition_effective' = 'at_placement',
    '§8 the snapshot states at_placement');
  perform pg_temp.assert(v_snapshot ->> 'commission_recognition_source' = 'remittance_basis_gross',
    '§8 the snapshot says gross decided it, not the tenant setting or the policy');

  -- -------------------------------------------------------------------
  -- §7 the snapshot states the mode and its source on an ordinary policy
  -- -------------------------------------------------------------------
  select accounting_config_snapshot into v_snapshot from ins_policies where id = pol_place;
  perform pg_temp.assert(v_snapshot ->> 'commission_recognition_effective' = 'at_placement',
    '§7 the tenant-setting policy records the effective mode');
  perform pg_temp.assert(v_snapshot ->> 'commission_recognition_source' = 'tenant_setting',
    '§7 and records that it came from the tenant setting');
  perform pg_temp.assert(v_snapshot ->> 'ins.commission_recognition' = 'at_placement',
    '§7 the raw setting is still recorded alongside it');

  raise notice 'PASS: §1 setting workflow and registry, §2 earn at placement, §3 override precedence, §4 frozen at bind, §5 unimplemented refused, §6 void does not un-earn placement, §7 snapshot, §8 gross precedence';
  raise notice 'ALL COMMISSION RECOGNITION TESTS PASSED';
end $$;

rollback;
