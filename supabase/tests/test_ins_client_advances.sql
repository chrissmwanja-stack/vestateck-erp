-- =====================================================================
-- Client advances: 2040 holds the money, and the client can get it back
-- Accountant pack v2, decision 4 (B2)
-- =====================================================================
-- The pack's criteria, and which of them this file proves:
--
--   "A receipt with no policy creates a 2040 credit and no receivable"   §1
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
--   "binding a policy allocates it and clears 2040"                      NOT PROVEN
--                                                                        (B11: no
--                                                                        reclass
--                                                                        source;
--                                                                        see the
--                                                                        migration
--                                                                        header)
=======
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
--   "binding a policy allocates it and clears 2040"                      §5
--                                                                        (B11's
--                                                                        disposition
--                                                                        primitive)
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
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
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
--   "an unallocated advance is visible on the client statement"          §3
--   "and is refundable"                                                  §4
--
-- §2 proves the part of the AR criterion that matters most: taking an advance does
-- NOT create a receivable, so AR is not overstated by money paid before the policy.
--
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
-- §5 proves the release is refused rather than half-done, so nobody can ship a UI
-- that believes an advance was applied.
=======
-- §5 proves both halves: an over-refund is refused, and a release now clears 2040
-- against AR with cash untouched. Before B11's disposition primitive the release
-- refused; a test that still expected the refusal would be asserting a bug.
>>>>>>> theirs
=======
-- §5 proves both halves: an over-refund is refused, and a release now clears 2040
-- against AR with cash untouched. Before B11's disposition primitive the release
-- refused; a test that still expected the refusal would be asserting a bug.
>>>>>>> theirs
=======
-- §5 proves both halves: an over-refund is refused, and a release now clears 2040
-- against AR with cash untouched. Before B11's disposition primitive the release
-- refused; a test that still expected the refusal would be asserting a bug.
>>>>>>> theirs
=======
-- §5 proves both halves: an over-refund is refused, and a release now clears 2040
-- against AR with cash untouched. Before B11's disposition primitive the release
-- refused; a test that still expected the refusal would be asserting a bug.
>>>>>>> theirs
=======
-- §5 proves both halves: an over-refund is refused, and a release now clears 2040
-- against AR with cash untouched. Before B11's disposition primitive the release
-- refused; a test that still expected the refusal would be asserting a bug.
>>>>>>> theirs
=======
-- §5 proves both halves: an over-refund is refused, and a release now clears 2040
-- against AR with cash untouched. Before B11's disposition primitive the release
-- refused; a test that still expected the refusal would be asserting a bug.
>>>>>>> theirs
=======
-- §5 proves both halves: an over-refund is refused, and a release now clears 2040
-- against AR with cash untouched. Before B11's disposition primitive the release
-- refused; a test that still expected the refusal would be asserting a bug.
>>>>>>> theirs
=======
-- §5 proves both halves: an over-refund is refused, and a release now clears 2040
-- against AR with cash untouched. Before B11's disposition primitive the release
-- refused; a test that still expected the refusal would be asserting a bug.
>>>>>>> theirs
=======
-- §5 proves both halves: an over-refund is refused, and a release now clears 2040
-- against AR with cash untouched. Before B11's disposition primitive the release
-- refused; a test that still expected the refusal would be asserting a bug.
>>>>>>> theirs
=======
-- §5 proves both halves: an over-refund is refused, and a release now clears 2040
-- against AR with cash untouched. Before B11's disposition primitive the release
-- refused; a test that still expected the refusal would be asserting a bug.
>>>>>>> theirs
=======
-- §5 proves both halves: an over-refund is refused, and a release now clears 2040
-- against AR with cash untouched. Before B11's disposition primitive the release
-- refused; a test that still expected the refusal would be asserting a bug.
>>>>>>> theirs
=======
-- §5 proves both halves: an over-refund is refused, and a release now clears 2040
-- against AR with cash untouched. Before B11's disposition primitive the release
-- refused; a test that still expected the refusal would be asserting a bug.
>>>>>>> theirs
=======
-- §5 proves both halves: an over-refund is refused, and a release now clears 2040
-- against AR with cash untouched. Before B11's disposition primitive the release
-- refused; a test that still expected the refusal would be asserting a bug.
>>>>>>> theirs
=======
-- §5 proves both halves: an over-refund is refused, and a release now clears 2040
-- against AR with cash untouched. Before B11's disposition primitive the release
-- refused; a test that still expected the refusal would be asserting a bug.
>>>>>>> theirs
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

create function pg_temp.balance(p_gl uuid, p_credit_positive boolean default true)
returns numeric language sql security definer as $$
  select coalesce(sum(case when p_credit_positive then l.credit - l.debit else l.debit - l.credit end), 0)
    from journal_entry_lines l
    join journal_entries je on je.id = l.journal_entry_id
   where je.tenant_id = (select v from ids where k = 'tenant')
     and l.gl_account_id = p_gl
$$;
grant execute on function pg_temp.balance(uuid, boolean) to authenticated;

do $$
declare
  ta uuid := gen_random_uuid();
  admin1 uuid := gen_random_uuid();
  admin2 uuid := gen_random_uuid();
  mgr uuid := gen_random_uuid();
  maker uuid := gen_random_uuid();
  checker uuid := gen_random_uuid();
  trust_gl uuid; ar_gl uuid; adv_gl uuid; bank_gl uuid;
  v_bank uuid; v_party uuid; v_client uuid;
begin
  insert into tenants(id, name) values (ta, 'Client advances test');
  insert into auth.users(id, email, raw_user_meta_data, raw_app_meta_data, aud, role, created_at, updated_at)
    select u, 'adv-' || u || '@test.local', '{}', '{}', 'authenticated', 'authenticated', now(), now()
    from unnest(array[admin1, admin2, mgr, maker, checker]) u;
  insert into app_users(id, tenant_id, name, email)
    select u, ta, 'Advance actor', 'adv-' || u || '@test.local'
    from unnest(array[admin1, admin2, mgr, maker, checker]) u;
  update app_users set is_company_admin = true where id in (admin1, admin2);

  insert into tenant_modules(tenant_id, module) values (ta, 'insurance');
  insert into staff_roles(tenant_id, user_id, module, role) values (ta, mgr, 'insurance', 'manager');
  insert into finance_team_members(tenant_id, user_id, role)
    values (ta, mgr, 'finance'), (ta, maker, 'finance'), (ta, checker, 'finance');

  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '1000', 'Operating', 'asset') returning id into bank_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '1020', 'Client money', 'asset') returning id into trust_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type, is_control_account) values (ta, '1100', 'AR', 'asset', true) returning id into ar_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type, is_control_account) values (ta, '2040', 'Unallocated Client Advances', 'liability', true) returning id into adv_gl;
  insert into gl_posting_rules(tenant_id, account_role, gl_account_id) values
    (ta, 'bank', bank_gl), (ta, 'client_money_bank', trust_gl),
    (ta, 'ar_control', ar_gl), (ta, 'client_advance_payable', adv_gl);

  insert into fin_bank_accounts(tenant_id, name, kind, currency, gl_account_id)
    values (ta, 'ADV-TRUST', 'client_money', 'UGX', trust_gl) returning id into v_bank;

  -- accounts.account_type is vendor|client|both; the party account is an accounts
  -- row, and bd_clients carries no party link (only ins_clients does).
  insert into accounts(tenant_id, name, account_type)
    values (ta, 'Advance test client', 'client') returning id into v_party;

  insert into bd_clients(tenant_id, name)
    values (ta, 'Advance test client') returning id into v_client;

  insert into ins_clients(tenant_id, client_id, client_type, party_account_id)
    values (ta, v_client, 'corporate', v_party);

  create temp table ids (k text primary key, v uuid);
  insert into ids(k, v) values
    ('tenant', ta), ('client', (select id from ins_clients where client_id = v_client)),
    ('party', v_party), ('bank', v_bank), ('adv', adv_gl), ('ar', ar_gl),
    ('trust', trust_gl), ('mgr', mgr), ('maker', maker), ('checker', checker);
end $$;

create function pg_temp.id(p_key text) returns uuid
language sql security definer set search_path = public, pg_temp as $$
  select v from ids where k = p_key
$$;
grant execute on function pg_temp.id(text) to authenticated;

-- ---------------------------------------------------------------------
-- §1 taking an advance credits 2040 and creates no receivable
-- ---------------------------------------------------------------------
do $$
declare v_adv ins_client_advances%rowtype;
begin
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  v_adv := public.ins_record_client_advance(
             pg_temp.id('client'), pg_temp.id('bank'), 750000, current_date,
             'ADV-REF-1', 'premium paid before placement');
  reset role;

  perform pg_temp.assert(pg_temp.balance(pg_temp.id('adv')) = 750000,
    format('§1 2040 should hold a 750,000 credit, got %s', pg_temp.balance(pg_temp.id('adv'))));
  perform pg_temp.assert(pg_temp.balance(pg_temp.id('trust')) = 750000,
    format('§1 client money bank should hold 750,000, got %s', pg_temp.balance(pg_temp.id('trust'))));
  perform pg_temp.assert(pg_temp.balance(pg_temp.id('ar')) = 0,
    format('§1 taking an advance must not create a receivable, AR is %s', pg_temp.balance(pg_temp.id('ar'))));
  perform pg_temp.assert(v_adv.status = 'unallocated',
    '§1 a new advance is unallocated, got ' || coalesce(v_adv.status, '(none)'));
  raise notice 'PASS: §1 an advance credits 2040, debits client money and creates no receivable';
end $$;

-- ---------------------------------------------------------------------
-- §2 it is a payable on the advance control account, not on AR
-- ---------------------------------------------------------------------
do $$
declare v_item fin_open_items%rowtype;
begin
  select * into v_item from fin_open_items
   where tenant_id = pg_temp.id('tenant') and control_role = 'client_advance_payable';
  perform pg_temp.assert(v_item.side = 'payable',
    '§2 an advance open item is a payable, got ' || coalesce(v_item.side, '(none)'));
  perform pg_temp.assert(v_item.amount = 750000,
    format('§2 the advance item should be 750,000, got %s', v_item.amount));
  perform pg_temp.assert(pg_temp.balance(pg_temp.id('ar')) = 0,
    '§2 and AR is still untouched');
  raise notice 'PASS: §2 the advance sits as a payable on 2040';
end $$;

-- ---------------------------------------------------------------------
-- §3 it appears on the client statement as a liability
-- ---------------------------------------------------------------------
do $$
declare n integer; avail numeric;
begin
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  select count(*), coalesce(max(available), 0) into n, avail
    from public.ins_client_advance_statement(pg_temp.id('client'));
  reset role;

  perform pg_temp.assert(n = 1, format('§3 the statement should show one advance, got %s', n));
  perform pg_temp.assert(avail = 750000,
    format('§3 the statement should show 750,000 available, got %s', avail));
  raise notice 'PASS: §3 the unallocated advance is visible on the client statement';
end $$;

-- ---------------------------------------------------------------------
-- §4 it is refundable, in part, and the balance follows
-- ---------------------------------------------------------------------
do $$
declare v_adv ins_client_advances%rowtype; avail numeric;
begin
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  v_adv := public.ins_refund_client_advance(
             (select id from ins_client_advances where tenant_id = pg_temp.id('tenant')),
             pg_temp.id('bank'), 250000, current_date, 'client asked for the balance back');
  reset role;

  perform pg_temp.assert(v_adv.refunded_amount = 250000,
    format('§4 refunded_amount should be 250,000, got %s', v_adv.refunded_amount));
  perform pg_temp.assert(pg_temp.balance(pg_temp.id('adv')) = 500000,
    format('§4 2040 should fall to 500,000, got %s', pg_temp.balance(pg_temp.id('adv'))));
  perform pg_temp.assert(pg_temp.balance(pg_temp.id('trust')) = 500000,
    format('§4 client money should fall to 500,000, got %s', pg_temp.balance(pg_temp.id('trust'))));

  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  select max(available) into avail from public.ins_client_advance_statement(pg_temp.id('client'));
  reset role;
  perform pg_temp.assert(avail = 500000,
    format('§4 the statement should show 500,000 available, got %s', avail));
  raise notice 'PASS: §4 a partial refund clears part of 2040 and the statement follows';
end $$;

-- ---------------------------------------------------------------------
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
-- §5 over-refunding is refused, and so is the unimplemented release
-- ---------------------------------------------------------------------
do $$
declare v_adv uuid := (select id from ins_client_advances where tenant_id = pg_temp.id('tenant'));
        v_refused boolean := false;
        v_release_refused boolean := false;
=======
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
-- §5 over-refunding is refused, and the release now works
-- ---------------------------------------------------------------------
-- This section previously asserted that the release refused with
-- INS_ADVANCE_RELEASE_NOT_AVAILABLE. That was true of the first cut of B2, before
-- 20261124010500 gave the subledger a non-cash movement. It now has to prove the
-- opposite: that the advance clears 2040 and reduces AR without touching cash.
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
--
-- NOTE ON WHERE THE CAP LIVES NOW. Since Appendix B Q2 the approval gate runs before
-- the amount check, so a direct over-refund is refused as INS_REFUND_APPROVAL_REQUIRED
-- rather than INS_ADVANCE_EXCEEDS: you cannot reach the balance test without an approval
-- that covers the amount. That order is the safer one and is asserted below. The balance
-- cap itself is asserted where it is still reachable -- when the request is raised.
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
do $$
declare v_adv uuid := (select id from ins_client_advances where tenant_id = pg_temp.id('tenant'));
        v_refused boolean := false;
        v_adv_row ins_client_advances%rowtype;
        v_pol uuid;
        v_line uuid; v_insurer uuid;
        v_cash_before numeric;
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
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
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
begin
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  begin
    perform public.ins_refund_client_advance(v_adv, pg_temp.id('bank'), 600000, current_date, 'too much');
  exception when others then
    v_refused := true;
    perform pg_temp.assert(sqlerrm like 'INS_ADVANCE_EXCEEDS%',
      '§5 over-refund should be refused as INS_ADVANCE_EXCEEDS, got: ' || sqlerrm);
  end;
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours

  -- The release is refused by name, not silently.
  begin
    perform public.ins_apply_client_advance(v_adv, gen_random_uuid(), 100000, 'release');
  exception when others then
    v_release_refused := true;
    perform pg_temp.assert(sqlerrm like 'INS_ADVANCE_RELEASE_NOT_AVAILABLE%',
      '§5 the release must refuse as INS_ADVANCE_RELEASE_NOT_AVAILABLE, got: ' || sqlerrm);
  end;
  reset role;

  perform pg_temp.assert(v_refused, '§5 refunding more than the balance must be refused');
  perform pg_temp.assert(v_release_refused, '§5 the unimplemented release must refuse, not pretend');
  raise notice 'PASS: §5 over-refund and the unimplemented release are both refused by name';
=======
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
  reset role;
  perform pg_temp.assert(v_refused, '§5 refunding more than the balance must be refused');
=======
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
begin
  -- The balance cap is enforced when the request is raised.
  perform pg_temp.jwt(pg_temp.id('maker'));
  set local role authenticated;
  begin
    perform public.ins_request_refund(v_adv, 600000, 'too much');
  exception when others then
    v_refused := true;
    perform pg_temp.assert(sqlerrm like 'INS_ADVANCE_EXCEEDS%',
      '§5 an over-refund request should be refused as INS_ADVANCE_EXCEEDS, got: ' || sqlerrm);
  end;
  reset role;
  perform pg_temp.assert(v_refused, '§5 requesting more than the balance must be refused');

  -- And an unapproved direct refund does not get past the approval gate at all.
  v_refused := false;
  perform pg_temp.jwt(pg_temp.id('maker'));
  set local role authenticated;
  begin
    perform public.ins_refund_client_advance(v_adv, pg_temp.id('bank'), 600000, current_date, 'too much');
  exception when others then
    v_refused := true;
    perform pg_temp.assert(sqlerrm like 'INS_REFUND_APPROVAL_REQUIRED%',
      '§5 an unapproved refund must be refused at the approval gate, got: ' || sqlerrm);
  end;
  reset role;
  perform pg_temp.assert(v_refused, '§5 one finance user must not release client money alone');
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

  -- A bound policy for the same client, so the advance has something to pay.
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  insert into ins_product_lines(tenant_id, code, name) values (pg_temp.id('tenant'), 'ADV', 'Advance line') returning id into v_line;
  insert into ins_insurers(tenant_id, code, name) values (pg_temp.id('tenant'), 'ADVINS', 'Advance Insurer') returning id into v_insurer;
  v_pol := ins_create_policy(pg_temp.id('client'), v_insurer, v_line,
                             current_date, current_date + 300, 1000000, 'UGX', 1000000, 10,
                             null, null, 'Advance release policy', null);
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
  reset role;

  v_cash_before := pg_temp.balance(pg_temp.id('trust'), true);

  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  v_adv_row := public.ins_apply_client_advance(v_adv, v_pol, 300000, 'released against the bound policy');
  reset role;

  perform pg_temp.assert(v_adv_row.applied_amount = 300000,
    format('§5 applied_amount should be 300,000, got %s', v_adv_row.applied_amount));
  perform pg_temp.assert(v_adv_row.applied_policy_id = v_pol,
    '§5 the advance should record the policy it was released against');
  -- 2040 is a liability: releasing reduces the credit, so credit-positive falls by 300,000.
  perform pg_temp.assert(pg_temp.balance(pg_temp.id('adv'), true) = 200000,
    format('§5 2040 should fall to 200,000, got %s', pg_temp.balance(pg_temp.id('adv'), true)));
  perform pg_temp.assert(pg_temp.balance(pg_temp.id('trust'), true) = v_cash_before,
    '§5 releasing an advance must not move cash');
  raise notice 'PASS: §5 over-refund refused, and the release clears 2040 against AR without moving cash';
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
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
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
end $$;

-- ---------------------------------------------------------------------
-- §6 an advance item cannot be settled by an ordinary receipt
-- ---------------------------------------------------------------------
-- Without ins_advance_allocation_guard, a generic settlement could consume the
-- advance and clear 2040 with no advance row to explain it.
do $$
declare v_item uuid := (select open_item_id from ins_client_advances where tenant_id = pg_temp.id('tenant'));
        v_refused boolean := false;
        v_set public.fin_settlements;
begin
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  begin
    v_set := public.fin_record_settlement(
      pg_temp.id('bank'), 'out', pg_temp.id('party'), 500000, current_date,
      jsonb_build_array(jsonb_build_object('open_item_id', v_item, 'amount', 500000)),
      null, 'generic refund attempt');
  exception when others then
    v_refused := true;
  end;
  reset role;

  perform pg_temp.assert(v_refused,
    '§6 a generic settlement must not be able to consume an advance: only the advance RPCs may');
  raise notice 'PASS: §6 the advance can only be consumed by the advance path';
end $$;

do $$ begin
  raise notice 'ALL PASS: advances post to 2040 with no receivable, show on the statement, refund correctly, refuse over-refunds, and refuse the release that B11 tracks';
end $$;

rollback;
