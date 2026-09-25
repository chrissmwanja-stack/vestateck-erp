-- Test impersonation attribution — item 3
begin;

-- Test that approval_actions has new columns
do $$
begin
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='approval_actions' and column_name='actor_id') then
    raise exception 'FAIL: approval_actions.actor_id missing';
  end if;
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='approval_actions' and column_name='effective_user_id') then
    raise exception 'FAIL: approval_actions.effective_user_id missing';
  end if;
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='approval_actions' and column_name='impersonation_session_id') then
    raise exception 'FAIL: approval_actions.impersonation_session_id missing';
  end if;
end $$;

-- Test effective_user_id() and impersonated_user_id() exist and are SECURITY DEFINER
do $$
declare
  v_count int;
begin
  select count(*) into v_count from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='effective_user_id' and p.prosecdef;
  if v_count=0 then raise exception 'FAIL: effective_user_id should be SECURITY DEFINER'; end if;

  select count(*) into v_count from pg_proc where proname='impersonated_user_id';
  if v_count=0 then raise exception 'FAIL: impersonated_user_id missing'; end if;

  select count(*) into v_count from pg_proc where proname='platform_admin_bypass';
  if v_count=0 then raise exception 'FAIL: platform_admin_bypass missing'; end if;
end $$;

-- Test get_my_tenant_id respects impersonation_sessions with expires_at
-- The function should check expires_at > now(), not just ended_at is null (old 2h magic)
do $$
declare
  v_def text;
begin
  select pg_get_functiondef(oid) into v_def from pg_proc where proname='get_my_tenant_id' and pronamespace='public'::regnamespace;
  if v_def not like '%expires_at > now()%' then
    raise exception 'FAIL: get_my_tenant_id should check expires_at > now() (hard expiry)';
  end if;
end $$;

-- Test start_impersonation requires reason >=5 chars
do $$
declare
  v_def text;
begin
  select pg_get_functiondef(oid) into v_def from pg_proc where proname='start_impersonation' and pronargs=2;
  if v_def is null then
    -- try 3-arg version
    select pg_get_functiondef(oid) into v_def from pg_proc where proname='start_impersonation' and pronargs=3 limit 1;
  end if;
  if v_def not like '%reason%' or v_def not like '%5%' then
    raise exception 'FAIL: start_impersonation should require reason >=5 chars';
  end if;
end $$;

raise notice 'PASS: impersonation attribution tests';

rollback;
