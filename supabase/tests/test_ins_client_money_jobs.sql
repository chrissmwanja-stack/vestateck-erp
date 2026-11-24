-- =====================================================================
-- The daily client-money jobs reach every tenant without a session
-- Accountant pack v2, B9; pack section 9
-- =====================================================================
-- What this file proves, and why it is not obvious:
--
--   ins_client_money_check() and ins_escalate_missed_reconciliations() take their tenant
--   from get_my_tenant_id(), which reads the caller's JWT. A scheduled job has no JWT. So
--   the functions were callable, built, and incapable of running on a schedule: called
--   from cron they would see NO tenant, check nothing, and return successfully.
--
--   §1 asserts that a session-less caller reaches a real tenant through the platform
--   cores. That is the property the whole migration exists for.
--   §2 asserts the shortage the job finds is attributed to the system, not to a person.
--   §3 asserts a missed reconciliation is escalated and recorded once, not daily.
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

do $$
declare
  ta uuid := gen_random_uuid();
  mgr uuid := gen_random_uuid();
  trust_gl uuid; adv_gl uuid; pay_gl uuid; recv_gl uuid; ar_gl uuid; bank_gl uuid;
  v_bank uuid;
  v_party uuid;
begin
  insert into tenants(id, name) values (ta, 'Client money jobs test');
  insert into auth.users(id, email, raw_user_meta_data, raw_app_meta_data, aud, role, created_at, updated_at)
    values (mgr, 'cmj-' || mgr || '@test.local', '{}', '{}', 'authenticated', 'authenticated', now(), now());
  insert into app_users(id, tenant_id, name, email)
    values (mgr, ta, 'CM job actor', 'cmj-' || mgr || '@test.local');
  insert into tenant_modules(tenant_id, module) values (ta, 'insurance');
  insert into staff_roles(tenant_id, user_id, module, role) values (ta, mgr, 'insurance', 'manager');
  insert into finance_team_members(tenant_id, user_id, role) values (ta, mgr, 'finance');

  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '1000', 'Operating', 'asset') returning id into bank_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '1020', 'Client money', 'asset') returning id into trust_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type, is_control_account) values (ta, '1100', 'AR', 'asset', true) returning id into ar_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type, is_control_account) values (ta, '2040', 'Unallocated advances', 'liability', true) returning id into adv_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type, is_control_account) values (ta, '2030', 'Client claim payable', 'liability', true) returning id into pay_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type, is_control_account) values (ta, '1120', 'Insurer claim receivable', 'asset', true) returning id into recv_gl;

  insert into gl_posting_rules(tenant_id, account_role, gl_account_id) values
    (ta, 'bank', bank_gl), (ta, 'client_money_bank', trust_gl), (ta, 'ar_control', ar_gl),
    (ta, 'client_advance_payable', adv_gl), (ta, 'client_claim_payable', pay_gl),
    (ta, 'insurer_claim_receivable', recv_gl);

  -- A client-money bank account. With no money in it and an advance outstanding, the free
  -- position is negative by construction: 0 held, 250,000 owed back to a client.
  insert into fin_bank_accounts(tenant_id, name, kind, currency, gl_account_id)
    values (ta, 'CMJ-TRUST', 'client_money', 'UGX', trust_gl) returning id into v_bank;

  -- fin_open_items.party_account_id is NOT NULL, so the fixture needs a real account even
  -- though the position calculation reads only the control role and the balance.
  insert into accounts(tenant_id, account_code, name, account_type) values (ta, 'CMJ-CLI', 'CMJ client', 'client')
    returning id into v_party;

  insert into fin_open_items
    (tenant_id, party_account_id, side, control_role, source_type, source_id,
     document_no, document_date, due_date, currency, amount, description)
  values (ta, v_party, 'payable', 'client_advance_payable', 'ins_client_advance', gen_random_uuid(),
          'ADV-JOB-1', current_date, current_date, 'UGX', 250000, 'advance held, none received');

  create temp table ids (k text primary key, v uuid);
  insert into ids(k, v) values ('tenant', ta), ('bank', v_bank), ('mgr', mgr), ('trust', trust_gl);
end $$;

create function pg_temp.id(p_key text) returns uuid
language sql security definer set search_path = public, pg_temp as $$
  select v from ids where k = p_key
$$;
grant execute on function pg_temp.id(text) to authenticated;

-- ---------------------------------------------------------------------
-- §1 a caller with NO session reaches the tenant
-- ---------------------------------------------------------------------
-- No JWT is set here on purpose. This is what cron sees.
do $$
declare
  v_rows integer := 0;
  v_row  record;
  v_found boolean := false;
begin
  perform pg_temp.assert(public.get_my_tenant_id() is null,
    '§1 this section is only meaningful without a tenant context; get_my_tenant_id() returned one');

  for v_row in select * from public.platform_ins_client_money_check(pg_temp.id('tenant')) loop
    v_rows := v_rows + 1;
    if v_row.currency = 'UGX' then v_found := true; end if;
  end loop;

  perform pg_temp.assert(v_rows > 0,
    '§1 the tenant-parameterised check must return rows without a session, got none -- this is the inert-job failure');
  perform pg_temp.assert(v_found,
    '§1 the check must report the UGX position for this tenant');

  -- And the interactive function, by contrast, cannot: that is the bug being fixed.
  perform pg_temp.assert(
    (select count(*) from public.ins_client_money_check()) = 0,
    '§1 the interactive function should see nothing without a session, which is why the job cannot use it');
  raise notice 'PASS: §1 the scheduled core reaches the tenant where the interactive function cannot';
end $$;

-- ---------------------------------------------------------------------
-- §2 the shortage is attributed to the system, not to a person
-- ---------------------------------------------------------------------
do $$
declare v_inc fin_client_money_incidents%rowtype;
begin
  select * into v_inc from fin_client_money_incidents
   where tenant_id = pg_temp.id('tenant') and kind = 'shortage' and status = 'open';
  perform pg_temp.assert(v_inc.id is not null,
    '§2 a negative free position must raise an open shortage incident');
  perform pg_temp.assert(v_inc.shortage < 0,
    '§2 the incident must carry the negative position, got ' || v_inc.shortage);
  perform pg_temp.assert(v_inc.detected_automatically,
    '§2 an incident found by the job must be marked automatic');
  perform pg_temp.assert(v_inc.detected_by is null,
    '§2 an automatic detection must not name a person as the detector');
  raise notice 'PASS: §2 the job raises a shortage attributed to the system';
end $$;

-- ---------------------------------------------------------------------
-- §3 a missed reconciliation escalates once, not once a day
-- ---------------------------------------------------------------------
do $$
declare
  v_first uuid;
  v_second uuid;
  v_count integer;
  v_escalated integer := 0;
  v_row record;
begin
  for v_row in select * from public.platform_ins_escalate_missed_reconciliations(pg_temp.id('tenant')) loop
    if v_row.escalated then v_escalated := v_escalated + 1; end if;
    v_first := v_row.incident_id;
  end loop;
  perform pg_temp.assert(v_escalated = 1,
    '§3 the never-reconciled client-money account must escalate, got ' || v_escalated);

  -- Running again does not raise a second incident for the same account.
  for v_row in select * from public.platform_ins_escalate_missed_reconciliations(pg_temp.id('tenant')) loop
    v_second := v_row.incident_id;
  end loop;
  perform pg_temp.assert(v_first is not null and v_first = v_second,
    '§3 a second run must refresh the same incident, not open a new one');

  select count(*) into v_count from fin_client_money_incidents
   where tenant_id = pg_temp.id('tenant') and kind = 'reconciliation_missed';
  perform pg_temp.assert(v_count = 1,
    format('§3 there must be exactly one reconciliation incident, got %s', v_count));
  raise notice 'PASS: §3 a missed reconciliation escalates once and is refreshed after that';
end $$;

do $$ begin
  raise notice 'ALL PASS: the daily client-money jobs reach every tenant without a session, and record what they find';
end $$;

rollback;
