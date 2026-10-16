-- Cross-tenant tests for the insurance reporting VIEWS, and a strong check of the
-- broker-fee tax report using a real posted financial snapshot.
--
-- The six views are security_invoker, so tenant isolation comes from the base-table
-- RLS, not from a tenant filter in the view. If a base table's RLS is loosened, or a
-- view is changed to security definer, tenant B would see tenant A's rows. These
-- checks catch that.
--
--   ins_broker_fee_tax_report     broker-fee invoice lines (needs a snapshot: the
--                                 policy is configured and bound through the app RPCs,
--                                 with a broker fee charge, so it is an extended snapshot)
--   ins_claim_cash_position       claim cash position
--   ins_commission_ledger         commission entries
--   ins_commission_position       commission totals by tenant
--   ins_policy_cash_items         open items for premium cash. INTERNAL: no grant to
--                                 authenticated, so direct reads are denied (42501).
--   ins_renewal_pipeline          active policies expiring within 120 days
--
-- Grants: the read views must give authenticated SELECT only (no INSERT, UPDATE,
-- DELETE, TRUNCATE, REFERENCES or TRIGGER), and anon nothing.
--
-- For each readable view:
--   1. Positive control: tenant A's own user sees rows (so an empty result cannot pass).
--   2. Tenant B (no data of its own) sees zero rows, and no row for tenant A's tenant_id.
--   3. Tenant A's rows are unchanged after tenant B has read everything (fingerprint).
-- The broker-fee RPC (ins_broker_fee_tax_rows) gets the same checks, plus the exact
-- values for tenant A's fee line, and a date-filtered call for tenant B.
--
-- Run only on a disposable local/test database; every fixture rolls back.

\set ON_ERROR_STOP on
begin;

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

-- Runs a statement that must fail with the given SQLSTATE.
create function pg_temp.expect_state(p_sql text, p_state text, p_label text)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlstate = p_state then return; end if;
    raise exception 'FAIL: % raised sqlstate % (%), expected %', p_label, sqlstate, sqlerrm, p_state;
  end;
  raise exception 'FAIL: % succeeded but should have failed with sqlstate %', p_label, p_state;
end $$;

-- Rows of a view for one tenant, as the current role sees them.
create function pg_temp.cnt(p_view text, p_tenant uuid)
returns integer language plpgsql as $$
declare n integer;
begin
  execute format('select count(*) from %I where tenant_id = $1', p_view) using p_tenant into n;
  return n;
end $$;

-- All rows of a view as the current role sees them (no tenant filter).
create function pg_temp.cnt_all(p_view text)
returns integer language plpgsql as $$
declare n integer;
begin
  execute format('select count(*) from %I', p_view) into n;
  return n;
end $$;

-- Content fingerprint of everything the current role can see in a view.
create function pg_temp.fp(p_view text)
returns text language plpgsql as $$
declare r text;
begin
  execute format(
    'select coalesce(md5(string_agg(t::text, ''|'' order by t::text)), ''none'') || '':'' || count(*) from %I t',
    p_view) into r;
  return r;
end $$;

do $$
declare
  views text[] := array['ins_broker_fee_tax_report','ins_claim_cash_position','ins_commission_ledger',
                        'ins_commission_position','ins_renewal_pipeline'];
  v text;
  dml text;
  ta uuid := gen_random_uuid(); tb uuid := gen_random_uuid();
  mgr_a uuid := gen_random_uuid(); mgr_b uuid := gen_random_uuid();
  bank_gl uuid; trust_gl uuid; ar_gl uuid; pay_gl uuid; unearned_gl uuid; income_gl uuid;
  fee_gl uuid; tax_gl uuid;
  line_id uuid; insurer uuid; c ins_clients%rowtype; p ins_policies%rowtype; cl ins_claims%rowtype;
  config jsonb; charge_config jsonb;
  fp_before jsonb := '{}'::jsonb; fp_after jsonb := '{}'::jsonb;
  n integer; fee_row record; total_fee_rows integer;
begin
  -- 0. Grants (no fixture needed). Read views: SELECT only for authenticated.
  foreach v in array views loop
    foreach dml in array array['INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER'] loop
      perform pg_temp.assert(not has_table_privilege('authenticated', v, dml),
        format('authenticated has %s on view %s (read views must be SELECT only)', dml, v));
    end loop;
    perform pg_temp.assert(has_table_privilege('authenticated', v, 'SELECT'), format('authenticated lacks SELECT on %s', v));
    perform pg_temp.assert(not has_table_privilege('anon', v, 'SELECT'), format('anon can read %s', v));
  end loop;
  perform pg_temp.assert(not has_table_privilege('authenticated', 'ins_policy_cash_items', 'SELECT'),
    'ins_policy_cash_items is internal but authenticated has SELECT');
  perform pg_temp.assert(not has_table_privilege('anon', 'ins_policy_cash_items', 'SELECT'),
    'anon can read ins_policy_cash_items');

  -- Two tenants. Tenant B has an insurance manager with finance access but no data.
  insert into tenants(id, name) values (ta, 'Views cross-tenant A'), (tb, 'Views cross-tenant B');
  insert into auth.users(id, email, raw_user_meta_data, raw_app_meta_data, aud, role, created_at, updated_at)
    select u, 'vw-'||u||'@test.local', '{}', '{}', 'authenticated', 'authenticated', now(), now()
    from unnest(array[mgr_a, mgr_b]) u;
  insert into app_users(id, tenant_id, name, email) values
    (mgr_a, ta, 'Views manager A', 'vw-'||mgr_a||'@test.local'),
    (mgr_b, tb, 'Views manager B', 'vw-'||mgr_b||'@test.local');
  insert into tenant_modules(tenant_id, module) values (ta, 'insurance'), (tb, 'insurance');
  insert into staff_roles(tenant_id, user_id, module, role) values
    (ta, mgr_a, 'insurance', 'manager'), (tb, mgr_b, 'insurance', 'manager');
  insert into finance_team_members(tenant_id, user_id, role) values
    (ta, mgr_a, 'finance'), (tb, mgr_b, 'finance');

  -- Tenant A: the GL and posting rules that bind and the commission/fee postings need.
  insert into gl_accounts(tenant_id, account_code, name, account_type) values
    (ta, '1000', 'Operating', 'asset'), (ta, '1020', 'Client money', 'asset'),
    (ta, '1100', 'AR', 'asset'), (ta, '2010', 'Insurer payable', 'liability'),
    (ta, '2020', 'Unearned commission', 'liability'), (ta, '4000', 'Commission income', 'revenue'),
    (ta, '4010', 'Broker fee income', 'revenue'), (ta, '2100', 'Output VAT liability', 'liability');
  select id into bank_gl from gl_accounts where tenant_id = ta and account_code = '1000';
  select id into trust_gl from gl_accounts where tenant_id = ta and account_code = '1020';
  select id into ar_gl from gl_accounts where tenant_id = ta and account_code = '1100';
  select id into pay_gl from gl_accounts where tenant_id = ta and account_code = '2010';
  select id into unearned_gl from gl_accounts where tenant_id = ta and account_code = '2020';
  select id into income_gl from gl_accounts where tenant_id = ta and account_code = '4000';
  select id into fee_gl from gl_accounts where tenant_id = ta and account_code = '4010';
  select id into tax_gl from gl_accounts where tenant_id = ta and account_code = '2100';
  insert into gl_posting_rules(tenant_id, account_role, gl_account_id) values
    (ta, 'bank', bank_gl), (ta, 'client_money_bank', trust_gl), (ta, 'ar_control', ar_gl),
    (ta, 'insurer_payable', pay_gl), (ta, 'unearned_commission', unearned_gl),
    (ta, 'commission_income', income_gl), (ta, 'vat_output', tax_gl);

  -- Tenant A's manager builds the policy through the app RPCs.
  perform pg_temp.jwt(mgr_a); set local role authenticated;
  insert into ins_product_lines(tenant_id, code, name) values (ta, 'MOTOR', 'Motor') returning id into line_id;
  insert into ins_insurers(tenant_id, code, name) values (ta, 'ALPHA', 'Alpha') returning id into insurer;
  c := ins_register_client('Views client A', 'corporate', null, null, null, 'low');
  -- Expires in 30 days so the renewal pipeline has a row for the positive control.
  p := ins_create_policy(c.id, insurer, line_id, current_date, current_date + 30, 50000, 'UGX', 1000, 10, null, null);

  -- One insurer at 100% with a broker fee of 50 plus 18% exclusive VAT (= 9). The 18% is
  -- only a test value, NOT a configured or default statutory rate. A charge makes the
  -- snapshot "extended", which is what the broker-fee report reads.
  config := jsonb_build_array(jsonb_build_object('insurer_id', insurer, 'is_lead', true, 'share_pct', 100,
    'commission_rate_pct', 10, 'insurer_policy_no', 'V-001', 'reviewed', true));
  charge_config := jsonb_build_array(jsonb_build_object('kind', 'broker_fee', 'description', 'Broker service fee',
    'amount', 50, 'recipient_mode', 'broker', 'income_gl_account_id', fee_gl,
    'vat_mode', 'exclusive', 'vat_rate_pct', 18, 'reviewed', true));
  perform ins_set_policy_financial_configuration(p.id, config, charge_config);
  p := ins_bind_policy(p.id);

  -- A claim on the bound policy, so the claim cash position has a row.
  cl := ins_create_claim(p.id, current_date, current_date, 'Views test loss', 'CLM-VIEW-1', 5000);
  -- The claim cash view only lists approved claims, so approve it (amount within the reserve).
  perform ins_transition_claim(cl.id, 'assessing', null, null);
  perform ins_transition_claim(cl.id, 'approved', 'Views test approval', 4000);
  reset role;

  -- Snapshot sanity, checked as superuser: the broker-fee snapshot exists and is extended.
  perform pg_temp.assert(exists(select 1 from ins_policy_financial_snapshots
    where policy_id = p.id and extended and broker_fee_total = 50),
    'fixture: bound policy has no extended snapshot with broker_fee_total 50');

  -- 1. Positive control, and fingerprint of tenant A's view rows before tenant B reads.
  perform pg_temp.jwt(mgr_a); set local role authenticated;
  foreach v in array views loop
    n := pg_temp.cnt(v, ta);
    perform pg_temp.assert(n > 0, format('control: tenant A sees no rows in %s', v));
    fp_before := fp_before || jsonb_build_object(v, pg_temp.fp(v));
  end loop;

  select fee_amount, vat_amount into fee_row from ins_broker_fee_tax_rows() where policy_id = p.id;
  perform pg_temp.assert(fee_row.fee_amount = 50 and fee_row.vat_amount = 9,
    format('control: tenant A fee line is %s / %s, expected 50 / 9', fee_row.fee_amount, fee_row.vat_amount));
  reset role;

  -- Internal view: direct reads are denied for tenant A's own manager too.
  perform pg_temp.jwt(mgr_a); set local role authenticated;
  perform pg_temp.expect_state('select count(*) from ins_policy_cash_items', '42501',
    'tenant A direct read of internal view ins_policy_cash_items');
  reset role;

  -- 2. Tenant B: no data of its own, and no tenant A rows in any view or the fee RPC.
  perform pg_temp.jwt(mgr_b); set local role authenticated;
  perform pg_temp.expect_state('select count(*) from ins_policy_cash_items', '42501',
    'tenant B direct read of internal view ins_policy_cash_items');
  foreach v in array views loop
    perform pg_temp.assert(pg_temp.cnt_all(v) = 0,
      format('tenant B sees %s rows of some tenant in %s (expected none)', pg_temp.cnt_all(v), v));
    perform pg_temp.assert(pg_temp.cnt(v, ta) = 0,
      format('tenant B sees tenant A rows in %s', v));
  end loop;

  select count(*) into total_fee_rows from ins_broker_fee_tax_rows();
  perform pg_temp.assert(total_fee_rows = 0, 'tenant B sees tenant A broker-fee rows');
  select count(*) into total_fee_rows from ins_broker_fee_tax_rows(current_date - 365, current_date + 365);
  perform pg_temp.assert(total_fee_rows = 0, 'tenant B sees tenant A broker-fee rows with a date filter');
  reset role;

  -- 3. Tenant A's rows are unchanged after tenant B's reads.
  perform pg_temp.jwt(mgr_a); set local role authenticated;
  foreach v in array views loop
    fp_after := fp_after || jsonb_build_object(v, pg_temp.fp(v));
    perform pg_temp.assert(fp_after->>v = fp_before->>v,
      format('tenant A rows changed in %s after tenant B reads', v));
  end loop;
  reset role;

  raise notice 'PASS: view grants, cross-tenant views (5 readable, 1 internal) and broker-fee report with a real snapshot';
end $$;

rollback;
