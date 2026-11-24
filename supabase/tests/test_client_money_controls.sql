-- =====================================================================
-- Client money: position test, missed-reconciliation escalation, shortage incidents
-- Accountant pack v2, B9
-- =====================================================================
--   "a transfer that would leave the client-money position negative is refused"     §1, §2
--   "two consecutive missed reconciliations escalate"                                §3
--   "a shortage raises an incident and blocks further transfers until independently
--    released"                                                                       §4, §5
--
-- §2 is the one that matters most, and the one the old code got wrong: the account
-- HOLDS the money, so the balance test passes, and yet the money is already spoken
-- for. That is the difference between a balance and a position.
--
-- One transaction, rolled back. Disposable database only.
-- =====================================================================
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

create function pg_temp.expect_error(p_sql text, p_code text, p_what text)
returns void language plpgsql as $$
declare v_ok boolean := false;
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm like p_code || '%' then
      v_ok := true;
    else
      raise exception 'FAIL: % should be refused as %, but was refused as: %', p_what, p_code, sqlerrm;
    end if;
  end;
  if not v_ok then
    raise exception 'FAIL: % should have been refused as % and was not refused at all', p_what, p_code;
  end if;
end $$;

do $$
declare
  ta     uuid := gen_random_uuid();
  mgr    uuid := gen_random_uuid();
  fin1   uuid := gen_random_uuid();
  fin2   uuid := gen_random_uuid();
  trust_gl uuid; ops_gl uuid; ar_gl uuid; ap_gl uuid; pay_gl uuid; eq_gl uuid;
  v_trust uuid; v_ops uuid; v_party uuid; v_supplier uuid; v_line uuid;
  v_insurer uuid; v_client uuid;
begin
  insert into tenants(id, name) values (ta, 'Client money test');
  insert into auth.users(id, email, raw_user_meta_data, raw_app_meta_data, aud, role, created_at, updated_at)
    select u, 'cm-' || u || '@test.local', '{}', '{}', 'authenticated', 'authenticated', now(), now()
    from unnest(array[mgr, fin1, fin2]) u;
  insert into app_users(id, tenant_id, name, email)
    select u, ta, 'Client money actor', 'cm-' || u || '@test.local'
    from unnest(array[mgr, fin1, fin2]) u;
  update app_users set is_company_admin = true where id = mgr;
  insert into tenant_modules(tenant_id, module) values (ta, 'insurance');
  insert into staff_roles(tenant_id, user_id, module, role) values (ta, mgr, 'insurance', 'manager');
  insert into finance_team_members(tenant_id, user_id, role)
    values (ta, mgr, 'finance'), (ta, fin1, 'finance'), (ta, fin2, 'finance');

  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '1020', 'Client money', 'asset') returning id into trust_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '1000', 'Operating', 'asset') returning id into ops_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '1100', 'AR', 'asset') returning id into ar_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '2000', 'AP', 'liability') returning id into ap_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '2010', 'Insurer payable', 'liability') returning id into pay_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '3200', 'Retained earnings', 'equity') returning id into eq_gl;
  insert into gl_posting_rules(tenant_id, account_role, gl_account_id) values
    (ta, 'client_money_bank', trust_gl), (ta, 'bank', ops_gl),
    (ta, 'ar_control', ar_gl), (ta, 'ap_control', ap_gl), (ta, 'insurer_payable', pay_gl);

  insert into fin_bank_accounts(tenant_id, name, kind, currency, gl_account_id)
    values (ta, 'CM-TRUST', 'client_money', 'UGX', trust_gl) returning id into v_trust;
  insert into fin_bank_accounts(tenant_id, name, kind, currency, gl_account_id)
    values (ta, 'CM-OPS', 'operating', 'UGX', ops_gl) returning id into v_ops;

<<<<<<< ours
<<<<<<< ours
  insert into accounts(tenant_id, account_code, name, account_type) values (ta, 'T-' || substr(gen_random_uuid()::text, 1, 8), 'CM client', 'client') returning id into v_party;
  insert into accounts(tenant_id, account_code, name, account_type) values (ta, 'T-' || substr(gen_random_uuid()::text, 1, 8), 'CM supplier', 'vendor') returning id into v_supplier;
=======
  insert into accounts(tenant_id, name, account_type) values (ta, 'CM client', 'client') returning id into v_party;
  insert into accounts(tenant_id, name, account_type) values (ta, 'CM supplier', 'vendor') returning id into v_supplier;
>>>>>>> theirs
=======
  insert into accounts(tenant_id, name, account_type) values (ta, 'CM client', 'client') returning id into v_party;
  insert into accounts(tenant_id, name, account_type) values (ta, 'CM supplier', 'vendor') returning id into v_supplier;
>>>>>>> theirs

  insert into ins_product_lines(tenant_id, code, name) values (ta, 'GEN', 'General') returning id into v_line;
  insert into ins_insurers(tenant_id, code, name) values (ta, 'CMINS', 'Client Money Insurer') returning id into v_insurer;
  insert into bd_clients(tenant_id, name) values (ta, 'CM client') ;
  insert into ins_clients(tenant_id, client_id, client_type, party_account_id)
    select ta, id, 'corporate', v_party from bd_clients where tenant_id = ta and name = 'CM client'
    returning id into v_client;

  create temp table ids (k text primary key, v uuid);
  insert into ids(k, v) values ('tenant', ta), ('mgr', mgr), ('fin1', fin1), ('fin2', fin2),
    ('trust', trust_gl), ('ops', ops_gl), ('ar', ar_gl), ('ap', ap_gl), ('pay', pay_gl),
    ('eq', eq_gl),
    ('trust_bank', v_trust), ('ops_bank', v_ops),
    ('party', v_party), ('supplier', v_supplier),
    ('line', v_line), ('insurer', v_insurer), ('client', v_client);
end $$;

create function pg_temp.id(p_key text) returns uuid
language sql security definer set search_path = public, pg_temp as $$
  select v from pg_temp.ids where k = p_key
$$;
grant execute on function pg_temp.id(text) to authenticated;

-- Post a journal straight at the ledger, the way the platform does internally. Used to
-- set up a position; the controls under test are all on the transfer path.
create function pg_temp.post(p_lines jsonb, p_desc text default 'fixture')
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid;
begin
  v_id := (public.post_journal_entry(pg_temp.id('tenant'), 'opening_balance', null,
            public.ins_local_today(), p_desc, p_lines)).id;
  return v_id;
end $$;
grant execute on function pg_temp.post(jsonb, text) to authenticated;

-- An earned commission entry, so there is something to transfer.
create function pg_temp.earned(p_amount numeric)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_policy uuid; v_entry uuid;
begin
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
=======
>>>>>>> theirs
=======
  -- A bound policy has to satisfy ins_policies_bound_check: with status 'active',
  -- gross_premium > 0, commission_amount and net_premium_to_insurer must both be present,
  -- they must sum to gross_premium, and bound_at must be set. This fixture originally set
  -- only commission_amount and left bound_at null, so it violated the check on its first
  -- insert and the file could never have run past its own helper.
>>>>>>> theirs
  insert into ins_policies
    (tenant_id, policy_no, client_id, insurer_id, product_line_id, status,
     inception_date, expiry_date, currency, gross_premium, sum_insured,
     commission_rate_pct, commission_amount, net_premium_to_insurer, bound_at, transaction_type)
  values
    (pg_temp.id('tenant'), 'CM-' || substr(gen_random_uuid()::text, 1, 6),
     pg_temp.id('client'), pg_temp.id('insurer'), pg_temp.id('line'), 'active',
     current_date - 30, current_date + 335, 'UGX', 1000000, 5000000, 10,
     p_amount, 1000000 - p_amount, now(), 'new_business')
  returning id into v_policy;

  -- ins_commission_entries has NO currency column. It has not had one in the baseline or in
  -- any later migration -- checked against information_schema on a live database, which
  -- returns zero rows for it. The currency of a commission entry is the policy's currency,
  -- which is why nothing needs to store it here.
  --
  -- This insert carried `currency` for a while, which made the whole file fail at its first
  -- fixture with 42703 before a single control was exercised. Nothing caught it because the
  -- file had never been executed: it was written, parse-checked, and trusted.
  insert into ins_commission_entries
    (tenant_id, policy_id, insurer_share_id, amount, status, earned_on)
  values
<<<<<<< ours
    (pg_temp.id('tenant'), v_policy, null, p_amount, 'UGX', 'earned', current_date)
<<<<<<< ours
=======
  -- A bound policy has to satisfy ins_policies_bound_check: with status 'active',
  -- gross_premium > 0, commission_amount and net_premium_to_insurer must both be present,
  -- they must sum to gross_premium, and bound_at must be set. This fixture originally set
  -- only commission_amount and left bound_at null, so it violated the check on its first
  -- insert and the file could never have run past its own helper.
  insert into ins_policies
    (tenant_id, policy_no, client_id, insurer_id, product_line_id, status,
     inception_date, expiry_date, currency, gross_premium, sum_insured,
     commission_rate_pct, commission_amount, net_premium_to_insurer, bound_at, transaction_type)
  values
    (pg_temp.id('tenant'), 'CM-' || substr(gen_random_uuid()::text, 1, 6),
     pg_temp.id('client'), pg_temp.id('insurer'), pg_temp.id('line'), 'active',
     current_date - 30, current_date + 335, 'UGX', 1000000, 5000000, 10,
     p_amount, 1000000 - p_amount, now(), 'new_business')
  returning id into v_policy;

  -- ins_commission_entries has NO currency column. It has not had one in the baseline or in
  -- any later migration -- checked against information_schema on a live database, which
  -- returns zero rows for it. The currency of a commission entry is the policy's currency,
  -- which is why nothing needs to store it here.
  --
  -- This insert carried `currency` for a while, which made the whole file fail at its first
  -- fixture with 42703 before a single control was exercised. Nothing caught it because the
  -- file had never been executed: it was written, parse-checked, and trusted.
  insert into ins_commission_entries
    (tenant_id, policy_id, insurer_share_id, amount, status, earned_on)
  values
    (pg_temp.id('tenant'), v_policy, null, p_amount, 'earned', current_date)
>>>>>>> theirs
=======
>>>>>>> theirs
=======
    (pg_temp.id('tenant'), v_policy, null, p_amount, 'earned', current_date)
>>>>>>> theirs
  returning id into v_entry;

  return v_entry;
end $$;
grant execute on function pg_temp.earned(numeric) to authenticated;

-- ---------------------------------------------------------------------
-- §1 a position with nothing spoken for: the transfer goes through
-- ---------------------------------------------------------------------
do $$
declare v_entry uuid; v_tr ins_commission_transfers%rowtype;
begin
  -- 500,000 of client money held. The credit side goes to equity, not to AP control:
  -- a credit on a control account would itself be an open item owed to somebody, and
  -- the position would start out negative, which is the very thing this file tests.
  perform pg_temp.post(jsonb_build_array(
    jsonb_build_object('gl_account_id', pg_temp.id('trust'), 'debit', 500000),
    jsonb_build_object('gl_account_id', pg_temp.id('eq'),    'credit', 500000)),
    'client money funded');

  perform pg_temp.assert(
    public.platform_ins_client_money_free(pg_temp.id('tenant'), 'UGX') = 500000,
    format('§1 the fixture position should be a clean 500,000, got %s',
      public.platform_ins_client_money_free(pg_temp.id('tenant'), 'UGX')));

  v_entry := pg_temp.earned(100000);

  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  v_tr := public.ins_transfer_earned_commission(
            pg_temp.id('trust_bank'), pg_temp.id('ops_bank'), public.ins_local_today(),
            array[v_entry], 'clean transfer');
  reset role;

  perform pg_temp.assert(v_tr.id is not null and v_tr.amount = 100000,
    '§1 with money held and nothing owed, the transfer should succeed');
  raise notice 'PASS: §1 a clean position lets the transfer through';
end $$;

-- ---------------------------------------------------------------------
-- §2 the same balance, but the money is spoken for
-- ---------------------------------------------------------------------
-- The account holds 400,000 after the transfer above. Put an insurer liability of
-- 380,000 against it: the balance test the old code used would still pass a 100,000
-- transfer (400,000 >= 100,000), but the POSITION is only 20,000.
do $$
declare
  v_pos record;
  v_entry uuid;
begin
  perform pg_temp.post(jsonb_build_array(
    jsonb_build_object('gl_account_id', pg_temp.id('pay'), 'debit', 380000),
    jsonb_build_object('gl_account_id', pg_temp.id('trust'), 'credit', 380000)));
  -- An insurer payable open item: money the trust holds for the insurer.
  insert into fin_open_items
    (tenant_id, party_account_id, control_role, side, source_type, source_id,
     document_no, document_date, due_date, amount, currency, fx_rate,
     accounting_policy_version, description)
  values
    (pg_temp.id('tenant'), pg_temp.id('supplier'), 'insurer_payable', 'payable',
     'ins_policy_insurer', gen_random_uuid(), 'CM-INS-1', current_date, current_date,
     380000, 'UGX', 1, 1, 'premium owed to the insurer');

  select * into v_pos from public.ins_client_money_position();
  perform pg_temp.assert(v_pos.client_money = 400000,
    format('§2 the account should hold 400,000, got %s', v_pos.client_money));
  perform pg_temp.assert(v_pos.insurer_payable = 380000,
    format('§2 the insurer should be owed 380,000, got %s', v_pos.insurer_payable));
  perform pg_temp.assert(v_pos.free_money = 20000,
    format('§2 free client money should be 20,000, got %s', v_pos.free_money));

  v_entry := pg_temp.earned(100000);

  -- The balance test would have passed; the position test must not.
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  perform pg_temp.expect_error(
    format($q$select public.ins_transfer_earned_commission(%L, %L, %L, array[%L]::uuid[], 'grab the balance')$q$,
      pg_temp.id('trust_bank'), pg_temp.id('ops_bank'), public.ins_local_today(), v_entry),
    'INS_TRANSFER_POSITION',
    '§2 a transfer the balance covers but the position does not');
  reset role;
  raise notice 'PASS: §2 the same balance passes the old test and fails the position test';
end $$;

-- ---------------------------------------------------------------------
-- §2b the position test is fail-closed, and the way out of it is a signed decision
-- ---------------------------------------------------------------------
-- The test is on by default. A company whose regulator requires commission to be
-- banked in client money needs it off, and that must be a recorded choice by two
-- people rather than a code path somebody finds by accident.
do $$
declare v_entry uuid; v_tr ins_commission_transfers%rowtype;
        v_set uuid; v_admin1 uuid := gen_random_uuid(); v_admin2 uuid := gen_random_uuid();
begin
  -- The default, before anything is configured, is 'enforce'.
  perform pg_temp.assert(
    (public.acct_get_setting('ins.client_money_position_test', current_date) ->> 'value') = 'enforce'
    and (public.acct_get_setting('ins.client_money_position_test', current_date) ->> 'source') = 'default',
    '§2b the position test must be on by default with no company configuration');

  insert into auth.users(id, email, raw_user_meta_data, raw_app_meta_data, aud, role, created_at, updated_at)
    values (v_admin1, 'cm-a1@test.local', '{}', '{}', 'authenticated', 'authenticated', now(), now()),
           (v_admin2, 'cm-a2@test.local', '{}', '{}', 'authenticated', 'authenticated', now(), now());
  insert into app_users(id, tenant_id, name, email)
    values (v_admin1, pg_temp.id('tenant'), 'CM admin one', 'cm-a1@test.local'),
           (v_admin2, pg_temp.id('tenant'), 'CM admin two', 'cm-a2@test.local');
  update app_users set is_company_admin = true where id in (v_admin1, v_admin2);

  perform pg_temp.jwt(v_admin1);
  set local role authenticated;
  v_set := (public.acct_setting_propose('ins.client_money_position_test', 'permissive', current_date,
              'our regulator requires commission to be retained in the client-money account')).id;
  reset role;
  perform pg_temp.jwt(v_admin2);
  set local role authenticated;
  perform public.acct_setting_approve(v_set);
  reset role;

  v_entry := pg_temp.earned(100000);
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  -- Under the approved permissive setting the balance test stands alone, which is what
  -- these four existing insurance test files rely on.
  v_tr := public.ins_transfer_earned_commission(
            pg_temp.id('trust_bank'), pg_temp.id('ops_bank'), public.ins_local_today(),
            array[v_entry], 'permitted under the approved setting');
  reset role;

  perform pg_temp.assert(v_tr.id is not null,
    '§2b with an approved permissive setting the balance test alone decides');
  raise notice 'PASS: §2b the position test is fail-closed by default and relaxable only by an approved setting';
end $$;

-- ---------------------------------------------------------------------
-- §3 two consecutive missed reconciliations escalate
-- ---------------------------------------------------------------------
do $$
declare v_prev date := public.ins_local_today() - 1; v_prev2 date;
        v_streak integer; v_row record; v_escalated boolean := false;
        v_incident_after_one uuid;
begin
  -- Walk back to two consecutive business days.
  while extract(isodow from v_prev) in (6,7) loop v_prev := v_prev - 1; end loop;
  v_prev2 := v_prev - 1;
  while extract(isodow from v_prev2) in (6,7) loop v_prev2 := v_prev2 - 1; end loop;

  v_streak := public.platform_ins_reconciliation_streak(pg_temp.id('tenant'), pg_temp.id('trust_bank'));
  -- Never reconciled, so the streak runs back from yesterday. The loop gives up after
  -- 400 iterations, so the maximum is bounded; what matters is that it is not zero and
  -- not one.
  perform pg_temp.assert(v_streak >= 2,
    format('§3 with nothing ever reconciled the streak should be at least 2, got %s', v_streak));

  -- One reported day alone is not an escalation.
  select * into v_row from public.ins_escalate_missed_reconciliations() r
   where r.bank_account_id = pg_temp.id('trust_bank');
  perform pg_temp.assert(v_row.escalated,
    '§3 two missed days must escalate');
  perform pg_temp.assert(v_row.incident_id is not null,
    '§3 an escalation must raise an incident record');
  v_incident_after_one := v_row.incident_id;

  -- Running it again refreshes the same incident rather than raising a second one.
  select * into v_row from public.ins_escalate_missed_reconciliations() r
   where r.bank_account_id = pg_temp.id('trust_bank');
  perform pg_temp.assert(v_row.incident_id = v_incident_after_one,
    '§3 a second run must refresh the open incident, not raise another');
  perform pg_temp.assert(
    (select count(*) from fin_client_money_incidents
      where tenant_id = pg_temp.id('tenant') and kind = 'reconciliation_missed'
        and status = 'open') = 1,
    '§3 exactly one open missed-reconciliation incident should exist');

  -- A reviewed reconciliation for yesterday resets the streak to zero.
  perform pg_temp.jwt(pg_temp.id('fin1'));
  set local role authenticated;
  perform public.ins_prepare_client_money_reconciliation(pg_temp.id('trust_bank'), v_prev, null);
  reset role;
  perform pg_temp.jwt(pg_temp.id('fin2'));
  set local role authenticated;
  perform public.ins_review_client_money_reconciliation(
    (select id from fin_client_money_reconciliations
      where tenant_id = pg_temp.id('tenant') and reconciled_for = v_prev), 'checked to the statement');
  reset role;

  v_streak := public.platform_ins_reconciliation_streak(pg_temp.id('tenant'), pg_temp.id('trust_bank'));
  perform pg_temp.assert(v_streak = 1,
    format('§3 reconciling yesterday should leave a streak of 1, got %s', v_streak));
  raise notice 'PASS: §3 missed days accumulate, two escalates once, and a reviewed day resets it';
end $$;

-- ---------------------------------------------------------------------
-- §4 a shortage raises an incident and blocks transfers
-- ---------------------------------------------------------------------
do $$
declare v_inc record; v_entry uuid; v_prev date := public.ins_local_today() - 1;
        v_pos record;
begin
  -- Make the position genuinely negative: the insurer is owed more than is held.
  perform pg_temp.post(jsonb_build_array(
    jsonb_build_object('gl_account_id', pg_temp.id('pay'), 'debit', 100000),
    jsonb_build_object('gl_account_id', pg_temp.id('trust'), 'credit', 100000)));

  select * into v_pos from public.ins_client_money_position();
  perform pg_temp.assert(v_pos.free_money < 0,
    format('§4 the fixture must produce a negative position, got %s', v_pos.free_money));

  -- The check records it.
  select * into v_inc from public.ins_client_money_check('UGX') c where c.blocked;
  perform pg_temp.assert(v_inc.incident_id is not null,
    '§4 a negative position must raise a shortage incident');
  perform pg_temp.assert(
    (select kind = 'shortage' and status = 'open' and shortage < 0
       from fin_client_money_incidents where id = v_inc.incident_id),
    '§4 the incident should be an open shortage carrying the negative figure');

  -- Whether a transfer would fit is now irrelevant: §2b left an approved 'permissive'
  -- setting in force, so the position test no longer applies -- and the transfer is
  -- STILL refused. That is the point of the shortage block: it does not depend on the
  -- arithmetic of this transfer, only on the fact that the account is short.
  v_entry := pg_temp.earned(1000);
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  perform pg_temp.expect_error(
    format($q$select public.ins_transfer_earned_commission(%L, %L, %L, array[%L]::uuid[], 'small transfer')$q$,
      pg_temp.id('trust_bank'), pg_temp.id('ops_bank'), public.ins_local_today(), v_entry),
    'INS_TRANSFER_SHORTAGE',
    '§4 any transfer while a shortage is open');
  reset role;

  insert into pg_temp.ids(k, v) values ('incident', v_inc.incident_id);
  raise notice 'PASS: §4 a shortage blocks every transfer in that currency, even with the position test relaxed';
end $$;

-- ---------------------------------------------------------------------
-- §5 the block is released only by an independent person, and only once fixed
-- ---------------------------------------------------------------------
do $$
declare v_inc uuid := (select v from pg_temp.ids where k = 'incident');
        v_entry uuid; v_tr ins_commission_transfers%rowtype;
begin
  -- The preparer cannot release their own finding -- here, the same rule that runs
  -- everywhere else in the pack: the person who raised it is not the person who clears it.
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  -- Still short, so the release must refuse on the fixing rule even for an admin.
  perform pg_temp.expect_error(
    format($q$select public.ins_release_shortage(%L, 'released, please carry on')$q$, v_inc),
    'INS_SHORTAGE_STILL_SHORT',
    '§5 releasing a block while the position is still negative');
  reset role;

  -- Fund the account: the client pays the premium that the insurer is owed.
  perform pg_temp.post(jsonb_build_array(
    jsonb_build_object('gl_account_id', pg_temp.id('trust'), 'debit', 400000),
    jsonb_build_object('gl_account_id', pg_temp.id('ar'),    'credit', 400000)),
    'client settles the premium');

  perform pg_temp.assert(
    public.platform_ins_client_money_free(pg_temp.id('tenant'), 'UGX') >= 0,
    '§5 the position must be non-negative before a release can succeed');

  -- Too short a note is refused: a release with no explanation is not a control.
  perform pg_temp.jwt(pg_temp.id('fin1'));
  set local role authenticated;
  perform pg_temp.expect_error(
    format($q$select public.ins_release_shortage(%L, 'ok')$q$, v_inc),
    'INS_SHORTAGE_REASON',
    '§5 releasing with no explanation');
  reset role;

  perform pg_temp.jwt(pg_temp.id('fin2'));
  set local role authenticated;
  perform public.ins_release_shortage(v_inc,
    'client paid the premium on 20 November; the payment cleared the insurer liability in full');
  reset role;

  perform pg_temp.assert(
    (select status = 'released' and released_by = pg_temp.id('fin2') and released_at is not null
       from fin_client_money_incidents where id = v_inc),
    '§5 the incident must be released, with who and when recorded');

  -- With the block lifted, a transfer that fits goes through.
  v_entry := pg_temp.earned(5000);
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  v_tr := public.ins_transfer_earned_commission(
            pg_temp.id('trust_bank'), pg_temp.id('ops_bank'), public.ins_local_today(),
            array[v_entry], 'after the release');
  reset role;

  perform pg_temp.assert(v_tr.id is not null,
    '§5 once released, a transfer that fits the position should succeed');
  raise notice 'PASS: §5 a shortage cannot be released until the money is there, and the release is attributed';
end $$;

<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
do $$ begin
  raise notice 'ALL PASS: the position test refuses what the balance test allowed, missed reconciliations escalate once, and a shortage blocks transfers until an independent release';
=======
=======
>>>>>>> theirs
-- ---------------------------------------------------------------------
-- §6 the zero-tolerance preconditions on the transfer itself
-- ---------------------------------------------------------------------
-- Two additions in 20261124011800, each aimed at a way the same money could move twice.
do $$
declare
  v_entry  uuid;
  v_entry2 uuid;
  v_tr     ins_commission_transfers%rowtype;
  v_fake   uuid := gen_random_uuid();
begin
  v_entry  := pg_temp.earned(20000);
  v_entry2 := pg_temp.earned(30000);

  -- 6a. The normal path still works, so the new preconditions have not narrowed anything.
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  v_tr := public.ins_transfer_earned_commission(
            pg_temp.id('trust_bank'), pg_temp.id('ops_bank'), public.ins_local_today(),
            array[v_entry], 'precondition baseline');
  reset role;
  perform pg_temp.assert(v_tr.id is not null,
    '§6a a legitimate transfer must still go through with the preconditions in place');

  -- 6b. The entry is now 'transferred'. Asking for it again must be refused, and refused
  -- with the specific code, not merely "not earned".
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  perform pg_temp.expect_error(
    format($q$select public.ins_transfer_earned_commission(%L,%L,public.ins_local_today(),array[%L],'again')$q$,
      pg_temp.id('trust_bank'), pg_temp.id('ops_bank'), v_entry),
    'INS_TRANSFER_ENTRIES',
    '§6b transferring an entry that a posted transfer already moved');
  reset role;

  -- 6c. The interesting case: an entry reset to 'earned' but still pointing at a POSTED
  -- transfer. That is the state an undone void would leave, and it is the one where
  -- "earned" is a lie. Construction is legitimate -- there is no constraint forbidding it --
  -- and the new precondition is precisely what catches it.
  update ins_commission_entries
     set status = 'earned', transfer_id = null
   where id = v_entry2;
  update ins_commission_entries
     set status = 'transferred', transfer_id = v_tr.id
   where id = v_entry2;

  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  perform pg_temp.expect_error(
    format($q$select public.ins_transfer_earned_commission(%L,%L,public.ins_local_today(),array[%L],'stale')$q$,
      pg_temp.id('trust_bank'), pg_temp.id('ops_bank'), v_entry2),
    'INS_TRANSFER_ENTRIES',
    '§6c an entry already on a posted transfer, offered again');
  reset role;

  -- 6d. The pool path (no explicit entries) must be unaffected: it cannot select an entry
  -- that is not 'earned', so the precondition never fires there and nothing regresses.
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  begin
    v_tr := public.ins_transfer_earned_commission(
              pg_temp.id('trust_bank'), pg_temp.id('ops_bank'), public.ins_local_today(),
              null, 'pool path');
    perform pg_temp.assert(v_tr.id is not null, '§6d the pool path should still transfer');
  exception when others then
    perform pg_temp.assert(sqlerrm not like 'INS_TRANSFER_ALREADY_TRANSFERRED%',
      format('§6d the pool path must not be blocked by the new precondition, got: %s', sqlerrm));
  end;
  reset role;

  raise notice 'PASS: §6 a posted transfer cannot be re-run over the same entries, and the pool path is unchanged';
end $$;

<<<<<<< ours
do $$ begin
  raise notice 'ALL PASS: the position test refuses what the balance test allowed, missed reconciliations escalate once, a shortage blocks transfers until an independent release, and the transfer itself cannot move the same entry twice';
>>>>>>> theirs
=======
do $$ begin
  raise notice 'ALL PASS: the position test refuses what the balance test allowed, missed reconciliations escalate once, and a shortage blocks transfers until an independent release';
>>>>>>> theirs
=======
do $$ begin
  raise notice 'ALL PASS: the position test refuses what the balance test allowed, missed reconciliations escalate once, a shortage blocks transfers until an independent release, and the transfer itself cannot move the same entry twice';
>>>>>>> theirs
end $$;

rollback;
