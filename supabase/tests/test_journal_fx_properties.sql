-- Phase A, A3: property-style tests for foreign-currency posting and void
-- (post_journal_entry, void_journal_entry, check_journal_entry_balanced).
--
-- The scenario tests (test_journal_gateway_currency.sql, test_journal_base_rounding.sql)
-- pin down specific journals. This file instead posts a few hundred RANDOM journals and
-- checks the invariants that must hold for every one of them, because rounding and
-- rate bugs live in the shapes nobody thought to write down.
--
-- Properties (P = per journal, L = whole ledger):
--   P1  Any journal that balances in its own currency posts. It never raises
--       JOURNAL_BASE_UNBALANCED, whatever the amounts, line counts or rate.
--   P2  It balances exactly in base currency once posted.
--   P3  Excluding the system rounding line it still balances in its own currency.
--   P4  There is at most one rounding line. It is in the functional currency (rate 1),
--       it equals the residual of the per-line rounded base amounts, and it is never
--       larger than the trigger's tolerance, ceil(foreign lines / 2) * 0.01.
--   P5  Every foreign line carries the approved rate for the journal date and a base
--       amount of round(amount * rate, 2).
--   V1  After a new rate is approved, voiding still reverses at each line's ORIGINAL
--       rate: original + reversal net to exactly zero in base for every account,
--       and to zero in each currency for every (account, currency).
--   V2  The reversal keeps every line's currency and rate, and has as many rounding
--       lines as the original (a reversed rounding line is not a new one).
--   V3  Voiding twice is a no-op and creates no further entry.
--   L1  After everything is voided, every account in the ledger is zero in base and in
--       each currency, including the rounding account.
--   Coverage: a guard fails the test if the random shapes stopped exercising rounding.
--
-- Deterministic: the generator is seeded, so a failure reproduces. The failing
-- iteration and its inputs are in the error message. Change the seed to explore.
--
-- Run against a fresh local stack only (`supabase db reset`). One transaction that
-- ROLLBACKs. Any RAISE EXCEPTION is a real assertion failure.

\set ON_ERROR_STOP on

begin;

create function pg_temp.assert(p_ok boolean, p_msg text)
returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_msg; end if;
end $$;

-- Split p_total cents into p_parts positive integer parts (each at least 1 cent).
create function pg_temp.split_cents(p_total integer, p_parts integer)
returns integer[] language plpgsql as $$
declare
  v_rest integer := p_total - p_parts;   -- what is left after giving every part 1 cent
  v_cuts integer[];
  v_out  integer[] := '{}';
  v_prev integer := 0;
  c integer;
begin
  if p_parts = 1 then return array[p_total]; end if;
  select coalesce(array_agg(x order by x), '{}') into v_cuts
    from (select floor(random() * (v_rest + 1))::integer as x from generate_series(1, p_parts - 1)) s;
  foreach c in array v_cuts loop
    v_out := v_out || (1 + c - v_prev);
    v_prev := c;
  end loop;
  v_out := v_out || (1 + v_rest - v_prev);
  return v_out;
end $$;

do $$
declare
  c_iterations constant integer := 300;
  ta uuid := gen_random_uuid();
  approver uuid := gen_random_uuid();
  fin uuid := gen_random_uuid();
  bank uuid; rev1 uuid; rev2 uuid; rnd uuid;
  accts uuid[];
  reg_id uuid; fx_id uuid;
  currencies text[] := array['USD', 'EUR', 'KES', 'GBP'];
  -- Awkward on purpose: fractional rates, a small one, one with 8 decimal places.
  rates numeric[]   := array[3712.34567891, 4012.5, 28.87654321, 4689.1];
  new_rates numeric[] := array[3911.11111111, 3999.9, 31.5, 4501.25];
  i integer; k integer; nd integer; nc integer; n_foreign integer;
  cur text; rate numeric; total_cents integer;
  dparts integer[]; cparts integer[]; lines jsonb;
  je uuid; jev uuid; je2 uuid;
  entries uuid[] := '{}'; reversals uuid[] := '{}'; metas jsonb[] := '{}';
  r record; v_n integer; v_resid numeric; v_tol numeric; v_expected numeric; v_ctx text;
  v_rounded integer := 0; v_entries_before integer;
begin
  perform setseed(0.31415926);

  -------------------------------------------------------------------
  -- Fixtures (as the table owner), same shape as the gateway test
  -------------------------------------------------------------------
  insert into tenants (id, name) values (ta, 'FX Property Co');
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token)
  values ('00000000-0000-0000-0000-000000000000', fin, 'authenticated', 'authenticated', 'fxp-' || fin || '@test.local',
          extensions.crypt('Tester123', extensions.gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}', '{}',
          now(), now(), '', '');
  insert into app_users (id, tenant_id, name, email, is_company_admin)
  values (fin, ta, 'FX Property Finance', 'fxp-' || fin || '@test.local', false);
  insert into finance_team_members (tenant_id, user_id, role) values (ta, fin, 'finance');

  insert into gl_accounts (tenant_id, account_code, name, account_type) values
    (ta, '1000', 'Bank', 'asset'), (ta, '4000', 'Income 1', 'revenue'), (ta, '4100', 'Income 2', 'revenue'),
    (ta, '6999', 'FX rounding', 'expense');
  select id into bank from gl_accounts where tenant_id = ta and account_code = '1000';
  select id into rev1 from gl_accounts where tenant_id = ta and account_code = '4000';
  select id into rev2 from gl_accounts where tenant_id = ta and account_code = '4100';
  select id into rnd  from gl_accounts where tenant_id = ta and account_code = '6999';
  insert into gl_posting_rules (tenant_id, account_role, gl_account_id) values (ta, 'fx_rounding', rnd);
  accts := array[bank, rev1, rev2];

  perform set_config('reg.via_rpc', 'on', true);
  perform set_config('fx.via_rpc', 'on', true);
  insert into regulatory_parameters (tenant_id, parameter_key, value_num, effective_from, source_ref)
    values (ta, 'fx.rate_max_age_days', 90, date '2000-01-01', 'UNVERIFIED: test fixture') returning id into reg_id;
  update regulatory_parameters set status = 'approved', approved_by = approver, approved_at = now() where id = reg_id;
  -- Yesterday's rates: what every journal below is dated and priced at.
  for k in 1 .. array_length(currencies, 1) loop
    insert into fx_rates (tenant_id, currency, rate_date, rate, source)
      values (ta, currencies[k], current_date - 1, rates[k], 'test fixture') returning id into fx_id;
    update fx_rates set status = 'approved', approved_by = approver, approved_at = now() where id = fx_id;
  end loop;
  perform set_config('reg.via_rpc', 'off', true);
  perform set_config('fx.via_rpc', 'off', true);

  -------------------------------------------------------------------
  -- Phase 1: post random journals; check P1 to P5 on each
  -------------------------------------------------------------------
  for i in 1 .. c_iterations loop
    k := 1 + floor(random() * array_length(currencies, 1))::integer;
    cur := currencies[k];
    rate := rates[k];
    nd := 1 + floor(random() * 3)::integer;          -- 1 to 3 debit lines
    nc := 1 + floor(random() * 3)::integer;          -- 1 to 3 credit lines
    total_cents := 10 + floor(random() * 99999990)::integer;   -- 0.10 to ~1,000,000.00
    dparts := pg_temp.split_cents(total_cents, nd);
    cparts := pg_temp.split_cents(total_cents, nc);

    select jsonb_agg(l) into lines from (
      select jsonb_build_object('gl_account_id', accts[1 + floor(random() * 3)::integer],
                                'debit', p / 100.0, 'credit', 0, 'currency', cur) as l
        from unnest(dparts) p
      union all
      select jsonb_build_object('gl_account_id', accts[1 + floor(random() * 3)::integer],
                                'debit', 0, 'credit', p / 100.0, 'currency', cur)
        from unnest(cparts) p
    ) s;

    v_ctx := format('iteration %s: %s at %s, %s debit lines %s, %s credit lines %s',
                    i, cur, rate, nd, dparts, nc, cparts);
    begin
      select id into je from post_journal_entry(ta, 'manual', null, current_date - 1, 'prop ' || i, lines);
      set constraints all immediate;
      set constraints all deferred;
    exception when others then
      raise exception 'FAIL P1: a journal balanced in % was refused (%). %', cur, sqlerrm, v_ctx;
    end;

    n_foreign := nd + nc;

    -- P2
    select coalesce(sum(base_debit - base_credit), 0) into v_resid from journal_entry_lines where journal_entry_id = je;
    perform pg_temp.assert(v_resid = 0, format('P2 base net is %s, not 0. %s', v_resid, v_ctx));

    -- P3
    select coalesce(sum(debit - credit), 0) into v_resid
      from journal_entry_lines where journal_entry_id = je and not is_rounding;
    perform pg_temp.assert(v_resid = 0, format('P3 own-currency net is %s, not 0. %s', v_resid, v_ctx));

    -- P5, per foreign line
    select count(*) into v_n from journal_entry_lines where journal_entry_id = je and not is_rounding;
    perform pg_temp.assert(v_n = n_foreign, format('expected %s lines, found %s. %s', n_foreign, v_n, v_ctx));
    for r in select * from journal_entry_lines where journal_entry_id = je and not is_rounding loop
      perform pg_temp.assert(r.currency = cur and r.fx_rate = rate,
        format('P5 line has %s at %s, expected %s at %s. %s', r.currency, r.fx_rate, cur, rate, v_ctx));
      v_expected := round(r.debit * rate, 2);
      perform pg_temp.assert(r.base_debit = v_expected,
        format('P5 base_debit %s, expected %s. %s', r.base_debit, v_expected, v_ctx));
      v_expected := round(r.credit * rate, 2);
      perform pg_temp.assert(r.base_credit = v_expected,
        format('P5 base_credit %s, expected %s. %s', r.base_credit, v_expected, v_ctx));
    end loop;

    -- P4
    select count(*) into v_n from journal_entry_lines where journal_entry_id = je and is_rounding;
    perform pg_temp.assert(v_n <= 1, format('P4 %s rounding lines on one entry. %s', v_n, v_ctx));
    select coalesce(sum(base_debit - base_credit), 0) into v_resid
      from journal_entry_lines where journal_entry_id = je and not is_rounding;   -- residual before rounding
    v_tol := ceil(n_foreign * 0.5) * 0.01;
    if v_resid = 0 then
      perform pg_temp.assert(v_n = 0, format('P4 a rounding line was added though base already balanced. %s', v_ctx));
    else
      v_rounded := v_rounded + 1;
      perform pg_temp.assert(v_n = 1, format('P4 residual %s but no rounding line. %s', v_resid, v_ctx));
      perform pg_temp.assert(abs(v_resid) <= v_tol,
        format('P4 residual %s exceeds the tolerance %s. %s', v_resid, v_tol, v_ctx));
      select * into r from journal_entry_lines where journal_entry_id = je and is_rounding;
      perform pg_temp.assert(r.currency = fin_ledger_currency(ta) and r.fx_rate = 1,
        format('P4 rounding line must be functional currency at rate 1, got %s at %s. %s', r.currency, r.fx_rate, v_ctx));
      perform pg_temp.assert(r.gl_account_id = rnd, format('P4 rounding went to the wrong account. %s', v_ctx));
      perform pg_temp.assert(r.base_debit - r.base_credit = -v_resid,
        format('P4 rounding line (%s) does not cancel the residual %s. %s', r.base_debit - r.base_credit, v_resid, v_ctx));
    end if;

    entries := entries || je;
    metas := metas || jsonb_build_object('i', i, 'ctx', v_ctx);
  end loop;

  -- Coverage guard: the generator must keep exercising the rounding path.
  perform pg_temp.assert(v_rounded >= c_iterations / 10,
    format('only %s of %s random journals needed rounding; the generator no longer exercises it', v_rounded, c_iterations));
  raise notice 'PASS P1-P5: % random foreign journals posted, balanced in base, correct rate and rounding (% needed a rounding line)',
    c_iterations, v_rounded;

  -------------------------------------------------------------------
  -- Phase 2: approve NEW rates dated today, so a void that used today's rate would fail
  -------------------------------------------------------------------
  perform set_config('fx.via_rpc', 'on', true);
  for k in 1 .. array_length(currencies, 1) loop
    insert into fx_rates (tenant_id, currency, rate_date, rate, source)
      values (ta, currencies[k], current_date, new_rates[k], 'test fixture') returning id into fx_id;
    update fx_rates set status = 'approved', approved_by = approver, approved_at = now() where id = fx_id;
  end loop;
  perform set_config('fx.via_rpc', 'off', true);

  -------------------------------------------------------------------
  -- Phase 3: void every journal; check V1 to V3
  -------------------------------------------------------------------
  for i in 1 .. array_length(entries, 1) loop
    je := entries[i];
    v_ctx := metas[i] ->> 'ctx';

    perform set_config('request.jwt.claims', json_build_object('sub', fin, 'role', 'authenticated')::text, true);
    set local role authenticated;
    select id into jev from void_journal_entry(je, 'property test void ' || i);
    reset role;
    set constraints all immediate;
    set constraints all deferred;
    reversals := reversals || jev;

    -- V1, in base currency per account
    perform pg_temp.assert(not exists (
        select 1 from journal_entry_lines where journal_entry_id in (je, jev)
         group by gl_account_id having sum(base_debit - base_credit) <> 0),
      format('V1 an account does not net to zero in base after the void. %s', v_ctx));
    -- V1, in each currency per account
    perform pg_temp.assert(not exists (
        select 1 from journal_entry_lines where journal_entry_id in (je, jev)
         group by gl_account_id, currency having sum(debit - credit) <> 0),
      format('V1 an account does not net to zero in its own currency after the void. %s', v_ctx));

    -- V2, the reversal keeps each line's currency and rate, and the rounding line count
    perform pg_temp.assert(not exists (
        select 1 from journal_entry_lines rl
         where rl.journal_entry_id = jev
           and not exists (select 1 from journal_entry_lines ol
                            where ol.journal_entry_id = je and ol.currency = rl.currency and ol.fx_rate = rl.fx_rate)),
      format('V2 a reversal line uses a currency or rate the original never had. %s', v_ctx));
    perform pg_temp.assert(
      (select count(*) from journal_entry_lines where journal_entry_id = jev and is_rounding)
        = (select count(*) from journal_entry_lines where journal_entry_id = je and is_rounding),
      format('V2 reversal has a different number of rounding lines than the original. %s', v_ctx));
    perform pg_temp.assert((select status from journal_entries where id = je) = 'void',
      format('V2 the original must be marked void. %s', v_ctx));

    -- V3, void again is a no-op (checked on a sample to keep the run short)
    if i % 10 = 0 then
      select count(*) into v_entries_before from journal_entries where tenant_id = ta;
      perform set_config('request.jwt.claims', json_build_object('sub', fin, 'role', 'authenticated')::text, true);
      set local role authenticated;
      select id into je2 from void_journal_entry(je, 'property test void again ' || i);
      reset role;
      perform pg_temp.assert(je2 = je, format('V3 a second void returned a different entry. %s', v_ctx));
      perform pg_temp.assert((select count(*) from journal_entries where tenant_id = ta) = v_entries_before,
        format('V3 a second void created another entry. %s', v_ctx));
    end if;
  end loop;
  raise notice 'PASS V1-V3: % voids reversed at the original rates, netting to zero per account and per currency', array_length(entries, 1);

  -------------------------------------------------------------------
  -- L1: everything is voided, so the whole ledger must be zero
  -------------------------------------------------------------------
  perform pg_temp.assert(not exists (
      select 1 from journal_entry_lines where tenant_id = ta
       group by gl_account_id having sum(base_debit - base_credit) <> 0),
    'L1 after voiding everything, some account is not zero in base currency');
  perform pg_temp.assert(not exists (
      select 1 from journal_entry_lines where tenant_id = ta
       group by gl_account_id, currency having sum(debit - credit) <> 0),
    'L1 after voiding everything, some account is not zero in its own currency');
  perform pg_temp.assert(
    (select coalesce(sum(base_debit), 0) from journal_entry_lines where tenant_id = ta)
      = (select coalesce(sum(base_credit), 0) from journal_entry_lines where tenant_id = ta),
    'L1 the base-currency trial balance does not balance');
  raise notice 'PASS L1: the ledger is zero in base and in every currency after voiding all journals, rounding account included';
end $$;

do $$ begin raise notice 'PASS: foreign-currency posting and void property tests (A3)'; end $$;

rollback;