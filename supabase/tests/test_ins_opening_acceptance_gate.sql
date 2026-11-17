-- =====================================================================
-- Insurance: the post-opening acceptance gate.
--
-- What this pins. Before this migration a company could post any number of
-- opening positions and nobody had to accept any of them. Measured on a clean
-- replay: batch A posted 1,000,000 of receivable, batch B then posted 500,000
-- more, both dated at their own cut-over, with no record that the books had two
-- openings.
--
--   §1  one opening per company: a second batch is refused by name
--   §2  a reopen is deliberate, needs a reason, and re-arms the gate
--   §3  acceptance needs a second person: the poster cannot accept their own
--   §4  acceptance can only be given once
--   §5  an unaccepted opening blocks BINDING but not drafting or approving
--   §6  an accepted opening lets business proceed, and the gate does not touch
--       a company that never migrated anything
--   §7  accepting stores the differences the reviewer was shown
--   §8  the acceptance is per company, not per batch: accepting one batch
--       settles the company, and a reopen puts it back
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

create function pg_temp.expect_error(p_sql text, p_needle text, p_label text)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm like '%' || p_needle || '%' then return; end if;
    raise exception 'FAIL: % raised the wrong error: %', p_label, sqlerrm;
  end;
  raise exception 'FAIL: % succeeded but should have failed with %', p_label, p_needle;
end $$;

create function pg_temp.jwt(p_uid uuid)
returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
$$;

create function pg_temp.one_share(p_policy uuid, p_insurer uuid, p_rate numeric)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into ins_policy_insurer_shares
    (tenant_id, policy_id, insurer_id, is_lead, share_pct, commission_rate_pct, reviewed)
  select tenant_id, p_policy, p_insurer, true, 100, p_rate, true
    from ins_policies where id = p_policy;
end $$;

-- Stage, validate, commit and post one batch as the signed-in manager.
create function pg_temp.make_batch(p_label text, p_policy_no text,
                                 p_client text default 'Gate Client')
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid; v_rep jsonb;
begin
  select id into v_id from public.ins_import_create_batch(p_label, current_date);
  perform public.ins_import_stage_rows(v_id, 'policies', jsonb_build_array(jsonb_build_object(
    'legacy_policy_no', p_policy_no,
    'client_name', p_client,
    'insurer', 'GATEINS1',
    'product_line', 'GEN',
    'inception_date', '2026-01-01',
    'expiry_date', '2026-12-31',
    'currency', 'UGX',
    'gross_premium', '1000000',
    'commission_rate_pct', '10')));
  v_rep := public.ins_import_validate_batch(v_id);
  if (v_rep ->> 'error_count')::int <> 0 then
    raise exception 'fixture: batch "%" did not validate: % -- rows: %', p_label, v_rep::text,
      (select string_agg(coalesce(errors::text,''), ' | ') from ins_import_rows where batch_id = v_id);
  end if;
  perform public.ins_import_commit_policies(v_id);
  perform public.ins_import_post_opening_position(v_id);
  return v_id;
end $$;

---------------------------------------------------------------------
-- Fixtures
---------------------------------------------------------------------
create temp table pg_temp.g_ids as
select gen_random_uuid() as ta,          -- the migrating company
       gen_random_uuid() as tc,          -- a company that never migrated
       gen_random_uuid() as mgr,         -- insurance manager: posts and binds
       gen_random_uuid() as rev;         -- a second manager: accepts

insert into tenants (id, name)
select ta, 'Gate Brokerage' from pg_temp.g_ids
union all select tc, 'Never Migrated Brokerage' from pg_temp.g_ids;

insert into auth.users (instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token)
select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
  'gate-' || u.id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
  now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
from (select mgr as id from pg_temp.g_ids union all select rev from pg_temp.g_ids) u;

insert into app_users (id, tenant_id, name, email)
select mgr, ta, 'Gate Manager', 'gate-' || mgr || '@test.local' from pg_temp.g_ids
union all select rev, ta, 'Gate Reviewer', 'gate-' || rev || '@test.local' from pg_temp.g_ids;

insert into tenant_modules (tenant_id, module)
select ta, 'insurance' from pg_temp.g_ids union all select tc, 'insurance' from pg_temp.g_ids;

insert into staff_roles (tenant_id, user_id, module, role)
select ta, mgr, 'insurance', 'manager' from pg_temp.g_ids
union all select ta, rev, 'insurance', 'manager' from pg_temp.g_ids;

-- Chart: the five roles the opening position needs, plus the bind roles.
insert into gl_accounts (tenant_id, account_code, name, account_type, is_control_account)
select i.ta, v.code, v.name, v.type, v.control
from pg_temp.g_ids i,
     (values ('1000', 'Operating', 'asset', false),
             ('1020', 'Client Money', 'asset', true),
             ('1100', 'Accounts Receivable Control', 'asset', true),
             ('2010', 'Insurer Payable (Premiums)', 'liability', true),
             ('2400', 'Unearned Commission', 'liability', true),
             ('3200', 'Retained Earnings', 'equity', false),
             ('3900', 'Opening Balance Clearing', 'equity', false),
             ('4000', 'Commission Income', 'revenue', false)) v(code, name, type, control);

insert into gl_posting_rules (tenant_id, account_role, gl_account_id)
select a.tenant_id, v.role, a.id
from (values ('bank', '1000'), ('client_money_bank', '1020'), ('ar_control', '1100'),
             ('insurer_payable', '2010'), ('unearned_commission', '2400'),
             ('commission_income', '4000'), ('opening_balance_clearing', '3900'),
             ('retained_earnings', '3200')) v(role, code)
join gl_accounts a on a.account_code = v.code
join pg_temp.g_ids i on a.tenant_id = i.ta;

-- Master data exactly as the import expects it: active insurers and product
-- lines, and a BD client with an insurance profile.
select set_config('ins.via_rpc', 'on', true);
insert into ins_insurers (tenant_id, code, name, is_active)
select ta, 'GATEINS1', 'Gate Insurer', true from pg_temp.g_ids;
insert into ins_product_lines (tenant_id, code, name, class, is_active)
select ta, 'GEN', 'General', 'general', true from pg_temp.g_ids;
insert into bd_clients (tenant_id, name)
select ta, 'Gate Client' from pg_temp.g_ids
union all select ta, 'Gate Property Client' from pg_temp.g_ids;
insert into ins_clients (tenant_id, client_id, client_type, kyc_status)
select c.tenant_id, c.id, 'corporate', 'verified'
  from bd_clients c join pg_temp.g_ids i on c.tenant_id = i.ta;
select set_config('ins.via_rpc', 'off', true);

do $$
declare
  o pg_temp.g_ids;
  b1 uuid; b2 uuid; b3 uuid;
  v_before integer; v_after integer;
  v_rep jsonb;
  c ins_clients%rowtype; p ins_policies%rowtype;
  v_line uuid; v_insurer uuid; v_share integer;
begin
  select * into o from pg_temp.g_ids;
  perform pg_temp.jwt(o.mgr);

  -------------------------------------------------------------------
  -- §1 one opening per company
  -------------------------------------------------------------------
  b1 := pg_temp.make_batch('GATE-1 first opening', 'GATE-P1');
  perform pg_temp.assert(
    (select ins_opening_posted_at from tenants where id = o.ta) is not null,
    '§1 the first opening stamps the company cut-over');
  perform pg_temp.assert(
    (select opening_posted_at from ins_import_batches where id = b1) is not null,
    '§1 the batch records when it posted');

  -- A second batch, fully valid, that tries to post its own opening.
  perform pg_temp.expect_error(
    $q$select pg_temp.make_batch($q$ || '''GATE-2 second opening''' || $q$, $q$ || '''GATE-P2''' || $q$)$q$,
    'INS_OPENING_EXISTS',
    '§1 posting a second opening position for the same company');

  -------------------------------------------------------------------
  -- §5 an unaccepted opening blocks binding, not drafting
  -------------------------------------------------------------------
  -- Draft a policy and take it through approval: both must still work.
  set local role authenticated;
  c := ins_register_client('Gate Client', 'corporate', null, null, null, 'low');
  select id into v_line from ins_product_lines where tenant_id = o.ta and code = 'GEN';
  select id into v_insurer from ins_insurers where tenant_id = o.ta and code = 'GATEINS1';
  p := ins_create_policy(c.id, v_insurer, v_line, current_date, current_date + 365,
                         1000000, 'UGX', 300000, 10, null, null, 'First post-cut-over policy', null);
  perform pg_temp.one_share(p.id, v_insurer, 10);
  perform public.ins_submit_policy_for_approval(p.id);
  reset role;

  -- Approve as a second manager (the app requires someone other than the maker).
  perform pg_temp.jwt(o.rev);
  set local role authenticated;
  perform public.ins_decide_policy(p.id, 'approved');
  reset role;

  perform pg_temp.assert(
    (select status from ins_policies where id = p.id) = 'approved',
    '§5 a policy can still be drafted and approved on an unaccepted opening');

  select count(*) into v_before from journal_entries
   where tenant_id = o.ta and source_type = 'ins_policy_bind';

  perform pg_temp.jwt(o.mgr);
  set local role authenticated;
  perform pg_temp.expect_error(
    format($q$select public.ins_bind_policy(%L)$q$, p.id),
    'INS_OPENING_UNACCEPTED',
    '§5 binding on an opening nobody has accepted');
  reset role;

  select count(*) into v_after from journal_entries
   where tenant_id = o.ta and source_type = 'ins_policy_bind';
  perform pg_temp.assert(v_after = v_before,
    '§5 the refused bind posted nothing');

  -------------------------------------------------------------------
  -- §3 acceptance needs a second person
  -------------------------------------------------------------------
  perform pg_temp.jwt(o.mgr);
  set local role authenticated;
  perform pg_temp.expect_error(
    format($q$select public.ins_import_accept_opening(%L, 'looks fine')$q$, b1),
    'INS_OPENING_SELF_ACCEPT',
    '§3 the manager who posted the opening accepting it');
  reset role;

  -------------------------------------------------------------------
  -- §4 acceptance is one moment, recorded once
  -------------------------------------------------------------------
  perform pg_temp.jwt(o.rev);
  set local role authenticated;
  v_rep := public.ins_import_accept_opening(b1, 'Checked against the legacy trial balance');

  perform pg_temp.assert((v_rep ->> 'accepted')::boolean, '§4 the reviewer accepted the opening');
  perform pg_temp.assert(
    (select ins_opening_accepted_at from tenants where id = o.ta) is not null,
    '§4 the company records the acceptance');
  perform pg_temp.assert(
    (select opening_accepted_by from ins_import_batches where id = b1) = o.rev,
    '§4 the batch records who accepted it');

  perform pg_temp.expect_error(
    format($q$select public.ins_import_accept_opening(%L, 'again')$q$, b1),
    'INS_OPENING_ALREADY_ACCEPTED',
    '§4 accepting the same opening twice');
  reset role;

  -------------------------------------------------------------------
  -- §7 the differences the reviewer saw are stored
  -------------------------------------------------------------------
  perform pg_temp.assert(
    (select opening_accepted_diff from ins_import_batches where id = b1) is not null,
    '§7 accepting stores the reconciliation the reviewer was shown');
  perform pg_temp.assert(
    (select opening_accept_note from ins_import_batches where id = b1)
      = 'Checked against the legacy trial balance',
    '§7 the reviewer''s note is kept');

  -------------------------------------------------------------------
  -- §6 an accepted opening lets business proceed
  -------------------------------------------------------------------
  perform pg_temp.jwt(o.mgr);
  set local role authenticated;
  p := public.ins_bind_policy(p.id);
  reset role;
  perform pg_temp.assert(p.status = 'active',
    '§6 once the opening is accepted, binding works again');
  perform pg_temp.assert(
    (select count(*) from journal_entries
      where tenant_id = o.ta and source_type = 'ins_policy_bind') = v_before + 1,
    '§6 the bind posted exactly one journal');

  -------------------------------------------------------------------
  -- §2 a reopen needs a reason and re-arms the gate
  -------------------------------------------------------------------
  perform pg_temp.jwt(o.mgr);
  set local role authenticated;
  perform pg_temp.expect_error(
    format($q$select public.ins_import_reopen_opening(%L, 'fix')$q$, b1),
    'INS_OPENING_REOPEN_REASON',
    '§2 reopening with a one-word reason');

  perform public.ins_import_reopen_opening(b1,
    'The property portfolio was left out of the first cut-over and must be added');
  reset role;

  perform pg_temp.assert(
    (select ins_opening_accepted_at from tenants where id = o.ta) is null,
    '§2 a reopen clears the acceptance');
  perform pg_temp.assert(
    (select ins_opening_reopened_at from tenants where id = o.ta) is not null,
    '§2 the reopen is stamped');

  -- The second opening is now allowed...
  b2 := pg_temp.make_batch('GATE-3 correction opening', 'GATE-P3', 'Gate Property Client');
  perform pg_temp.assert(b2 is not null, '§2 a reopened company may post a correction opening');
  perform pg_temp.assert(
    (select count(*) from journal_entries
      where tenant_id = o.ta and source_type = 'ins_import_opening') = 2,
    '§2 both openings stand: a correction is a second position, not a rewrite');

  -- ...and the gate is armed again until someone accepts it.
  perform pg_temp.jwt(o.mgr);
  set local role authenticated;
  c := ins_register_client('Gate Client 2', 'corporate', null, null, null, 'low');
  p := ins_create_policy(c.id, v_insurer, v_line, current_date, current_date + 365,
                         2000000, 'UGX', 400000, 10, null, null, 'Second post-cut-over policy', null);
  perform pg_temp.one_share(p.id, v_insurer, 10);
  perform public.ins_submit_policy_for_approval(p.id);
  reset role;
  perform pg_temp.jwt(o.rev);
  set local role authenticated;
  perform public.ins_decide_policy(p.id, 'approved');
  reset role;

  perform pg_temp.jwt(o.mgr);
  set local role authenticated;
  perform pg_temp.expect_error(
    format($q$select public.ins_bind_policy(%L)$q$, p.id),
    'INS_OPENING_UNACCEPTED',
    '§2 binding while the correction opening is unaccepted');
  reset role;

  -------------------------------------------------------------------
  -- §8 acceptance settles the company, per batch, second person
  -------------------------------------------------------------------
  perform pg_temp.jwt(o.rev);
  set local role authenticated;
  perform public.ins_import_accept_opening(b2, 'Correction reviewed with the property schedule');
  reset role;
  perform pg_temp.jwt(o.mgr);
  set local role authenticated;
  p := public.ins_bind_policy(p.id);
  reset role;
  perform pg_temp.assert(p.status = 'active',
    '§8 accepting the correction opening reopens ordinary business');

  -------------------------------------------------------------------
  -- §6 a company that never migrated is not gated
  -------------------------------------------------------------------
  perform pg_temp.assert(
    (select ins_opening_posted_at from tenants where id = o.tc) is null,
    '§6 an unmigrated company has no cut-over recorded');
  perform pg_temp.assert(
    public.ins_opening_accepted_for(o.tc),
    '§6 and is not gated: a tenant with no opening may bind freely');

  raise notice 'PASS: §1 single opening, §2 reopen, §3 second person, §4 accept once, §5 gate blocks binding not drafting, §6 accepted company proceeds, §7 stored differences, §8 per company';
  raise notice 'ALL OPENING ACCEPTANCE GATE TESTS PASSED';
end $$;

rollback;
