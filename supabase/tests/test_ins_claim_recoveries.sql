-- =====================================================================
-- Claim recoveries
-- Accountant pack v2, B8; pack section 7.7
-- =====================================================================
-- The pack's criteria:
--
--   "A recovery is raised against a claim"                        §1
--   "allocated when received"                                     §2
--   "and never touches commission accounts"                       §3, §4
--
-- Plus the property that makes a recovery a separate receivable rather than a
-- negative claim: it has its own payer, and raising one does not change the claim's
-- approved amount or create a second accrual (§5).
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

create function pg_temp.balance(p_gl uuid) returns numeric
language sql security definer as $$
  select coalesce(sum(l.debit - l.credit), 0)
    from journal_entry_lines l
    join journal_entries je on je.id = l.journal_entry_id
   where je.tenant_id = (select v from ids where k = 'tenant')
     and l.gl_account_id = p_gl
$$;
grant execute on function pg_temp.balance(uuid) to authenticated;

do $$
declare
  ta uuid := gen_random_uuid();
  admin1 uuid := gen_random_uuid();
  admin2 uuid := gen_random_uuid();
  mgr uuid := gen_random_uuid();
  trust_gl uuid; ar_gl uuid; pay_gl uuid; recv_gl uuid;
  recov_gl uuid; comm_gl uuid; unearned_gl uuid; recvbl_gl uuid;
  v_bank uuid; v_party uuid; v_bd uuid; v_client uuid; v_insurer_party uuid;
begin
  insert into tenants(id, name) values (ta, 'Recoveries test');
  insert into auth.users(id, email, raw_user_meta_data, raw_app_meta_data, aud, role, created_at, updated_at)
    select u, 'rec-' || u || '@test.local', '{}', '{}', 'authenticated', 'authenticated', now(), now()
    from unnest(array[admin1, admin2, mgr]) u;
  insert into app_users(id, tenant_id, name, email)
    select u, ta, 'Recovery actor', 'rec-' || u || '@test.local'
    from unnest(array[admin1, admin2, mgr]) u;
  update app_users set is_company_admin = true where id in (admin1, admin2);

  insert into tenant_modules(tenant_id, module) values (ta, 'insurance');
  insert into staff_roles(tenant_id, user_id, module, role) values (ta, mgr, 'insurance', 'manager');
  insert into finance_team_members(tenant_id, user_id, role) values (ta, mgr, 'finance');

  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '1020', 'Client money', 'asset') returning id into trust_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type, is_control_account) values (ta, '1100', 'AR', 'asset', true) returning id into ar_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type, is_control_account) values (ta, '1120', 'Insurer claim recv', 'asset', true) returning id into recv_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type, is_control_account) values (ta, '2030', 'Client claim payable', 'liability', true) returning id into pay_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '4900', 'Recovery income', 'revenue') returning id into recov_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type, is_control_account) values (ta, '4000', 'Commission income', 'revenue', true) returning id into comm_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type, is_control_account) values (ta, '2020', 'Unearned commission', 'liability', true) returning id into unearned_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type, is_control_account) values (ta, '1110', 'Commission receivable', 'asset', true) returning id into recvbl_gl;
  insert into gl_posting_rules(tenant_id, account_role, gl_account_id) values
    (ta, 'client_money_bank', trust_gl), (ta, 'ar_control', ar_gl),
    (ta, 'insurer_claim_receivable', recv_gl), (ta, 'client_claim_payable', pay_gl),
    (ta, 'commission_income', comm_gl), (ta, 'unearned_commission', unearned_gl),
    (ta, 'commission_receivable', recvbl_gl);

  insert into fin_bank_accounts(tenant_id, name, kind, currency, gl_account_id)
    values (ta, 'REC-TRUST', 'client_money', 'UGX', trust_gl) returning id into v_bank;

<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
  insert into accounts(tenant_id, account_code, name, account_type) values (ta, 'T-' || substr(gen_random_uuid()::text, 1, 8), 'Recovery client', 'client') returning id into v_party;
  insert into accounts(tenant_id, account_code, name, account_type) values (ta, 'T-' || substr(gen_random_uuid()::text, 1, 8), 'Recovery Insurer', 'vendor') returning id into v_insurer_party;
=======
  insert into accounts(tenant_id, name, account_type) values (ta, 'Recovery client', 'client') returning id into v_party;
  insert into accounts(tenant_id, name, account_type) values (ta, 'Recovery Insurer', 'vendor') returning id into v_insurer_party;
>>>>>>> theirs
=======
  insert into accounts(tenant_id, name, account_type) values (ta, 'Recovery client', 'client') returning id into v_party;
  insert into accounts(tenant_id, name, account_type) values (ta, 'Recovery Insurer', 'vendor') returning id into v_insurer_party;
>>>>>>> theirs
=======
  insert into accounts(tenant_id, name, account_type) values (ta, 'Recovery client', 'client') returning id into v_party;
  insert into accounts(tenant_id, name, account_type) values (ta, 'Recovery Insurer', 'vendor') returning id into v_insurer_party;
>>>>>>> theirs
=======
  insert into accounts(tenant_id, name, account_type) values (ta, 'Recovery client', 'client') returning id into v_party;
  insert into accounts(tenant_id, name, account_type) values (ta, 'Recovery Insurer', 'vendor') returning id into v_insurer_party;
>>>>>>> theirs
  insert into bd_clients(tenant_id, name) values (ta, 'Recovery client') returning id into v_bd;
  insert into ins_clients(tenant_id, client_id, client_type, party_account_id)
    values (ta, v_bd, 'corporate', v_party) returning id into v_client;

  create temp table ids (k text primary key, v uuid);
  insert into ids(k, v) values ('tenant', ta), ('client', v_client), ('party', v_party),
    ('insurerparty', v_insurer_party), ('bank', v_bank), ('ar', ar_gl), ('pay', pay_gl),
    ('recv', recv_gl), ('trust', trust_gl), ('recov', recov_gl), ('comm', comm_gl),
    ('unearned', unearned_gl), ('mgr', mgr);
end $$;

create function pg_temp.id(p_key text) returns uuid
language sql security definer set search_path = public, pg_temp as $$
  select v from ids where k = p_key
$$;
grant execute on function pg_temp.id(text) to authenticated;

-- A claim approved and recognised at 400,000, with the insurer funded, so it can be
-- paid out and recovered against.
create function pg_temp.claim_ready() returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_line uuid; v_insurer uuid; v_pol uuid; v_claim ins_claims%rowtype;
begin
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  insert into ins_product_lines(tenant_id, code, name)
    values (pg_temp.id('tenant'), 'REC', 'Recovery line') returning id into v_line;
  insert into ins_insurers(tenant_id, code, name)
    values (pg_temp.id('tenant'), 'RECINS', 'Recovery Insurer') returning id into v_insurer;
  v_pol := ins_create_policy(pg_temp.id('client'), v_insurer, v_line,
                             current_date - 60, current_date + 300, 2000000, 'UGX', 2000000, 10,
                             null, null, 'Recovery policy', null);
  reset role;
  insert into ins_policy_insurer_shares
    (tenant_id, policy_id, insurer_id, is_lead, share_pct, commission_rate_pct, reviewed)
  values (pg_temp.id('tenant'), v_pol, v_insurer, true, 100, 10, true);
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  perform ins_submit_policy_for_approval(v_pol);
  reset role;
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  perform ins_bind_policy(v_pol);
  v_claim := ins_create_claim(v_pol, current_date - 20, current_date - 19, 'Storm damage', null, 400000);
  perform ins_transition_claim(v_claim.id, 'assessing', 'assessed');
  perform ins_transition_claim(v_claim.id, 'approved', 'approved at 400,000', 400000);
  perform ins_recognise_claim_receivable(v_claim.id, 'insurer letter');
  perform ins_record_claim_receipt(v_claim.id, pg_temp.id('bank'), 400000, current_date, 'FUND-REC', 'funds');
  reset role;
  return v_claim.id;
end $$;

-- ---------------------------------------------------------------------
-- §1 a recovery is raised against the claim, as its own receivable
-- ---------------------------------------------------------------------
do $$
declare v_claim uuid := pg_temp.claim_ready();
        v_rec ins_claim_recoveries%rowtype;
begin
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  v_rec := ins_raise_claim_recovery(
    v_claim, 'insurer_underpayment', pg_temp.id('insurerparty'), 75000,
    pg_temp.id('recov'), 'insurer settled 75,000 short of the agreed amount');
  reset role;

  perform pg_temp.assert(v_rec.status = 'outstanding',
    '§1 a new recovery is outstanding, got ' || coalesce(v_rec.status, '(none)'));
  perform pg_temp.assert(v_rec.amount = 75000,
    format('§1 the recovery should be 75,000, got %s', v_rec.amount));
  -- Dr AR by 75,000, Cr recovery income by 75,000.
  perform pg_temp.assert(pg_temp.balance(pg_temp.id('ar')) > 0,
    format('§1 AR should carry the recovery receivable, got %s', pg_temp.balance(pg_temp.id('ar'))));
  perform pg_temp.assert(pg_temp.balance(pg_temp.id('recov')) = -75000,
    format('§1 recovery income should be credited 75,000, got %s', pg_temp.balance(pg_temp.id('recov'))));
  raise notice 'PASS: §1 a recovery is raised as its own receivable against the claim';
end $$;

-- ---------------------------------------------------------------------
-- §2 receiving it allocates against the recovery, not the claim
-- ---------------------------------------------------------------------
do $$
declare v_rec_id uuid := (select id from ins_claim_recoveries where tenant_id = pg_temp.id('tenant') limit 1);
        v_rec ins_claim_recoveries%rowtype;
        v_claim_received numeric;
begin
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  v_rec := ins_receive_claim_recovery(v_rec_id, pg_temp.id('bank'), 75000, current_date, 'REC-REF-1', 'settled by the insurer');
  reset role;

  perform pg_temp.assert(v_rec.received_amount = 75000,
    format('§2 received_amount should be 75,000, got %s', v_rec.received_amount));
  perform pg_temp.assert(v_rec.status = 'received',
    '§2 a fully received recovery is received, got ' || coalesce(v_rec.status, '(none)'));
  -- Receiving converts the receivable into cash: AR back down, bank up.
  perform pg_temp.assert(pg_temp.balance(pg_temp.id('trust')) = 400000 + 75000,
    format('§2 client money should hold the insurer funds plus the recovery (475,000), got %s',
           pg_temp.balance(pg_temp.id('trust'))));
  raise notice 'PASS: §2 the recovery is allocated when received, through the ordinary cash path';
end $$;

-- ---------------------------------------------------------------------
-- §3/§4 commission accounts are refused, by name
-- ---------------------------------------------------------------------
do $$
declare v_claim uuid := (select id from ins_claims where tenant_id = pg_temp.id('tenant') limit 1);
        v_r1 boolean := false; v_r2 boolean := false; v_r3 boolean := false;
begin
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  begin
    perform ins_raise_claim_recovery(v_claim, 'third_party', pg_temp.id('insurerparty'), 10000,
                                     pg_temp.id('comm'), 'trying commission income');
  exception when others then
    v_r1 := true;
    perform pg_temp.assert(sqlerrm like 'INS_RECOVERY_COMMISSION%',
      '§3 commission income must be refused, got: ' || sqlerrm);
  end;
  begin
    perform ins_raise_claim_recovery(v_claim, 'third_party', pg_temp.id('insurerparty'), 10000,
                                     pg_temp.id('unearned'), 'trying unearned commission');
  exception when others then
    v_r2 := true;
  end;
  -- And a control account is refused as a credit account for the same reason as
  -- elsewhere: that would be posting to a control account with no subledger item.
  begin
    perform ins_raise_claim_recovery(v_claim, 'third_party', pg_temp.id('insurerparty'), 10000,
                                     pg_temp.id('pay'), 'trying a control account');
  exception when others then
    v_r3 := true;
  end;
  reset role;

  perform pg_temp.assert(v_r1 and v_r2, '§3 neither commission income nor unearned commission may receive a recovery');
  perform pg_temp.assert(v_r3, '§3 a control account may not be the credit account');
  raise notice 'PASS: §3/§4 a recovery cannot be posted to commission or to a control account';
end $$;

-- ---------------------------------------------------------------------
-- §5 a recovery is not a negative claim
-- ---------------------------------------------------------------------
do $$
declare v_claim uuid; v_approved_before numeric; v_approved_after numeric;
        v_accruals integer; v_rec ins_claim_recoveries%rowtype;
begin
  v_claim := pg_temp.claim_ready();
  select approved_amount into v_approved_before from ins_claims where id = v_claim;

  select count(*) into v_accruals from journal_entries
   where tenant_id = pg_temp.id('tenant') and source_id = v_claim and source_type = 'ins_claim_accrual';

  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  v_rec := ins_raise_claim_recovery(v_claim, 'third_party', pg_temp.id('insurerparty'), 50000,
                                    pg_temp.id('recov'), 'subrogation against the contractor');
  reset role;

  select approved_amount into v_approved_after from ins_claims where id = v_claim;
  perform pg_temp.assert(v_approved_after = v_approved_before,
    format('§5 raising a recovery must not re-price the claim: %s -> %s', v_approved_before, v_approved_after));
  perform pg_temp.assert(
    (select count(*) from journal_entries
      where tenant_id = pg_temp.id('tenant') and source_id = v_claim and source_type = 'ins_claim_accrual') = v_accruals,
    '§5 and must not create a second claim accrual');
  perform pg_temp.assert(v_rec.payer_party_account_id = pg_temp.id('insurerparty'),
    '§5 the recovery keeps its own payer rather than defaulting to the claim client');
  raise notice 'PASS: §5 a recovery leaves the claim's approval and accrual untouched';
end $$;

-- ---------------------------------------------------------------------
-- §6 writing off a recovery charges the loss back to the same account
-- ---------------------------------------------------------------------
do $$
declare v_rec_id uuid; v_rec ins_claim_recoveries%rowtype; v_recov_before numeric;
begin
  select id into v_rec_id from ins_claim_recoveries
   where tenant_id = pg_temp.id('tenant') and status = 'outstanding' limit 1;
  v_recov_before := pg_temp.balance(pg_temp.id('recov'));

  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  v_rec := ins_write_off_claim_recovery(v_rec_id, 50000, 'contractor is insolvent; no prospect of recovery');
  reset role;

  perform pg_temp.assert(v_rec.status = 'written_off',
    '§6 a fully written-off recovery is written_off, got ' || coalesce(v_rec.status, '(none)'));
  -- Credited 50,000 at raise, debited 50,000 at write-off: net nil on recovery income.
  perform pg_temp.assert(pg_temp.balance(pg_temp.id('recov')) = v_recov_before + 50000,
    format('§6 the write-off should reverse the credit: %s -> %s',
           v_recov_before, pg_temp.balance(pg_temp.id('recov'))));
  raise notice 'PASS: §6 a recovery written off leaves no net income behind';
end $$;

-- ---------------------------------------------------------------------
-- §7 a recovery is immutable in its basis
-- ---------------------------------------------------------------------
do $$
declare v_rec_id uuid := (select id from ins_claim_recoveries where tenant_id = pg_temp.id('tenant') limit 1);
        v_refused boolean := false;
begin
  begin
    update ins_claim_recoveries set amount = 999999 where id = v_rec_id;
  exception when others then
    v_refused := true;
  end;
  perform pg_temp.assert(v_refused, '§7 the amount of a recovery cannot be edited after the fact');
  raise notice 'PASS: §7 a recovery cannot be edited after the fact';
end $$;

do $$ begin
  raise notice 'ALL PASS: recoveries are separate receivables, allocate on receipt, never touch commission, and write off to the same account';
end $$;

rollback;
