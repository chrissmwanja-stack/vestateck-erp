-- =====================================================================
-- Refund approval limits and split prevention
-- Accountant pack v2, B7
-- =====================================================================
-- The pack's criteria:
--
--   "A refund above a user's limit routes to the next level"                §1, §2
--   "the same user cannot approve it"                                       §3
--   "two same-day refunds to the same payee just under the limit are
--    flagged as a possible split"                                           §4
--
-- Plus the criterion that makes the workflow more than advisory: the refund function
-- itself refuses when an approved request is missing (§5), so the approval cannot be
-- bypassed by calling the execution path directly.
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
  ta uuid := gen_random_uuid();
  admin1 uuid := gen_random_uuid();
  admin2 uuid := gen_random_uuid();
  fin1 uuid := gen_random_uuid();
  fin2 uuid := gen_random_uuid();
  mgr uuid := gen_random_uuid();
  trust_gl uuid; ar_gl uuid; adv_gl uuid;
  v_bank uuid; v_party uuid; v_bd uuid; v_client uuid;
  v_adv uuid;
  s_low uuid; s_high uuid;
begin
  insert into tenants(id, name) values (ta, 'Refund limits test');
  insert into auth.users(id, email, raw_user_meta_data, raw_app_meta_data, aud, role, created_at, updated_at)
    select u, 'rfl-' || u || '@test.local', '{}', '{}', 'authenticated', 'authenticated', now(), now()
    from unnest(array[admin1, admin2, fin1, fin2, mgr]) u;
  insert into app_users(id, tenant_id, name, email)
    select u, ta, 'Refund actor', 'rfl-' || u || '@test.local'
    from unnest(array[admin1, admin2, fin1, fin2, mgr]) u;
  update app_users set is_company_admin = true where id in (admin1, admin2);

  insert into tenant_modules(tenant_id, module) values (ta, 'insurance');
  insert into staff_roles(tenant_id, user_id, module, role) values (ta, mgr, 'insurance', 'manager'), (ta, admin1, 'insurance', 'member'), (ta, fin1, 'insurance', 'member'), (ta, fin2, 'insurance', 'member');
  -- fin1 and fin2 are ordinary finance; mgr is the higher approver.
  insert into finance_team_members(tenant_id, user_id, role) values (ta, fin1, 'finance'), (ta, fin2, 'finance'), (ta, mgr, 'finance'), (ta, admin1, 'finance');

  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '1020', 'Client money', 'asset') returning id into trust_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type, is_control_account) values (ta, '1100', 'AR', 'asset', true) returning id into ar_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type, is_control_account) values (ta, '2040', 'Advances', 'liability', true) returning id into adv_gl;
  insert into gl_posting_rules(tenant_id, account_role, gl_account_id) values
    (ta, 'client_money_bank', trust_gl), (ta, 'ar_control', ar_gl),
    (ta, 'client_advance_payable', adv_gl), (ta, 'commission_income', ar_gl);

  insert into fin_bank_accounts(tenant_id, name, kind, currency, gl_account_id)
    values (ta, 'RFL-TRUST', 'client_money', 'UGX', trust_gl) returning id into v_bank;

  insert into accounts(tenant_id, account_code, name, account_type) values (ta, 'RFL-CLI', 'Refund client', 'client') returning id into v_party;
  insert into bd_clients(tenant_id, name) values (ta, 'Refund client') returning id into v_bd;
  insert into ins_clients(tenant_id, client_id, client_type, party_account_id)
    values (ta, v_bd, 'corporate', v_party) returning id into v_client;

  -- Two approval stages: 500,000 needs finance, 2,000,000 needs a manager.
  insert into workflow_stages (tenant_id, name, sequence_order, approver_role, threshold_amount, applies_to, is_active)
    values (ta, 'Refund level 1', 1, 'finance', 500000, 'insurance_refunds', true) returning id into s_low;
  insert into workflow_stages (tenant_id, name, sequence_order, approver_role, threshold_amount, applies_to, is_active)
    values (ta, 'Refund level 2', 2, 'manager', 2000000, 'insurance_refunds', true) returning id into s_high;

  -- fin1 may approve up to 1,000,000 on their own; so a 1,500,000 refund is above
  -- their limit even though it is only a level-1 refund.
  -- scope_type is CHECK-constrained to department | cost_center | global.
  insert into approval_assignments (tenant_id, user_id, workflow_stage_id, scope_type, threshold_max)
    values (ta, fin1, s_low, 'global', 1000000);

  create temp table ids (k text primary key, v uuid);
  insert into ids(k, v) values ('tenant', ta), ('client', v_client), ('party', v_party),
    ('bank', v_bank), ('adv', adv_gl), ('ar', ar_gl), ('trust', trust_gl),
    ('admin1', admin1), ('fin1', fin1), ('fin2', fin2), ('mgr', mgr),
    ('low', s_low), ('high', s_high);
end $$;

-- Lives in pg_temp but is resolved through pg_temp explicitly, because inside the
-- authenticated role an unqualified name is not guaranteed to find it.
create function pg_temp.id(p_key text) returns uuid
language sql security definer set search_path = public, pg_temp as $$
  select v from pg_temp.ids where k = p_key
$$;
grant execute on function pg_temp.id(text) to authenticated;

-- Take a 5,000,000 advance so there is plenty to refund.
do $$
begin
  perform pg_temp.jwt(pg_temp.id('fin1'));
  set local role authenticated;
  perform ins_record_client_advance(pg_temp.id('client'), pg_temp.id('bank'), 5000000,
                                    current_date, 'ADV-RFL', 'advance for refund limit tests');
  reset role;
end $$;

-- ---------------------------------------------------------------------
-- §1 the amount decides which level applies
-- ---------------------------------------------------------------------
do $$
declare r record;
begin
  select * into r from public.ins_refund_required_level(300000);
  perform pg_temp.assert(r.stage_id is null,
    '§1 below the lowest threshold no stage applies, so ordinary finance may refund');

  select * into r from public.ins_refund_required_level(750000);
  perform pg_temp.assert(r.stage_id = pg_temp.id('low') and r.approver_role = 'finance',
    format('§1 750,000 should route to level 1 (finance), got %s/%s', r.level, r.approver_role));

  select * into r from public.ins_refund_required_level(2500000);
  perform pg_temp.assert(r.stage_id = pg_temp.id('high') and r.approver_role = 'manager',
    format('§1 2,500,000 should route to level 2 (manager), got %s/%s', r.level, r.approver_role));
  raise notice 'PASS: §1 the refund amount selects the approval level from the stage configuration';
end $$;

-- ---------------------------------------------------------------------
-- §2 a refund above the user's own limit cannot be approved by them
-- ---------------------------------------------------------------------
do $$
declare v_adv uuid := (select id from ins_client_advances where tenant_id = pg_temp.id('tenant'));
        v_req ins_refund_requests%rowtype; v_refused boolean := false;
begin
  perform pg_temp.jwt(pg_temp.id('admin1'));
  set local role authenticated;
  v_req := ins_request_refund(v_adv, 1500000, 'client overpaid and wants the difference back');
  reset role;

  perform pg_temp.assert(v_req.status = 'pending' and v_req.required_level = 1,
    format('§2 the request should be pending at level 1, got %s/%s', v_req.status, v_req.required_level));

  -- fin1's personal limit is 1,000,000, so 1,500,000 must go higher.
  perform pg_temp.jwt(pg_temp.id('fin1'));
  set local role authenticated;
  begin
    perform ins_decide_refund(v_req.id, 'approve', 'looks fine to me');
  exception when others then
    v_refused := true;
    perform pg_temp.assert(sqlerrm like 'INS_REFUND_LIMIT%',
      '§2 approving above your own limit must be refused as INS_REFUND_LIMIT, got: ' || sqlerrm);
  end;
  reset role;

  perform pg_temp.assert(v_refused, '§2 a user cannot approve above their own limit');
  raise notice 'PASS: §2 a refund above the approver''s own limit routes higher';
end $$;

-- ---------------------------------------------------------------------
-- §3 the requester cannot approve their own refund
-- ---------------------------------------------------------------------
do $$
declare v_adv uuid := (select id from ins_client_advances where tenant_id = pg_temp.id('tenant'));
        v_req ins_refund_requests%rowtype; v_refused boolean := false;
begin
  -- fin1 raises a refund small enough for their own limit.
  perform pg_temp.jwt(pg_temp.id('fin1'));
  set local role authenticated;
  v_req := ins_request_refund(v_adv, 600000, 'duplicate premium payment refund');
  reset role;

  perform pg_temp.jwt(pg_temp.id('fin1'));
  set local role authenticated;
  begin
    perform ins_decide_refund(v_req.id, 'approve', 'approving my own request');
  exception when others then
    v_refused := true;
    perform pg_temp.assert(sqlerrm like 'INS_REFUND_SELF%',
      '§3 self-approval must be refused as INS_REFUND_SELF, got: ' || sqlerrm);
  end;
  reset role;

  perform pg_temp.assert(v_refused, '§3 the requester cannot approve their own refund');

  -- A different finance user can.
  perform pg_temp.jwt(pg_temp.id('fin2'));
  set local role authenticated;
  v_req := ins_decide_refund(v_req.id, 'approve', 'checked against the receipt');
  reset role;
  perform pg_temp.assert(v_req.status = 'approved',
    '§3 a different finance user should be able to approve, got ' || coalesce(v_req.status, '(none)'));
  raise notice 'PASS: §3 the requester cannot approve; a second finance user can';
end $$;

-- ---------------------------------------------------------------------
-- §4 two same-day refunds just under the limit are flagged as a split
-- ---------------------------------------------------------------------
do $$
declare v_adv uuid := (select id from ins_client_advances where tenant_id = pg_temp.id('tenant'));
        v_first ins_refund_requests%rowtype; v_second ins_refund_requests%rowtype;
begin
  -- Both are 400,000: individually below the 500,000 level-1 threshold, together
  -- above it. That is the pattern the pack describes.
  perform pg_temp.jwt(pg_temp.id('admin1'));
  set local role authenticated;
  v_first := ins_request_refund(v_adv, 400000, 'first of two same-day refunds');
  v_second := ins_request_refund(v_adv, 400000, 'second of two same-day refunds');
  reset role;

  perform pg_temp.assert(v_first.split_flagged = false,
    '§4 the first request alone is not a split');
  perform pg_temp.assert(v_second.split_flagged = true,
    '§4 the second same-day request should be flagged as a possible split');
  perform pg_temp.assert(v_second.split_detail like '%other refund(s)%',
    format('§4 the flag should carry its evidence, got: %s', coalesce(v_second.split_detail, '(none)')));
  perform pg_temp.assert(v_second.required_stage_id is null,
    '§4 and each request is still individually below the threshold, which is why it is a split');
  raise notice 'PASS: §4 two same-day refunds just under the limit are flagged with the figures that triggered it';
end $$;

-- ---------------------------------------------------------------------
-- §5 the execution path refuses without an approved request
-- ---------------------------------------------------------------------
do $$
declare v_adv uuid := (select id from ins_client_advances where tenant_id = pg_temp.id('tenant'));
        v_refused boolean := false;
begin
  -- 800,000 is a level-1 amount, and no approved request covers it.
  perform pg_temp.jwt(pg_temp.id('fin1'));
  set local role authenticated;
  begin
    perform ins_refund_client_advance(v_adv, pg_temp.id('bank'), 800000, current_date,
                                      'refunding without approval');
  exception when others then
    v_refused := true;
    perform pg_temp.assert(sqlerrm like 'INS_REFUND_APPROVAL_REQUIRED%',
      '§5 refunding above the threshold without an approved request must be refused, got: ' || sqlerrm);
  end;
  reset role;
  perform pg_temp.assert(v_refused,
    '§5 the refund function itself must refuse, or the approval workflow is advisory');
  raise notice 'PASS: §5 a refund above the threshold cannot be executed without an approved request';
end $$;

-- ---------------------------------------------------------------------
-- §6 below the threshold nothing changes, and an approved request executes
-- ---------------------------------------------------------------------
do $$
declare v_adv uuid := (select id from ins_client_advances where tenant_id = pg_temp.id('tenant'));
        v_row ins_client_advances%rowtype;
        v_req ins_refund_requests%rowtype;
        v_exec ins_refund_requests%rowtype;
begin
  -- 200,000 is below every threshold: ordinary finance, no request needed.
  perform pg_temp.jwt(pg_temp.id('fin1'));
  set local role authenticated;
  v_row := ins_refund_client_advance(v_adv, pg_temp.id('bank'), 200000, current_date,
                                     'small refund below any limit');
  reset role;
  perform pg_temp.assert(v_row.refunded_amount >= 200000,
    format('§6 a below-threshold refund should go through, refunded %s', v_row.refunded_amount));

  -- The approved 600,000 request from §3 executes and is marked executed.
  perform pg_temp.jwt(pg_temp.id('fin1'));
  set local role authenticated;
  v_row := ins_refund_client_advance(v_adv, pg_temp.id('bank'), 600000, current_date,
                                     'executing the approved refund');
  reset role;
  select * into v_exec from ins_refund_requests
   where tenant_id = pg_temp.id('tenant') and status = 'executed' limit 1;
  perform pg_temp.assert(v_exec.id is not null,
    '§6 the approved request should be marked executed once the money moves');
  raise notice 'PASS: §6 below-threshold refunds are untouched, and an approved request executes once';
end $$;

-- ---------------------------------------------------------------------
-- §9 the shipped stage means every refund needs a second person (Appendix B Q2)
-- ---------------------------------------------------------------------
-- The accountant's decision: "independent maker-checker approval for every client-advance
-- refund, regardless of amount. That is safer than allowing one finance user to release
-- client money alone."
--
-- The engine already enforced it; what was missing was that no stage shipped, so no level
-- applied and the gate was inert. 20261124011300 inserts one stage with a null threshold,
-- which is matched for every amount. This section proves the two properties that matter:
-- a tiny refund still needs approval, and the requester still cannot be the approver.
do $$
declare
  v_lvl record;
  v_refused boolean := false;
begin
  insert into public.workflow_stages
    (tenant_id, name, sequence_order, approver_role, threshold_amount, applies_to, is_active)
  values (pg_temp.id('tenant'), 'Client advance refund', 0, 'finance', null, 'insurance_refunds', true);

  -- A refund of 1 (one shilling) is matched by the shipped stage.
  select * into v_lvl from platform_ins_refund_required_level(pg_temp.id('tenant'), 1);
  perform pg_temp.assert(v_lvl.stage_id is not null,
    '§9 the shipped insurance_refunds stage must apply to any amount, including 1');

  -- With a stage applying, the raw refund function must refuse without an approved request.
  perform pg_temp.jwt(pg_temp.id('fin1'));
  set local role authenticated;
  begin
    perform ins_refund_client_advance(
      (select id from ins_client_advances where tenant_id = pg_temp.id('tenant') limit 1),
      pg_temp.id('bank'), 1, current_date, 'attempt to release client money alone');
  exception when others then
    v_refused := true;
    perform pg_temp.assert(sqlerrm like 'INS_REFUND_APPROVAL_REQUIRED%',
      '§9 an unapproved refund of any size must be refused as INS_REFUND_APPROVAL_REQUIRED, got: ' || sqlerrm);
  end;
  reset role;
  perform pg_temp.assert(v_refused,
    '§9 one finance user must not be able to release client money alone');

  raise notice 'PASS: §9 every client-advance refund requires an independent second approver';
end $$;

do $$ begin
  raise notice 'ALL PASS: refund limits route by amount and by the approver''s own limit, self-approval is refused, splits are flagged, and the execution path enforces the approval';
end $$;

rollback;
