-- Regression test for:
--   supabase/migrations/20261008083846_template_kinds_gl_flags_apply_template.sql
--
-- Verifies, against a fully-migrated fresh stack:
--   1. The 5 insurance posting roles are accepted by gl_posting_rules and the
--      original roles still are; platform_gl_posting_roles() matches the CHECK
--      exactly (drift guard); an unknown role is still refused.
--   2. save_industry_template() accepts gl_account / posting_rule / feature_flag
--      items and refuses: a bad account type or code, a duplicate item, an unknown
--      role, a rule pointing at an account that is not in the template, an unknown
--      flag, a non-boolean flag value, a missing or unknown kind. Saving back exactly
--      what was read (what the editor does) keeps every item and payload.
--   3. apply_template() is platform-admin only; a bad mode and a fill without a
--      reason are refused; preview writes nothing.
--   4. fill adds modules (and gives the company admin a role on them), departments,
--      flags, accounts and posting rules, and writes an audit event.
--   5. fill is idempotent: a second run adds nothing.
--   6. fill never overwrites: an account with the same code and another type, a
--      posting rule already pointing elsewhere, a differing flag override and a
--      case/space-variant department are left alone and reported as conflicts.
--   7. seed_tenant_defaults() applies the new kinds on a fresh tenant, still applies
--      them when the departments early-return fires (without touching departments,
--      modules or the tenant's template label), and adds no chart for `general`.
--
-- Run against a fresh local stack only -- never against a linked project.

\set ON_ERROR_STOP on

begin;

do $$
declare
  v_home  uuid := gen_random_uuid();
  v_admin uuid := gen_random_uuid();
  v_user  uuid := gen_random_uuid();
  v_cadm  uuid := gen_random_uuid();
  t_a     uuid := gen_random_uuid();  -- fills cleanly
  t_b     uuid := gen_random_uuid();  -- has conflicting pre-existing data
  t_c     uuid := gen_random_uuid();  -- fresh, seeded
  t_d     uuid := gen_random_uuid();  -- already has a department, seeded
  t_e     uuid := gen_random_uuid();  -- general template, seeded
begin
  create temp table test_ids (k text primary key, v uuid) on commit drop;
  insert into test_ids values ('home', v_home), ('admin', v_admin), ('user', v_user), ('cadm', v_cadm),
    ('t_a', t_a), ('t_b', t_b), ('t_c', t_c), ('t_d', t_d), ('t_e', t_e);
  grant select on test_ids to authenticated, anon, service_role;

  create temp table results (k text primary key, v jsonb) on commit drop;
  grant select, insert, update on results to authenticated;

  insert into tenants (id, name, status, created_at, plan, subscription_status, industry_template) values
    (v_home, 'Tpl Test Platform Home', 'active', now() - interval '300 days', 'internal', 'active', 'general'),
    (t_a, 'Tpl Test A', 'active', now() - interval '30 days', 'trial', 'trialing', 'general'),
    (t_b, 'Tpl Test B', 'active', now() - interval '30 days', 'trial', 'trialing', 'general'),
    (t_c, 'Tpl Test C', 'active', now() - interval '30 days', 'trial', 'trialing', 'general'),
    (t_d, 'Tpl Test D', 'active', now() - interval '30 days', 'trial', 'trialing', 'general'),
    (t_e, 'Tpl Test E', 'active', now() - interval '30 days', 'trial', 'trialing', 'general');

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, recovery_token, last_sign_in_at
  )
  select
    '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
    u.handle || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
    now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', '', now()
  from (values (v_admin, 'tpl-admin'), (v_user, 'tpl-user'), (v_cadm, 'tpl-cadm')) as u(id, handle);

  insert into auth.mfa_factors (id, user_id, friendly_name, factor_type, status, created_at, updated_at)
   values (gen_random_uuid(), v_admin, 'test', 'totp', 'verified', now(), now());

  update app_users set is_platform_admin = false where is_platform_admin;

  insert into app_users (id, tenant_id, name, email, is_platform_admin, is_company_admin, created_at) values
    (v_admin, v_home, 'Tpl Admin',  'tpl-admin@test.local', true,  false, now() - interval '300 days'),
    (v_user,  t_a,    'Tpl User',   'tpl-user@test.local',  false, false, now() - interval '3 days'),
    (v_cadm,  t_a,    'Tpl CAdmin', 'tpl-cadm@test.local',  false, true,  now() - interval '3 days');

  -- A module only the template carries, and two flags it can default.
  insert into platform_modules (key, name, tier, vertical, route_base)
  values ('tpltest_pack', 'Template Test Pack', 'vertical', 'tpltest', '/tpltest');
  insert into platform_feature_flags (key, description, default_enabled)
  values ('tpltest.flag_on', 'Template test flag', false),
         ('tpltest.flag_off', 'Template test flag 2', true);
end $$;

create or replace function pg_temp.become(p_key text, p_aal text default 'aal2') returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', (select v from test_ids where k = p_key), 'role', 'authenticated', 'aal', p_aal)::text, true);
end $$;

create or replace function pg_temp.tid(p_key text) returns uuid
language sql as $$ select v from test_ids where k = p_key $$;

create or replace function pg_temp.assert(p_ok boolean, p_msg text) returns void
language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_msg; end if;
end $$;

-- save_industry_template() must refuse p_items with a TEMPLATE_ITEMS_INVALID message containing p_expect.
create or replace function pg_temp.expect_invalid(p_label text, p_items text, p_expect text) returns void
language plpgsql as $$
declare v_ok boolean := false;
begin
  begin
    perform save_industry_template('tpl_bad', 'Bad', null, p_items::jsonb);
    v_ok := true;
  exception when others then
    if sqlerrm not like 'TEMPLATE_ITEMS_INVALID:%' || p_expect || '%' then
      raise exception 'FAIL (%): unexpected error: %', p_label, sqlerrm;
    end if;
  end;
  if v_ok then raise exception 'FAIL (%): accepted', p_label; end if;
end $$;

-- Any statement must fail; if p_expect is given, the message must contain it.
create or replace function pg_temp.expect_error(p_label text, p_sql text, p_expect text default null) returns void
language plpgsql as $$
declare v_ok boolean := false;
begin
  begin
    execute p_sql;
    v_ok := true;
  exception when others then
    if p_expect is not null and sqlerrm not like '%' || p_expect || '%' then
      raise exception 'FAIL (%): unexpected error: %', p_label, sqlerrm;
    end if;
  end;
  if v_ok then raise exception 'FAIL (%): succeeded', p_label; end if;
end $$;

-- Row counts for one tenant, as one jsonb, so before/after can be compared.
create or replace function pg_temp.counts(p_tenant uuid) returns jsonb
language sql as $$
  select jsonb_build_object(
    'modules',  (select count(*) from tenant_modules where tenant_id = p_tenant),
    'depts',    (select count(*) from departments where tenant_id = p_tenant),
    'flags',    (select count(*) from tenant_feature_flags where tenant_id = p_tenant),
    'accounts', (select count(*) from gl_accounts where tenant_id = p_tenant),
    'rules',    (select count(*) from gl_posting_rules where tenant_id = p_tenant))
$$;

-- ---------------------------------------------------------------------
-- 1. Posting roles (as table owner)
-- ---------------------------------------------------------------------
do $$
declare
  v_role text; v_acct uuid; v_def text; v_n int; v_lits int;
begin
  select pg_get_constraintdef(oid) into v_def from pg_constraint
   where conrelid = 'public.gl_posting_rules'::regclass and conname = 'gl_posting_rules_account_role_check';
  perform pg_temp.assert(v_def is not null, 'role CHECK missing');

  select count(*) into v_n from unnest(platform_gl_posting_roles()) r where v_def like '%''' || r || '''%';
  select count(*) into v_lits from regexp_matches(v_def, '''[a-z_]+''::text', 'g');
  perform pg_temp.assert(v_n = cardinality(platform_gl_posting_roles()) and v_lits = cardinality(platform_gl_posting_roles()),
    format('platform_gl_posting_roles() (%s) and the CHECK (%s literals) disagree', cardinality(platform_gl_posting_roles()), v_lits));
  perform pg_temp.assert(cardinality(platform_gl_posting_roles()) = 18, 'expected 18 roles');

  insert into gl_accounts (tenant_id, account_code, name, account_type)
  values (pg_temp.tid('home'), 'ROLE', 'Role probe', 'asset') returning id into v_acct;
  foreach v_role in array array['client_money_bank', 'insurer_payable', 'commission_receivable',
                                'commission_income', 'wht_receivable', 'bank', 'salaries_expense'] loop
    insert into gl_posting_rules (tenant_id, account_role, gl_account_id) values (pg_temp.tid('home'), v_role, v_acct);
  end loop;
  begin
    insert into gl_posting_rules (tenant_id, account_role, gl_account_id) values (pg_temp.tid('home'), 'made_up_role', v_acct);
    raise exception 'FAIL: unknown posting role accepted';
  exception when check_violation then null; end;
  delete from gl_posting_rules where tenant_id = pg_temp.tid('home');
  delete from gl_accounts where tenant_id = pg_temp.tid('home');
end $$;

-- ---------------------------------------------------------------------
-- 2. save_industry_template validation and round-trip (as platform admin)
-- ---------------------------------------------------------------------
set local role authenticated;
select pg_temp.become('admin');

do $$
declare
  v_base jsonb := '[
    {"kind":"department","name":"Claims"},
    {"kind":"department","name":"Underwriting"},
    {"kind":"module","name":"tpltest_pack"},
    {"kind":"module","name":"hr"},
    {"kind":"feature_flag","name":"tpltest.flag_on","payload":{"enabled":true}},
    {"kind":"gl_account","name":"1000","payload":{"name":"Operating Bank","account_type":"asset","is_control_account":true}},
    {"kind":"gl_account","name":"1050","payload":{"name":"Client Money Bank","account_type":"asset","is_control_account":true}},
    {"kind":"gl_account","name":"2100","payload":{"name":"Insurer Payable","account_type":"liability","is_control_account":true}},
    {"kind":"posting_rule","name":"bank","payload":{"account_code":"1000"}},
    {"kind":"posting_rule","name":"client_money_bank","payload":{"account_code":"1050"}},
    {"kind":"posting_rule","name":"insurer_payable","payload":{"account_code":"2100"}}
  ]'::jsonb;
  v_saved jsonb;
begin
  perform pg_temp.expect_invalid('bad type',
    '[{"kind":"gl_account","name":"1","payload":{"name":"X","account_type":"income"}}]', 'invalid account_type');
  perform pg_temp.expect_invalid('no payload name',
    '[{"kind":"gl_account","name":"1","payload":{"account_type":"asset"}}]', 'needs a name in its payload');
  perform pg_temp.expect_invalid('bad code',
    '[{"kind":"gl_account","name":"bad code!","payload":{"name":"X","account_type":"asset"}}]', 'must be 1-20 characters');
  perform pg_temp.expect_invalid('bad control flag',
    '[{"kind":"gl_account","name":"1","payload":{"name":"X","account_type":"asset","is_control_account":"yes"}}]', 'is_control_account must be true or false');
  perform pg_temp.expect_invalid('duplicate code',
    '[{"kind":"gl_account","name":"1","payload":{"name":"X","account_type":"asset"}},{"kind":"gl_account","name":"1","payload":{"name":"Y","account_type":"asset"}}]',
    'duplicate item');
  perform pg_temp.expect_invalid('unknown role',
    '[{"kind":"gl_account","name":"1","payload":{"name":"X","account_type":"asset"}},{"kind":"posting_rule","name":"nope","payload":{"account_code":"1"}}]',
    'unknown posting role');
  perform pg_temp.expect_invalid('rule to missing account',
    '[{"kind":"gl_account","name":"1","payload":{"name":"X","account_type":"asset"}},{"kind":"posting_rule","name":"bank","payload":{"account_code":"2"}}]',
    'not a gl_account in this template');
  perform pg_temp.expect_invalid('rule with no account',
    '[{"kind":"posting_rule","name":"bank","payload":{}}]', 'not a gl_account in this template');
  perform pg_temp.expect_invalid('unknown flag',
    '[{"kind":"feature_flag","name":"no.such.flag"}]', 'unknown feature flag');
  perform pg_temp.expect_invalid('non-boolean flag',
    '[{"kind":"feature_flag","name":"tpltest.flag_on","payload":{"enabled":"on"}}]', 'enabled must be true or false');
  perform pg_temp.expect_invalid('missing kind', '[{"name":"x"}]', 'unknown kind (missing)');
  perform pg_temp.expect_invalid('unknown kind', '[{"kind":"lookup","name":"x"}]', 'unknown kind lookup');

  perform save_industry_template('tpl_ins', 'Template Test Insurance', null, v_base);

  select coalesce(jsonb_agg(jsonb_build_object('kind', kind, 'sort_order', sort_order, 'name', name, 'payload', payload)
                            order by kind, sort_order), '[]')
    into v_saved from industry_template_items where template_key = 'tpl_ins';
  insert into results values ('saved_before', v_saved);
  perform save_industry_template('tpl_ins', 'Template Test Insurance', null, v_saved);
  select coalesce(jsonb_agg(jsonb_build_object('kind', kind, 'sort_order', sort_order, 'name', name, 'payload', payload)
                            order by kind, sort_order), '[]')
    into v_saved from industry_template_items where template_key = 'tpl_ins';
  insert into results values ('saved_after', v_saved);
end $$;
reset role;

do $$
begin
  perform pg_temp.assert(jsonb_array_length((select v from results where k = 'saved_before')) = 11,
    'expected 11 items after the first save');
  perform pg_temp.assert((select v from results where k = 'saved_before') = (select v from results where k = 'saved_after'),
    're-saving the items changed them');
  perform pg_temp.assert((select count(*) from industry_template_items where template_key = 'tpl_ins' and kind = 'gl_account') = 3
    and (select count(*) from industry_template_items where template_key = 'tpl_ins' and kind = 'posting_rule') = 3
    and (select count(*) from industry_template_items where template_key = 'tpl_ins' and kind = 'feature_flag') = 1,
    'GL / posting / flag items missing after save');
  perform pg_temp.assert(not exists (select 1 from industry_templates where key = 'tpl_bad'),
    'a rejected save left a template behind');
end $$;

-- ---------------------------------------------------------------------
-- 3. Access, mode, reason, preview writes nothing
-- ---------------------------------------------------------------------
set local role authenticated;
select pg_temp.become('user');
do $$
begin
  perform pg_temp.expect_error('plain user preview',
    format('select apply_template(%L, ''tpl_ins'', ''preview'')', pg_temp.tid('t_a')));
  perform pg_temp.expect_error('plain user fill',
    format('select apply_template(%L, ''tpl_ins'', ''fill'', ''some reason here'')', pg_temp.tid('t_a')));
  perform pg_temp.expect_error('plain user seed',
    format('select seed_tenant_defaults(%L, ''tpl_ins'')', pg_temp.tid('t_c')));
end $$;

select pg_temp.become('admin');
do $$
begin
  perform pg_temp.expect_error('bad mode',
    format('select apply_template(%L, ''tpl_ins'', ''overwrite'', ''some reason here'')', pg_temp.tid('t_a')), 'TEMPLATE_MODE_INVALID');
  perform pg_temp.expect_error('fill without reason',
    format('select apply_template(%L, ''tpl_ins'', ''fill'')', pg_temp.tid('t_a')), 'REASON_REQUIRED');
  perform pg_temp.expect_error('fill with short reason',
    format('select apply_template(%L, ''tpl_ins'', ''fill'', ''x'')', pg_temp.tid('t_a')), 'REASON_REQUIRED');
  perform pg_temp.expect_error('unknown template',
    format('select apply_template(%L, ''no_such_tpl'', ''preview'')', pg_temp.tid('t_a')), 'TEMPLATE_NOT_FOUND');
  perform pg_temp.expect_error('unknown tenant',
    'select apply_template(gen_random_uuid(), ''tpl_ins'', ''preview'')', 'TENANT_NOT_FOUND');

  insert into results values ('preview_a', apply_template(pg_temp.tid('t_a'), 'tpl_ins', 'preview'));
end $$;
reset role;

do $$
declare v jsonb := (select v from results where k = 'preview_a');
begin
  perform pg_temp.assert(pg_temp.counts(pg_temp.tid('t_a')) = '{"modules":0,"depts":0,"flags":0,"accounts":0,"rules":0}'::jsonb,
    'preview wrote rows');
  perform pg_temp.assert((v ->> 'applied')::boolean = false and v ->> 'mode' = 'preview', 'preview result flags wrong');
  perform pg_temp.assert(jsonb_array_length(v -> 'modules') = 2 and jsonb_array_length(v -> 'departments') = 2
    and jsonb_array_length(v -> 'feature_flags') = 1 and jsonb_array_length(v -> 'gl_accounts') = 3
    and jsonb_array_length(v -> 'posting_rules') = 3 and jsonb_array_length(v -> 'conflicts') = 0,
    format('preview on an empty tenant should list everything, got %s', v));
  perform pg_temp.assert(not exists (select 1 from platform_audit_events where action = 'tenant.template.apply'),
    'preview wrote an audit event');
end $$;

-- ---------------------------------------------------------------------
-- 4. fill on a clean tenant
-- ---------------------------------------------------------------------
set local role authenticated;
select pg_temp.become('admin');
do $$
begin
  insert into results values ('fill_a', apply_template(pg_temp.tid('t_a'), 'tpl_ins', 'fill', 'template test fill'));
end $$;
reset role;

do $$
declare t uuid := pg_temp.tid('t_a'); v jsonb := (select v from results where k = 'fill_a');
begin
  perform pg_temp.assert((v ->> 'applied')::boolean, 'fill result not marked applied');
  perform pg_temp.assert(pg_temp.counts(t) = '{"modules":2,"depts":2,"flags":1,"accounts":3,"rules":3}'::jsonb,
    format('fill counts wrong: %s', pg_temp.counts(t)));
  perform pg_temp.assert(exists (select 1 from tenant_modules where tenant_id = t and module = 'tpltest_pack')
    and exists (select 1 from tenant_modules where tenant_id = t and module = 'hr'), 'modules not entitled');
  perform pg_temp.assert(exists (select 1 from staff_roles where tenant_id = t and user_id = pg_temp.tid('cadm') and module = 'tpltest_pack' and role = 'admin')
    and exists (select 1 from staff_roles where tenant_id = t and user_id = pg_temp.tid('cadm') and module = 'hr' and role = 'admin'),
    'company admin did not get roles on the newly entitled modules');
  perform pg_temp.assert((select count(*) from departments where tenant_id = t and name in ('Claims', 'Underwriting')) = 2, 'departments missing');
  perform pg_temp.assert((select enabled from tenant_feature_flags where tenant_id = t and flag_key = 'tpltest.flag_on') is true, 'flag not set');
  perform pg_temp.assert((select is_control_account from gl_accounts where tenant_id = t and account_code = '1000') is true
    and (select account_type from gl_accounts where tenant_id = t and account_code = '2100') = 'liability'
    and (select name from gl_accounts where tenant_id = t and account_code = '1050') = 'Client Money Bank', 'account attributes wrong');
  perform pg_temp.assert((select a.account_code from gl_posting_rules r join gl_accounts a on a.id = r.gl_account_id
                           where r.tenant_id = t and r.account_role = 'client_money_bank') = '1050'
    and (select a.account_code from gl_posting_rules r join gl_accounts a on a.id = r.gl_account_id
          where r.tenant_id = t and r.account_role = 'insurer_payable') = '2100', 'posting rules point at the wrong accounts');
  perform pg_temp.assert((select count(*) from platform_audit_events
                           where action = 'tenant.template.apply' and tenant_id = t and reason = 'template test fill') = 1,
    'expected exactly one apply audit event');
end $$;

-- ---------------------------------------------------------------------
-- 5. Idempotence
-- ---------------------------------------------------------------------
set local role authenticated;
select pg_temp.become('admin');
do $$
begin
  insert into results values ('fill_a2', apply_template(pg_temp.tid('t_a'), 'tpl_ins', 'fill', 'template test refill'));
end $$;
reset role;

do $$
declare t uuid := pg_temp.tid('t_a'); v jsonb := (select v from results where k = 'fill_a2');
begin
  perform pg_temp.assert(jsonb_array_length(v -> 'modules') = 0 and jsonb_array_length(v -> 'departments') = 0
    and jsonb_array_length(v -> 'feature_flags') = 0 and jsonb_array_length(v -> 'gl_accounts') = 0
    and jsonb_array_length(v -> 'posting_rules') = 0 and jsonb_array_length(v -> 'conflicts') = 0,
    format('second fill should add nothing, got %s', v));
  perform pg_temp.assert(pg_temp.counts(t) = '{"modules":2,"depts":2,"flags":1,"accounts":3,"rules":3}'::jsonb, 'second fill changed counts');
end $$;

-- ---------------------------------------------------------------------
-- 6. Never overwrite
-- ---------------------------------------------------------------------
do $$
declare t uuid := pg_temp.tid('t_b'); v_zz uuid;
begin
  insert into tenant_modules (tenant_id, module) values (t, 'hr');
  insert into departments (tenant_id, name) values (t, ' claims ');
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (t, '1000', 'Existing Bank', 'liability');
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (t, 'ZZ', 'Other', 'asset') returning id into v_zz;
  insert into gl_posting_rules (tenant_id, account_role, gl_account_id) values (t, 'bank', v_zz);
  insert into tenant_feature_flags (tenant_id, flag_key, enabled) values (t, 'tpltest.flag_on', false);
end $$;

set local role authenticated;
select pg_temp.become('admin');
do $$
begin
  insert into results values ('preview_b', apply_template(pg_temp.tid('t_b'), 'tpl_ins', 'preview'));
  insert into results values ('fill_b', apply_template(pg_temp.tid('t_b'), 'tpl_ins', 'fill', 'template test conflicts'));
end $$;
reset role;

do $$
declare t uuid := pg_temp.tid('t_b'); p jsonb := (select v from results where k = 'preview_b'); f jsonb := (select v from results where k = 'fill_b');
begin
  perform pg_temp.assert(jsonb_array_length(p -> 'conflicts') = 3, format('expected 3 conflicts in preview, got %s', p -> 'conflicts'));
  perform pg_temp.assert(jsonb_array_length(p -> 'gl_accounts') = 2 and jsonb_array_length(p -> 'posting_rules') = 2
    and jsonb_array_length(p -> 'departments') = 1 and jsonb_array_length(p -> 'modules') = 1
    and jsonb_array_length(p -> 'feature_flags') = 0, format('preview additions wrong: %s', p));
  perform pg_temp.assert(p - 'mode' - 'applied' = f - 'mode' - 'applied', 'fill did not do exactly what preview said');

  perform pg_temp.assert((select account_type from gl_accounts where tenant_id = t and account_code = '1000') = 'liability'
    and (select name from gl_accounts where tenant_id = t and account_code = '1000') = 'Existing Bank', 'existing account was overwritten');
  perform pg_temp.assert((select a.account_code from gl_posting_rules r join gl_accounts a on a.id = r.gl_account_id
                           where r.tenant_id = t and r.account_role = 'bank') = 'ZZ', 'existing posting rule was repointed');
  perform pg_temp.assert((select enabled from tenant_feature_flags where tenant_id = t and flag_key = 'tpltest.flag_on') is false,
    'existing flag override was changed');
  perform pg_temp.assert((select count(*) from departments where tenant_id = t) = 2, 'department duplicated or missing');
  perform pg_temp.assert(pg_temp.counts(t) = '{"modules":2,"depts":2,"flags":1,"accounts":4,"rules":3}'::jsonb,
    format('conflict fill counts wrong: %s', pg_temp.counts(t)));
end $$;

-- ---------------------------------------------------------------------
-- 7. seed_tenant_defaults
-- ---------------------------------------------------------------------
insert into departments (tenant_id, name) values (pg_temp.tid('t_d'), 'Existing Dept');

set local role authenticated;
select pg_temp.become('admin');
do $$
begin
  perform seed_tenant_defaults(pg_temp.tid('t_c'), 'tpl_ins');
  perform seed_tenant_defaults(pg_temp.tid('t_d'), 'tpl_ins');
  perform seed_tenant_defaults(pg_temp.tid('t_e'), 'general');
  perform seed_tenant_defaults(pg_temp.tid('t_c'), 'tpl_ins');  -- repeat is a no-op
end $$;
reset role;

do $$
begin
  -- fresh tenant: everything
  perform pg_temp.assert(pg_temp.counts(pg_temp.tid('t_c')) = '{"modules":2,"depts":2,"flags":1,"accounts":3,"rules":3}'::jsonb,
    format('fresh seed counts wrong: %s', pg_temp.counts(pg_temp.tid('t_c'))));
  perform pg_temp.assert((select industry_template from tenants where id = pg_temp.tid('t_c')) = 'tpl_ins', 'template label not set on fresh seed');

  -- early-return tenant: departments/modules/label untouched, chart and flags applied
  perform pg_temp.assert(pg_temp.counts(pg_temp.tid('t_d')) = '{"modules":0,"depts":1,"flags":1,"accounts":3,"rules":3}'::jsonb,
    format('early-return seed counts wrong: %s', pg_temp.counts(pg_temp.tid('t_d'))));
  perform pg_temp.assert((select industry_template from tenants where id = pg_temp.tid('t_d')) = 'general',
    'early-return seed changed the tenant template label');

  -- general template: no chart, no rules, no flags
  perform pg_temp.assert((select count(*) from gl_accounts where tenant_id = pg_temp.tid('t_e')) = 0
    and (select count(*) from gl_posting_rules where tenant_id = pg_temp.tid('t_e')) = 0
    and (select count(*) from tenant_feature_flags where tenant_id = pg_temp.tid('t_e')) = 0,
    'the general template must not create a chart, rules or flags');
  perform pg_temp.assert(not exists (select 1 from industry_template_items
                                      where template_key in ('general', 'construction')
                                        and kind in ('gl_account', 'posting_rule', 'feature_flag')),
    'general / construction templates must not carry GL or flag items');
end $$;

rollback;
