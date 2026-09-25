-- Test journal immutability — item 4
begin;

-- Setup: need a tenant with GL accounts and posting rules
-- Use existing test pattern from test_gl_posting_and_period_close.sql
-- For this isolated test, verify triggers exist and block mutation

-- Test 1: journal_entries should have no_update trigger
do $$
declare
  v_count int;
begin
  select count(*) into v_count from pg_trigger where tgname='no_update_journal_entries' and tgrelid='public.journal_entries'::regclass;
  if v_count = 0 then
    raise exception 'FAIL: journal_entries should have no_update trigger';
  end if;
  select count(*) into v_count from pg_trigger where tgname='no_update_journal_entry_lines' and tgrelid='public.journal_entry_lines'::regclass;
  if v_count = 0 then
    raise exception 'FAIL: journal_entry_lines should have no_update trigger';
  end if;
end $$;

-- Test 2: attempt to UPDATE journal_entries should raise JOURNAL_IMMUTABLE
-- Create dummy journal entry via direct insert (bypass post_journal_entry for test)
-- We need a tenant and gl_account

-- Use a known tenant from seed if exists, otherwise create temp
-- For simplicity, test the trigger function directly with a temp table mimicking journal_entries

create temp table tmp_journal_test (id uuid primary key, status text) with (autovacuum_enabled=false);
create trigger tmp_no_update before update or delete on tmp_journal_test for each row execute function public.prevent_journal_mutation();

insert into tmp_journal_test (id, status) values ('00000000-0000-0000-0000-000000000001', 'posted');

do $$
begin
  begin
    update tmp_journal_test set status='void' where id='00000000-0000-0000-0000-000000000001';
    raise exception 'FAIL: update should have been blocked';
  exception when restrict_violation then
    if sqlerrm not like 'JOURNAL_IMMUTABLE:%' then
      raise exception 'FAIL: wrong error: %', sqlerrm;
    end if;
  end;
  begin
    delete from tmp_journal_test where id='00000000-0000-0000-0000-000000000001';
    raise exception 'FAIL: delete should have been blocked';
  exception when restrict_violation then
    -- expected
  end;
end $$;

drop table tmp_journal_test;

-- Test 3: void via session variable should be allowed
do $$
declare
  v_id uuid := gen_random_uuid();
begin
  -- Create a real journal entry in a temp clone to test void path
  -- We'll test the session variable logic directly
  perform set_config('app.allow_journal_void', 'true', true);
  -- Simulate: if trigger sees app.allow_journal_void=true and posted->void, it should allow
  -- Create temp table with same trigger
  create temp table tmp_void_test (id uuid primary key, status text);
  create trigger tmp_void_guard before update or delete on tmp_void_test for each row execute function public.prevent_journal_mutation();
  insert into tmp_void_test values (v_id, 'posted');
  update tmp_void_test set status='void' where id=v_id; -- should succeed because flag true
  perform set_config('app.allow_journal_void', 'false', true);
  -- Now try again, should fail
  begin
    update tmp_void_test set status='posted' where id=v_id;
    raise exception 'FAIL: second update should be blocked after flag false';
  exception when restrict_violation then
    -- ok
  end;
  drop table tmp_void_test;
end $$;

-- Test 4: posted invoice update should be blocked
do $$
declare
  v_count int;
begin
  select count(*) into v_count from pg_trigger where tgname like 'trg_prevent_posted_%' and tgrelid='public.supplier_invoices'::regclass;
  if v_count = 0 then
    raise exception 'FAIL: supplier_invoices should have posted invoice guard';
  end if;
end $$;

raise notice 'PASS: journal immutability tests';

rollback;
