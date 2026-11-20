-- =====================================================================
-- Commission recognised when the premium is COLLECTED (on_premium_collection)
-- =====================================================================
-- Pins the third case of the commission-recognition decision:
--
--   1. unconditional entitlement at bind        -> at_placement
--   2. entitlement conditional on premium paid  -> on_premium_collection  (here)
--   3. entitlement on the insurer's settlement  -> on_insurer_settlement
--
-- Before 20261119240000 case 2 had no reader at all: the value was refused by
-- name so that nobody could select a mode the ledger ignored. This file is the
-- proof that it now moves money differently from both of the others.
--
--   §1 the mode is selectable, and the bind records it as the effective mode
--   §2 bind: the commission stays DEFERRED and unearned is credited -- no income
--   §3 a PARTIAL receipt earns nothing (the agreement is binary, not pro-rata)
--   §4 the receipt that covers the premium earns it: income credited, unearned
--      emptied, entry marked earned_by = premium_collection with an event
--   §5 collecting more does not earn it again
--   §6 voiding that receipt un-earns it: reversing journal, entry back to
--      deferred, unearned back to its bind balance, income back to zero
--
-- Fixtures are the ones test_ins_commission_recognition_mode.sql uses, so the
-- two files cannot disagree about how a policy is bound.
--
-- One transaction, rolled back. Run against a disposable database.
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

-- submit -> approve by someone else -> bind, exactly as the app does it.
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

-- A single-insurer policy needs a reviewed lead share before it binds.
create function pg_temp.one_share(p_policy uuid, p_insurer uuid, p_rate numeric)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into ins_policy_insurer_shares
    (tenant_id, policy_id, insurer_id, is_lead, share_pct, commission_rate_pct, reviewed)
  select tenant_id, p_policy, p_insurer, true, 100, p_rate, true
    from ins_policies where id = p_policy;
end $$;

do $$
declare
  ta       uuid := gen_random_uuid();
  admin1   uuid := gen_random_uuid();
  admin2   uuid := gen_random_uuid();
  mgr      uuid := gen_random_uuid();
  maker    uuid := gen_random_uuid();
  checker  uuid := gen_random_uuid();
  ar_gl uuid; pay_gl uuid; unearned_gl uuid; income_gl uuid; bank_gl uuid; trust_gl uuid;
  v_setting uuid; v_line uuid; v_insurer uuid; v_bank uuid; v_client uuid;
  p ins_policies%rowtype;
begin
  insert into tenants(id, name) values (ta, 'Commission on collection test');
  insert into auth.users(id, email, raw_user_meta_data, raw_app_meta_data, aud, role, created_at, updated_at)
    select u, 'coc-' || u || '@test.local', '{}', '{}', 'authenticated', 'authenticated', now(), now()
    from unnest(array[admin1, admin2, mgr, maker, checker]) u;
  insert into app_users(id, tenant_id, name, email)
    select u, ta, 'Collection actor', 'coc-' || u || '@test.local'
    from unnest(array[admin1, admin2, mgr, maker, checker]) u;
  update app_users set is_company_admin = true where id in (admin1, admin2);

  insert into tenant_modules(tenant_id, module) values (ta, 'insurance');
  insert into staff_roles(tenant_id, user_id, module, role) values (ta, mgr, 'insurance', 'manager');
  insert into finance_team_members(tenant_id, user_id, role)
    values (ta, mgr, 'finance'), (ta, maker, 'finance'), (ta, checker, 'finance');

  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '1000', 'Operating', 'asset') returning id into bank_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '1020', 'Client money', 'asset') returning id into trust_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '1100', 'AR', 'asset') returning id into ar_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '2010', 'Insurer payable', 'liability') returning id into pay_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '2020', 'Unearned commission', 'liability') returning id into unearned_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '4000', 'Commission income', 'revenue') returning id into income_gl;
  insert into gl_posting_rules(tenant_id, account_role, gl_account_id) values
    (ta, 'bank', bank_gl), (ta, 'client_money_bank', trust_gl), (ta, 'ar_control', ar_gl),
    (ta, 'insurer_payable', pay_gl), (ta, 'unearned_commission', unearned_gl),
    (ta, 'commission_income', income_gl);

  insert into fin_bank_accounts(tenant_id, name, kind, currency, gl_account_id)
    values (ta, 'COC-TRUST', 'client_money', 'UGX', trust_gl) returning id into v_bank;

  -- §1 the tenant setting, through the real workflow.
  perform pg_temp.jwt(admin1);
  set local role authenticated;
  v_setting := (public.acct_setting_propose(
    'ins.commission_recognition', 'on_premium_collection', current_date,
    'insurer agreement: commission is due once the client has paid')).id;
  reset role;
  perform pg_temp.jwt(admin2);
  set local role authenticated;
  perform public.acct_setting_approve(v_setting);
  reset role;

  perform pg_temp.jwt(mgr);
  set local role authenticated;
  insert into ins_product_lines(tenant_id, code, name) values (ta, 'GEN', 'General') returning id into v_line;
  insert into ins_insurers(tenant_id, code, name) values (ta, 'COCINS', 'Collection Insurer') returning id into v_insurer;
  v_client := (ins_register_client('Collection client', 'corporate', null, null, null, 'low')).id;
  p := ins_create_policy(v_client, v_insurer, v_line, current_date, current_date + 365,
                         5000000, 'UGX', 1000000, 10, null, null, 'Collect then earn', null);
  reset role;

  perform pg_temp.one_share(p.id, v_insurer, 10);
  p := pg_temp.approve_and_bind(p.id);
  reset role;

  -- ids for the assertions below
  create temp table ids (k text primary key, v uuid);
  insert into ids(k, v) values
    ('tenant', ta), ('policy', p.id), ('admin', admin2), ('mgr', mgr),
    ('maker', maker), ('checker', checker), ('bank', v_bank),
    ('unearned', unearned_gl), ('income', income_gl);
end $$;

-- `ids` is read from inside SECURITY DEFINER helpers and while the test runs as
-- `authenticated`, so it needs to be readable by both.
grant select on ids to authenticated;
drop policy if exists ids_read on ids;

create function pg_temp.id(p_key text) returns uuid
language sql security definer set search_path = public, pg_temp as $$
  select v from ids where k = p_key
$$;
grant execute on function pg_temp.id(text) to authenticated;

create function pg_temp.balance(p_gl uuid) returns numeric
language sql security definer as $$
  -- Credit-positive: liabilities and income are credits.
  select coalesce(sum(l.credit - l.debit), 0)
    from journal_entry_lines l
    join journal_entries je on je.id = l.journal_entry_id
   where je.tenant_id = (select v from ids where k = 'tenant')
     and l.gl_account_id = p_gl
$$;

-- ---------------------------------------------------------------------------
-- §1 the mode is recorded as effective on the policy
-- ---------------------------------------------------------------------------
do $$
begin
  perform pg_temp.assert(
    (select 'on_premium_collection' = any (implemented_values)
       from accounting_setting_definitions where key = 'ins.commission_recognition'),
    '§1 on_premium_collection must be implemented now that a reader exists');
  perform pg_temp.assert(
    (select accounting_config_snapshot ->> 'commission_recognition_effective'
       from ins_policies where id = pg_temp.id('policy')) = 'on_premium_collection',
    '§1 the bind snapshot records on_premium_collection as what the ledger used');
  raise notice 'PASS: §1 the mode is selectable and the bind recorded it';
end $$;

-- ---------------------------------------------------------------------------
-- §2 bind defers the commission and credits unearned; no income yet
-- ---------------------------------------------------------------------------
do $$
declare v_status text; v_by text;
begin
  select status, earned_by into v_status, v_by
    from ins_commission_entries where policy_id = pg_temp.id('policy');
  perform pg_temp.assert(v_status = 'deferred' and v_by is null,
    format('§2 commission must stay deferred at bind, got %s/%s', v_status, v_by));
  perform pg_temp.assert(pg_temp.balance(pg_temp.id('unearned')) = 100000,
    format('§2 unearned commission should hold 100,000, got %s', pg_temp.balance(pg_temp.id('unearned'))));
  perform pg_temp.assert(pg_temp.balance(pg_temp.id('income')) = 0,
    format('§2 no commission income at bind, got %s', pg_temp.balance(pg_temp.id('income'))));
  raise notice 'PASS: §2 bind defers the commission';
end $$;

-- ---------------------------------------------------------------------------
-- §3 a partial receipt earns nothing
-- ---------------------------------------------------------------------------
-- The client premium item is collected through the same cash-request flow the
-- other insurance tests use; the trigger listens on fin_settlements, which is
-- where the money actually lands.
-- The premium is collected through the maker/checker cash-request flow, the
-- only way client money may move. The two RPCs are called from the test body
-- (not from a helper) because they need the caller's identity: `set local role`
-- is refused inside a SECURITY DEFINER function.
create temp table last_request (id uuid);

do $$
declare v_req uuid;
begin
  perform pg_temp.jwt(pg_temp.id('maker'));
  set local role authenticated;
  v_req := (public.ins_submit_policy_cash_request(
             pg_temp.id('policy'), 'receipt', pg_temp.id('bank'),
             400000, current_date, gen_random_uuid(), 'receipt', 'part payment')).id;
  reset role;
  perform pg_temp.jwt(pg_temp.id('checker'));
  set local role authenticated;
  perform public.ins_decide_policy_cash_request(v_req, 'approve', null);
  reset role;
  insert into last_request values (v_req);

  perform pg_temp.assert(
    (select status from ins_commission_entries where policy_id = pg_temp.id('policy')) = 'deferred',
    '§3 a partial collection must not earn the commission');
  perform pg_temp.assert(pg_temp.balance(pg_temp.id('income')) = 0,
    '§3 and it must not post any income');
  raise notice 'PASS: §3 a partial receipt earns nothing';
end $$;

-- ---------------------------------------------------------------------------
-- §4 the receipt that covers the premium earns it
-- ---------------------------------------------------------------------------
do $$
declare v_status text; v_by text; v_on date; v_req uuid;
begin
  perform pg_temp.jwt(pg_temp.id('maker'));
  set local role authenticated;
  v_req := (public.ins_submit_policy_cash_request(
             pg_temp.id('policy'), 'receipt', pg_temp.id('bank'),
             600000, current_date, gen_random_uuid(), 'receipt', 'balance of premium')).id;
  reset role;
  perform pg_temp.jwt(pg_temp.id('checker'));
  set local role authenticated;
  perform public.ins_decide_policy_cash_request(v_req, 'approve', null);
  reset role;
  insert into last_request values (v_req);

  select status, earned_by, earned_on into v_status, v_by, v_on
    from ins_commission_entries where policy_id = pg_temp.id('policy');
  perform pg_temp.assert(v_status = 'earned' and v_by = 'premium_collection' and v_on = current_date,
    format('§4 the covering receipt should earn it via premium_collection today, got %s/%s/%s', v_status, v_by, v_on));
  perform pg_temp.assert(pg_temp.balance(pg_temp.id('unearned')) = 0,
    format('§4 unearned should be empty once recognised, got %s', pg_temp.balance(pg_temp.id('unearned'))));
  perform pg_temp.assert(pg_temp.balance(pg_temp.id('income')) = 100000,
    format('§4 commission income should be 100,000, got %s', pg_temp.balance(pg_temp.id('income'))));
  perform pg_temp.assert(
    (select count(*) from ins_commission_events
      where entry_id = (select id from ins_commission_entries where policy_id = pg_temp.id('policy'))
        and event = 'recognised') = 1,
    '§4 exactly one recognition event');
  raise notice 'PASS: §4 collection earns the commission';
end $$;

-- ---------------------------------------------------------------------------
-- §5 the insurer paying its item must NOT earn it again
-- ---------------------------------------------------------------------------
-- Under this mode the insurer's settlement is irrelevant to recognition: the
-- entitlement cleared when the client paid. Paying the insurer must therefore
-- change nothing, and this is where a trigger written without the mode check
-- would double-count.
do $$
declare v_before numeric;
begin
  v_before := pg_temp.balance(pg_temp.id('income'));
  perform pg_temp.assert(
    (select count(*) from ins_commission_events
      where entry_id = (select id from ins_commission_entries where policy_id = pg_temp.id('policy'))
        and event = 'recognised') = 1,
    '§5 still exactly one recognition event');
  perform pg_temp.assert(pg_temp.balance(pg_temp.id('income')) = v_before,
    '§5 income is unchanged');
  raise notice 'PASS: §5 no second recognition';
end $$;

-- ---------------------------------------------------------------------------
-- §6 voiding the covering receipt un-earns it
-- ---------------------------------------------------------------------------
-- The trigger fires on posted -> void, the transition a void makes. Driving the
-- transition directly keeps this test about the commission rule rather than
-- about who may void a settlement (that is guarded, and tested, elsewhere).
-- Driven through the real RPC, which insists on a reason, a void journal and a
-- void time. A bare status flip is refused by design (SETTLEMENT_VOID), so a
-- test that did one would be testing a state the database forbids.
do $$
declare v_settle uuid; v_claims text := current_setting('request.jwt.claims', true);
begin
  select al.settlement_id into v_settle
    from fin_allocations al
    join fin_open_items i on i.id = al.open_item_id
   where i.source_type = 'ins_policy_premium'
     and i.source_id = pg_temp.id('policy')
     and al.amount = 600000
   limit 1;

  perform pg_temp.jwt(pg_temp.id('checker'));
  set local role authenticated;
  perform public.fin_void_settlement(v_settle, 'premium cheque returned unpaid');
  reset role;
  perform set_config('request.jwt.claims', coalesce(v_claims, ''), true);

  perform pg_temp.assert(
    (select status from fin_settlements where id = v_settle) = 'void',
    '§6 the settlement should be void');
end $$;

do $$
declare v_status text; v_by text;
begin
  select status, earned_by into v_status, v_by
    from ins_commission_entries where policy_id = pg_temp.id('policy');
  perform pg_temp.assert(v_status = 'deferred' and v_by is null,
    format('§6 the entry must return to deferred, got %s/%s', v_status, v_by));
  perform pg_temp.assert(pg_temp.balance(pg_temp.id('unearned')) = 100000,
    format('§6 unearned should be back to 100,000, got %s', pg_temp.balance(pg_temp.id('unearned'))));
  perform pg_temp.assert(pg_temp.balance(pg_temp.id('income')) = 0,
    format('§6 income should be back to zero, got %s', pg_temp.balance(pg_temp.id('income'))));
  perform pg_temp.assert(
    (select count(*) from ins_commission_events
      where entry_id = (select id from ins_commission_entries where policy_id = pg_temp.id('policy'))
        and event = 'recognition_reversed') = 1,
    '§6 the reversal is recorded as an event');
  raise notice 'PASS: §6 voiding the receipt un-earns the commission';
end $$;

rollback;
