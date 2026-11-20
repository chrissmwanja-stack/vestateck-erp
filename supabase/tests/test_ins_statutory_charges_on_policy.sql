-- =====================================================================
-- Statutory charges are priced on the policy, and bind cannot skip them
-- =====================================================================
-- Before 20261120005000 the catalogue was a library: the client supplied charge
-- lines, ins_price_charges existed, and nobody called it. A company could bind a
-- policy carrying no training levy and nothing noticed.
--
-- This file pins the integration:
--
--   §1 pricing writes catalogue-sourced lines and records what it priced
--   §2 acknowledging is a separate, real step -- pricing does not authorise itself
--   §3 bind refuses when the catalogue has moved since the acknowledgement
--   §4 bind refuses outright when nothing was acknowledged but the catalogue prices
--   §5 an acknowledged and unchanged set binds, and the policy records the version
--   §6 manual charges survive re-pricing; the mechanism only owns its own rows
--   §7 the commission snapshot the bind already took is still intact
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

create temp table ctx (k text primary key, v uuid);
create temp table pol (k text primary key, v uuid);

do $$
declare
  ta uuid := gen_random_uuid();
  admin1 uuid := gen_random_uuid();
  admin2 uuid := gen_random_uuid();
  mgr uuid := gen_random_uuid();
  v_line uuid; v_insurer uuid; v_client uuid; v_policy uuid;
  v_levy_gl uuid; v_setting uuid;
begin
  insert into tenants(id, name) values (ta, 'Statutory charges on policy');
  insert into auth.users(id, email, raw_user_meta_data, raw_app_meta_data, aud, role, created_at, updated_at)
    select u, 'spc-' || u || '@test.local', '{}', '{}', 'authenticated', 'authenticated', now(), now()
    from unnest(array[admin1, admin2, mgr]) u;
  insert into app_users(id, tenant_id, name, email)
    select u, ta, 'Statutory actor', 'spc-' || u || '@test.local'
    from unnest(array[admin1, admin2, mgr]) u;
  update app_users set is_company_admin = true where id in (admin1, admin2);

  insert into tenant_modules(tenant_id, module) values (ta, 'insurance');
  insert into staff_roles(tenant_id, user_id, module, role) values (ta, mgr, 'insurance', 'manager');

  -- The chart the levy needs. Without this the resolver refuses, by design.
  insert into gl_accounts(tenant_id, account_code, name, account_type, is_control_account)
    values (ta, '2060', 'Insurance Training Levy Payable', 'liability', true)
    returning id into v_levy_gl;
  insert into gl_posting_rules(tenant_id, account_role, gl_account_id)
    values (ta, 'insurance_training_levy_payable', v_levy_gl);

  -- The rest of the chart the bind's journals need. Without it the bind fails on
  -- INS_POSTING_RULE_MISSING before reaching anything this file is about.
  insert into gl_accounts(tenant_id, account_code, name, account_type) values
    (ta, '1100', 'AR', 'asset'),
    (ta, '2010', 'Insurer payable', 'liability'),
    (ta, '2020', 'Unearned commission', 'liability'),
    (ta, '4000', 'Commission income', 'revenue'),
    (ta, '1110', 'Commission receivable', 'asset');
  insert into gl_posting_rules(tenant_id, account_role, gl_account_id)
  select ta, r.role, a.id
    from (values ('ar_control', '1100'), ('insurer_payable', '2010'),
                 ('unearned_commission', '2020'), ('commission_income', '4000'),
                 ('commission_receivable', '1110')) as r(role, code)
    join gl_accounts a on a.tenant_id = ta and a.account_code = r.code;

  -- Enforcement is opt-in per company (20261120235901), because requiring it
  -- globally changes the premium of every existing policy. This file is about the
  -- enforcing mode, so the company chooses it -- through the real workflow, not by
  -- an insert, so the approval path is exercised too.
  -- Proposing an accounting setting is a company-admin action, so switch identity
  -- for it and come back to the manager afterwards.
  perform pg_temp.jwt(admin1);
  set local role authenticated;
  v_setting := (public.acct_setting_propose('ins.statutory_charge_enforcement',
    'required', current_date, 'test fixture: this company collects a statutory levy')).id;
  reset role;
  perform pg_temp.jwt(admin2);
  set local role authenticated;
  perform public.acct_setting_approve(v_setting);
  reset role;
  perform pg_temp.jwt(admin1);
  set local role authenticated;

  -- A commission recognition mode, so bind does not fail on an unrelated rule.
  perform pg_temp.jwt(admin1);
  set local role authenticated;
  v_setting := (public.acct_setting_propose('ins.commission_recognition',
    'on_insurer_settlement', current_date, 'test fixture: the conservative default')).id;
  reset role;
  perform pg_temp.jwt(admin2);
  set local role authenticated;
  perform public.acct_setting_approve(v_setting);
  reset role;

  perform pg_temp.jwt(mgr);
  set local role authenticated;
  insert into ins_product_lines(tenant_id, code, name) values (ta, 'CHG', 'Charges') returning id into v_line;
  insert into ins_insurers(tenant_id, code, name) values (ta, 'SPCINS', 'Statutory Insurer') returning id into v_insurer;
  v_client := (ins_register_client('Statutory client', 'corporate', null, null, null, 'low')).id;
  v_policy := (ins_create_policy(v_client, v_insurer, v_line, current_date, current_date + 365,
                5000000, 'UGX', 100000, 10, null, null, 'Statutory charge fixture', null)).id;
  -- Shares are select-only under RLS; they are written by the configuration RPC,
  -- not by a caller. Configuring them through it is also what the app does.
  perform public.ins_set_policy_financial_configuration(
    v_policy,
    jsonb_build_array(jsonb_build_object(
      'insurer_id', v_insurer, 'is_lead', true, 'share_pct', 100,
      'commission_rate_pct', 10, 'reviewed', true)),
    '[]'::jsonb);
  reset role;

  insert into ctx(k, v) values
    ('tenant', ta), ('mgr', mgr), ('admin1', admin1), ('admin2', admin2),
    ('levy_gl', v_levy_gl), ('insurer', v_insurer);
  insert into pol(k, v) values ('p', v_policy);
end $$;

create function pg_temp.id(p_key text) returns uuid
language sql security definer set search_path = public, pg_temp as $$
  select v from ctx where k = p_key
$$;
grant execute on function pg_temp.id(text) to authenticated;

-- The approval gate is a separate trigger (INS_NOT_APPROVED) and is not what this
-- file is about. Moving straight to 'approved' lets the probes below enter at the
-- transition the statutory guard actually watches.
create function pg_temp.approve_directly() returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update public.ins_policies set status = 'approved' where id = (select pol.v from pol where pol.k = 'p');
end $$;

-- A second draft policy, configured but never priced, for the "never acknowledged"
-- case. Written as the owner: this is fixture setup, not a behaviour under test.
create function pg_temp.new_never_priced_policy(p_prefix text default 'POL-NEVER-PRICED') returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_new uuid;
  p ins_policies%rowtype;
begin
  select * into p from public.ins_policies where id = (select pol.v from pol where pol.k = 'p');
  insert into public.ins_policies
    (tenant_id, policy_no, client_id, insurer_id, product_line_id, inception_date, expiry_date,
     sum_insured, gross_premium, currency, commission_rate_pct, commission_amount,
     net_premium_to_insurer, status)
  values (p.tenant_id, p_prefix, p.client_id, p.insurer_id, p.product_line_id,
          p.inception_date, p.expiry_date, p.sum_insured, p.gross_premium, p.currency,
          10, 10000, 90000, 'draft')
  returning id into v_new;

  insert into public.ins_policy_insurer_shares
    (tenant_id, policy_id, insurer_id, is_lead, share_pct, commission_rate_pct, reviewed)
  values (p.tenant_id, v_new, p.insurer_id, true, 100, 10, true);

  return v_new;
end $$;
grant execute on function pg_temp.new_never_priced_policy(text) to authenticated;

-- Approval by a second person holding an insurance manager role. A policy cannot be
-- approved by the person who submitted it, and the fixture's admin2 has no insurance
-- role, so this creates one -- the same shape the commission-recognition test uses.
create function pg_temp.decide_approved(p_policy uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_tenant uuid;
  v_appr uuid := gen_random_uuid();
  v_claims text := current_setting('request.jwt.claims', true);
begin
  select tenant_id into v_tenant from public.ins_policies where id = p_policy;
  insert into auth.users(id, email, raw_user_meta_data, raw_app_meta_data, aud, role, created_at, updated_at)
    values (v_appr, 'appr-' || v_appr || '@test.local', '{}', '{}', 'authenticated', 'authenticated', now(), now())
    on conflict (id) do nothing;
  insert into public.app_users(id, tenant_id, name, email)
    values (v_appr, v_tenant, 'Second insurance approver', 'appr-' || v_appr || '@test.local')
    on conflict (id) do nothing;
  insert into public.staff_roles(tenant_id, user_id, module, role)
    values (v_tenant, v_appr, 'insurance', 'manager')
    on conflict do nothing;

  -- Identity is switched by the caller; `set local role` is refused inside a
  -- SECURITY DEFINER function. Return the approver so the caller can assume them.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_appr, 'role', 'authenticated')::text, true);
end $$;
grant execute on function pg_temp.decide_approved(uuid) to authenticated;

create function pg_temp.id2(p_key text) returns uuid
language sql security definer set search_path = public, pg_temp as $$
  select pol.v from pol where pol.k = p_key
$$;
grant execute on function pg_temp.id2(text) to authenticated;

create function pg_temp.policy() returns uuid
language sql security definer set search_path = public, pg_temp as $$
  select pol.v from pol where pol.k = 'p'
$$;
grant execute on function pg_temp.policy() to authenticated;

-- ---------------------------------------------------------------------------
-- §1 pricing writes lines and records what it priced
-- ---------------------------------------------------------------------------
do $$
declare v jsonb;
begin
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  v := public.ins_apply_statutory_charges(pg_temp.policy());
  reset role;

  perform pg_temp.assert((v ->> 'total')::numeric = 500,
    format('§1 0.5%% of a 100,000 premium is 500, got %s', v ->> 'total'));
  perform pg_temp.assert((v ->> 'acknowledged')::boolean = false,
    '§1 pricing alone does not acknowledge');
  perform pg_temp.assert(jsonb_array_length(v -> 'lines') = 1,
    '§1 one statutory line was priced');
  perform pg_temp.assert(
    (select count(*) from ins_policy_charges where policy_id = pg_temp.policy() and catalogue_id is not null) = 1,
    '§1 the line is written to the policy');
  perform pg_temp.assert(
    (select amount from ins_policy_charges where policy_id = pg_temp.policy() and catalogue_id is not null) = 500,
    '§1 for 500');
  -- A levy is not the brokerage's income, and it carries no VAT of its own.
  perform pg_temp.assert(
    (select vat_mode = 'not_calculated' and income_gl_account_id is null
       from ins_policy_charges where policy_id = pg_temp.policy() and catalogue_id is not null),
    '§1 a statutory levy is not treated as commission income and carries no VAT');
  perform pg_temp.assert(
    (select payable_role from ins_policy_charges where policy_id = pg_temp.policy() and catalogue_id is not null)
      = 'insurance_training_levy_payable',
    '§1 the line says which role it is payable to');
  perform pg_temp.assert(
    (select statutory_charges_ack from ins_policies where id = pg_temp.policy()) is null,
    '§1 and the policy carries no acknowledgement yet');
  raise notice 'PASS: §1 pricing writes catalogue-sourced lines';
end $$;

-- ---------------------------------------------------------------------------
-- §2 acknowledging is a separate step
-- ---------------------------------------------------------------------------
do $$
declare v_ack jsonb;
begin
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  v_ack := public.ins_acknowledge_statutory_charges(pg_temp.policy());
  reset role;

  perform pg_temp.assert((v_ack ->> 'total')::numeric = 500,
    '§2 the acknowledgement records the total');
  perform pg_temp.assert((v_ack ->> 'acknowledged_by') is not null,
    '§2 and who acknowledged it');
  perform pg_temp.assert(
    (select statutory_charges_ack is not null from ins_policies where id = pg_temp.policy()),
    '§2 the policy stores it');
  perform pg_temp.assert(
    (select reviewed from ins_policy_charges where policy_id = pg_temp.policy() and catalogue_id is not null),
    '§2 acknowledging marks the lines reviewed, which is what bind checks');
  raise notice 'PASS: §2 acknowledgement is its own event';
end $$;

-- ---------------------------------------------------------------------------
-- §6 manual charges survive re-pricing
-- ---------------------------------------------------------------------------
-- The mechanism owns only the rows it wrote. A negotiated fee added by the manager
-- must not be deleted by re-running statutory pricing -- that would silently drop
-- revenue, and it would do it every time someone re-priced.
do $$
declare v_manual uuid; v_before integer;
begin
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  reset role;
  -- As the owner: ins_policy_charges has a SELECT policy only, so a manager cannot
  -- insert a charge directly -- manual charges arrive through the configuration RPC,
  -- which is what the delete-and-replace in §6 must not touch either.
  insert into ins_policy_charges(tenant_id, policy_id, kind, description, amount,
                                 recipient_mode, vat_mode, reviewed, fee_class)
    values (pg_temp.id('tenant'), pg_temp.policy(), 'broker_fee', 'Negotiated arrangement fee',
            25000, 'broker', 'not_calculated', true, 'insurance_brokerage')
    returning id into v_manual;

  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  perform public.ins_apply_statutory_charges(pg_temp.policy());
  reset role;

  perform pg_temp.assert(
    exists (select 1 from ins_policy_charges where id = v_manual),
    '§6 a manual charge survives re-pricing');
  select count(*) into v_before from ins_policy_charges
   where policy_id = pg_temp.policy() and catalogue_id is not null;
  perform pg_temp.assert(v_before = 1,
    format('§6 and re-pricing did not duplicate the statutory line (got %s)', v_before));
  -- Re-pricing invalidates the acknowledgement, because the figures are new.
  perform pg_temp.assert(
    (select statutory_charges_ack from ins_policies where id = pg_temp.policy()) is null,
    '§6 re-pricing clears the acknowledgement rather than leaving a stale one');
  raise notice 'PASS: §6 manual charges survive; the mechanism owns only its own rows';
end $$;

-- ---------------------------------------------------------------------------
-- §3 bind refuses a stale acknowledgement
-- ---------------------------------------------------------------------------
-- A verified rate changes between drafting and binding. The acknowledgement said
-- 500; the catalogue now says something else. Binding under the old figure would
-- under-collect a statutory levy, which is the failure this whole mechanism exists
-- to prevent.
do $$
begin
  -- Acknowledgement is a draft-time act, and this section runs before §4 moves the
  -- first policy to 'approved', so it is still a draft here. It is the policy priced
  -- in §1 and re-priced in §6, and (as §6 established) re-pricing cleared its
  -- acknowledgement, so acknowledging now is the first acknowledgement since.
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  perform public.ins_acknowledge_statutory_charges(pg_temp.policy());
  reset role;
  perform pg_temp.approve_directly();

  -- The regulator raises the levy. Written as the owner: statutory rows are
  -- maintained by migration, and a billed rate is immutable, so this is a new
  -- version end-dating the old one -- exactly the lawful route.
  insert into ins_charge_catalogue
    (code, name, charge_class, formula, collector, recipient_name, recipient_kind,
     payable_role, effective_from, version, supersedes_id,
     verification_status, source_reference, verified_at)
  select 'UG_INSURANCE_TRAINING_LEVY', 'Insurance Training Levy', 'statutory_levy',
         '{"kind":"rate","base":"gross_premium","rate_pct":1.0}'::jsonb,
         'insurer', 'Insurance Training College', 'statutory_body',
         'insurance_training_levy_payable', current_date, 2, id,
         'verified', 'test fixture: amended rate, source reference long enough', now()
    from ins_charge_catalogue
   where code = 'UG_INSURANCE_TRAINING_LEVY' and version = 1 and effective_to is null;
  update ins_charge_catalogue set effective_to = current_date - 1
   where code = 'UG_INSURANCE_TRAINING_LEVY' and version = 1;

  perform pg_temp.expect_error(
    format($q$update ins_policies set status = 'active', bound_at = now(),
                 commission_amount = 10000, net_premium_to_insurer = 90000
             where id = %L$q$, pg_temp.policy()),
    'INS_CHARGE_ACK_STALE',
    '§3 the approved -> active transition under an acknowledgement the catalogue has outgrown');
  raise notice 'PASS: §3 bind refuses a stale acknowledgement';
end $$;

-- ---------------------------------------------------------------------------
-- §4 bind refuses when nothing was acknowledged
-- ---------------------------------------------------------------------------
do $$
begin
  -- A SECOND policy that never ran pricing. The first one is approved and locked
  -- and carries a stale acknowledgement; reusing it would mean clearing a locked
  -- row, and "a manager never priced this policy" is the state worth testing rather
  -- than manufacturing it by hand.
  insert into pol(k, v) values ('p2', pg_temp.new_never_priced_policy());

  update ins_policies set status = 'approved' where id = pg_temp.id2('p2');
  -- Activation alone trips ins_policies_bound_check (bound_at and the commission
  -- split must be present). Supplying them keeps the CHECK out of the way so the
  -- statutory guard answers, which is the rule under test.
  perform pg_temp.expect_error(
    format($q$update ins_policies set status = 'active', bound_at = now(),
                 commission_amount = 10000, net_premium_to_insurer = 90000
             where id = %L$q$, pg_temp.id2('p2')),
    'INS_CHARGE_NOT_ACKNOWLEDGED',
    '§4 the approved -> active transition with charges priced but not acknowledged');
  raise notice 'PASS: §4 the guard refuses an unacknowledged policy';
end $$;

-- ---------------------------------------------------------------------------
-- §5 re-price, acknowledge, and it binds -- with the version on the policy
-- ---------------------------------------------------------------------------
do $$
declare v_ack jsonb; v_snapshot jsonb;
begin
  -- A third policy, still a draft: pricing is a draft-only act and both earlier
  -- policies are approved and locked by this point. This one walks the whole flow
  -- in the order the application takes it.
  insert into pol(k, v) values ('p3', pg_temp.new_never_priced_policy('POL-HAPPY-PATH'));
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  v_ack := public.ins_apply_statutory_charges(pg_temp.id2('p3'));
  perform pg_temp.assert((v_ack ->> 'total')::numeric = 1000,
    format('§5 the new rate prices 1,000, got %s', v_ack ->> 'total'));
  perform public.ins_acknowledge_statutory_charges(pg_temp.id2('p3'));
  reset role;

  -- Submit and approve for real, then bind: the point of this section is that an
  -- acknowledged, unchanged set clears the whole gate chain, not just the guard.
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  perform public.ins_submit_policy_for_approval(pg_temp.id2('p3'));
  reset role;

  perform pg_temp.decide_approved(pg_temp.id2('p3'));
  set local role authenticated;
  perform public.ins_decide_policy(pg_temp.id2('p3'), 'approved');
  reset role;

  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  perform public.ins_bind_policy(pg_temp.id2('p3'));
  reset role;

  select statutory_charges_ack, accounting_config_snapshot into v_ack, v_snapshot
    from ins_policies where id = pg_temp.id2('p3');

  perform pg_temp.assert((select status from ins_policies where id = pg_temp.id2('p3')) = 'active',
    '§5 the policy bound');
  perform pg_temp.assert((v_ack ->> 'total')::numeric = 1000,
    '§5 the acknowledgement is on the bound policy');
  perform pg_temp.assert(
    (v_snapshot -> 'statutory_charges' ->> 'total')::numeric = 1000,
    format('§5 and frozen into the bind snapshot (snapshot keys: %s; statutory: %s)',
           (select string_agg(k, ',') from jsonb_object_keys(v_snapshot) k),
           coalesce((v_snapshot -> 'statutory_charges')::text, 'NULL')));

  -- §7 the commission snapshot the bind already took is untouched by the wrapper.
  perform pg_temp.assert(
    v_snapshot ? 'commission_recognition_effective',
    '§7 the commission recognition resolution is still in the snapshot');
  perform pg_temp.assert(
    (v_snapshot ->> 'commission_recognition_effective') = 'on_insurer_settlement',
    '§7 and still carries the mode the bind resolved');
  raise notice 'PASS: §5 an acknowledged policy binds and records its statutory version';
  raise notice 'PASS: §7 the commission snapshot survived the wrapper';
end $$;

rollback;
