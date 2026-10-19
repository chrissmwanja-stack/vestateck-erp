-- Phase A, A3 slice 2b: base-currency rounding (posting role fx_rounding,
-- journal_entry_lines.is_rounding, the extended check_journal_entry_balanced).
--
-- Covers: a journal that balances in its own currency but not after per-line
-- rounding is posted with one flagged rounding line in either direction; refused
-- (and nothing kept) when the company has no fx_rounding role; no rounding line when
-- amounts are exact; the caller cannot set the flag; differences beyond the
-- arithmetic bound still raise JOURNAL_BASE_UNBALANCED; UGX-only entries keep their
-- old rule and message; a genuine mixed-currency entry posts; the role is per
-- company; both immediate and deferred (commit-time) paths.
--
-- Run against a fresh local stack only (`supabase db reset`). One transaction that
-- ROLLBACKs. Any RAISE EXCEPTION is a real assertion failure.

\set ON_ERROR_STOP on

begin;

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

create function pg_temp.assert(p_ok boolean, p_msg text)
returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_msg; end if;
end $$;

create function pg_temp.mk_entry(p_tenant uuid, p_desc text) returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into journal_entries (tenant_id, entry_date, source_type, description)
  values (p_tenant, current_date - 1, 'manual', p_desc) returning id into v;
  return v;
end $$;

do $$
declare
  ta uuid := gen_random_uuid();
  tb uuid := gen_random_uuid();
  approver uuid := gen_random_uuid();
  bank uuid; rev1 uuid; rev2 uuid; rnd uuid; bank_b uuid; rev_b uuid;
  reg_id uuid; fx_id uuid; je uuid; n integer; r record;
begin
  -------------------------------------------------------------------
  -- Fixtures (as the table owner)
  -------------------------------------------------------------------
  insert into tenants (id, name) values (ta, 'Rounding A'), (tb, 'Rounding B');
  insert into gl_accounts (tenant_id, account_code, name, account_type) values
    (ta, '1000', 'Bank', 'asset'), (ta, '4000', 'Income 1', 'revenue'), (ta, '4100', 'Income 2', 'revenue'),
    (ta, '6999', 'FX rounding', 'expense'),
    (tb, '1000', 'Bank B', 'asset'), (tb, '4000', 'Income B', 'revenue');
  select id into bank from gl_accounts where tenant_id = ta and account_code = '1000';
  select id into rev1 from gl_accounts where tenant_id = ta and account_code = '4000';
  select id into rev2 from gl_accounts where tenant_id = ta and account_code = '4100';
  select id into rnd  from gl_accounts where tenant_id = ta and account_code = '6999';
  select id into bank_b from gl_accounts where tenant_id = tb and account_code = '1000';
  select id into rev_b  from gl_accounts where tenant_id = tb and account_code = '4000';

  -- Approved age limit and approved USD (1.5) and EUR (3700.1234) rates for both companies.
  perform set_config('reg.via_rpc', 'on', true);
  perform set_config('fx.via_rpc', 'on', true);
  for r in select t as tid from (values (ta), (tb)) v(t) loop
    insert into regulatory_parameters (tenant_id, parameter_key, value_num, effective_from, source_ref)
      values (r.tid, 'fx.rate_max_age_days', 90, date '2000-01-01', 'UNVERIFIED: test fixture') returning id into reg_id;
    update regulatory_parameters set status = 'approved', approved_by = approver, approved_at = now() where id = reg_id;
    insert into fx_rates (tenant_id, currency, rate_date, rate, source)
      values (r.tid, 'USD', current_date - 1, 1.5, 'test fixture') returning id into fx_id;
    update fx_rates set status = 'approved', approved_by = approver, approved_at = now() where id = fx_id;
    insert into fx_rates (tenant_id, currency, rate_date, rate, source)
      values (r.tid, 'EUR', current_date - 1, 3700.1234, 'test fixture') returning id into fx_id;
    update fx_rates set status = 'approved', approved_by = approver, approved_at = now() where id = fx_id;
  end loop;
  perform set_config('reg.via_rpc', 'off', true);
  perform set_config('fx.via_rpc', 'off', true);

  -------------------------------------------------------------------
  -- 1. No fx_rounding role: the rounding case is refused and nothing is kept
  -------------------------------------------------------------------
  je := pg_temp.mk_entry(ta, 'no role');
  set constraints all immediate;
  perform pg_temp.expect_error(format(
    $q$insert into journal_entry_lines (journal_entry_id, tenant_id, gl_account_id, debit, credit, currency) values
       (%L, %L, %L, 1.00, 0, 'USD'), (%L, %L, %L, 0, 0.33, 'USD'), (%L, %L, %L, 0, 0.67, 'USD')$q$,
    je, ta, bank, je, ta, rev1, je, ta, rev2),
    'JOURNAL_ROUNDING_ACCOUNT_MISSING', 'rounding needed but no fx_rounding role');
  select count(*) into n from journal_entry_lines where journal_entry_id = je;
  perform pg_temp.assert(n = 0, format('refused entry kept %s lines', n));
  set constraints all deferred;
  raise notice 'PASS: without an fx_rounding role the entry is refused and no lines are kept';

  insert into gl_posting_rules (tenant_id, account_role, gl_account_id) values (ta, 'fx_rounding', rnd);

  -------------------------------------------------------------------
  -- 2. Debits lower than credits after rounding: one debit rounding line
  -------------------------------------------------------------------
  je := pg_temp.mk_entry(ta, 'debit side short');
  set constraints all immediate;
  insert into journal_entry_lines (journal_entry_id, tenant_id, gl_account_id, debit, credit, currency) values
    (je, ta, bank, 1.00, 0, 'USD'), (je, ta, rev1, 0, 0.33, 'USD'), (je, ta, rev2, 0, 0.67, 'USD');
  set constraints all deferred;
  select count(*) into n from journal_entry_lines where journal_entry_id = je and is_rounding;
  perform pg_temp.assert(n = 1, format('expected exactly one rounding line, found %s', n));
  select * into r from journal_entry_lines where journal_entry_id = je and is_rounding;
  perform pg_temp.assert(r.gl_account_id = rnd and r.currency = 'UGX' and r.fx_rate = 1
                         and r.debit = 0.01 and r.credit = 0 and r.base_debit = 0.01 and r.base_credit = 0
                         and r.description = 'Base-currency rounding',
    format('rounding line wrong: acct %s %s rate %s dr %s cr %s', r.gl_account_id, r.currency, r.fx_rate, r.debit, r.credit));
  perform pg_temp.assert((select sum(base_debit) - sum(base_credit) from journal_entry_lines where journal_entry_id = je) = 0,
    'entry must balance in base currency after the rounding line');
  raise notice 'PASS: debit-short entry gets one UGX debit rounding line on the fx_rounding account';

  -------------------------------------------------------------------
  -- 3. Debits higher than credits after rounding: one credit rounding line
  -------------------------------------------------------------------
  je := pg_temp.mk_entry(ta, 'credit side short');
  set constraints all immediate;
  insert into journal_entry_lines (journal_entry_id, tenant_id, gl_account_id, debit, credit, currency) values
    (je, ta, bank, 0.33, 0, 'USD'), (je, ta, rev1, 0.33, 0, 'USD'), (je, ta, rev2, 0.34, 0, 'USD'),
    (je, ta, rev2, 0, 1.00, 'USD');
  set constraints all deferred;
  select * into r from journal_entry_lines where journal_entry_id = je and is_rounding;
  perform pg_temp.assert(r.credit = 0.01 and r.debit = 0 and r.base_credit = 0.01,
    format('expected a 0.01 credit rounding line, got dr %s cr %s', r.debit, r.credit));
  perform pg_temp.assert((select sum(base_debit) - sum(base_credit) from journal_entry_lines where journal_entry_id = je) = 0,
    'entry must balance in base currency after the rounding line');
  raise notice 'PASS: credit-short entry gets one UGX credit rounding line';

  -------------------------------------------------------------------
  -- 4. Commit-time path: lines inserted deferred, check runs when constraints are flushed
  -------------------------------------------------------------------
  je := pg_temp.mk_entry(ta, 'deferred path');
  insert into journal_entry_lines (journal_entry_id, tenant_id, gl_account_id, debit, credit, currency) values
    (je, ta, bank, 1.00, 0, 'USD'), (je, ta, rev1, 0, 0.33, 'USD'), (je, ta, rev2, 0, 0.67, 'USD');
  perform pg_temp.assert((select count(*) from journal_entry_lines where journal_entry_id = je) = 3, 'deferred: rounding must not run before the flush');
  set constraints all immediate;     -- runs the pending commit-time checks now
  set constraints all deferred;
  perform pg_temp.assert((select count(*) from journal_entry_lines where journal_entry_id = je and is_rounding) = 1,
    'deferred path should add exactly one rounding line when the checks run');
  perform pg_temp.assert((select sum(base_debit) - sum(base_credit) from journal_entry_lines where journal_entry_id = je) = 0,
    'deferred path must balance in base currency');
  raise notice 'PASS: the commit-time (deferred) path adds exactly one rounding line';

  -------------------------------------------------------------------
  -- 5. Exact amounts need no rounding line
  -------------------------------------------------------------------
  je := pg_temp.mk_entry(ta, 'exact');
  set constraints all immediate;
  insert into journal_entry_lines (journal_entry_id, tenant_id, gl_account_id, debit, credit, currency) values
    (je, ta, bank, 1000, 0, 'EUR'), (je, ta, rev1, 0, 1000, 'EUR');
  set constraints all deferred;
  perform pg_temp.assert((select count(*) from journal_entry_lines where journal_entry_id = je) = 2, 'exact entry should have exactly two lines');
  perform pg_temp.assert(not exists (select 1 from journal_entry_lines where journal_entry_id = je and is_rounding), 'exact entry must have no rounding line');
  raise notice 'PASS: exact foreign amounts get no rounding line';

  -------------------------------------------------------------------
  -- 6. The caller cannot set the flag
  -------------------------------------------------------------------
  je := pg_temp.mk_entry(ta, 'flag');
  set constraints all immediate;
  insert into journal_entry_lines (journal_entry_id, tenant_id, gl_account_id, debit, credit, is_rounding) values
    (je, ta, bank, 5, 0, true), (je, ta, rev1, 0, 5, true);
  set constraints all deferred;
  perform pg_temp.assert(not exists (select 1 from journal_entry_lines where journal_entry_id = je and is_rounding), 'a caller-supplied is_rounding must be ignored');
  raise notice 'PASS: a caller cannot mark a line as rounding';

  -------------------------------------------------------------------
  -- 7. Differences beyond the arithmetic bound are errors, role or not
  -------------------------------------------------------------------
  je := pg_temp.mk_entry(ta, 'far off');
  set constraints all immediate;
  perform pg_temp.expect_error(format(
    $q$insert into journal_entry_lines (journal_entry_id, tenant_id, gl_account_id, debit, credit, currency) values
       (%L, %L, %L, 10, 0, 'USD'), (%L, %L, %L, 0, 10, 'UGX')$q$, je, ta, bank, je, ta, rev1),
    'JOURNAL_BASE_UNBALANCED', 'USD 10 against UGX 10');
  -- One foreign line, UGX side off by 0.02: beyond the 0.01 bound for one line.
  perform pg_temp.expect_error(format(
    $q$insert into journal_entry_lines (journal_entry_id, tenant_id, gl_account_id, debit, credit, currency) values
       (%L, %L, %L, 1.00, 0, 'USD'), (%L, %L, %L, 0, 1.52, 'UGX')$q$, je, ta, bank, je, ta, rev1),
    'JOURNAL_BASE_UNBALANCED', 'difference of two cents on one foreign line');
  -- One foreign line, UGX side off by 0.01: within the bound, rounded to the rounding account.
  insert into journal_entry_lines (journal_entry_id, tenant_id, gl_account_id, debit, credit, currency) values
    (je, ta, bank, 1.00, 0, 'USD'), (je, ta, rev1, 0, 1.51, 'UGX');
  set constraints all deferred;
  perform pg_temp.assert((select count(*) from journal_entry_lines where journal_entry_id = je and is_rounding) = 1,
    'a one-cent difference on one foreign line should be absorbed');
  raise notice 'PASS: beyond-the-bound differences still raise JOURNAL_BASE_UNBALANCED; within it is absorbed';

  -------------------------------------------------------------------
  -- 8. UGX-only entries: same rule, same message, never a rounding line
  -------------------------------------------------------------------
  je := pg_temp.mk_entry(ta, 'ugx unbalanced');
  set constraints all immediate;
  perform pg_temp.expect_error(format(
    $q$insert into journal_entry_lines (journal_entry_id, tenant_id, gl_account_id, debit, credit) values (%L, %L, %L, 100, 0), (%L, %L, %L, 0, 99.99)$q$,
    je, ta, bank, je, ta, rev1),
    'is not balanced', 'UGX-only unbalanced entry');
  set constraints all deferred;
  raise notice 'PASS: UGX-only entries keep the old rule and message';

  -------------------------------------------------------------------
  -- 9. A genuine mixed-currency entry (balanced in base) posts with no rounding line
  -------------------------------------------------------------------
  je := pg_temp.mk_entry(ta, 'mixed');
  set constraints all immediate;
  insert into journal_entry_lines (journal_entry_id, tenant_id, gl_account_id, debit, credit, currency) values
    (je, ta, bank, 100, 0, 'EUR'), (je, ta, rev1, 0, 370012.34, 'UGX');
  set constraints all deferred;
  perform pg_temp.assert(not exists (select 1 from journal_entry_lines where journal_entry_id = je and is_rounding),
    'a mixed entry that balances in base needs no rounding line');
  raise notice 'PASS: EUR 100 against UGX 370,012.34 posts (balanced in base, not as a raw cross-currency sum)';

  -------------------------------------------------------------------
  -- 10. The role is per company
  -------------------------------------------------------------------
  je := pg_temp.mk_entry(tb, 'company B has no role');
  set constraints all immediate;
  perform pg_temp.expect_error(format(
    $q$insert into journal_entry_lines (journal_entry_id, tenant_id, gl_account_id, debit, credit, currency) values
       (%L, %L, %L, 1.00, 0, 'USD'), (%L, %L, %L, 0, 0.33, 'USD'), (%L, %L, %L, 0, 0.67, 'USD')$q$,
    je, tb, bank_b, je, tb, rev_b, je, tb, rev_b),
    'JOURNAL_ROUNDING_ACCOUNT_MISSING', 'company B uses company A''s rounding account');
  set constraints all deferred;
  raise notice 'PASS: another company''s rounding account is never used';
end $$;

do $$ begin raise notice 'PASS: journal base rounding (A3 slice 2b) tests'; end $$;

rollback;
