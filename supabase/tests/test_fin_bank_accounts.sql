-- Phase 2, D4a: bank-account registry (fin_bank_accounts).
--
-- Covers: creation rules (CHECKs and the guard trigger), client-money vs
-- operating segregation, immutability, no-delete, RLS (finance read/write,
-- cost_control read-only, outsiders, other tenants, anon), the read-only
-- guard attachment, the unregistered-names view and the backfill function.
--
-- Run against a fresh local stack only (`supabase start` / `supabase db reset`).
-- Everything runs in one transaction that ROLLBACKs, so no fixture data is left
-- behind; any RAISE EXCEPTION is a real assertion failure and makes psql exit
-- non-zero (see the other files in this directory for the same convention).

\set ON_ERROR_STOP on

begin;

-- Runs a statement that must fail with an error whose text contains p_needle.
create function pg_temp.expect_error(p_sql text, p_needle text, p_label text)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm like '%' || p_needle || '%' then
      return;
    end if;
    raise exception 'FAIL: % raised the wrong error: %', p_label, sqlerrm;
  end;
  raise exception 'FAIL: % succeeded but should have failed with %', p_label, p_needle;
end $$;

do $$
declare
  v_ta uuid := gen_random_uuid();   -- tenant A (main)
  v_tb uuid := gen_random_uuid();   -- tenant B (isolation)
  v_fin_a uuid := gen_random_uuid();
  v_cc_a  uuid := gen_random_uuid();
  v_out_a uuid := gen_random_uuid();
  v_fin_b uuid := gen_random_uuid();

  v_bank_a uuid; v_cash_a uuid; v_trust_a uuid; v_liab_a uuid;
  v_inactive_a uuid; v_spare_a uuid; v_spare2_a uuid; v_bank_b uuid;

  v_ops uuid; v_trust uuid; v_legacy uuid;
  v_n integer;
  v_row fin_bank_accounts%rowtype;
begin
  -------------------------------------------------------------------
  -- Fixtures (as the table owner)
  -------------------------------------------------------------------
  insert into tenants (id, name) values (v_ta, 'Bank Registry Co A'), (v_tb, 'Bank Registry Co B');

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, recovery_token
  )
  select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
         'bankreg-' || u.id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
         now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
  from (values (v_fin_a), (v_cc_a), (v_out_a), (v_fin_b)) as u(id);

  insert into app_users (id, tenant_id, name, email) values
    (v_fin_a, v_ta, 'Registry Finance A', 'bankreg-' || v_fin_a || '@test.local'),
    (v_cc_a,  v_ta, 'Registry Cost Control A', 'bankreg-' || v_cc_a || '@test.local'),
    (v_out_a, v_ta, 'Registry Outsider A', 'bankreg-' || v_out_a || '@test.local'),
    (v_fin_b, v_tb, 'Registry Finance B', 'bankreg-' || v_fin_b || '@test.local');

  insert into finance_team_members (tenant_id, user_id, role) values
    (v_ta, v_fin_a, 'finance'),
    (v_ta, v_cc_a, 'cost_control'),
    (v_tb, v_fin_b, 'finance');
  -- v_out_a is deliberately not on the finance team.

  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '1000', 'Operating Bank', 'asset') returning id into v_bank_a;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '1010', 'Cash', 'asset') returning id into v_cash_a;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '1020', 'Client Money Bank', 'asset') returning id into v_trust_a;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '1030', 'Spare Bank', 'asset') returning id into v_spare_a;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '1040', 'Spare Bank 2', 'asset') returning id into v_spare2_a;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_ta, '2010', 'Insurer Payable', 'liability') returning id into v_liab_a;
  insert into gl_accounts (tenant_id, account_code, name, account_type, is_active) values (v_ta, '1999', 'Retired Bank', 'asset', false) returning id into v_inactive_a;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_tb, '1000', 'Operating Bank', 'asset') returning id into v_bank_b;

  insert into gl_posting_rules (tenant_id, account_role, gl_account_id) values
    (v_ta, 'bank', v_bank_a),
    (v_ta, 'cash', v_cash_a),
    (v_ta, 'client_money_bank', v_trust_a);

  -------------------------------------------------------------------
  -- 1. Finance user: creation rules
  -------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object('sub', v_fin_a, 'role', 'authenticated')::text, true);
  set local role authenticated;

  insert into fin_bank_accounts (tenant_id, name, kind, currency, gl_account_id)
  values (v_ta, 'OPS-UGX', 'operating', 'UGX', v_bank_a) returning id into v_ops;

  insert into fin_bank_accounts (tenant_id, name, kind, currency, gl_account_id)
  values (v_ta, 'TRUST-UGX', 'client_money', 'UGX', v_trust_a) returning id into v_trust;

  -- A legacy-style row: defaults, no GL account yet.
  insert into fin_bank_accounts (tenant_id, name) values (v_ta, 'LEGACY-1') returning id into v_legacy;
  select * into v_row from fin_bank_accounts where id = v_legacy;
  if v_row.kind <> 'operating' or v_row.currency <> 'UGX' or v_row.gl_account_id is not null or not v_row.is_active then
    raise exception 'FAIL: defaults wrong for a bare insert (kind %, currency %, gl %, active %)',
      v_row.kind, v_row.currency, v_row.gl_account_id, v_row.is_active;
  end if;
  raise notice 'PASS: finance user registers operating, client-money and legacy-style accounts';

  perform pg_temp.expect_error(
    format('insert into fin_bank_accounts (tenant_id, name, kind) values (%L, ''CM-NOGL'', ''client_money'')', v_ta),
    'fin_bank_accounts_client_money_gl_check', 'client_money without a GL account');
  perform pg_temp.expect_error(
    format('insert into fin_bank_accounts (tenant_id, name, gl_account_id) values (%L, ''X-LIAB'', %L)', v_ta, v_liab_a),
    'BANK_ACCOUNT_GL_INVALID', 'liability GL account');
  perform pg_temp.expect_error(
    format('insert into fin_bank_accounts (tenant_id, name, gl_account_id) values (%L, ''X-OTHERTENANT'', %L)', v_ta, v_bank_b),
    'BANK_ACCOUNT_GL_INVALID', 'GL account of another company');
  perform pg_temp.expect_error(
    format('insert into fin_bank_accounts (tenant_id, name, gl_account_id) values (%L, ''X-INACTIVE'', %L)', v_ta, v_inactive_a),
    'BANK_ACCOUNT_GL_INVALID', 'inactive GL account');
  raise notice 'PASS: GL account must be an active asset account of the same company';

  -- Segregation: three independent ways to break it.
  perform pg_temp.expect_error(
    format('insert into fin_bank_accounts (tenant_id, name, kind, gl_account_id) values (%L, ''X-OPS-ON-TRUST'', ''operating'', %L)', v_ta, v_trust_a),
    'BANK_ACCOUNT_SEGREGATION', 'operating account on the client-money GL account');
  perform pg_temp.expect_error(
    format('insert into fin_bank_accounts (tenant_id, name, kind, gl_account_id) values (%L, ''X-CM-ON-OPS'', ''client_money'', %L)', v_ta, v_bank_a),
    'BANK_ACCOUNT_SEGREGATION', 'client-money account sharing an operating account''s GL account');
  perform pg_temp.expect_error(
    format('insert into fin_bank_accounts (tenant_id, name, kind, gl_account_id) values (%L, ''X-CM-ON-CASH'', ''client_money'', %L)', v_ta, v_cash_a),
    'BANK_ACCOUNT_SEGREGATION', 'client-money account on the operating cash posting account');
  -- A dedicated second client-money account on its own GL account is fine.
  insert into fin_bank_accounts (tenant_id, name, kind, gl_account_id) values (v_ta, 'TRUST-2', 'client_money', v_spare_a);
  -- ...and then that GL account is client money for good.
  perform pg_temp.expect_error(
    format('insert into fin_bank_accounts (tenant_id, name, kind, gl_account_id) values (%L, ''X-OPS-ON-TRUST2'', ''operating'', %L)', v_ta, v_spare_a),
    'BANK_ACCOUNT_SEGREGATION', 'operating account on a second client-money GL account');
  raise notice 'PASS: client money and operating money cannot share a GL account';

  -- Plain CHECKs and uniqueness.
  perform pg_temp.expect_error(
    format('insert into fin_bank_accounts (tenant_id, name) values (%L, ''OPS-UGX'')', v_ta),
    'fin_bank_accounts_tenant_name_unique', 'duplicate name');
  perform pg_temp.expect_error(
    format('insert into fin_bank_accounts (tenant_id, name) values (%L, '' PADDED'')', v_ta),
    'fin_bank_accounts_name_check', 'name with leading space');
  perform pg_temp.expect_error(
    format('insert into fin_bank_accounts (tenant_id, name) values (%L, '''')', v_ta),
    'fin_bank_accounts_name_check', 'empty name');
  perform pg_temp.expect_error(
    format('insert into fin_bank_accounts (tenant_id, name, currency) values (%L, ''X-CUR'', ''ugx'')', v_ta),
    'fin_bank_accounts_currency_check', 'lower-case currency');
  perform pg_temp.expect_error(
    format('insert into fin_bank_accounts (tenant_id, name, kind, gl_account_id) values (%L, ''X-KIND'', ''savings'', %L)', v_ta, v_spare2_a),
    'fin_bank_accounts_kind_check', 'unknown kind');
  raise notice 'PASS: name, currency and kind constraints';

  -------------------------------------------------------------------
  -- 2. Immutability, completing a legacy row, no delete
  -------------------------------------------------------------------
  perform pg_temp.expect_error(
    format('update fin_bank_accounts set name = ''OPS-RENAMED'' where id = %L', v_ops),
    'BANK_ACCOUNT_NAME_IMMUTABLE', 'rename');
  perform pg_temp.expect_error(
    format('update fin_bank_accounts set kind = ''client_money'' where id = %L', v_legacy),
    'BANK_ACCOUNT_KIND_IMMUTABLE', 'change kind');
  perform pg_temp.expect_error(
    format('update fin_bank_accounts set gl_account_id = %L where id = %L', v_spare_a, v_ops),
    'BANK_ACCOUNT_GL_IMMUTABLE', 're-point a mapped GL account');

  -- Mapping a legacy row for the first time is allowed, once.
  update fin_bank_accounts set gl_account_id = v_cash_a where id = v_legacy;
  perform pg_temp.expect_error(
    format('update fin_bank_accounts set gl_account_id = %L where id = %L', v_bank_a, v_legacy),
    'BANK_ACCOUNT_GL_IMMUTABLE', 're-point after first mapping');

  -- Ordinary edits and deactivation work.
  update fin_bank_accounts set bank_name = 'Stanbic', account_number = '9030001', is_active = false where id = v_ops;
  select * into v_row from fin_bank_accounts where id = v_ops;
  if v_row.bank_name <> 'Stanbic' or v_row.is_active then
    raise exception 'FAIL: ordinary edit / deactivation did not stick';
  end if;
  update fin_bank_accounts set is_active = true where id = v_ops;

  perform pg_temp.expect_error(
    format('delete from fin_bank_accounts where id = %L', v_ops),
    'permission denied', 'delete');
  raise notice 'PASS: name, kind and mapped GL account are immutable; edits and deactivation work; delete is refused';

  -------------------------------------------------------------------
  -- 3. Who can see and write
  -------------------------------------------------------------------
  -- cost_control: reads, cannot write.
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cc_a, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into v_n from fin_bank_accounts;
  if v_n < 4 then
    raise exception 'FAIL: cost_control member should read the registry, saw % rows', v_n;
  end if;
  perform pg_temp.expect_error(
    format('insert into fin_bank_accounts (tenant_id, name) values (%L, ''CC-WRITE'')', v_ta),
    'row-level security', 'cost_control insert');
  update fin_bank_accounts set bank_name = 'hijack' where id = v_ops;
  get diagnostics v_n = row_count;
  if v_n <> 0 then
    raise exception 'FAIL: cost_control update changed % row(s)', v_n;
  end if;

  -- A tenant member who is not on the finance team: nothing.
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', v_out_a, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into v_n from fin_bank_accounts;
  if v_n <> 0 then
    raise exception 'FAIL: non-finance member saw % registry row(s)', v_n;
  end if;
  perform pg_temp.expect_error(
    format('insert into fin_bank_accounts (tenant_id, name) values (%L, ''OUT-WRITE'')', v_ta),
    'row-level security', 'non-finance insert');

  -- Finance user of another company: sees nothing of A, cannot write into A.
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', v_fin_b, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into v_n from fin_bank_accounts;
  if v_n <> 0 then
    raise exception 'FAIL: another company''s finance user saw % registry row(s)', v_n;
  end if;
  perform pg_temp.expect_error(
    format('insert into fin_bank_accounts (tenant_id, name) values (%L, ''CROSS-TENANT'')', v_ta),
    'row-level security', 'cross-tenant insert');
  insert into fin_bank_accounts (tenant_id, name, gl_account_id) values (v_tb, 'B-OPS', v_bank_b);

  -- anon: no access at all.
  reset role;
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  set local role anon;
  perform pg_temp.expect_error('select 1 from fin_bank_accounts', 'permission denied', 'anon select');
  perform pg_temp.expect_error('select 1 from fin_unregistered_bank_accounts', 'permission denied', 'anon view select');
  reset role;
  raise notice 'PASS: RLS (finance writes, cost_control reads, outsiders / other tenants / anon see nothing)';

  -------------------------------------------------------------------
  -- 4. Triggers attached
  -------------------------------------------------------------------
  select count(*) into v_n from pg_trigger
  where tgrelid = 'public.fin_bank_accounts'::regclass and not tgisinternal and tgenabled = 'O'
    and tgname in ('tenant_read_only_guard', 'trg_fin_bank_accounts_guard', 'trg_touch_fin_bank_accounts_updated_at');
  if v_n <> 3 then
    raise exception 'FAIL: expected read-only guard, validation and touch triggers on fin_bank_accounts, found %', v_n;
  end if;
  raise notice 'PASS: read-only guard, validation and updated_at triggers are attached';

  -------------------------------------------------------------------
  -- 5. Unregistered-names view
  -------------------------------------------------------------------
  -- payroll_run rows are not posted by the cash trigger, so no chart is needed.
  -- cash_bank_transactions has a BEFORE INSERT trigger that forces tenant_id to
  -- the caller's tenant; fixtures that name a tenant switch it off for the
  -- fixture insert only (this whole file rolls back).
  -- recorded_by defaults to auth.uid() and is NOT NULL, so fixtures act as a user.
  perform set_config('request.jwt.claims', json_build_object('sub', v_fin_a, 'role', 'authenticated')::text, true);
  alter table cash_bank_transactions disable trigger set_cash_bank_transaction_defaults_trigger;
  insert into cash_bank_transactions (tenant_id, transaction_type, payment_method, reference_type, reference_id, amount, transaction_date, bank_account)
  values (v_ta, 'payment', 'bank', 'payroll_run', gen_random_uuid(), 1000, current_date, 'UNMAPPED-1'),
         (v_ta, 'payment', 'bank', 'payroll_run', gen_random_uuid(), 1000, current_date, 'OPS-UGX');
  alter table cash_bank_transactions enable trigger set_cash_bank_transaction_defaults_trigger;
  insert into bank_statement_lines (tenant_id, bank_account, statement_date, amount)
  values (v_ta, 'UNMAPPED-1', current_date, -1000),
         (v_ta, 'UNMAPPED-2', current_date, -500);

  perform set_config('request.jwt.claims', json_build_object('sub', v_fin_a, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into v_n from fin_unregistered_bank_accounts where name = 'OPS-UGX';
  if v_n <> 0 then raise exception 'FAIL: a registered name appears in fin_unregistered_bank_accounts'; end if;
  select row_count into v_n from fin_unregistered_bank_accounts where name = 'UNMAPPED-1';
  if v_n is distinct from 2 then raise exception 'FAIL: UNMAPPED-1 should have 2 rows, view says %', v_n; end if;
  if not exists (select 1 from fin_unregistered_bank_accounts where name = 'UNMAPPED-1' and sources = array['bank_statement_lines', 'cash_bank_transactions']) then
    raise exception 'FAIL: UNMAPPED-1 should list both sources';
  end if;
  if not exists (select 1 from fin_unregistered_bank_accounts where name = 'UNMAPPED-2' and sources = array['bank_statement_lines']) then
    raise exception 'FAIL: UNMAPPED-2 should list the statement source only';
  end if;
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', v_fin_b, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into v_n from fin_unregistered_bank_accounts;
  if v_n <> 0 then raise exception 'FAIL: another company''s finance user saw % unregistered name(s)', v_n; end if;
  reset role;
  raise notice 'PASS: fin_unregistered_bank_accounts lists unregistered names, scoped to the caller''s company';
end $$;

-- ---------------------------------------------------------------------
-- 6. Backfill
-- ---------------------------------------------------------------------
do $$
declare
  v_tc uuid := gen_random_uuid();   -- has a chart and a 'bank' rule
  v_td uuid := gen_random_uuid();   -- no posting rules at all
  v_te uuid := gen_random_uuid();   -- 'bank' rule points at a non-asset account
  v_bank_c uuid; v_trust_c uuid; v_liab_e uuid;
  v_n integer;
  v_row fin_bank_accounts%rowtype;
begin
  insert into tenants (id, name) values (v_tc, 'Backfill C'), (v_td, 'Backfill D'), (v_te, 'Backfill E');

  -- Transactions first, posting rules after, so no posting is attempted.
  -- (Tenant-forcing trigger off for the fixtures only; see section 5.)
  perform set_config('request.jwt.claims', json_build_object('sub', (select id from auth.users limit 1), 'role', 'authenticated')::text, true);
  alter table cash_bank_transactions disable trigger set_cash_bank_transaction_defaults_trigger;
  insert into cash_bank_transactions (tenant_id, transaction_type, payment_method, reference_type, reference_id, amount, currency, transaction_date, bank_account)
  select v_tc, 'payment', 'bank', 'payroll_run', gen_random_uuid(), 100, c.cur, current_date, c.acct
  from (values
    ('STANBIC-1', 'UGX'), ('STANBIC-1', 'UGX'), ('STANBIC-1', 'UGX'), ('STANBIC-1', 'USD'),
    ('  STANBIC-1  ', 'UGX'),
    ('DFCU-USD', 'USD'),
    ('JUNKCUR', 'ugx '),
    ('BADCUR', 'XX')
  ) as c(acct, cur);
  insert into cash_bank_transactions (tenant_id, transaction_type, payment_method, reference_type, reference_id, amount, transaction_date, bank_account)
  values (v_tc, 'payment', 'bank', 'payroll_run', gen_random_uuid(), 100, current_date, null),
         (v_tc, 'payment', 'bank', 'payroll_run', gen_random_uuid(), 100, current_date, '   ');
  insert into bank_statement_lines (tenant_id, bank_account, statement_date, amount)
  values (v_tc, 'CENTENARY', current_date, 50), (v_tc, 'STANBIC-1', current_date, 50);

  insert into cash_bank_transactions (tenant_id, transaction_type, payment_method, reference_type, reference_id, amount, transaction_date, bank_account)
  values (v_td, 'payment', 'bank', 'payroll_run', gen_random_uuid(), 100, current_date, 'D-ACC'),
         (v_te, 'payment', 'bank', 'payroll_run', gen_random_uuid(), 100, current_date, 'E-ACC');

  alter table cash_bank_transactions enable trigger set_cash_bank_transaction_defaults_trigger;

  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_tc, '1000', 'Operating Bank', 'asset') returning id into v_bank_c;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_tc, '1020', 'Client Money Bank', 'asset') returning id into v_trust_c;
  insert into gl_accounts (tenant_id, account_code, name, account_type) values (v_te, '2000', 'Not an asset', 'liability') returning id into v_liab_e;
  insert into gl_posting_rules (tenant_id, account_role, gl_account_id) values
    (v_tc, 'bank', v_bank_c), (v_tc, 'client_money_bank', v_trust_c), (v_te, 'bank', v_liab_e);

  -- Tenant C: STANBIC-1 (merged across spellings and sources), DFCU-USD, JUNKCUR, BADCUR, CENTENARY.
  v_n := public.platform_fin_backfill_bank_accounts(v_tc);
  if v_n <> 5 then raise exception 'FAIL: backfill registered % accounts for tenant C, expected 5', v_n; end if;

  select * into v_row from fin_bank_accounts where tenant_id = v_tc and name = 'STANBIC-1';
  if v_row.currency <> 'UGX' or v_row.gl_account_id is distinct from v_bank_c or v_row.kind <> 'operating' then
    raise exception 'FAIL: STANBIC-1 should be operating, UGX (most used), on the bank-rule account; got % % %', v_row.kind, v_row.currency, v_row.gl_account_id;
  end if;
  select * into v_row from fin_bank_accounts where tenant_id = v_tc and name = 'DFCU-USD';
  if v_row.currency <> 'USD' then raise exception 'FAIL: DFCU-USD currency is %', v_row.currency; end if;
  select * into v_row from fin_bank_accounts where tenant_id = v_tc and name = 'JUNKCUR';
  if v_row.currency <> 'UGX' then raise exception 'FAIL: ''ugx '' should normalise to UGX, got %', v_row.currency; end if;
  select * into v_row from fin_bank_accounts where tenant_id = v_tc and name = 'BADCUR';
  if v_row.currency <> 'UGX' then raise exception 'FAIL: unusable currency should fall back to UGX, got %', v_row.currency; end if;
  select count(*) into v_n from fin_bank_accounts where tenant_id = v_tc and name in ('', '   ');
  if v_n <> 0 then raise exception 'FAIL: blank bank_account values must not be registered'; end if;
  select count(*) into v_n from fin_bank_accounts where tenant_id = v_td or tenant_id = v_te;
  if v_n <> 0 then raise exception 'FAIL: backfill for tenant C touched other tenants'; end if;

  -- Idempotent.
  v_n := public.platform_fin_backfill_bank_accounts(v_tc);
  if v_n <> 0 then raise exception 'FAIL: second backfill registered % accounts, expected 0', v_n; end if;
  raise notice 'PASS: backfill merges spellings and sources, picks the most-used currency, maps the bank-rule account, is idempotent and tenant-scoped';

  -- No rule at all: registered, unmapped. Non-asset rule account: registered, unmapped, no error.
  perform public.platform_fin_backfill_bank_accounts(v_td);
  perform public.platform_fin_backfill_bank_accounts(v_te);
  select * into v_row from fin_bank_accounts where tenant_id = v_td and name = 'D-ACC';
  if v_row.id is null or v_row.gl_account_id is not null then raise exception 'FAIL: D-ACC should be registered without a GL account'; end if;
  select * into v_row from fin_bank_accounts where tenant_id = v_te and name = 'E-ACC';
  if v_row.id is null or v_row.gl_account_id is not null then raise exception 'FAIL: E-ACC must be registered unmapped when the bank rule is not an asset account'; end if;
  raise notice 'PASS: backfill leaves GL unmapped when the tenant has no usable bank rule, without failing';

  -- The 'client_money_bank' rule account cannot back an operating account
  -- (rule path; no client_money registry row exists in tenant C).
  perform pg_temp.expect_error(
    format('insert into fin_bank_accounts (tenant_id, name, kind, gl_account_id) values (%L, ''X-OPS-ON-CMRULE'', ''operating'', %L)', v_tc, v_trust_c),
    'BANK_ACCOUNT_SEGREGATION', 'operating account on the client_money_bank rule account');
  -- Moving the tenant boundary is blocked even for the table owner.
  perform pg_temp.expect_error(
    format('update fin_bank_accounts set tenant_id = %L where tenant_id = %L and name = ''CENTENARY''', v_td, v_tc),
    'BANK_ACCOUNT_TENANT_IMMUTABLE', 'move account to another tenant');
  raise notice 'PASS: segregation via the client_money_bank rule; tenant is immutable';

  -- Internal function is not callable by clients.
  perform set_config('request.jwt.claims', '{"role":"authenticated"}', true);
  set local role authenticated;
  perform pg_temp.expect_error('select public.platform_fin_backfill_bank_accounts()', 'permission denied', 'client call to backfill');
  reset role;
  raise notice 'PASS: backfill function is internal';
end $$;

do $$ begin raise notice 'PASS: fin_bank_accounts (D4a) tests'; end $$;

rollback;