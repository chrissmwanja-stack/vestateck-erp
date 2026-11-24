-- =====================================================================
-- The three cancellation dates
-- Accountant pack v2, B4
-- =====================================================================
-- The pack's criteria, and which section proves each:
--
--   "a cancellation requested in period 1, effective in period 2 and settled in
--    period 3 posts to the settlement period while reporting its effective date"   §2-§4
--   "a backdated effective date without evidence is refused"                        §1
--
-- §1 also proves the refusal is not a blanket ban: with evidence recorded, the same
-- backdated date is accepted. A control that refuses everything is not a control.
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

do $$
declare
  ta       uuid := gen_random_uuid();
  mk1      uuid := gen_random_uuid();
  ck1      uuid := gen_random_uuid();
  v_line   uuid; v_insurer uuid; v_party uuid; v_bd uuid; v_client uuid; v_policy uuid;
  v_trust  uuid; v_ap uuid; v_ar uuid;
begin
  insert into tenants(id, name) values (ta, 'Cancellation dates test');
  insert into auth.users(id, email, raw_user_meta_data, raw_app_meta_data, aud, role, created_at, updated_at)
    select u, 'cxd-' || u || '@test.local', '{}', '{}', 'authenticated', 'authenticated', now(), now()
    from unnest(array[mk1, ck1]) u;
  insert into app_users(id, tenant_id, name, email)
    select u, ta, 'Cancellation actor', 'cxd-' || u || '@test.local'
    from unnest(array[mk1, ck1]) u;
  update app_users set is_company_admin = true where id in (mk1, ck1);

  insert into tenant_modules(tenant_id, module) values (ta, 'insurance');
  insert into finance_team_members(tenant_id, user_id, role)
    values (ta, mk1, 'finance'), (ta, ck1, 'finance');

  -- Settlement needs real GL: a client-money bank (asset), the ap_control posting
  -- role for the client refund, and the ar_control role for the insurer recovery.
  insert into gl_accounts(tenant_id, account_code, name, account_type)
    values (ta, '1020', 'Client money', 'asset') returning id into v_trust;
  insert into gl_accounts(tenant_id, account_code, name, account_type)
    values (ta, '2000', 'AP control', 'liability') returning id into v_ap;
  insert into gl_accounts(tenant_id, account_code, name, account_type)
    values (ta, '1100', 'AR control', 'asset') returning id into v_ar;
  insert into gl_posting_rules(tenant_id, account_role, gl_account_id)
    values (ta, 'client_money_bank', v_trust),
           (ta, 'ap_control', v_ap),
           (ta, 'ar_control', v_ar),
           (ta, 'insurer_payable', v_ap);

  insert into ins_product_lines(tenant_id, code, name) values (ta, 'MOT', 'Motor') returning id into v_line;
  insert into ins_insurers(tenant_id, code, name) values (ta, 'CXDINS', 'Dates Insurer') returning id into v_insurer;

  insert into accounts(tenant_id, name, account_type) values (ta, 'Dates client', 'client') returning id into v_party;
  insert into bd_clients(tenant_id, name) values (ta, 'Dates client') returning id into v_bd;
  insert into ins_clients(tenant_id, client_id, client_type, party_account_id)
    values (ta, v_bd, 'corporate', v_party) returning id into v_client;

  -- A policy running from the start of the year: cover exists to cancel.
  insert into ins_policies
    (tenant_id, policy_no, client_id, insurer_id, product_line_id, status,
     inception_date, expiry_date, currency, gross_premium, sum_insured,
     commission_rate_pct, transaction_type)
  values
    (ta, 'CXD-1', v_client, v_insurer, v_line, 'active',
     date '2026-01-01', date '2026-12-31', 'UGX', 12000000, 50000000, 10, 'new_business')
  returning id into v_policy;

  create temp table ids (k text primary key, v uuid);
  insert into ids(k, v) values ('tenant', ta), ('mk', mk1), ('ck', ck1),
    ('party', v_party), ('client', v_client), ('policy', v_policy),
    ('line', v_line), ('insurer', v_insurer), ('bd', v_bd),
    ('trust', v_trust), ('ap', v_ap), ('ar', v_ar);
end $$;

create function pg_temp.id(p_key text) returns uuid
language sql security definer set search_path = public, pg_temp as $$
  select v from pg_temp.ids where k = p_key
$$;
grant execute on function pg_temp.id(text) to authenticated;

-- Build a cancellation row directly. ins_submit_policy_cancellation needs a full
-- pricing preview; what B4 governs are the dates on the row and the guards around
-- them, so the row is inserted with a pinned proposed_at to stand for "requested in
-- period 1". This is the only way to pin the request date, because proposed_at
-- defaults to now().
create function pg_temp.make_cancellation(p_effective date, p_requested timestamptz)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid;
begin
  insert into ins_policy_cancellations
    (tenant_id, policy_id, request_key, reason, effective_date, insurer_terms,
     charge_refunds, proposed_by, proposed_at, calculation, status)
  values
    ((select v from ids where k = 'tenant'),
     (select v from ids where k = 'policy'),
     gen_random_uuid(),
     'client sold the vehicle',
     p_effective,
     '[]'::jsonb,
     '[]'::jsonb,
     (select v from ids where k = 'mk'),
     p_requested,
     '{}'::jsonb,
     'proposed')
  returning id into v_id;
  return v_id;
end $$;
grant execute on function pg_temp.make_cancellation(date, timestamptz) to authenticated;

-- ---------------------------------------------------------------------
-- §1 a backdated effective date with no evidence is refused
-- ---------------------------------------------------------------------
-- Requested 15 March, effective 1 February: cover stops six weeks before anyone asked.
do $$
declare v_id uuid; v_refused boolean := false;
begin
  v_id := pg_temp.make_cancellation(date '2026-02-01', timestamptz '2026-03-15 10:00+03');

  perform pg_temp.assert(
    (select effective_date < (proposed_at at time zone 'Africa/Kampala')::date
       from ins_policy_cancellations where id = v_id),
    '§1 the fixture must actually be backdated, or the rest of this section proves nothing');

  begin
    perform public.ins_cancellation_effective_evidence_check(v_id);
  exception when others then
    v_refused := true;
    perform pg_temp.assert(sqlerrm like 'INS_CANCELLATION_BACKDATED_NO_EVIDENCE%',
      '§1 a backdated date without evidence must be refused as INS_CANCELLATION_BACKDATED_NO_EVIDENCE, got: ' || sqlerrm);
  end;

  perform pg_temp.assert(v_refused,
    '§1 a backdated effective date with no evidence behind it must be refused');
  raise notice 'PASS: §1 backdating without evidence is refused, and the message says what to record';
end $$;

-- ---------------------------------------------------------------------
-- §2 evidence makes the same backdated date acceptable, and not before
-- ---------------------------------------------------------------------
do $$
declare v_id uuid;
begin
  v_id := pg_temp.make_cancellation(date '2026-02-01', timestamptz '2026-03-15 10:00+03');

  perform pg_temp.jwt(pg_temp.id('mk'));
  set local role authenticated;
  perform public.ins_record_cancellation_date_evidence(
    v_id, 'client letter', 'LTR-2026-0214', date '2026-02-14',
    'client wrote on 14 February asking for cover to stop from 1 February');
  reset role;

  -- Now the check passes, and it is the same date it refused a moment ago.
  perform public.ins_cancellation_effective_evidence_check(v_id);
  raise notice 'PASS: §2 recording dated evidence lets the identical backdated date through';

  -- Future-dated evidence is refused: notice the company did not have yet is not
  -- notice.
  perform pg_temp.jwt(pg_temp.id('mk'));
  set local role authenticated;
  begin
    perform public.ins_record_cancellation_date_evidence(
      v_id, 'client letter', 'LTR-FUTURE', current_date + 5, 'not yet written');
    raise exception 'FAIL: §2 future-dated evidence should be refused';
  exception when others then
    if sqlerrm not like 'INS_CANCELLATION_EVIDENCE_INPUT%' then raise; end if;
  end;
  reset role;
end $$;

-- ---------------------------------------------------------------------
-- §3 not backdated at all means no evidence needed
-- ---------------------------------------------------------------------
do $$
declare v_id uuid;
begin
  v_id := pg_temp.make_cancellation(date '2026-03-15', timestamptz '2026-03-15 10:00+03');
  perform public.ins_cancellation_effective_evidence_check(v_id);
  raise notice 'PASS: §3 a cancellation effective on the day it was requested needs nothing extra';
end $$;

-- ---------------------------------------------------------------------
-- §4 the period it posts to comes from the cash, not from the coverage date
-- ---------------------------------------------------------------------
-- Three dates, three different periods. This is the criterion the pack states
-- explicitly, and the failure it guards against is a cancellation posted to the month
-- cover stopped rather than the month the money settled.
do $$
declare
  v_id      uuid;
  v_request date; v_effective date; v_settle date;
  v_item    uuid;
  v_bank    uuid;
  v_party   uuid := pg_temp.id('party');
  v_adj     uuid;
  v_board   uuid;
begin
  v_id := pg_temp.make_cancellation(date '2026-02-01', timestamptz '2026-03-15 10:00+03');

  -- The client refund side: a payable item, which a client-money bank settles
  -- outbound.
  insert into fin_open_items
    (tenant_id, party_account_id, control_role, side, source_type, source_id,
     document_no, document_date, due_date, amount, currency, fx_rate,
     accounting_policy_version, description)
  values
    (pg_temp.id('tenant'), v_party, 'ap_control', 'payable',
     'ins_cancellation_client_refund', v_id, 'CXL-CXD-1',
     date '2026-04-20', date '2026-04-20', 1000000, 'UGX', 1, 1,
     'Client refund due: CXD-1')
  returning id into v_item;

  insert into fin_bank_accounts (tenant_id, name, kind, currency, gl_account_id)
    values (pg_temp.id('tenant'), 'CXD-TRUST', 'client_money', 'UGX', pg_temp.id('trust'))
  returning id into v_bank;

  -- Move the money on 20 April: period 3, two months after cover stopped. The cash
  -- guards require the moving function to declare itself, so it does.
  perform set_config('ins.via_rpc', 'on', true);
  perform public.platform_fin_record_settlement_impl(
    pg_temp.id('tenant'), v_bank, 'out', v_party, 1000000, date '2026-04-20',
    jsonb_build_array(jsonb_build_object('open_item_id', v_item, 'amount', 1000000)),
    'REFUND-CXD-1', 'cancellation refund');

  -- The insurer recovery side, which settles on ITS OWN date and through a different
  -- account: inbound, so an operating bank, and ar_control because the brokerage is
  -- collecting from the insurer.
  insert into ins_cancellation_insurer_adjustments
    (tenant_id, cancellation_id, insurer_id, return_premium, commission_clawback,
     pass_through_refund, total_insurer_credit, payable_credit, recovery_due,
     retained_commission, transferred_clawback_due)
  values
    (pg_temp.id('tenant'), v_id, pg_temp.id('insurer'), 300000, 30000, 0, 330000,
     330000, 330000, 0, 0)
  returning id into v_adj;

  insert into fin_open_items
    (tenant_id, party_account_id, control_role, side, source_type, source_id,
     document_no, document_date, due_date, amount, currency, fx_rate,
     accounting_policy_version, description)
  values
    (pg_temp.id('tenant'), v_party, 'ar_control', 'receivable',
     'ins_cancellation_insurer_recovery', v_adj, 'CXL-CXD-1-R',
     date '2026-04-05', date '2026-04-05', 330000, 'UGX', 1, 1,
     'Insurer recovery: CXD-1')
  returning id into v_item;

  insert into fin_bank_accounts (tenant_id, name, kind, currency, gl_account_id)
    select pg_temp.id('tenant'), 'CXD-OPS', 'operating', 'UGX', id
      from gl_accounts where tenant_id = pg_temp.id('tenant') and account_code = '1020'
  returning id into v_board;
  -- An operating account cannot sit on the client-money GL account, so give it one.
  update fin_bank_accounts set gl_account_id = pg_temp.id('ar')
   where id = v_board;

  perform set_config('ins.via_rpc', 'on', true);
  perform public.platform_fin_record_settlement_impl(
    pg_temp.id('tenant'), v_board, 'in', v_party, 330000, date '2026-04-05',
    jsonb_build_array(jsonb_build_object('open_item_id', v_item, 'amount', 330000)),
    'RECOVERY-CXD-1', 'cancellation insurer recovery');

  -- Before posting, the row has no settlement date: it is derived.
  perform pg_temp.assert(
    (select settlement_date is null from ins_policy_cancellations where id = v_id),
    '§4 settlement_date should be null until it is stamped at posting');

  -- The two sides settled ten days apart, so the period is not complete until the
  -- later one: 20 April, not 5 April.
  perform pg_temp.assert(
    public.ins_cancellation_settlement_date(v_id) = date '2026-04-20',
    format('§4 the settlement date must be the LATER of the two sides, got %s',
      public.ins_cancellation_settlement_date(v_id)));

  -- Post it: the guard stamps the settlement date from the cash.
  update ins_policy_cancellations
     set status = 'posted',
         prepared_by = pg_temp.id('mk'), prepared_at = now(),
         clearing_gl_account_id = pg_temp.id('trust'),
         checked_by = pg_temp.id('ck'), checked_at = now(),
         review_note = 'checked the refund against the insurer credit note',
         cancellation_no = 'CXL-CXD-1', posting_date = date '2026-04-20',
         cash_at_posting = '{}'::jsonb
   where id = v_id;

  select request_date, effective_date, settlement_date
    into v_request, v_effective, v_settle
    from public.ins_cancellation_dates(v_id);

  perform pg_temp.assert(v_effective = date '2026-02-01',
    format('§4 the effective date must still be reported as 1 February, got %s', v_effective));
  perform pg_temp.assert(v_settle = date '2026-04-20',
    format('§4 the settlement date must be 20 April, the later of the two cash dates, got %s', v_settle));
  perform pg_temp.assert(v_request = date '2026-03-15',
    format('§4 the request date must be 15 March, got %s', v_request));

  perform pg_temp.assert(v_effective < v_request and v_request < v_settle,
    '§4 the three dates must be three distinct dates in the order the pack describes');

  perform pg_temp.assert(
    (select effective_is_backdated from public.ins_cancellation_dates(v_id)),
    '§4 the row must report itself as backdated');
  perform pg_temp.assert(
    (select evidence_held from public.ins_cancellation_dates(v_id)) = false,
    '§4 no evidence was recorded for this one, and it must say so rather than assume');
  raise notice 'PASS: §4 it posts to the settlement period and still reports its coverage date';
end $$;

-- ---------------------------------------------------------------------
-- §5 a posted cancellation cannot be moved between periods afterwards
-- ---------------------------------------------------------------------
do $$
declare v_id uuid; v_refused boolean := false;
begin
  select c.id into v_id from ins_policy_cancellations c
   where c.tenant_id = pg_temp.id('tenant') and c.status = 'posted' limit 1;

  begin
    update ins_policy_cancellations
       set settlement_date = date '2026-05-31'
     where id = v_id;
  exception when others then
    v_refused := true;
    perform pg_temp.assert(sqlerrm like 'INS_CANCELLATION_DATES_IMMUTABLE%',
      '§5 moving a posted cancellation must be refused as INS_CANCELLATION_DATES_IMMUTABLE, got: ' || sqlerrm);
  end;
  perform pg_temp.assert(v_refused,
    '§5 a posted cancellation cannot be relocated into another period');

  -- And evidence cannot be attached after the fact to justify a date already posted.
  perform pg_temp.jwt(pg_temp.id('mk'));
  set local role authenticated;
  v_refused := false;
  begin
    perform public.ins_record_cancellation_date_evidence(
      v_id, 'client letter', 'LTR-LATE', current_date, 'added afterwards');
  exception when others then
    v_refused := true;
    perform pg_temp.assert(sqlerrm like 'INS_CANCELLATION_EVIDENCE_STATE%',
      '§5 evidence added after posting must be refused, got: ' || sqlerrm);
  end;
  reset role;
  perform pg_temp.assert(v_refused,
    '§5 a justification cannot be added after the cancellation has posted');
  raise notice 'PASS: §5 posted dates are frozen and evidence cannot be back-filled';
end $$;

<<<<<<< ours
=======
-- ---------------------------------------------------------------------
-- §6 the real submission path, which every other section above skips
-- ---------------------------------------------------------------------
-- §§1-5 insert the cancellation row directly, because ins_submit_policy_cancellation
-- needs a full pricing preview and they are testing the dates, not the submission. That
-- is exactly why the defect below survived: the check was only ever exercised on a row
-- that already existed. Here the submission function itself is driven end to end.
--
-- The defect: the refusal was raised AFTER the insert. The exception rolled the
-- proposal back with it, so the message's instruction -- record evidence, then retry --
-- named a cancellation that no longer existed, and the retry was refused again. A
-- backdated cancellation could not be proposed at all, in any number of attempts.
--
-- This section needs its own policy: §1-§5 leave a live proposal (and a posted
-- cancellation) against the fixture policy, and ins_submit_policy_cancellation
-- correctly refuses a second live proposal on the same policy.
do $$
declare
  v_policy uuid;
  v_key    uuid := gen_random_uuid();
  v_id     uuid;
  v_eff    date;
  -- One set of terms per original insurer share, which for an un-snapshotted policy
  -- is the single policy insurer. method is explicit, so the submission's
  -- configured-default step leaves it alone.
  v_terms  jsonb;
begin
  insert into ins_policies
    (tenant_id, policy_no, client_id, insurer_id, product_line_id, status,
     inception_date, expiry_date, currency, gross_premium, sum_insured,
     commission_rate_pct, transaction_type)
  values
    (pg_temp.id('tenant'), 'CXD-SUBMIT-1', pg_temp.id('client'), pg_temp.id('insurer'),
     pg_temp.id('line'), 'active', date '2026-01-01', date '2026-12-31', 'UGX',
     6000000, 20000000, 10, 'new_business')
  returning id into v_policy;

  -- Six weeks back: backdated by any measure, and in the past so the submission gate
  -- (effective date < today) applies.
  v_eff := public.ins_local_today() - 42;

  v_terms := jsonb_build_array(jsonb_build_object(
    'insurer_id', pg_temp.id('insurer')::text,
    'terms', jsonb_build_object(
      'method', 'manual_review',
      'contract_reference', 'pro-rata cancellation per policy wording',
      'manual_return_premium', '100000')));

  perform pg_temp.jwt(pg_temp.id('mk'));
  set local role authenticated;

  -- 6a. A backdated submission with no evidence is refused...
  begin
    perform public.ins_submit_policy_cancellation(
      v_policy, v_eff, v_terms, '[]'::jsonb,
      'client sold the vehicle', v_key);
    raise exception 'FAIL: §6 a backdated submission with no evidence must be refused';
  exception when others then
    if sqlerrm not like 'INS_CANCELLATION_BACKDATED_NO_EVIDENCE%' then raise; end if;
    perform pg_temp.assert(sqlerrm like '%ins_record_cancellation_date_evidence%',
      '§6 the refusal must name the function that fixes it, got: ' || sqlerrm);
  end;

  -- ...and the rollback is the point: nothing was created.
  perform pg_temp.assert(
    not exists (select 1 from public.ins_policy_cancellations
                 where policy_id = v_policy and request_key = v_key),
    '§6 a refused submission must leave no proposal behind');

  -- 6b. So the evidence is captured BEFORE the submission, against the same key.
  perform public.ins_record_cancellation_date_evidence(
    null, 'client letter', 'LTR-2026-0611', public.ins_local_today() - 45,
    'client wrote asking for cover to stop', v_key);

  perform pg_temp.assert(
    exists (select 1 from public.ins_cancellation_date_evidence
             where tenant_id = pg_temp.id('tenant') and request_key = v_key
               and cancellation_id is null),
    '§6 evidence captured ahead of a proposal must be held unattached');

  -- 6c. The same submission, unchanged, now succeeds -- and consumes the evidence.
  v_id := (public.ins_submit_policy_cancellation(
    v_policy, v_eff, v_terms, '[]'::jsonb,
    'client sold the vehicle', v_key)).id;

  perform pg_temp.assert(
    (select count(*) from public.ins_cancellation_date_evidence
      where tenant_id = pg_temp.id('tenant') and cancellation_id = v_id
        and request_key is null and the_date = v_eff) = 1,
    '§6 the submission must attach the pending evidence to the new cancellation and stamp it with the effective date');

  perform pg_temp.assert(
    (select status from public.ins_policy_cancellations where id = v_id) = 'proposed',
    '§6 a backdated submission with evidence lands as a proposal for Finance');

  -- Retrying with the same key returns the same proposal rather than making a second.
  perform pg_temp.assert(
    (public.ins_submit_policy_cancellation(
       v_policy, v_eff, v_terms, '[]'::jsonb,
       'client sold the vehicle', v_key)).id = v_id,
    '§6 a retry with the same request key must return the same proposal');

  -- And the audit trail has its first event, which the first cut of this migration lost.
  perform pg_temp.assert(
    exists (select 1 from public.ins_cancellation_events
             where cancellation_id = v_id and event = 'proposed'),
    '§6 the proposal must record its proposed event');

  reset role;
  raise notice 'PASS: §6 a backdated cancellation is proposable, via evidence captured before the submission';
end $$;

>>>>>>> theirs
do $$ begin
  raise notice 'ALL PASS: three dates are recorded separately, a backdated effective date needs evidence, and the period comes from the cash';
end $$;

rollback;
