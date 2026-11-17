-- =====================================================================
-- Insurance: agent commission subledger (item 6, 20261117240000).
--
-- What this pins: the brokerage must pay the RIGHT intermediary, on the RIGHT
-- basis, at the RIGHT moment, and must never pay one whose money is somebody
-- else's. The register already named three categories; this proves the category
-- decides the accounting, so the same register cannot be used two ways.
--
--   §1  insurer-appointed agent  -> recorded, and NOTHING reaches the books.
--       Even asking for a share is refused by name, not answered with zero.
--   §2  sub-agent, % of brokerage commission -> the accountant's own example:
--       UGX 5,000,000 at 15% gives 750,000, of which 40% is 300,000.
--   §3  the term in force is the one that applies; a later approved term does
--       not reach back over policies that incepted before it.
--   §4  a share of a commission that is zero cannot be computed
--   §5  one term in force: overlapping approved terms are refused, entering is
--       not approving, and an approver cannot approve what they entered
--   §6  accrual is a consequence of recognition, and is idempotent
--   §7  calculation is not payment: accrued -> eligible -> paid, in order
--   §8  paying a suspended intermediary, or one whose licence has lapsed, is
--       refused by name -- both reasons, separately
--   §9  an unpaid share reverses with a reason; a PAID one is refused rather
--       than silently un-paid
--   §10 withholding is COMPUTED from the approved rate and character, and the
--       accountant's own example lands exactly: 300,000 -> 30,000 -> 270,000
--   §11 a co-broker is a different arrangement, refused rather than bent
--   §11b a flat amount across currencies is refused rather than converted
--   §12 the ledger: expense debit, ap_control credit, nothing netted against
--       commission income and nothing touching the client's premium
--   §13 a policy whose date no approved term covers is refused by name
--
-- Item 6b adds the withholding tax treatment the accountant confirmed:
--
--   §10  withholding computed at 10% of the gross; 300,000 -> 30,000 -> 270,000
--   §10b withholding cannot be typed by hand, and its net cannot drift
--   §10c the RATE did not change on 1 July 2026, the CHARACTER did
--   §10d an unapproved rate or character is refused, never defaulted to zero
--   §14 the bill to URA: prepared from the accruals, approved by a second
--       person, paid with a reference, void releases the lines
--   §15 the agent's statement says gross, withheld, net, and whether it was final
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
    if sqlerrm like '%' || p_needle || '%' then return; end if;
    raise exception 'FAIL: % raised the wrong error: %', p_label, sqlerrm;
  end;
  raise exception 'FAIL: % succeeded but should have failed with %', p_label, p_needle;
end $$;

create function pg_temp.jwt(p_uid uuid)
returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
$$;

-- submit -> approve by somebody else -> bind, exactly as the app does it.
create function pg_temp.approve_and_bind(p_id uuid) returns public.ins_policies
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  p public.ins_policies;
  v_tenant uuid;
  v_claims text := current_setting('request.jwt.claims', true);
  v_appr uuid;
begin
  select tenant_id into v_tenant from public.ins_policies where id = p_id;
  v_appr := ('a9700000-0000-4000-8000-' || substr(replace(v_tenant::text, '-', ''), 1, 12))::uuid;
  perform public.ins_submit_policy_for_approval(p_id);
  insert into auth.users(id, email, raw_user_meta_data, raw_app_meta_data, aud, role, created_at, updated_at)
    values (v_appr, 'agappr-' || v_appr || '@test.local', '{}', '{}', 'authenticated', 'authenticated', now(), now())
    on conflict (id) do nothing;
  insert into public.app_users(id, tenant_id, name, email)
    values (v_appr, v_tenant, 'Agent test approver', 'agappr-' || v_appr || '@test.local')
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

create function pg_temp.one_share(p_policy uuid, p_insurer uuid, p_rate numeric)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into ins_policy_insurer_shares
    (tenant_id, policy_id, insurer_id, is_lead, share_pct, commission_rate_pct, reviewed)
  select tenant_id, p_policy, p_insurer, true, 100, p_rate, true
    from ins_policies where id = p_policy;
end $$;

-- Movement on one GL account for ONE journal entry, debit-positive. Used where
-- later scenarios add accruals to the same tenant and a tenant-wide total would
-- stop meaning what the assertion says it means.
create function pg_temp.acct_je(p_entry uuid, p_gl uuid) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(sum(l.debit - l.credit), 0)
    from journal_entry_lines l
   where l.journal_entry_id = p_entry and l.gl_account_id = p_gl;
$$;

-- Movement on one GL account for this tenant, debit-positive.
create function pg_temp.acct(p_tenant uuid, p_gl uuid) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(sum(l.debit - l.credit), 0)
    from journal_entry_lines l
    join journal_entries je on je.id = l.journal_entry_id
   where je.tenant_id = p_tenant and l.gl_account_id = p_gl;
$$;

-- Recognise the brokerage's commission the way BOTH real paths do it in one
-- transaction: the event AND the entry's status. Doing only one half would be a
-- fixture no real path can produce, and eligibility reads the status.
create function pg_temp.recognise(p_policy uuid, p_amount numeric)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_entry uuid;
  v_tenant uuid;
begin
  select tenant_id into v_tenant from ins_policies where id = p_policy;
  select id into v_entry from ins_commission_entries where policy_id = p_policy;
  update ins_commission_entries
     set status = 'earned', earned_on = current_date, earned_by = 'settlement'
   where id = v_entry;
  insert into ins_commission_events(id, tenant_id, entry_id, event, amount)
    values (gen_random_uuid(), v_tenant, v_entry, 'recognised', p_amount);
end $$;

do $$
declare
  ta       uuid := gen_random_uuid();
  admin1   uuid := gen_random_uuid();
  admin2   uuid := gen_random_uuid();
  mgr      uuid := gen_random_uuid();
  ar_gl    uuid; pay_gl uuid; unearned_gl uuid; income_gl uuid;
  expense_gl uuid; ap_gl uuid; bank_gl uuid; trust_gl uuid; comm_recv_gl uuid;
  wht_gl   uuid;
  c        ins_clients%rowtype;
  p        ins_policies%rowtype;
  v_line   uuid; v_insurer uuid; v_opbank uuid;
  v_insurer_agent uuid; v_sub uuid; v_sub2 uuid; v_ref uuid; v_cobroker uuid;
  v_term   public.ins_intermediary_terms;
  v_calc   jsonb;
  v_acc    public.ins_agent_commission_accruals;
  v_pol_place uuid; v_pol_insurer_agent uuid; v_pol_tier uuid;
  v_pol_exp uuid; v_pol_rev uuid;
  v_comm   numeric;
begin
  insert into tenants(id, name) values (ta, 'Agent commission test');
  insert into auth.users(id, email, raw_user_meta_data, raw_app_meta_data, aud, role, created_at, updated_at)
    select u, 'agent-' || u || '@test.local', '{}', '{}', 'authenticated', 'authenticated', now(), now()
    from unnest(array[admin1, admin2, mgr]) u;
  insert into app_users(id, tenant_id, name, email)
    select u, ta, 'Agent actor', 'agent-' || u || '@test.local'
    from unnest(array[admin1, admin2, mgr]) u;
  update app_users set is_company_admin = true where id in (admin1, admin2);

  insert into tenant_modules(tenant_id, module) values (ta, 'insurance');
  -- can_manage_insurance() wants the insurance staff role, not just company admin.
  insert into staff_roles(tenant_id, user_id, module, role)
    values (ta, mgr, 'insurance', 'manager'),
           (ta, admin1, 'insurance', 'manager'),
           (ta, admin2, 'insurance', 'manager');

  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '1000', 'Operating', 'asset') returning id into bank_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '1020', 'Client money', 'asset') returning id into trust_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '1100', 'AR', 'asset') returning id into ar_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '1210', 'Commission receivable', 'asset') returning id into comm_recv_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '2010', 'Insurer payable', 'liability') returning id into pay_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '2020', 'Unearned commission', 'liability') returning id into unearned_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '2100', 'AP control', 'liability') returning id into ap_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '4000', 'Commission income', 'revenue') returning id into income_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '5010', 'Agent commission', 'expense') returning id into expense_gl;
  -- Withholding tax withheld from agents and owed to URA. Its own liability, not
  -- squeezed into ap_control, so it can be aged against a filing deadline.
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '2200', 'WHT payable (URA)', 'liability') returning id into wht_gl;
  insert into gl_posting_rules(tenant_id, account_role, gl_account_id) values
    (ta, 'bank', bank_gl), (ta, 'client_money_bank', trust_gl), (ta, 'ar_control', ar_gl),
    (ta, 'insurer_payable', pay_gl), (ta, 'unearned_commission', unearned_gl),
    (ta, 'commission_income', income_gl), (ta, 'commission_receivable', comm_recv_gl),
    (ta, 'ap_control', ap_gl), (ta, 'agent_commission_expense', expense_gl),
    (ta, 'wht_payable', wht_gl);

  insert into fin_bank_accounts(tenant_id, name, kind, currency, gl_account_id)
    values (ta, 'AGENT-OP', 'operating', 'UGX', bank_gl) returning id into v_opbank;

  -- Withholding tax used to be refused outright by this subledger, so no
  -- parameters were needed here. It is computed now, and computed ONLY from
  -- approved values -- so the fixture has to do what the app makes a company do:
  -- propose a draft, then have somebody else approve it.
  --
  -- Three rows. The rate (s.134, 10% from 1 July 2020). The character before
  -- 1 July 2026, when the withholding was not final. And the character from
  -- 1 July 2026, when s.139(aa) made it final. The rate does not change across
  -- that boundary; the character does, which is the whole point of §10c.
  declare
    v_p_rate  uuid;
    v_p_char1 uuid;
    v_p_char2 uuid;
  begin
    insert into regulatory_parameters(tenant_id, parameter_key, value_num, effective_from, source_ref, created_by)
      values (ta, 'tax.wht_agent_commission_percent', 10, date '2020-07-01',
              'VERIFIED: Income Tax Act s.134, 10% of gross commission paid to an insurance agent', admin1)
      returning id into v_p_rate;
    insert into regulatory_parameters(tenant_id, parameter_key, value_text, effective_from, effective_to, source_ref, created_by)
      values (ta, 'tax.wht_agent_commission_is_final', 'false', date '2020-07-01', date '2026-06-30',
              'VERIFIED: not a final tax before 1 July 2026', admin1)
      returning id into v_p_char1;
    insert into regulatory_parameters(tenant_id, parameter_key, value_text, effective_from, source_ref, created_by)
      values (ta, 'tax.wht_agent_commission_is_final', 'true', date '2026-07-01',
              'VERIFIED: s.139(aa) Income Tax (Amendment) Act 2026, final from 1 July 2026', admin1)
      returning id into v_p_char2;

    insert into regulatory_approval_assignments(tenant_id, user_id, scope, scope_value, responsibility, effective_from, assigned_by)
      values (ta, admin2, 'category', 'tax', 'Tax parameters (test)', date '2020-07-01', admin1);

    perform pg_temp.jwt(admin2);
    set local role authenticated;
    perform public.reg_approve_parameter(v_p_rate);
    perform public.reg_approve_parameter(v_p_char1);
    perform public.reg_approve_parameter(v_p_char2);
    reset role;
  end;

  perform pg_temp.jwt(mgr);
  set local role authenticated;
  insert into ins_product_lines(tenant_id, code, name) values (ta, 'GEN', 'General') returning id into v_line;
  insert into ins_insurers(tenant_id, code, name) values (ta, 'ALPHA', 'Alpha Assurance') returning id into v_insurer;
  reset role;

  -- The register requires every sub-agent to have a parent, so the referral
  -- partner at the top of the chain comes first. That is the real shape of
  -- these arrangements: a sub-agent hangs off the intermediary that introduced
  -- it, not off the brokerage in the abstract.
  insert into ins_intermediaries(tenant_id, code, kind, name, category, status)
    values (ta, 'INSAGT', 'individual', 'Insurer appointed agent', 'insurer_appointed_agent', 'active')
    returning id into v_insurer_agent;
  insert into ins_intermediaries(tenant_id, code, kind, name, category, status)
    values (ta, 'REF1', 'individual', 'Referral partner', 'referral_partner', 'active') returning id into v_ref;
  insert into ins_intermediaries(tenant_id, code, kind, name, category, status, parent_id)
    values (ta, 'SUB2', 'business', 'Sub agent two', 'sub_agent', 'active', v_ref) returning id into v_sub2;
  insert into ins_intermediaries(tenant_id, code, kind, name, category, status, parent_id)
    values (ta, 'SUB1', 'individual', 'Sub agent one', 'sub_agent', 'active', v_ref) returning id into v_sub;
  insert into ins_intermediaries(tenant_id, code, kind, name, category, status)
    values (ta, 'COBRK', 'business', 'Independent co-broker', 'independent_broker', 'active') returning id into v_cobroker;

  perform pg_temp.jwt(mgr);
  set local role authenticated;

  -- -------------------------------------------------------------------
  -- §1 An insurer-appointed agent is recorded, and nothing is accrued
  -- -------------------------------------------------------------------
  -- The accountant was most emphatic about this one: do not let an
  -- insurer-appointed agent's commission enter the brokerage's accounts merely
  -- because the brokerage arranged the policy.
  perform pg_temp.expect_error(
    format($q$select public.ins_set_intermediary_term(%L, 'pct_of_broker_commission', current_date, 40)$q$,
           v_insurer_agent),
    'INS_AGENT_INSURER_PAID',
    '§1 a commission-share term cannot be set for an insurer-appointed agent');

  -- basis 'none' IS allowed: the register and the books should agree that this
  -- intermediary exists and is paid by somebody else.
  reset role;
  perform pg_temp.jwt(admin1);
  set local role authenticated;
  v_term := public.ins_set_intermediary_term(
    v_insurer_agent, 'none', current_date - 400, null, null, null, null, null, null,
    'insurer remunerates directly');
  perform pg_temp.assert(v_term.id is not null, '§1 an insurer-appointed agent can record basis none');
  reset role;

  c := ins_register_client('Agent client', 'corporate', null, null, null, 'low');
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  p := ins_create_policy(c.id, v_insurer, v_line, current_date, current_date + 365,
                         5000000, 'UGX', 1000000, 10, null, v_insurer_agent, 'Insurer-paid agent', null);
  v_pol_insurer_agent := p.id;
  perform pg_temp.one_share(v_pol_insurer_agent, v_insurer, 10);
  p := pg_temp.approve_and_bind(v_pol_insurer_agent);
  reset role;

  -- Asking for a share at all is the mistake, so the calculation names it
  -- rather than returning a comfortable zero that lets a caller carry on.
  perform pg_temp.expect_error(
    format($q$select public.ins_agent_commission_calculate(%L, %L)$q$,
           v_pol_insurer_agent, v_insurer_agent),
    'INS_AGENT_INSURER_PAID',
    '§1 asking for a share on an insurer-appointed agent is refused by name');
  perform pg_temp.assert(
    (select count(*) from ins_agent_commission_accruals where policy_id = v_pol_insurer_agent) = 0,
    '§1 no accrual exists for a policy whose agent the insurer pays');
  perform pg_temp.assert(pg_temp.acct(ta, expense_gl) = 0,
    '§1 and no agent commission expense was posted');
  perform pg_temp.assert(pg_temp.acct(ta, ap_gl) = 0,
    '§1 and no payable was created');

  -- -------------------------------------------------------------------
  -- §2 The accountant's own example, to the shilling
  -- -------------------------------------------------------------------
  -- 5,000,000 premium at a 15% insurer commission is a brokerage commission of
  -- 750,000; a 40% sub-agent share is 300,000, leaving 450,000 retained.
  perform pg_temp.jwt(admin1);
  set local role authenticated;
  v_term := public.ins_set_intermediary_term(
    v_sub, 'pct_of_broker_commission', current_date - 400, 40,
    null, null, null, null, null, 'agreed 40% share');
  perform pg_temp.assert(v_term.status = 'draft',
    '§2 a term starts as a draft; entering it is not approving it');
  reset role;

  perform pg_temp.jwt(admin2);
  set local role authenticated;
  perform public.ins_approve_intermediary_term(v_term.id);
  reset role;

  c := ins_register_client('Agent client two', 'corporate', null, null, null, 'low');
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  p := ins_create_policy(c.id, v_insurer, v_line, current_date, current_date + 365,
                         5000000, 'UGX', 5000000, 15, null, v_sub, 'Sub-agent business', null);
  v_pol_place := p.id;
  perform pg_temp.one_share(v_pol_place, v_insurer, 15);
  p := pg_temp.approve_and_bind(v_pol_place);
  reset role;

  v_comm := round(5000000 * 15 / 100, 2);
  perform pg_temp.assert(v_comm = 750000,
    format('§2 the brokerage commission is 750,000 (got %s)', v_comm));

  v_calc := public.ins_agent_commission_calculate(v_pol_place, v_sub);
  perform pg_temp.assert((v_calc ->> 'payable_by_brokerage')::boolean,
    '§2 a sub-agent IS payable by the brokerage');
  perform pg_temp.assert((v_calc ->> 'commission_base')::numeric = 750000,
    format('§2 the base is the brokerage commission, not the premium (got %s)', v_calc ->> 'commission_base'));
  perform pg_temp.assert((v_calc ->> 'gross_amount')::numeric = 300000,
    format('§2 the sub-agent share is 300,000 (got %s)', v_calc ->> 'gross_amount'));
  perform pg_temp.assert((v_calc ->> 'basis') = 'pct_of_broker_commission',
    '§2 the default basis is a percentage of the brokerage commission');

  -- -------------------------------------------------------------------
  -- §6 Accrual follows recognition, and is idempotent
  -- -------------------------------------------------------------------
  perform pg_temp.assert(
    (select count(*) from ins_agent_commission_accruals where policy_id = v_pol_place) = 0,
    '§6 binding alone does not accrue a share when commission is earned on settlement');

  perform pg_temp.recognise(v_pol_place, v_comm);

  perform pg_temp.assert(
    (select count(*) from ins_agent_commission_accruals where policy_id = v_pol_place) = 1,
    '§6 recognising the brokerage commission accrues the sub-agent share');
  select * into v_acc from ins_agent_commission_accruals where policy_id = v_pol_place;
  perform pg_temp.assert(v_acc.gross_amount = 300000,
    format('§6 the accrued share is 300,000 (got %s)', v_acc.gross_amount));
  perform pg_temp.assert(v_acc.status = 'accrued',
    format('§6 it starts accrued, not payable (got %s)', v_acc.status));
  perform pg_temp.assert(v_acc.basis = 'pct_of_broker_commission' and v_acc.rate_pct = 40,
    '§6 the basis and rate are COPIED onto the accrual, not joined at read time');
  perform pg_temp.assert(v_acc.commission_base = 750000,
    '§6 the base it was computed on is stored with it');

  -- The ledger, not just the row.
  perform pg_temp.assert(pg_temp.acct(ta, expense_gl) = 300000,
    format('§12 agent commission expense is debited 300,000 (got %s)', pg_temp.acct(ta, expense_gl)));
  -- ap_control carries the NET, 270,000, not the gross 300,000: the agent is
  -- owed what will actually reach them, and the withheld 30,000 is a liability to
  -- URA that belongs on its own line. Someone reading only ap_control should be
  -- able to tell what the agent will be paid without applying a tax rate.
  perform pg_temp.assert(pg_temp.acct(ta, ap_gl) = -270000,
    format('§12 ap_control is credited the NET 270,000 (got %s)', pg_temp.acct(ta, ap_gl)));
  perform pg_temp.assert(pg_temp.acct(ta, expense_gl) = 300000,
    format('§12 while the expense stays the GROSS 300,000 (got %s)', pg_temp.acct(ta, expense_gl)));
  perform pg_temp.assert(
    (select count(*) from journal_entries where tenant_id = ta and source_type = 'ins_agent_commission_accrual') = 1,
    '§12 the accrual posts exactly one journal');

  -- The accrual RPC is owner-only, because the trigger calls it as the table
  -- owner and a client has no business calling it directly. So the test calls
  -- it the same way, and then puts the ordinary role back.
  reset role;
  -- If the idempotency check were removed, the natural key or the journal's
  -- source uniqueness would still stop a second posting -- but as a raw
  -- exception, which is a worse answer than "already done". Capture it so a
  -- regression reads as a test failure rather than an unexplained crash.
  begin
    v_calc := public.ins_agent_commission_accrue(v_pol_place);
  exception when others then
    raise exception 'FAIL: §6 a second accrual crashed instead of reporting already-done: %', sqlerrm;
  end;
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  perform pg_temp.assert((v_calc ->> 'already_accrued')::boolean,
    '§6 a second accrual is reported as already done, not posted twice');
  perform pg_temp.assert(pg_temp.acct(ta, expense_gl) = 300000,
    '§6 and the expense is unchanged');
  -- Belt and braces, deliberately: even if the RPC's own idempotency check were
  -- removed, the natural key means a second row for the same policy and
  -- intermediary cannot exist. Two independent guards, asserted separately,
  -- because "it happens to be caught elsewhere" is not the same as "it cannot
  -- happen".
  perform pg_temp.assert(
    (select count(*) from ins_agent_commission_accruals
      where policy_id = v_pol_place and intermediary_id = v_sub) = 1,
    '§6 exactly one accrual row exists for the policy and intermediary');
  -- Run as the owner so the CONSTRAINT is what answers, not the missing grant:
  -- a client cannot insert here at all, which is a separate and equally right
  -- answer, but it would hide whether the key itself holds.
  reset role;
  perform pg_temp.expect_error(
    format($q$insert into public.ins_agent_commission_accruals
                (tenant_id, policy_id, intermediary_id, basis, commission_base, gross_amount, currency)
              values (%L, %L, %L, 'pct_of_broker_commission', 750000, 300000, 'UGX')$q$,
           ta, v_pol_place, v_sub),
    'ins_agent_accruals_once_key',
    '§6 and the natural key refuses a duplicate accrual outright');
  perform pg_temp.jwt(mgr);
  set local role authenticated;

  -- -------------------------------------------------------------------
  -- §7 Calculation is not payment
  -- -------------------------------------------------------------------
  perform pg_temp.expect_error(
    format($q$select public.ins_agent_commission_pay(%L, %L, current_date, 'pay now')$q$,
           v_acc.id, v_opbank),
    'INS_AGENT_NOT_ELIGIBLE',
    '§7 an accrued-but-not-eligible share cannot be paid');

  perform pg_temp.assert(
    ((public.ins_agent_commission_mark_eligible(v_pol_place)) ->> 'marked_eligible')::int = 1,
    '§7 the share becomes eligible once the brokerage commission is earned');
  perform pg_temp.assert(
    (select status from ins_agent_commission_accruals where id = v_acc.id) = 'eligible',
    '§7 the status moved to eligible');
  perform pg_temp.assert(
    (select count(*) from ins_agent_commission_events where accrual_id = v_acc.id and event = 'eligible') = 1,
    '§7 eligibility is an event, not a silent field change');

  v_calc := public.ins_agent_commission_pay(v_acc.id, v_opbank, current_date, 'paid in full');
  perform pg_temp.assert((v_calc ->> 'paid')::boolean, '§7 the share can now be paid');
  perform pg_temp.assert(
    (select status from ins_agent_commission_accruals where id = v_acc.id) = 'paid',
    '§7 the accrual is marked paid');
  perform pg_temp.assert(
    (select paid_at from ins_agent_commission_accruals where id = v_acc.id) is not null,
    '§7 with a paid timestamp');
  perform pg_temp.assert(pg_temp.acct(ta, ap_gl) = 0,
    format('§12 paying clears the payable to zero (got %s)', pg_temp.acct(ta, ap_gl)));

  v_calc := public.ins_agent_commission_pay(v_acc.id, v_opbank, current_date, 'again');
  perform pg_temp.assert((v_calc ->> 'already_paid')::boolean,
    '§7 a second payment is reported as already done');

  -- -------------------------------------------------------------------
  -- §9 A paid share is not silently reversed
  -- -------------------------------------------------------------------
  perform pg_temp.expect_error(
    format($q$select public.ins_agent_commission_reverse(%L, 'policy cancelled after payment')$q$, v_acc.id),
    'INS_AGENT_ALREADY_PAID',
    '§9 reversing a paid share is refused; recovery is a human decision');
  perform pg_temp.assert(
    (select status from ins_agent_commission_accruals where id = v_acc.id) = 'paid',
    '§9 and the paid row is untouched');

  -- -------------------------------------------------------------------
  -- §3 The term in force governs; a later one does not reach back
  -- -------------------------------------------------------------------
  -- Entered by one admin, approved by the other: the term guard applies to
  -- terms exactly as it does to commission rates.
  perform pg_temp.jwt(admin1);
  set local role authenticated;
  v_term := public.ins_set_intermediary_term(
    v_sub2, 'pct_of_broker_commission', current_date - 400, 25, null, null, current_date,
    null, null, 'first year 25%');
  reset role;
  perform pg_temp.jwt(admin2);
  set local role authenticated;
  perform public.ins_approve_intermediary_term(v_term.id);
  reset role;

  perform pg_temp.jwt(admin2);
  set local role authenticated;
  v_term := public.ins_set_intermediary_term(
    v_sub2, 'pct_of_broker_commission', current_date + 1, 35, null, null, null,
    null, null, 'renegotiated to 35%');
  reset role;
  perform pg_temp.jwt(admin1);
  set local role authenticated;
  perform public.ins_approve_intermediary_term(v_term.id);
  reset role;

  c := ins_register_client('Agent client three', 'corporate', null, null, null, 'low');
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  p := ins_create_policy(c.id, v_insurer, v_line, current_date, current_date + 365,
                         5000000, 'UGX', 1000000, 10, null, v_sub2, 'Term in force', null);
  v_pol_tier := p.id;
  perform pg_temp.one_share(v_pol_tier, v_insurer, 10);
  p := pg_temp.approve_and_bind(v_pol_tier);
  reset role;

  v_calc := public.ins_agent_commission_calculate(v_pol_tier, v_sub2);
  perform pg_temp.assert((v_calc ->> 'rate_pct')::numeric = 25,
    format('§3 a policy incepting today uses the 25%% term, not the later one (got %s)', v_calc ->> 'rate_pct'));
  perform pg_temp.assert((v_calc ->> 'gross_amount')::numeric = 25000,
    format('§3 giving 25%% of 100,000 = 25,000 (got %s)', v_calc ->> 'gross_amount'));

  -- -------------------------------------------------------------------
  -- §5 One term in force; entering is not approving
  -- -------------------------------------------------------------------
  perform pg_temp.jwt(admin1);
  set local role authenticated;
  perform pg_temp.expect_error(
    format($q$select public.ins_set_intermediary_term(%L, 'pct_of_broker_commission', current_date, 50, null, null, current_date + 100)$q$,
           v_sub2),
    'INS_AGENT_TERM_OVERLAP',
    '§5 an overlapping approved term is refused rather than stacked');

  perform pg_temp.jwt(admin2);
  v_term := public.ins_set_intermediary_term(
    v_ref, 'pct_of_broker_commission', current_date, 10, null, null, null, null, null, 'referral 10%');
  perform pg_temp.expect_error(
    format($q$select public.ins_approve_intermediary_term(%L)$q$, v_term.id),
    'INS_AGENT_TERM_SELF_APPROVAL',
    '§5 the person who entered a term cannot approve it');
  reset role;
  perform pg_temp.jwt(admin1);
  set local role authenticated;
  perform public.ins_approve_intermediary_term(v_term.id);
  reset role;

  -- -------------------------------------------------------------------
  -- §4 No share before the brokerage has earned anything
  -- -------------------------------------------------------------------
  c := ins_register_client('Agent client four', 'corporate', null, null, null, 'low');
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  p := ins_create_policy(c.id, v_insurer, v_line, current_date + 5, current_date + 370,
                         5000000, 'UGX', 500000, 0, null, v_ref, 'No commission yet', null);
  v_pol_exp := p.id;
  perform pg_temp.one_share(v_pol_exp, v_insurer, 0);
  reset role;
  perform pg_temp.expect_error(
    format($q$select public.ins_agent_commission_calculate(%L, %L)$q$, v_pol_exp, v_ref),
    'INS_AGENT_NO_BASE',
    '§4 a share of a commission that is zero cannot be computed');

  -- -------------------------------------------------------------------
  -- §13 A term that is missing is refused, not silently zero
  -- -------------------------------------------------------------------
  c := ins_register_client('Agent client five', 'corporate', null, null, null, 'low');
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  p := ins_create_policy(c.id, v_insurer, v_line, current_date - 800, current_date - 400,
                         5000000, 'UGX', 1000000, 10, null, v_sub2, 'Before any term', null);
  v_pol_rev := p.id;
  perform pg_temp.one_share(v_pol_rev, v_insurer, 10);
  reset role;
  perform pg_temp.expect_error(
    format($q$select public.ins_agent_commission_calculate(%L, %L)$q$, v_pol_rev, v_sub2),
    'INS_AGENT_TERM_MISSING',
    '§13 a policy whose date no approved term covers is refused by name');

  -- -------------------------------------------------------------------
  -- §10 Withholding is computed, and the accountant's example lands exactly
  -- -------------------------------------------------------------------
  -- The §2 accrual is the accountant's own example: gross 300,000 on a UGX
  -- policy. At 10% that withholds 30,000 and leaves 270,000 for the agent, with
  -- 30,000 owed to URA. Those are the four numbers, asserted one at a time so a
  -- failure says which one moved.
  select * into v_acc from ins_agent_commission_accruals where id = v_acc.id;
  perform pg_temp.assert(v_acc.gross_amount = 300000,
    format('§10 gross agent commission is 300,000 (got %s)', v_acc.gross_amount));
  perform pg_temp.assert(v_acc.wht_amount = 30000,
    format('§10 withholding is 10%% of the gross = 30,000 (got %s)', v_acc.wht_amount));
  perform pg_temp.assert(v_acc.net_amount = 270000,
    format('§10 net payable to the agent is 270,000 (got %s)', v_acc.net_amount));
  perform pg_temp.assert(v_acc.wht_rate_pct = 10,
    format('§10 the rate that produced it is recorded (got %s)', v_acc.wht_rate_pct));

  -- The identity the database enforces, restated as a business fact.
  perform pg_temp.assert(v_acc.gross_amount = v_acc.wht_amount + v_acc.net_amount,
    '§10 gross = withheld + net');

  -- And the ledger agrees with the accrual, rather than agreeing with itself.
  -- The expense is the GROSS (that is what the agent's work cost); the payable
  -- to the agent is the NET; the tax sits in its own liability.
  perform pg_temp.assert(pg_temp.acct_je(v_acc.journal_entry_id, ap_gl) = -270000,
    format('§10 ap_control carries 270,000, the net due to the agent (got %s)',
           -pg_temp.acct_je(v_acc.journal_entry_id, ap_gl)));
  perform pg_temp.assert(pg_temp.acct_je(v_acc.journal_entry_id, wht_gl) = -30000,
    format('§10 wht_payable carries 30,000 owed to URA (got %s)',
           -pg_temp.acct_je(v_acc.journal_entry_id, wht_gl)));
  perform pg_temp.assert(pg_temp.acct_je(v_acc.journal_entry_id, expense_gl) = 300000,
    format('§10 the expense is the gross 300,000, not the net (got %s)',
           pg_temp.acct_je(v_acc.journal_entry_id, expense_gl)));

  -- The three legs balance. Stated explicitly because a withholding entry that
  -- balances is the only thing standing between a clerk and an unbalanced book.
  perform pg_temp.assert(
    (select coalesce(sum(l.debit), 0) = coalesce(sum(l.credit), 0)
       from journal_entry_lines l
      where l.journal_entry_id = v_acc.journal_entry_id),
    '§10 the accrual entry balances with three legs');

  -- -------------------------------------------------------------------
  -- §10b withholding cannot be written by hand
  -- -------------------------------------------------------------------
  -- It is computed from a rate and a date so that it can be tied back to both.
  -- A figure typed straight onto the row is one nobody can explain later, so the
  -- guard still refuses -- but for a different reason than before, and the
  -- message must say which.
  -- The realistic edit is a clerk "correcting" the tax down to make a payment
  -- reconcile. That is under-withholding, and it is refused like any other
  -- hand-written figure.
  perform pg_temp.expect_error(
    format($q$update public.ins_agent_commission_accruals set wht_amount = 10000, net_amount = 290000 where id = %L$q$,
           v_acc.id),
    'INS_AGENT_WHT_RPC_ONLY',
    '§10b withholding cannot be typed down by hand; only the calculation may set it');
  -- Nor can the character be flipped to suit: whether the tax was final on a
  -- given date is a fact about the date, not a field to adjust.
  perform pg_temp.expect_error(
    format($q$update public.ins_agent_commission_accruals set wht_is_final = false where id = %L$q$, v_acc.id),
    'INS_AGENT_WHT_RPC_ONLY',
    '§10b the final/non-final flag recorded on an accrual cannot be edited after the fact');
  -- And the row is untouched by both attempts.
  perform pg_temp.assert(
    (select wht_amount = 30000 and wht_is_final and net_amount = 270000
       from ins_agent_commission_accruals where id = v_acc.id),
    '§10b the accrual still carries 30,000 withheld, 270,000 net, final');

  -- -------------------------------------------------------------------
  -- §10c the rate did not change on 1 July 2026 -- the character did
  -- -------------------------------------------------------------------
  -- This is the assertion that would have been wrong under the obvious model
  -- ("the rate changed in 2026"). The rate is 10% on both sides of the boundary,
  -- so the only observable difference is the final/non-final flag. A policy
  -- incepting before 1 July 2026 gets 10% NOT final; one on or after gets 10%
  -- FINAL. Same money, different meaning.
  perform pg_temp.assert(
    (public.ins_agent_wht_for(date '2026-06-30') ->> 'is_final')::boolean = false,
    '§10c on 30 June 2026 the withholding is not final');
  perform pg_temp.assert(
    (public.ins_agent_wht_for(date '2026-07-01') ->> 'is_final')::boolean = true,
    '§10c on 1 July 2026 the withholding became final (s.139(aa))');
  perform pg_temp.assert(
    (public.ins_agent_wht_for(date '2026-06-30') ->> 'rate_pct')::numeric
    = (public.ins_agent_wht_for(date '2026-07-01') ->> 'rate_pct')::numeric,
    '§10c and the rate is the same 10% on both sides: the character changed, not the rate');

  -- A policy incepting before the boundary accrues a NON-final withholding. The
  -- money is identical to §10 -- 30,000 withheld, 270,000 net -- which is
  -- exactly why the flag had to be stored separately rather than inferred from
  -- the rate.
  reset role;
  declare
    v_c10  ins_clients%rowtype;
    v_p10  ins_policies%rowtype;
    v_calc10 jsonb;
    v_acc10 public.ins_agent_commission_accruals;
    v_term10 public.ins_intermediary_terms;
    v_sub10 uuid;
  begin
    -- A separate sub-agent, not v_sub2: v_sub2 already has an approved term
    -- running from today, and a second term overlapping it is refused (§5). One
    -- agent, one arrangement per period, is the rule this policy relies on.
    insert into ins_intermediaries(tenant_id, code, kind, name, category, status, parent_id)
      values (ta, 'SUB0', 'individual', 'Sub agent pre-boundary', 'sub_agent', 'active', v_ref)
      returning id into v_sub10;

    v_c10 := ins_register_client('Pre-boundary client', 'corporate', null, null, null, 'low');
    perform pg_temp.jwt(admin1);
    set local role authenticated;
    v_term10 := public.ins_set_intermediary_term(v_sub10, 'pct_of_broker_commission', date '2025-01-01', 40);
    reset role;
    -- Entering a term is not approving it (§5), and the calculation only reads
    -- approved terms. So a second admin approves, as the app requires.
    perform pg_temp.jwt(admin2);
    set local role authenticated;
    perform public.ins_approve_intermediary_term(v_term10.id);
    reset role;

    -- Incepted 2026-01-15: well before s.139(aa) took effect.
    v_p10 := ins_create_policy(v_c10.id, v_insurer, v_line, date '2026-01-15', date '2027-01-14',
                               5000000, 'UGX', 5000000, 15, null, v_sub10, 'pre-boundary', null);
    perform pg_temp.one_share(v_p10.id, v_insurer, 15);
    perform pg_temp.jwt(mgr);
    set local role authenticated;
    v_p10 := pg_temp.approve_and_bind(v_p10.id);
    reset role;

    perform pg_temp.recognise(v_p10.id, 750000);
    -- The trigger already accrued it when the commission was recognised, so this
    -- call reports the existing share rather than making a second one -- which is
    -- the idempotency §6 pins, seen from the other side.
    v_calc10 := public.ins_agent_commission_accrue(v_p10.id);
    perform pg_temp.assert((v_calc10 ->> 'already_accrued')::boolean,
      '§10c recognition accrued the pre-boundary share, so the explicit call is a no-op');

    select * into v_acc10 from ins_agent_commission_accruals where policy_id = v_p10.id;
    -- A share of 40% of a base of 150 would be 60, and withholding 10% of that
    -- would be 6 -- arithmetically fine and completely wrong. The base is the
    -- brokerage's COMMISSION in money, which recognition put at 750,000; the
    -- assertion is on the base itself so a unit error fails here rather than
    -- quietly producing a plausible-looking tax figure.
    perform pg_temp.assert(v_acc10.commission_base = 750000,
      format('§10c the share is computed on the brokerage commission, 750,000 (got %s)', v_acc10.commission_base));
    perform pg_temp.assert(v_acc10.gross_amount = 300000,
      format('§10c 40%% of that is 300,000 (got %s)', v_acc10.gross_amount));
    perform pg_temp.assert(v_acc10.wht_amount = 30000,
      format('§10c the same 30,000 is withheld before the boundary (got %s)', v_acc10.wht_amount));
    perform pg_temp.assert(v_acc10.net_amount = 270000,
      format('§10c and the agent still nets 270,000 (got %s)', v_acc10.net_amount));
    perform pg_temp.assert(v_acc10.wht_is_final = false,
      '§10c but the withholding is recorded as NOT final, because on that date it was only a payment on account');
  end;

  -- -------------------------------------------------------------------
  -- §10d a missing or unapproved parameter is refused, never defaulted to zero
  -- -------------------------------------------------------------------
  -- Under-withholding is the error the brokerage pays for later with interest, so
  -- "no approved rate" must stop the accrual rather than quietly withhold nothing
  -- and pay the agent in full.
  perform pg_temp.expect_error(
    $q$select public.ins_agent_wht_for(date '2019-06-30')$q$,
    'INS_AGENT_WHT_RATE_MISSING',
    '§10d a date before any approved rate is refused by name, not withheld at zero');
  -- The character is a separate fact and must be missing separately. This is a
  -- real state, not a contrived one: a company that entered the rate but never
  -- entered the character has a rate it cannot use. Shortening the pre-boundary
  -- window is reversible, so the fixture cleans up after itself and every later
  -- scenario still sees the character it expects.
  reset role;
  declare
    v_char1 uuid;
  begin
    select id into v_char1 from regulatory_parameters
     where tenant_id = ta and parameter_key = 'tax.wht_agent_commission_is_final'
       and effective_from = date '2020-07-01';
    perform pg_temp.jwt(admin2);
    set local role authenticated;
    perform public.reg_end_parameter(v_char1, date '2025-12-31');
    reset role;

    perform pg_temp.expect_error(
      $q$select public.ins_agent_wht_for(date '2026-06-30')$q$,
      'INS_AGENT_WHT_CHARACTER_MISSING',
      '§10d a rate with no approved character in force is refused: the rate alone does not say whether the tax settles the liability');
    -- The rate itself is present on that date, so the refusal is unambiguously
    -- about the character and not a knock-on of the missing rate check above.
    perform pg_temp.assert(
      (select count(*) from regulatory_parameters
        where tenant_id = ta and parameter_key = 'tax.wht_agent_commission_percent'
          and status = 'approved' and effective_from <= date '2026-06-30'
          and coalesce(effective_to, 'infinity') >= date '2026-06-30') = 1,
      '§10d the rate WAS approved on that date, so only the character was missing');
  end;

  -- -------------------------------------------------------------------
  -- §9 Reversal of an UNPAID share, with a reason
  -- -------------------------------------------------------------------
  perform pg_temp.recognise(v_pol_tier, 100000);
  select * into v_acc from ins_agent_commission_accruals where policy_id = v_pol_tier;
  perform pg_temp.assert(v_acc.id is not null, '§9 the second policy accrued a share');
  perform pg_temp.assert(v_acc.gross_amount = 25000,
    format('§9 the second share is 25%% of 100,000 = 25,000 (got %s)', v_acc.gross_amount));

  perform pg_temp.expect_error(
    format($q$select public.ins_agent_commission_reverse(%L, 'short')$q$, v_acc.id),
    'INS_AGENT_REVERSAL_REASON',
    '§9 a reversal needs a real reason');

  v_calc := public.ins_agent_commission_reverse(v_acc.id,
    'policy cancelled before the insurer settled');
  perform pg_temp.assert((v_calc ->> 'reversed')::boolean, '§9 an unpaid share can be reversed');
  perform pg_temp.assert(
    (select status from ins_agent_commission_accruals where id = v_acc.id) = 'reversed',
    '§9 the accrual is marked reversed');
  -- Before this reversal the expense held two accruals: 300,000 from §2 and
  -- 25,000 from this policy. The reversal credits the 25,000 back, so the total
  -- must return to the 300,000 of §2 alone. Asserting the TOTAL rather than a
  -- delta is deliberate: "the expense came back down to where it was" is the
  -- statement that catches a wrong sign, and it is the one an accountant makes.
  -- Tenant-wide, because §10c added a second 300,000 accrual to this tenant after
  -- §10 asserted its own. So the total is 600,000 and the reversal must bring it
  -- back to exactly that -- not to zero, and not down by the wrong amount.
  perform pg_temp.assert(pg_temp.acct(ta, expense_gl) = 600000,
    format('§9 the reversal credited the expense back to 600,000 (got %s)', pg_temp.acct(ta, expense_gl)));
  perform pg_temp.assert(
    (select count(*) from ins_agent_commission_events where accrual_id = v_acc.id and event = 'reversed') = 1,
    '§9 and the reversal is an event with its reason');

  perform pg_temp.expect_error(
    format($q$select public.ins_agent_commission_pay(%L, %L, current_date, 'try again')$q$,
           v_acc.id, v_opbank),
    'INS_AGENT_ACCRUAL_REVERSED',
    '§9 a reversed share cannot be paid afterwards');

  -- -------------------------------------------------------------------
  -- §8 A suspended intermediary or an expired licence is a compliance stop
  -- -------------------------------------------------------------------
  -- A share accrued while the agent was active is not payable once they are
  -- not. This is the check an audit asks about, so it is a refusal that names
  -- which of the two it is.
  reset role;
  declare
    v_acc8   public.ins_agent_commission_accruals;
    v_pol8   uuid;
    v_client ins_clients%rowtype;
    v_pol    ins_policies%rowtype;
    v_sub3   uuid;
  begin
    insert into ins_intermediaries(tenant_id, code, kind, name, category, status,
                                   parent_id, licence_valid_to)
      values (ta, 'SUB3', 'individual', 'Sub agent three', 'sub_agent', 'active',
              v_ref, current_date + 10)
      returning id into v_sub3;

    perform pg_temp.jwt(admin1);
    set local role authenticated;
    v_term := public.ins_set_intermediary_term(
      v_sub3, 'pct_of_broker_commission', current_date - 400, 20, null, null, null, null, null, '20%');
    reset role;
    perform pg_temp.jwt(admin2);
    set local role authenticated;
    perform public.ins_approve_intermediary_term(v_term.id);
    reset role;

    v_client := ins_register_client('Agent client six', 'corporate', null, null, null, 'low');
    perform pg_temp.jwt(mgr);
    set local role authenticated;
    v_pol := ins_create_policy(v_client.id, v_insurer, v_line, current_date, current_date + 365,
                               5000000, 'UGX', 1000000, 10, null, v_sub3, 'Licence test', null);
    v_pol8 := v_pol.id;
    perform pg_temp.one_share(v_pol8, v_insurer, 10);
    v_pol := pg_temp.approve_and_bind(v_pol8);
    reset role;

    perform pg_temp.recognise(v_pol8, 100000);

    select * into v_acc8 from ins_agent_commission_accruals where policy_id = v_pol8;
    perform pg_temp.assert(v_acc8.id is not null and v_acc8.gross_amount = 20000,
      format('§8 a 20%% share of 100,000 accrued as 20,000 (got %s)', v_acc8.gross_amount));
    perform public.ins_agent_commission_mark_eligible(v_pol8);

    update ins_intermediaries set status = 'suspended'
     where tenant_id = ta and code = 'SUB3';
    perform pg_temp.expect_error(
      format($q$select public.ins_agent_commission_pay(%L, %L, current_date, 'pay')$q$, v_acc8.id, v_opbank),
      'INS_AGENT_NOT_ACTIVE',
      '§8 a share cannot be paid to a suspended intermediary');

    -- Active again, but the licence has lapsed: refused for a different reason,
    -- which is the point of checking both.
    update ins_intermediaries
       set status = 'active', licence_valid_to = current_date - 1
     where tenant_id = ta and code = 'SUB3';
    perform pg_temp.expect_error(
      format($q$select public.ins_agent_commission_pay(%L, %L, current_date, 'pay')$q$, v_acc8.id, v_opbank),
      'INS_AGENT_LICENCE_EXPIRED',
      '§8 and not to one whose licence expired before the payment date');

    perform pg_temp.assert(
      (select status from ins_agent_commission_accruals where id = v_acc8.id) = 'eligible',
      '§8 both refusals left the share unpaid');
  end;

  -- -------------------------------------------------------------------
  -- §11 A co-broker is a different arrangement, refused rather than bent
  -- -------------------------------------------------------------------
  perform pg_temp.jwt(admin1);
  set local role authenticated;
  perform pg_temp.expect_error(
    format($q$select public.ins_set_intermediary_term(%L, 'pct_of_broker_commission', current_date, 30)$q$,
           v_cobroker),
    'INS_AGENT_CO_BROKER',
    '§11 a co-broker cannot be given a sub-agent commission share');
  reset role;

  -- -------------------------------------------------------------------
  -- §11b A flat amount in another currency is refused, not guessed
  -- -------------------------------------------------------------------
  reset role;
  declare
    v_polflat uuid;
    v_client2 ins_clients%rowtype;
    v_pol2    ins_policies%rowtype;
    v_termf   public.ins_intermediary_terms;
    v_sub4    uuid;
  begin
    -- A USD policy can only bind against an approved rate. Approving a rate is
    -- a governed act, so the fixture goes through the same guard the app does.
    perform set_config('reg.via_rpc', 'on', true);
    perform set_config('fx.via_rpc', 'on', true);
    insert into regulatory_parameters(tenant_id, parameter_key, value_num, effective_from, source_ref)
      values (ta, 'fx.rate_max_age_days', 3650, date '2000-01-01', 'UNVERIFIED: test fixture');
    update regulatory_parameters set status = 'approved', approved_by = admin1, approved_at = now()
     where tenant_id = ta and parameter_key = 'fx.rate_max_age_days';
    insert into fx_rates(tenant_id, currency, rate_date, rate, source)
      values (ta, 'USD', current_date, 3800, 'fixture');
    update fx_rates set status = 'approved', approved_by = admin1, approved_at = now()
     where tenant_id = ta and currency = 'USD';
    perform set_config('reg.via_rpc', 'off', true);
    perform set_config('fx.via_rpc', 'off', true);

    insert into ins_intermediaries(tenant_id, code, kind, name, category, status, parent_id)
      values (ta, 'SUB4', 'individual', 'Sub agent four', 'sub_agent', 'active', v_ref)
      returning id into v_sub4;

    perform pg_temp.jwt(admin1);
    set local role authenticated;
    v_termf := public.ins_set_intermediary_term(
      v_sub4, 'flat_amount_per_policy', current_date - 400, null, 50000,
      null, null, null, null, 'flat 50,000 per policy');
    reset role;
    perform pg_temp.jwt(admin2);
    set local role authenticated;
    perform public.ins_approve_intermediary_term(v_termf.id);
    reset role;

    v_client2 := ins_register_client('Agent client seven', 'corporate', null, null, null, 'low');
    perform pg_temp.jwt(mgr);
    set local role authenticated;
    v_pol2 := ins_create_policy(v_client2.id, v_insurer, v_line, current_date, current_date + 365,
                                5000000, 'USD', 1000, 10, null, v_sub4, 'USD flat test', null);
    v_polflat := v_pol2.id;
    perform pg_temp.one_share(v_polflat, v_insurer, 10);
    v_pol2 := pg_temp.approve_and_bind(v_polflat);
    reset role;

    perform pg_temp.expect_error(
      format($q$select public.ins_agent_commission_calculate(%L, %L)$q$, v_polflat, v_sub4),
      'INS_AGENT_FIXED_CURRENCY',
      '§11b a flat amount across currencies is refused rather than converted silently');
  end;

  -- -------------------------------------------------------------------
  -- §14 the withheld tax is URA's money and has its own lifecycle
  -- -------------------------------------------------------------------
  -- Withholding is not the end of the story: the brokerage holds 30,000 of
  -- somebody else's money and owes it to the revenue authority. Until that is
  -- modelled, the tax has been taken from the agent and gone nowhere.
  reset role;
  declare
    v_client14 ins_clients%rowtype;
    v_pol14    ins_policies%rowtype;
    v_sub14    uuid;
    v_term14   public.ins_intermediary_terms;
    v_prep     jsonb;
    v_rem      public.ins_wht_remittances;
    v_pos      jsonb;
    v_wht_before numeric;
    v_acc_total  numeric;
  begin
    -- This tenant already withheld 30,000 (§10, final) and 30,000 (§10c, not
    -- final). Both are real liabilities, and the character does not change what
    -- is owed to URA -- it changes what the AGENT has to do afterwards.
    -- Earlier scenarios left several accruals behind, so the total is asserted
    -- against the accruals themselves rather than a number copied out of a run.
    -- The invariant is what matters: the position is the sum of what was
    -- withheld, and none of it has been reported yet.
    v_acc_total := (select coalesce(sum(wht_amount), 0) from ins_agent_commission_accruals
                     where tenant_id = ta and status <> 'reversed');
    perform pg_temp.assert(v_acc_total > 0, '§14 earlier scenarios did withhold tax');
    v_pos := public.ins_wht_position();
    perform pg_temp.assert((v_pos ->> 'withheld_total')::numeric = v_acc_total,
      format('§14 the position equals the sum of the accruals, %s (got %s)',
             v_acc_total, v_pos ->> 'withheld_total'));
    perform pg_temp.assert((v_pos ->> 'unreported')::numeric = v_acc_total,
      format('§14 and none of it is on a return yet (got %s)', v_pos ->> 'unreported'));

    -- A period with nothing in it is not an error: it returns nothing to report.
    perform pg_temp.jwt(mgr); set local role authenticated;
    perform pg_temp.assert(
      (public.ins_wht_prepare_remittance(date '2020-01-01', date '2020-01-31') ->> 'prepared')::boolean = false,
      '§14 a period with no withholding prepares nothing, rather than a zero return');
    reset role;

    -- Prepare the return for the current month, which is where both accruals sit.
    perform pg_temp.jwt(mgr); set local role authenticated;
    v_prep := public.ins_wht_prepare_remittance(
      date_trunc('month', current_date)::date,
      (date_trunc('month', current_date) + interval '1 month - 1 day')::date, 'UGX');
    reset role;
    perform pg_temp.assert((v_prep ->> 'prepared')::boolean,
      format('§14 a return is prepared (got %s)', v_prep::text));
    perform pg_temp.assert((v_prep ->> 'amount')::numeric = v_acc_total,
      format('§14 it covers everything withheld so far, %s (got %s)', v_acc_total, v_prep ->> 'amount'));
    perform pg_temp.assert((v_prep ->> 'lines')::int
      = (select count(*) from ins_agent_commission_accruals
          where tenant_id = ta and wht_amount > 0 and status <> 'reversed'),
      '§14 one line per accrual that carries withholding');

    select * into v_rem from ins_wht_remittances where id = (v_prep ->> 'remittance_id')::uuid;
    perform pg_temp.assert(v_rem.remittance_no like 'WHT-%',
      format('§14 the return is numbered (got %s)', v_rem.remittance_no));

    -- Preparing it again must not duplicate the bill: the tax is already on a
    -- return, and a second one would pay URA twice.
    perform pg_temp.jwt(mgr); set local role authenticated;
    perform pg_temp.assert(
      (public.ins_wht_prepare_remittance(
         date_trunc('month', current_date)::date,
         (date_trunc('month', current_date) + interval '1 month - 1 day')::date, 'UGX')
       ->> 'already_prepared')::boolean,
      '§14 preparing the same period again reuses the open return');
    reset role;
    perform pg_temp.assert(
      (select count(*) from ins_wht_remittances where tenant_id = ta and status = 'prepared') = 1,
      '§14 so there is still exactly one open return');

    -- Nothing can be paid before it is approved, and the preparer cannot approve.
    perform pg_temp.jwt(mgr); set local role authenticated;
    perform pg_temp.expect_error(
      format($q$select public.ins_wht_pay_remittance(%L, %L, current_date, 'URAPAY123')$q$, v_rem.id, v_opbank),
      'INS_WHT_NOT_APPROVED',
      '§14 a prepared return cannot be paid, because nobody has checked it yet');
    perform pg_temp.expect_error(
      format($q$select public.ins_wht_approve_remittance(%L)$q$, v_rem.id),
      'INS_WHT_SELF_APPROVAL',
      '§14 the person who prepared it cannot also approve it');
    reset role;

    perform pg_temp.jwt(admin2); set local role authenticated;
    perform pg_temp.assert((public.ins_wht_approve_remittance(v_rem.id) ->> 'approved')::boolean,
      '§14 a second person approves it');
    reset role;

    -- Paying needs a real reference: it is what the next reconciliation is matched
    -- against, and "we think we paid" is not a reference.
    perform pg_temp.jwt(admin2); set local role authenticated;
    perform pg_temp.expect_error(
      format($q$select public.ins_wht_pay_remittance(%L, %L, current_date, '')$q$, v_rem.id, v_opbank),
      'INS_WHT_PAYMENT_REF',
      '§14 paying without a URA reference is refused');
    reset role;

    v_wht_before := pg_temp.acct(ta, wht_gl);
    perform pg_temp.jwt(admin2); set local role authenticated;
    perform pg_temp.assert(
      (public.ins_wht_pay_remittance(v_rem.id, v_opbank, current_date, 'URA/2026/000123') ->> 'paid')::boolean,
      '§14 the return is paid');
    reset role;

    -- Paying it clears the liability: what was 60,000 owed to URA is now nil,
    -- and the bank took the hit. That is the whole point of the lifecycle.
    perform pg_temp.assert(pg_temp.acct(ta, wht_gl) = 0,
      format('§14 wht_payable is cleared to zero by the payment (got %s)', pg_temp.acct(ta, wht_gl)));
    perform pg_temp.assert(v_wht_before = -v_acc_total,
      format('§14 it stood at %s before the payment (got %s)', v_acc_total, -v_wht_before));
    perform pg_temp.assert(
      (select status = 'paid' and payment_reference = 'URA/2026/000123'
         from ins_wht_remittances where id = v_rem.id),
      '§14 the return records the payment and its reference');
    perform pg_temp.assert(
      (select count(*) from journal_entries
        where tenant_id = ta and source_type = 'ins_wht_remittance') = 1,
      '§14 and posts exactly one journal');

    -- A paid return is final: a refund is a conversation with URA, not a journal.
    perform pg_temp.jwt(admin2); set local role authenticated;
    perform pg_temp.expect_error(
      format($q$select public.ins_wht_void_remittance(%L, 'changed our mind about paying it')$q$, v_rem.id),
      'INS_WHT_ALREADY_PAID',
      '§14 a paid return cannot be voided');
    perform pg_temp.assert(
      (public.ins_wht_pay_remittance(v_rem.id, v_opbank, current_date, 'URA/2026/000123') ->> 'already_paid')::boolean,
      '§14 and paying it twice is reported rather than repeated');
    reset role;

    v_pos := public.ins_wht_position();
    perform pg_temp.assert((v_pos ->> 'paid_total')::numeric = v_acc_total
                       and (v_pos ->> 'unreported')::numeric = 0
                       and (v_pos ->> 'awaiting_payment')::numeric = 0,
      format('§14 the position is settled: nothing unreported, nothing awaiting payment (%s)', v_pos::text));

    -- -------------------------------------------------------------------
    -- §14b voiding an open return releases its lines, so the tax can be reported
    -- -------------------------------------------------------------------
    -- The realistic need: a return is prepared, then a commission is reversed
    -- before the return is filed. The tax has to come off the bill, and the
    -- accrual has to be available to a fresh return. Void does that; delete does
    -- not exist.
    v_client14 := ins_register_client('WHT void client', 'corporate', null, null, null, 'low');
    insert into ins_intermediaries(tenant_id, code, kind, name, category, status, parent_id)
      values (ta, 'SUB9', 'individual', 'Sub agent void test', 'sub_agent', 'active', v_ref)
      returning id into v_sub14;

    perform pg_temp.jwt(admin1); set local role authenticated;
    v_term14 := public.ins_set_intermediary_term(v_sub14, 'pct_of_broker_commission', date '2020-07-01', 40);
    reset role;
    perform pg_temp.jwt(admin2); set local role authenticated;
    perform public.ins_approve_intermediary_term(v_term14.id);
    reset role;

    v_pol14 := ins_create_policy(v_client14.id, v_insurer, v_line, current_date, current_date + 365,
                                 5000000, 'UGX', 5000000, 15, null, v_sub14, 'WHT void test', null);
    perform pg_temp.one_share(v_pol14.id, v_insurer, 15);
    perform pg_temp.jwt(mgr); set local role authenticated;
    v_pol14 := pg_temp.approve_and_bind(v_pol14.id);
    reset role;

    -- Next month, so it is a clean period with exactly one accrual.
    perform pg_temp.recognise(v_pol14.id, 750000);
    perform pg_temp.assert(
      (select wht_amount from ins_agent_commission_accruals where policy_id = v_pol14.id) = 30000,
      '§14b the new policy withholds 30,000 in its own right');

    perform pg_temp.jwt(mgr); set local role authenticated;
    v_prep := public.ins_wht_prepare_remittance(
      date_trunc('month', current_date)::date,
      (date_trunc('month', current_date) + interval '1 month - 1 day')::date, 'UGX');
    reset role;
    perform pg_temp.assert((v_prep ->> 'prepared')::boolean
                       and (v_prep ->> 'lines')::int = 1,
      format('§14b a second return is prepared for the one newly withheld 30,000 (%s)', v_prep::text));

    -- A void needs a reason worth reading.
    perform pg_temp.jwt(mgr); set local role authenticated;
    perform pg_temp.expect_error(
      format($q$select public.ins_wht_void_remittance(%L, 'oops')$q$, (v_prep ->> 'remittance_id')::uuid),
      'INS_WHT_VOID_REASON',
      '§14b voiding needs a reason of real length');
    perform pg_temp.assert(
      (public.ins_wht_void_remittance((v_prep ->> 'remittance_id')::uuid,
        'commission reversed before filing; tax must come off this return') ->> 'void')::boolean,
      '§14b the return is voided');
    reset role;

    -- The lines are released, so the same tax is reportable again -- and the void
    -- return is still on file as a record that it happened.
    perform pg_temp.assert(
      (select count(*) from ins_wht_remittance_lines
        where tenant_id = ta and remittance_id = (v_prep ->> 'remittance_id')::uuid) = 0,
      '§14b voiding released the lines');
    perform pg_temp.assert(
      (select status from ins_wht_remittances where id = (v_prep ->> 'remittance_id')::uuid) = 'void',
      '§14b and the return itself is kept, marked void');

    perform pg_temp.jwt(mgr); set local role authenticated;
    v_prep := public.ins_wht_prepare_remittance(
      date_trunc('month', current_date)::date,
      (date_trunc('month', current_date) + interval '1 month - 1 day')::date, 'UGX');
    reset role;
    perform pg_temp.assert((v_prep ->> 'prepared')::boolean
                       and (v_prep ->> 'amount')::numeric = 30000,
      format('§14b the released 30,000 can be reported on a fresh return (got %s)', v_prep::text));

    -- -------------------------------------------------------------------
    -- §15 the agent's statement tells them what happened to their tax
    -- -------------------------------------------------------------------
    -- A sub-agent reading a statement needs one thing this build can now say and
    -- could not before: whether the money withheld is gone for good or will be
    -- trued up when they declare. Same 10%, different sentence.
    perform pg_temp.jwt(admin2); set local role authenticated;
    v_pos := public.ins_agent_commission_statement(v_sub14);
    reset role;
    perform pg_temp.assert((v_pos ->> 'gross_commission')::numeric = 300000,
      format('§15 the statement shows the gross, 300,000 (got %s)', v_pos ->> 'gross_commission'));
    perform pg_temp.assert((v_pos ->> 'wht_withheld')::numeric = 30000,
      format('§15 the tax withheld, 30,000 (got %s)', v_pos ->> 'wht_withheld'));
    perform pg_temp.assert((v_pos ->> 'net_commission')::numeric = 270000,
      format('§15 and the net, 270,000 (got %s)', v_pos ->> 'net_commission'));
    perform pg_temp.assert(
      (select bool_and((l ->> 'wht_is_final')::boolean)
         from jsonb_array_elements(v_pos -> 'lines') l),
      '§15 the line records that this withholding was FINAL, because the policy incepted after 1 July 2026');
    perform pg_temp.assert((v_pos ->> 'outstanding')::numeric = 270000,
      format('§15 nothing has been paid yet, so all 270,000 is outstanding (got %s)', v_pos ->> 'outstanding'));

    -- The other side of the boundary, on a real statement: the sub-agent from
    -- §10c, whose policy incepted before 1 July 2026. Same 30,000 withheld, same
    -- 270,000 net -- and the statement must say this one was NOT final, because
    -- that agent still has to account for it. Asserting only a final line would
    -- pass even if the flag were hard-coded to true.
    perform pg_temp.jwt(admin2); set local role authenticated;
    v_pos := public.ins_agent_commission_statement(
      (select id from ins_intermediaries where tenant_id = ta and code = 'SUB0'));
    reset role;
    perform pg_temp.assert((v_pos ->> 'wht_withheld')::numeric = 30000
                       and (v_pos ->> 'net_commission')::numeric = 270000,
      format('§15 the pre-boundary agent has the same 30,000 / 270,000 (%s)', v_pos::text));
    perform pg_temp.assert(
      (select not (l ->> 'wht_is_final')::boolean
         from jsonb_array_elements(v_pos -> 'lines') l),
      '§15 but their line says the withholding was NOT final, because it was not on that date');

    -- Paying the agent clears the outstanding balance, and only to the net.
    -- The share has to become eligible first: calculation and payment are
    -- separate moments (§7), and withholding changes neither of them.
    perform pg_temp.jwt(mgr); set local role authenticated;
    perform public.ins_agent_commission_mark_eligible(v_pol14.id);
    perform pg_temp.assert(
      (public.ins_agent_commission_pay(
         (select id from ins_agent_commission_accruals where policy_id = v_pol14.id),
         v_opbank, current_date, 'net of withholding') ->> 'amount')::numeric = 270000,
      '§15 paying the agent pays 270,000, not 300,000');
    reset role;

    perform pg_temp.jwt(admin2); set local role authenticated;
    v_pos := public.ins_agent_commission_statement(v_sub14);
    reset role;
    perform pg_temp.assert((v_pos ->> 'paid')::numeric = 270000
                       and (v_pos ->> 'outstanding')::numeric = 0,
      format('§15 after payment the statement shows 270,000 paid and nothing outstanding (%s)', v_pos::text));
  end;

  -- -------------------------------------------------------------------
  -- §16 reversing a share with withholding must unwind ALL THREE legs
  -- -------------------------------------------------------------------
  -- The reversal was written when an accrual had two legs. With three it must
  -- credit the expense gross, debit the payable NET, and debit the tax back out
  -- of wht_payable -- each for exactly what the accrual put there. A reversal that
  -- debits ap_control for the gross clears 30,000 that was never credited to it
  -- and leaves a debit balance on a payable account, which is the kind of thing
  -- that sits on a reconciliation for a year.
  reset role;
  declare
    v_client16 ins_clients%rowtype;
    v_pol16    ins_policies%rowtype;
    v_sub16    uuid;
    v_term16   public.ins_intermediary_terms;
    v_acc16    public.ins_agent_commission_accruals;
    v_rev      jsonb;
    v_rev_je   uuid;
    v_ap_before numeric;
    v_wht_before numeric;
  begin
    v_client16 := ins_register_client('Reversal with tax client', 'corporate', null, null, null, 'low');
    insert into ins_intermediaries(tenant_id, code, kind, name, category, status, parent_id)
      values (ta, 'SUB8', 'individual', 'Sub agent reversal tax', 'sub_agent', 'active', v_ref)
      returning id into v_sub16;

    perform pg_temp.jwt(admin1); set local role authenticated;
    v_term16 := public.ins_set_intermediary_term(v_sub16, 'pct_of_broker_commission', date '2020-07-01', 40);
    reset role;
    perform pg_temp.jwt(admin2); set local role authenticated;
    perform public.ins_approve_intermediary_term(v_term16.id);
    reset role;

    v_pol16 := ins_create_policy(v_client16.id, v_insurer, v_line, current_date, current_date + 365,
                                 5000000, 'UGX', 5000000, 15, null, v_sub16, 'reversal tax test', null);
    perform pg_temp.one_share(v_pol16.id, v_insurer, 15);
    perform pg_temp.jwt(mgr); set local role authenticated;
    v_pol16 := pg_temp.approve_and_bind(v_pol16.id);
    reset role;

    -- The baseline is taken BEFORE the accrual exists, so "back to where it was"
    -- means back to a balance this policy never touched. Capturing it afterwards
    -- would compare against a figure already containing the very credit being
    -- reversed, and the assertion would pass on a reversal that changed nothing.
    v_ap_before  := pg_temp.acct(ta, ap_gl);
    v_wht_before := pg_temp.acct(ta, wht_gl);

    perform pg_temp.recognise(v_pol16.id, 750000);
    select * into v_acc16 from ins_agent_commission_accruals where policy_id = v_pol16.id;
    perform pg_temp.assert(v_acc16.gross_amount = 300000 and v_acc16.wht_amount = 30000
                       and v_acc16.net_amount = 270000,
      format('§16 the share to unwind is 300,000 / 30,000 / 270,000 (got %s / %s / %s)',
             v_acc16.gross_amount, v_acc16.wht_amount, v_acc16.net_amount));

    -- The accrual itself moved both: ap_control by the net, wht_payable by the tax.
    perform pg_temp.assert(pg_temp.acct(ta, ap_gl) = v_ap_before - 270000,
      format('§16 accruing moved ap_control by the net 270,000 (got %s)',
             pg_temp.acct(ta, ap_gl) - v_ap_before));
    perform pg_temp.assert(pg_temp.acct(ta, wht_gl) = v_wht_before - 30000,
      format('§16 and wht_payable by the tax 30,000 (got %s)',
             pg_temp.acct(ta, wht_gl) - v_wht_before));

    perform pg_temp.jwt(mgr); set local role authenticated;
    v_rev := public.ins_agent_commission_reverse(v_acc16.id, 'policy cancelled before settlement');
    reset role;
    perform pg_temp.assert((v_rev ->> 'reversed')::boolean, '§16 the share reverses');
    perform pg_temp.assert((v_rev ->> 'wht_reversed')::numeric = 30000,
      format('§16 and it reports the tax it unwound (got %s)', v_rev ->> 'wht_reversed'));

    v_rev_je := (v_rev ->> 'journal_entry_id')::uuid;
    -- Each leg is exactly the mirror of what the accrual posted.
    perform pg_temp.assert(pg_temp.acct_je(v_rev_je, expense_gl) = -300000,
      format('§16 the expense is credited by the gross, 300,000 (got %s)',
             pg_temp.acct_je(v_rev_je, expense_gl)));
    perform pg_temp.assert(pg_temp.acct_je(v_rev_je, ap_gl) = 270000,
      format('§16 the payable is debited by the NET, 270,000 -- not the gross (got %s)',
             pg_temp.acct_je(v_rev_je, ap_gl)));
    perform pg_temp.assert(pg_temp.acct_je(v_rev_je, wht_gl) = 30000,
      format('§16 the tax is debited out of wht_payable, 30,000 (got %s)',
             pg_temp.acct_je(v_rev_je, wht_gl)));
    perform pg_temp.assert(
      (select coalesce(sum(l.debit), 0) = coalesce(sum(l.credit), 0)
         from journal_entry_lines l where l.journal_entry_id = v_rev_je),
      '§16 the reversal entry balances');

    -- And the balances return to exactly where they were: nothing left on the
    -- payable, and nothing owed to URA for a commission that was cancelled.
    perform pg_temp.assert(pg_temp.acct(ta, ap_gl) = v_ap_before,
      format('§16 ap_control is back to %s (got %s)', v_ap_before, pg_temp.acct(ta, ap_gl)));
    perform pg_temp.assert(pg_temp.acct(ta, wht_gl) = v_wht_before,
      format('§16 wht_payable is back to %s (got %s)', v_wht_before, pg_temp.acct(ta, wht_gl)));
  end;

  raise notice 'PASS: agent commission subledger (all scenarios)';
end $$;

-- ---------------------------------------------------------------------
-- Catalog-level assertions
-- ---------------------------------------------------------------------
-- The accrual helpers are internal; clients reach the subledger through the
-- payment and calculation RPCs, which are the ones with permission checks.
select pg_temp.assert(
  (select count(*) = 0 from information_schema.routine_privileges
    where routine_schema = 'public'
      and routine_name in ('ins_agent_commission_accrue', 'ins_agent_commission_backfill',
                           'ins_intermediary_terms_guard', 'ins_agent_commission_wht_guard')
      and grantee in ('anon', 'authenticated', 'PUBLIC')),
  'the accrual and guard helpers are owner-only');

select pg_temp.assert(
  (select count(*) = 3 from pg_policies
    where schemaname = 'public'
      and tablename in ('ins_intermediary_terms', 'ins_agent_commission_accruals',
                        'ins_agent_commission_events')
      and cmd = 'SELECT' and 'authenticated' = any (roles)),
  'all three new tables have an authenticated SELECT policy, and only for SELECT');

select pg_temp.assert('agent_commission_expense' = any (platform_gl_posting_roles()),
  'agent_commission_expense is a posting role');

select pg_temp.assert(
  (select count(*) = 1 from industry_template_items
    where template_key = 'insurance' and kind = 'posting_rule'
      and name = 'agent_commission_expense'),
  'the insurance template maps agent_commission_expense');

select pg_temp.assert(
  (select count(*) = 1 from industry_template_items
    where template_key = 'insurance' and kind = 'gl_account' and name = '5010'),
  'the insurance template carries the agent commission account');

-- ---------------------------------------------------------------------
-- Catalog: item 6b
-- ---------------------------------------------------------------------
select pg_temp.assert('wht_payable' = any (platform_gl_posting_roles()),
  'wht_payable is a posting role (it was in the baseline, unread by insurance until now)');
select pg_temp.assert(
  (select count(*) = 1 from industry_template_items
    where template_key = 'insurance' and kind = 'posting_rule' and name = 'wht_payable'),
  'the insurance template maps wht_payable, so a new company can withhold from day one');

-- Both new keys must be DECLARED, or the governance guard refuses every row for
-- them and the withholding can never be configured at all.
select pg_temp.assert(
  (select count(*) = 2 from regulatory_parameter_definitions
    where key in ('tax.wht_agent_commission_percent', 'tax.wht_agent_commission_is_final')),
  'both withholding keys are declared parameter definitions');
select pg_temp.assert(
  (select value_type = 'text' from regulatory_parameter_definitions
    where key = 'tax.wht_agent_commission_is_final'),
  'the character is a text value, because true/false is not a percentage');
select pg_temp.assert(
  (select value_type = 'percent' and not class_scoped from regulatory_parameter_definitions
    where key = 'tax.wht_agent_commission_percent'),
  'the rate is a single percentage, not varied by class');

-- The two remittance tables are read-only to clients: a return to the revenue
-- authority is prepared and paid through RPCs that check who is asking.
select pg_temp.assert(
  (select count(*) = 2 from pg_policies
    where schemaname = 'public'
      and tablename in ('ins_wht_remittances', 'ins_wht_remittance_lines')
      and cmd = 'SELECT' and 'authenticated' = any (roles)),
  'both withholding tables have an authenticated SELECT policy');
select pg_temp.assert(
  (select count(*) = 0 from information_schema.role_table_grants
    where table_schema = 'public'
      and table_name in ('ins_wht_remittances', 'ins_wht_remittance_lines')
      and grantee in ('anon', 'authenticated')
      and privilege_type in ('INSERT', 'UPDATE', 'DELETE')),
  'and no client can write to them directly');

-- The two RPCs that move money in and out are not open to anon.
select pg_temp.assert(
  (select count(*) = 0 from information_schema.routine_privileges
    where routine_schema = 'public'
      and routine_name in ('ins_wht_prepare_remittance', 'ins_wht_approve_remittance',
                           'ins_wht_pay_remittance', 'ins_wht_void_remittance')
      and grantee = 'anon'),
  'the withholding remittance RPCs are not granted to anon');

-- The identity constraint, proven rather than assumed: the database refuses an
-- accrual whose net does not equal gross less tax. Written with no withholding,
-- because a hand-written withholding figure is refused by the guard before the
-- constraint is ever reached (§10b) -- that is a different refusal, and testing
-- one by triggering the other would prove nothing about either.
do $$
begin
  begin
    insert into ins_agent_commission_accruals
      (tenant_id, policy_id, intermediary_id, basis, commission_base, gross_amount,
       wht_amount, net_amount, currency, status)
    select tenant_id, id, agent_id, 'pct_of_broker_commission', 1000, 1000, 0, 950, 'UGX', 'accrued'
      from ins_policies where agent_id is not null limit 1;
    raise exception 'FAIL: with no tax withheld, a net of 950 against a gross of 1000 must be refused';
  exception when check_violation then null;
  end;
end $$;
select pg_temp.assert(true, 'the database refuses a net that does not equal gross less withholding');

rollback;
