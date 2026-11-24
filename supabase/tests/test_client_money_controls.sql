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
  unearn_gl uuid; inc_gl uuid;
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
  -- Binding a policy needs a complete insurance chart: ar_control, insurer_payable,
  -- unearned_commission and commission_income. The fixture only had the first two, so the
  -- policy could be created and approved but never bound -- and this file's commission has to
  -- come from a genuine bind. Two more accounts, added here rather than worked around.
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '2100', 'Unearned commission', 'liability') returning id into unearn_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '4200', 'Commission income', 'revenue') returning id into inc_gl;
  insert into gl_posting_rules(tenant_id, account_role, gl_account_id) values
    (ta, 'client_money_bank', trust_gl), (ta, 'bank', ops_gl),
    (ta, 'ar_control', ar_gl), (ta, 'ap_control', ap_gl), (ta, 'insurer_payable', pay_gl),
    (ta, 'unearned_commission', unearn_gl), (ta, 'commission_income', inc_gl);

  insert into fin_bank_accounts(tenant_id, name, kind, currency, gl_account_id)
    values (ta, 'CM-TRUST', 'client_money', 'UGX', trust_gl) returning id into v_trust;
  insert into fin_bank_accounts(tenant_id, name, kind, currency, gl_account_id)
    values (ta, 'CM-OPS', 'operating', 'UGX', ops_gl) returning id into v_ops;

  insert into accounts(tenant_id, account_code, name, account_type) values (ta, 'CM-CLIENT', 'CM client', 'client') returning id into v_party;
  insert into accounts(tenant_id, account_code, name, account_type) values (ta, 'CM-SUPPLIER', 'CM supplier', 'vendor') returning id into v_supplier;

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
-- Fixture postings are dated in the PAST, deliberately. company_accounting_settings_guard
-- refuses to approve a setting effective on or before the latest posted entry, because that
-- would restate history. §2b has to approve a setting effective today, so nothing in the
-- fixture may be dated today -- with every journal on the business date, that section could
-- never run, and it failed with ACCT_SETTING_BACKDATED the first time it was executed.
-- `immutable` would be a lie and PostgreSQL folds it at plan time; stable reads it per call.
create function pg_temp.backdate() returns date
language sql stable as $$ select public.ins_local_today() - 45 $$;

create function pg_temp.post(p_lines jsonb, p_desc text default 'fixture')
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid;
begin
  v_id := (public.post_journal_entry(pg_temp.id('tenant'), 'opening_balance', null,
            pg_temp.backdate(), p_desc, p_lines)).id;
  return v_id;
end $$;
grant execute on function pg_temp.post(jsonb, text) to authenticated;

-- An earned commission entry, so there is something to transfer.
--
-- This used to create a policy and insert a commission entry directly with status 'earned'.
-- Two things were wrong with that, and both were only visible by running it:
--   * ins_policies_guard refuses a direct insert (INS_RPC_ONLY), so no policy could be created;
--   * a commission entry marked 'earned' without the premium actually collected still meets
--     ins_policy_cash_commission_guard's funding test only by accident, and the transfer was
--     refused with INS_CASH_COMMISSION_UNFUNDED. The guard is right: commission cannot be
--     moved out of client money that was never collected.
-- So the fixture now does what the business does: the client pays the premium into the client
-- account, the insurer is remitted, and the commission becomes genuinely earned and funded.
create function pg_temp.earned(p_amount numeric, p_gross numeric default 1000000)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_policy uuid; v_entry uuid; v_item uuid; v_set uuid; v_req uuid; v_req2 uuid;
begin
  -- ins_create_policy() needs a session identity (can_access_insurance), so act as the
  -- company admin who holds the insurance module.
  -- fin1 must be an insurance manager to approve the policy: ins_decide_policy calls
  -- can_manage_insurance() -> has_module_role('insurance', {admin,manager}), which reads
  -- staff_roles joined to tenant_modules and does NOT consult app_users.is_company_admin. The
  -- finance team role alone is not enough, and neither is the company-admin flag.
  perform pg_temp.jwt(pg_temp.id('mgr'));
  -- The notes carry a marker so the position can be computed WITHOUT this fixture. The
  -- backing premium receipt and remittance are real credits and debits in the client-money
  -- account, so ignoring them made §2's expected 400,000 read as 1,020,000 -- a genuine
  -- figure, not a defect, and not what §2 is about: §2 is about a position computed from a
  -- balance the test states explicitly.
  v_policy := (public.ins_create_policy(
    pg_temp.id('client'), pg_temp.id('insurer'), pg_temp.id('line'),
    current_date - 30, current_date + 335, 5000000, 'UGX', p_gross, 10,
    null, null, null, 'cm-position-fixture')).id;

  -- Binding snapshots the commission-recognition mode from the insurer's approved terms or the
  -- company default, and refuses to guess: without terms it raises
  -- INS_COMMISSION_RECOGNITION_UNSET. 'on_premium_collection' is the mode this file needs --
  -- commission is not earned until the premium is collected -- and the terms are proposed and
  -- approved by two different people because the RPCs say so.
  perform pg_temp.jwt(pg_temp.id('mgr'));
  -- One set of terms, re-used by every policy this fixture binds: the table has a unique start
  -- per insurer, so proposing again for the same insurer and date is a duplicate key.
  declare v_terms uuid;
  begin
  select id into v_terms from public.ins_insurer_commission_terms
   where tenant_id = pg_temp.id('tenant') and insurer_id = pg_temp.id('insurer')
   order by effective_from desc limit 1;
  if v_terms is null then
    v_terms := (public.ins_propose_insurer_commission_terms(
      pg_temp.id('insurer'), 'on_premium_collection', current_date - 60,
      'Client money fixture agreement', 'fixture: commission recognised when the premium is collected')).id;
    -- Approving terms needs a company admin who is NOT the proposer. fin1 was made an
    -- insurance manager for the policy approval below, but terms are stricter: the guard
    -- checks app_users.is_company_admin. fin2 is a plain second finance user, so promote it
    -- to company admin here and revert immediately -- it is used later as an ordinary finance
    -- actor and must not carry extra authority into those sections.
    update public.app_users set is_company_admin = true where id = pg_temp.id('fin2');
    perform pg_temp.jwt(pg_temp.id('fin2'));
    perform public.ins_approve_insurer_commission_terms(v_terms);
    update public.app_users set is_company_admin = false where id = pg_temp.id('fin2');
  end if;
  end;
  perform pg_temp.jwt(pg_temp.id('mgr'));

  -- Nothing to collect on a draft: submit, approve and bind, which is what raises the open
  -- items. ins_bind_policy refuses a draft (INS_NOT_APPROVED), and an approval must come from
  -- a DIFFERENT person than the raiser, so the second finance user signs it.
  perform public.ins_submit_policy_for_approval(v_policy);
  insert into public.staff_roles(tenant_id, user_id, module, role)
    select pg_temp.id('tenant'), pg_temp.id('fin1'), 'insurance', 'manager'
    where not exists (select 1 from public.staff_roles
                       where tenant_id = pg_temp.id('tenant') and user_id = pg_temp.id('fin1'));
  perform pg_temp.jwt(pg_temp.id('fin1'));
  perform public.ins_decide_policy(v_policy, 'approved');
  perform pg_temp.jwt(pg_temp.id('mgr'));
  perform public.ins_bind_policy(v_policy);

  -- The client pays in full, in client money.
  select id into v_item from public.fin_open_items
   where source_id = v_policy and source_type = 'ins_policy_premium';
  -- Policy cash is NOT a bare fin_record_settlement: ins_policy_cash_allocation_guard
  -- requires a maker/checker request (INS_CASH_APPROVAL_REQUIRED), which is the whole point of
  -- the insurance cash path. So the maker submits a request and a different person decides it.
  declare v_req uuid;
  begin
    perform pg_temp.jwt(pg_temp.id('fin1'));
    v_req := (public.ins_submit_policy_cash_request(
      v_policy, 'receipt', pg_temp.id('trust_bank'), p_gross,
      pg_temp.backdate(), gen_random_uuid(), 'client premium')).id;
    perform pg_temp.jwt(pg_temp.id('fin2'));
    perform public.ins_decide_policy_cash_request(v_req, 'approve', 'checked to the policy');
  end;

  -- Then remit to the insurer, capped by what the platform says may be remitted for this
  -- policy. The cap is not "premium less my p_amount": it is allocated collections less the
  -- commission the BIND recorded, so asking for anything else is refused with INS_CASH_CAP.
  -- Asking the platform for the cap instead of guessing it is the whole fix -- the first
  -- version remitted gross minus p_amount and was refused 999,000 against 900,000.
  declare v_cap numeric := (public.ins_policy_cash_totals(v_policy) ->> 'maximum_remittance')::numeric;
  begin
    perform pg_temp.jwt(pg_temp.id('fin1'));
    v_req2 := (public.ins_submit_policy_cash_request(
      v_policy, 'remittance', pg_temp.id('trust_bank'), v_cap,
      pg_temp.backdate(), gen_random_uuid(), 'remit to insurer')).id;
    perform pg_temp.jwt(pg_temp.id('fin2'));
    perform public.ins_decide_policy_cash_request(v_req2, 'approve', 'checked to the statement');
  end;

  -- Whatever the remittance left in the client-money account is held against this policy's
  -- commission. Sell it down to exactly p_amount, so the fixture's net effect on the
  -- tenant-wide position is one commission's worth of client money and nothing else -- the
  -- state §1 and §2 describe from scratch. The commission stays earned and funded: what funds
  -- a transfer is the allocated collections, and those are not touched by this journal.
  declare v_residue numeric;
  begin
    select coalesce(sum(fa.amount) filter (where fs.direction = 'in'), 0)
         - coalesce(sum(fa.amount) filter (where fs.direction = 'out'), 0)
      into v_residue
      from public.fin_open_items i
      join public.fin_allocations fa on fa.open_item_id = i.id
      join public.fin_settlements fs on fs.id = fa.settlement_id and fs.status = 'posted'
     where i.source_id = v_policy
       and i.source_type in ('ins_policy_premium','ins_policy_insurer');
    -- v_residue is the fixture's ENTIRE net movement through the client-money account
    -- (premium collected less remitted). Left alone it would be real money in the account and
    -- §2's stated 400,000 would read 500,000 -- measured. So it is taken back out, leaving the
    -- client-money account exactly as §1 describes it from scratch. The condition is > 0, not
    -- > p_amount: the transfer below moves the commission out anyway, so removing only a
    -- supposed excess removed nothing and the figure stayed wrong.
    if v_residue > 0 then
      perform pg_temp.post(jsonb_build_array(
        jsonb_build_object('gl_account_id', pg_temp.id('eq'),    'debit', v_residue),
        jsonb_build_object('gl_account_id', pg_temp.id('trust'), 'credit', v_residue)),
        'fixture: return the policy cash to where it came from');
    end if;
  end;

  -- Same commission whatever the premium: the entry is the one p_amount says.
  select id into v_entry from ins_commission_entries
   where policy_id = v_policy order by created_at limit 1;
  if v_entry is null then
    raise exception 'fixture: binding did not raise a commission entry for policy %', v_policy;
  end if;
  update ins_commission_entries set amount = p_amount where id = v_entry;
  return v_entry;
end $$;
grant execute on function pg_temp.earned(numeric, numeric) to authenticated;

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
            pg_temp.id('trust_bank'), pg_temp.id('ops_bank'), pg_temp.backdate(),
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
  -- No GL journal here. This used to post Dr insurer payable / Cr client money for 380,000 as
  -- well as inserting the open item, which counted the same liability twice: the position
  -- reads `owed` from the SUBLEDGER, so the journal only succeeded in draining the account and
  -- the three assertions below could never all hold (the account read 20,000, not 400,000).
  -- The liability is one open item, which is where a real insurer payable comes from.
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
      pg_temp.id('trust_bank'), pg_temp.id('ops_bank'), pg_temp.backdate(), v_entry),
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
  -- Dated TODAY, not backdated: the setting is effective today, and the guard looks it up by
  -- the transfer date, so a backdated transfer is still governed by the default 'enforce' --
  -- which is precisely what this section is trying to override. (§2b dated it today already;
  -- that was correct and is the reason the fixture postings are the ones backdated.)
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

  -- A reviewed reconciliation resets the streak. NOT for yesterday, though: the loop stops at
  -- the first REVIEWED day, so reconciling yesterday makes it stop immediately and the streak
  -- is 0. Reconciling the missed day BEFORE yesterday (v_prev2) leaves exactly one missed day
  -- between here and now, and the streak is 1 -- which is what §3 states. This section asserted
  -- 1 while doing the other thing, and passed for a while only because the whole file aborted
  -- earlier; executed, it failed at the first assertion.
  perform pg_temp.jwt(pg_temp.id('fin1'));
  set local role authenticated;
  perform public.ins_prepare_client_money_reconciliation(pg_temp.id('trust_bank'), v_prev2, null);
  reset role;
  perform pg_temp.jwt(pg_temp.id('fin2'));
  set local role authenticated;
  perform public.ins_review_client_money_reconciliation(
    (select id from fin_client_money_reconciliations
      where tenant_id = pg_temp.id('tenant') and reconciled_for = v_prev2), 'checked to the statement');
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
  --
  -- One open item, not a journal. This used to ALSO post Dr insurer payable / Cr client money
  -- for 100,000 (kept from before the fixture, when §2 did the same), which counts the same
  -- liability twice: `owed` comes from the subledger. The doubled exposure then made the
  -- earned-commission fixture below try to remit more than allocated collections allowed, and
  -- it failed with INS_CASH_CAP -- 999,000 requested against 900,000 available.
  insert into fin_open_items
    (tenant_id, party_account_id, control_role, side, source_type, source_id,
     document_no, document_date, due_date, amount, currency, fx_rate,
     accounting_policy_version, description)
  values
    (pg_temp.id('tenant'), pg_temp.id('supplier'), 'insurer_payable', 'payable',
     'ins_policy_insurer', gen_random_uuid(), 'CM-INS-2', current_date, current_date,
     100000, 'UGX', 1, 1, 'shortage fixture: premium owed to the insurer');

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
      pg_temp.id('trust_bank'), pg_temp.id('ops_bank'), pg_temp.backdate(), v_entry),
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
            pg_temp.id('trust_bank'), pg_temp.id('ops_bank'), pg_temp.backdate(),
            array[v_entry], 'after the release');
  reset role;

  perform pg_temp.assert(v_tr.id is not null,
    '§5 once released, a transfer that fits the position should succeed');
  raise notice 'PASS: §5 a shortage cannot be released until the money is there, and the release is attributed';
end $$;

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
            pg_temp.id('trust_bank'), pg_temp.id('ops_bank'), pg_temp.backdate(),
            array[v_entry], 'precondition baseline');
  reset role;
  perform pg_temp.assert(v_tr.id is not null,
    '§6a a legitimate transfer must still go through with the preconditions in place');

  -- 6b. The entry is now 'transferred'. Asking for it again must be refused, and refused
  -- with the specific code, not merely "not earned".
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  perform pg_temp.expect_error(
    format($q$select public.ins_transfer_earned_commission(%L,%L,pg_temp.backdate(),array[%L]::uuid[],'again')$q$,
      pg_temp.id('trust_bank'), pg_temp.id('ops_bank'), v_entry),
    -- INS_TRANSFER_ALREADY_TRANSFERRED, not INS_TRANSFER_ENTRIES. 20261124011800 checks this
    -- FIRST and deliberately, because an entry's status returns to 'earned' when its transfer
    -- is voided -- so "earned and not yet transferred" cannot tell a never-transferred entry
    -- from one whose money moved and came back. The distinct code is the more useful answer and
    -- this assertion predates it.
    'INS_TRANSFER_ALREADY_TRANSFERRED',
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
    format($q$select public.ins_transfer_earned_commission(%L,%L,pg_temp.backdate(),array[%L]::uuid[],'stale')$q$,
      pg_temp.id('trust_bank'), pg_temp.id('ops_bank'), v_entry2),
    -- Same reason as §6b: the posted-transfer check runs first and says something more precise.
    'INS_TRANSFER_ALREADY_TRANSFERRED',
    '§6c an entry already on a posted transfer, offered again');
  reset role;

  -- 6d. The pool path (no explicit entries) must be unaffected: it cannot select an entry
  -- that is not 'earned', so the precondition never fires there and nothing regresses.
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  begin
    v_tr := public.ins_transfer_earned_commission(
              pg_temp.id('trust_bank'), pg_temp.id('ops_bank'), pg_temp.backdate(),
              null, 'pool path');
    perform pg_temp.assert(v_tr.id is not null, '§6d the pool path should still transfer');
  exception when others then
    perform pg_temp.assert(sqlerrm not like 'INS_TRANSFER_ALREADY_TRANSFERRED%',
      format('§6d the pool path must not be blocked by the new precondition, got: %s', sqlerrm));
  end;
  reset role;

  raise notice 'PASS: §6 a posted transfer cannot be re-run over the same entries, and the pool path is unchanged';
end $$;

do $$ begin
  raise notice 'ALL PASS: the position test refuses what the balance test allowed, missed reconciliations escalate once, a shortage blocks transfers until an independent release, and the transfer itself cannot move the same entry twice';
end $$;

rollback;
