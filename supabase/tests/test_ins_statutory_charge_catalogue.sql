-- =====================================================================
-- Statutory charge catalogue (owner item 4)
-- =====================================================================
-- The catalogue is only worth having if it can be trusted, and trust here means
-- four things that a reviewer cannot check by reading a seed file:
--
--   §1 verified charges price from the statute, unverified ones are invisible
--   §2 a rate cannot be edited once billed -- a new version is the only way
--   §3 the class/basis/collector/recipient/payable-account fields are mandatory,
--      because a charge that cannot say all five is not chargeable
--   §4 a company cannot write a statutory charge, and cannot see another
--      company's commercial fee
--   §5 the policy charge snapshots the version it was billed under, so a later
--      rate change cannot restate an old policy
--
-- One transaction, rolled back.
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

do $$
declare
  ta uuid := gen_random_uuid();
  tb uuid := gen_random_uuid();
  admin_a uuid := gen_random_uuid();
  admin_b uuid := gen_random_uuid();
  v_levy uuid; v_ira uuid; v_stamp uuid;
  v_row record; v_count integer;
  v_own_fee uuid; v_used uuid;
begin
  insert into tenants(id, name) values (ta, 'Charges A'), (tb, 'Charges B');
  insert into auth.users(id, email, raw_user_meta_data, raw_app_meta_data, aud, role, created_at, updated_at)
    select u, 'chg-' || u || '@test.local', '{}', '{}', 'authenticated', 'authenticated', now(), now()
    from unnest(array[admin_a, admin_b]) u;
  insert into app_users(id, tenant_id, name, email)
    select u, case when u = admin_a then ta else tb end, 'Charges admin', 'chg-' || u || '@test.local'
    from unnest(array[admin_a, admin_b]) u;
  update app_users set is_company_admin = true where id in (admin_a, admin_b);
  insert into tenant_modules(tenant_id, module) values (ta, 'insurance'), (tb, 'insurance');
  -- Company admin is not insurance access: the module needs its own role, which
  -- is why §4 below can only be written by a user who has one.
  insert into staff_roles(tenant_id, user_id, module, role)
    values (ta, admin_a, 'insurance', 'admin'), (tb, admin_b, 'insurance', 'admin');

  select id into v_levy from ins_charge_catalogue where code = 'UG_INSURANCE_TRAINING_LEVY';
  select id into v_ira from ins_charge_catalogue where code = 'UG_IRA_LEVY';
  select id into v_stamp from ins_charge_catalogue where code = 'UG_STAMP_DUTY_GENERAL';

  -- -------------------------------------------------------------------
  -- §1 only verified charges price
  -- -------------------------------------------------------------------
  -- 5,000,000 gross premium at 0.5% is 25,000. The IRA levy (1.5%) would be
  -- 75,000 and the stamp duty 35,000 -- both absent because both are unverified,
  -- which is the whole point of seeding them inactive.
  select count(*) into v_count from ins_price_charges(ta, 5000000, 4500000, 500000, 'MOTOR', 'UGX', current_date);
  perform pg_temp.assert(v_count = 1,
    format('§1 exactly the one verified charge should price, got %s lines', v_count));

  select * into v_row from ins_price_charges(ta, 5000000, 4500000, 500000, 'MOTOR', 'UGX', current_date) limit 1;
  perform pg_temp.assert(v_row.code = 'UG_INSURANCE_TRAINING_LEVY',
    format('§1 the priced charge should be the training levy, got %s', v_row.code));
  perform pg_temp.assert(v_row.amount = 25000,
    format('§1 0.5%% of 5,000,000 is 25,000, got %s', v_row.amount));
  perform pg_temp.assert(v_row.charge_class = 'statutory_levy',
    '§1 it is classified as a statutory levy, not a fee');
  perform pg_temp.assert(v_row.recipient_name = 'Insurance Training College',
    '§1 the recipient is named');
  perform pg_temp.assert(v_row.catalogue_version >= 1 and v_row.snapshot is not null,
    '§1 the resolved line carries its version and snapshot');

  -- The warning channel, not silence: an unmapped payable account must surface.
  perform pg_temp.assert(
    exists (select 1 from unnest(v_row.warnings) w where w like 'INS_CHARGE_PAYABLE_UNCONFIGURED%'),
    '§1 an unconfigured payable account is reported as a warning');

  -- Unverified rows are still readable, so the accountant can see what is
  -- waiting, but they never produce an amount.
  perform pg_temp.assert(
    (select not is_active and verification_status = 'unverified'
       from ins_charge_catalogue where id = v_ira),
    '§1 the IRA levy is seeded unverified and inactive');
  perform pg_temp.assert(
    (select not is_active and verification_status = 'unverified' and fixed_amount = 35000
       from ins_charge_catalogue where id = v_stamp),
    '§1 stamp duty is seeded unverified, inactive, with its unconfirmed amount recorded');

  -- -------------------------------------------------------------------
  -- §3 the mandatory fields are mandatory
  -- -------------------------------------------------------------------
  perform pg_temp.expect_error(
    format($q$insert into ins_charge_catalogue
      (tenant_id, code, name, charge_class, formula, collector, recipient_name,
       recipient_kind, payable_role, effective_from)
      values (%L, 'X1', 'No recipient kind', 'statutory_levy',
               '{"kind":"rate","base":"gross_premium","rate_pct":1}'::jsonb,
               'insurer', 'Someone', null, 'x', current_date)$q$, ta),
    'null value',
    '§3 a charge without a recipient kind');

  perform pg_temp.expect_error(
    format($q$insert into ins_charge_catalogue
      (tenant_id, code, name, charge_class, formula, collector, recipient_name,
       recipient_kind, payable_role, effective_from)
      values (%L, 'X2', 'No payable role', 'statutory_levy',
               '{"kind":"rate","base":"gross_premium","rate_pct":1}'::jsonb,
               'insurer', 'Someone', 'regulator', null, current_date)$q$, ta),
    'null value',
    '§3 a charge without a payable account role');

  -- "Verified" without a source is an opinion, and is refused.
  perform pg_temp.expect_error(
    format($q$insert into ins_charge_catalogue
      (tenant_id, code, name, charge_class, formula, collector, recipient_name,
       recipient_kind, payable_role, verification_status, effective_from)
      values (%L, 'X3', 'Verified from nowhere', 'statutory_levy',
               '{"kind":"rate","base":"gross_premium","rate_pct":1}'::jsonb,
               'insurer', 'Someone', 'regulator', 'x', 'verified', current_date)$q$, ta),
    'ins_charge_catalogue_provenance_check',
    '§3 a verified charge with no source reference');

  -- A malformed formula is refused structurally, not by an enumeration. These
  -- are the mistakes a new charge is actually likely to contain.
  perform pg_temp.expect_error(
    format($q$insert into ins_charge_catalogue
      (tenant_id, code, name, charge_class, formula, collector, recipient_name,
       recipient_kind, payable_role, effective_from)
      values (%L, 'X4', 'Rate with no base', 'statutory_levy',
              '{"kind":"rate","rate_pct":1}'::jsonb,
              'insurer', 'Someone', 'regulator', 'x', current_date)$q$, ta),
    'ins_charge_catalogue_formula_check',
    '§3 a rate formula that names no base quantity');
  perform pg_temp.expect_error(
    format($q$insert into ins_charge_catalogue
      (tenant_id, code, name, charge_class, formula, collector, recipient_name,
       recipient_kind, payable_role, effective_from)
      values (%L, 'X5', 'Descending bands', 'statutory_levy',
              '{"kind":"banded","base":"gross_premium","bands":[{"up_to":100,"rate_pct":1},{"up_to":50,"rate_pct":2}]}'::jsonb,
              'insurer', 'Someone', 'regulator', 'x', current_date)$q$, ta),
    'ins_charge_catalogue_formula_check',
    '§3 banded rates that do not ascend');
  perform pg_temp.expect_error(
    format($q$insert into ins_charge_catalogue
      (tenant_id, code, name, charge_class, formula, collector, recipient_name,
       recipient_kind, payable_role, effective_from)
      values (%L, 'X6', 'Unknown kind', 'statutory_levy',
              '{"kind":"telepathy","rate_pct":1}'::jsonb,
              'insurer', 'Someone', 'regulator', 'x', current_date)$q$, ta),
    'ins_charge_catalogue_formula_check',
    '§3 a formula kind this build cannot price');

  -- -------------------------------------------------------------------
  -- §4 company scoping
  -- -------------------------------------------------------------------
  perform pg_temp.jwt(admin_b);
  set local role authenticated;
  -- B can read the statutory default it inherits...
  perform pg_temp.assert(
    exists (select 1 from ins_charge_catalogue where code = 'UG_INSURANCE_TRAINING_LEVY' and tenant_id is null),
    '§4 a statutory charge is visible to every company');
  -- ...and cannot write one, because a statute is not a company's to enter.
  begin
    insert into ins_charge_catalogue
      (tenant_id, code, name, charge_class, formula, collector, recipient_name,
       recipient_kind, payable_role, effective_from)
      values (null, 'FAKE', 'Company-written statute', 'statutory_tax',
              '{"kind":"rate","base":"gross_premium","rate_pct":2}'::jsonb,
              'insurer', 'Nobody', 'government', 'x', current_date);
    raise exception 'FAIL: §4 a company wrote a statutory charge (tenant_id null)';
  exception when insufficient_privilege or check_violation then
    null;  -- refused, which is the correct outcome
  end;
  reset role;

  -- A company's own commercial fee is its own.
  perform pg_temp.jwt(admin_a);
  set local role authenticated;
  insert into ins_charge_catalogue
    (tenant_id, code, name, charge_class, formula, currency, collector,
     recipient_name, recipient_kind, payable_role, effective_from)
    values (ta, 'A_POLICY_FEE', 'Policy issue fee', 'commercial_fee',
            '{"kind":"fixed","amount":10000,"per":"policy"}'::jsonb, 'UGX',
            'broker', 'Charges A', 'broker', 'broker_fee_income', current_date)
    returning id into v_own_fee;
  reset role;

  perform pg_temp.jwt(admin_b);
  set local role authenticated;
  perform pg_temp.assert(
    not exists (select 1 from ins_charge_catalogue where code = 'A_POLICY_FEE'),
    '§4 company B cannot see company A''s commercial fee');
  reset role;

  -- -------------------------------------------------------------------
  -- §2 and §5 a billed rate cannot be edited, and the policy keeps its snapshot
  -- -------------------------------------------------------------------
  perform pg_temp.jwt(admin_a);
  set local role authenticated;
  perform pg_temp.assert(
    exists (select 1 from ins_price_charges(ta, 5000000, 4500000, 500000, 'MOTOR', 'UGX', current_date)
             where code = 'A_POLICY_FEE' and amount = 10000),
    '§5 company A''s own fee prices for company A');
  reset role;

  -- Bill the training levy on a policy charge, then try to change the rate.
  -- ins_policy_charges carries a SELECT policy only: charges are written by the
  -- bind and by the endorsement posting path, never by a caller, so this row is
  -- seeded as the owner. The assertion is about the catalogue, not about who may
  -- insert a policy charge.
  declare
    v_policy uuid;
    v_line uuid;
    v_insurer uuid;
    v_client uuid;
    v_snapshot jsonb;
  begin
    perform pg_temp.jwt(admin_a);
    set local role authenticated;
    insert into ins_product_lines(tenant_id, code, name) values (ta, 'CHG', 'Charges') returning id into v_line;
    insert into ins_insurers(tenant_id, code, name) values (ta, 'CHGINS', 'Charges Insurer') returning id into v_insurer;
    v_client := (ins_register_client('Charges client', 'corporate', null, null, null, 'low')).id;
    insert into ins_policies(id, tenant_id, policy_no, client_id, insurer_id, product_line_id,
                             inception_date, expiry_date, sum_insured, gross_premium, currency,
                             commission_rate_pct, commission_amount, net_premium_to_insurer, status, created_by)
      values (gen_random_uuid(), ta, 'CHG-0001', v_client, v_insurer, v_line,
              current_date, current_date + 365, 1000000, 5000000, 'UGX',
              10, 500000, 4500000, 'draft', admin_a)
      returning id into v_policy;

    select snapshot into v_snapshot from ins_price_charges(ta, 5000000, 4500000, 500000, 'CHG', 'UGX', current_date)
      where code = 'UG_INSURANCE_TRAINING_LEVY';

    reset role;
    insert into ins_policy_charges
      (tenant_id, policy_id, kind, description, amount, recipient_mode, vat_mode, reviewed,
       catalogue_id, charge_class, catalogue_version, collector, recipient_name, payable_role,
       catalogue_snapshot)
      values (ta, v_policy, 'insurer_pass_through', 'Insurance Training Levy', 25000, 'all_insurers',
              'not_calculated', true, v_levy, 'statutory_levy', 1, 'insurer',
              'Insurance Training College', 'insurance_training_levy_payable', v_snapshot)
      returning id into v_used;

    perform pg_temp.assert(v_used is not null, '§5 the charge was billed');
    perform pg_temp.assert(
      (select (catalogue_snapshot ->> 'rate_pct')::numeric from ins_policy_charges where id = v_used) = 0.5,
      '§5 the policy charge snapshots the 0.5%% it was billed at');

    -- Now the minister raises the levy. A change of 0.5 -> 0.75 on the row that
    -- was already billed must be refused.
    perform pg_temp.expect_error(
      format($q$update ins_charge_catalogue set formula = '{"kind":"rate","base":"gross_premium","rate_pct":0.75}'::jsonb where id = %L$q$, v_levy),
      'INS_CHARGE_CATALOGUE_IMMUTABLE',
      '§2 a formula change on a charge already billed');

    -- The lawful route: a new version, end-dating the old one. Written as the
    -- owner, not as a company user: a statutory rate is maintained by migration
    -- and seed review, and the RLS insert policy would (correctly) refuse a
    -- tenant writing a row with tenant_id null.
    insert into ins_charge_catalogue
      (code, name, charge_class, formula, collector, recipient_name, recipient_kind,
       payable_role, effective_from, version, supersedes_id)
      values ('UG_INSURANCE_TRAINING_LEVY', 'Insurance Training Levy', 'statutory_levy',
              '{"kind":"rate","base":"gross_premium","rate_pct":0.75}'::jsonb,
              'insurer', 'Insurance Training College',
              'statutory_body', 'insurance_training_levy_payable', current_date, 2, v_levy);
    update ins_charge_catalogue set effective_to = current_date - 1 where id = v_levy;

    perform pg_temp.assert(
      (select version from ins_charge_catalogue where supersedes_id = v_levy) = 2,
      '§2 the new rate is a second version, linked backwards');
  end;

  -- -------------------------------------------------------------------
  -- §6 a NEW charge needs rows, not a migration
  -- -------------------------------------------------------------------
  -- This is the assertion the design exists for. Two charges of shapes that did
  -- not exist when the table was written -- a banded levy, and a levy on sum
  -- insured rather than premium -- are added by INSERT alone. No DDL, no new
  -- function, no changed constraint. If this section ever needs a migration to
  -- pass, the catalogue has regressed to a fixed list of three charges.
  declare
    v_line uuid;
    v_banded uuid;
    v_sum_insured uuid;
    v_rows record;
    v_total numeric;
  begin
    insert into ins_charge_catalogue
      (code, name, charge_class, formula, collector, recipient_name, recipient_kind,
       payable_role, verification_status, source_reference, verified_at, effective_from)
      values
      ('T_BANDED_LEVY', 'Banded test levy', 'statutory_levy',
       '{"kind":"banded","base":"gross_premium","bands":[{"up_to":1000000,"rate_pct":1.0},{"up_to":5000000,"rate_pct":0.5},{"up_to":null,"rate_pct":0.1}]}'::jsonb,
       'insurer', 'Test statutory body', 'statutory_body', 'test_levy_payable',
       'verified', 'test fixture, source_reference length must exceed ten', now(), current_date);
    select id into v_banded from ins_charge_catalogue where code = 'T_BANDED_LEVY';

    insert into ins_charge_catalogue
      (code, name, charge_class, formula, collector, recipient_name, recipient_kind,
       payable_role, verification_status, source_reference, verified_at, effective_from)
      values
      ('T_SUM_INSURED_LEVY', 'Sum-insured test levy', 'regulatory_contribution',
       '{"kind":"rate","base":"sum_insured","rate_pct":0.02,"min":100,"max":5000}'::jsonb,
       'insurer', 'Test regulator', 'regulator', 'test_reg_levy_payable',
       'verified', 'test fixture, source_reference length must exceed ten', now(), current_date);
    select id into v_sum_insured from ins_charge_catalogue where code = 'T_SUM_INSURED_LEVY';
    perform pg_temp.assert(v_banded is not null and v_sum_insured is not null,
      '§6 the two new charges exist as catalogue rows');

    -- A banded levy on 3,000,000 gross, marginal:
    --   first 1,000,000 at 1.0%  = 10,000
    --   next  2,000,000 at 0.5%  = 10,000
    --   nothing in the open band =      0   -> 20,000
    select amount into v_total
      from ins_price_charges_for(ta,
        '{"gross_premium":3000000,"sum_insured":450000000}'::jsonb, 'CHG', 'UGX', current_date)
     where code = 'T_BANDED_LEVY';
    perform pg_temp.assert(v_total = 20000,
      format('§6 the banded levy prices marginally to 20,000, got %s', v_total));

    -- The sum-insured levy: 0.02% of 450,000,000 = 90,000, capped at 5,000. The
    -- cap is what makes the assertion meaningful -- it proves min/max apply to
    -- every kind, not just to rates on premium.
    select amount into v_total
      from ins_price_charges_for(ta,
        '{"gross_premium":3000000,"sum_insured":450000000}'::jsonb, 'CHG', 'UGX', current_date)
     where code = 'T_SUM_INSURED_LEVY';
    perform pg_temp.assert(v_total = 5000,
      format('§6 the sum-insured levy is capped at 5,000, got %s', v_total));

    -- The same levy with a small sum insured hits the floor instead.
    select amount into v_total
      from ins_price_charges_for(ta,
        '{"gross_premium":3000000,"sum_insured":100000}'::jsonb, 'CHG', 'UGX', current_date)
     where code = 'T_SUM_INSURED_LEVY';
    perform pg_temp.assert(v_total = 100,
      format('§6 the floor of 100 applies to a tiny sum insured, got %s', v_total));

    -- And the refusal: a charge needing a quantity the caller did not pass must
    -- raise, not price at zero. Under-billing nobody notices is the failure mode
    -- a charge engine must not have.
    begin
      perform 1 from ins_price_charges_for(ta,
        '{"gross_premium":3000000}'::jsonb, 'CHG', 'UGX', current_date)
       where code = 'T_SUM_INSURED_LEVY';
      raise exception 'FAIL: §6 a sum-insured levy priced with no sum insured supplied';
    exception when others then
      if sqlerrm not like '%INS_CHARGE_PARAM_MISSING%' then
        raise exception 'FAIL: §6 expected INS_CHARGE_PARAM_MISSING, got: %', sqlerrm;
      end if;
    end;

    -- A new CLASS is a row in the registry, and it inherits the verification rule
    -- without any code naming it.
    perform pg_temp.assert(
      (select is_statutory from ins_charge_class where code = 'statutory_tax'),
      '§6 statutory membership is a registry property, not a name in a function');
  end;

  raise notice 'PASS: §1 pricing and verification, §2 immutability and versioning, §3 mandatory fields, §4 company scoping, §5 policy snapshots, §6 new charges need no DDL';
  raise notice 'ALL STATUTORY CHARGE CATALOGUE TESTS PASSED';
end $$;

rollback;
