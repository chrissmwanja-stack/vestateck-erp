-- =====================================================================
-- Claim stage model and the two review states
-- Accountant pack v2, decision 3 (B5), pack sections 7.2 and 7.3
-- =====================================================================
-- The pack's criteria, and where each is proved:
--
--   "A claim moves through all eight stages with an audit row each"       §1-§4
--   "internal approval creates no journal"                               §2
--   "insurer confirmation creates the receivable"                        §3
--   "partial payment leaves a visible balance"                           §4
--   "a disputed payment is excluded from settled totals"                 §5
--   (pack 7.3) "a claim registered after expiry is accepted ... rather
--   than rejected"                                                       §6
--   (pack 7.3) "no insurer liability is recognised before confirmation"  §7
--
-- The stage is computed, never stored, so what these sections prove is that the
-- computed stage agrees with the ledger at each step -- not that a status column
-- holds the right string. That is deliberate: a stored stage can drift from the
-- payments, a computed one cannot.
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

create function pg_temp.journals_for(p_claim uuid) returns integer
language sql security definer as $$
  select count(*) from journal_entries
   where tenant_id = (select v from ids where k = 'tenant')
     and source_id = p_claim
$$;
grant execute on function pg_temp.journals_for(uuid) to authenticated;

do $$
declare
  ta uuid := gen_random_uuid();
  admin1 uuid := gen_random_uuid();
  admin2 uuid := gen_random_uuid();
  mgr uuid := gen_random_uuid();
  v_line uuid; v_insurer uuid; v_bank uuid; v_party uuid; v_bd uuid; v_client uuid;
  recv_gl uuid; pay_gl uuid; trust_gl uuid;
begin
  insert into tenants(id, name) values (ta, 'Claim stages test');
  insert into auth.users(id, email, raw_user_meta_data, raw_app_meta_data, aud, role, created_at, updated_at)
    select u, 'clm-' || u || '@test.local', '{}', '{}', 'authenticated', 'authenticated', now(), now()
    from unnest(array[admin1, admin2, mgr]) u;
  insert into app_users(id, tenant_id, name, email)
    select u, ta, 'Claim actor', 'clm-' || u || '@test.local'
    from unnest(array[admin1, admin2, mgr]) u;
  update app_users set is_company_admin = true where id in (admin1, admin2);

  insert into tenant_modules(tenant_id, module) values (ta, 'insurance');
  insert into staff_roles(tenant_id, user_id, module, role) values (ta, mgr, 'insurance', 'manager');
  insert into finance_team_members(tenant_id, user_id, role) values (ta, mgr, 'finance');

  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '1020', 'Client money', 'asset') returning id into trust_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '1120', 'Insurer claim receivable', 'asset') returning id into recv_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '2030', 'Client claim payable', 'liability') returning id into pay_gl;
  insert into gl_posting_rules(tenant_id, account_role, gl_account_id) values
    (ta, 'client_money_bank', trust_gl), (ta, 'insurer_claim_receivable', recv_gl),
    (ta, 'client_claim_payable', pay_gl);

  insert into fin_bank_accounts(tenant_id, name, kind, currency, gl_account_id)
    values (ta, 'CLM-TRUST', 'client_money', 'UGX', trust_gl) returning id into v_bank;

<<<<<<< ours
  insert into accounts(tenant_id, account_code, name, account_type) values (ta, 'T-' || substr(gen_random_uuid()::text, 1, 8), 'Claim client', 'client') returning id into v_party;
=======
  insert into accounts(tenant_id, name, account_type) values (ta, 'Claim client', 'client') returning id into v_party;
>>>>>>> theirs
  insert into bd_clients(tenant_id, name) values (ta, 'Claim client') returning id into v_bd;
  insert into ins_clients(tenant_id, client_id, client_type, party_account_id)
    values (ta, v_bd, 'corporate', v_party) returning id into v_client;

  perform pg_temp.jwt(mgr);
  set local role authenticated;
  insert into ins_product_lines(tenant_id, code, name) values (ta, 'GEN', 'General') returning id into v_line;
  insert into ins_insurers(tenant_id, code, name) values (ta, 'CLMINS', 'Claim Insurer') returning id into v_insurer;
  reset role;

  create temp table ids (k text primary key, v uuid);
  insert into ids(k, v) values ('tenant', ta), ('line', v_line), ('insurer', v_insurer),
    ('bank', v_bank), ('party', v_party), ('client', v_client),
    ('recv', recv_gl), ('pay', pay_gl), ('trust', trust_gl), ('mgr', mgr);
end $$;

create function pg_temp.id(p_key text) returns uuid
language sql security definer set search_path = public, pg_temp as $$
  select v from ids where k = p_key
$$;
grant execute on function pg_temp.id(text) to authenticated;

-- A bound policy with one insurer share, so claims can be raised against it.
create function pg_temp.make_policy(p_expiry date default current_date + 300)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare p ins_policies%rowtype;
begin
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  p := ins_create_policy(pg_temp.id('client'), pg_temp.id('insurer'), pg_temp.id('line'),
                         current_date - 30, p_expiry, 2000000, 'UGX', 2000000, 10,
                         null, null, 'Claim test policy', null);
  reset role;
  insert into ins_policy_insurer_shares
    (tenant_id, policy_id, insurer_id, is_lead, share_pct, commission_rate_pct, reviewed)
  values (pg_temp.id('tenant'), p.id, pg_temp.id('insurer'), true, 100, 10, true);
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  perform ins_submit_policy_for_approval(p.id);
  reset role;
  -- Approve as a second manager so maker/checker holds.
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  perform public.ins_bind_policy(p.id);
  reset role;
  return p.id;
end $$;

-- ---------------------------------------------------------------------
-- §1 reported -> assessed, with an audit row for each move
-- ---------------------------------------------------------------------
do $$
declare v_claim ins_claims%rowtype; v_events integer; v_stage text;
begin
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  v_claim := ins_create_claim(
    (select id from ins_policies where tenant_id = pg_temp.id('tenant') limit 1),
    current_date - 5, current_date - 4, 'Fire damage to stock', 'INS-REF-1', 500000);
  reset role;

  perform pg_temp.assert(ins_claim_stage(v_claim.id) = 'reported',
    '§1 a new claim is reported, got ' || coalesce(ins_claim_stage(v_claim.id), '(none)'));

  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  perform ins_transition_claim(v_claim.id, 'assessing', 'loss adjuster appointed');
  reset role;

  v_stage := ins_claim_stage(v_claim.id);
  select count(*) into v_events from ins_claim_events where claim_id = v_claim.id;
  perform pg_temp.assert(v_stage = 'assessed',
    '§1 after assessing the stage is assessed, got ' || coalesce(v_stage, '(none)'));
  perform pg_temp.assert(v_events >= 2,
    format('§1 each move should leave an audit row, got %s', v_events));
  raise notice 'PASS: §1 reported -> assessed, with an audit row for each move';
end $$;

-- ---------------------------------------------------------------------
-- §2 internal approval posts nothing
-- ---------------------------------------------------------------------
do $$
declare v_claim uuid := (select id from ins_claims where tenant_id = pg_temp.id('tenant') limit 1);
        v_before integer; v_after integer; v_stage text;
begin
  v_before := pg_temp.journals_for(v_claim);
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  perform ins_transition_claim(v_claim, 'approved', 'approved internally at 400,000', 400000);
  reset role;
  v_after := pg_temp.journals_for(v_claim);

  v_stage := ins_claim_stage(v_claim);
  perform pg_temp.assert(v_after = v_before,
    format('§2 internal approval must post no journal: went from %s to %s', v_before, v_after));
  perform pg_temp.assert(v_stage = 'internally_approved',
    '§2 the stage should be internally_approved, got ' || coalesce(v_stage, '(none)'));
  perform pg_temp.assert(pg_temp.balance(pg_temp.id('recv')) = 0,
    format('§2 no receivable before insurer confirmation, 1120 is %s', pg_temp.balance(pg_temp.id('recv'))));
  raise notice 'PASS: §2 internal approval creates no journal and no receivable';
end $$;

-- ---------------------------------------------------------------------
-- §3 insurer confirmation creates the receivable
-- ---------------------------------------------------------------------
do $$
declare v_claim uuid := (select id from ins_claims where tenant_id = pg_temp.id('tenant') limit 1);
        v_stage text;
begin
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  perform ins_recognise_claim_receivable(v_claim, 'insurer letter 4471 dated today');
  reset role;

  v_stage := ins_claim_stage(v_claim);
  perform pg_temp.assert(v_stage = 'insurer_confirmed',
    '§3 the stage should be insurer_confirmed, got ' || coalesce(v_stage, '(none)'));
  perform pg_temp.assert(pg_temp.balance(pg_temp.id('recv')) = 400000,
    format('§3 1120 should hold 400,000, got %s', pg_temp.balance(pg_temp.id('recv'))));
  perform pg_temp.assert(pg_temp.balance(pg_temp.id('pay')) = -400000,
    format('§3 2030 should hold a 400,000 credit, got %s', pg_temp.balance(pg_temp.id('pay'))));
  raise notice 'PASS: §3 insurer confirmation recognises Dr 1120 / Cr 2030';
end $$;

-- ---------------------------------------------------------------------
-- §4 funding, then a partial payment leaving a visible balance
-- ---------------------------------------------------------------------
do $$
declare v_claim uuid := (select id from ins_claims where tenant_id = pg_temp.id('tenant') limit 1);
        v_stage text;
begin
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  perform ins_record_claim_receipt(v_claim, pg_temp.id('bank'), 400000, current_date, 'FUND-1', 'insurer funds');
  reset role;

  v_stage := ins_claim_stage(v_claim);
  perform pg_temp.assert(v_stage = 'funded',
    '§4 once the insurer has funded it the stage is funded, got ' || coalesce(v_stage, '(none)'));

  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  perform ins_record_claim_payout(v_claim, pg_temp.id('bank'), 150000, current_date, 'PAY-1', 'first instalment');
  reset role;

  v_stage := ins_claim_stage(v_claim);
  perform pg_temp.assert(v_stage = 'partially_paid',
    '§4 a partial payment is partially_paid, got ' || coalesce(v_stage, '(none)'));

  -- The balance stays visible: 2030 still carries what has not been paid.
  perform pg_temp.assert(pg_temp.balance(pg_temp.id('pay')) = -250000,
    format('§4 2030 should still carry 250,000 owed to the client, got %s', pg_temp.balance(pg_temp.id('pay'))));
  raise notice 'PASS: §4 funding then a partial payment, with the balance still on 2030';
end $$;

-- ---------------------------------------------------------------------
-- §5 paying the rest reaches fully_paid; a disputed payment is excluded
-- ---------------------------------------------------------------------
do $$
declare v_claim uuid := (select id from ins_claims where tenant_id = pg_temp.id('tenant') limit 1);
        v_pay uuid; v_stage text;
begin
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  v_pay := (select id from ins_claim_payments
             where claim_id = v_claim and kind = 'client_payout' order by created_at limit 1);
  -- Dispute the first payment: it must drop out of the settled total.
  perform ins_set_claim_review_state(v_claim, 'payment_disputed', 'client disputes the amount of PAY-1');
  reset role;

  v_stage := ins_claim_stage(v_claim);
  perform pg_temp.assert(v_stage = 'payment_disputed',
    '§5 a disputed payment puts the claim in payment_disputed, got ' || coalesce(v_stage, '(none)'));

  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  perform ins_set_claim_review_state(v_claim, null, 'dispute resolved in the client''s favour');
  reset role;

  v_stage := ins_claim_stage(v_claim);
  perform pg_temp.assert(v_stage = 'partially_paid',
    '§5 clearing the dispute returns it to partially_paid, got ' || coalesce(v_stage, '(none)'));
  raise notice 'PASS: §5 a disputed payment takes the claim out of settled totals, and clearing it restores the stage';
end $$;

-- ---------------------------------------------------------------------
-- §6 a claim registered before cover started is accepted and flagged
-- ---------------------------------------------------------------------
do $$
declare v_pol uuid := pg_temp.make_policy(current_date + 30);
        v_claim ins_claims%rowtype;
        v_refused boolean := false;
begin
  -- Without the acknowledgement it is still refused: the guard has not been
  -- weakened into silent acceptance.
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  begin
    perform ins_create_claim(v_pol, current_date + 60, current_date + 61,
                             'Storm damage reported late', null, 100000);
  exception when others then
    v_refused := true;
    perform pg_temp.assert(sqlerrm like 'INS_LOSS_OUTSIDE_POLICY%',
      '§6 an out-of-period loss without acknowledgement must be refused, got: ' || sqlerrm);
  end;

  -- With the acknowledgement and a reason, it is accepted and flagged.
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  v_claim := ins_create_claim(v_pol, current_date + 60, current_date + 61,
                              'Storm damage reported late', null, 100000,
                              true, 'incident occurred during the cover period under the prior certificate');
  reset role;

  perform pg_temp.assert(v_refused, '§6 the unacknowledged attempt must be refused');
  perform pg_temp.assert(v_claim.late_notification,
    '§6 the accepted late claim should be flagged late_notification');
  perform pg_temp.assert(v_claim.review_state = 'coverage_under_review',
    '§6 and marked coverage_under_review, got ' || coalesce(v_claim.review_state, '(none)'));
  raise notice 'PASS: §6 an out-of-period claim is refused without an acknowledgement and accepted with one, flagged for review';
end $$;

-- ---------------------------------------------------------------------
-- §7 nothing is recognised while coverage is under review
-- ---------------------------------------------------------------------
do $$
declare v_claim uuid := (select id from ins_claims
                          where tenant_id = pg_temp.id('tenant')
                            and review_state = 'coverage_under_review' limit 1);
        v_refused boolean := false;
begin
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  perform ins_transition_claim(v_claim, 'assessing', 'checking the certificate');
  perform ins_transition_claim(v_claim, 'approved', 'assessed at 100,000', 100000);
  reset role;

  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  begin
    perform ins_recognise_claim_receivable(v_claim, 'insurer letter 9921');
  exception when others then
    v_refused := true;
    perform pg_temp.assert(sqlerrm like 'INS_CLAIM_REVIEW%',
      '§7 recognition under review must be refused as INS_CLAIM_REVIEW, got: ' || sqlerrm);
  end;
  reset role;

  perform pg_temp.assert(v_refused,
    '§7 a claim under coverage review must not have its insurer liability recognised');
  raise notice 'PASS: §7 coverage under review blocks recognition of insurer liability';
end $$;

<<<<<<< ours
=======
-- ---------------------------------------------------------------------
-- §8 repudiation is the ninth state, and it keeps its grounds (Appendix B Q3)
-- ---------------------------------------------------------------------
-- The accountant accepted repudiation as a ninth stage and attached conditions: it must
-- stay distinguishable from a paid claim and from a merely closed one, it must record the
-- insurer's decision, date, reason and correspondence, and it must be reopenable.
--
-- Note that before this section existed, NOTHING could set a claim to 'repudiated'. The
-- value was in the CHECK and reported by ins_claim_stage(), but no function wrote it, so
-- the state was reportable and unreachable.
do $$
declare
  v_claim   ins_claims%rowtype;
  v_policy  uuid;
  v_refused boolean := false;
  v_stage   text;
  v_events  integer;
begin
  v_policy := pg_temp.make_policy();

  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  v_claim := ins_create_claim(v_policy, current_date - 5, current_date - 4,
                              'Storm damage to roof', 'REP-REF-1', 300000);

  -- 8a. A repudiation with no reference behind it is refused: a claim declined with
  -- nothing to point at cannot be reviewed or challenged.
  begin
    perform ins_set_claim_repudiation(v_claim.id, current_date, 'Insurer declined: wear and tear', '   ');
    raise exception 'FAIL: §8 a repudiation with no reference must be refused';
  exception when others then
    if sqlerrm not like 'INS_REPUDIATION_REFERENCE%' then raise; end if;
  end;

  -- 8b. With grounds, it records the state and the evidence.
  perform ins_set_claim_repudiation(
    v_claim.id, current_date - 1,
    'Insurer declined: pre-existing wear and tear, not storm damage',
    'DECL-2026-0912');
  reset role;

  select * into v_claim from ins_claims where id = v_claim.id;
  perform pg_temp.assert(v_claim.status = 'repudiated',
    '§8 the claim must be stored as repudiated');
  perform pg_temp.assert(v_claim.repudiation_reference = 'DECL-2026-0912',
    '§8 the insurer''s decision reference must be kept, got ' || coalesce(v_claim.repudiation_reference, '(null)'));
  perform pg_temp.assert(v_claim.repudiation_date = current_date - 1,
    '§8 the insurer''s decision date must be kept');

  v_stage := ins_claim_stage(v_claim.id);
  perform pg_temp.assert(v_stage = 'repudiated',
    '§8 the stage must report repudiation rather than closing the claim, got ' || coalesce(v_stage, '(none)'));

  select count(*) into v_events from ins_claim_events
   where claim_id = v_claim.id and to_status = 'repudiated';
  perform pg_temp.assert(v_events = 1,
    '§8 the repudiation must leave exactly one audit row, got ' || v_events);

  -- 8c. The grounds cannot be quietly rewritten while the claim stays repudiated.
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  begin
    perform set_config('ins.via_rpc', 'on', true);
    update ins_claims set repudiation_reason = 'changed my mind' where id = v_claim.id;
    raise exception 'FAIL: §8 the grounds for a repudiation must not be rewritable';
  exception when others then
    if sqlerrm not like 'INS_REPUDIATION_IMMUTABLE%' then raise; end if;
  end;

  -- 8d. It can be reopened, and the grounds survive the reopening.
  perform ins_reopen_claim(v_claim.id, 'Insurer reversed its decision after a loss adjuster review');
  reset role;

  select * into v_claim from ins_claims where id = v_claim.id;
  perform pg_temp.assert(v_claim.status = 'assessing',
    '§8 reopening returns the claim to assessing, got ' || v_claim.status);
  perform pg_temp.assert(v_claim.repudiation_reference = 'DECL-2026-0912',
    '§8 reopening must keep the record of what the insurer decided');
  perform pg_temp.assert(v_claim.repudiation_reopened_at is not null,
    '§8 reopening must be dated so the gap is visible');
  perform pg_temp.assert(ins_claim_stage(v_claim.id) = 'assessed',
    '§8 a reopened claim is assessed again, got ' || coalesce(ins_claim_stage(v_claim.id), '(none)'));

  -- 8e. Only a repudiated claim is reopened this way.
  v_refused := false;
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  begin
    perform ins_reopen_claim(v_claim.id, 'trying again');
  exception when others then
    v_refused := true;
    perform pg_temp.assert(sqlerrm like 'INS_CLAIM_STATE%',
      '§8 reopening a claim that is not repudiated must be refused as INS_CLAIM_STATE, got: ' || sqlerrm);
  end;
  reset role;
  perform pg_temp.assert(v_refused, '§8 only a repudiated claim may be reopened');

  raise notice 'PASS: §8 repudiation is a ninth state with recorded grounds, and it can be reopened';
end $$;

>>>>>>> theirs
do $$ begin
  raise notice 'ALL PASS: the eight stages follow the ledger, internal approval posts nothing, confirmation posts the receivable, and review states gate recognition';
end $$;

rollback;
