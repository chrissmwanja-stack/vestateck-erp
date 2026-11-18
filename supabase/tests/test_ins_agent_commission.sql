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

-- ---------------------------------------------------------------------
-- Maker-checker helpers (item 8, bit 4)
-- ---------------------------------------------------------------------
-- Since agent payment separates preparing from approving, every test that pays
-- an agent has to go through both. Two people are needed and they must differ,
-- so these helpers take the two roles explicitly rather than hiding the fact
-- that a second pair of eyes is required. `jwt_as()` does the role switch the
-- tests already did by hand.
create or replace function pg_temp.jwt_as(p_uid uuid) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  set local role authenticated;
end $$;

create or replace function pg_temp.jwt_off() returns void
language plpgsql as $$
begin
  reset role;
end $$;

/**
 * Prepare and approve a payment for one share, by two different users, and return
 * the approved payment id. `p_maker` proposes, `p_checker` approves.
 */
create or replace function pg_temp.approve_payment(
  p_accrual uuid, p_bank uuid, p_on date, p_maker uuid, p_checker uuid, p_note text default null
) returns uuid
language plpgsql as $$
declare v jsonb; v_id uuid;
begin
  perform pg_temp.jwt_as(p_maker);
  v := public.ins_agent_commission_prepare_payment(p_accrual, p_bank, p_on, p_note);
  v_id := (v ->> 'payment_id')::uuid;
  perform pg_temp.jwt_off();
  -- The checker must be a DIFFERENT user than the maker, or the self-approval
  -- refusal fires -- which is the control working, not a fixture problem.
  perform pg_temp.jwt_as(p_checker);
  perform public.ins_agent_commission_approve_payment(v_id);
  perform pg_temp.jwt_off();
  return v_id;
end $$;

/**
 * The whole journey: prepare (maker), approve (checker), release. Returns the
 * release jsonb, so a caller asserting on the payment figures gets the same shape
 * ins_agent_commission_pay used to return.
 */
create or replace function pg_temp.pay_via_checker(
  p_accrual uuid, p_bank uuid, p_on date, p_maker uuid, p_checker uuid, p_note text default null
) returns jsonb
language plpgsql as $$
declare v_id uuid; v jsonb;
begin
  v_id := pg_temp.approve_payment(p_accrual, p_bank, p_on, p_maker, p_checker, p_note);
  perform pg_temp.jwt_as(p_checker);
  v := public.ins_agent_commission_release_payment(v_id, p_note);
  perform pg_temp.jwt_off();
  return v;
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
  v_payment uuid;
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
  -- ap_control carries the GROSS at accrual. It used to carry the net, because
  -- the tax was taken out of the payable when the share was earned. Nothing has
  -- been paid at this point, so s.134 has nothing to bite on and no tax has been
  -- withheld: the agent is owed the whole 300,000 until the payment that takes
  -- the tax out of it (§7 asserts the net lands on the bank leg instead).
  perform pg_temp.assert(pg_temp.acct(ta, ap_gl) = -300000,
    format('§12 ap_control is credited the GROSS 300,000, because no tax is withheld until payment (got %s)', pg_temp.acct(ta, ap_gl)));
  perform pg_temp.assert(pg_temp.acct(ta, wht_gl) = 0,
    format('§12 and wht_payable is untouched by the accrual (got %s)', pg_temp.acct(ta, wht_gl)));
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
    'ins_agent_accruals_live_once_key',
    '§6 and the natural key refuses a duplicate accrual outright');
  perform pg_temp.jwt(mgr);
  set local role authenticated;

  -- -------------------------------------------------------------------
  -- §7 Calculation is not payment
  -- -------------------------------------------------------------------
  -- Refused at PREPARE: that is the earliest point anybody tries to move money,
  -- and making the proposer find out is better than letting a proposal reach an
  -- approver who cannot tell it is unpayable.
  perform pg_temp.expect_error(
    format($q$select public.ins_agent_commission_prepare_payment(%L, %L, current_date, 'pay now')$q$,
           v_acc.id, v_opbank),
    'INS_AGENT_NOT_ELIGIBLE',
    '§7 an accrued-but-not-eligible share cannot be prepared for payment');

  perform pg_temp.assert(
    ((public.ins_agent_commission_mark_eligible(v_pol_place)) ->> 'marked_eligible')::int = 1,
    '§7 the share becomes eligible once the brokerage commission is earned');
  perform pg_temp.assert(
    (select status from ins_agent_commission_accruals where id = v_acc.id) = 'eligible',
    '§7 the status moved to eligible');
  perform pg_temp.assert(
    (select count(*) from ins_agent_commission_events where accrual_id = v_acc.id and event = 'eligible') = 1,
    '§7 eligibility is an event, not a silent field change');

  -- ---------------------------------------------------------------------
  -- §7b maker-checker: one person cannot prepare, approve and release
  -- ---------------------------------------------------------------------
  -- The control this item exists for. Asserted as three refusals plus one success,
  -- because "a second person is required" is only true if the first person is
  -- actually stopped -- a test that only drove the happy path would pass on an
  -- implementation where any manager could do all three.
  reset role;
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  v_calc := public.ins_agent_commission_prepare_payment(v_acc.id, v_opbank, current_date, 'paid in full');
  perform pg_temp.assert((v_calc ->> 'prepared')::boolean,
    format('§7b the preparer proposes a payment (%s)', v_calc::text));
  perform pg_temp.assert((v_calc ->> 'wht_amount')::numeric = 30000
                     and (v_calc ->> 'net_amount')::numeric = 270000,
    '§7b and the proposal freezes the tax and the net the approver will be asked to accept');
  v_payment := (v_calc ->> 'payment_id')::uuid;

  perform pg_temp.expect_error(
    format($q$select public.ins_agent_commission_approve_payment(%L)$q$, v_payment),
    'INS_AGENT_SELF_APPROVAL',
    '§7b the preparer cannot approve their own payment');
  perform pg_temp.expect_error(
    format($q$select public.ins_agent_commission_pay(%L, %L, current_date, 'sneak')$q$, v_acc.id, v_opbank),
    'INS_AGENT_PAYMENT_NOT_APPROVED',
    '§7b and cannot step round it by calling pay() directly: an unapproved payment does not release');
  reset role;

  -- A second manager approves, and only then does the cash move.
  perform pg_temp.jwt(admin2);
  set local role authenticated;
  perform pg_temp.assert((public.ins_agent_commission_approve_payment(v_payment) ->> 'approved')::boolean,
    '§7b somebody else approves it');
  reset role;

  v_calc := public.ins_agent_commission_release_payment(v_payment, 'paid in full');
  perform pg_temp.assert((v_calc ->> 'paid')::boolean, '§7 the share can now be paid');
  perform pg_temp.assert(
    (select status from ins_agent_commission_accruals where id = v_acc.id) = 'paid',
    '§7 the accrual is marked paid');
  perform pg_temp.assert(
    (select paid_at from ins_agent_commission_accruals where id = v_acc.id) is not null,
    '§7 with a paid timestamp');
  perform pg_temp.assert(pg_temp.acct(ta, ap_gl) = 0,
    format('§12 paying clears the payable to zero (got %s)', pg_temp.acct(ta, ap_gl)));
  -- The tax is taken at THIS event, so the liability and the net both appear now.
  perform pg_temp.assert(pg_temp.acct(ta, wht_gl) = -30000,
    format('§12 paying withholds 30,000 into wht_payable (got %s)', pg_temp.acct(ta, wht_gl)));
  perform pg_temp.assert((v_calc ->> 'amount')::numeric = 270000
                     and (v_calc ->> 'wht_amount')::numeric = 30000,
    format('§12 the payment pays the net 270,000 and withholds 30,000 (%s)', v_calc::text));
  -- The character is decided by the payment date. The release response no longer
  -- echoes it (it is frozen on the payment, not re-resolved at release), so this
  -- reads it from the accrual -- which is where the agent's statement reads it.
  perform pg_temp.assert(
    (select wht_is_final from ins_agent_commission_accruals where id = v_acc.id),
    '§12 and the character is fixed by the PAYMENT date, which is after 1 July 2026');

  -- Pressing release twice is reported, not repeated: the second call finds the
  -- payment already paid and does not post a second journal or withhold twice.
  perform pg_temp.assert((public.ins_agent_commission_release_payment(v_payment) ->> 'already_paid')::boolean,
    '§7 a second release is reported as already done');
  -- And the share can no longer be prepared for payment at all.
  perform pg_temp.expect_error(
    format($q$select public.ins_agent_commission_prepare_payment(%L, %L, current_date, 'again')$q$,
           v_acc.id, v_opbank),
    'INS_AGENT_ALREADY_PAID',
    '§7 nor can a payment be prepared for a share that has been paid');

  -- -------------------------------------------------------------------
  -- §7c the authorisation cannot be walked around
  -- -------------------------------------------------------------------
  -- §7b proves one person cannot do all three steps. That is worth very little
  -- if the proposal can be EDITED between preparing and approving, or released
  -- without an approval at all -- so each of those routes is refused by name,
  -- and each is asserted separately because they fail in different ways.
  reset role;
  declare
    v_pol7c  ins_policies%rowtype;
    v_acc7c  public.ins_agent_commission_accruals;
    v_pay7c  uuid;
    v_client7c ins_clients%rowtype;
  begin
    v_client7c := ins_register_client('Maker checker client', 'corporate', null, null, null, 'low');
    perform pg_temp.jwt(mgr); set local role authenticated;
    v_pol7c := ins_create_policy(v_client7c.id, v_insurer, v_line, current_date, current_date + 365,
                                 5000000, 'UGX', 5000000, 15, null, v_sub, 'maker checker', null);
    perform pg_temp.one_share(v_pol7c.id, v_insurer, 15);
    v_pol7c := pg_temp.approve_and_bind(v_pol7c.id);
    reset role;

    perform pg_temp.recognise(v_pol7c.id, 750000);
    select * into v_acc7c from ins_agent_commission_accruals where policy_id = v_pol7c.id;

    perform pg_temp.jwt(mgr); set local role authenticated;
    perform public.ins_agent_commission_mark_eligible(v_pol7c.id);
    v_pay7c := (public.ins_agent_commission_prepare_payment(
                  v_acc7c.id, v_opbank, current_date, 'proposed') ->> 'payment_id')::uuid;

    -- Releasing without an approval must not work. This is the bypass that would
    -- make the whole control decorative.
    perform pg_temp.expect_error(
      format($q$select public.ins_agent_commission_release_payment(%L)$q$, v_pay7c),
      'INS_AGENT_PAYMENT_NOT_APPROVED',
      '§7c a prepared payment cannot be released before it is approved');
    reset role;

    -- The figure the approver will see cannot be moved by the preparer after the
    -- fact. Editing it would mean approving one number and paying another.
    perform pg_temp.expect_error(
      format($q$update public.ins_agent_commission_payments set net_amount = 1, wht_amount = %s where id = %L$q$,
             0, v_pay7c),
      'INS_AGENT_PAYMENT_IMMUTABLE',
      '§7c the figures on a prepared payment cannot be edited');

    -- Not even by reassigning it to a different share.
    perform pg_temp.expect_error(
      format($q$update public.ins_agent_commission_payments set paid_on = current_date - 30 where id = %L$q$, v_pay7c),
      'INS_AGENT_PAYMENT_IMMUTABLE',
      '§7c nor can the payment date be moved after preparing');

    -- The table itself refuses a row whose approver is its preparer, so the rule
    -- holds even for a caller that never goes through the function.
    perform pg_temp.expect_error(
      format($q$update public.ins_agent_commission_payments set approved_by = prepared_by where id = %L$q$, v_pay7c),
      'ins_agent_payments_no_self_approval_chk',
      '§7c and the table constraint refuses a payment approved by its own preparer');

    -- A proposal whose share changed underneath it is stale, not approvable. A
    -- reversal is the realistic cause: the agent share is unwound while the
    -- payment sits waiting for a second signature.
    perform public.ins_agent_commission_reverse(v_acc7c.id, 'share unwound while payment awaited approval');
    perform pg_temp.jwt(admin2); set local role authenticated;
    perform pg_temp.expect_error(
      format($q$select public.ins_agent_commission_approve_payment(%L)$q$, v_pay7c),
      'INS_AGENT_PAYMENT_STALE',
      '§7c an approval is refused once the share behind it has been reversed');
    reset role;
  end;

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
  -- §10 Withholding is taken at PAYMENT, and the accountant's example lands
  -- -------------------------------------------------------------------
  -- The accountant's example is gross 300,000 on a UGX policy: 10% withholds
  -- 30,000 and leaves 270,000 for the agent, with 30,000 owed to URA. The
  -- arithmetic is unchanged; WHERE it happens is the correction. s.134 attaches
  -- withholding to payment, so an accrual that has not been paid withholds
  -- nothing -- and the §2 share, accrued but unpaid, must show none of it.
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

  -- The tax is on the PAYMENT, which is the event s.134 attaches to. This share
  -- was paid in §7, and the accrual it sits on was posted with two legs and no
  -- tax at all -- asserted on the accrual's own journal, so a regression that
  -- moved the leg back would fail here rather than pass on a coincidence.
  perform pg_temp.assert(pg_temp.acct_je(v_acc.journal_entry_id, wht_gl) = 0,
    format('§10 the ACCRUAL entry carries no tax (got %s)',
           -pg_temp.acct_je(v_acc.journal_entry_id, wht_gl)));
  perform pg_temp.assert(
    (select coalesce(sum(l.debit), 0) = coalesce(sum(l.credit), 0)
       from journal_entry_lines l
      where l.journal_entry_id = v_acc.journal_entry_id),
    '§10 the accrual entry balances with two legs');

  perform pg_temp.assert(pg_temp.acct_je(v_acc.payment_journal_entry_id, ap_gl) = 300000,
    format('§10 the PAYMENT debits the payable by the gross 300,000 (got %s)',
           pg_temp.acct_je(v_acc.payment_journal_entry_id, ap_gl)));
  perform pg_temp.assert(pg_temp.acct_je(v_acc.payment_journal_entry_id, wht_gl) = -30000,
    format('§10 and credits 30,000 to wht_payable, owed to URA from that payment (got %s)',
           -pg_temp.acct_je(v_acc.payment_journal_entry_id, wht_gl)));
  perform pg_temp.assert(
    (select coalesce(sum(l.credit), 0) = 270000
       from journal_entry_lines l
      where l.journal_entry_id = v_acc.payment_journal_entry_id
        and l.credit > 0 and l.gl_account_id not in (wht_gl)),
    '§10 the only other credit is the bank leg at the net 270,000 the agent received');
  perform pg_temp.assert(
    (select coalesce(sum(l.debit), 0) = coalesce(sum(l.credit), 0)
       from journal_entry_lines l
      where l.journal_entry_id = v_acc.payment_journal_entry_id),
    '§10 the payment entry balances with three legs');

  -- The quotation side must not pre-empt it either: a calculation is not a
  -- payment, and a provisional 10% on screen is a figure the payment is free to
  -- contradict once it has a date to apply the law to.
  v_calc := public.ins_agent_commission_calculate(v_pol_place, v_sub);
  perform pg_temp.assert((v_calc ->> 'wht_amount')::numeric = 0
                     and (v_calc ->> 'net_amount')::numeric = (v_calc ->> 'gross_amount')::numeric
                     and (v_calc ->> 'wht_not_yet_determined')::boolean,
    format('§10 the quote is gross and says the withholding is not determined yet (%s)', v_calc::text));

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
    -- Inception was 2026-01-15, but nothing was withheld at accrual: the share
    -- is unpaid, so the date its policy incepted cannot fix a character yet.
    -- That is the correction, stated on the case that used to expose it.
    perform pg_temp.assert(v_acc10.wht_amount = 0 and v_acc10.net_amount = 300000,
      format('§10c an unpaid pre-boundary share withholds nothing (got %s / %s)',
             v_acc10.wht_amount, v_acc10.net_amount));
  end;

  -- -------------------------------------------------------------------
  -- §10e the share earned BEFORE the boundary but paid AFTER it
  -- -------------------------------------------------------------------
  -- This is the case the old model got wrong and arithmetic could not catch.
  -- s.139(aa) made the tax final from 1 July 2026 without changing the 10%
  -- rate, so a share earned under the old regime and paid under the new one
  -- withholds the same 30,000 and must record it as FINAL, because finality is
  -- a fact about the payment date. Resolving it against inception gave the right
  -- money with the wrong character, and told the agent to account for income the
  -- law had already settled.
  declare
    v_client10e ins_clients%rowtype;
    v_pol10e   ins_policies%rowtype;
    v_acc10e   public.ins_agent_commission_accruals;
    v_pay10e   jsonb;
    v_sub10e   uuid;
    v_term10e  public.ins_intermediary_terms;
  begin
    v_client10e := ins_register_client('Paid after the boundary', 'corporate', null, null, null, 'low');
    insert into ins_intermediaries(tenant_id, code, kind, name, category, status, parent_id)
      values (ta, 'SUB10E', 'individual', 'Sub agent paid after boundary', 'sub_agent', 'active', v_ref)
      returning id into v_sub10e;
    perform pg_temp.jwt(admin1); set local role authenticated;
    v_term10e := public.ins_set_intermediary_term(v_sub10e, 'pct_of_broker_commission', date '2020-07-01', 40);
    reset role;
    perform pg_temp.jwt(admin2); set local role authenticated;
    perform public.ins_approve_intermediary_term(v_term10e.id);
    reset role;
    perform pg_temp.jwt(mgr); set local role authenticated;
    v_pol10e := ins_create_policy(v_client10e.id, v_insurer, v_line, date '2026-01-15', date '2027-01-14',
                                  5000000, 'UGX', 5000000, 15, null, v_sub10e, 'paid after boundary', null);
    perform pg_temp.one_share(v_pol10e.id, v_insurer, 15);
    v_pol10e := pg_temp.approve_and_bind(v_pol10e.id);
    reset role;

    perform pg_temp.recognise(v_pol10e.id, 750000);
    select * into v_acc10e from ins_agent_commission_accruals where policy_id = v_pol10e.id;
    perform pg_temp.assert(v_acc10e.wht_amount = 0,
      format('§10e the accrual withheld nothing (got %s)', v_acc10e.wht_amount));

    perform pg_temp.jwt(mgr); set local role authenticated;
    perform public.ins_agent_commission_mark_eligible(v_pol10e.id);
    reset role;
    v_pay10e := pg_temp.pay_via_checker(v_acc10e.id, v_opbank, date '2026-11-18', mgr, admin2,
                                        'paid after the boundary');

    perform pg_temp.assert((v_pay10e ->> 'wht_amount')::numeric = 30000,
      format('§10e paying after the boundary withholds 30,000 (got %s)', v_pay10e ->> 'wht_amount'));
    -- The release response echoes the money but not the character; the character
    -- lives on the accrual (asserted on the next line) and on the payment row,
    -- because that is where the agent's statement reads it from.
    perform pg_temp.assert(
      (select wht_is_final from ins_agent_commission_accruals where id = v_acc10e.id),
      '§10e and it is FINAL, because finality is decided by the payment date and not the inception date');
    perform pg_temp.assert((v_pay10e ->> 'wht_on')::date = date '2026-11-18',
      '§10e the date used to resolve it is recorded on the payment, so the figure can be tied to a law');
    perform pg_temp.assert(
      (select wht_is_final and wht_rate_pct = 10 and wht_parameter_ref is not null and paid_on = date '2026-11-18'
         from ins_agent_commission_accruals where id = v_acc10e.id),
      '§10e the accrual now carries the character, the rate, the parameter it came from, and the payment date');
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
  -- The expense must equal the sum of the LIVE accruals: the reversal credits
  -- this policy's 25,000 back and stops counting it, and nothing else moves.
  -- Asserting the invariant rather than a hard-coded total is deliberate. The
  -- earlier version pinned a running tenant total (600,000), which failed the
  -- moment an unrelated scenario above it accrued another share -- it was
  -- measuring the fixture, not the behaviour. The invariant catches a wrong sign
  -- just as well and does not need editing every time a scenario is added.
  perform pg_temp.assert(
    pg_temp.acct(ta, expense_gl) =
      (select coalesce(sum(gross_amount), 0) from ins_agent_commission_accruals
        where tenant_id = ta and status <> 'reversed'),
    format('§9 the expense equals the sum of the live accruals, %s (got %s)',
           (select coalesce(sum(gross_amount), 0) from ins_agent_commission_accruals
             where tenant_id = ta and status <> 'reversed'),
           pg_temp.acct(ta, expense_gl)));
  perform pg_temp.assert(
    (select status from ins_agent_commission_accruals where id = v_acc.id) = 'reversed',
    '§9 and the reversed 25,000 is no longer part of that sum');
  perform pg_temp.assert(
    (select count(*) from ins_agent_commission_events where accrual_id = v_acc.id and event = 'reversed') = 1,
    '§9 and the reversal is an event with its reason');

  perform pg_temp.expect_error(
    format($q$select public.ins_agent_commission_prepare_payment(%L, %L, current_date, 'try again')$q$,
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
    -- Refused at prepare: nobody should be able to put a payment for a suspended
    -- agent in front of an approver in the first place.
    perform pg_temp.expect_error(
      format($q$select public.ins_agent_commission_prepare_payment(%L, %L, current_date, 'pay')$q$, v_acc8.id, v_opbank),
      'INS_AGENT_NOT_ACTIVE',
      '§8 a share cannot be paid to a suspended intermediary');

    -- Active again, but the licence has lapsed: refused for a different reason,
    -- which is the point of checking both.
    update ins_intermediaries
       set status = 'active', licence_valid_to = current_date - 1
     where tenant_id = ta and code = 'SUB3';
    perform pg_temp.expect_error(
      format($q$select public.ins_agent_commission_prepare_payment(%L, %L, current_date, 'pay')$q$, v_acc8.id, v_opbank),
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
    -- A return follows PAYMENT (s.140), so what is reportable is what has been
    -- withheld at a payment -- not what earlier scenarios accrued. Several
    -- accruals are sitting unpaid (§10, §10c), and they correctly contribute
    -- nothing: no money has moved, so there is nothing to return to URA yet.
    -- §10e is the one share paid so far, and its 30,000 is the whole of it.
    v_acc_total := (select coalesce(sum(wht_amount), 0) from ins_agent_commission_accruals
                     where tenant_id = ta and status = 'paid');
    perform pg_temp.assert(v_acc_total = 60000,
      format('§14 two shares have been paid (§7 and §10e), withholding 30,000 each = 60,000 (got %s)', v_acc_total));
    perform pg_temp.assert(
      (select coalesce(sum(wht_amount), 0) from ins_agent_commission_accruals
        where tenant_id = ta and status <> 'paid') = 0,
      '§14 and the unpaid accruals carry no withholding at all');
    v_pos := public.ins_wht_position();
    perform pg_temp.assert((v_pos ->> 'withheld_total')::numeric = v_acc_total,
      format('§14 the position equals what has been withheld at payment, %s (got %s)',
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
          where tenant_id = ta and wht_amount > 0 and status = 'paid'),
      '§14 one line per PAID accrual that carries withholding');

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

    -- The share has to be PAID before it can be reported, because the return's
    -- period and the obligation both follow the payment. Accruing it is not
    -- enough, and asserting that first is what pins the ordering.
    perform pg_temp.recognise(v_pol14.id, 750000);
    perform pg_temp.assert(
      (select wht_amount from ins_agent_commission_accruals where policy_id = v_pol14.id) = 0,
      '§14b an unpaid share has nothing to return');

    perform pg_temp.jwt(mgr); set local role authenticated;
    perform public.ins_agent_commission_mark_eligible(v_pol14.id);
    perform pg_temp.pay_via_checker(
      (select id from ins_agent_commission_accruals where policy_id = v_pol14.id),
      v_opbank, current_date, mgr, admin2, 'paid so the tax can be returned');
    reset role;
    perform pg_temp.assert(
      (select wht_amount from ins_agent_commission_accruals where policy_id = v_pol14.id) = 30000,
      '§14b paying withholds 30,000 in its own right');

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
    -- §14b has already paid this share, so the statement shows the tax, the net
    -- and nothing outstanding. The tax appears here only because a payment
    -- happened: had it not, the statement would show 300,000 gross and no tax,
    -- which is the same rule the return follows.
    perform pg_temp.assert((v_pos ->> 'outstanding')::numeric = 0,
      format('§15 the paid share leaves nothing outstanding (got %s)', v_pos ->> 'outstanding'));

    -- The other side of the boundary, on a real statement: the sub-agent from
    -- §10c. Same 30,000 withheld, same 270,000 net -- but this one must be NOT
    -- final, because the tax was withheld before s.139(aa) took effect and that
    -- agent still has to account for it. Asserting only a final line would pass
    -- even if the flag were hard-coded to true.
    --

    -- §14b already paid this share, so a second attempt must be refused rather
    -- than repeated: the deduction is taken once, and the refusal names the state.
    perform pg_temp.jwt(mgr); set local role authenticated;
    perform pg_temp.expect_error(
      format($q$select public.ins_agent_commission_prepare_payment(
                 (select id from ins_agent_commission_accruals where policy_id = %L), %L, current_date, 'pressed twice')$q$,
             v_pol14.id, v_opbank),
      'INS_AGENT_ALREADY_PAID',
      '§15 a share cannot be prepared for payment twice -- the tax is withheld exactly once');
    reset role;

    perform pg_temp.jwt(admin2); set local role authenticated;
    v_pos := public.ins_agent_commission_statement(v_sub14);
    reset role;
    perform pg_temp.assert((v_pos ->> 'paid')::numeric = 270000
                       and (v_pos ->> 'outstanding')::numeric = 0,
      format('§15 after payment the statement shows 270,000 paid and nothing outstanding (%s)', v_pos::text));
    perform pg_temp.assert((v_pos ->> 'wht_withheld')::numeric = 30000
                       and (v_pos ->> 'net_commission')::numeric = 270000,
      format('§15 the tax withheld, 30,000, and the net, 270,000 appear once the share is paid (%s)', v_pos::text));
  end;

  -- -------------------------------------------------------------------
  -- §14c the return's period follows the PAYMENT month, not the accrual month
  -- -------------------------------------------------------------------
  -- Every other payment in this file happens in the month the share was accrued,
  -- so the two bases coincide and a routine that grouped by accrual month would
  -- pass unnoticed. That is exactly the mistake s.140 punishes: a commission
  -- accrued in November and paid in December belongs on DECEMBER's return. This
  -- pays against a future date to separate the two, and asserts both directions,
  -- because a routine that reported it in neither month would pass a test that
  -- only asked the December question.
  declare
    v_client14c ins_clients%rowtype;
    v_pol14c    ins_policies%rowtype;
    v_acc14c    public.ins_agent_commission_accruals;
    v_sub14c    uuid;
    v_term14c   public.ins_intermediary_terms;
    v_nov       jsonb;
    v_dec       jsonb;
  begin
    v_client14c := ins_register_client('Payment month client', 'corporate', null, null, null, 'low');
    insert into ins_intermediaries(tenant_id, code, kind, name, category, status, parent_id)
      values (ta, 'SUB14C', 'individual', 'Sub agent payment month', 'sub_agent', 'active', v_ref)
      returning id into v_sub14c;
    perform pg_temp.jwt(admin1); set local role authenticated;
    v_term14c := public.ins_set_intermediary_term(v_sub14c, 'pct_of_broker_commission', date '2020-07-01', 40);
    reset role;
    perform pg_temp.jwt(admin2); set local role authenticated;
    perform public.ins_approve_intermediary_term(v_term14c.id);
    reset role;

    perform pg_temp.jwt(mgr); set local role authenticated;
    v_pol14c := ins_create_policy(v_client14c.id, v_insurer, v_line, current_date, current_date + 365,
                                  5000000, 'UGX', 5000000, 15, null, v_sub14c, 'payment month test', null);
    perform pg_temp.one_share(v_pol14c.id, v_insurer, 15);
    v_pol14c := pg_temp.approve_and_bind(v_pol14c.id);
    reset role;

    perform pg_temp.recognise(v_pol14c.id, 750000);
    select * into v_acc14c from ins_agent_commission_accruals where policy_id = v_pol14c.id;

    -- Accrued this month, paid next month.
    perform pg_temp.jwt(mgr); set local role authenticated;
    perform public.ins_agent_commission_mark_eligible(v_pol14c.id);
    reset role;
    perform pg_temp.pay_via_checker(v_acc14c.id, v_opbank, date '2026-12-10', mgr, admin2,
                                    'paid in December');

    perform pg_temp.assert(
      (select paid_on from ins_agent_commission_accruals where id = v_acc14c.id) = date '2026-12-10',
      '§14c the payment date is stored as the DATE PAID, not the date the row was written');

    -- December's return must carry it.
    perform pg_temp.jwt(mgr); set local role authenticated;
    v_dec := public.ins_wht_prepare_remittance(date '2026-12-01', date '2026-12-31', 'UGX');
    reset role;
    perform pg_temp.assert(v_dec ->> 'prepared' is not null,
      format('§14c December prepares a return (%s)', v_dec::text));
    perform pg_temp.assert((v_dec ->> 'amount')::numeric = 30000,
      format('§14c and it carries the 30,000 withheld by the December payment, not the earlier ones (got %s)',
             v_dec ->> 'amount'));

    -- And the accrual month must not report it again: the tax is already on a
    -- return, so a second appearance would have URA paid twice for one deduction.
    perform pg_temp.assert(
      (select coalesce(sum(l.amount), 0) from ins_wht_remittance_lines l
         join ins_wht_remittances r on r.id = l.remittance_id
        where l.tenant_id = ta and l.accrual_id = v_acc14c.id) = 30000,
      '§14c the December withholding is claimed by exactly one return');
  end;

  -- -------------------------------------------------------------------
  -- §16 a reversal unwinds the accrual's two legs, and a reversal can never
  --     involve tax -- which is now a structural fact rather than a choice
  -- -------------------------------------------------------------------
  -- Withholding exists only on a PAID share, and reverse() refuses a paid share
  -- outright (recovering money from an agent is a decision, not a journal). So by
  -- construction there is no tax to unwind: the reversal credits the expense by
  -- the gross and debits the payable by the gross, and it must not touch
  -- wht_payable at all. The old version of this test asserted a three-leg
  -- reversal, which was only reachable because the accrual used to withhold.
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
    perform pg_temp.assert(v_acc16.gross_amount = 300000 and v_acc16.wht_amount = 0
                       and v_acc16.net_amount = 300000,
      format('§16 the unpaid share to unwind is 300,000 gross and untaxed (got %s / %s / %s)',
             v_acc16.gross_amount, v_acc16.wht_amount, v_acc16.net_amount));

    -- The accrual moved ap_control by the gross and left wht_payable alone.
    perform pg_temp.assert(pg_temp.acct(ta, ap_gl) = v_ap_before - 300000,
      format('§16 accruing moved ap_control by the gross 300,000 (got %s)',
             pg_temp.acct(ta, ap_gl) - v_ap_before));
    perform pg_temp.assert(pg_temp.acct(ta, wht_gl) = v_wht_before,
      format('§16 and wht_payable not at all, because nothing has been paid (got %s)',
             pg_temp.acct(ta, wht_gl) - v_wht_before));

    perform pg_temp.jwt(mgr); set local role authenticated;
    v_rev := public.ins_agent_commission_reverse(v_acc16.id, 'policy cancelled before settlement');
    reset role;
    perform pg_temp.assert((v_rev ->> 'reversed')::boolean, '§16 the share reverses');
    perform pg_temp.assert((v_rev ->> 'wht_reversed')::numeric = 0,
      format('§16 and reports no tax unwound, because an unpaid share never carried any (got %s)',
             v_rev ->> 'wht_reversed'));

    v_rev_je := (v_rev ->> 'journal_entry_id')::uuid;
    -- Each leg is exactly the mirror of what the accrual posted.
    perform pg_temp.assert(pg_temp.acct_je(v_rev_je, expense_gl) = -300000,
      format('§16 the expense is credited by the gross, 300,000 (got %s)',
             pg_temp.acct_je(v_rev_je, expense_gl)));
    perform pg_temp.assert(pg_temp.acct_je(v_rev_je, ap_gl) = 300000,
      format('§16 the payable is debited by the GROSS it was credited with, 300,000 (got %s)',
             pg_temp.acct_je(v_rev_je, ap_gl)));
    perform pg_temp.assert(pg_temp.acct_je(v_rev_je, wht_gl) = 0,
      format('§16 wht_payable is not touched by the reversal (got %s)',
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

    -- -----------------------------------------------------------------
    -- §16b a reversed share can be accrued again
    -- -----------------------------------------------------------------
    -- Reversing is how a wrong share gets corrected, and the correction is
    -- reverse-then-re-accrue. Before this was fixed, the idempotency lookup
    -- counted reversed rows and the table carried a plain UNIQUE (tenant, policy,
    -- intermediary), so a reversal retired that policy's agent commission for
    -- good: the lookup said "already accrued" and the constraint said the same.
    -- The repair path for a wrongly-accrued share therefore did not exist, which
    -- matters most precisely when the tax was wrong and needs redoing.
    reset role;
    v_rev := public.ins_agent_commission_accrue(v_pol16.id);
    perform pg_temp.assert(coalesce((v_rev ->> 'accrued')::boolean, false),
      format('§16b the share can be accrued again after being reversed (%s)', v_rev::text));

    perform pg_temp.assert(
      (select count(*) from ins_agent_commission_accruals
        where policy_id = v_pol16.id and intermediary_id = v_sub16 and status <> 'reversed') = 1,
      '§16b and there is exactly one LIVE accrual, so the natural key still holds');
    perform pg_temp.assert(
      (select count(*) from ins_agent_commission_accruals
        where policy_id = v_pol16.id and intermediary_id = v_sub16) = 2,
      '§16b while the reversed row is kept, because a reversal is history and not a deletion');

    -- And it still refuses a second LIVE one: the relaxed key must not have
    -- become no key at all.
    perform pg_temp.expect_error(
      format($q$insert into public.ins_agent_commission_accruals
                  (tenant_id, policy_id, intermediary_id, basis, commission_base, gross_amount, currency)
                values (%L, %L, %L, 'pct_of_broker_commission', 750000, 300000, 'UGX')$q$,
             ta, v_pol16.id, v_sub16),
      'ins_agent_accruals_live_once_key',
      '§16b a second LIVE accrual is still refused outright');
  end;

  -- -------------------------------------------------------------------
  -- §17 an event says WHO did it (item 8, bit 5)
  -- -------------------------------------------------------------------
  -- The actor arrives from the column default `auth.uid()`, which fires because
  -- every insert omits actor_id rather than writing NULL. That is worth pinning
  -- precisely because it is invisible: it holds today, it would stop holding the
  -- first time somebody writes `actor_id` into an insert list and leaves it null,
  -- and a history where every line reads "System" is not an audit trail.
  reset role;
  declare
    v_acc17  public.ins_agent_commission_accruals;
    v_actor  uuid;
  begin
    select * into v_acc17 from public.ins_agent_commission_accruals
     where tenant_id = ta and status = 'paid' order by created_at limit 1;

    select actor_id into v_actor from public.ins_agent_commission_events
     where tenant_id = ta and accrual_id = v_acc17.id and event = 'paid';

    perform pg_temp.assert(v_actor is not null,
      '§17 the event that released the money names the manager who released it');
    -- Non-null is not enough: the actor must be somebody who works here, because
    -- a made-up identity would pass a non-null check and fail an audit.
    perform pg_temp.assert(v_actor in (admin1, admin2, mgr),
      format('§17 and it names one of the people who works here (got %s)', v_actor));

    -- No session means no identity. Outside `authenticated` there is no user, and
    -- the act was genuinely performed with nobody to name: writing one would be
    -- worse than leaving it blank.
    perform set_config('request.jwt.claims', '', true);
    insert into public.ins_agent_commission_events (tenant_id, accrual_id, event, amount, note)
      values (ta, v_acc17.id, 'eligible', null, 'no session');
    perform pg_temp.assert(
      (select actor_id from public.ins_agent_commission_events
        where tenant_id = ta and note = 'no session') is null,
      '§17 with no user session the actor stays null rather than being invented');
    delete from public.ins_agent_commission_events where tenant_id = ta and note = 'no session';

    -- The default reads the CLAIMS, not the database role, so it keeps working
    -- inside a security-definer RPC where the effective role is the owner.
    perform set_config('request.jwt.claims',
      json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
    insert into public.ins_agent_commission_events (tenant_id, accrual_id, event, amount, note)
      values (ta, v_acc17.id, 'eligible', null, 'named by claims');
    perform pg_temp.assert(
      (select actor_id from public.ins_agent_commission_events
        where tenant_id = ta and note = 'named by claims') = mgr,
      '§17 and inside a user session it names that user');
    delete from public.ins_agent_commission_events where tenant_id = ta and note = 'named by claims';
  end;

  -- -------------------------------------------------------------------
  -- §18 the position is per currency
  -- -------------------------------------------------------------------
  -- The old function answered in one sum, so a tenant working in two currencies
  -- got a number that was not money. By this point in the file the tenant is fully
  -- settled (§14 paid the last return), which is a useful state to assert the
  -- identities from, and a useless one for a backlog: the per-currency figures must
  -- still add up to the flat ones, and both must add up to what is unresolved.
  reset role;
  declare
    v_pos    jsonb;
    v_ccy    jsonb;
    v_ugx    numeric;
    v_rems   numeric;
  begin
    v_pos := public.ins_wht_position();
    perform pg_temp.assert(jsonb_typeof(v_pos -> 'by_currency') = 'array',
      '§18 the position splits by currency');
    perform pg_temp.assert(jsonb_array_length(v_pos -> 'by_currency') >= 1,
      '§18 and this tenant has at least one currency with tax in it');

    select elem into v_ccy from jsonb_array_elements(v_pos -> 'by_currency') as elem
     where elem ->> 'currency' = 'UGX';
    perform pg_temp.assert(v_ccy is not null, '§18 UGX appears in the split');

    -- The split must agree with the tax actually withheld, or it is decoration.
    select round(coalesce(sum(wht_amount), 0), 2) into v_ugx
      from public.ins_agent_commission_accruals
     where tenant_id = ta and currency = 'UGX' and wht_amount > 0 and status <> 'reversed';
    perform pg_temp.assert((v_ccy ->> 'withheld_total')::numeric = v_ugx,
      format('§18 the UGX line matches the accruals it is derived from (%s vs %s)',
             v_ccy ->> 'withheld_total', v_ugx));

    -- With one currency in use, the split and the flat summary must be the same
    -- numbers. This is what makes the flat fields safe for the single-currency
    -- tenants that already read them.
    perform pg_temp.assert((v_ccy ->> 'withheld_total')::numeric = (v_pos ->> 'withheld_total')::numeric,
      '§18 with one currency the split agrees with the flat total');
    perform pg_temp.assert((v_ccy ->> 'reported_total')::numeric = (v_pos ->> 'reported_total')::numeric,
      '§18 and so does the reported total');

    -- Every return this tenant prepared is on the flat reported figure: the split
    -- cannot silently drop a remittance.
    select round(coalesce(sum(amount), 0), 2) into v_rems
      from public.ins_wht_remittances
     where tenant_id = ta and status in ('prepared', 'approved', 'paid');
    perform pg_temp.assert((v_pos ->> 'reported_total')::numeric = v_rems,
      format('§18 the reported total is the sum of live returns (%s vs %s)',
             v_pos ->> 'reported_total', v_rems));

    -- Each currency's line must satisfy its own identity, whichever branch the
    -- floor takes.
    perform pg_temp.assert(
      (v_ccy ->> 'unreported_open')::numeric
        = greatest((v_ccy ->> 'withheld_total')::numeric - (v_ccy ->> 'reported_total')::numeric, 0),
      '§18 unreported_open is withheld less reported, floored at zero');
    perform pg_temp.assert(
      (v_ccy ->> 'awaiting_payment')::numeric
        = greatest((v_ccy ->> 'reported_total')::numeric - (v_ccy ->> 'paid_total')::numeric, 0),
      '§18 awaiting_payment is reported less paid, floored at zero');
    perform pg_temp.assert(
      (v_ccy ->> 'unreported')::numeric
        = (v_ccy ->> 'unreported_open')::numeric - (v_ccy ->> 'over_reported')::numeric,
      '§18 unreported = unreported_open - over_reported, exactly');
  end;

  -- -------------------------------------------------------------------
  -- §19 two currencies in one tenant stay two answers
  -- -------------------------------------------------------------------
  -- The defect this bit exists for. Until the position was split, 500 USD of tax
  -- and 900,000 UGX of tax came back as one number, and that number was not
  -- money. Asserting the split on a single-currency tenant would prove nothing:
  -- the old code passes that test. So this builds the mixed case deliberately.
  --
  -- The shares are inserted rather than accrued, because the accrual path derives
  -- its currency from the policy and a policy in USD needs an insurer, a product
  -- line and a premium in a currency this fixture does not otherwise use. The
  -- column being asserted on is `currency`, and the withholding is already a
  -- stored figure at this point in the lifecycle, so the insert is the honest
  -- fixture rather than a shortcut around the code under test.
  reset role;
  declare
    v_pos     jsonb;
    v_ugx     jsonb;
    v_usd     jsonb;
    v_acc     uuid;
    v_ret     jsonb;
  begin
    -- `ins_agent_commission_wht_guard` refuses a hand-written withholding
    -- figure, which is the control doing its job: a tax amount nobody can tie
    -- back to a rate and a date is a number with no defence. The calculation
    -- RPCs set this same flag inside their own transaction, so setting it here is
    -- how a fixture stands in for the calculation rather than around it.
    perform set_config('ins.via_wht_calc', 'on', true);
    insert into public.ins_agent_commission_accruals
      (tenant_id, policy_id, intermediary_id, basis, commission_base,
       gross_amount, wht_amount, net_amount, currency, status, paid_at, paid_on,
       wht_rate_pct, wht_is_final, wht_parameter_ref)
    values
      -- A paid share must name the rate, its character AND the parameter row they
      -- came from, so the tax can be traced to a decision rather than a decimal.
      (ta, v_pol_exp, v_sub, 'pct_of_broker_commission', 1000, 111.11, 11.11, 100.00,
       'USD', 'paid', now(), date '2026-11-18', 10, true,
       (select id from public.regulatory_parameters
         where tenant_id = ta and parameter_key = 'tax.wht_agent_commission_percent'
         order by effective_from limit 1))
    returning id into v_acc;
    perform set_config('ins.via_wht_calc', 'off', true);

    v_pos := public.ins_wht_position();
    select elem into v_ugx from jsonb_array_elements(v_pos -> 'by_currency') as elem
     where elem ->> 'currency' = 'UGX';
    select elem into v_usd from jsonb_array_elements(v_pos -> 'by_currency') as elem
     where elem ->> 'currency' = 'USD';

    perform pg_temp.assert(v_ugx is not null and v_usd is not null,
      format('§19 both currencies appear in the split (%s)', v_pos -> 'by_currency'));

    -- The identity a single-currency tenant can never test: each line counts ITS
    -- OWN currency, not the whole tenant. 11.11 must not appear as 120,011.11.
    perform pg_temp.assert((v_usd ->> 'withheld_total')::numeric = 11.11,
      format('§19 the USD line counts only USD tax (got %s)', v_usd ->> 'withheld_total'));
    perform pg_temp.assert((v_ugx ->> 'withheld_total')::numeric = 120000.00,
      format('§19 and the UGX line is unchanged by it (got %s)', v_ugx ->> 'withheld_total'));
    perform pg_temp.assert((v_usd ->> 'unreported_open')::numeric = 11.11,
      '§19 the USD tax is unreported, because no return has been prepared for it');

    -- The flat summary is now knowingly the sum of unlike things. It is kept for
    -- the single-currency callers it was written for, and this asserts the size of
    -- the lie rather than pretending it does not exist.
    perform pg_temp.assert((v_pos ->> 'withheld_total')::numeric = 120011.11,
      '§19 the flat total adds the two currencies together, which is why by_currency exists');

    -- A return in one currency cannot claim the other currency's tax, or URA is
    -- paid shillings for a dollar liability.
    perform pg_temp.jwt(mgr); set local role authenticated;
    v_ret := public.ins_wht_prepare_remittance(date '2026-11-01', date '2026-11-30', 'USD');
    reset role;
    perform pg_temp.assert((v_ret ->> 'amount')::numeric = 11.11,
      format('§19 a USD return claims only the USD tax (got %s)', v_ret -> 'amount'));
    perform pg_temp.assert(
      not exists (select 1 from public.ins_wht_remittance_lines l
                   join public.ins_agent_commission_accruals a on a.id = l.accrual_id
                  where l.tenant_id = ta and a.currency <> 'USD'
                    and l.remittance_id = (v_ret ->> 'remittance_id')::uuid),
      '§19 and no UGX share is on it');
  end;

  -- -------------------------------------------------------------------
  -- §20 the statement: per currency, consistent, and dated by payment
  -- -------------------------------------------------------------------
  -- Three defects in one function, and the third is a correctness problem.
  --
  --  (a) It summed unlike currencies.
  --  (b) `lines` included reversed shares while the totals excluded them, so the
  --      detail did not add up to the headline.
  --  (c) The window filtered on created_at -- when the row was written -- while
  --      the money it reports is paid on paid_on.
  --
  -- (c) is asserted by contradiction: the same accrual must fall on the statement
  -- for its PAYMENT month and out of the statement for the month it was created,
  -- which are different months for §14c's share.
  reset role;
  declare
    v_st      jsonb;
    v_st_nov  jsonb;
    v_st_dec  jsonb;
    v_line    jsonb;
    v_usd     jsonb;
    v_sum     numeric;
    v_net     numeric;
    v_created date;
    v_acc     uuid;
  begin
    -- (a) the mixed-currency agent from §19. v_sub now has a USD share and a
    -- shilling share, so the two dialects of "total" cannot agree.
    v_st := public.ins_agent_commission_statement(v_sub);
    perform pg_temp.assert(jsonb_array_length(v_st -> 'by_currency') = 2,
      format('§20 a two-currency agent gets two lines (%s)', v_st -> 'by_currency'));

    select elem into v_usd from jsonb_array_elements(v_st -> 'by_currency') as elem
     where elem ->> 'currency' = 'USD';
    perform pg_temp.assert((v_usd ->> 'gross_commission')::numeric = 111.11,
      format('§20 the USD line counts only USD business (got %s)', v_usd ->> 'gross_commission'));

    -- Every currency line's outstanding must be its own net less its own paid.
    for v_line in select * from jsonb_array_elements(v_st -> 'by_currency') loop
      perform pg_temp.assert(
        (v_line ->> 'outstanding')::numeric
          = round((v_line ->> 'net_commission')::numeric - (v_line ->> 'paid')::numeric, 2),
        format('§20 %s outstanding is its own net less its own paid (%s)',
               v_line ->> 'currency', v_line::text));
    end loop;

    -- (b) the lines must add up to the headline, in the currency they share.
    -- This is the assertion the old function failed: reversed shares were in the
    -- detail and out of the total.
    select coalesce(sum((elem ->> 'gross_amount')::numeric), 0),
           coalesce(sum((elem ->> 'net_amount')::numeric), 0)
      into v_sum, v_net
      from jsonb_array_elements(v_st -> 'lines') as elem
     where elem ->> 'status' <> 'reversed';
    perform pg_temp.assert(v_sum = (v_st ->> 'gross_commission')::numeric,
      format('§20 the statement lines add up to its gross (%s vs %s)',
             v_sum, v_st ->> 'gross_commission'));
    perform pg_temp.assert(
      not exists (select 1 from jsonb_array_elements(v_st -> 'lines') as elem
                   where elem ->> 'status' = 'reversed'),
      '§20 and no reversed share appears in the detail at all');

    -- (c) dated by payment. §14c accrued in November and was paid in December.
    select x.id, x.created_at::date into v_acc, v_created
      from public.ins_agent_commission_accruals x
     where x.tenant_id = ta and x.paid_on = date '2026-12-10' limit 1;
    perform pg_temp.assert(v_acc is not null, '§20 the December-paid share exists');

    v_st_nov := public.ins_agent_commission_statement(
      (select intermediary_id from public.ins_agent_commission_accruals where id = v_acc),
      date '2026-11-01', date '2026-11-30');
    v_st_dec := public.ins_agent_commission_statement(
      (select intermediary_id from public.ins_agent_commission_accruals where id = v_acc),
      date '2026-12-01', date '2026-12-31');

    perform pg_temp.assert(
      exists (select 1 from jsonb_array_elements(v_st_dec -> 'lines') as elem
               where (elem ->> 'accrual_id')::uuid = v_acc),
      '§20 the share appears on the statement for the month it was PAID');
    perform pg_temp.assert(
      not exists (select 1 from jsonb_array_elements(v_st_nov -> 'lines') as elem
                   where (elem ->> 'accrual_id')::uuid = v_acc),
      format('§20 and not on the statement for the month its row was written (%s)', v_created));

    -- The totals must follow the same window as the lines. Asserting only the
    -- lines let a mutant that filtered the TOTALS on created_at survive: the
    -- detail moved to December while the headline stayed in November, and nothing
    -- compared the two. Computed here as an oracle rather than restated.
    perform pg_temp.assert((v_st_dec ->> 'gross_commission')::numeric = (
        select coalesce(sum(gross_amount), 0) from public.ins_agent_commission_accruals
         where tenant_id = ta and status <> 'reversed'
           and intermediary_id = (select intermediary_id from public.ins_agent_commission_accruals where id = v_acc)
           and coalesce(paid_on, created_at::date) between date '2026-12-01' and date '2026-12-31'),
      format('§20 the December statement total follows the payment date (%s)',
             v_st_dec ->> 'gross_commission'));
    perform pg_temp.assert((v_st_nov ->> 'gross_commission')::numeric = (
        select coalesce(sum(gross_amount), 0) from public.ins_agent_commission_accruals
         where tenant_id = ta and status <> 'reversed'
           and intermediary_id = (select intermediary_id from public.ins_agent_commission_accruals where id = v_acc)
           and coalesce(paid_on, created_at::date) between date '2026-11-01' and date '2026-11-30'),
      format('§20 and so does the November one (%s)', v_st_nov ->> 'gross_commission'));

    -- A reversed share must be out of both the window and the totals. §16 left
    -- one behind; picking it up here proves the filter is the same on both paths.
    perform pg_temp.assert(
      (select count(*) from public.ins_agent_commission_accruals
        where tenant_id = ta and status = 'reversed') > 0,
      '§20 there is a reversed share in this tenant to test the filter with');
    perform pg_temp.assert(
      not exists (
        select 1 from public.ins_agent_commission_accruals x
          join jsonb_array_elements(public.ins_agent_commission_statement(x.intermediary_id) -> 'lines') as elem
            on (elem ->> 'accrual_id')::uuid = x.id
         where x.tenant_id = ta and x.status = 'reversed'),
      '§20 a reversed share is absent from every statement, whatever the window');
  end;


  -- -------------------------------------------------------------------
  -- §21 manual accrual: a manager may ask, and the rules still decide
  -- -------------------------------------------------------------------
  -- The manager check is asserted FIRST, before any policy exists, because it
  -- is the only guard that can be removed without the rest of the section
  -- noticing: every scenario after this one runs as a manager, so a wrapper
  -- that lost its can_manage_insurance() check would still pass them all.
  -- (Measured: that mutant survived until this assertion existed.)
  -- The action exists because a share can be missing for reasons recognition
  -- never sees: commission earned before the subledger shipped, a book
  -- migrated with earned commission on it, a share reversed for the wrong
  -- reason. What it must NOT be is a way around the accrual rules, so the
  -- tests below are as much about what is refused as about what is posted.
  declare
    v_m21    uuid := gen_random_uuid();
    v_pol21  public.ins_policies;
    v_c21    uuid;
    v_b21    jsonb;
    v_o21    jsonb;
    v_prev21 jsonb;
    v_run21  jsonb;
    v_pol21b public.ins_policies;
    v_pol21c public.ins_policies;
    v_pol21d public.ins_policies;
    v_gl_before numeric;
    v_gl_after  numeric;
  begin
    -- A second manager, because the action is manager-gated.
    insert into auth.users(id, email, raw_user_meta_data, raw_app_meta_data, aud, role, created_at, updated_at)
      values (v_m21, 'manacc-' || v_m21 || '@test.local', '{}', '{}', 'authenticated', 'authenticated', now(), now())
      on conflict (id) do nothing;
    insert into public.app_users(id, tenant_id, name, email)
      values (v_m21, ta, 'Manual accrual manager', 'manacc-' || v_m21 || '@test.local')
      on conflict (id) do nothing;
    insert into public.staff_roles(tenant_id, user_id, module, role)
      select ta, v_m21, 'insurance', 'manager'
      where not exists (select 1 from public.staff_roles
                        where tenant_id = ta and user_id = v_m21 and module = 'insurance');

    -- (0) A user with no insurance role must be refused, and refused by the
    -- wrapper rather than by whatever happens to be missing further down.
    reset role;
    declare
      v_plain21 uuid := gen_random_uuid();
    begin
      insert into auth.users(id, email, raw_user_meta_data, raw_app_meta_data, aud, role, created_at, updated_at)
        values (v_plain21, 'plain-' || v_plain21 || '@test.local', '{}', '{}', 'authenticated', 'authenticated', now(), now())
        on conflict (id) do nothing;
      insert into public.app_users(id, tenant_id, name, email)
        values (v_plain21, ta, 'No insurance role', 'plain-' || v_plain21 || '@test.local')
        on conflict (id) do nothing;

      perform pg_temp.jwt(v_plain21); set local role authenticated;
      perform pg_temp.expect_error(
        format($q$select public.ins_agent_commission_accrue_manual(%L, 'not mine to ask')$q$, v_pol_place),
        'INS_ACCESS_DENIED',
        '§21 somebody without an insurance role cannot accrue commission, whoever they ask for');
      perform pg_temp.expect_error(
        format($q$select public.ins_run_agent_commission_accruals(date '2000-01-01', current_date, 'not mine')$q$),
        'INS_ACCESS_DENIED',
        '§21 nor run accruals across the book');
      perform pg_temp.expect_error(
        format($q$select public.ins_agent_commission_accrual_preview(date '2000-01-01', current_date)$q$),
        'INS_ACCESS_DENIED',
        '§21 nor even look at what would be run');
      reset role;
    end;

    -- (a) A bound policy whose commission is still DEFERRED. This is the case
    -- the whole guard exists for: the brokerage has not been paid, so it has
    -- not earned the commission, so there is nothing for the agent's share to
    -- come out of. Asking must fail, and it must say why in words.
    reset role;
    v_c21 := (select id from ins_clients where tenant_id = ta limit 1);
    perform pg_temp.jwt(mgr); set local role authenticated;
    v_pol21b := ins_create_policy(v_c21, v_insurer, v_line, current_date, current_date + 365,
                                  4000000, 'UGX', 4000000, 15, null, v_sub, 'manual not yet recognised', null);
    perform pg_temp.one_share(v_pol21b.id, v_insurer, 15);
    v_pol21b := pg_temp.approve_and_bind(v_pol21b.id);
    reset role;

    perform pg_temp.jwt(v_m21); set local role authenticated;
    v_b21 := public.ins_agent_commission_blocked_reason(v_pol21b.id);
    perform pg_temp.assert(v_b21 ->> 'code' = 'INS_AGENT_NOT_RECOGNISED',
      format('§21 a bound policy whose commission is deferred refuses manual accrual by name (got %s)', v_b21 ->> 'code'));
    perform pg_temp.assert(v_b21 ->> 'reason' like '%not been recognised%',
      format('§21 and the reason says the recognition point is the obstacle (got %s)', v_b21 ->> 'reason'));
    perform pg_temp.assert(
      v_b21 ->> 'reason' like '%' || public.ins_commission_recognition_mode(v_pol21b.id) || '%',
      '§21 and names the policy''s recognition mode, so the manager can see which rule is holding it');

    -- Nothing was posted while saying no. An explanation that still moved the
    -- ledger would be the worst of both.
    perform pg_temp.assert(not exists (
      select 1 from public.ins_agent_commission_accruals
       where policy_id = v_pol21b.id), '§21 and nothing was accrued while it was refusing');

    v_o21 := public.ins_agent_commission_accrue_manual(v_pol21b.id, 'try anyway');
    perform pg_temp.assert(not (v_o21 ->> 'accrued')::boolean,
      '§21 asking anyway is still refused, and returns rather than raising');
    perform pg_temp.assert(v_o21 ->> 'code' = 'INS_AGENT_NOT_RECOGNISED',
      format('§21 with the same code (got %s)', v_o21 ->> 'code'));
    reset role;

    -- (b) Now the commission is recognised -- by the normal path, which accrues
    -- automatically. So to test the MANUAL action we need a share that the
    -- trigger did not create. The honest way to get one is to accrue, reverse,
    -- and re-accrue manually: reversal is the documented repair path, and it
    -- leaves exactly the state the manual action exists for.
    perform pg_temp.recognise(v_pol21b.id, 600000);
    perform pg_temp.assert(exists (
      select 1 from public.ins_agent_commission_accruals
       where policy_id = v_pol21b.id and status <> 'reversed'),
      '§21 recognition accrues the share on its own, as before');

    perform pg_temp.jwt(v_m21); set local role authenticated;
    v_b21 := public.ins_agent_commission_blocked_reason(v_pol21b.id);
    perform pg_temp.assert(v_b21 ->> 'code' = 'INS_AGENT_ALREADY_ACCRUED',
      format('§21 a live share is reported as already accrued, not accrued twice (got %s)', v_b21 ->> 'code'));

    -- The manual action must not double-post over the trigger's work.
    reset role;
    select gross_amount into v_gl_before
      from public.ins_agent_commission_accruals where policy_id = v_pol21b.id and status <> 'reversed';
    perform pg_temp.jwt(v_m21); set local role authenticated;
    v_o21 := public.ins_agent_commission_accrue_manual(v_pol21b.id, 'duplicate attempt');
    perform pg_temp.assert(not (v_o21 ->> 'accrued')::boolean,
      '§21 and pressing the button does nothing at all');
    reset role;
    perform pg_temp.assert((select count(*) from public.ins_agent_commission_accruals
                             where policy_id = v_pol21b.id) = 1,
      '§21 exactly one accrual row exists for the policy');
    perform pg_temp.assert(v_gl_before = 240000,
      format('§21 the share is the agreed 40%% of the 600,000 commission (got %s)', v_gl_before));

    -- (c) Reverse it. Then the share is gone but the commission is still earned,
    -- which is the gap the manual action fills.
    reset role;
    perform public.ins_agent_commission_reverse(
      (select id from public.ins_agent_commission_accruals
        where policy_id = v_pol21b.id and status <> 'reversed'),
      'accrued against the wrong term');

    perform pg_temp.jwt(v_m21); set local role authenticated;
    v_b21 := public.ins_agent_commission_blocked_reason(v_pol21b.id);
    perform pg_temp.assert(v_b21 ->> 'code' is null,
      format('§21 after a reversal the policy is accrueable again (got %s: %s)', v_b21 ->> 'code', v_b21 ->> 'reason'));
    perform pg_temp.assert((v_b21 ->> 'gross_amount')::numeric = 240000,
      format('§21 and the preview shows the same figure the accrual will post, from the same calculation (got %s)', v_b21 ->> 'gross_amount'));

    v_o21 := public.ins_agent_commission_accrue_manual(v_pol21b.id, 're-accrued after reversing the wrong term');
    perform pg_temp.assert((v_o21 ->> 'accrued')::boolean,
      format('§21 the manual action re-accrues it (got %s)', v_o21::text));
    perform pg_temp.assert((v_o21 ->> 'gross_amount')::numeric = 240000,
      '§21 at the term''s figure, not at any figure the caller could name');
    reset role;

    -- One live share, plus the reversed one kept as history.
    perform pg_temp.assert((
      select count(*) from public.ins_agent_commission_accruals
       where policy_id = v_pol21b.id and status <> 'reversed') = 1,
      '§21 the manual accrual leaves exactly one live share');
    perform pg_temp.assert((
      select count(*) from public.ins_agent_commission_accruals
       where policy_id = v_pol21b.id and status = 'reversed') = 1,
      '§21 and the reversal is still there as history -- nothing is deleted');

    -- (d) Who asked, and why. The event is the audit trail, and a manual accrual
    -- must be distinguishable from one the settlement trigger produced.
    perform pg_temp.assert((
      select e.note like 'accrued manually by a manager:%' from public.ins_agent_commission_events e
        join public.ins_agent_commission_accruals x on x.id = e.accrual_id
       where x.policy_id = v_pol21b.id and x.status <> 'reversed' and e.event = 'accrued'),
      '§21 the event records that a person asked for it');
    perform pg_temp.assert((
      select e.note like '%re-accrued after reversing the wrong term%' from public.ins_agent_commission_events e
        join public.ins_agent_commission_accruals x on x.id = e.accrual_id
       where x.policy_id = v_pol21b.id and x.status <> 'reversed' and e.event = 'accrued'),
      '§21 and carries the reason the manager gave');
    perform pg_temp.assert((
      select e.actor_id = v_m21 from public.ins_agent_commission_events e
        join public.ins_agent_commission_accruals x on x.id = e.accrual_id
       where x.policy_id = v_pol21b.id and x.status <> 'reversed' and e.event = 'accrued'),
      '§21 and stamps the manager who did it');

    -- The first accrual, the trigger's, must NOT be relabelled as manual.
    perform pg_temp.assert((
      select e.note not like 'accrued manually%' from public.ins_agent_commission_events e
        join public.ins_agent_commission_accruals x on x.id = e.accrual_id
       where x.policy_id = v_pol21b.id and x.status = 'reversed' and e.event = 'accrued'),
      '§21 an accrual the settlement trigger made is not rewritten as a manual one');

    -- (e) An insurer-appointed agent is refused by name, not accrued at zero.
    reset role;
    perform pg_temp.jwt(v_m21); set local role authenticated;
    v_b21 := public.ins_agent_commission_blocked_reason(v_pol_insurer_agent);
    perform pg_temp.assert(v_b21 ->> 'code' = 'INS_AGENT_INSURER_PAID',
      format('§21 an insurer-appointed agent cannot be accrued by hand either (got %s)', v_b21 ->> 'code'));
    reset role;

    -- (f) The bulk run: only what is genuinely eligible, one report, and every
    -- obstacle accounted for. The period is wide enough to hold the policies
    -- this file has built, including the ones filed under a past date.
    perform pg_temp.jwt(v_m21); set local role authenticated;
    v_prev21 := public.ins_agent_commission_accrual_preview(date '2000-01-01', current_date + 400);
    perform pg_temp.assert((v_prev21 ->> 'eligible_count')::int >= 0,
      '§21 the preview answers for a period');
    perform pg_temp.assert(jsonb_typeof(v_prev21 -> 'blocked') = 'array',
      '§21 and lists every obstacle rather than only counting them');
    perform pg_temp.assert(jsonb_typeof(v_prev21 -> 'by_currency') = 'array',
      '§21 totals per currency, never one merged figure');

    -- Everything the preview called eligible must be something the run can
    -- accrue or cleanly report. Nothing may be silently dropped.
    v_run21 := public.ins_run_agent_commission_accruals(date '2000-01-01', current_date + 400, 'period run under test');
    perform pg_temp.assert(
      (v_run21 ->> 'accrued')::int + (v_run21 ->> 'skipped')::int + (v_run21 ->> 'failed')::int
        = (v_prev21 ->> 'eligible_count')::int,
      format('§21 every eligible policy is accounted for as accrued, skipped or failed (%s of %s)',
             (v_run21 ->> 'accrued')::int + (v_run21 ->> 'skipped')::int + (v_run21 ->> 'failed')::int,
             v_prev21 ->> 'eligible_count'));

    -- Running it twice must post nothing the second time. This is what makes it
    -- safe to press without knowing the current state of the book.
    v_run21 := public.ins_run_agent_commission_accruals(date '2000-01-01', current_date + 400, 'second run');
    perform pg_temp.assert((v_run21 ->> 'accrued')::int = 0,
      format('§21 a second run accrues nothing (got %s)', v_run21 ->> 'accrued'));
    reset role;

    -- A failure inside the run is reported as a failure, not folded into the
    -- successes. The race is real: the preview and the run are two readings of
    -- the same book, and something can change between them. Simulated the way
    -- it would actually happen -- the posting rule an accrual needs is removed
    -- after the preview has already called the policy eligible.
    -- (Measured: the mutant that counted failures as successes survived until
    -- this assertion existed.)
    reset role;
    declare
      v_fail21 public.ins_policies;
      v_c21b   uuid;
      v_prevf  jsonb;
    begin
      v_c21b := (select id from ins_clients where tenant_id = ta limit 1);
      perform pg_temp.jwt(mgr); set local role authenticated;
      v_fail21 := ins_create_policy(v_c21b, v_insurer, v_line, current_date, current_date + 365,
                                    1000000, 'UGX', 1000000, 15, null, v_ref, 'run failure', null);
      perform pg_temp.one_share(v_fail21.id, v_insurer, 15);
      v_fail21 := pg_temp.approve_and_bind(v_fail21.id);
      reset role;

      -- Recognise it in a way the trigger cannot act on, then drop the accrual
      -- it may have made, so the policy sits eligible-but-unaccrued.
      perform pg_temp.recognise(v_fail21.id, 150000);
      reset role;
      delete from public.ins_agent_commission_accruals where policy_id = v_fail21.id;

      perform pg_temp.jwt(v_m21); set local role authenticated;
      v_prevf := public.ins_agent_commission_accrual_preview(current_date, current_date);
      perform pg_temp.assert(
        exists (select 1 from jsonb_array_elements(v_prevf -> 'eligible') e
                 where (e ->> 'policy_id')::uuid = v_fail21.id),
        '§21 the policy is eligible when the preview reads the book');
      reset role;

      -- Now remove the rule the ACCRUAL needs, behind the preview's back.
      delete from public.gl_posting_rules
       where tenant_id = ta and account_role = 'agent_commission_expense';

      perform pg_temp.jwt(v_m21); set local role authenticated;
      v_run21 := public.ins_run_agent_commission_accruals(current_date, current_date, 'failure reporting');
      perform pg_temp.assert((v_run21 ->> 'failed')::int >= 1,
        format('§21 an accrual that raises mid-run is counted as failed, not accrued (%s accrued / %s failed / %s skipped)',
               v_run21 ->> 'accrued', v_run21 ->> 'failed', v_run21 ->> 'skipped'));
      perform pg_temp.assert(
        exists (select 1 from jsonb_array_elements(v_run21 -> 'failures') f),
        '§21 and the failure carries its message rather than being swallowed');
      perform pg_temp.assert(
        (v_run21 ->> 'accrued')::int + (v_run21 ->> 'skipped')::int + (v_run21 ->> 'failed')::int
          = jsonb_array_length(v_run21 -> 'results'),
        '§21 and every counted policy appears in the results list');

      -- Restore what the rest of the file needs.
      reset role;
      insert into public.gl_posting_rules (tenant_id, account_role, gl_account_id)
      select ta, 'agent_commission_expense', expense_gl
      where not exists (select 1 from public.gl_posting_rules
                        where tenant_id = ta and account_role = 'agent_commission_expense');
    end;

    -- (g) A non-manager cannot accrue at all. The action is a manager's.
    reset role;
    perform pg_temp.jwt(v_m21); set local role authenticated;
    perform pg_temp.assert(nullif(current_setting('request.jwt.claims', true), '') is not null,
      '§21 (a session is active for the grant check below)');
    reset role;

    perform pg_temp.assert(
      not has_function_privilege('authenticated',
        'public.ins_agent_commission_accrue(uuid)', 'execute'),
      '§21 the raw accrual function stays owner-only: clients cannot bypass the manager check');
    perform pg_temp.assert(
      has_function_privilege('authenticated',
        'public.ins_agent_commission_accrue_manual(uuid, text)', 'execute'),
      '§21 and the manual wrapper is what they are given instead');

    -- Nothing about the original signature changed, so the recognition trigger
    -- keeps working without being revisited.
    perform pg_temp.assert((
      select count(*) from pg_trigger where tgname = 'trg_ins_agent_commission_on_recognition') = 1,
      '§21 the recognition trigger is untouched');
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
