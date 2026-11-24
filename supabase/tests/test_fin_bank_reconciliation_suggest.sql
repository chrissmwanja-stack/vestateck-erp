-- =====================================================================
-- Finance C: bank reconciliation -- suggest and confirm
-- =====================================================================
-- Covers migration 20261117170000.
--
-- Asserted:
--   1. Suggestions list real candidates for an unmatched line, ranked.
--   2. A suggestion writes nothing -- it is a question, not a decision.
--   3. Confirming a suggestion matches the pair, as a manual match.
--   4. Confirming a stale suggestion is refused with a clear message
--      (line already taken, or candidate no longer eligible).
--   5. The insurance third-user rule IS enforced server-side: the poster of
--      the cash request cannot reconcile it. This pins a claim that was
--      previously (wrongly) recorded as a client-only rule.
--   6. The review report shows machine vs human decisions.
--   7. fin_bank_review_gaps names banks with unreviewed auto-matches.
--   8. Everything is finance-gated and tenant-scoped.
--
-- One transaction, ROLLBACKs at the end.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

create or replace function pg_temp.seed_commission_terms() returns void
language sql security definer set search_path = public, auth, pg_temp as $$
  insert into public.ins_insurer_commission_terms
    (tenant_id, insurer_id, mode, effective_from, status, agreed_ref, rationale,
     proposed_by, approved_by, approved_at)
  select i.tenant_id, i.id, 'on_insurer_settlement', date '2000-01-01', 'approved',
         'TEST-FIXTURE', 'test fixture default commission terms',
         (select id from auth.users order by id limit 1),
         (select id from auth.users order by id offset 1 limit 1),
         now()
    from public.ins_insurers i
   where not exists (
     select 1 from public.ins_insurer_commission_terms t
      where t.tenant_id = i.tenant_id and t.insurer_id = i.id and t.status = 'approved'
   );
$$;

create function pg_temp.assert(p_ok boolean, p_msg text)
returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_msg; end if;
end $$;

create function pg_temp.expect_error(p_sql text, p_like text, p_msg text)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
    raise exception 'FAIL: % (no error raised)', p_msg;
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
    if sqlerrm not like p_like then
      raise exception 'FAIL: % (unexpected error: %)', p_msg, sqlerrm;
    end if;
  end;
end $$;


-- Submitting, approving and binding a policy needs three different insurance
-- managers (segregation of duties), which is a fixture surface of its own.
-- This is the same helper the existing insurance suite uses, so the shape is
-- proven rather than invented here.
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

do $$
declare
  ta uuid := gen_random_uuid();
  tb uuid := gen_random_uuid();
  fin uuid := gen_random_uuid();
  other uuid := gen_random_uuid();
  finb uuid := gen_random_uuid();
  fin2 uuid := gen_random_uuid();

  org uuid; cc uuid; vendor uuid; dep uuid;
  g_exp uuid; g_vat uuid; g_ap uuid; g_bank uuid; g_wht uuid;
  si uuid; cb uuid; cb2 uuid;
  sl uuid; sl2 uuid;
  n int;
  v_row bank_reconciliations%rowtype;
  v_review record;
  v_bank_id uuid;
begin
  ------------------------------------------------------------------
  -- Fixtures
  ------------------------------------------------------------------
  insert into tenants (id, name, industry_template, status)
  values (ta, 'Recon Co', 'general', 'active'), (tb, 'Other Co', 'general', 'active');

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token
  )
  select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
         'rec-' || u.id || '@test.local',
         extensions.crypt('Tester123', extensions.gen_salt('bf')),
         now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
  from (values (fin), (other), (finb), (fin2)) as u(id);

  insert into app_users (id, tenant_id, name, email, is_company_admin) values
    (fin,   ta, 'Recon Finance',  'rec-' || fin || '@test.local', true),
    (other, ta, 'Recon Other',    'rec-' || other || '@test.local', false),
    (fin2,  ta, 'Recon Finance 2','rec-' || fin2 || '@test.local', false),
    (finb,  tb, 'Recon Finance B','rec-' || finb || '@test.local', true);

  insert into finance_team_members (tenant_id, user_id, role) values
    (ta, fin, 'finance'), (ta, fin2, 'finance'), (tb, finb, 'finance');

  perform set_config('request.jwt.claims',
                     json_build_object('sub', fin, 'role', 'authenticated')::text, true);

  insert into organizations (tenant_id, company_code, site_name) values (ta, 'RC', 'Site') returning id into org;
  insert into cost_centers (tenant_id, name) values (ta, 'CC') returning id into cc;
  insert into accounts (tenant_id, account_code, name, account_type)
    values (ta, 'SUP-RC', 'Supplier', 'vendor') returning id into vendor;

  insert into gl_accounts (tenant_id, account_code, name, account_type)
    values (ta, '5000', 'Expense', 'expense') returning id into g_exp;
  insert into gl_accounts (tenant_id, account_code, name, account_type)
    values (ta, '1200', 'VAT Input', 'asset') returning id into g_vat;
  insert into gl_accounts (tenant_id, account_code, name, account_type)
    values (ta, '2000', 'AP', 'liability') returning id into g_ap;
  insert into gl_accounts (tenant_id, account_code, name, account_type)
    values (ta, '1000', 'Bank', 'asset') returning id into g_bank;
  insert into gl_accounts (tenant_id, account_code, name, account_type)
    values (ta, '2100', 'WHT', 'liability') returning id into g_wht;

  insert into gl_posting_rules (tenant_id, account_role, gl_account_id) values
    (ta, 'default_expense', g_exp), (ta, 'vat_input', g_vat),
    (ta, 'ap_control', g_ap), (ta, 'bank', g_bank), (ta, 'wht_payable', g_wht);

  insert into fin_bank_accounts (tenant_id, name, kind, currency, gl_account_id)
  values (ta, 'OPS-RC', 'operating', 'UGX', g_bank) returning id into v_bank_id;

  insert into accounting_periods (tenant_id, period_start, period_end)
  values (ta, date_trunc('month', current_date)::date,
              (date_trunc('month', current_date) + interval '1 month - 1 day')::date);

  -- Two supplier invoices, each paid, so there are two real bank movements.
  insert into supplier_invoices (
    tenant_id, cost_center_id, invoice_number, invoice_date, due_date,
    amount_incl_vat, vat_amount, currency, organization_id, prf_oif_number,
    vendor_account_id
  ) values (
    ta, cc, 'INV-RC-1', current_date, current_date + 30,
    500, 0, 'UGX', org, 'PRF-1', vendor
  ) returning id into si;

  insert into cash_bank_transactions (
    tenant_id, transaction_type, payment_method, reference_type, reference_id,
    amount, currency, transaction_date, bank_account, description
  ) values (
    ta, 'payment', 'bank', 'supplier_invoice', si,
    500, 'UGX', current_date, 'OPS-RC', 'Paying INV-RC-1'
  ) returning id into cb;

  insert into supplier_invoices (
    tenant_id, cost_center_id, invoice_number, invoice_date, due_date,
    amount_incl_vat, vat_amount, currency, organization_id, prf_oif_number,
    vendor_account_id
  ) values (
    ta, cc, 'INV-RC-2', current_date, current_date + 30,
    750, 0, 'UGX', org, 'PRF-2', vendor
  ) returning id into si;

  insert into cash_bank_transactions (
    tenant_id, transaction_type, payment_method, reference_type, reference_id,
    amount, currency, transaction_date, bank_account, description
  ) values (
    ta, 'payment', 'bank', 'supplier_invoice', si,
    750, 'UGX', current_date, 'OPS-RC', 'Paying INV-RC-2'
  ) returning id into cb2;

  -- The bank statement lines, one per movement, both still unmatched.
  insert into bank_statement_lines (
    tenant_id, bank_account, statement_date, description, reference, amount, currency
  ) values (
    ta, 'OPS-RC', current_date, 'Outgoing INV-RC-1', 'STMT-1', -500, 'UGX'
  ) returning id into sl;

  insert into bank_statement_lines (
    tenant_id, bank_account, statement_date, description, reference, amount, currency
  ) values (
    ta, 'OPS-RC', current_date, 'Outgoing INV-RC-2', 'STMT-2', -750, 'UGX'
  ) returning id into sl2;

  ------------------------------------------------------------------
  -- 1. Suggestions
  ------------------------------------------------------------------
  perform set_config('request.jwt.claims',
                     json_build_object('sub', fin, 'role', 'authenticated')::text, true);
  set local role authenticated;

  select count(*) into n from fin_bank_suggested_matches('OPS-RC', null, null);
  perform pg_temp.assert(n > 0, 'no suggestions were returned for the unmatched lines');

  -- Each line gets exactly the movement that matches its amount.
  perform pg_temp.assert(
    exists (select 1 from fin_bank_suggested_matches('OPS-RC', null, null) s
             where s.statement_line_id = sl and s.candidate_id = cb and s.source = 'cash_bank'),
    'the 500 line should suggest the 500 payment');
  perform pg_temp.assert(
    exists (select 1 from fin_bank_suggested_matches('OPS-RC', null, null) s
             where s.statement_line_id = sl2 and s.candidate_id = cb2),
    'the 750 line should suggest the 750 payment');

  -- Ranked from 1, and never more than three per line.
  perform pg_temp.assert(
    (select min(suggestion_rank) from fin_bank_suggested_matches('OPS-RC', null, null)) = 1,
    'suggestions should be ranked from 1');
  perform pg_temp.assert(
    (select max(c) from (
       select count(*) c from fin_bank_suggested_matches('OPS-RC', null, null)
        group by statement_line_id) x) <= 3,
    'a line should never offer more than three suggestions');
  reset role;
  raise notice 'PASS: suggestions list the matching movements, ranked, at most three per line';

  ------------------------------------------------------------------
  -- 2. A suggestion writes nothing
  ------------------------------------------------------------------
  perform set_config('request.jwt.claims',
                     json_build_object('sub', fin, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform count(*) from fin_bank_suggested_matches('OPS-RC', null, null);
  select count(*) into n from bank_reconciliations;
  reset role;
  perform pg_temp.assert(n = 0,
    format('asking for suggestions created %s reconciliation rows -- it must be read-only', n));
  raise notice 'PASS: asking for suggestions writes nothing';

  ------------------------------------------------------------------
  -- 3. Confirming a suggestion
  ------------------------------------------------------------------
  perform set_config('request.jwt.claims',
                     json_build_object('sub', fin, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_row := fin_bank_confirm_match(sl, 'cash_bank', cb);
  reset role;

  perform pg_temp.assert(v_row.id is not null, 'confirming a suggestion returned no reconciliation');
  perform pg_temp.assert(v_row.cash_bank_transaction_id = cb,
    'the reconciliation should point at the confirmed transaction');
  -- Confirmation is a manual decision, and must be recorded as such: an
  -- auditor needs to tell reviewed work from machine-accepted work.
  perform pg_temp.assert(v_row.match_type = 'manual',
    format('a confirmed suggestion should be recorded as a manual match, got %s', v_row.match_type));
  perform pg_temp.assert(v_row.matched_by = fin,
    'the reconciler should be recorded');

  -- The confirmed line drops out of the suggestion queue.
  perform set_config('request.jwt.claims',
                     json_build_object('sub', fin, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform pg_temp.assert(
    not exists (select 1 from fin_bank_suggested_matches('OPS-RC', null, null) s
                 where s.statement_line_id = sl),
    'a reconciled line should leave the suggestion queue');
  reset role;
  raise notice 'PASS: confirming a suggestion matches the pair as a reviewed, manual match';

  ------------------------------------------------------------------
  -- 4. Stale confirmations are refused
  ------------------------------------------------------------------
  perform set_config('request.jwt.claims',
                     json_build_object('sub', fin, 'role', 'authenticated')::text, true);
  set local role authenticated;

  -- The line is already matched.
  perform pg_temp.expect_error(
    format($q$select fin_bank_confirm_match(%L, 'cash_bank', %L)$q$, sl, cb),
    '%CONFIRM_STALE%',
    'confirming an already-reconciled line was allowed');

  -- cb is already used by that reconciliation, so it is no longer a candidate
  -- for the other line -- and the amount does not match it anyway.
  perform pg_temp.expect_error(
    format($q$select fin_bank_confirm_match(%L, 'cash_bank', %L)$q$, sl2, cb),
    '%CONFIRM_STALE%',
    'confirming a candidate that no longer qualifies was allowed');

  -- An unknown source is named, not silently treated as something else.
  perform pg_temp.expect_error(
    format($q$select fin_bank_confirm_match(%L, 'magic', %L)$q$, sl2, cb2),
    '%CONFIRM_SOURCE%',
    'an unknown suggestion source was accepted');
  reset role;
  raise notice 'PASS: stale and malformed confirmations are refused with clear messages';

  ------------------------------------------------------------------
  -- 5. The insurance third-user rule is enforced server-side
  ------------------------------------------------------------------
  -- This pins the corrected finding. The maker/poster of an insurance cash
  -- settlement cannot reconcile it, and it is the DATABASE that says so.
  declare
    v_cl uuid; v_item uuid; v_set uuid; v_sl uuid;
    v_pol uuid; v_req uuid; v_cid uuid; v_ins uuid; v_line uuid;
    v_ar uuid; v_pay uuid; v_unearned uuid; v_inc uuid; v_trust uuid;
  begin
    perform set_config('request.jwt.claims',
                       json_build_object('sub', fin, 'role', 'authenticated')::text, true);

    insert into gl_accounts (tenant_id, account_code, name, account_type)
      values (ta, '1100', 'Client Money Bank', 'asset') returning id into v_cl;
    insert into fin_bank_accounts (tenant_id, name, kind, currency, gl_account_id)
      values (ta, 'CLIENT-RC', 'client_money', 'UGX', v_cl);

    -- The minimum insurance shape the guard looks at: a policy row (FK), the
    -- insurer payable open item, a cash request whose maker is the finance
    -- user, and the settlement that request posted. The guard's job is to
    -- refuse the person who featured in that chain.
    --
    -- Client and policy have to go through their RPCs (INS_RPC_ONLY), which is
    -- the same path a real user takes, and those RPCs need the insurance
    -- module enabled plus a module role for the caller.
    -- Binding a policy posts, so the insurance posting roles must be mapped.
    insert into gl_accounts (tenant_id, account_code, name, account_type)
      values (ta, '1300', 'Insurance AR', 'asset') returning id into v_ar;
    insert into gl_accounts (tenant_id, account_code, name, account_type)
      values (ta, '2010', 'Insurer payable', 'liability') returning id into v_pay;
    insert into gl_accounts (tenant_id, account_code, name, account_type)
      values (ta, '2020', 'Unearned commission', 'liability') returning id into v_unearned;
    insert into gl_accounts (tenant_id, account_code, name, account_type)
      values (ta, '4000', 'Commission income', 'revenue') returning id into v_inc;
    insert into gl_accounts (tenant_id, account_code, name, account_type)
      values (ta, '1030', 'Client money bank', 'asset') returning id into v_trust;
    insert into gl_posting_rules (tenant_id, account_role, gl_account_id) values
      (ta, 'ar_control', v_ar), (ta, 'insurer_payable', v_pay),
      (ta, 'unearned_commission', v_unearned), (ta, 'commission_income', v_inc),
      (ta, 'client_money_bank', v_trust)
    on conflict do nothing;

    insert into tenant_modules (tenant_id, module) values (ta, 'insurance');
    insert into staff_roles (tenant_id, user_id, module, role) values (ta, fin, 'insurance', 'manager');
    perform set_config('request.jwt.claims',
                       json_build_object('sub', fin, 'role', 'authenticated')::text, true);

    insert into ins_insurers (tenant_id, code, name) values (ta, 'RINS', 'Recon Insurer')
      returning id into v_ins; perform pg_temp.seed_commission_terms();
    insert into ins_product_lines (tenant_id, code, name) values (ta, 'RGEN', 'General')
      returning id into v_line;

    -- Both RPCs return the whole row, not just an id.
    v_cid := (ins_register_client('Recon Client', 'corporate', null, null, null, 'low')).id;
    v_pol := (ins_create_policy(
      v_cid, v_ins, v_line, current_date, current_date + 365,
      1000, 'UGX', 1000, 10, null, null)).id;

    perform pg_temp.assert(v_pol is not null, 'the fixture policy was not created');
    -- Cash can only move against a bound policy.
    v_pol := (pg_temp.approve_and_bind(v_pol)).id;

    -- Binding the policy already raised the insurer payable open item, so use
    -- that one rather than inventing a second for the same policy (there is a
    -- unique index on source for insurance-adjacent items).
    select i.id into v_item
      from fin_open_items i
     where i.tenant_id = ta
       and i.control_role in ('ar_control', 'ins_policy_premium')
       and i.source_id = v_pol
     order by i.created_at
     limit 1;

    perform pg_temp.assert(v_item is not null,
      'binding the policy did not raise a premium receivable open item');

    perform pg_temp.assert(
      exists (select 1 from ins_policy_cash_items v where v.id = v_item),
      'the fixture open item does not resolve as an insurance cash item');

    -- The allocation guard refuses to allocate an insurer payable outside the
    -- approved-cash RPC context (INS_CASH_APPROVAL_REQUIRED), so the fixture
    -- opens that context exactly as the real RPC does rather than bypassing
    -- the rule it is testing. The checker must be a different Finance user
    -- (maker <> checker is a table constraint), which is the whole point: the
    -- person who posts is fin, so fin is who must be refused.
    insert into ins_policy_cash_requests (
      tenant_id, policy_id, kind, bank_account_id, amount, cash_date,
      request_key, status, maker_id, checker_id, checked_at, operation_txid
    ) values (
      ta, v_pol, 'receipt',
      (select id from fin_bank_accounts where tenant_id = ta and name = 'CLIENT-RC'),
      (select amount from fin_open_items where id = v_item),
      current_date, gen_random_uuid(), 'posting', fin2, fin, now(), txid_current()
    );

    -- The guard binds the allocation to the CHECKER's live transaction, so the
    -- fixture acts as the checker here: fin2 made the request, fin checked and
    -- posted it. fin is therefore the person who must be refused below.
    perform set_config('request.jwt.claims',
                       json_build_object('sub', fin, 'role', 'authenticated')::text, true);
    perform set_config('ins.via_rpc', 'on', true);
    insert into fin_settlements (
      tenant_id, settlement_no, direction, bank_account_id, party_account_id,
      amount, currency, settlement_date
    ) values (
      ta, 'STL-RC-1', 'in',
      (select id from fin_bank_accounts where tenant_id = ta and name = 'CLIENT-RC'),
      (select party_account_id from fin_open_items where id = v_item),
      (select amount from fin_open_items where id = v_item), 'UGX', current_date
    ) returning id into v_set;
    insert into fin_allocations (tenant_id, settlement_id, open_item_id, amount)
      select ta, v_set, v_item, amount from fin_open_items where id = v_item;
    perform set_config('ins.via_rpc', 'off', true);
    perform set_config('request.jwt.claims',
                       json_build_object('sub', fin, 'role', 'authenticated')::text, true);

    update ins_policy_cash_requests
       set status = 'posted', settlement_id = v_set, operation_txid = null
     where tenant_id = ta and policy_id = v_pol;

    insert into bank_statement_lines (
      tenant_id, bank_account, statement_date, description, reference, amount, currency
    ) values (
      ta, 'CLIENT-RC', current_date, 'Premium receipt', 'STMT-INS',
      (select amount from fin_open_items where id = v_item), 'UGX'
    ) returning id into v_sl;

    -- fin is the maker of the request AND the poster of the settlement.
    perform pg_temp.assert(
      (select created_by from fin_settlements where id = v_set) = fin,
      'the fixture settlement should be posted by the finance user');

    perform pg_temp.expect_error(
      format($q$select fin_bank_confirm_match(%L, 'settlement', %L)$q$, v_sl, v_set),
      '%INS_CASH_THIRD_PERSON%',
      'the maker/poster of an insurance cash settlement reconciled it themselves -- the third-user rule is not enforced server-side');
  end;

  -- And the queue says up front that this decision needs a third user.
  perform set_config('request.jwt.claims',
                     json_build_object('sub', fin, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform pg_temp.assert(
    (select s.needs_third_user from fin_bank_suggested_matches('CLIENT-RC', null, null) s
      where s.source = 'settlement' limit 1),
    'the queue should flag that an insurance cash match needs a third user');
  reset role;
  raise notice 'PASS: the insurance third-user rule is enforced by the database, and flagged in the queue';

  ------------------------------------------------------------------
  -- 6. The review report
  ------------------------------------------------------------------
  perform set_config('request.jwt.claims',
                     json_build_object('sub', fin, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select * into v_review from fin_bank_reconciliation_review(v_bank_id, current_date)
   where metric = 'statement lines confirmed by a person';
  perform pg_temp.assert(v_review.value = 1,
    format('the report should show one human-confirmed match, got %s', v_review.value));

  select * into v_review from fin_bank_reconciliation_review(v_bank_id, current_date)
   where metric = 'statement lines matched automatically';
  perform pg_temp.assert(v_review.value = 0,
    format('the report should show no machine matches, got %s', v_review.value));

  select * into v_review from fin_bank_reconciliation_review(v_bank_id, current_date)
   where metric = 'statement lines still unmatched';
  perform pg_temp.assert(v_review.value = 1,
    format('the report should show one unmatched line, got %s', v_review.value));

  select * into v_review from fin_bank_reconciliation_review(v_bank_id, current_date)
   where metric = 'distinct confirmers';
  perform pg_temp.assert(v_review.value = 1,
    'the report should count one distinct confirmer');
  reset role;
  raise notice 'PASS: the review report separates machine matches from human confirmations';

  ------------------------------------------------------------------
  -- 7. Review gaps: unreviewed auto-matches are named
  ------------------------------------------------------------------
  -- Turn the confirmed match into an auto match to simulate accepting the
  -- machine's answer without review.
  perform set_config('request.jwt.claims',
                     json_build_object('sub', fin, 'role', 'authenticated')::text, true);
  reset role;
  update bank_reconciliations set match_type = 'auto', matched_at = now() - interval '30 days'
   where id = v_row.id;
  update bank_statement_lines set statement_date = current_date - 30 where id = sl;

  perform set_config('request.jwt.claims',
                     json_build_object('sub', fin, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform pg_temp.assert(
    exists (select 1 from fin_bank_review_gaps(ta, 7) g
             where g.bank_account = 'OPS-RC' and g.auto_matched >= 1),
    'fin_bank_review_gaps did not report the unreviewed auto-match');
  reset role;
  raise notice 'PASS: unreviewed auto-matches older than the cutoff are reported';

  ------------------------------------------------------------------
  -- 8. Gating and isolation
  ------------------------------------------------------------------
  -- A non-finance member of the same tenant cannot list suggestions.
  perform set_config('request.jwt.claims',
                     json_build_object('sub', other, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform count(*) from fin_bank_suggested_matches('OPS-RC', null, null);
    raise exception 'FAIL: a non-finance user listed bank suggestions';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
    if sqlerrm not like '%not authorized%' then
      raise exception 'FAIL: wrong error for a non-finance caller: %', sqlerrm;
    end if;
  end;
  reset role;

  -- Another tenant's finance user cannot see this bank's suggestions.
  perform set_config('request.jwt.claims',
                     json_build_object('sub', finb, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform count(*) from fin_bank_suggested_matches('OPS-RC', null, null);
    raise exception 'FAIL: another tenant listed this bank''s suggestions';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
    if sqlerrm not like '%is not a registered bank account%' then
      raise exception 'FAIL: wrong error for a cross-tenant suggestion call: %', sqlerrm;
    end if;
  end;
  reset role;
  raise notice 'PASS: suggestions and confirmations are finance-gated and tenant-scoped';

  raise notice 'ALL BANK RECONCILIATION SUGGEST TESTS PASSED';
end $$;

rollback;
