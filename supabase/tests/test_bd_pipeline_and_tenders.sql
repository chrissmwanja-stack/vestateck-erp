-- Functional test for the BD migration:
--   20260921140000_bd_pipeline_math_and_tender_submissions.sql
--     (opportunity probability guard trigger, bd_pipeline_summary RPC,
--      bd_tender_submissions, transition_tender RPC)
--
-- Covers:
--   * NULL probability coalesces from the tenant stage default on insert
--     AND on update; explicit probabilities survive
--   * bd_pipeline_summary matches hand-computed stage totals; outsiders
--     get an empty summary, never other tenants' numbers
--   * tender lifecycle guards: open -> submitted writes one submission
--     row (ref + note + officer); invalid skips and second submits
--     refused; award notifies the (non-actor) creator; awarded is
--     terminal; submissions RLS: bd members read, outsiders read nothing
--
-- Run against a fresh local stack only (psql -f), never a linked project.

\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------
do $$
declare
  v_tenant  uuid := gen_random_uuid();
  v_member  uuid := gen_random_uuid(); -- bd member (tender creator)
  v_mgr     uuid := gen_random_uuid(); -- bd manager
  v_plain   uuid := gen_random_uuid(); -- no roles
begin
  insert into tenants (id, name) values (v_tenant, 'BD Pipeline Test Co');

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, recovery_token
  )
  select
    '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
    u.handle || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
    now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
  from (values
    (v_member, 'bd-member'),
    (v_mgr,    'bd-manager'),
    (v_plain,  'bd-plain')
  ) as u(id, handle);

  insert into app_users (id, tenant_id, name, email)
  select u.id, v_tenant, u.name, u.email
  from (values
    (v_member, 'BD Member',  'bd-member@test.local'),
    (v_mgr,    'BD Manager', 'bd-manager@test.local'),
    (v_plain,  'Plain User', 'bd-plain@test.local')
  ) as u(id, name, email);

  insert into tenant_modules (tenant_id, module) values (v_tenant, 'bd');
  insert into staff_roles (tenant_id, user_id, module, role) values
    (v_tenant, v_member, 'bd', 'member'),
    (v_tenant, v_mgr,    'bd', 'manager');

  -- Stage lookup: identification @10, negotiation @70
  insert into bd_opportunity_stages (tenant_id, stage, label, probability_default, order_index) values
    (v_tenant, 'identification', 'Identification', 10, 1),
    (v_tenant, 'negotiation',    'Negotiation',    70, 4);

  -- Opportunity A: probability deliberately NULL -> guard coalesces to 10
  insert into bd_opportunities (tenant_id, title, stage, estimated_value, probability)
  values (v_tenant, 'Opp A null-prob', 'identification', 100000, null);

  -- Opportunity B: explicit probability -> untouched
  insert into bd_opportunities (tenant_id, title, stage, estimated_value, probability)
  values (v_tenant, 'Opp B explicit', 'negotiation', 50000, 60);

  -- One tender, created by the member
  insert into bd_tenders (tenant_id, title, status, estimated_value, created_by)
  values (v_tenant, 'Roadworks Tender', 'open', 250000, v_member);

  create temp table if not exists test_identities(handle text primary key, id uuid not null) on commit drop;
  insert into test_identities (handle, id) values
    ('member', v_member), ('manager', v_mgr), ('plain', v_plain),
    ('opp_a', (select id from bd_opportunities where title = 'Opp A null-prob')),
    ('opp_b', (select id from bd_opportunities where title = 'Opp B explicit')),
    ('tender', (select id from bd_tenders where title = 'Roadworks Tender'));
  grant select on test_identities to authenticated;
end $$;

-- ---------------------------------------------------------------------
-- 1. Probability guard: NULL -> stage default on insert and on update
-- ---------------------------------------------------------------------
do $$
begin
  if (select probability from bd_opportunities
      where id = (select id from test_identities where handle = 'opp_a')) <> 10 then
    raise exception 'FAIL: NULL probability not coalesced to stage default 10 on insert (got %)',
      (select probability from bd_opportunities where id = (select id from test_identities where handle = 'opp_a'));
  end if;
  if (select probability from bd_opportunities
      where id = (select id from test_identities where handle = 'opp_b')) <> 60 then
    raise exception 'FAIL: explicit probability 60 was overwritten';
  end if;

  -- explicit NULL on update coalesces to the (new) stage default, not NULL
  update bd_opportunities set stage = 'negotiation', probability = null
  where id = (select id from test_identities where handle = 'opp_a');
  if (select probability from bd_opportunities
      where id = (select id from test_identities where handle = 'opp_a')) <> 70 then
    raise exception 'FAIL: NULL probability on update not coalesced to negotiation default 70';
  end if;

  -- move it back so the summary assertions below stay predictable
  update bd_opportunities set stage = 'identification', probability = 10
  where id = (select id from test_identities where handle = 'opp_a');
  raise notice 'PASS: probability guard coalesces NULLs on insert + update, keeps explicit values';
end $$;

-- ---------------------------------------------------------------------
-- 2. bd_pipeline_summary: member gets hand-checkable math; outsider
--    gets an empty summary
-- ---------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from test_identities where handle = 'plain'))::text, true);

do $$
declare
  v_summary jsonb;
begin
  v_summary := bd_pipeline_summary();
  if jsonb_array_length(v_summary -> 'stages') <> 0
     or (v_summary #>> '{totals,count}')::int <> 0 then
    raise exception 'FAIL: outsider saw pipeline data (% not empty)', v_summary;
  end if;
  raise notice 'PASS: outsider gets an empty pipeline summary';
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', (select id from test_identities where handle = 'member'))::text, true);

do $$
declare
  v_summary jsonb;
  v_id_stage jsonb;
  v_neg_stage jsonb;
begin
  v_summary := bd_pipeline_summary();
  v_id_stage  := (select s from jsonb_array_elements(v_summary -> 'stages') s where s ->> 'stage' = 'identification');
  v_neg_stage := (select s from jsonb_array_elements(v_summary -> 'stages') s where s ->> 'stage' = 'negotiation');

  if v_id_stage is null or v_neg_stage is null then
    raise exception 'FAIL: summary did not return both tenant stages (% found)', jsonb_array_length(v_summary -> 'stages');
  end if;

  if (v_id_stage ->> 'count')::int <> 1
     or (v_id_stage ->> 'total')::numeric <> 100000
     or (v_id_stage ->> 'weighted')::numeric <> 10000 then
    raise exception 'FAIL: identification agg wrong (expect 1 / 100000 / 10000): %', v_id_stage;
  end if;
  if (v_neg_stage ->> 'count')::int <> 1
     or (v_neg_stage ->> 'total')::numeric <> 50000
     or (v_neg_stage ->> 'weighted')::numeric <> 30000 then
    raise exception 'FAIL: negotiation agg wrong (expect 1 / 50000 / 30000): %', v_neg_stage;
  end if;
  if (v_summary #>> '{totals,count}')::int <> 2
     or (v_summary #>> '{totals,total}')::numeric <> 150000
     or (v_summary #>> '{totals,weighted}')::numeric <> 40000 then
    raise exception 'FAIL: totals wrong (expect 2 / 150000 / 40000): %', v_summary -> 'totals';
  end if;
  raise notice 'PASS: bd_pipeline_summary matches hand-computed per-stage and total math';
end $$;

-- ---------------------------------------------------------------------
-- 3. Tender lifecycle: guards, submission record, award notification
-- ---------------------------------------------------------------------
do $$
declare
  v_tender_id uuid := (select id from test_identities where handle = 'tender');
  v_tender public.bd_tenders%rowtype;
begin
  -- invalid skips
  begin
    perform transition_tender(v_tender_id, 'awarded');
    raise exception 'FAIL: open -> awarded was allowed';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
  begin
    perform transition_tender(v_tender_id, 'under_evaluation');
    raise exception 'FAIL: open -> under_evaluation was allowed (must submit first)';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;

  -- valid path: submit (records the submission)
  v_tender := transition_tender(v_tender_id, 'submitted', 'PPDA-2026-0045', 'Uploaded via EGP portal');
  if v_tender.status <> 'submitted' then
    raise exception 'FAIL: submit did not move tender to submitted';
  end if;

  begin
    perform transition_tender(v_tender_id, 'submitted');
    raise exception 'FAIL: a second submit was allowed';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;

  v_tender := transition_tender(v_tender_id, 'under_evaluation');
  v_tender := transition_tender(v_tender_id, 'awarded');
  if v_tender.status <> 'awarded' then
    raise exception 'FAIL: award did not land';
  end if;

  begin
    perform transition_tender(v_tender_id, 'lost');
    raise exception 'FAIL: awarded tender could transition further';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
  raise notice 'PASS: tender lifecycle guards + terminal awarded enforced';
end $$;

reset role;
do $$
declare
  v_tender_id uuid := (select id from test_identities where handle = 'tender');
  v_member uuid := (select id from test_identities where handle = 'member');
begin
  if (select count(*) from bd_tender_submissions where tender_id = v_tender_id) <> 1 then
    raise exception 'FAIL: expected exactly one submission row';
  end if;
  if (select submission_ref from bd_tender_submissions where tender_id = v_tender_id) <> 'PPDA-2026-0045'
     or (select note from bd_tender_submissions where tender_id = v_tender_id) <> 'Uploaded via EGP portal'
     or (select submitted_by from bd_tender_submissions where tender_id = v_tender_id) <> v_member then
    raise exception 'FAIL: submission row lost the ref/note/officer';
  end if;
  -- award performed by the member as well in this walk, so no
  -- notification expected (creator == actor) -- assert none fired
  if (select count(*) from notifications where type = 'tender_awarded') <> 0 then
    raise exception 'FAIL: self-action generated a notification';
  end if;
  raise notice 'PASS: submission recorded once with ref/note/officer; self-award stays quiet';
end $$;

-- award by ANOTHER user must notify the creator
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from test_identities where handle = 'manager'))::text, true);

do $$
declare
  v_tender2 uuid;
begin
  insert into bd_tenders (tenant_id, title, status, created_by)
  select t.tenant_id, 'Drainage Tender', 'open',
         (select id from test_identities where handle = 'member')
  from bd_tenders t where t.id = (select id from test_identities where handle = 'tender')
  returning id into v_tender2;

  perform transition_tender(v_tender2, 'submitted', null, null);
  perform transition_tender(v_tender2, 'awarded');

  reset role;
  if (select count(*) from notifications
      where type = 'tender_awarded'
        and recipient_id = (select id from test_identities where handle = 'member')
        and title = 'Tender awarded: Drainage Tender') <> 1 then
    raise exception 'FAIL: creator not notified when someone else awarded';
  end if;
  raise notice 'PASS: award by a colleague notifies the tender creator';
end $$;

-- ---------------------------------------------------------------------
-- 4. Outsider: RPC refused, submissions unreadable; member reads both
-- ---------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from test_identities where handle = 'plain'))::text, true);

do $$
begin
  begin
    perform transition_tender((select id from test_identities where handle = 'tender'), 'cancelled');
    raise exception 'FAIL: outsider transitioned a tender';
  exception when raise_exception then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
  if (select count(*) from bd_tender_submissions) <> 0 then
    raise exception 'FAIL: outsider can read tender submissions';
  end if;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', (select id from test_identities where handle = 'member'))::text, true);

do $$
begin
  if (select count(*) from bd_tender_submissions) <> 2 then
    raise exception 'FAIL: bd member cannot read the two tenant submissions';
  end if;
  raise notice 'PASS: outsider refused + reads nothing; bd member reads submissions';
end $$;

reset role;
rollback;
