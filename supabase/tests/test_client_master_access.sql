-- Regression test for the client-master access helpers (decision D2):
--   can_access_client_master() / can_manage_client_master() and the policies on
--   bd_clients, bd_contacts, bd_client_categories.
--
-- Verifies, against a fully-migrated fresh stack:
--   1. A BD member still reads and writes clients/contacts/categories-read, and
--      still cannot write categories (admin tier only) -- behaviour unchanged.
--   2. An insurance member reads and writes clients and contacts, reads
--      categories, cannot write categories; an insurance admin can.
--   3. Insurance users do NOT see BD pipeline data (opportunities, tenders, leads).
--   4. A user with neither module sees nothing in the client master.
--   5. Tenant isolation: an insurance user cannot see another tenant's clients.
--   6. anon cannot execute the helpers.
--
-- Run against a fresh local stack only -- never against a linked project.

\set ON_ERROR_STOP on

begin;

do $$
declare
  t_ins   uuid := gen_random_uuid();
  t_bd    uuid := gen_random_uuid();
  u_im    uuid := gen_random_uuid();  -- insurance member
  u_ia    uuid := gen_random_uuid();  -- insurance admin
  u_bm    uuid := gen_random_uuid();  -- bd member
  u_hr    uuid := gen_random_uuid();  -- hr only (no client master access)
begin
  create temp table test_ids (k text primary key, v uuid) on commit drop;
  insert into test_ids values
    ('t_ins', t_ins), ('t_bd', t_bd), ('im', u_im), ('ia', u_ia), ('bm', u_bm), ('hr', u_hr);
  grant select on test_ids to authenticated, anon, service_role;

  insert into tenants (id, name, status, created_at, plan, subscription_status, industry_template) values
    (t_ins, 'CM Test Insurance Co', 'active', now() - interval '30 days', 'trial', 'trialing', 'general'),
    (t_bd,  'CM Test BD Co',        'active', now() - interval '30 days', 'trial', 'trialing', 'general');

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, recovery_token, last_sign_in_at
  )
  select
    '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
    u.handle || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
    now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', '', now()
  from (values (u_im, 'cm-im'), (u_ia, 'cm-ia'), (u_bm, 'cm-bm'), (u_hr, 'cm-hr')) as u(id, handle);

  insert into app_users (id, tenant_id, name, email, is_platform_admin, is_company_admin, created_at) values
    (u_im, t_ins, 'Ins Member', 'cm-im@test.local', false, false, now()),
    (u_ia, t_ins, 'Ins Admin',  'cm-ia@test.local', false, false, now()),
    (u_hr, t_ins, 'HR Only',    'cm-hr@test.local', false, false, now()),
    (u_bm, t_bd,  'BD Member',  'cm-bm@test.local', false, false, now());

  insert into tenant_modules (tenant_id, module) values
    (t_ins, 'insurance'), (t_ins, 'hr'), (t_bd, 'bd');
  insert into staff_roles (tenant_id, user_id, module, role) values
    (t_ins, u_im, 'insurance', 'member'),
    (t_ins, u_ia, 'insurance', 'admin'),
    (t_ins, u_hr, 'hr',        'member'),
    (t_bd,  u_bm, 'bd',        'member');

  -- Seed rows as table owner (bypasses RLS).
  insert into bd_clients (tenant_id, name) values (t_ins, 'Ins Client A'), (t_bd, 'BD Client A');
  insert into bd_client_categories (tenant_id, name) values (t_ins, 'Ins Cat'), (t_bd, 'BD Cat');
  insert into bd_contacts (tenant_id, client_id, first_name, last_name)
    select t_ins, id, 'Ann', 'Ins' from bd_clients where tenant_id = t_ins;
  -- BD-only pipeline data in the insurance tenant (should stay invisible to insurance users).
  -- bd_opportunities.stage defaults to 'identification' and has a composite FK
  -- to bd_opportunity_stages(tenant_id, stage); fresh test tenants have no
  -- lookup rows, so seed the default stage for both.
  insert into bd_opportunity_stages (tenant_id, stage, label, probability_default, order_index) values
    (t_ins, 'identification', 'Identification', 10, 1),
    (t_bd,  'identification', 'Identification', 10, 1);
  insert into bd_opportunities (tenant_id, title) values (t_ins, 'Hidden Opp'), (t_bd, 'BD Opp');
  insert into bd_tenders (tenant_id, title) values (t_ins, 'Hidden Tender'), (t_bd, 'BD Tender');
  insert into bd_leads (tenant_id, company_name, contact_name) values (t_ins, 'Hidden Lead', 'X'), (t_bd, 'BD Lead', 'Y');
end $$;

create or replace function pg_temp.become(p_key text) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', (select v from test_ids where k = p_key), 'role', 'authenticated', 'aal', 'aal2')::text, true);
end $$;

-- ---------------------------------------------------------------------
-- 1. BD member: unchanged
-- ---------------------------------------------------------------------
set local role authenticated;
select pg_temp.become('bm');
do $$
declare t_bd uuid := (select v from test_ids where k = 't_bd');
begin
  if (select count(*) from bd_clients) <> 1 then raise exception 'FAIL: bd member should see 1 client'; end if;
  if (select count(*) from bd_client_categories) <> 1 then raise exception 'FAIL: bd member should read categories'; end if;
  if (select count(*) from bd_opportunities) <> 1 or (select count(*) from bd_tenders) <> 1 then
    raise exception 'FAIL: bd member lost pipeline access';
  end if;
  insert into bd_clients (tenant_id, name) values (t_bd, 'BD Client B');
  begin
    insert into bd_client_categories (tenant_id, name) values (t_bd, 'Nope');
    raise exception 'FAIL: bd member wrote a category (admin tier only)';
  exception when insufficient_privilege then null; end;
end $$;
reset role;

-- ---------------------------------------------------------------------
-- 2. Insurance member
-- ---------------------------------------------------------------------
set local role authenticated;
select pg_temp.become('im');
do $$
declare
  t_ins uuid := (select v from test_ids where k = 't_ins');
  v_client uuid;
begin
  if (select count(*) from bd_clients) <> 1 then raise exception 'FAIL: insurance member should see own tenant client only'; end if;
  if (select count(*) from bd_contacts) <> 1 then raise exception 'FAIL: insurance member should see contacts'; end if;
  if (select count(*) from bd_client_categories) <> 1 then raise exception 'FAIL: insurance member should read categories'; end if;

  insert into bd_clients (tenant_id, name) values (t_ins, 'Ins Client B') returning id into v_client;
  update bd_clients set name = 'Ins Client B2' where id = v_client;
  if (select name from bd_clients where id = v_client) <> 'Ins Client B2' then raise exception 'FAIL: insurance member update'; end if;
  insert into bd_contacts (tenant_id, client_id, first_name, last_name) values (t_ins, v_client, 'Bo', 'Ins');
  delete from bd_contacts where client_id = v_client;
  delete from bd_clients where id = v_client;

  begin
    insert into bd_client_categories (tenant_id, name) values (t_ins, 'Nope');
    raise exception 'FAIL: insurance member wrote a category';
  exception when insufficient_privilege then null; end;

  -- 3. no pipeline data
  if (select count(*) from bd_opportunities) <> 0 then raise exception 'FAIL: insurance member sees opportunities'; end if;
  if (select count(*) from bd_tenders) <> 0 then raise exception 'FAIL: insurance member sees tenders'; end if;
  if (select count(*) from bd_leads) <> 0 then raise exception 'FAIL: insurance member sees leads'; end if;
end $$;
reset role;

-- Insurance admin may write categories.
set local role authenticated;
select pg_temp.become('ia');
do $$
declare t_ins uuid := (select v from test_ids where k = 't_ins');
begin
  insert into bd_client_categories (tenant_id, name) values (t_ins, 'Motor');
  update bd_client_categories set name = 'Motor Fleet' where name = 'Motor';
  delete from bd_client_categories where name = 'Motor Fleet';
end $$;
reset role;

-- ---------------------------------------------------------------------
-- 4. User with neither module sees nothing
-- ---------------------------------------------------------------------
set local role authenticated;
select pg_temp.become('hr');
do $$
declare t_ins uuid := (select v from test_ids where k = 't_ins');
begin
  if (select count(*) from bd_clients) <> 0 or (select count(*) from bd_contacts) <> 0
     or (select count(*) from bd_client_categories) <> 0 then
    raise exception 'FAIL: user without bd/insurance sees the client master';
  end if;
  begin
    insert into bd_clients (tenant_id, name) values (t_ins, 'Nope');
    raise exception 'FAIL: user without bd/insurance inserted a client';
  exception when insufficient_privilege then null; end;
end $$;
reset role;

-- ---------------------------------------------------------------------
-- 5. Tenant isolation (insurance member cannot see or write the BD tenant's clients)
-- ---------------------------------------------------------------------
set local role authenticated;
select pg_temp.become('im');
do $$
declare t_bd uuid := (select v from test_ids where k = 't_bd');
begin
  if exists (select 1 from bd_clients where tenant_id = t_bd) then raise exception 'FAIL: cross-tenant read'; end if;
  begin
    insert into bd_clients (tenant_id, name) values (t_bd, 'Cross');
    raise exception 'FAIL: cross-tenant insert';
  exception when insufficient_privilege then null; end;
end $$;
reset role;

-- ---------------------------------------------------------------------
-- 6. anon cannot execute the helpers
-- ---------------------------------------------------------------------
set local role anon;
do $$
begin
  begin perform can_access_client_master(); raise exception 'FAIL: anon executed can_access_client_master';
  exception when insufficient_privilege then null; end;
  begin perform can_manage_client_master(); raise exception 'FAIL: anon executed can_manage_client_master';
  exception when insufficient_privilege then null; end;
end $$;
reset role;

rollback;