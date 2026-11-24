-- =====================================================================
-- Non-cash party-balance movement (dispositions)
-- Accountant pack v2, B11
-- =====================================================================
-- This is the primitive that unblocks three features: releasing a client advance
-- (B2), writing off a claim balance (B8), and anything else that must reduce a
-- party balance without cash. What has to be true:
--
--   §1 an advance release reduces 2040 and AR by the same amount, with cash untouched
--   §2 the subledger agrees: consumption rises, outstanding falls, the item shows it
--   §3 releasing more than the advance holds is refused
--   §4 a write-off reduces the claim payable and lands in the named expense account
--   §5 a write-off may not post to a commission account (pack's recovery rule)
--   §6 a disposition may not use a control account as its counterparty
--   §7 a disposition cannot be edited or deleted -- reverse it with a new posting
--   §8 the kind must match the item: an advance cannot be written off as a claim
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

-- Debit-positive for assets, credit-positive for liabilities, as before.
create function pg_temp.balance(p_gl uuid) returns numeric
language sql security definer as $$
  select coalesce(sum(l.debit - l.credit), 0)
    from journal_entry_lines l
    join journal_entries je on je.id = l.journal_entry_id
   where je.tenant_id = (select v from ids where k = 'tenant')
     and l.gl_account_id = p_gl
$$;
grant execute on function pg_temp.balance(uuid) to authenticated;

create function pg_temp.outstanding(p_item uuid) returns numeric
language sql security definer as $$
  select outstanding_amount from fin_open_item_balances where id = p_item
$$;
grant execute on function pg_temp.outstanding(uuid) to authenticated;

do $$
declare
  ta uuid := gen_random_uuid();
  admin1 uuid := gen_random_uuid();
  admin2 uuid := gen_random_uuid();
  mgr uuid := gen_random_uuid();
  trust_gl uuid; ar_gl uuid; adv_gl uuid; pay_gl uuid; recv_gl uuid;
  bad_debt_gl uuid; comm_gl uuid; unearned_gl uuid;
  v_bank uuid; v_party uuid; v_bd uuid; v_client uuid;
begin
  insert into tenants(id, name) values (ta, 'Disposition test');
  insert into auth.users(id, email, raw_user_meta_data, raw_app_meta_data, aud, role, created_at, updated_at)
    select u, 'dsp-' || u || '@test.local', '{}', '{}', 'authenticated', 'authenticated', now(), now()
    from unnest(array[admin1, admin2, mgr]) u;
  insert into app_users(id, tenant_id, name, email)
    select u, ta, 'Disposition actor', 'dsp-' || u || '@test.local'
    from unnest(array[admin1, admin2, mgr]) u;
  update app_users set is_company_admin = true where id in (admin1, admin2);

  insert into tenant_modules(tenant_id, module) values (ta, 'insurance');
  insert into staff_roles(tenant_id, user_id, module, role) values (ta, mgr, 'insurance', 'manager');
  insert into finance_team_members(tenant_id, user_id, role) values (ta, mgr, 'finance');

  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '1020', 'Client money', 'asset') returning id into trust_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type, is_control_account) values (ta, '1100', 'AR', 'asset', true) returning id into ar_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type, is_control_account) values (ta, '2040', 'Advances', 'liability', true) returning id into adv_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type, is_control_account) values (ta, '2030', 'Client claim payable', 'liability', true) returning id into pay_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type, is_control_account) values (ta, '1120', 'Insurer claim recv', 'asset', true) returning id into recv_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '5900', 'Bad debts written off', 'expense') returning id into bad_debt_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type, is_control_account) values (ta, '4000', 'Commission income', 'revenue', true) returning id into comm_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type, is_control_account) values (ta, '2020', 'Unearned commission', 'liability', true) returning id into unearned_gl;
  insert into gl_posting_rules(tenant_id, account_role, gl_account_id) values
    (ta, 'client_money_bank', trust_gl), (ta, 'ar_control', ar_gl),
    (ta, 'client_advance_payable', adv_gl), (ta, 'client_claim_payable', pay_gl),
    (ta, 'insurer_claim_receivable', recv_gl), (ta, 'commission_income', comm_gl),
    (ta, 'unearned_commission', unearned_gl);
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
=======
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
  -- Appendix B Q1/Q4: the one contra-claims-expense account a write-off and a recovery
  -- both post to. Mapped here to the fixture's bad-debt account so the existing balance
  -- assertions still describe the posting, while the account itself is now chosen by
  -- mapping rather than passed at every call.
  insert into gl_posting_rules(tenant_id, account_role, gl_account_id)
    values (ta, 'ins_claim_write_off_expense', bad_debt_gl);
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs

  insert into fin_bank_accounts(tenant_id, name, kind, currency, gl_account_id)
    values (ta, 'DSP-TRUST', 'client_money', 'UGX', trust_gl) returning id into v_bank;

<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
  insert into accounts(tenant_id, account_code, name, account_type) values (ta, 'T-' || substr(gen_random_uuid()::text, 1, 8), 'Disposition client', 'client') returning id into v_party;
=======
  insert into accounts(tenant_id, name, account_type) values (ta, 'Disposition client', 'client') returning id into v_party;
>>>>>>> theirs
=======
  insert into accounts(tenant_id, name, account_type) values (ta, 'Disposition client', 'client') returning id into v_party;
>>>>>>> theirs
=======
  insert into accounts(tenant_id, name, account_type) values (ta, 'Disposition client', 'client') returning id into v_party;
>>>>>>> theirs
=======
  insert into accounts(tenant_id, name, account_type) values (ta, 'Disposition client', 'client') returning id into v_party;
>>>>>>> theirs
  insert into bd_clients(tenant_id, name) values (ta, 'Disposition client') returning id into v_bd;
  insert into ins_clients(tenant_id, client_id, client_type, party_account_id)
    values (ta, v_bd, 'corporate', v_party) returning id into v_client;

  create temp table ids (k text primary key, v uuid);
  insert into ids(k, v) values ('tenant', ta), ('client', v_client), ('party', v_party),
    ('bank', v_bank), ('adv', adv_gl), ('ar', ar_gl), ('pay', pay_gl), ('recv', recv_gl),
    ('trust', trust_gl), ('baddebt', bad_debt_gl), ('comm', comm_gl), ('unearned', unearned_gl),
    ('mgr', mgr);
end $$;

create function pg_temp.id(p_key text) returns uuid
language sql security definer set search_path = public, pg_temp as $$
  select v from ids where k = p_key
$$;
grant execute on function pg_temp.id(text) to authenticated;

-- Take a 600,000 advance so there is something to release.
do $$
begin
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  perform ins_record_client_advance(pg_temp.id('client'), pg_temp.id('bank'), 600000,
                                    current_date, 'ADV-DSP', 'advance for disposition test');
  reset role;
end $$;

-- ---------------------------------------------------------------------
-- §1 a release moves 2040 and AR, and no cash
-- ---------------------------------------------------------------------
do $$
declare v_item uuid; v_cash_before numeric; v_disp fin_open_item_dispositions%rowtype;
begin
  select open_item_id into v_item from ins_client_advances where tenant_id = pg_temp.id('tenant');
  v_cash_before := pg_temp.balance(pg_temp.id('trust'));

  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  v_disp := ins_dispose_open_item(v_item, 'advance_release', 250000,
                                  pg_temp.id('ar'), 'released to a policy receivable', current_date);
  reset role;

  -- 2040 is a liability, so a release reduces its credit: debit-positive goes +250,000.
  perform pg_temp.assert(pg_temp.balance(pg_temp.id('adv')) = 250000,
    format('§1 2040 should show a net 250,000 debit after releasing 250,000, got %s', pg_temp.balance(pg_temp.id('adv'))));
  -- AR is an asset, reduced by a credit: debit-positive goes to -250,000.
  perform pg_temp.assert(pg_temp.balance(pg_temp.id('ar')) = -250000,
    format('§1 AR should fall by 250,000, got %s', pg_temp.balance(pg_temp.id('ar'))));
  perform pg_temp.assert(pg_temp.balance(pg_temp.id('trust')) = v_cash_before,
    format('§1 cash must not move: %s -> %s', v_cash_before, pg_temp.balance(pg_temp.id('trust'))));
  perform pg_temp.assert(v_disp.kind = 'advance_release' and v_disp.amount = 250000,
    '§1 the disposition should record kind and amount');
  raise notice 'PASS: §1 a release reduces 2040 and AR equally and leaves cash alone';
end $$;

-- ---------------------------------------------------------------------
-- §2 the subledger agrees with the ledger
-- ---------------------------------------------------------------------
do $$
declare v_item uuid; v_out numeric; v_consumed numeric;
begin
  select open_item_id into v_item from ins_client_advances where tenant_id = pg_temp.id('tenant');
  v_out := pg_temp.outstanding(v_item);
  v_consumed := fin_open_item_consumed(v_item);

  perform pg_temp.assert(v_out = 350000,
    format('§2 the advance item should show 350,000 outstanding, got %s', v_out));
  perform pg_temp.assert(v_consumed = 250000,
    format('§2 consumption should count the disposition (250,000), got %s', v_consumed));
  raise notice 'PASS: §2 the open-item balance counts dispositions, so the subledger agrees with 2040';
end $$;

-- ---------------------------------------------------------------------
-- §3 releasing more than is held is refused
-- ---------------------------------------------------------------------
do $$
declare v_item uuid; v_refused boolean := false;
begin
  select open_item_id into v_item from ins_client_advances where tenant_id = pg_temp.id('tenant');
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  begin
    perform ins_dispose_open_item(v_item, 'advance_release', 400000,
                                  pg_temp.id('ar'), 'too much', current_date);
  exception when others then
    v_refused := true;
    perform pg_temp.assert(sqlerrm like 'INS_DISPOSITION_EXCEEDS%',
      '§3 over-releasing should be refused as INS_DISPOSITION_EXCEEDS, got: ' || sqlerrm);
  end;
  reset role;
  perform pg_temp.assert(v_refused, '§3 releasing more than the advance holds must be refused');
  raise notice 'PASS: §3 over-release is refused, so 2040 cannot go negative';
end $$;

-- ---------------------------------------------------------------------
-- §6 a control account cannot be the counterparty
-- ---------------------------------------------------------------------
do $$
declare v_item uuid; v_refused boolean := false;
begin
  select open_item_id into v_item from ins_client_advances where tenant_id = pg_temp.id('tenant');
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  begin
    perform ins_dispose_open_item(v_item, 'advance_release', 10000,
                                  pg_temp.id('pay'), 'wrong counterparty', current_date);
  exception when others then
    v_refused := true;
    perform pg_temp.assert(sqlerrm like 'INS_DISPOSITION_ACCOUNT%',
      '§6 a control account as counterparty must be refused, got: ' || sqlerrm);
  end;
  reset role;
  perform pg_temp.assert(v_refused,
    '§6 a disposition must not post to a control account -- that is posting without a subledger reference');
  raise notice 'PASS: §6 a control account cannot be named as the counterparty';
end $$;

-- ---------------------------------------------------------------------
-- §8 the kind must match the item
-- ---------------------------------------------------------------------
do $$
declare v_item uuid; v_refused boolean := false;
begin
  select open_item_id into v_item from ins_client_advances where tenant_id = pg_temp.id('tenant');
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  begin
    perform ins_dispose_open_item(v_item, 'claim_write_off', 10000,
                                  pg_temp.id('baddebt'), 'wrong kind', current_date);
  exception when others then
    v_refused := true;
    perform pg_temp.assert(sqlerrm like 'INS_DISPOSITION_KIND%',
      '§8 a claim write-off against an advance item must be refused, got: ' || sqlerrm);
  end;
  reset role;
  perform pg_temp.assert(v_refused, '§8 the kind must match what the item is');
  raise notice 'PASS: §8 an advance cannot be written off as a claim';
end $$;

-- ---------------------------------------------------------------------
-- §7 dispositions are immutable
-- ---------------------------------------------------------------------
do $$
declare v_disp uuid; v_refused_update boolean := false; v_refused_delete boolean := false;
begin
  select id into v_disp from fin_open_item_dispositions where tenant_id = pg_temp.id('tenant') limit 1;
  -- Even as the table owner the trigger refuses; the point is that no path exists.
  begin
    update fin_open_item_dispositions set reason = 'changed my mind' where id = v_disp;
  exception when others then
    v_refused_update := true;
  end;
  begin
    delete from fin_open_item_dispositions where id = v_disp;
  exception when others then
    v_refused_delete := true;
  end;
  perform pg_temp.assert(v_refused_update, '§7 a disposition cannot be edited');
  perform pg_temp.assert(v_refused_delete, '§7 a disposition cannot be deleted');
  raise notice 'PASS: §7 a disposition is immutable; it must be reversed by a new posting';
end $$;

-- ---------------------------------------------------------------------
-- §4/§5 claim write-offs land in the named expense, never in commission
-- ---------------------------------------------------------------------
do $$
declare v_line uuid; v_insurer uuid; v_pol uuid; v_claim ins_claims%rowtype;
        v_refused boolean := false; v_pay_before numeric; v_baddebt_before numeric;
begin
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  insert into ins_product_lines(tenant_id, code, name) values (pg_temp.id('tenant'), 'GEN', 'General') returning id into v_line;
  insert into ins_insurers(tenant_id, code, name) values (pg_temp.id('tenant'), 'DSPINS', 'Disposition Insurer') returning id into v_insurer;
  v_pol := ins_create_policy(pg_temp.id('client'), v_insurer, v_line,
                             current_date - 20, current_date + 200, 1000000, 'UGX', 1000000, 10,
                             null, null, 'Write-off policy', null);
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
  v_claim := ins_create_claim(v_pol, current_date - 5, current_date - 4, 'Water damage', null, 200000);
  perform ins_transition_claim(v_claim.id, 'assessing', 'assessed');
  perform ins_transition_claim(v_claim.id, 'approved', 'approved at 150,000', 150000);
  perform ins_recognise_claim_receivable(v_claim.id, 'insurer confirmation letter');
  reset role;

  v_pay_before := pg_temp.balance(pg_temp.id('pay'));
  v_baddebt_before := pg_temp.balance(pg_temp.id('baddebt'));

<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
  -- Commission is refused by name.
=======
  -- Commission is refused. Since Appendix B Q1 the account is configured once on the
  -- posting role, so naming a different account at the call site is itself refused --
  -- whichever account is named, and commission accounts included.
>>>>>>> theirs
=======
  -- Commission is refused by name.
>>>>>>> theirs
=======
  -- Commission is refused. Since Appendix B Q1 the account is configured once on the
  -- posting role, so naming a different account at the call site is itself refused --
  -- whichever account is named, and commission accounts included.
>>>>>>> theirs
=======
  -- Commission is refused. Since Appendix B Q1 the account is configured once on the
  -- posting role, so naming a different account at the call site is itself refused --
  -- whichever account is named, and commission accounts included.
>>>>>>> theirs
=======
  -- Commission is refused. Since Appendix B Q1 the account is configured once on the
  -- posting role, so naming a different account at the call site is itself refused --
  -- whichever account is named, and commission accounts included.
>>>>>>> theirs
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  begin
    perform ins_write_off_claim(v_claim.id, 50000, pg_temp.id('comm'), 'trying commission');
  exception when others then
    v_refused := true;
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
=======
>>>>>>> theirs
    perform pg_temp.assert(sqlerrm like 'INS_WRITE_OFF_COMMISSION%' or sqlerrm like 'INS_WRITE_OFF_ACCOUNT%',
      '§5 writing off into a commission account must be refused, got: ' || sqlerrm);
  end;

  -- The real write-off.
  perform ins_write_off_claim(v_claim.id, 50000, pg_temp.id('baddebt'), 'insurer shortfall accepted');
<<<<<<< ours
=======
    perform pg_temp.assert(sqlerrm like 'INS_WRITE_OFF_ACCOUNT%',
      '§5 naming an account other than the configured contra-claims-expense account must be refused, got: ' || sqlerrm);
  end;

  -- And with no account named, the configured one is used.
  perform ins_write_off_claim(v_claim.id, 50000, null, 'insurer shortfall accepted');
>>>>>>> theirs
=======
>>>>>>> theirs
=======
=======
>>>>>>> theirs
=======
>>>>>>> theirs
    perform pg_temp.assert(sqlerrm like 'INS_WRITE_OFF_ACCOUNT%',
      '§5 naming an account other than the configured contra-claims-expense account must be refused, got: ' || sqlerrm);
  end;

  -- And with no account named, the configured one is used.
  perform ins_write_off_claim(v_claim.id, 50000, null, 'insurer shortfall accepted');
<<<<<<< ours
<<<<<<< ours
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
  reset role;

  perform pg_temp.assert(v_refused, '§5 a commission account must not absorb a claim write-off');
  perform pg_temp.assert(pg_temp.balance(pg_temp.id('baddebt')) = v_baddebt_before + 50000,
    format('§4 bad debts should rise by 50,000, got a change of %s',
           pg_temp.balance(pg_temp.id('baddebt')) - v_baddebt_before));
  -- 2030 is a liability; writing it down is a debit, so the credit balance falls by 50,000.
  perform pg_temp.assert(pg_temp.balance(pg_temp.id('pay')) = v_pay_before + 50000,
    format('§4 the claim payable should fall by 50,000 (credit balance -50,000), got a change of %s',
           pg_temp.balance(pg_temp.id('pay')) - v_pay_before));
  raise notice 'PASS: §4 a write-off reduces 2030 into the named expense account, and §5 refuses commission';
end $$;

do $$ begin
  raise notice 'ALL PASS: dispositions move party balances without cash, the subledger counts them, and every guard holds';
end $$;

rollback;
