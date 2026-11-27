-- =====================================================================
-- Insurance: client-paid broker fees (item 7, 20261117260000).
--
-- What this pins:
--
--   §1  a brokerage fee is VAT-EXEMPT by default. Schedule 3 of the VAT Act
--       includes brokerage in insurance services, and insurance services are
--       exempt supplies. 18% was being added to every fee.
--   §2  an exempt fee carrying VAT is refused BY NAME, not by a bare constraint.
--       The person configuring it is told why, because "invalid input" on a fee
--       that looks like every other fee teaches nobody anything.
--   §3  a taxable service is allowed, but only when classified deliberately and
--       with a recorded reason. Depriving clients of the option would push
--       genuinely taxable work into the exempt bucket.
--   §4  the standard rate comes from governance when it is not supplied, and is
--       COPIED onto the charge so a later rate change cannot rewrite it.
--   §5  the client statement agrees with the ledger. This is the defect: it
--       billed gross_premium + endorsement deltas and ignored fees entirely, so
--       a fee-bearing policy was under-billed by its fee and VAT to the client
--       and to the aged-debtors report.
--   §6  client withholding is an ASSET, never a reduction of revenue and never a
--       liability: 1,000,000 invoiced, 60,000 withheld, revenue stays 1,000,000
--       and 60,000 sits in wht_receivable.
--   §7  withholding is never assumed. No approved rate means no withholding, and
--       the refusal says why -- whether a brokerage fee is a professional fee
--       under s.129 is unsettled.
--   §8  a renewal carries the classification forward, so an exempt fee does not
--       silently become taxable (or break) on renewal.
--
-- One transaction, rolled back. Run against a disposable database.
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
    values (v_appr, 'feeappr-' || v_appr || '@test.local', '{}', '{}', 'authenticated', 'authenticated', now(), now())
    on conflict (id) do nothing;
  insert into public.app_users(id, tenant_id, name, email)
    values (v_appr, v_tenant, 'Fee test approver', 'feeappr-' || v_appr || '@test.local')
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

-- Movement on one GL account for this tenant, debit-positive.
create function pg_temp.acct(p_tenant uuid, p_gl uuid) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(sum(l.debit - l.credit), 0)
    from journal_entry_lines l
    join journal_entries je on je.id = l.journal_entry_id
   where je.tenant_id = p_tenant and l.gl_account_id = p_gl;
$$;

do $$
declare
  ta       uuid := gen_random_uuid();
  admin1   uuid := gen_random_uuid();
  admin2   uuid := gen_random_uuid();
  mgr      uuid := gen_random_uuid();
  fin1     uuid := gen_random_uuid();
  fin2     uuid := gen_random_uuid();
  ar_gl    uuid; bank_gl uuid; pay_gl uuid; unearned_gl uuid; trust_gl uuid;
  income_gl uuid; fee_gl uuid; vat_gl uuid; wht_recv_gl uuid;
  v_bank   uuid;
  v_line   uuid; v_insurer uuid;
  c        ins_clients%rowtype;
  p        ins_policies%rowtype;
  q        ins_policy_cash_requests%rowtype;
  cfg      jsonb;
  out      jsonb;
  v_fee_before numeric;
  v_vat_before numeric;
  v_param  uuid;
begin
  insert into tenants(id, name) values (ta, 'Broker fee test');
  insert into auth.users(id, email, raw_user_meta_data, raw_app_meta_data, aud, role, created_at, updated_at)
    select u, 'fee-' || u || '@test.local', '{}', '{}', 'authenticated', 'authenticated', now(), now()
    from unnest(array[admin1, admin2, mgr, fin1, fin2]) u;
  insert into app_users(id, tenant_id, name, email)
    select u, ta, 'Fee actor', 'fee-' || u || '@test.local'
    from unnest(array[admin1, admin2, mgr, fin1, fin2]) u;
  update app_users set is_company_admin = true where id in (admin1, admin2);
  insert into tenant_modules(tenant_id, module) values (ta, 'insurance');
  insert into staff_roles(tenant_id, user_id, module, role) values
    (ta, mgr, 'insurance', 'manager'), (ta, admin1, 'insurance', 'manager'),
    (ta, admin2, 'insurance', 'manager');
  insert into finance_team_members(tenant_id, user_id, role) values
    (ta, fin1, 'finance'), (ta, fin2, 'finance');

  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '1000', 'Operating', 'asset') returning id into bank_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '1100', 'AR', 'asset') returning id into ar_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '1210', 'WHT receivable', 'asset') returning id into wht_recv_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '2010', 'Insurer payable', 'liability') returning id into pay_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '2020', 'Unearned commission', 'liability') returning id into unearned_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '4000', 'Commission income', 'revenue') returning id into income_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '4100', 'Broker fees', 'revenue') returning id into fee_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '2200', 'VAT output', 'liability') returning id into vat_gl;
  insert into gl_posting_rules(tenant_id, account_role, gl_account_id) values
    (ta, 'bank', bank_gl), (ta, 'ar_control', ar_gl), (ta, 'insurer_payable', pay_gl),
    (ta, 'unearned_commission', unearned_gl), (ta, 'commission_income', income_gl),
    (ta, 'vat_output', vat_gl), (ta, 'wht_receivable', wht_recv_gl);
  -- Client money is a separate bank account and a separate GL account: premium
  -- received from a client is held in trust, not in the operating account.
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '1020', 'Client money', 'asset') returning id into trust_gl;
  insert into gl_posting_rules(tenant_id, account_role, gl_account_id) values (ta, 'client_money_bank', trust_gl);
  insert into fin_bank_accounts(tenant_id, name, kind, currency, gl_account_id)
    values (ta, 'FEE-OP', 'operating', 'UGX', bank_gl) returning id into v_bank;
  insert into fin_bank_accounts(tenant_id, name, kind, currency, gl_account_id)
    values (ta, 'FEE-TRUST', 'client_money', 'UGX', trust_gl) returning id into v_bank;

  perform pg_temp.jwt(mgr);
  set local role authenticated;
  insert into ins_product_lines(tenant_id, code, name) values (ta, 'GEN', 'General') returning id into v_line;
  insert into ins_insurers(tenant_id, code, name) values (ta, 'ALPHA', 'Alpha Assurance') returning id into v_insurer; perform pg_temp.seed_commission_terms();
  reset role;

  c := ins_register_client('Fee client', 'corporate', null, null, null, 'low');

  cfg := jsonb_build_array(jsonb_build_object('insurer_id', v_insurer, 'share_pct', 100,
           'is_lead', true, 'commission_rate_pct', 10, 'reviewed', true));

  -- -------------------------------------------------------------------
  -- §1 A brokerage fee defaults to EXEMPT, and carries no VAT
  -- -------------------------------------------------------------------
  -- This is the correction that matters most: 18% was being added to every
  -- broker fee. Schedule 3 of the VAT Act puts brokerage inside insurance
  -- services, and insurance services are exempt supplies.
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  p := ins_create_policy(c.id, v_insurer, v_line, current_date, current_date + 365,
                         1000000, 'UGX', 1000000, 10, null, null);
  perform ins_set_policy_financial_configuration(p.id, cfg,
    jsonb_build_array(jsonb_build_object('kind', 'broker_fee', 'description', 'Brokerage fee',
      'amount', 50000, 'recipient_mode', 'broker', 'income_gl_account_id', fee_gl,
      'fee_class', 'insurance_brokerage', 'vat_mode', 'not_calculated', 'reviewed', true)));
  reset role;

  perform pg_temp.assert(
    (select fee_class = 'insurance_brokerage' and vat_mode = 'not_calculated'
            and vat_rate_pct is null and coalesce(vat_amount, 0) = 0
       from ins_policy_charges where policy_id = p.id and kind = 'broker_fee'),
    '§1 an exempt brokerage fee records no VAT at all');

  perform pg_temp.jwt(mgr);
  set local role authenticated;
  p := pg_temp.approve_and_bind(p.id);
  reset role;

  perform pg_temp.assert(p.gross_premium = 1000000,
    format('§1 the policy itself is unchanged (got %s)', p.gross_premium));
  perform pg_temp.assert(
    (select invoice_total = 1050000 and broker_fee_total = 50000 and vat_total = 0
       from ins_policy_financial_snapshots where policy_id = p.id),
    '§1 the client is billed premium + fee, with no VAT');
  perform pg_temp.assert(pg_temp.acct(ta, vat_gl) = 0,
    format('§1 no output VAT is posted for an exempt fee (got %s)', -pg_temp.acct(ta, vat_gl)));
  perform pg_temp.assert(pg_temp.acct(ta, fee_gl) = -50000,
    format('§1 but the fee revenue is still recognised (got %s)', -pg_temp.acct(ta, fee_gl)));

  -- -------------------------------------------------------------------
  -- §2 An exempt fee carrying VAT is refused, by name
  -- -------------------------------------------------------------------
  c := ins_register_client('Fee client two', 'corporate', null, null, null, 'low');
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  p := ins_create_policy(c.id, v_insurer, v_line, current_date, current_date + 365,
                         1000000, 'UGX', 1000000, 10, null, null);
  perform pg_temp.expect_error(
    format($q$select ins_set_policy_financial_configuration(%L, %L::jsonb, %L::jsonb)$q$, p.id, cfg,
      jsonb_build_array(jsonb_build_object('kind', 'broker_fee', 'description', 'Fee',
        'amount', 50000, 'recipient_mode', 'broker', 'income_gl_account_id', fee_gl,
        'fee_class', 'insurance_brokerage', 'vat_mode', 'exclusive', 'vat_rate_pct', 18,
        'reviewed', true))),
    'INS_FEE_VAT_EXEMPT',
    '§2 an exempt brokerage fee cannot carry VAT');

  -- A fee with no classification at all is refused too. Defaulting silently to
  -- exempt would be right for a brokerage fee and wrong for a consultancy
  -- charge, and only the caller knows which this is.
  perform pg_temp.expect_error(
    format($q$select ins_set_policy_financial_configuration(%L, %L::jsonb, %L::jsonb)$q$, p.id, cfg,
      jsonb_build_array(jsonb_build_object('kind', 'broker_fee', 'description', 'Fee',
        'amount', 50000, 'recipient_mode', 'broker', 'income_gl_account_id', fee_gl,
        'reviewed', true))),
    'INS_FEE_CLASS_REQUIRED',
    '§2 a fee must say what kind of supply it is');

  -- -------------------------------------------------------------------
  -- §3 A taxable service is allowed, but only deliberately
  -- -------------------------------------------------------------------
  -- Removing the option would push genuinely taxable work into the exempt
  -- bucket, which under-declares VAT. So it is available and must be justified.
  perform pg_temp.expect_error(
    format($q$select ins_set_policy_financial_configuration(%L, %L::jsonb, %L::jsonb)$q$, p.id, cfg,
      jsonb_build_array(jsonb_build_object('kind', 'broker_fee', 'description', 'Consultancy',
        'amount', 50000, 'recipient_mode', 'broker', 'income_gl_account_id', fee_gl,
        'fee_class', 'other_taxable_service', 'vat_mode', 'exclusive', 'vat_rate_pct', 18,
        'reviewed', true))),
    'INS_FEE_CLASS_REASON',
    '§3 classifying a fee as taxable needs a reason, because it departs from the exempt default');

  perform pg_temp.expect_error(
    format($q$select ins_set_policy_financial_configuration(%L, %L::jsonb, %L::jsonb)$q$, p.id, cfg,
      jsonb_build_array(jsonb_build_object('kind', 'broker_fee', 'description', 'Consultancy',
        'amount', 50000, 'recipient_mode', 'broker', 'income_gl_account_id', fee_gl,
        'fee_class', 'vatable_consultancy', 'reviewed', true))),
    'INS_FEE_CLASS_INVALID',
    '§3 an invented classification is refused');

  -- -------------------------------------------------------------------
  -- §4 The standard rate comes from governance, and is copied
  -- -------------------------------------------------------------------
  -- 18% used to be typed per charge by whoever configured the policy. It is now
  -- an approved, effective-dated parameter -- and the value used is copied onto
  -- the charge so that changing the rate later cannot rewrite a bound policy.
  -- Proposing needs an acting user: the parameters table is written under RLS.
  perform pg_temp.jwt(admin1);
  set local role authenticated;
  insert into regulatory_parameters(tenant_id, parameter_key, value_num, effective_from, source_ref, created_by)
    values (ta, 'tax.vat_standard_rate_percent', 18, current_date - 365,
            'VERIFIED: test fixture, standard VAT rate', admin1)
    returning id into v_param;
  reset role;
  insert into regulatory_approval_assignments(tenant_id, user_id, scope, scope_value, responsibility, effective_from, assigned_by)
    values (ta, admin2, 'category', 'tax', 'Tax parameters (test)', current_date - 365, admin1);
  perform pg_temp.jwt(admin2);
  set local role authenticated;
  perform public.reg_approve_parameter(v_param);
  reset role;

  perform pg_temp.jwt(mgr);
  set local role authenticated;
  perform ins_set_policy_financial_configuration(p.id, cfg,
    jsonb_build_array(jsonb_build_object('kind', 'broker_fee', 'description', 'Consultancy work',
      'amount', 50000, 'recipient_mode', 'broker', 'income_gl_account_id', fee_gl,
      'fee_class', 'other_taxable_service',
      'fee_class_reason', 'Test fixture: separate advisory engagement, not insurance brokerage',
      'vat_mode', 'exclusive', 'reviewed', true)));
  reset role;

  perform pg_temp.assert(
    (select vat_rate_pct = 18 and vat_rate_parameter_ref = v_param
       from ins_policy_charges where policy_id = p.id and kind = 'broker_fee'),
    '§4 the approved standard rate was used and the parameter it came from is recorded');

  -- A taxable fee when no approved rate covers the date is refused, not guessed.
  -- End-dated rather than deleted: an approved parameter cannot be edited
  -- (`REG_APPROVED_IMMUTABLE`), and shortening its window is the sanctioned way
  -- to take it out of force. The assertion below confirms it really is out of
  -- force before the refusal is tested, so a passing test cannot be an accident.
  select id into v_param from regulatory_parameters
   where tenant_id = ta and parameter_key = 'tax.vat_standard_rate_percent';
  perform pg_temp.jwt(admin2);
  set local role authenticated;
  perform public.reg_end_parameter(v_param, current_date - 1);
  reset role;
  perform pg_temp.assert(
    not exists (select 1 from regulatory_parameters
                 where tenant_id = ta and parameter_key = 'tax.vat_standard_rate_percent'
                   and status = 'approved'
                   and effective_from <= current_date
                   and coalesce(effective_to, 'infinity'::date) >= current_date),
    '§4 fixture: no approved standard rate covers today, so the refusal below is real');
  delete from ins_policy_charges where policy_id = p.id;
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  perform pg_temp.expect_error(
    format($q$select ins_set_policy_financial_configuration(%L, %L::jsonb, %L::jsonb)$q$, p.id, cfg,
      jsonb_build_array(jsonb_build_object('kind', 'broker_fee', 'description', 'Consultancy',
        'amount', 50000, 'recipient_mode', 'broker', 'income_gl_account_id', fee_gl,
        'fee_class', 'other_taxable_service',
        'fee_class_reason', 'Test fixture: separate advisory engagement, not insurance brokerage',
        'vat_mode', 'exclusive', 'reviewed', true))),
    'INS_FEE_VAT_RATE_MISSING',
    '§4 a taxable fee with no approved rate is refused rather than given a number');
  reset role;

  -- -------------------------------------------------------------------
  -- §5 The client statement agrees with the ledger
  -- -------------------------------------------------------------------
  -- The defect. Before this change, a policy billed 1,050,000 (premium plus a
  -- 50,000 exempt fee) reported 1,000,000 billed, because the view recomputed
  -- billing from the premium instead of reading the receivable. The client and
  -- the aged-debtors report were both short by the fee.
  perform pg_temp.assert(
    p.status = 'draft',
    '§5 fixture: this policy is still a draft, so it is not yet on the statement');

  -- Give it the exempt fee and re-check, exactly as the bug was found.
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  perform ins_set_policy_financial_configuration(p.id, cfg,
    jsonb_build_array(jsonb_build_object('kind', 'broker_fee', 'description', 'Brokerage fee',
      'amount', 50000, 'recipient_mode', 'broker', 'income_gl_account_id', fee_gl,
      'fee_class', 'insurance_brokerage', 'vat_mode', 'not_calculated', 'reviewed', true)));
  p := pg_temp.approve_and_bind(p.id);
  reset role;

  perform pg_temp.assert(
    (select billed_amount from ins_client_statement where policy_id = p.id) = 1050000,
    format('§5 the statement bills 1,050,000, premium plus fee (got %s)',
           (select billed_amount from ins_client_statement where policy_id = p.id)));
  perform pg_temp.assert(
    (select balance_amount from ins_client_statement where policy_id = p.id) = 1050000,
    '§5 and the whole of it is outstanding before any receipt');
  perform pg_temp.assert(
    (select broker_fee_amount = 50000 and broker_fee_vat_amount = 0
       from ins_client_statement where policy_id = p.id),
    '§5 the statement can now tell the client what the fee was');
  -- The statement and the ledger are the same number. This is the assertion that
  -- would have caught the original defect.
  perform pg_temp.assert(
    (select billed_amount from ins_client_statement where policy_id = p.id) = pg_temp.acct(ta, ar_gl)
      - (select coalesce(sum(debit - credit), 0) from journal_entry_lines
          where gl_account_id = ar_gl and journal_entry_id <> p.journal_entry_id),
    '§5 the statement agrees with the receivable posted at bind');

  -- -------------------------------------------------------------------
  -- §6 Client withholding is an asset, not lost revenue
  -- -------------------------------------------------------------------
  -- A client that withholds 6% from a 1,000,000 fee still owes and has paid the
  -- full fee as far as the brokerage is concerned: revenue stays whole and the
  -- withheld tax becomes a credit to claim. Recording it must not reduce income.
  perform pg_temp.assert(
    (select billed_amount from ins_client_statement where policy_id = p.id) = 1050000,
    '§6 fixture: the fee-bearing policy bills 1,050,000');

  -- A receipt for the whole amount, then the withholding recorded against it.
  perform pg_temp.jwt(fin1);
  set local role authenticated;
  q := ins_submit_policy_cash_request(p.id, 'receipt', v_bank, 1050000, current_date,
        gen_random_uuid(), 'FEE-RCPT-1', null);
  reset role;
  perform pg_temp.jwt(fin2);
  set local role authenticated;
  perform ins_decide_policy_cash_request(q.id, 'approve', 'cash received');
  reset role;

  -- Nothing is withheld until somebody says so, with a basis and a reason.
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  perform pg_temp.expect_error(
    format($q$select ins_record_fee_withholding(%L, 63000, 's129_professional_fee', 'short')$q$, q.id),
    'INS_FEE_WHT_REASON',
    '§6 withholding needs a reason worth reading');
  perform pg_temp.expect_error(
    format($q$select ins_record_fee_withholding(%L, 1050000, 's129_professional_fee', 'withholding the entire invoice, which cannot be right')$q$, q.id),
    'INS_FEE_WHT_EXCEEDS',
    '§6 a client cannot withhold the whole invoice');
  reset role;

  v_fee_before := pg_temp.acct(ta, fee_gl);
  v_vat_before := pg_temp.acct(ta, vat_gl);

  perform pg_temp.jwt(mgr);
  set local role authenticated;
  out := ins_record_fee_withholding(q.id, 63000, 's129_professional_fee',
    'Client asserted 6% professional-fee withholding on this receipt', 6);
  reset role;

  perform pg_temp.assert((out ->> 'recorded')::boolean, '§6 the withholding is recorded');
  perform pg_temp.assert((out ->> 'gross_amount')::numeric = 1050000
                     and (out ->> 'wht_amount')::numeric = 63000
                     and (out ->> 'net_received')::numeric = 987000,
    format('§6 gross 1,050,000 less 63,000 withheld is 987,000 received (%s)', out::text));

  -- The three things that must be true of the ledger.
  perform pg_temp.assert(pg_temp.acct(ta, wht_recv_gl) = 63000,
    format('§6 the withheld tax is an ASSET in wht_receivable (got %s)', pg_temp.acct(ta, wht_recv_gl)));
  perform pg_temp.assert(pg_temp.acct(ta, fee_gl) = v_fee_before,
    format('§6 revenue is untouched by withholding (was %s, now %s)', v_fee_before, pg_temp.acct(ta, fee_gl)));
  perform pg_temp.assert(pg_temp.acct(ta, vat_gl) = v_vat_before,
    '§6 and so is VAT; withholding is income tax the client paid on the brokerage''s behalf');
  -- Nothing new landed in a liability: this is not the brokerage's tax to owe.
  perform pg_temp.assert(
    not exists (select 1 from journal_entry_lines l join journal_entries je on je.id = l.journal_entry_id
                 where je.tenant_id = ta and je.source_type = 'ins_fee_withholding'
                   and l.gl_account_id in (select id from gl_accounts where tenant_id = ta and account_type = 'liability')),
    '§6 no liability is created: the brokerage owes nothing, it is owed');

  perform pg_temp.assert(
    (select coalesce(sum(l.debit), 0) = coalesce(sum(l.credit), 0)
       from journal_entry_lines l join journal_entries je on je.id = l.journal_entry_id
      where je.tenant_id = ta and je.source_type = 'ins_fee_withholding'),
    '§6 the withholding entry balances');

  perform pg_temp.assert(
    (public.ins_fee_withholding_position() ->> 'recoverable_total')::numeric = 63000,
    '§6 the position reports 63,000 recoverable');

  -- Withholding cannot be recorded against a receipt that has not settled: an
  -- entry describing money that has not arrived is a fiction.
  --
  -- Built on its own policy so the receipt is guaranteed to be legal: a PENDING
  -- request is submitted by one Finance user and never approved. Written this
  -- way round because a receipt on a settled policy is refused by the cash cap,
  -- and catching that refusal would turn this into a test that passes by not
  -- running.
  declare
    v_pending ins_policy_cash_requests%rowtype;
    v_pol2    ins_policies%rowtype;
    v_cl2     ins_clients%rowtype;
  begin
    v_cl2 := ins_register_client('Fee client pending', 'corporate', null, null, null, 'low');
    perform pg_temp.jwt(mgr);
    set local role authenticated;
    v_pol2 := ins_create_policy(v_cl2.id, v_insurer, v_line, current_date, current_date + 365,
                                1000000, 'UGX', 1000000, 10, null, null);
    v_pol2 := pg_temp.approve_and_bind(v_pol2.id);
    reset role;

    perform pg_temp.jwt(fin1);
    set local role authenticated;
    v_pending := ins_submit_policy_cash_request(v_pol2.id, 'receipt', v_bank, 500000,
                   current_date, gen_random_uuid(), 'FEE-PENDING', null);
    reset role;

    perform pg_temp.assert(v_pending.id is not null and v_pending.status <> 'posted',
      format('§6 fixture: the receipt is %s, so it is not money yet', v_pending.status));

    perform pg_temp.jwt(mgr);
    set local role authenticated;
    perform pg_temp.expect_error(
      format($q$select ins_record_fee_withholding(%L, 6000, 's129_professional_fee', 'withholding recorded before the cash arrived, which is not money yet')$q$, v_pending.id),
      'INS_FEE_WHT_NOT_POSTED',
      '§6 withholding cannot be recorded against a receipt that has not posted');
    reset role;
  end;

  -- Recording it twice is reported, not repeated: a claim entered twice is a
  -- claim the revenue authority will reject.
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  out := ins_record_fee_withholding(q.id, 63000, 's129_professional_fee',
    'Client asserted 6% professional-fee withholding on this receipt', 6);
  reset role;
  perform pg_temp.assert((out ->> 'already_recorded')::boolean,
    '§6 recording the same withholding twice is reported as already done');
  perform pg_temp.assert(pg_temp.acct(ta, wht_recv_gl) = 63000,
    '§6 and the asset is not doubled');

  -- -------------------------------------------------------------------
  -- §7 Withholding is never assumed: no approved rate, no deduction
  -- -------------------------------------------------------------------
  -- Whether a client-paid insurance brokerage fee is a professional fee under
  -- s.129 is NOT settled. Being VAT-exempt does not answer it. So with the rate
  -- unapproved, the claim is refused rather than defaulted to 6%.
  --
  -- The second half proves the refusal is really about the missing rate: a rate
  -- of 6% supplied explicitly, with a stated basis, IS accepted. Without that,
  -- the first assertion would also pass on an implementation that refused every
  -- claim regardless of the rate, and defaulting-to-6% would look like a fix.
  c := ins_register_client('Fee client three', 'corporate', null, null, null, 'low');
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  p := ins_create_policy(c.id, v_insurer, v_line, current_date, current_date + 365,
                         1000000, 'UGX', 1000000, 10, null, null);
  p := pg_temp.approve_and_bind(p.id);
  reset role;

  perform pg_temp.jwt(fin1);
  set local role authenticated;
  q := ins_submit_policy_cash_request(p.id, 'receipt', v_bank, 1000000, current_date,
        gen_random_uuid(), 'FEE-RCPT-2', null);
  reset role;
  perform pg_temp.jwt(fin2);
  set local role authenticated;
  perform ins_decide_policy_cash_request(q.id, 'approve', 'cash received');
  reset role;

  perform pg_temp.assert(
    not exists (select 1 from regulatory_parameters
                 where tenant_id = ta and parameter_key = 'tax.wht_client_fee_percent'
                   and status = 'approved'),
    '§7 fixture: no rate for client withholding on fees is approved');

  perform pg_temp.jwt(mgr);
  set local role authenticated;
  perform pg_temp.expect_error(
    format($q$select ins_record_fee_withholding(%L, 60000, 's129_professional_fee', 'Client withheld six per cent on this fee, see the remittance advice')$q$, q.id),
    'INS_FEE_WHT_RATE_MISSING',
    '§7 with no approved rate the deduction is refused, never assumed at 6%');
  reset role;

  -- And the same claim IS accepted once the rate is stated explicitly with its
  -- basis, which is what makes the refusal above about the missing rate rather
  -- than about withholding in general.
  perform pg_temp.assert(
    not exists (select 1 from ins_fee_wht_records
                 where tenant_id = ta and cash_request_id = q.id),
    '§7 the refused claim recorded nothing');
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  out := ins_record_fee_withholding(q.id, 60000, 's129_professional_fee',
    'Client asserted 6% professional-fee withholding under s.129, remittance advice attached', 6);
  reset role;
  perform pg_temp.assert((out ->> 'recorded')::boolean,
    '§7 with the rate stated explicitly the claim is recorded');
  perform pg_temp.assert(pg_temp.acct(ta, wht_recv_gl) = 63000 + 60000,
    format('§7 and the asset rises by it (got %s)', pg_temp.acct(ta, wht_recv_gl)));

  -- -------------------------------------------------------------------
  -- §8 A renewal carries the classification forward
  -- -------------------------------------------------------------------
  -- The renewal path copies charges by naming its columns. When the
  -- classification columns were added it silently dropped them, and the
  -- consistency constraint refused every fee-bearing renewal. A renewal must
  -- carry the original classification rather than re-deriving it: the same
  -- supply to the same client does not become taxable because a rule was
  -- approved in between.
  reset role;
  declare
    v_renew ins_policies%rowtype;
    v_old ins_policy_charges%rowtype;
  begin
    select * into v_old from ins_policy_charges where policy_id = p.id and kind = 'broker_fee';
    perform pg_temp.assert(v_old.id is null or true, '§8 fixture');
    -- Use the §5 policy, which carries the exempt fee.
    select * into v_old from ins_policy_charges
     where policy_id = (select policy_id from ins_policy_charges
                         where fee_class = 'insurance_brokerage' and tenant_id = ta limit 1)
       and kind = 'broker_fee';
    perform pg_temp.assert(v_old.fee_class = 'insurance_brokerage',
      '§8 fixture: an exempt fee exists to renew');

    perform pg_temp.jwt(mgr);
    set local role authenticated;
    v_renew := ins_create_renewal_draft(
      (select policy_id from ins_policy_charges where id = v_old.id));
    reset role;

    perform pg_temp.assert(
      (select fee_class = 'insurance_brokerage' and vat_mode = 'not_calculated'
              and vat_rate_pct is null
         from ins_policy_charges where policy_id = v_renew.id and kind = 'broker_fee'),
      '§8 the renewed policy carries the exempt classification and no VAT');
  end;

  raise notice 'PASS: client-paid broker fees (all scenarios)';
end $$;

-- ---------------------------------------------------------------------
-- Catalog assertions
-- ---------------------------------------------------------------------
select pg_temp.assert(
  (select count(*) = 1 from regulatory_parameter_definitions
    where key = 'tax.vat_standard_rate_percent' and value_type = 'percent'),
  'the standard VAT rate is a declared percentage parameter');
select pg_temp.assert(
  (select count(*) = 1 from regulatory_parameter_definitions
    where key = 'tax.wht_client_fee_percent' and value_type = 'percent'),
  'the client-fee withholding rate is a declared percentage parameter');

-- The statement must not read a finance-only table directly; it goes through a
-- helper, as the module's own catalog test requires.
select pg_temp.assert(
  pg_get_viewdef('public.ins_client_statement'::regclass) !~* '\m(fin_open_items|fin_open_item_balances)\M',
  'the client statement reads the ledger through a helper, not a finance table');
select pg_temp.assert(
  (select p.prosecdef and exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%')
     from pg_proc p where p.oid = 'public.ins_policy_billed_amount(uuid)'::regprocedure),
  'the billed-amount helper is SECURITY DEFINER with a pinned search_path');
select pg_temp.assert(
  not has_function_privilege('anon', 'public.ins_policy_billed_amount(uuid)'::regprocedure, 'EXECUTE'),
  'and it is not anon-executable');

-- The withholding record is read-only to clients; every write goes through the RPC.
select pg_temp.assert(
  (select count(*) = 1 from pg_policies where schemaname = 'public'
     and tablename = 'ins_fee_wht_records' and cmd = 'SELECT'
     and 'authenticated' = any (roles)),
  'the fee withholding table has an authenticated SELECT policy, and only for SELECT');
select pg_temp.assert(
  (select count(*) = 0 from information_schema.role_table_grants
    where table_schema = 'public' and table_name = 'ins_fee_wht_records'
      and grantee in ('anon', 'authenticated')
      and privilege_type in ('INSERT', 'UPDATE', 'DELETE')),
  'and no client can write to it directly');

-- The identity the ledger depends on, proven: net = gross - withheld.
do $$
begin
  begin
    insert into ins_fee_wht_records
      (tenant_id, cash_request_id, client_id, currency, gross_amount, wht_amount,
       net_received, wht_rate_pct, basis, reason)
    select tenant_id, gen_random_uuid(), client_id, 'UGX', 1000, 100, 950, 6,
           's129_professional_fee', 'a reason of sufficient length for the constraint'
      from ins_policies where tenant_id is not null limit 1;
    raise exception 'FAIL: gross 1000 less 100 withheld should not net to 950';
  exception when check_violation then null;
  end;
end $$;
select pg_temp.assert(true, 'the database refuses a net that is not gross less withheld');

rollback;
