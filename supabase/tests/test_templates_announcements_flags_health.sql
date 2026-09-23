-- Regression test for:
--   supabase/migrations/20260923090000_templates_announcements_flags_health.sql
--
-- Verifies, against a fully-migrated fresh stack:
--   1. Industry templates: the two seeded presets reproduce the previous
--      hard-coded seed_tenant_defaults() output exactly (departments,
--      modules, 7 stages with low/high routing and the 5,000,000
--      threshold); unknown / inactive keys are refused; a new template
--      saved through save_industry_template() seeds a company; validation
--      rejects bad keys, unknown modules and dangling stage routes;
--      templates in use cannot be deleted; default switching is exclusive.
--   2. apply_workflow_template(): refuses while a request is mid-pipeline,
--      otherwise retires the old stages (is_active=false, ids preserved)
--      and materialises the new ones; audited.
--   3. Announcements: window + targeting + dismissal semantics of
--      get_active_announcements(); critical never dismissible; admin
--      list/save/delete gated; plain users cannot read the table.
--   4. Feature flags: default -> override -> clear resolution via
--      feature_enabled() and get_my_feature_flags(); impersonation
--      resolves for the impersonated tenant; admin RPCs gated.
--   5. Health: platform_job_runs is written by the sweeps and the digest
--      wrapper; get_platform_health() is admin-only and reports jobs,
--      stuck approvals, stale invites, migrations and cron.
--
-- Run against a fresh local stack only -- never against a linked project.

\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------
do $$
declare
  v_home   uuid := gen_random_uuid();
  v_admin  uuid := gen_random_uuid();   -- platform admin, MFA enrolled
  v_plain  uuid := gen_random_uuid();   -- member of t_a with a department
  v_other  uuid := gen_random_uuid();   -- member of t_b
  t_a      uuid := gen_random_uuid();   -- seeded 'general'
  t_b      uuid := gen_random_uuid();   -- seeded 'construction'
  t_c      uuid := gen_random_uuid();   -- seeded from a custom template
begin
  create temp table test_ids (k text primary key, v uuid) on commit drop;
  insert into test_ids values ('home', v_home), ('admin', v_admin), ('plain', v_plain), ('other', v_other),
    ('t_a', t_a), ('t_b', t_b), ('t_c', t_c);
  grant select, insert on test_ids to authenticated, anon, service_role;

  insert into tenants (id, name, status, created_at, plan, subscription_status, industry_template) values
    (v_home, 'Tpl Test Platform Home', 'active', now() - interval '300 days', 'internal', 'active', 'general'),
    (t_a,    'Tpl General Co',         'active', now() - interval '30 days',  'trial', 'trialing', 'general'),
    (t_b,    'Tpl Construction Co',    'active', now() - interval '30 days',  'trial', 'trialing', 'construction'),
    (t_c,    'Tpl Custom Co',          'pending', now() - interval '1 day',   'trial', 'trialing', 'general');

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, recovery_token, last_sign_in_at
  )
  select
    '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
    u.handle || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
    now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', '', now()
  from (values (v_admin, 'tpl-admin'), (v_plain, 'tpl-plain'), (v_other, 'tpl-other')) as u(id, handle);

  insert into auth.mfa_factors (id, user_id, friendly_name, factor_type, status, created_at, updated_at)
   values (gen_random_uuid(), v_admin, 'test', 'totp', 'verified', now(), now());

  update app_users set is_platform_admin = false where is_platform_admin;

  insert into app_users (id, tenant_id, name, email, is_platform_admin, is_company_admin, created_at) values
    (v_admin, v_home, 'Tpl Admin', 'tpl-admin@test.local', true,  false, now() - interval '300 days'),
    (v_plain, t_a,    'Tpl Plain', 'tpl-plain@test.local', false, false, now() - interval '3 days'),
    (v_other, t_b,    'Tpl Other', 'tpl-other@test.local', false, false, now() - interval '3 days');

  -- Stale invite for the health report.
  insert into invitations (tenant_id, email, invited_by, role_bundle, status, created_at) values
    (t_b, 'stale@x.test', v_admin, 'member', 'pending', now() - interval '12 days');

  delete from platform_job_runs;
  delete from platform_announcements;
  delete from platform_feature_flags;
end $$;

create or replace function pg_temp.become(p_key text, p_aal text default 'aal2') returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', (select v from test_ids where k = p_key), 'role', 'authenticated', 'aal', p_aal)::text, true);
end $$;

-- RLS on departments / workflow_stages / tenant_modules is tenant-scoped
-- with no platform-admin bypass, so verify seeded rows through a
-- security-definer helper (owned by postgres, bypasses RLS) rather than
-- as the admin.
create or replace function pg_temp.n(p_sql text) returns bigint
language plpgsql security definer as $$
declare v bigint; begin execute p_sql into v; return v; end $$;
create or replace function pg_temp.j(p_sql text) returns jsonb
language plpgsql security definer as $$
declare v jsonb; begin execute 'select to_jsonb(x) from (' || p_sql || ') x' into v; return v; end $$;
grant execute on function pg_temp.n(text), pg_temp.j(text) to authenticated;

-- ---------------------------------------------------------------------
-- 1. Industry templates
-- ---------------------------------------------------------------------
set local role authenticated;
select pg_temp.become('admin');
do $$
declare
  t_a uuid := (select v from test_ids where k = 't_a');
  t_b uuid := (select v from test_ids where k = 't_b');
  t_c uuid := (select v from test_ids where k = 't_c');
  v_n int;
  s4 record; s5 uuid; s6 uuid; s7 uuid;
  v_json jsonb;
begin
  -- seeded presets are listed, general is default
  if (select count(*) from list_industry_templates()) < 2 then raise exception 'FAIL: presets missing'; end if;
  if (select key from list_industry_templates() where is_default) <> 'general' then raise exception 'FAIL: general not default'; end if;
  select department_count, module_count, stage_count into s4 from list_industry_templates() where key = 'construction';
  if s4.department_count <> 10 or s4.module_count <> 8 or s4.stage_count <> 7 then
    raise exception 'FAIL: construction counts %', to_jsonb(s4);
  end if;

  -- seed general
  perform seed_tenant_defaults(t_a, 'general');
  v_n := pg_temp.n(format('select count(*) from departments where tenant_id = %L', t_a));
  if v_n <> 8 then raise exception 'FAIL: general departments = %', v_n; end if;
  v_n := pg_temp.n(format('select count(*) from tenant_modules where tenant_id = %L', t_a));
  if v_n <> 6 then raise exception 'FAIL: general modules = %', v_n; end if;
  v_n := pg_temp.n(format('select count(*) from workflow_stages where tenant_id = %L and is_active and applies_to = ''requests''', t_a));
  if v_n <> 7 then raise exception 'FAIL: general stages = %', v_n; end if;

  -- routing: stage 4 threshold 5,000,000 -> low = Finance(5), high = PM(6); PM -> DGM(7); DGM -> Finance(5)
  v_json := pg_temp.j(format('select * from workflow_stages where tenant_id = %L and sequence_order = 4', t_a));
  s5 := (pg_temp.j(format('select id from workflow_stages where tenant_id = %L and sequence_order = 5', t_a)) ->> 'id')::uuid;
  s6 := (pg_temp.j(format('select id from workflow_stages where tenant_id = %L and sequence_order = 6', t_a)) ->> 'id')::uuid;
  s7 := (pg_temp.j(format('select id from workflow_stages where tenant_id = %L and sequence_order = 7', t_a)) ->> 'id')::uuid;
  if v_json ->> 'name' <> 'Control Chief/Manager' or v_json ->> 'approver_role' <> 'Procurement & Logistics Chief' or (v_json ->> 'threshold_amount')::numeric <> 5000000 then
    raise exception 'FAIL: stage 4 = %', v_json;
  end if;
  if (v_json ->> 'next_stage_low_id')::uuid <> s5 or (v_json ->> 'next_stage_high_id')::uuid <> s6 then raise exception 'FAIL: stage 4 routing'; end if;
  if (pg_temp.j(format('select next_stage_low_id as x from workflow_stages where id = %L', s6)) ->> 'x')::uuid <> s7 then raise exception 'FAIL: PM -> DGM'; end if;
  if (pg_temp.j(format('select next_stage_low_id as x from workflow_stages where id = %L', s7)) ->> 'x')::uuid <> s5 then raise exception 'FAIL: DGM -> Finance'; end if;
  if pg_temp.n(format('select count(*) from workflow_stages a join workflow_stages b on b.id = a.next_stage_low_id where a.tenant_id = %L and a.sequence_order = 1 and b.sequence_order = 2', t_a)) <> 1 then
    raise exception 'FAIL: 1 -> 2';
  end if;
  if (pg_temp.j(format('select next_stage_low_id as x from workflow_stages where id = %L', s5)) ->> 'x') is not null then raise exception 'FAIL: Finance terminal'; end if;

  -- idempotent
  perform seed_tenant_defaults(t_a, 'general');
  v_n := pg_temp.n(format('select count(*) from departments where tenant_id = %L', t_a));
  if v_n <> 8 then raise exception 'FAIL: reseed not idempotent (%)', v_n; end if;

  -- construction
  perform seed_tenant_defaults(t_b, 'construction');
  v_n := pg_temp.n(format('select count(*) from departments where tenant_id = %L', t_b));
  if v_n <> 10 then raise exception 'FAIL: construction departments = %', v_n; end if;
  if pg_temp.n(format('select count(*) from departments where tenant_id = %L and name = ''Machine Operations''', t_b)) <> 1 then raise exception 'FAIL: no Machine Operations'; end if;
  v_n := pg_temp.n(format('select count(*) from tenant_modules where tenant_id = %L and module in (''machine_operation'', ''sustainability'')', t_b));
  if v_n <> 2 then raise exception 'FAIL: construction extra modules = %', v_n; end if;
  if (pg_temp.j(format('select enabled_by from tenant_modules where tenant_id = %L and module = ''hr''', t_b)) ->> 'enabled_by')::uuid <> (select v from test_ids where k = 'admin') then
    raise exception 'FAIL: enabled_by not the caller';
  end if;

  -- unknown key refused
  begin
    perform seed_tenant_defaults(t_c, 'mining');
    raise exception 'FAIL: unknown template accepted';
  exception when others then
    if sqlerrm not like 'TEMPLATE_NOT_FOUND%' then raise; end if;
  end;

  -- validation on save
  begin
    perform save_industry_template('Mining!', 'Mining', null, '[]'::jsonb);
    raise exception 'FAIL: bad key accepted';
  exception when others then if sqlerrm not like 'TEMPLATE_KEY_INVALID%' then raise; end if; end;
  begin
    perform save_industry_template('mining', 'Mining', null, '[{"kind":"module","name":"crypto"}]'::jsonb);
    raise exception 'FAIL: unknown module accepted';
  exception when others then if sqlerrm not like 'TEMPLATE_ITEMS_INVALID%' then raise; end if; end;
  begin
    perform save_industry_template('mining', 'Mining', null,
      '[{"kind":"workflow_stage","sort_order":1,"name":"A","payload":{"approver_role":"X","next_low":9}}]'::jsonb);
    raise exception 'FAIL: dangling route accepted';
  exception when others then if sqlerrm not like 'TEMPLATE_ITEMS_INVALID%' then raise; end if; end;
  begin
    perform save_industry_template('mining', 'Mining', null,
      '[{"kind":"workflow_stage","sort_order":1,"name":"A","payload":{}}]'::jsonb);
    raise exception 'FAIL: stage without approver accepted';
  exception when others then if sqlerrm not like 'TEMPLATE_ITEMS_INVALID%' then raise; end if; end;

  -- a real custom template: 2 departments, 1 module, 2-stage pipeline with a threshold split
  v_json := save_industry_template('mining', 'Mining', 'Pits and plants', '[
    {"kind":"department","sort_order":1,"name":"Pit Operations"},
    {"kind":"department","sort_order":2,"name":"Plant"},
    {"kind":"module","sort_order":1,"name":"pmo"},
    {"kind":"workflow_stage","sort_order":1,"name":"Supervisor","payload":{"approver_role":"Supervisor","threshold_amount":1000,"next_low":2,"next_high":3}},
    {"kind":"workflow_stage","sort_order":2,"name":"Finance","payload":{"approver_role":"Finance Officer","is_finance_terminal_stage":true}},
    {"kind":"workflow_stage","sort_order":3,"name":"GM","payload":{"approver_role":"General Manager","next_low":2}}
  ]'::jsonb);
  if (v_json ->> 'stage_count')::int <> 3 or (v_json ->> 'department_count')::int <> 2 then
    raise exception 'FAIL: saved template shape %', v_json;
  end if;
  if not exists (select 1 from platform_audit_events where action = 'industry_template.create' and target_id = 'mining') then
    raise exception 'FAIL: template create not audited';
  end if;

  perform seed_tenant_defaults(t_c, 'mining');
  v_n := pg_temp.n(format('select count(*) from departments where tenant_id = %L', t_c));
  if v_n <> 2 then raise exception 'FAIL: mining departments = %', v_n; end if;
  v_json := pg_temp.j(format('select a.threshold_amount, lo.sequence_order as lo, hi.sequence_order as hi from workflow_stages a
    left join workflow_stages lo on lo.id = a.next_stage_low_id left join workflow_stages hi on hi.id = a.next_stage_high_id
    where a.tenant_id = %L and a.sequence_order = 1', t_c));
  if (v_json ->> 'threshold_amount')::numeric <> 1000 or (v_json ->> 'lo')::int <> 2 or (v_json ->> 'hi')::int <> 3 then
    raise exception 'FAIL: mining routing %', v_json;
  end if;
  if pg_temp.n(format('select count(*) from workflow_stages where tenant_id = %L and sequence_order = 2 and is_finance_terminal_stage', t_c)) <> 1 then
    raise exception 'FAIL: stage flag not applied';
  end if;
  if (select industry_template from tenants where id = t_c) <> 'mining' then raise exception 'FAIL: tenants.industry_template not updated'; end if;

  -- in use -> cannot delete; default switching exclusive
  begin
    perform delete_industry_template('mining');
    raise exception 'FAIL: in-use template deleted';
  exception when others then if sqlerrm not like 'TEMPLATE_IN_USE%' then raise; end if; end;
  perform set_default_industry_template('construction');
  if (select count(*) from industry_templates where is_default) <> 1
     or (select key from industry_templates where is_default) <> 'construction' then
    raise exception 'FAIL: default not exclusive';
  end if;
  perform set_default_industry_template('general');

  -- deactivated template can no longer seed
  perform save_industry_template('mining', 'Mining', 'Pits and plants', '[]'::jsonb, false);
  begin
    perform seed_tenant_defaults(gen_random_uuid(), 'mining');
    raise exception 'FAIL: inactive template accepted';
  exception when others then if sqlerrm not like 'TEMPLATE_NOT_FOUND%' then raise; end if; end;
  if (select count(*) from list_industry_templates()) <> 2 then raise exception 'FAIL: inactive still listed'; end if;
  if (select count(*) from list_industry_templates(true)) <> 3 then raise exception 'FAIL: include_inactive'; end if;

  raise notice 'PASS: 1. industry templates seed identically to the old code, custom templates work, validation holds';
end $$;

-- plain users: nothing
select pg_temp.become('plain');
do $$
begin
  if (select count(*) from list_industry_templates()) <> 0 then raise exception 'FAIL: plain saw templates'; end if;
  if (select count(*) from industry_templates) <> 0 then raise exception 'FAIL: plain read industry_templates'; end if;
  begin
    perform save_industry_template('x_y', 'X', null, '[]'::jsonb);
    raise exception 'FAIL: plain saved a template';
  exception when others then if sqlerrm not like 'PLATFORM_ADMIN_REQUIRED%' then raise; end if; end;
  begin
    perform seed_tenant_defaults((select v from test_ids where k = 't_a'), 'general');
    raise exception 'FAIL: plain seeded';
  exception when others then if sqlerrm not like 'Only platform admins%' then raise; end if; end;
  raise notice 'PASS: 1b. templates are platform-admin only';
end $$;

-- ---------------------------------------------------------------------
-- 2. apply_workflow_template
-- ---------------------------------------------------------------------
reset role;
-- Put a request mid-pipeline in t_a (as the plain user, who needs a department).
update app_users set department_id = (select id from departments where tenant_id = (select v from test_ids where k = 't_a') and name = 'IT Support')
where id = (select v from test_ids where k = 'plain');
select pg_temp.become('plain');
insert into requests (item_description, quantity, mr_number) values ('Tpl test laptop', 1, 'MR-TPL-A1');

set local role authenticated;
select pg_temp.become('admin');
do $$
declare
  t_a uuid := (select v from test_ids where k = 't_a');
  v_old uuid[];
  v_res jsonb;
begin
  begin
    perform apply_workflow_template(t_a, 'construction', 'testing');
    raise exception 'FAIL: applied while request open';
  exception when others then if sqlerrm not like 'WORKFLOW_IN_USE%' then raise; end if; end;
  begin
    perform apply_workflow_template(t_a, 'construction', 'x');
    raise exception 'FAIL: short reason accepted';
  exception when others then if sqlerrm not like 'REASON_REQUIRED%' then raise; end if; end;

  -- close it and retry
  perform pg_temp.n(format('with u as (update requests set status = ''cancelled'' where tenant_id = %L returning 1) select count(*) from u', t_a));
  v_old := array(select (x ->> 'id')::uuid from jsonb_array_elements(pg_temp.j(format('select coalesce(jsonb_agg(jsonb_build_object(''id'', id)), ''[]''::jsonb) as ids from workflow_stages where tenant_id = %L and is_active', t_a)) -> 'ids') x);

  v_res := apply_workflow_template(t_a, 'construction', 'switching to the construction pipeline');
  if (v_res ->> 'stages_created')::int <> 7 or (v_res ->> 'stages_retired')::int <> 7 then raise exception 'FAIL: apply result %', v_res; end if;
  if pg_temp.n(format('select count(*) from workflow_stages where tenant_id = %L and id = any (%L::uuid[]) and not is_active', t_a, v_old)) <> 7 then
    raise exception 'FAIL: old stages not retired in place';
  end if;
  if pg_temp.n(format('select count(*) from workflow_stages where tenant_id = %L and is_active and applies_to = ''requests''', t_a)) <> 7 then
    raise exception 'FAIL: new stages not active';
  end if;
  if not exists (select 1 from platform_audit_events where action = 'tenant.workflow.apply_template' and tenant_id = t_a
                 and reason = 'switching to the construction pipeline') then
    raise exception 'FAIL: apply not audited';
  end if;
  raise notice 'PASS: 2. apply_workflow_template refuses in-flight work, retires in place, audits';
end $$;

-- ---------------------------------------------------------------------
-- 3. Announcements
-- ---------------------------------------------------------------------
do $$
declare
  t_a uuid := (select v from test_ids where k = 't_a');
  t_b uuid := (select v from test_ids where k = 't_b');
  a_all uuid; a_a uuid; a_future uuid; a_past uuid; a_crit uuid; a_off uuid;
begin
  a_all    := save_platform_announcement(null, 'Maintenance Saturday', 'We will be down 02:00-03:00 UTC.', 'warning');
  a_a      := save_platform_announcement(null, 'Hello A', 'Only for company A', 'info', t_a);
  a_future := save_platform_announcement(null, 'Later', 'Not yet', 'info', null, now() + interval '1 day');
  a_past   := save_platform_announcement(null, 'Gone', 'Ended', 'info', null, now() - interval '2 days', now() - interval '1 day');
  a_crit   := save_platform_announcement(null, 'Security notice', 'Rotate your passwords', 'critical', null, now(), null, true, 'https://status.example', 'Status');
  a_off    := save_platform_announcement(null, 'Draft', 'Disabled', 'info', null, now(), null, true, null, null, false);
  insert into test_ids values ('a_all', a_all), ('a_a', a_a), ('a_crit', a_crit);

  if (select count(*) from list_platform_announcements(true)) <> 6 then raise exception 'FAIL: admin list'; end if;
  if (select state from list_platform_announcements(true) where id = a_future) <> 'scheduled'
     or (select state from list_platform_announcements(true) where id = a_past) <> 'ended'
     or (select state from list_platform_announcements(true) where id = a_off) <> 'disabled'
     or (select state from list_platform_announcements(true) where id = a_all) <> 'live' then
    raise exception 'FAIL: announcement states';
  end if;
  if not exists (select 1 from platform_audit_events where action = 'announcement.create' and target_id = a_a::text and tenant_id = t_a) then
    raise exception 'FAIL: announcement create not audited';
  end if;
  begin
    perform save_platform_announcement(null, '', 'x');
    raise exception 'FAIL: empty title accepted';
  exception when others then if sqlerrm not like 'ANNOUNCEMENT_INVALID%' then raise; end if; end;
  begin
    perform save_platform_announcement(null, 'x', 'y', 'info', null, now(), now() - interval '1 hour');
    raise exception 'FAIL: inverted window accepted';
  exception when others then if sqlerrm not like '%platform_announcements_window_check%' then raise; end if; end;
end $$;

-- company A member: global warning + critical + A-only; not future/past/off/B
select pg_temp.become('plain');
do $$
declare v_ids uuid[]; v_crit_dismissible boolean;
begin
  select array_agg(id order by title) into v_ids from get_active_announcements();
  if coalesce(array_length(v_ids, 1), 0) <> 3 then raise exception 'FAIL: plain sees % announcements', coalesce(array_length(v_ids, 1), 0); end if;
  if (select severity from get_active_announcements() limit 1) <> 'critical' then raise exception 'FAIL: critical not first'; end if;
  select dismissible into v_crit_dismissible from get_active_announcements() where id = (select v from test_ids where k = 'a_crit');
  if v_crit_dismissible then raise exception 'FAIL: critical dismissible'; end if;
  if (select count(*) from platform_announcements) <> 0 then raise exception 'FAIL: plain read announcements table'; end if;
  if (select count(*) from list_platform_announcements()) <> 0 then raise exception 'FAIL: plain used admin list'; end if;

  -- dismiss the warning
  perform dismiss_announcement((select v from test_ids where k = 'a_all'));
  if (select count(*) from get_active_announcements()) <> 2 then raise exception 'FAIL: dismissal not applied'; end if;
  perform dismiss_announcement((select v from test_ids where k = 'a_all'));  -- idempotent
  begin
    perform dismiss_announcement((select v from test_ids where k = 'a_crit'));
    raise exception 'FAIL: critical dismissed';
  exception when others then if sqlerrm not like 'ANNOUNCEMENT_NOT_DISMISSIBLE%' then raise; end if; end;
  begin
    perform save_platform_announcement(null, 'Hax', 'nope');
    raise exception 'FAIL: plain published';
  exception when others then if sqlerrm not like 'PLATFORM_ADMIN_REQUIRED%' then raise; end if; end;
end $$;

-- company B member: sees the warning (own dismissals only) + critical, not A's
select pg_temp.become('other');
do $$
begin
  if (select count(*) from get_active_announcements()) <> 2 then raise exception 'FAIL: other sees % announcements', (select count(*) from get_active_announcements()); end if;
  if exists (select 1 from get_active_announcements() where title = 'Hello A') then raise exception 'FAIL: other saw A-only'; end if;
  raise notice 'PASS: 3. announcements window/targeting/dismissal semantics hold';
end $$;

-- admin: dismissal count + delete
select pg_temp.become('admin');
do $$
begin
  if (select dismissals from list_platform_announcements() where id = (select v from test_ids where k = 'a_all')) <> 1 then
    raise exception 'FAIL: dismissal count';
  end if;
  perform delete_platform_announcement((select v from test_ids where k = 'a_a'));
  if exists (select 1 from platform_announcements where id = (select v from test_ids where k = 'a_a')) then raise exception 'FAIL: not deleted'; end if;
  if not exists (select 1 from platform_audit_events where action = 'announcement.delete') then raise exception 'FAIL: delete not audited'; end if;
end $$;

-- ---------------------------------------------------------------------
-- 4. Feature flags
-- ---------------------------------------------------------------------
do $$
declare
  t_a uuid := (select v from test_ids where k = 't_a');
  t_b uuid := (select v from test_ids where k = 't_b');
begin
  perform save_feature_flag('new_dashboard', 'New dashboard layout', false);
  perform save_feature_flag('bulk_import', 'CSV bulk import', true);
  begin
    perform save_feature_flag('Bad Key', 'x', false);
    raise exception 'FAIL: bad flag key accepted';
  exception when others then if sqlerrm not like 'FLAG_KEY_INVALID%' then raise; end if; end;
  begin
    perform set_tenant_feature_flag(t_a, 'nope', true);
    raise exception 'FAIL: unknown flag override accepted';
  exception when others then if sqlerrm not like 'FLAG_NOT_FOUND%' then raise; end if; end;

  perform set_tenant_feature_flag(t_a, 'new_dashboard', true, 'pilot customer');
  perform set_tenant_feature_flag(t_b, 'bulk_import', false, 'asked to hide it');

  if (select tenants_on from list_feature_flags() where key = 'new_dashboard') <> 1 then raise exception 'FAIL: tenants_on'; end if;
  if (select effective from get_tenant_feature_flags(t_a) where key = 'new_dashboard') is not true then raise exception 'FAIL: effective A'; end if;
  if (select override from get_tenant_feature_flags(t_b) where key = 'new_dashboard') is not null then raise exception 'FAIL: B override should be null'; end if;
  if not exists (select 1 from platform_audit_events where action = 'tenant.feature_flag.set' and tenant_id = t_a and reason = 'pilot customer') then
    raise exception 'FAIL: flag set not audited';
  end if;
end $$;

select pg_temp.become('plain');   -- tenant A
do $$
begin
  if not feature_enabled('new_dashboard') then raise exception 'FAIL: A override on'; end if;
  if not feature_enabled('bulk_import') then raise exception 'FAIL: A default on'; end if;
  if feature_enabled('does_not_exist') then raise exception 'FAIL: unknown flag true'; end if;
  if (select enabled from get_my_feature_flags() where key = 'new_dashboard') is not true then raise exception 'FAIL: my flags A'; end if;
  if (select count(*) from platform_feature_flags) <> 0 then raise exception 'FAIL: plain read flags table'; end if;
  if (select count(*) from list_feature_flags()) <> 0 then raise exception 'FAIL: plain used admin flag list'; end if;
  begin
    perform save_feature_flag('hax', 'x', true);
    raise exception 'FAIL: plain saved flag';
  exception when others then if sqlerrm not like 'PLATFORM_ADMIN_REQUIRED%' then raise; end if; end;
end $$;

select pg_temp.become('other');   -- tenant B
do $$
begin
  if feature_enabled('new_dashboard') then raise exception 'FAIL: B default off'; end if;
  if feature_enabled('bulk_import') then raise exception 'FAIL: B override off'; end if;
end $$;

-- clear the override -> default again; impersonation resolves for the impersonated tenant
select pg_temp.become('admin');
do $$
declare t_a uuid := (select v from test_ids where k = 't_a');
begin
  perform set_tenant_feature_flag(t_a, 'new_dashboard', null);
  if exists (select 1 from tenant_feature_flags where tenant_id = t_a and flag_key = 'new_dashboard') then raise exception 'FAIL: override not cleared'; end if;
  perform set_tenant_feature_flag(t_a, 'new_dashboard', true);
  perform start_impersonation(t_a, 'checking the new dashboard for them');
  if not feature_enabled('new_dashboard') then raise exception 'FAIL: impersonation did not resolve tenant A'; end if;
  perform end_impersonation();
  raise notice 'PASS: 4. feature flags resolve default -> override -> clear, gated, impersonation-aware';
end $$;

-- ---------------------------------------------------------------------
-- 5. Health
-- ---------------------------------------------------------------------
reset role;
-- A stuck request in t_b: seed gave it stages; the 'other' user needs a department.
update app_users set department_id = (select id from departments where tenant_id = (select v from test_ids where k = 't_b') and name = 'IT Support')
where id = (select v from test_ids where k = 'other');
select pg_temp.become('other');
-- (mr_number is globally unique but numbered per tenant -- pre-existing quirk -- so pass one explicitly)
insert into requests (item_description, quantity, mr_number) values ('Tpl stuck item', 2, 'MR-TPL-B1');
update requests set updated_at = now() - interval '10 days', created_at = now() - interval '10 days' where item_description = 'Tpl stuck item';

-- Sweeps record runs. 'other' is not a module member -> sweep returns 0 and records nothing.
insert into staff_roles (tenant_id, user_id, module, role)
values ((select v from test_ids where k = 't_b'), (select v from test_ids where k = 'other'), 'machine_operation', 'member'),
       ((select v from test_ids where k = 't_b'), (select v from test_ids where k = 'other'), 'sustainability', 'member');

set local role authenticated;
select pg_temp.become('other');
do $$
begin
  perform machine_maintenance_overdue_sweep();
  perform sustainability_cert_expiry_sweep();
  begin
    perform get_platform_health();
    raise exception 'FAIL: plain read health';
  exception when others then if sqlerrm not like 'PLATFORM_ADMIN_REQUIRED%' then raise; end if; end;
  begin
    perform platform_record_job_run('hax', null, 'ok', 1);
    raise exception 'FAIL: plain recorded a job run';
  exception when insufficient_privilege then null; end;
end $$;

-- digest wrapper records too (as postgres, like cron would)
reset role;
select set_config('request.jwt.claims', json_build_object('role', 'postgres')::text, true);
do $$
begin
  update platform_settings set notifications = jsonb_build_object('alert_recipients', jsonb_build_array('ops@x.test'), 'digest_enabled', true) where id = true;
  perform platform_run_operator_digest_logged();
end $$;

set local role authenticated;
select pg_temp.become('admin');
do $$
declare h jsonb; j jsonb;
begin
  h := get_platform_health();
  if (h -> 'jobs') is null then raise exception 'FAIL: no jobs'; end if;
  select x into j from jsonb_array_elements(h -> 'jobs') x where x ->> 'job' = 'machine_maintenance_overdue_sweep';
  if j is null or (j ->> 'runs_7d')::int < 1 or j ->> 'last_status' <> 'ok' then raise exception 'FAIL: maintenance sweep run missing: %', h -> 'jobs'; end if;
  select x into j from jsonb_array_elements(h -> 'jobs') x where x ->> 'job' = 'sustainability_cert_expiry_sweep';
  if j is null then raise exception 'FAIL: sustainability sweep run missing'; end if;
  select x into j from jsonb_array_elements(h -> 'jobs') x where x ->> 'job' = 'operator_digest';
  if j is null or j ->> 'last_status' <> 'ok' then raise exception 'FAIL: digest run missing: %', h -> 'jobs'; end if;

  if (select count(*) from jsonb_array_elements(h -> 'stuck_approvals') x where x ->> 'tenant_name' = 'Tpl Construction Co' and (x ->> 'count')::int = 1 and (x ->> 'oldest_days')::int >= 9) <> 1 then
    raise exception 'FAIL: stuck approvals %', h -> 'stuck_approvals';
  end if;
  if (select count(*) from jsonb_array_elements(h -> 'stale_invites') x where x ->> 'tenant_name' = 'Tpl Construction Co' and (x ->> 'count')::int = 1) <> 1 then
    raise exception 'FAIL: stale invites %', h -> 'stale_invites';
  end if;
  if (h -> 'database' ->> 'size_bytes')::bigint <= 0 then raise exception 'FAIL: db size'; end if;
  if (h -> 'digest' ->> 'last_generated_at') is null then raise exception 'FAIL: digest last_generated_at'; end if;
  if (h ->> 'announcements_live')::int < 2 then raise exception 'FAIL: announcements_live'; end if;
  if (h ->> 'feature_flags')::int <> 2 then raise exception 'FAIL: feature_flags count'; end if;
  if (h -> 'cron' ->> 'installed')::boolean and not exists (
      select 1 from jsonb_array_elements(h -> 'cron' -> 'jobs') x where x ->> 'jobname' = 'platform_operator_digest_daily') then
    raise exception 'FAIL: digest cron job not reported';
  end if;
  if (h -> 'migrations') is null then raise exception 'FAIL: migrations block'; end if;
  raise notice 'PASS: 5. health reports job runs, stuck approvals, stale invites, digest, cron';
end $$;

-- Cron command now points at the logged wrapper.
reset role;
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if not exists (select 1 from cron.job where jobname = 'platform_operator_digest_daily' and command like '%platform_run_operator_digest_logged%') then
      raise exception 'FAIL: cron job not rescheduled to the logged wrapper';
    end if;
  end if;
  raise notice 'PASS: 6. cron rescheduled';
end $$;

rollback;
