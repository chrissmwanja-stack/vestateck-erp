-- =====================================================================
-- Commission recognised PRO RATA as premium is collected
-- (pro_rata_on_collection, accountant pack v2 decision 1)
-- =====================================================================
-- This file exists because of one line of the pack: "A CI check should not
-- equate a setting existing with the accounting behaviour actually working."
-- The register can only prove that
-- accounting_setting_definitions.allowed_values contains the mode. This proves
-- the ledger moves, and that it moves differently from the binary mode.
--
--   §1 the mode is selectable and is recorded as the effective mode at bind
--   §2 bind: commission is DEFERRED in 2020 and 4000 is untouched
--   §3 a receipt for 50% of the premium earns exactly 50% of the commission;
--      the rest stays deferred and the entry stays 'deferred', not 'earned'
--   §4 a second receipt for the other 50% earns the remainder and no more
--      (the pack's own worked example: 1,000,000 / 10% / 500,000 + 500,000)
--   §5 re-processing a receipt recognises nothing further (cumulative, not
--      incremental -- the bug a naive per-receipt calculator has)
--   §6 voiding the second receipt un-earns exactly what that receipt earned,
--      leaving the first half earned. The binary mode would reverse everything.
--
-- Money moves through the maker/checker cash-request RPCs, the only path client
-- money may take, and is voided through fin_void_settlement, which refuses a
-- bare status flip. Same fixtures and same flow as
-- test_ins_commission_on_premium_collection.sql, so the two files cannot
-- disagree about how a policy is bound or how cash is taken.
--
-- One transaction, rolled back. Run against a disposable database only.
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

-- submit -> approve by someone else -> bind, the same path the app uses.
create function pg_temp.approve_and_bind(p_id uuid) returns public.ins_policies
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  p public.ins_policies;
  v_tenant uuid;
  v_claims text := current_setting('request.jwt.claims', true);
  v_appr uuid;
begin
  select tenant_id into v_tenant from public.ins_policies where id = p_id;
  v_appr := ('b8800000-0000-4000-8000-' || substr(replace(v_tenant::text, '-', ''), 1, 12))::uuid;
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

create function pg_temp.one_share(p_policy uuid, p_insurer uuid, p_rate numeric)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into ins_policy_insurer_shares
    (tenant_id, policy_id, insurer_id, is_lead, share_pct, commission_rate_pct, reviewed)
  select tenant_id, p_policy, p_insurer, true, 100, p_rate, true
    from ins_policies where id = p_policy;
end $$;

create function pg_temp.balance(p_gl uuid) returns numeric
language sql security definer as $$
  -- Credit-positive: liabilities and income carry credits.
  select coalesce(sum(l.credit - l.debit), 0)
    from journal_entry_lines l
    join journal_entries je on je.id = l.journal_entry_id
   where je.tenant_id = (select v from ids where k = 'tenant')
     and l.gl_account_id = p_gl
$$;
grant execute on function pg_temp.balance(uuid) to authenticated;

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
  insert into tenants(id, name) values (ta, 'Pro-rata commission test');
  insert into auth.users(id, email, raw_user_meta_data, raw_app_meta_data, aud, role, created_at, updated_at)
    select u, 'pro-' || u || '@test.local', '{}', '{}', 'authenticated', 'authenticated', now(), now()
    from unnest(array[admin1, admin2, mgr, maker, checker]) u;
  insert into app_users(id, tenant_id, name, email)
    select u, ta, 'Pro-rata actor', 'pro-' || u || '@test.local'
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
    values (ta, 'PRO-TRUST', 'client_money', 'UGX', trust_gl) returning id into v_bank;

  -- §1 the tenant setting, through the real propose/approve workflow. This is
  -- also what makes the bind possible at all under decision 2: with no
  -- configured value the policy would now refuse to bind.
  perform pg_temp.jwt(admin1);
  set local role authenticated;
  v_setting := (public.acct_setting_propose(
    'ins.commission_recognition', 'pro_rata_on_collection', current_date,
    'insurer agreement: commission accrues as the client pays')).id;
  reset role;
  perform pg_temp.jwt(admin2);
  set local role authenticated;
  perform public.acct_setting_approve(v_setting);
  reset role;

  perform pg_temp.jwt(mgr);
  set local role authenticated;
  insert into ins_product_lines(tenant_id, code, name) values (ta, 'GEN', 'General') returning id into v_line;
  insert into ins_insurers(tenant_id, code, name) values (ta, 'PROINS', 'Pro-rata Insurer') returning id into v_insurer;
  v_client := (ins_register_client('Pro-rata client', 'corporate', null, null, null, 'low')).id;
  -- premium 1,000,000 UGX, commission 10% = 100,000: the pack's worked example,
  -- so the assertions below can be read against section 4.3 of the document.
  p := ins_create_policy(v_client, v_insurer, v_line, current_date, current_date + 365,
                         1000000, 'UGX', 1000000, 10, null, null, 'Pro rata earn', null);
  reset role;

  perform pg_temp.one_share(p.id, v_insurer, 10);
  p := pg_temp.approve_and_bind(p.id);
  reset role;

  create temp table ids (k text primary key, v uuid);
  insert into ids(k, v) values
    ('tenant', ta), ('policy', p.id), ('admin', admin2), ('mgr', mgr),
    ('maker', maker), ('checker', checker), ('bank', v_bank),
    ('unearned', unearned_gl), ('income', income_gl), ('ar', ar_gl), ('pay', pay_gl);
end $$;

grant select on ids to authenticated;
drop policy if exists ids_read on ids;

create function pg_temp.id(p_key text) returns uuid
language sql security definer set search_path = public, pg_temp as $$
  select v from ids where k = p_key
$$;
grant execute on function pg_temp.id(text) to authenticated;

-- Takes a premium payment through the maker/checker cash-request flow.
-- Cash may not move any other way, so a test that inserted a settlement
-- directly would be testing a state the application forbids.
create function pg_temp.take_premium(p_amount numeric, p_note text)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_req uuid;
begin
  perform pg_temp.jwt(pg_temp.id('maker'));
  set local role authenticated;
  v_req := (public.ins_submit_policy_cash_request(
             pg_temp.id('policy'), 'receipt', pg_temp.id('bank'),
             p_amount, current_date, gen_random_uuid(), 'receipt', p_note)).id;
  reset role;

  perform pg_temp.jwt(pg_temp.id('checker'));
  set local role authenticated;
  perform public.ins_decide_policy_cash_request(v_req, 'approve', null);
  reset role;

  return v_req;
end $$;

-- ---------------------------------------------------------------------
-- §1 the bind recorded the mode
-- ---------------------------------------------------------------------
do $$
declare s jsonb;
begin
  select accounting_config_snapshot into s from ins_policies where id = pg_temp.id('policy');
  perform pg_temp.assert(s ->> 'commission_recognition_effective' = 'pro_rata_on_collection',
    '§1 bind should record pro_rata_on_collection as the effective mode, got '
      || coalesce(s ->> 'commission_recognition_effective', '(none)'));
  raise notice 'PASS: §1 bind records pro_rata_on_collection as the effective mode';
end $$;

-- We can only take cash if the policy number is known to the cash request.
create temp table run (r1 uuid, r2 uuid, settle1 uuid, settle2 uuid, je1 uuid, je2 uuid);

-- ---------------------------------------------------------------------
-- §2 deferred at bind
-- ---------------------------------------------------------------------
do $$
declare v_status text;
begin
  select status into v_status from ins_commission_entries
   where policy_id = pg_temp.id('policy') and insurer_share_id is null and source_open_item_id is null;
  perform pg_temp.assert(v_status = 'deferred',
    '§2 the entry should be deferred at bind, got ' || coalesce(v_status, '(none)'));
  perform pg_temp.assert(pg_temp.balance(pg_temp.id('unearned')) = 100000,
    format('§2 unearned commission should hold 100,000 at bind, got %s', pg_temp.balance(pg_temp.id('unearned'))));
  perform pg_temp.assert(pg_temp.balance(pg_temp.id('income')) = 0,
    format('§2 no commission income at bind, got %s', pg_temp.balance(pg_temp.id('income'))));
  raise notice 'PASS: §2 bind defers the whole 100,000 in 2020 and leaves 4000 at zero';
end $$;

-- ---------------------------------------------------------------------
-- §3 a 50% receipt earns exactly 50%
-- ---------------------------------------------------------------------
do $$
declare v_req uuid; v_status text; v_cum numeric;
begin
  v_req := pg_temp.take_premium(500000, 'first half of premium');
  update run set r1 = v_req;

  select status, earned_cumulative into v_status, v_cum from ins_commission_entries
   where policy_id = pg_temp.id('policy') and insurer_share_id is null and source_open_item_id is null;

  perform pg_temp.assert(pg_temp.balance(pg_temp.id('income')) = 50000,
    format('§3 half the premium collected should earn 50,000, got %s', pg_temp.balance(pg_temp.id('income'))));
  perform pg_temp.assert(pg_temp.balance(pg_temp.id('unearned')) = 50000,
    format('§3 unearned should fall to 50,000, got %s', pg_temp.balance(pg_temp.id('unearned'))));
  perform pg_temp.assert(v_status = 'deferred',
    '§3 a partly-earned entry must stay deferred, got ' || coalesce(v_status, '(none)'));
  perform pg_temp.assert(coalesce(v_cum, 0) = 50000,
    format('§3 earned_cumulative should be 50,000, got %s', coalesce(v_cum::text, '(null)')));
  raise notice 'PASS: §3 a 50%% receipt earns 50,000 pro rata; 50,000 stays deferred and the entry is not earned';
end $$;

-- ---------------------------------------------------------------------
-- §4 the second 50% earns the remainder, and no more
-- ---------------------------------------------------------------------
do $$
declare v_req uuid; v_status text; v_cum numeric;
begin
  v_req := pg_temp.take_premium(500000, 'second half of premium');
  update run set r2 = v_req;

  select status, earned_cumulative into v_status, v_cum from ins_commission_entries
   where policy_id = pg_temp.id('policy') and insurer_share_id is null and source_open_item_id is null;

  perform pg_temp.assert(pg_temp.balance(pg_temp.id('income')) = 100000,
    format('§4 the full premium collected should earn the full 100,000, got %s', pg_temp.balance(pg_temp.id('income'))));
  perform pg_temp.assert(pg_temp.balance(pg_temp.id('unearned')) = 0,
    format('§4 unearned commission must empty to zero, got %s', pg_temp.balance(pg_temp.id('unearned'))));
  perform pg_temp.assert(v_status = 'earned',
    '§4 a fully-earned entry should be marked earned, got ' || coalesce(v_status, '(none)'));
  perform pg_temp.assert(coalesce(v_cum, 0) = 100000,
    format('§4 earned_cumulative should be 100,000, got %s', coalesce(v_cum::text, '(null)')));
  raise notice 'PASS: §4 the second receipt earns exactly the outstanding 50,000 and marks the entry earned';
end $$;

-- ---------------------------------------------------------------------
-- §5 re-processing recognises nothing further
-- ---------------------------------------------------------------------
do $$
declare v_income_before numeric; v_income_after numeric;
begin
  v_income_before := pg_temp.balance(pg_temp.id('income'));
  -- A no-op update on the settlement re-fires the AFTER UPDATE OF journal_entry_id
  -- trigger, the same way a replayed posting would.
  update fin_settlements set journal_entry_id = journal_entry_id
   where id in (select al.settlement_id from fin_allocations al
                 join fin_open_items i on i.id = al.open_item_id
                where i.source_type = 'ins_policy_premium'
                  and i.source_id = pg_temp.id('policy'));
  v_income_after := pg_temp.balance(pg_temp.id('income'));
  perform pg_temp.assert(v_income_after = v_income_before,
    format('§5 re-firing must not recognise again: %s -> %s', v_income_before, v_income_after));
  perform pg_temp.assert(pg_temp.balance(pg_temp.id('unearned')) = 0,
    format('§5 re-firing must not drive unearned negative, got %s', pg_temp.balance(pg_temp.id('unearned'))));
  raise notice 'PASS: §5 re-processing recognises nothing (the target is cumulative, not incremental)';
end $$;

-- ---------------------------------------------------------------------
-- §6 voiding the SECOND receipt un-earns only its half
-- ---------------------------------------------------------------------
do $$
declare v_settle uuid; v_claims text := current_setting('request.jwt.claims', true);
        v_status text; v_cum numeric;
begin
  -- The second receipt is the one that covered the balance.
  select al.settlement_id into v_settle
    from fin_allocations al
    join fin_open_items i on i.id = al.open_item_id
   where i.source_type = 'ins_policy_premium'
     and i.source_id = pg_temp.id('policy')
     and al.amount = 500000
   order by al.created_at desc
   limit 1;

  perform pg_temp.jwt(pg_temp.id('checker'));
  set local role authenticated;
  perform public.fin_void_settlement(v_settle, 'second receipt returned unpaid');
  reset role;
  perform set_config('request.jwt.claims', coalesce(v_claims, ''), true);

  perform pg_temp.assert((select status from fin_settlements where id = v_settle) = 'void',
    '§6 fixture: the settlement should be void');

  select status, earned_cumulative into v_status, v_cum from ins_commission_entries
   where policy_id = pg_temp.id('policy') and insurer_share_id is null and source_open_item_id is null;

  perform pg_temp.assert(pg_temp.balance(pg_temp.id('income')) = 50000,
    format('§6 voiding the second receipt should leave 50,000 earned (the first half), got %s',
           pg_temp.balance(pg_temp.id('income'))));
  perform pg_temp.assert(pg_temp.balance(pg_temp.id('unearned')) = 50000,
    format('§6 unearned should be restored to 50,000, got %s', pg_temp.balance(pg_temp.id('unearned'))));
  perform pg_temp.assert(v_status = 'deferred',
    '§6 a partly un-earned entry must return to deferred, got ' || coalesce(v_status, '(none)'));
  perform pg_temp.assert(coalesce(v_cum, 0) = 50000,
    format('§6 earned_cumulative should fall to 50,000, got %s', coalesce(v_cum::text, '(null)')));
  raise notice 'PASS: §6 voiding one receipt reverses exactly what it earned, not the whole entry';
end $$;

do $$ begin
  raise notice 'ALL PASS: pro_rata_on_collection earns in proportion to premium collected, is idempotent, and reverses only what a receipt earned';
end $$;

rollback;
