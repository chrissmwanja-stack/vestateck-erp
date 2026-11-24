-- =====================================================================
-- Commission recognition terms per insurer agreement
-- Accountant pack v2, B3 (decision 2B: fail closed per insurer)
-- =====================================================================
-- The pack's criterion: binding on an insurer with no configured mode is refused, and
-- the error names the insurer and the missing setting; configuring the mode allows the
-- bind and the chosen mode is frozen into the accounting snapshot.
--
-- §1-§3 prove the refusal, that it names the insurer, and that the message points at
--    BOTH places a mode could come from.
-- §4-§5 prove that an agreement makes the bind possible and is what gets frozen.
-- §6     proves the insurer's agreement outranks the company setting -- the point of
--        building this per insurer rather than per company.
-- §7     proves history survives a renegotiation.
-- §8     proves the readiness report tells an accountant about a gap before a client
--        is waiting at the counter.
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

create function pg_temp.expect_error(p_sql text, p_code text, p_what text)
returns void language plpgsql as $$
declare v_ok boolean := false;
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm like p_code || '%' then
      v_ok := true;
    else
      raise exception 'FAIL: % should be refused as %, but was refused as: %', p_what, p_code, sqlerrm;
    end if;
  end;
  if not v_ok then
    raise exception 'FAIL: % should have been refused as % and was not refused at all', p_what, p_code;
  end if;
end $$;

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
  v_appr := ('c3300000-0000-4000-8000-' || substr(replace(v_tenant::text, '-', ''), 1, 12))::uuid;
  perform public.ins_submit_policy_for_approval(p_id);
  insert into auth.users(id, email, raw_user_meta_data, raw_app_meta_data, aud, role, created_at, updated_at)
    values (v_appr, 'approver-' || v_appr || '@test.local', '{}', '{}', 'authenticated', 'authenticated', now(), now())
    on conflict (id) do nothing;
  insert into public.app_users(id, tenant_id, name, email)
    values (v_appr, v_tenant, 'Terms approver', 'approver-' || v_appr || '@test.local')
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

do $$
declare
  ta       uuid := gen_random_uuid();
  admin1   uuid := gen_random_uuid();
  admin2   uuid := gen_random_uuid();
  mgr      uuid := gen_random_uuid();
  bank_gl uuid; trust_gl uuid; ar_gl uuid; pay_gl uuid; unearned_gl uuid; income_gl uuid;
  v_line uuid; v_ins_a uuid; v_ins_b uuid; v_client uuid;
  p ins_policies%rowtype;
  v_t1 uuid; v_t2 uuid;
begin
  insert into tenants(id, name) values (ta, 'Insurer terms test');
  insert into auth.users(id, email, raw_user_meta_data, raw_app_meta_data, aud, role, created_at, updated_at)
    select u, 'trm-' || u || '@test.local', '{}', '{}', 'authenticated', 'authenticated', now(), now()
    from unnest(array[admin1, admin2, mgr]) u;
  insert into app_users(id, tenant_id, name, email)
    select u, ta, 'Terms actor', 'trm-' || u || '@test.local'
    from unnest(array[admin1, admin2, mgr]) u;
  update app_users set is_company_admin = true where id in (admin1, admin2);

  insert into tenant_modules(tenant_id, module) values (ta, 'insurance');
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
  -- The company admins also need an insurance role: ins_register_client and
  -- ins_propose_insurer_commission_terms both gate on can_access_insurance(), which
  -- is_company_admin alone does not satisfy.
  insert into staff_roles(tenant_id, user_id, module, role) values
    (ta, admin1, 'insurance', 'admin'), (ta, admin2, 'insurance', 'admin'), (ta, mgr, 'insurance', 'manager');
=======
  insert into staff_roles(tenant_id, user_id, module, role) values (ta, mgr, 'insurance', 'manager');
>>>>>>> theirs
=======
  insert into staff_roles(tenant_id, user_id, module, role) values (ta, mgr, 'insurance', 'manager');
>>>>>>> theirs
=======
  insert into staff_roles(tenant_id, user_id, module, role) values (ta, mgr, 'insurance', 'manager');
>>>>>>> theirs
=======
  insert into staff_roles(tenant_id, user_id, module, role) values (ta, mgr, 'insurance', 'manager');
>>>>>>> theirs
  insert into finance_team_members(tenant_id, user_id, role) values (ta, mgr, 'finance');

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

  insert into ins_product_lines(tenant_id, code, name) values (ta, 'GEN', 'General') returning id into v_line;
  insert into ins_insurers(tenant_id, code, name) values (ta, 'ALPHA', 'Alpha Assurance') returning id into v_ins_a;
  insert into ins_insurers(tenant_id, code, name) values (ta, 'BETA',  'Beta Insurance')  returning id into v_ins_b;

  perform pg_temp.jwt(admin1);
  set local role authenticated;
  v_client := (ins_register_client('Terms client', 'corporate', null, null, null, 'low')).id;
  reset role;

  -- NOTE: no company-wide ins.commission_recognition is configured anywhere in this
  -- fixture. That is deliberate: it is what makes §1 a per-insurer test rather than a
  -- company-setting test.
  create temp table ids (k text primary key, v uuid);
  insert into ids(k, v) values ('tenant', ta), ('admin1', admin1), ('admin2', admin2),
    ('mgr', mgr), ('line', v_line), ('ins_a', v_ins_a), ('ins_b', v_ins_b),
    ('client', v_client), ('unearned', unearned_gl), ('income', income_gl), ('ar', ar_gl);
end $$;

create function pg_temp.id(p_key text) returns uuid
language sql security definer set search_path = public, pg_temp as $$
  select v from pg_temp.ids where k = p_key
$$;
grant execute on function pg_temp.id(text) to authenticated;

<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
create function pg_temp.new_policy(p_insurer uuid, p_commission numeric default 100000,
                                   p_inception date default null)
=======
create function pg_temp.new_policy(p_insurer uuid, p_commission numeric default 100000)
>>>>>>> theirs
=======
create function pg_temp.new_policy(p_insurer uuid, p_commission numeric default 100000)
>>>>>>> theirs
=======
create function pg_temp.new_policy(p_insurer uuid, p_commission numeric default 100000)
>>>>>>> theirs
=======
create function pg_temp.new_policy(p_insurer uuid, p_commission numeric default 100000)
>>>>>>> theirs
returns public.ins_policies
language plpgsql security definer set search_path = public, pg_temp as $$
declare p public.ins_policies;
begin
  p := public.ins_create_policy(
         pg_temp.id('client'), p_insurer, pg_temp.id('line'),
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
         coalesce(p_inception, public.ins_local_today()),
         coalesce(p_inception, public.ins_local_today()) + 365,
=======
         public.ins_local_today(), public.ins_local_today() + 365,
>>>>>>> theirs
=======
         public.ins_local_today(), public.ins_local_today() + 365,
>>>>>>> theirs
=======
         public.ins_local_today(), public.ins_local_today() + 365,
>>>>>>> theirs
=======
         public.ins_local_today(), public.ins_local_today() + 365,
>>>>>>> theirs
         1000000, 'UGX', 1000000, 10, null, null, 'Terms fixture', null);
  insert into public.ins_policy_insurer_shares
    (tenant_id, policy_id, insurer_id, is_lead, share_pct, commission_rate_pct, reviewed)
  values (pg_temp.id('tenant'), p.id, p_insurer, true, 100, 10, true);
  return p;
end $$;
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
grant execute on function pg_temp.new_policy(uuid, numeric, date) to authenticated;
=======
grant execute on function pg_temp.new_policy(uuid, numeric) to authenticated;
>>>>>>> theirs
=======
grant execute on function pg_temp.new_policy(uuid, numeric) to authenticated;
>>>>>>> theirs
=======
grant execute on function pg_temp.new_policy(uuid, numeric) to authenticated;
>>>>>>> theirs
=======
grant execute on function pg_temp.new_policy(uuid, numeric) to authenticated;
>>>>>>> theirs

-- ---------------------------------------------------------------------
-- §1 an insurer with nothing configured cannot bind, and the error names it
-- ---------------------------------------------------------------------
do $$
declare p ins_policies%rowtype; v_msg text; v_ok boolean := false;
begin
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  p := pg_temp.new_policy(pg_temp.id('ins_a'));
  begin
    p := pg_temp.approve_and_bind(p.id);
  exception when others then
    v_msg := sqlerrm;
    v_ok := true;
  end;
  reset role;

  perform pg_temp.assert(v_ok,
    '§1 a policy on an insurer with no terms and no company default must not bind');
  perform pg_temp.assert(v_msg like 'INS_COMMISSION_RECOGNITION_UNSET%',
    '§1 the refusal must be INS_COMMISSION_RECOGNITION_UNSET, got: ' || coalesce(v_msg, '(none)'));
  -- The criterion says the error names the insurer. Check the actual name, not just
  -- that some insurer id appeared.
  perform pg_temp.assert(v_msg like '%Alpha Assurance%',
    '§1 the refusal must name the insurer, got: ' || coalesce(v_msg, '(none)'));
  perform pg_temp.assert(v_msg like '%ALPHA%',
    '§1 the refusal must give the insurer code as well as the name, got: ' || coalesce(v_msg, '(none)'));
  -- ...and both places the mode could have come from, so nobody is sent to the wrong
  -- screen.
  perform pg_temp.assert(v_msg like '%commission terms%' and v_msg like '%ins.commission_recognition%',
    '§1 the refusal must point at both the insurer terms and the company setting, got: ' || coalesce(v_msg, '(none)'));
  raise notice 'PASS: §1 bind is refused, names the insurer, and says where the mode should come from';
end $$;

-- ---------------------------------------------------------------------
-- §2 recording terms: vocabulary, provenance and overlap
-- ---------------------------------------------------------------------
do $$
declare v_id uuid;
begin
  perform pg_temp.jwt(pg_temp.id('admin1'));
  set local role authenticated;

  -- A mode nobody implements is refused by the same registry the company setting
  -- uses, so the two cannot drift apart.
  perform pg_temp.expect_error(
    format($q$select public.ins_propose_insurer_commission_terms(%L, 'whenever', current_date, 'Agreement 2026', 'asking for an unimplemented mode')$q$, pg_temp.id('ins_a')),
    'INS_COMMISSION_TERMS_MODE',
    '§2 an unimplemented mode');

  -- No provenance, no term: this table exists to stop bare assertions.
  perform pg_temp.expect_error(
    format($q$select public.ins_propose_insurer_commission_terms(%L, 'at_placement', current_date, '', 'a rationale that is long enough')$q$, pg_temp.id('ins_a')),
    'INS_COMMISSION_TERMS_PROVENANCE',
    '§2 terms with no agreed reference');

  reset role;
  raise notice 'PASS: §2 the mode vocabulary and the provenance requirement both hold';
end $$;

-- ---------------------------------------------------------------------
-- §3 self-approval is refused, and a second person can approve
-- ---------------------------------------------------------------------
do $$
declare v_id uuid;
begin
  perform pg_temp.jwt(pg_temp.id('admin1'));
  set local role authenticated;
  v_id := (public.ins_propose_insurer_commission_terms(
             pg_temp.id('ins_a'), 'at_placement', current_date,
             'Master agreement ALPHA 2026 clause 7.2',
             'commission is unconditional on placement under this agreement')).id;
  -- admin1 recorded it, so admin1 cannot approve it.
  perform pg_temp.expect_error(
    format($q$select public.ins_approve_insurer_commission_terms(%L)$q$, v_id),
    'INS_COMMISSION_TERMS_SELF_APPROVAL',
    '§3 approving your own terms');
  reset role;

  perform pg_temp.jwt(pg_temp.id('admin2'));
  set local role authenticated;
  perform public.ins_approve_insurer_commission_terms(v_id);
  reset role;

  perform pg_temp.assert(
    (select status = 'approved' and approved_by = pg_temp.id('admin2')
       from public.ins_insurer_commission_terms where id = v_id),
    '§3 a second admin should be able to approve the terms');
  raise notice 'PASS: §3 terms are maker-checker like every other accounting decision';
end $$;

-- ---------------------------------------------------------------------
-- §4 with terms in force, the bind succeeds and freezes what was agreed
-- ---------------------------------------------------------------------
do $$
declare p ins_policies%rowtype;
begin
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  p := pg_temp.new_policy(pg_temp.id('ins_a'));
  p := pg_temp.approve_and_bind(p.id);
  reset role;

  perform pg_temp.assert(p.status = 'active',
    '§4 the policy should now bind, got status ' || coalesce(p.status, '(none)'));
  perform pg_temp.assert(
    p.accounting_config_snapshot ->> 'commission_recognition_source' = 'insurer_agreement',
    '§4 the snapshot must record the agreement as the source, got ' ||
      coalesce(p.accounting_config_snapshot ->> 'commission_recognition_source', '(none)'));
  perform pg_temp.assert(
    p.accounting_config_snapshot ->> 'commission_recognition_effective' = 'at_placement',
    '§4 the snapshot must freeze at_placement, got ' ||
      coalesce(p.accounting_config_snapshot ->> 'commission_recognition_effective', '(none)'));
  perform pg_temp.assert(
    p.accounting_config_snapshot ->> 'commission_terms_ref' = 'Master agreement ALPHA 2026 clause 7.2',
    '§4 the snapshot must record WHICH agreement the mode came from, got ' ||
      coalesce(p.accounting_config_snapshot ->> 'commission_terms_ref', '(none)'));

  insert into pg_temp.ids(k, v) values ('policy_a', p.id);
  raise notice 'PASS: §4 an insurer agreement is what allows the bind, and it is frozen into the snapshot';
end $$;

-- ---------------------------------------------------------------------
-- §5 the other insurer is still uncovered
-- ---------------------------------------------------------------------
-- Terms for Alpha must not quietly cover Beta. This is the failure a company-wide
-- setting would have made invisible.
do $$
declare p ins_policies%rowtype; v_msg text; v_ok boolean := false;
begin
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
  p := pg_temp.new_policy(pg_temp.id('ins_b'));
  begin
    p := pg_temp.approve_and_bind(p.id);
  exception when others then
    v_msg := sqlerrm;
    v_ok := true;
  end;
  reset role;

  perform pg_temp.assert(v_ok, '§5 Beta has no terms and must not bind on Alpha''s agreement');
  perform pg_temp.assert(v_msg like '%Beta Insurance%',
    '§5 the refusal must name Beta, got: ' || coalesce(v_msg, '(none)'));
  perform pg_temp.assert(v_msg not like '%Alpha%',
    '§5 the refusal must not mention the insurer that IS covered, got: ' || coalesce(v_msg, '(none)'));
  raise notice 'PASS: §5 per-insurer means per insurer: Alpha''s agreement does not cover Beta';
end $$;

-- ---------------------------------------------------------------------
-- §6 the insurer's agreement outranks the company setting
-- ---------------------------------------------------------------------
do $$
declare v_set uuid; p ins_policies%rowtype;
begin
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
  -- A company setting cannot be effective on or before the latest posted journal
  -- entry (ACCT_SETTING_BACKDATED), and §4-§5 have already posted today's. So the
  -- default starts tomorrow, and the two policies below incept tomorrow to fall
  -- under it.
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
  -- Now configure a company default of on_premium_collection, through the real
  -- propose/approve workflow.
  perform pg_temp.jwt(pg_temp.id('admin1'));
  set local role authenticated;
  v_set := (public.acct_setting_propose(
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
              'ins.commission_recognition', 'on_premium_collection', current_date + 1,
=======
              'ins.commission_recognition', 'on_premium_collection', current_date,
>>>>>>> theirs
=======
              'ins.commission_recognition', 'on_premium_collection', current_date,
>>>>>>> theirs
=======
              'ins.commission_recognition', 'on_premium_collection', current_date,
>>>>>>> theirs
=======
              'ins.commission_recognition', 'on_premium_collection', current_date,
>>>>>>> theirs
              'house default for insurers with no negotiated term')).id;
  reset role;
  perform pg_temp.jwt(pg_temp.id('admin2'));
  set local role authenticated;
  perform public.acct_setting_approve(v_set);
  reset role;

  -- Beta, which has no agreement, now binds on the company default.
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
  p := pg_temp.new_policy(pg_temp.id('ins_b'), 100000, public.ins_local_today() + 1);
=======
  p := pg_temp.new_policy(pg_temp.id('ins_b'));
>>>>>>> theirs
=======
  p := pg_temp.new_policy(pg_temp.id('ins_b'));
>>>>>>> theirs
=======
  p := pg_temp.new_policy(pg_temp.id('ins_b'));
>>>>>>> theirs
=======
  p := pg_temp.new_policy(pg_temp.id('ins_b'));
>>>>>>> theirs
  p := pg_temp.approve_and_bind(p.id);
  reset role;
  perform pg_temp.assert(
    p.accounting_config_snapshot ->> 'commission_recognition_source' = 'tenant_setting'
    and p.accounting_config_snapshot ->> 'commission_recognition_effective' = 'on_premium_collection',
    format('§6 Beta should fall back to the company setting, got %s / %s',
      coalesce(p.accounting_config_snapshot ->> 'commission_recognition_source', '(none)'),
      coalesce(p.accounting_config_snapshot ->> 'commission_recognition_effective', '(none)')));

  -- Alpha keeps its own agreement, which says at_placement. If the company default
  -- were allowed to win, this is the assertion that would catch it.
  perform pg_temp.jwt(pg_temp.id('mgr'));
  set local role authenticated;
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
  p := pg_temp.new_policy(pg_temp.id('ins_a'), 100000, public.ins_local_today() + 1);
=======
  p := pg_temp.new_policy(pg_temp.id('ins_a'));
>>>>>>> theirs
=======
  p := pg_temp.new_policy(pg_temp.id('ins_a'));
>>>>>>> theirs
=======
  p := pg_temp.new_policy(pg_temp.id('ins_a'));
>>>>>>> theirs
=======
  p := pg_temp.new_policy(pg_temp.id('ins_a'));
>>>>>>> theirs
  p := pg_temp.approve_and_bind(p.id);
  reset role;
  perform pg_temp.assert(
    p.accounting_config_snapshot ->> 'commission_recognition_effective' = 'at_placement',
    '§6 Alpha must keep at_placement from its agreement rather than inherit the company default of on_premium_collection');
  raise notice 'PASS: §6 the agreement wins for the insurer that has one, the company default covers the rest';
end $$;

-- ---------------------------------------------------------------------
-- §7 renegotiation keeps both agreements readable
-- ---------------------------------------------------------------------
do $$
declare v_alpha uuid; v_new uuid; p ins_policies%rowtype;
begin
  select id into v_alpha from ins_insurer_commission_terms
   where tenant_id = pg_temp.id('tenant') and insurer_id = pg_temp.id('ins_a')
     and status = 'approved' limit 1;

  -- Approved terms cannot be rewritten into something else...
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
  -- Run as the table owner: for `authenticated` the update policy is `using (false)`,
  -- so the statement matches no rows and the trigger never fires. Direct writes by the
  -- app role are refused by RLS; this proves the trigger backstop for anything that
  -- bypasses it.
=======
  perform pg_temp.jwt(pg_temp.id('admin2'));
  set local role authenticated;
>>>>>>> theirs
=======
  perform pg_temp.jwt(pg_temp.id('admin2'));
  set local role authenticated;
>>>>>>> theirs
=======
  perform pg_temp.jwt(pg_temp.id('admin2'));
  set local role authenticated;
>>>>>>> theirs
=======
  perform pg_temp.jwt(pg_temp.id('admin2'));
  set local role authenticated;
>>>>>>> theirs
  perform pg_temp.expect_error(
    format($q$update ins_insurer_commission_terms set mode = 'on_insurer_settlement' where id = %L$q$, v_alpha),
    'INS_COMMISSION_TERMS_IMMUTABLE',
    '§7 rewriting approved terms');
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
=======
  reset role;
>>>>>>> theirs
=======
  reset role;
>>>>>>> theirs
=======
  reset role;
>>>>>>> theirs
=======
  reset role;
>>>>>>> theirs

  -- ...they are ended, and the new agreement is dated the day after.
  perform pg_temp.jwt(pg_temp.id('admin2'));
  set local role authenticated;
  perform public.ins_end_insurer_commission_terms(v_alpha, current_date, 'renegotiated for 2027');
  reset role;

  perform pg_temp.jwt(pg_temp.id('admin1'));
  set local role authenticated;
  v_new := (public.ins_propose_insurer_commission_terms(
              pg_temp.id('ins_a'), 'on_premium_collection', current_date + 1,
              'Master agreement ALPHA 2027 clause 4.1',
              'the 2027 agreement moves to collection-based recognition')).id;
  reset role;
  perform pg_temp.jwt(pg_temp.id('admin2'));
  set local role authenticated;
  perform public.ins_approve_insurer_commission_terms(v_new);
  reset role;

  -- Both are still on file, and the resolver picks the one in force for the date
  -- asked about -- which is the whole reason a term has an effective period.
  perform pg_temp.assert(
    (select count(*) from ins_insurer_commission_terms
      where tenant_id = pg_temp.id('tenant') and insurer_id = pg_temp.id('ins_a')
        and status = 'approved') = 2,
    '§7 both agreements should remain on file');

  perform pg_temp.assert(
    (select mode from public.platform_ins_commission_mode(
       pg_temp.id('tenant'), pg_temp.id('ins_a'), current_date)) = 'at_placement',
    '§7 today''s mode should still be the 2026 agreement');
  perform pg_temp.assert(
    (select mode from public.platform_ins_commission_mode(
       pg_temp.id('tenant'), pg_temp.id('ins_a'), current_date + 1)) = 'on_premium_collection',
    '§7 tomorrow''s mode should be the 2027 agreement');
  raise notice 'PASS: §7 renegotiation ends terms rather than rewriting them, and both stay readable';
end $$;

-- ---------------------------------------------------------------------
-- §8 the readiness report says who is covered and who is not
-- ---------------------------------------------------------------------
do $$
declare v_row record; v_gap boolean := false;
begin
  perform pg_temp.jwt(pg_temp.id('admin1'));
  set local role authenticated;
  for v_row in select * from public.ins_commission_mode_readiness() loop
    if v_row.insurer_code = 'ALPHA' then
      perform pg_temp.assert(v_row.will_bind and v_row.source = 'insurer_agreement',
        format('§8 Alpha should report its agreement, got %s / %s', v_row.source, v_row.says));
    elsif v_row.insurer_code = 'BETA' then
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
      -- §6 had to date the company default tomorrow (a setting cannot be backdated
      -- behind an entry already posted today), and this report evaluates today, so
      -- Beta is correctly reported as not yet covered rather than as covered.
      perform pg_temp.assert(not v_row.will_bind,
        format('§8 Beta should report a gap until the company default takes effect tomorrow, got %s / %s', v_row.source, v_row.says));
=======
      perform pg_temp.assert(v_row.will_bind and v_row.source = 'tenant_setting',
        format('§8 Beta should report the company default, got %s / %s', v_row.source, v_row.says));
>>>>>>> theirs
=======
      perform pg_temp.assert(v_row.will_bind and v_row.source = 'tenant_setting',
        format('§8 Beta should report the company default, got %s / %s', v_row.source, v_row.says));
>>>>>>> theirs
=======
      perform pg_temp.assert(v_row.will_bind and v_row.source = 'tenant_setting',
        format('§8 Beta should report the company default, got %s / %s', v_row.source, v_row.says));
>>>>>>> theirs
=======
      perform pg_temp.assert(v_row.will_bind and v_row.source = 'tenant_setting',
        format('§8 Beta should report the company default, got %s / %s', v_row.source, v_row.says));
>>>>>>> theirs
    end if;
    perform pg_temp.assert(v_row.says is not null, '§8 every insurer should carry a sentence, not just a flag');
    v_gap := v_gap or not v_row.will_bind;
  end loop;
  reset role;
  raise notice 'PASS: §8 an accountant can see coverage per insurer before a client is waiting';
end $$;

do $$ begin
  raise notice 'ALL PASS: bind is refused per insurer, the refusal names the insurer, agreements outrank the company default, and renegotiation keeps history';
end $$;

rollback;
