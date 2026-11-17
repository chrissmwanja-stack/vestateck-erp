-- =====================================================================
-- Insurer remittance basis: gross vs net, end to end for one insurer.
--
-- What this pins, and why it needed pinning: before 20261117180000 the
-- registry marked 'gross_premium' as implemented, but nothing read the
-- setting, so every bind withheld commission and remitted net. The value was
-- recorded and acted on by nothing.
--
--   §1  the setting can be chosen the way the app chooses it (propose,
--       compliance review, second-admin approval)
--   §2  a gross policy posts a deferred commission at bind, then earns it at
--       placement -- unearned zero, income credited, entry status 'earned'
--   §3  the share records the basis, and the resolver reads it back
--   §4  paying net under a gross basis is refused by name
--   §5  the registry refuses net_of_commission, a value nothing implements
--   §6  a tenant with no configured basis keeps the old behaviour: deferred
--       until remittance (no migration-time outage)
--   §7  gross is refused for co-insured policies and for policies with charges
--   §8  the snapshot records the recognition timing actually in force
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

-- Binding needs submit -> approve by someone else -> bind, exactly as the app
-- does it. Copied from test_ins_finance_pending_approvals.sql.
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

-- A single-insurer policy needs a reviewed lead share before it binds
-- (INS_CONFIG_REVIEW). The desk writes this row; the test does the same.
create function pg_temp.one_share(p_policy uuid, p_insurer uuid, p_rate numeric)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into ins_policy_insurer_shares
    (tenant_id, policy_id, insurer_id, is_lead, share_pct, commission_rate_pct, reviewed)
  select tenant_id, p_policy, p_insurer, true, 100, p_rate, true
    from ins_policies where id = p_policy;
end $$;

create function pg_temp.second_share(p_policy uuid, p_insurer uuid, p_pct numeric)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into ins_policy_insurer_shares
    (tenant_id, policy_id, insurer_id, is_lead, share_pct, commission_rate_pct, reviewed)
  select tenant_id, p_policy, p_insurer, false, p_pct, 10, true
    from ins_policies where id = p_policy;
end $$;

create function pg_temp.set_share_pct(p_policy uuid, p_insurer uuid, p_pct numeric)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update ins_policy_insurer_shares set share_pct = p_pct
   where policy_id = p_policy and insurer_id = p_insurer;
end $$;

do $$
declare
  ta uuid := gen_random_uuid();
  admin1 uuid := gen_random_uuid();   -- proposes the setting
  admin2 uuid := gen_random_uuid();   -- approves it (separate admin)
  mgr uuid := gen_random_uuid();      -- insurance manager who binds
  maker uuid := gen_random_uuid();    -- finance, raises the remittance request
  checker uuid := gen_random_uuid();  -- separate finance, approves and posts it
  ar_gl uuid; pay_gl uuid; unearned_gl uuid; income_gl uuid; bank_gl uuid; trust_gl uuid; comm_recv_gl uuid;
  c ins_clients%rowtype; p ins_policies%rowtype; pol_gross uuid; pol_net uuid;
  v_item uuid; v_settlement uuid; v_share uuid; v_setting uuid;
  v_net numeric; v_comm numeric; v_amt numeric; v_basis text; v_rec text; v_second uuid;
  v_bank uuid; v_req uuid; v_req2 uuid; v_req3 uuid; v_insurer uuid; v_line uuid;
  v_snapshot jsonb;
begin
  insert into tenants(id, name) values (ta, 'Remittance basis test');
  insert into auth.users(id, email, raw_user_meta_data, raw_app_meta_data, aud, role, created_at, updated_at)
    select u, 'basis-' || u || '@test.local', '{}', '{}', 'authenticated', 'authenticated', now(), now()
    from unnest(array[admin1, admin2, mgr, maker, checker]) u;
  insert into app_users(id, tenant_id, name, email)
    select u, ta, 'Basis actor', 'basis-' || u || '@test.local'
    from unnest(array[admin1, admin2, mgr, maker, checker]) u;
  -- Both admins are company admins: the setting workflow needs one to approve
  -- what the other proposed, and refuses self-approval.
  insert into tenant_modules(tenant_id, module) values (ta, 'insurance');
  insert into staff_roles(tenant_id, user_id, module, role) values (ta, mgr, 'insurance', 'manager');
  -- Recording a settlement needs the finance role; this test is about the
  -- remittance basis, not about who may pay.
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
    (ta, 'bank', bank_gl), (ta, 'client_money_bank', trust_gl), (ta, 'ar_control', ar_gl), (ta, 'insurer_payable', pay_gl),
    (ta, 'unearned_commission', unearned_gl), (ta, 'commission_income', income_gl),
    (ta, 'commission_receivable', comm_recv_gl);

  insert into fin_bank_accounts(tenant_id, name, kind, currency, gl_account_id)
    values (ta, 'BASIS-TRUST', 'client_money', 'UGX', trust_gl) returning id into v_bank;

  update app_users set is_company_admin = true where id in (admin1, admin2);

  -- -------------------------------------------------------------------
  -- §1 the setting is chosen the way the app chooses it
  -- -------------------------------------------------------------------
  perform pg_temp.jwt(admin1);
  set local role authenticated;
  -- These RPCs return the whole row, not an id.
  v_setting := (public.acct_setting_propose(
    'ins.insurer_remittance_basis', 'gross_premium', current_date,
    'Broker remits the full premium; commission invoiced separately (test fixture).')).id;
  reset role;

  perform pg_temp.jwt(admin2);
  set local role authenticated;
  perform public.acct_setting_record_review(v_setting, 'Reviewed by counsel', 'LEGAL-REF-1');
  perform public.acct_setting_approve(v_setting);
  reset role;

  perform pg_temp.assert(
    (select count(*) from company_accounting_settings
      where tenant_id = ta and setting_key = 'ins.insurer_remittance_basis'
        and status = 'approved') = 1,
    '§1 the gross basis was approved through the real workflow');

  perform pg_temp.jwt(mgr);
  set local role authenticated;

  -- -------------------------------------------------------------------
  -- §2 a gross policy earns commission at placement
  -- -------------------------------------------------------------------
  insert into ins_product_lines(tenant_id, code, name) values (ta, 'GEN', 'General') returning id into v_line;
  insert into ins_insurers(tenant_id, code, name) values (ta, 'ALPHA', 'Alpha Assurance') returning id into v_insurer;

  c := ins_register_client('Gross client', 'corporate', null, null, null, 'low');
  p := ins_create_policy(c.id, v_insurer, v_line,
                         current_date, current_date + 365, 5000000, 'UGX', 1000000, 10,
                         null, null, 'Gross basis policy', null);
  pol_gross := p.id;
  perform pg_temp.one_share(pol_gross, v_insurer, 10);
  p := pg_temp.approve_and_bind(pol_gross);
  -- Read journals as the owner: journal_entries is RLS-protected, and the
  -- assertions below are about what the ledger holds, not what this user may
  -- see. (Acting as `authenticated` here silently returned zero rows.)
  reset role;

  v_comm := round(1000000 * 10 / 100, 2);
  v_net  := 1000000 - v_comm;

  perform pg_temp.assert(p.status = 'active', '§2 the gross policy bound');
  perform pg_temp.assert(
    (select count(*) from ins_commission_entries where policy_id = pol_gross and status = 'earned') = 1,
    '§2 commission is earned at placement, not left deferred');
  perform pg_temp.assert(
    (select count(*) from ins_commission_entries where policy_id = pol_gross and status = 'deferred') = 0,
    '§2 nothing remains deferred on a gross policy');
  perform pg_temp.assert(
    (select earned_on from ins_commission_entries where policy_id = pol_gross) = p.inception_date,
    '§2 it is earned on the inception date');

  -- Unearned must be empty and commission income must hold the commission.
  -- The account's balance, not just the recognition entry's lines: the bind
  -- credits unearned and the recognition entry debits it back, so the two must
  -- be netted. Measuring only the recognition entry shows a false negative.
  select coalesce(sum(l.credit - l.debit), 0) into v_amt
    from journal_entry_lines l join journal_entries je on je.id = l.journal_entry_id
   where je.tenant_id = ta and l.gl_account_id = unearned_gl;
  perform pg_temp.assert(v_amt = 0,
    format('§2 the unearned commission account nets to zero at placement (got %s)', v_amt));

  -- Under gross the income is credited on the bind entry itself (the premium
  -- went across in full, so there is nothing to defer), not on a later
  -- recognition entry. Measure the account.
  select coalesce(sum(l.credit - l.debit), 0) into v_amt
    from journal_entry_lines l join journal_entries je on je.id = l.journal_entry_id
   where je.tenant_id = ta and l.gl_account_id = income_gl;
  perform pg_temp.assert(v_amt = v_comm,
    format('§2 commission income holds %s (got %s)', v_comm, v_amt));

  -- -------------------------------------------------------------------
  -- §3 the basis is recorded, and survives a later change of setting
  -- -------------------------------------------------------------------
  perform pg_temp.assert(
    (select settlement_basis from ins_policy_insurer_shares where policy_id = pol_gross) = 'gross_premium',
    '§3 the share records the basis it was bound under');

  perform pg_temp.assert(
    public.ins_share_basis(pol_gross) = 'gross_premium',
    '§3 the resolver reports the basis recorded on the share');

  -- Deliberately NOT tested here: that a later change of setting does not
  -- restate a bound policy. Only gross_premium is implemented, so no
  -- disagreeing value can be approved today, and the approved choice cannot be
  -- withdrawn (acct_setting_withdraw accepts drafts only). The precedence --
  -- ins_share_basis reads the recorded column before the setting -- is in the
  -- resolver; exercising it needs a second implemented value, which is Tier 2.

  -- -------------------------------------------------------------------
  -- §4 the basis is enforced where the money actually moves
  -- -------------------------------------------------------------------
  -- An insurer payable cannot be settled directly: ins_policy_cash_allocation_guard
  -- requires a maker/checker cash request in the same transaction. So the basis
  -- check is exercised through that flow, which is how a remittance is really
  -- recorded.
  select id into v_item from fin_open_items
   where tenant_id = ta and source_type = 'ins_policy_insurer' and source_id = pol_gross;
  perform pg_temp.assert(v_item is not null, '§4 the insurer payable exists');

  -- Money in first: the client pays the premium, so a remittance has something
  -- to be capped by. Maker raises it, a different Finance user posts it.
  perform pg_temp.jwt(maker);
  set local role authenticated;
  v_req3 := (public.ins_submit_policy_cash_request(
               pol_gross, 'receipt', v_bank, 1000000, current_date, gen_random_uuid(),
               'receipt', 'client pays the full premium')).id;
  reset role;
  perform pg_temp.jwt(checker);
  set local role authenticated;
  perform public.ins_decide_policy_cash_request(v_req3, 'approve', null);
  reset role;

  raise notice 'PROBE payable amount for gross policy: %', (select jsonb_agg(jsonb_build_object('role',control_role,'type',source_type,'amt',amount)) from fin_open_items where tenant_id = ta and source_id = pol_gross);
  -- The maker raises a net remittance against a policy whose basis is gross.
  perform pg_temp.jwt(maker);
  set local role authenticated;
  v_req := (public.ins_submit_policy_cash_request(
              pol_gross, 'remittance', v_bank, v_net, current_date, gen_random_uuid(),
              'net attempt', 'remitting net under a gross basis')).id;
  reset role;

  -- A different Finance user checks it. The basis guard must stop the posting.
  perform pg_temp.jwt(checker);
  set local role authenticated;
  perform pg_temp.expect_error(
    format($q$select public.ins_decide_policy_cash_request(%L, 'approve', null)$q$, v_req),
    'INS_SETTLEMENT_BASIS',
    '§4 approving a net remittance on a gross-basis policy');
  reset role;

  -- The same request at the full premium is accepted: the basis allows it, and
  -- this proves the refusal above was about the amount, not about the flow.
  perform pg_temp.jwt(maker);
  set local role authenticated;
  v_req2 := (public.ins_submit_policy_cash_request(
               pol_gross, 'remittance', v_bank, 1000000, current_date, gen_random_uuid(),
               'gross attempt', 'remitting the full premium under a gross basis')).id;
  reset role;
  perform pg_temp.jwt(checker);
  set local role authenticated;
  perform public.ins_decide_policy_cash_request(v_req2, 'approve', null);
  reset role;
  perform pg_temp.assert(
    (select status from ins_policy_cash_requests where id = v_req2) = 'posted',
    '§4 the full premium is accepted under a gross basis');

  -- -------------------------------------------------------------------
  -- §6 no configured basis -> the legacy path, unchanged
  -- -------------------------------------------------------------------
  -- The gross choice is in force from today. A policy placed BEFORE that date
  -- resolves nothing configured on its inception date and must keep the old
  -- behaviour: commission withheld, deferred until the insurer is paid. This is
  -- the check that the change is not an outage for tenants mid-book.
  reset role;
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  c := ins_register_client('Legacy basis client', 'corporate', null, null, null, 'low');
  p := ins_create_policy(c.id, v_insurer, v_line,
                         current_date - 400, current_date - 35, 2000000, 'UGX', 500000, 10,
                         null, null, 'Policy placed before the basis was chosen', null);
  pol_net := p.id;
  perform pg_temp.one_share(pol_net, v_insurer, 10);
  reset role;
  p := pg_temp.approve_and_bind(pol_net);
  reset role;

  perform pg_temp.assert(
    (select count(*) from ins_commission_entries where policy_id = pol_net and status = 'deferred') = 1,
    '§6 a basis-less policy still defers commission until the insurer is paid');
  perform pg_temp.assert(public.ins_share_basis(pol_net) = 'net_of_commission',
    '§6 with nothing configured, the resolver reports the legacy basis');

  perform pg_temp.jwt(mgr);
  set local role authenticated;

  -- -------------------------------------------------------------------
  -- §5 the registry refuses a value nothing implements
  -- -------------------------------------------------------------------
  -- net_of_commission is the behaviour in code but is NOT in implemented_values,
  -- so choosing it is refused by name. Pinned so nobody "adds" the value
  -- without adding something that reads it.
  reset role;
  perform pg_temp.jwt(admin1);
  set local role authenticated;
  perform pg_temp.expect_error(
    $q$select public.acct_setting_propose('ins.insurer_remittance_basis', 'net_of_commission', current_date, 'attempting an unimplemented value')$q$,
    'ACCT_SETTING_VALUE_NOT_ALLOWED',
    '§5 choosing net_of_commission, which nothing implements');
  reset role;

  -- -------------------------------------------------------------------
  -- §7 gross is refused where Tier 2 has not landed
  -- -------------------------------------------------------------------
  -- A co-insured policy under gross: refused by name rather than silently
  -- netting the second share.
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  insert into ins_insurers(tenant_id, code, name) values (ta, 'BETA', 'Beta Assurance') returning id into v_second;
  c := ins_register_client('Co-insured client', 'corporate', null, null, null, 'low');
  p := ins_create_policy(c.id, v_insurer, v_line,
                         current_date, current_date + 365, 9000000, 'UGX', 2000000, 10,
                         null, null, 'Two insurers, gross basis', null);
  perform pg_temp.one_share(p.id, v_insurer, 10);
  reset role;
  perform pg_temp.second_share(p.id, v_second, 40);
  perform pg_temp.set_share_pct(p.id, v_insurer, 60);
  perform pg_temp.expect_error(
    format($q$select pg_temp.approve_and_bind(%L)$q$, p.id),
    'INS_SETTLEMENT_BASIS_COINSURER',
    '§7 binding a co-insured policy on the gross basis');

  -- A policy with charges under gross: refused, because the charge split has
  -- not been built.
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  c := ins_register_client('Charges client', 'corporate', null, null, null, 'low');
  p := ins_create_policy(c.id, v_insurer, v_line,
                         current_date, current_date + 365, 1000000, 'UGX', 300000, 10,
                         null, null, 'Gross with a policy charge', null);
  perform pg_temp.one_share(p.id, v_insurer, 10);
  reset role;
  insert into ins_policy_charges(policy_id, tenant_id, kind, description, amount, recipient_mode, vat_mode, vat_rate_pct, reviewed)
    values (p.id, ta, 'broker_fee', 'Policy fee', 5000, 'broker', 'not_calculated', null, true);
  update ins_policy_charges set income_gl_account_id = income_gl
   where policy_id = p.id and kind = 'broker_fee';
  perform pg_temp.expect_error(
    format($q$select pg_temp.approve_and_bind(%L)$q$, p.id),
    'INS_SETTLEMENT_BASIS_CHARGES',
    '§7 binding a gross policy that carries charges');

  -- -------------------------------------------------------------------
  -- §8 the snapshot records the recognition timing actually in force
  -- -------------------------------------------------------------------
  select accounting_config_snapshot into v_snapshot from ins_policies where id = pol_gross;
  perform pg_temp.assert(v_snapshot ->> 'ins.insurer_remittance_basis' = 'gross_premium',
    '§8 the snapshot names the settlement basis');
  perform pg_temp.assert(v_snapshot ->> 'commission_recognition_effective' = 'at_placement',
    '§8 the snapshot states that gross settled at placement, not merely the setting');

  select accounting_config_snapshot -> 'commission_recognition_effective' into v_rec from ins_policies where id = pol_net;
  perform pg_temp.assert(v_rec is not null,
    '§8 the snapshot always states the effective recognition timing');

  raise notice 'PASS: §1 setting workflow, §2 earn at placement, §3 recorded basis, §4 gross refuses a net payment, §5 unimplemented value refused, §6 basis-less policy unchanged, §7 gross refused for co-insurance and charges, §8 snapshot';
  raise notice 'ALL REMITTANCE BASIS TESTS PASSED';
end $$;

rollback;
