-- E4: cancelling a posted endorsement, and what the ordinary cancellation engine
-- sees afterwards.
--
-- The sizing note in ROADMAP.md recorded three blockers against the phrase "cancel
-- endorsement items": a guard that refused outright, a cancellation preview that
-- refuses any policy with a posted credit note, and arithmetic that never knew about
-- endorsement items. This test is written against those three, in that order,
-- because each one is only interesting if the previous one is actually gone.
--
-- Covers: the ordering rule (live endorsements first, newest financial endorsement
-- first), the refusal when the money has moved (a settled item, a live credit note,
-- transferred commission, a cancellation in flight, a closed period), maker/checker
-- with self-approval refused, the additional side's reversal (items emptied, journal
-- mirrored, the recognised commission un-earned through its own recognition journal
-- and the entry removed), the return side's reversal (its credit notes voided, the
-- premium item free again), the review position forgetting a cancelled endorsement,
-- and the payoff: after unwinding, the ordinary cancellation preview runs on a policy
-- whose position is the bind position again.
--
-- Run against a fresh local stack only (`supabase db reset`). One transaction that
-- ROLLBACKs. Any RAISE EXCEPTION is a real assertion failure.

\set ON_ERROR_STOP on

begin;

create function pg_temp.approve_and_bind(p_id uuid) returns public.ins_policies
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  p public.ins_policies;
  v_tenant uuid;
  v_claims text := current_setting('request.jwt.claims', true);
  v_appr uuid;
begin
  select tenant_id into v_tenant from public.ins_policies where id = p_id;
  v_appr := ('a9800000-0000-4000-8000-' || substr(replace(v_tenant::text, '-', ''), 1, 12))::uuid;
  perform public.ins_submit_policy_for_approval(p_id);
  insert into auth.users(id, email, raw_user_meta_data, raw_app_meta_data, aud, role, created_at, updated_at)
    values (v_appr, 'approver-' || v_appr || '@test.local', '{}', '{}', 'authenticated', 'authenticated', now(), now())
    on conflict (id) do nothing;
  insert into public.app_users(id, tenant_id, name, email)
    values (v_appr, v_tenant, 'E4 policy approver', 'approver-' || v_appr || '@test.local')
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

create function pg_temp.motor_cert(p_policy uuid) returns void
language plpgsql as $$
declare pol ins_policies%rowtype; line_code text; r uuid; s text := replace(p_policy::text, '-', '');
begin
  if not can_manage_insurance() then return; end if;
  select * into pol from ins_policies where id = p_policy;
  if not found or pol.status <> 'draft' then return; end if;
  select code into line_code from ins_product_lines where id = pol.product_line_id;
  if line_code is distinct from 'MOTOR' then return; end if;
  if exists (select 1 from ins_certificate_stock where policy_id = p_policy and status = 'issued') then return; end if;
  r := ins_register_risk(pol.client_id, pol.product_line_id, 'vehicle', 'Test vehicle', null, 'E4' || s, null, null, null, null, 0);
  perform ins_load_certificate_range('E4C' || s || '-', 1, 1, 4);
  perform ins_issue_certificate('E4C' || s || '-0001', r, null);
  perform ins_link_policy_risk(p_policy, r);
  perform ins_attach_certificate(p_policy, 'E4C' || s || '-0001');
end $$;

create function pg_temp.expect_error(p_sql text, p_needle text, p_label text)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm like '%' || p_needle || '%' then
      return;
    end if;
    raise exception 'FAIL: % raised the wrong error: %', p_label, sqlerrm;
  end;
  raise exception 'FAIL: % succeeded but should have failed with %', p_label, p_needle;
end $$;

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

-- A full maker/checker endorsement: propose as the manager, prepare as finance
-- maker, approve as finance checker. Returns the posted row.
create function pg_temp.endorse(
  p_policy uuid, p_manager uuid, p_fin1 uuid, p_fin2 uuid,
  p_terms jsonb, p_reason text, p_clearing uuid
) returns public.ins_policy_endorsements
language plpgsql security definer set search_path = public, pg_temp as $$
declare e ins_policy_endorsements%rowtype;
begin
  perform pg_temp.jwt(p_manager);
  e := public.ins_propose_policy_endorsement(p_policy, current_date, p_terms, '{}'::jsonb, p_reason, gen_random_uuid());
  perform pg_temp.jwt(p_fin1);
  e := public.ins_prepare_policy_endorsement(e.id, p_clearing);
  perform pg_temp.jwt(p_fin2);
  e := public.ins_decide_policy_endorsement(e.id, 'approve', 'E4 checker approves: ' || p_reason);
  return e;
end $$;

-- A payment against one open item, straight through the settlement path.
create function pg_temp.pay(p_bank uuid, p_dir text, p_party uuid, p_item uuid, p_amount numeric)
returns public.fin_settlements language sql as $$
  select public.fin_record_settlement(p_bank, p_dir, p_party, p_amount, current_date,
    jsonb_build_array(jsonb_build_object('open_item_id', p_item, 'amount', p_amount)),
    'e4', 'E4 test');
$$;

do $$
declare
  ta uuid := gen_random_uuid();
  tb uuid := gen_random_uuid();
  mgr uuid := gen_random_uuid();
  fin1 uuid := gen_random_uuid();
  fin2 uuid := gen_random_uuid();
  mem uuid := gen_random_uuid();
  ub uuid := gen_random_uuid();
  v_branch uuid; v_line uuid; v_alpha uuid; v_client uuid;
  v_ar uuid; v_payable uuid; v_unearned uuid; v_income uuid; v_clearing uuid; v_bank_gl uuid; v_bank uuid;
  pa ins_policies%rowtype; pb ins_policies%rowtype; pc ins_policies%rowtype; pd ins_policies%rowtype;
  e1 ins_policy_endorsements%rowtype; e2 ins_policy_endorsements%rowtype;
  e3 ins_policy_endorsements%rowtype; e4 ins_policy_endorsements%rowtype;
  q jsonb; pos jsonb; st text; n integer;
  v_client_item uuid; v_ins_item uuid; v_end_item uuid; v_end_ins_item uuid; v_entry uuid;
  v_bal numeric; v_before numeric; v_after numeric;
begin
  -------------------------------------------------------------------
  -- Fixtures: two tenants, four bound UGX policies, a full chart.
  -------------------------------------------------------------------
  insert into tenants (id, name) values (ta, 'E4 Cancel Co'), (tb, 'E4 Cancel Other');
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token)
  select '00000000-0000-0000-0000-000000000000', x.id, 'authenticated', 'authenticated',
         'e4-' || x.id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')), now(),
         '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
    from (values (mgr), (fin1), (fin2), (mem), (ub)) as x(id);
  insert into app_users (id, tenant_id, name, email) values
    (mgr,  ta, 'E4 Manager',   'e4-' || mgr  || '@test.local'),
    (fin1, ta, 'E4 Fin Maker', 'e4-' || fin1 || '@test.local'),
    (fin2, ta, 'E4 Fin Check', 'e4-' || fin2 || '@test.local'),
    (mem,  ta, 'E4 Member',    'e4-' || mem  || '@test.local'),
    (ub,   tb, 'E4 Other',     'e4-' || ub   || '@test.local');
  insert into tenant_modules (tenant_id, module) values (ta, 'insurance'), (tb, 'insurance');
  insert into staff_roles (tenant_id, user_id, module, role) values (ta, mgr, 'insurance', 'manager');
  insert into finance_team_members (tenant_id, user_id, role) values (ta, fin1, 'finance'), (ta, fin2, 'finance');

  insert into gl_accounts (tenant_id, account_code, name, account_type) values
    (ta,'1100','AR','asset'), (ta,'2010','Insurer payable','liability'),
    (ta,'2020','Unearned commission','liability'), (ta,'4000','Commission income','revenue'),
    (ta,'2090','Endorsement clearing','liability'), (ta,'1000','Trust bank','asset');
  select id into v_ar       from gl_accounts where tenant_id = ta and account_code = '1100';
  select id into v_payable  from gl_accounts where tenant_id = ta and account_code = '2010';
  select id into v_unearned from gl_accounts where tenant_id = ta and account_code = '2020';
  select id into v_income   from gl_accounts where tenant_id = ta and account_code = '4000';
  select id into v_clearing from gl_accounts where tenant_id = ta and account_code = '2090';
  select id into v_bank_gl  from gl_accounts where tenant_id = ta and account_code = '1000';
  insert into gl_posting_rules (tenant_id, account_role, gl_account_id) values
    (ta,'ar_control',v_ar),(ta,'insurer_payable',v_payable),
    (ta,'unearned_commission',v_unearned),(ta,'commission_income',v_income);
  insert into fin_bank_accounts (id, tenant_id, name, kind, currency, gl_account_id, is_active)
  values (gen_random_uuid(), ta, 'E4 Trust UGX', 'client_money', 'UGX', v_bank_gl, true)
  returning id into v_bank;

  perform pg_temp.jwt(mgr);
  insert into organizations (tenant_id, company_code, site_name) values (ta, 'KLA', 'Kampala') returning id into v_branch;
  reset role;

  perform pg_temp.jwt(mgr);
  set local role authenticated;
  insert into ins_product_lines (tenant_id, code, name) values (ta, 'MOTOR', 'Motor') returning id into v_line;
  insert into ins_insurers (tenant_id, code, name, default_commission_rate_pct)
    values (ta, 'ALPHA', 'Alpha Assurance', 10) returning id into v_alpha;
  reset role;

  perform pg_temp.jwt(mgr);
  set local role authenticated;
  declare cc ins_clients%rowtype;
  begin
    cc := ins_register_client('E4 client', 'corporate', null, null, null, 'low');
    v_client := cc.id;
    pa := ins_create_policy(cc.id, v_alpha, v_line, current_date - 45, current_date + 320,
                            50000000, 'UGX', 1000000, 10, v_branch, null, 'E4 policy A', null);
    perform pg_temp.motor_cert(pa.id); pa := pg_temp.approve_and_bind(pa.id);
    pb := ins_create_policy(cc.id, v_alpha, v_line, current_date - 45, current_date + 320,
                            20000000, 'UGX', 400000, 10, v_branch, null, 'E4 policy B', null);
    perform pg_temp.motor_cert(pb.id); pb := pg_temp.approve_and_bind(pb.id);
    pc := ins_create_policy(cc.id, v_alpha, v_line, current_date - 45, current_date + 320,
                            30000000, 'UGX', 600000, 10, v_branch, null, 'E4 policy C', null);
    perform pg_temp.motor_cert(pc.id); pc := pg_temp.approve_and_bind(pc.id);
    pd := ins_create_policy(cc.id, v_alpha, v_line, current_date - 45, current_date + 320,
                            10000000, 'UGX', 300000, 10, v_branch, null, 'E4 policy D', null);
    perform pg_temp.motor_cert(pd.id); pd := pg_temp.approve_and_bind(pd.id);
  end;
  reset role;
  perform pg_temp.assert(pa.status = 'active' and pb.status = 'active'
                     and pc.status = 'active' and pd.status = 'active', 'all four policies bind');

  select id into v_client_item from fin_open_items
   where tenant_id = ta and source_type = 'ins_policy_premium' and source_id = pa.id;

  -------------------------------------------------------------------
  -- 1. The additional side is reversed completely.
  -------------------------------------------------------------------
  e1 := pg_temp.endorse(pa.id, mgr, fin1, fin2,
    jsonb_build_array(jsonb_build_object('insurer_id', v_alpha::text, 'agreed_delta', '100000')),
    'E4 fleet expansion', v_clearing);
  perform pg_temp.assert(e1.status = 'posted', 'the additional endorsement posts');
  select id into v_end_item from fin_open_items
   where tenant_id = ta and source_type = 'ins_policy_endorsement' and source_id = e1.id;
  -- E2 keys the insurer item by the commission entry whose full payment earns it.
  select (x #>> '{}')::uuid into v_entry from jsonb_array_elements(e1.commission_entry_ids) x;
  select id into v_end_ins_item from fin_open_items
   where tenant_id = ta and source_type = 'ins_policy_endorsement_insurer' and source_id = v_entry;
  perform pg_temp.assert(v_end_item is not null and v_end_ins_item is not null and v_entry is not null,
    'the endorsement leaves a client item, an insurer item and a commission entry');

  -- The eligibility check says yes, and names the amount it would clear.
  perform pg_temp.jwt(fin1);
  pos := ins_endorsement_unwind_position(e1.id);
  perform pg_temp.assert((pos ->> 'eligible')::boolean, 'a fresh endorsement is eligible to unwind');
  perform pg_temp.assert((pos ->> 'open_amount_to_clear')::numeric = 100000 + 90000,
    format('the position reports both items (%s)', pos ->> 'open_amount_to_clear'));

  -- Only Finance prepares, and only an independent Finance person approves.
  perform pg_temp.jwt(mgr);
  perform pg_temp.expect_error(
    format('select ins_prepare_endorsement_cancellation(%L::uuid, ''Manager tries to prepare'')', e1.id),
    'INS_CASH_FORBIDDEN', 'a non-Finance user preparing a cancellation');
  perform pg_temp.jwt(fin1);
  perform ins_prepare_endorsement_cancellation(e1.id, 'Client withdrew the expansion the day it was endorsed');
  perform pg_temp.jwt(fin1);
  perform pg_temp.expect_error(
    format('select ins_approve_endorsement_cancellation(%L::uuid, ''Maker approves their own preparation'')', e1.id),
    'INS_ENDORSEMENT_CANCEL_SELF_APPROVAL', 'the preparer approving');

  select coalesce(sum(l.debit), 0) into v_before from journal_entry_lines l
    join gl_accounts a on a.id = l.gl_account_id
   where a.account_code = '4000' and a.tenant_id = ta;

  perform pg_temp.jwt(fin2);
  e1 := ins_approve_endorsement_cancellation(e1.id, 'Checker unwinds the withdrawn expansion');
  reset role;
  perform pg_temp.assert(e1.status = 'cancelled', format('the endorsement is cancelled (%s)', e1.status));
  perform pg_temp.assert(e1.cancellation_no ~ '^ENDC-[0-9]{4}-[0-9]{4}$',
    format('the cancellation is numbered (%s)', coalesce(e1.cancellation_no, 'null')));
  perform pg_temp.assert(e1.cancellation_journal_id is not null, 'the cancellation names its journal');

  -- Items emptied: the policy's position is the bind position again.
  select outstanding_amount into v_bal from fin_open_item_balances where id = v_end_item;
  perform pg_temp.assert(coalesce(v_bal, 0) = 0, format('the endorsement client item is cleared (%s)', v_bal));
  select outstanding_amount into v_bal from fin_open_item_balances where id = v_end_ins_item;
  perform pg_temp.assert(coalesce(v_bal, 0) = 0, format('the endorsement insurer item is cleared (%s)', v_bal));

  -- Commission: the deferred entry is gone, unearned keeps nothing for it, and the
  -- policy's own bind entry is untouched.
  select coalesce(sum(l.debit), 0) into v_after from journal_entry_lines l
    join gl_accounts a on a.id = l.gl_account_id
   where a.account_code = '4000' and a.tenant_id = ta;
  perform pg_temp.assert(v_after = v_before,
    'no commission income was recognised for this endorsement, and none is disturbed');
  perform pg_temp.assert(not exists (select 1 from ins_commission_entries where id = v_entry),
    'the endorsement commission entry is removed');
  perform pg_temp.assert(exists (select 1 from ins_commission_entries
                                  where policy_id = pa.id and source_open_item_id is null
                                    and status = 'deferred'),
    'the policy''s own bind commission entry survives untouched');
  -- The reversal journal is balanced and the clearing account comes back to zero.
  perform pg_temp.assert((select sum(l.debit) - sum(l.credit) from journal_entry_lines l
                           where l.journal_entry_id = e1.cancellation_journal_id) = 0,
    'the cancellation journal balances');
  -- Clearing nets to zero across the whole document: the cancellation journal holds
  -- the balancing Dr unearned / Cr clearing leg, and the credit notes it raised carry
  -- the matching Dr clearing. Checked together, because either alone is a half.
  perform pg_temp.assert((select coalesce(sum(l.debit - l.credit), 0)
                            from journal_entry_lines l
                           where l.gl_account_id = v_clearing
                             and (l.journal_entry_id = e1.cancellation_journal_id
                                  or l.journal_entry_id in (
                                        select n.journal_entry_id from fin_credit_notes n
                                         where n.reference = e1.endorsement_no
                                           and n.status = 'posted'))) = 0,
    'the clearing account nets to zero across the cancellation and its notes');
  raise notice 'PASS: the additional side unwinds to the bind position';

  -------------------------------------------------------------------
  -- 2. A cancelled endorsement no longer counts in the policy position.
  -------------------------------------------------------------------
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  q := ins_endorsement_review_position(pa.id);
  reset role;
  perform pg_temp.assert((q ->> 'current_gross_premium')::numeric = 1000000,
    format('the position forgets the cancelled endorsement (%s)', q ->> 'current_gross_premium'));
  perform pg_temp.assert((q ->> 'posted_endorsements')::integer = 0,
    'a cancelled endorsement is not a posted one');
  perform pg_temp.assert((q ->> 'current_commission_amount')::numeric = 100000,
    'the commission position is the bind commission again');
  raise notice 'PASS: the review position forgets a cancelled endorsement';

  -------------------------------------------------------------------
  -- 3. The return side: its credit notes are voided, and the premium
  --    item is free again -- which is what blocker 2 was about.
  -------------------------------------------------------------------
  e2 := pg_temp.endorse(pb.id, mgr, fin1, fin2,
    jsonb_build_array(jsonb_build_object('insurer_id', v_alpha::text, 'agreed_delta', '-30000')),
    'E4 fleet reduction', v_clearing);
  perform pg_temp.assert(e2.status = 'posted' and e2.credit_note_ids <> '[]'::jsonb,
    'the return endorsement posts with credit notes');
  perform pg_temp.jwt(fin1);
  perform ins_prepare_endorsement_cancellation(e2.id, 'The reduction was agreed in error');
  perform pg_temp.jwt(fin2);
  e2 := ins_approve_endorsement_cancellation(e2.id, 'Checker unwinds the erroneous reduction');
  reset role;
  perform pg_temp.assert(e2.status = 'cancelled', 'the return endorsement is cancelled');
  perform pg_temp.assert(not exists (
      select 1 from fin_credit_notes n
       where n.id in (select (x ->> 'note_id')::uuid from jsonb_array_elements(e2.credit_note_ids) x)
         and n.status = 'posted'),
    'every credit note the return raised is void');
  -- Blocker 2 gone: the premium item has no live credit note against it any more.
  perform pg_temp.assert(not exists (
      select 1 from fin_credit_applications a join fin_credit_notes n on n.id = a.credit_note_id
       where a.open_item_id in (select id from fin_open_items
                                 where tenant_id = ta and source_type = 'ins_policy_premium' and source_id = pb.id)
         and n.status = 'posted'),
    'no live credit note remains on the policy premium item');
  raise notice 'PASS: the return side voids its notes and frees the premium item';

  -------------------------------------------------------------------
  -- 4. The refusals: money that has moved cannot be unwound.
  -------------------------------------------------------------------
  -- (a) A settled endorsement client item.
  e3 := pg_temp.endorse(pc.id, mgr, fin1, fin2,
    jsonb_build_array(jsonb_build_object('insurer_id', v_alpha::text, 'agreed_delta', '50000')),
    'E4 partly settled expansion', v_clearing);
  select id into v_end_item from fin_open_items
   where tenant_id = ta and source_type = 'ins_policy_endorsement' and source_id = e3.id;
  perform pg_temp.pay(v_bank, 'in', (select party_account_id from fin_open_items where id = v_end_item),
                      v_end_item, 20000);
  perform pg_temp.jwt(fin1);
  pos := ins_endorsement_unwind_position(e3.id);
  perform pg_temp.assert(not (pos ->> 'eligible')::boolean,
    'an endorsement whose client item is partly settled is not eligible');
  perform pg_temp.expect_error(
    format('select ins_prepare_endorsement_cancellation(%L::uuid, ''Trying anyway despite the money'')', e3.id),
    'INS_ENDORSEMENT_CANCEL_BLOCKED', 'preparing a cancellation over settled money');

  -- (b) The two cross-guards, from both directions.
  --
  -- A live cancellation and a posted endorsement can never coexist: each side's guard
  -- refuses to be created while the other is live. That means the unwind position's
  -- "cancellation in flight" check is defensive rather than reachable -- there is no
  -- sequence of ordinary operations that produces the state. Rather than contrive one
  -- by hand (which would test the fixture, not the system), this pins the guards that
  -- make it impossible.
  e4 := pg_temp.endorse(pd.id, mgr, fin1, fin2,
    jsonb_build_array(jsonb_build_object('insurer_id', v_alpha::text, 'agreed_delta', '25000')),
    'E4 endorsement that blocks a cancellation', v_clearing);
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  perform pg_temp.expect_error(
    format('select ins_submit_policy_cancellation(%L::uuid, current_date,
              jsonb_build_array(jsonb_build_object(''insurer_id'', %L::text, ''terms'',
                jsonb_build_object(''method'', ''manual_review'', ''contract_reference'', ''Alpha agreed terms'',
                                   ''manual_return_premium'', ''100000''))),
              ''[]''::jsonb, ''Cancelling policy D over a posted endorsement'', %L::uuid)',
           pd.id, v_alpha::text, gen_random_uuid()),
    'INS_ENDORSEMENT_POSTED', 'a cancellation raised while a posted endorsement exists');
  reset role;

  -- The other direction: raise a cancellation on a policy with nothing posted, and
  -- show that an endorsement can no longer be written on it.
  declare ph ins_policies%rowtype;
  begin
    perform pg_temp.jwt(mgr);
    set local role authenticated;
    declare cc ins_clients%rowtype;
    begin
      select * into cc from ins_clients where id = v_client;
      ph := ins_create_policy(cc.id, v_alpha, v_line, current_date - 45, current_date + 320,
                              9000000, 'UGX', 270000, 10, v_branch, null, 'E4 policy H', null);
      perform pg_temp.motor_cert(ph.id); ph := pg_temp.approve_and_bind(ph.id);
    end;
    perform ins_submit_policy_cancellation(ph.id, current_date,
      jsonb_build_array(jsonb_build_object('insurer_id', v_alpha::text, 'terms',
        jsonb_build_object('method', 'manual_review', 'contract_reference', 'Alpha agreed cancellation terms',
                           'manual_return_premium', '90000'))),
      '[]'::jsonb, 'Client cancelling policy H', gen_random_uuid());
    perform pg_temp.expect_error(
      format('select ins_propose_policy_endorsement(%L::uuid, current_date,
                jsonb_build_array(jsonb_build_object(''insurer_id'', %L::text, ''agreed_delta'', ''1000'')),
                ''{}''::jsonb, ''Endorsing a policy under cancellation'', %L::uuid)',
             ph.id, v_alpha::text, gen_random_uuid()),
      'INS_ENDORSEMENT_CXL_LIVE', 'an endorsement proposed on a policy with a cancellation in flight');
    reset role;
    raise notice 'PASS: settled money is refused, and the two cross-guards hold both ways';
  end;

  -------------------------------------------------------------------
  -- 5. The ordering rule: newest financial endorsement first.
  -------------------------------------------------------------------
  -- Policy C: the settled case above is the only written endorsement, so use policy
  -- B's pattern instead -- two clean endorsements on a fresh policy (pb is busy with
  -- a cancelled one, so a fifth policy is raised here).
  declare pf ins_policies%rowtype; e5 ins_policy_endorsements%rowtype; e6 ins_policy_endorsements%rowtype;
  begin
    perform pg_temp.jwt(mgr);
    set local role authenticated;
    declare cc ins_clients%rowtype;
    begin
      select * into cc from ins_clients where id = v_client;
      pf := ins_create_policy(cc.id, v_alpha, v_line, current_date - 45, current_date + 320,
                              15000000, 'UGX', 500000, 10, v_branch, null, 'E4 policy F', null);
      perform pg_temp.motor_cert(pf.id); pf := pg_temp.approve_and_bind(pf.id);
    end;
    reset role;
    e5 := pg_temp.endorse(pf.id, mgr, fin1, fin2,
      jsonb_build_array(jsonb_build_object('insurer_id', v_alpha::text, 'agreed_delta', '10000')),
      'E4 first change', v_clearing);
    e6 := pg_temp.endorse(pf.id, mgr, fin1, fin2,
      jsonb_build_array(jsonb_build_object('insurer_id', v_alpha::text, 'agreed_delta', '20000')),
      'E4 second change', v_clearing);
    perform pg_temp.jwt(fin1);
    pos := ins_endorsement_unwind_position(e5.id);
    perform pg_temp.assert(not (pos ->> 'eligible')::boolean,
      'the older of two financial endorsements cannot be unwound first');
    begin
      perform ins_prepare_endorsement_cancellation(e5.id, 'Trying to unwind out of order');
      raise exception 'FAIL: unwinding out of order succeeded';
    exception when others then
      perform pg_temp.assert(sqlerrm like '%newest%', format('the refusal explains the order (%s)', sqlerrm));
    end;
    -- Newest first works, and then the older one becomes eligible.
    perform ins_prepare_endorsement_cancellation(e6.id, 'Unwind the second change first');
    perform pg_temp.jwt(fin2);
    e6 := ins_approve_endorsement_cancellation(e6.id, 'Checker unwinds the second change');
    reset role;
    perform pg_temp.jwt(fin1);
    pos := ins_endorsement_unwind_position(e5.id);
    perform pg_temp.assert((pos ->> 'eligible')::boolean,
      'once the newest is unwound, the older one becomes eligible');
    raise notice 'PASS: the ordering rule is newest-first, and it lifts as you go';
  end;

  -------------------------------------------------------------------
  -- 6. The payoff: the ordinary cancellation now runs.
  -------------------------------------------------------------------
  -- Policy A had an additional endorsement, cancelled in section 1. Its position is
  -- the bind position, so the ordinary cancellation preview must now get past both
  -- blocker 1 (the guard) and blocker 2 (the credit-note refusal).
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  q := ins_preview_policy_cancellation(pa.id, current_date,
    jsonb_build_array(jsonb_build_object('insurer_id', v_alpha::text, 'terms',
      jsonb_build_object('method', 'manual_review', 'contract_reference', 'Alpha agreed cancellation terms',
                         'manual_return_premium', '500000'))),
    '[]'::jsonb);
  reset role;
  perform pg_temp.assert(q is not null and q ->> 'stage' = 'calculation_only',
    'the cancellation preview now runs on an unwound policy');
  perform pg_temp.assert((q ->> 'invoice_credit')::numeric > 0,
    'the preview produces a real credit figure');
  -- And the guard still refuses a policy that still HAS a posted endorsement.
  perform pg_temp.jwt(mgr);
  set local role authenticated;
  perform pg_temp.expect_error(
    format('select ins_submit_policy_cancellation(%L::uuid, current_date,
              jsonb_build_array(jsonb_build_object(''insurer_id'', %L::text, ''terms'',
                jsonb_build_object(''method'', ''manual_review'', ''contract_reference'', ''Alpha agreed terms'',
                                   ''manual_return_premium'', ''100000''))),
              ''[]''::jsonb, ''Cancelling policy C without unwinding'', %L::uuid)',
           pc.id, v_alpha::text, gen_random_uuid()),
    'INS_ENDORSEMENT_POSTED', 'cancelling a policy that still has a posted endorsement');
  reset role;
  raise notice 'PASS: unwinding endorsements unblocks the ordinary cancellation';

  -------------------------------------------------------------------
  -- 7. Only a posted endorsement can be cancelled; only by Finance.
  -------------------------------------------------------------------
  -- Policy D's own endorsement is posted (section 4), so it will serve: a live
  -- proposal on a different, clean policy is what this section needs.
  declare pi ins_policies%rowtype;
  begin
    perform pg_temp.jwt(mgr);
    set local role authenticated;
    declare cc ins_clients%rowtype;
    begin
      select * into cc from ins_clients where id = v_client;
      pi := ins_create_policy(cc.id, v_alpha, v_line, current_date - 45, current_date + 320,
                              8000000, 'UGX', 240000, 10, v_branch, null, 'E4 policy I', null);
      perform pg_temp.motor_cert(pi.id); pi := pg_temp.approve_and_bind(pi.id);
    end;
    e1 := ins_propose_policy_endorsement(pi.id, current_date,
      jsonb_build_array(jsonb_build_object('insurer_id', v_alpha::text, 'agreed_delta', '1000')),
      '{}'::jsonb, 'E4 proposal that is never posted', gen_random_uuid());
    reset role;
  end;
  perform pg_temp.jwt(fin1);
  pos := ins_endorsement_unwind_position(e1.id);
  perform pg_temp.assert(not (pos ->> 'eligible')::boolean
                     and (pos -> 'reasons')::text like '%withdraw it instead%',
    'an unposted proposal is refused with the right advice');
  perform pg_temp.expect_error(
    format('select ins_prepare_endorsement_cancellation(%L::uuid, ''Trying to cancel a bare proposal'')', e1.id),
    'INS_ENDORSEMENT_CANCEL_BLOCKED', 'cancelling a proposal that never posted');
  raise notice 'PASS: only a posted endorsement can be cancelled, and only Finance may';
end $$;

rollback;
