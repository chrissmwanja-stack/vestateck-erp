-- =====================================================================
-- Manual journals: the four criteria the pack sets
-- Accountant pack v2, B6
-- =====================================================================
--   "not unbalanced"                                              §1
--   "not self-approved"                                           §3
--   "no control account without a subledger reference"             §4
--   "not editable after posting"                                   §6
--
-- §2 proves the ledger primitive stays locked to ordinary users: the governed surface
-- is the only way in, and it is the surface that carries the controls.
-- §5 proves approval is what posts, in one transaction, and that the posting lands on
-- the real ledger rather than in a side table.
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

do $$
declare
  ta      uuid := gen_random_uuid();
  maker   uuid := gen_random_uuid();
  checker uuid := gen_random_uuid();
  admin1  uuid := gen_random_uuid();
  admin2  uuid := gen_random_uuid();
  outsider uuid := gen_random_uuid();
<<<<<<< ours
  exp_gl uuid; ar_gl uuid; ap_gl uuid; rev_gl uuid;
=======
  exp_gl uuid; ar_gl uuid; ap_gl uuid; rev_gl uuid; accr_gl uuid;
>>>>>>> theirs
  v_party uuid; v_supplier uuid;
begin
  insert into tenants(id, name) values (ta, 'Manual journal test');
  insert into auth.users(id, email, raw_user_meta_data, raw_app_meta_data, aud, role, created_at, updated_at)
    select u, 'mj-' || u || '@test.local', '{}', '{}', 'authenticated', 'authenticated', now(), now()
    from unnest(array[maker, checker, admin1, admin2, outsider]) u;
  insert into app_users(id, tenant_id, name, email)
    select u, ta, 'Journal actor', 'mj-' || u || '@test.local'
    from unnest(array[maker, checker, admin1, admin2, outsider]) u;
  update app_users set is_company_admin = true where id in (admin1, admin2);
  insert into finance_team_members(tenant_id, user_id, role)
    values (ta, maker, 'finance'), (ta, checker, 'finance');

  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '5000', 'Expenses', 'expense') returning id into exp_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '1100', 'AR control', 'asset') returning id into ar_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '2000', 'AP control', 'liability') returning id into ap_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '4100', 'Other revenue', 'revenue') returning id into rev_gl;
<<<<<<< ours
=======
  -- A liability that is NOT a control account. §1 needs a journal whose only fault is the
  -- imbalance: written against 2000 it was refused for posting to a control account first,
  -- because account-level checks run per line before the totals are compared. Both refusals
  -- are correct; only one of them tests §1.
  insert into gl_accounts(tenant_id, account_code, name, account_type) values (ta, '2100', 'Accruals', 'liability') returning id into accr_gl;
>>>>>>> theirs

  -- The control roles decide which subledger an open item belongs to, so the test can
  -- prove a reference resolves to the right account.
  update gl_accounts set is_control_account = true where id in (ar_gl, ap_gl);
  insert into gl_posting_rules(tenant_id, account_role, gl_account_id) values
    (ta, 'ar_control', ar_gl), (ta, 'ap_control', ap_gl);

<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
  insert into accounts(tenant_id, account_code, name, account_type) values (ta, 'T-' || substr(gen_random_uuid()::text, 1, 8), 'MJ client', 'client') returning id into v_party;
  insert into accounts(tenant_id, account_code, name, account_type) values (ta, 'T-' || substr(gen_random_uuid()::text, 1, 8), 'MJ supplier', 'vendor') returning id into v_supplier;
=======
  insert into accounts(tenant_id, name, account_type) values (ta, 'MJ client', 'client') returning id into v_party;
  insert into accounts(tenant_id, name, account_type) values (ta, 'MJ supplier', 'vendor') returning id into v_supplier;
>>>>>>> theirs
=======
  insert into accounts(tenant_id, name, account_type) values (ta, 'MJ client', 'client') returning id into v_party;
  insert into accounts(tenant_id, name, account_type) values (ta, 'MJ supplier', 'vendor') returning id into v_supplier;
>>>>>>> theirs
=======
  insert into accounts(tenant_id, name, account_type) values (ta, 'MJ client', 'client') returning id into v_party;
  insert into accounts(tenant_id, name, account_type) values (ta, 'MJ supplier', 'vendor') returning id into v_supplier;
>>>>>>> theirs
=======
  insert into accounts(tenant_id, account_code, name, account_type) values (ta, 'MJ-CLIENT', 'MJ client', 'client') returning id into v_party;
  insert into accounts(tenant_id, account_code, name, account_type) values (ta, 'MJ-SUPPLIER', 'MJ supplier', 'vendor') returning id into v_supplier;
>>>>>>> theirs

  create temp table ids (k text primary key, v uuid);
  insert into ids(k, v) values ('tenant', ta), ('maker', maker), ('checker', checker),
    ('admin1', admin1), ('admin2', admin2), ('outsider', outsider),
<<<<<<< ours
    ('exp', exp_gl), ('ar', ar_gl), ('ap', ap_gl), ('rev', rev_gl),
=======
    ('exp', exp_gl), ('ar', ar_gl), ('ap', ap_gl), ('rev', rev_gl), ('accr', accr_gl),
>>>>>>> theirs
    ('party', v_party), ('supplier', v_supplier);
end $$;

create function pg_temp.id(p_key text) returns uuid
language sql security definer set search_path = public, pg_temp as $$
  select v from pg_temp.ids where k = p_key
$$;
grant execute on function pg_temp.id(text) to authenticated;

-- ---------------------------------------------------------------------
-- §1 an unbalanced journal is refused, at the point it is written
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.jwt(pg_temp.id('maker'));
  set local role authenticated;
  perform pg_temp.expect_error(
    format($q$select public.fin_create_manual_journal(current_date, 'accrue the March audit fee', 'INV-AUD-001', %L::jsonb)$q$,
      jsonb_build_array(
        jsonb_build_object('gl_account_id', pg_temp.id('exp'), 'debit', 500000),
<<<<<<< ours
        jsonb_build_object('gl_account_id', pg_temp.id('ap'),  'credit', 400000))),
=======
        jsonb_build_object('gl_account_id', pg_temp.id('accr'), 'credit', 400000))),
>>>>>>> theirs
    'FIN_MANUAL_JOURNAL_UNBALANCED',
    '§1 a journal whose debits and credits differ');
  reset role;
  raise notice 'PASS: §1 an unbalanced manual journal is refused with the figures, before it can reach the ledger';
end $$;

-- ---------------------------------------------------------------------
-- §2 the ledger primitive itself stays locked
-- ---------------------------------------------------------------------
do $$
declare v_locked boolean := false;
begin
  perform pg_temp.assert(
    not has_function_privilege('authenticated', 'public.post_journal_entry(uuid,text,uuid,date,text,jsonb)', 'EXECUTE'),
    '§2 post_journal_entry must NOT be executable by authenticated: the governed surface is what carries the controls');
  raise notice 'PASS: §2 the raw primitive stays locked and only the governed surface writes journals';
end $$;

-- ---------------------------------------------------------------------
-- §3 the writer cannot approve their own journal
-- ---------------------------------------------------------------------
do $$
declare v_id uuid;
begin
  perform pg_temp.jwt(pg_temp.id('maker'));
  set local role authenticated;
  v_id := (public.fin_create_manual_journal(
             current_date, 'accrue the March audit fee', 'INV-AUD-001',
             jsonb_build_array(
               jsonb_build_object('gl_account_id', pg_temp.id('exp'), 'debit', 500000, 'description', 'audit fee'),
<<<<<<< ours
               jsonb_build_object('gl_account_id', pg_temp.id('ap'),  'credit', 500000, 'description', 'audit fee payable')))).id;
=======
               jsonb_build_object('gl_account_id', pg_temp.id('accr'), 'credit', 500000, 'description', 'audit fee payable')))).id;
>>>>>>> theirs
  perform public.fin_submit_manual_journal(v_id);

  -- maker wrote it, maker submitted it. maker may not approve it.
  perform pg_temp.expect_error(
    format($q$select public.fin_decide_manual_journal(%L, 'approve', 'looks fine')$q$, v_id),
    'FIN_MANUAL_JOURNAL_SELF_APPROVAL',
    '§3 approving your own journal');
  reset role;

  insert into pg_temp.ids(k, v) values ('journal', v_id);
  raise notice 'PASS: §3 the person who wrote the journal cannot approve it';
end $$;

-- ---------------------------------------------------------------------
-- §4 a control account needs a subledger reference that resolves
-- ---------------------------------------------------------------------
do $$
declare v_item uuid;
<<<<<<< ours
=======
  -- fin_open_items identifies a party balance by (source_type, source_id), so the line must
  -- name the ITEM'S source_id, not the item's own id. Passing v_item failed with 'no open item
  -- of that type and id exists' -- correctly: the reference really did not resolve.
  v_src uuid := gen_random_uuid();
>>>>>>> theirs
begin
  perform pg_temp.jwt(pg_temp.id('maker'));
  set local role authenticated;

  -- (a) no reference at all
  perform pg_temp.expect_error(
    format($q$select public.fin_create_manual_journal(current_date, 'clear a client balance by hand', 'NOTE-1', %L::jsonb)$q$,
      jsonb_build_array(
        jsonb_build_object('gl_account_id', pg_temp.id('exp'), 'debit', 100000),
        jsonb_build_object('gl_account_id', pg_temp.id('ar'),  'credit', 100000))),
    'FIN_MANUAL_JOURNAL_CONTROL',
    '§4 a manual line on AR control with no subledger reference');

<<<<<<< ours
=======
  -- The refusal above carries errcode 42501 (a privilege class, chosen so the same sentence
  -- reaches an ordinary user), and a caught 42501 does not roll back the statements before it:
  -- it aborts the surrounding block. Each of the three cases below therefore gets its own
  -- subtransaction, so one correct refusal cannot stop the next case from being tested.
  begin
>>>>>>> theirs
  -- (b) a reference that does not resolve
  perform pg_temp.expect_error(
    format($q$select public.fin_create_manual_journal(current_date, 'clear a client balance by hand', 'NOTE-2', %L::jsonb)$q$,
      jsonb_build_array(
        jsonb_build_object('gl_account_id', pg_temp.id('exp'), 'debit', 100000),
        jsonb_build_object('gl_account_id', pg_temp.id('ar'),  'credit', 100000,
                           'subledger_source_type', 'receivable_invoice',
                           'subledger_source_id', gen_random_uuid()))),
    'FIN_MANUAL_JOURNAL_CONTROL',
    '§4 a subledger reference that names an item that does not exist');
<<<<<<< ours
=======
  exception when others then
    -- Re-raised: a FAIL inside this subtransaction must still fail the test.
    raise;
  end;
>>>>>>> theirs
  reset role;

  -- (c) with a real open item behind it, the same entry is allowed -- the rule is a
  -- requirement for evidence, not a ban on the account.
  insert into fin_open_items
    (tenant_id, party_account_id, control_role, side, source_type, source_id,
     document_no, document_date, due_date, amount, currency, fx_rate,
     accounting_policy_version, description)
  values
    (pg_temp.id('tenant'), pg_temp.id('party'), 'ar_control', 'receivable',
<<<<<<< ours
     'manual', gen_random_uuid(), 'MJ-AR-1', current_date, current_date,
=======
     'manual', v_src, 'MJ-AR-1', current_date, current_date,
>>>>>>> theirs
     100000, 'UGX', 1, 1, 'balance to be cleared by manual journal')
  returning id into v_item;

  perform pg_temp.jwt(pg_temp.id('maker'));
  set local role authenticated;
  perform public.fin_create_manual_journal(
    current_date, 'clear the client balance agreed with them in writing', 'SETTLE-LETTER-9',
    jsonb_build_array(
      jsonb_build_object('gl_account_id', pg_temp.id('exp'), 'debit', 100000),
      jsonb_build_object('gl_account_id', pg_temp.id('ar'),  'credit', 100000,
                         'subledger_source_type', 'manual',
<<<<<<< ours
                         'subledger_source_id', v_item)));
=======
                         'subledger_source_id', v_src)));
>>>>>>> theirs
  reset role;
  raise notice 'PASS: §4 a control-account line needs a reference, and a real one is accepted';
end $$;

-- ---------------------------------------------------------------------
-- §5 approval is what posts, in the same transaction
-- ---------------------------------------------------------------------
do $$
declare v_id uuid := (select v from pg_temp.ids where k = 'journal');
        v_row public.fin_manual_journals%rowtype;
        v_lines integer; v_je_source text; v_dr numeric; v_cr numeric;
begin
  -- Before approval: nothing on the ledger.
  perform pg_temp.assert(not exists (select 1 from journal_entries
                                      where tenant_id = pg_temp.id('tenant')
                                        and source_type = 'manual'),
    '§5 a submitted journal must not have posted anything yet');

  perform pg_temp.jwt(pg_temp.id('checker'));
  set local role authenticated;
  v_row := public.fin_decide_manual_journal(v_id, 'approve', 'agreed to the insurer statement');
  reset role;

  perform pg_temp.assert(v_row.status = 'posted', '§5 approval should post, got ' || coalesce(v_row.status, '(none)'));
  perform pg_temp.assert(v_row.journal_entry_id is not null, '§5 the journal must be linked to its ledger entry');
  perform pg_temp.assert(v_row.journal_no is not null, '§5 a posted journal needs a number');

  select count(*), min(source_type) into v_lines, v_je_source
    from journal_entries where id = v_row.journal_entry_id and tenant_id = pg_temp.id('tenant');
  perform pg_temp.assert(v_lines = 1, '§5 exactly one ledger entry should exist');
  perform pg_temp.assert(v_je_source = 'manual',
    '§5 the ledger entry must carry source_type manual so existing reports find it, got ' || coalesce(v_je_source, '(none)'));

  select sum(debit), sum(credit) into v_dr, v_cr
    from journal_entry_lines where journal_entry_id = v_row.journal_entry_id;
  perform pg_temp.assert(v_dr = 500000 and v_cr = 500000,
    format('§5 the ledger should carry 500,000 each side, got %s / %s', v_dr, v_cr));
  raise notice 'PASS: §5 a second person''s approval posts the entry to the real ledger in one step';
end $$;

-- ---------------------------------------------------------------------
-- §6 a posted journal cannot be edited, and neither can its lines
-- ---------------------------------------------------------------------
do $$
declare v_id uuid := (select v from pg_temp.ids where k = 'journal');
begin
  perform pg_temp.jwt(pg_temp.id('checker'));
  set local role authenticated;
  perform pg_temp.expect_error(
    format($q$select public.fin_withdraw_manual_journal(%L, 'changing my mind')$q$, v_id),
    'FIN_MANUAL_JOURNAL_STATE',
    '§6 withdrawing a posted journal');
  reset role;

  -- And the lines are frozen the moment the journal leaves draft, which is stricter
  -- than "after posting": nobody can rewrite the figures between approval and posting.
  -- Asserted, not merely attempted -- a bare UPDATE that succeeded would otherwise pass
  -- silently.
  perform pg_temp.expect_error(
    format($q$update fin_manual_journal_lines set debit = 999999, credit = 0 where journal_id = %L and debit > 0$q$,
      pg_temp.id('journal')),
    'FIN_MANUAL_JOURNAL_LINE',
    '§6 rewriting the lines of a posted journal');

  perform pg_temp.expect_error(
    format($q$update fin_manual_journals set total_debit = 1 where id = %L$q$, pg_temp.id('journal')),
    'FIN_MANUAL_JOURNAL_IMMUTABLE',
    '§6 editing a posted journal');
  raise notice 'PASS: §6 posted journals cannot be withdrawn or edited, and lines freeze at submission';
end $$;

-- ---------------------------------------------------------------------
-- §7 a non-finance user cannot write one, and a rejected journal posts nothing
-- ---------------------------------------------------------------------
do $$
declare v_id uuid;
begin
  perform pg_temp.jwt(pg_temp.id('outsider'));
  set local role authenticated;
  perform pg_temp.expect_error(
    format($q$select public.fin_create_manual_journal(current_date, 'trying it on', 'NOTE-3', %L::jsonb)$q$,
      jsonb_build_array(
        jsonb_build_object('gl_account_id', pg_temp.id('exp'), 'debit', 1000),
        jsonb_build_object('gl_account_id', pg_temp.id('rev'), 'credit', 1000))),
    'FIN_MANUAL_JOURNAL_FORBIDDEN',
    '§7 a user outside finance writing a journal');
  reset role;

  perform pg_temp.jwt(pg_temp.id('maker'));
  set local role authenticated;
  v_id := (public.fin_create_manual_journal(
             current_date, 'credit an amount the client disputes', 'DISPUTE-7',
             jsonb_build_array(
               jsonb_build_object('gl_account_id', pg_temp.id('exp'), 'debit', 250000),
               jsonb_build_object('gl_account_id', pg_temp.id('rev'), 'credit', 250000)))).id;
  perform public.fin_submit_manual_journal(v_id);
  reset role;

  perform pg_temp.jwt(pg_temp.id('checker'));
  set local role authenticated;
  perform public.fin_decide_manual_journal(v_id, 'reject', 'no supporting correspondence on file');
  reset role;

  perform pg_temp.assert(
    (select status = 'rejected' and journal_entry_id is null
       from fin_manual_journals where id = v_id),
    '§7 a rejected journal must stay unposted');
  raise notice 'PASS: §7 finance-only, and a rejection leaves the ledger untouched';
end $$;

<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
=======
=======
>>>>>>> theirs
-- ---------------------------------------------------------------------
-- §6 an amount limit, when the company configures one (pack 10.2 / 11)
-- ---------------------------------------------------------------------
-- Section 11 asks for approval limits by amount. This proves the routing half -- that an amount
-- routes to the level the company configured, and that a company which configures nothing keeps
-- its single-checker behaviour. Since 20261124011700 the routed journal can actually be
-- approved through its levels; the chain itself is proved in
-- test_fin_manual_journal_chain.sql, and 6c below proves only that this file's company still
-- works end to end.
<<<<<<< ours
=======
-- ---------------------------------------------------------------------
-- §6 an amount limit, when the company configures one (pack 10.2 / 11)
-- ---------------------------------------------------------------------
<<<<<<< ours
-- Section 11 asks for approval limits by amount; B7 built the engine for refunds only, so a
-- very large manual journal still needed exactly one second person. This proves the two
-- halves of the fix and, just as importantly, that a company which configures nothing keeps
-- today's behaviour.
>>>>>>> theirs
=======
=======
-- ---------------------------------------------------------------------
-- §6 an amount limit, when the company configures one (pack 10.2 / 11)
-- ---------------------------------------------------------------------
>>>>>>> theirs
-- Section 11 asks for approval limits by amount. This proves the routing half -- that an amount
-- routes to the level the company configured, and that a company which configures nothing keeps
-- its single-checker behaviour. Since 20261124011700 the routed journal can actually be
-- approved through its levels; the chain itself is proved in
-- test_fin_manual_journal_chain.sql, and 6c below proves only that this file's company still
-- works end to end.
<<<<<<< ours
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
do $$
declare
  v_id uuid;
  v_lvl record;
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
  v_row record;
=======
>>>>>>> theirs
=======
  v_row record;
>>>>>>> theirs
=======
  v_row record;
>>>>>>> theirs
=======
  v_row record;
>>>>>>> theirs
begin
  -- 6a. No configuration means no extra level. This is the default, and it must not change.
  select * into v_lvl from public.platform_approval_required_level(
    pg_temp.id('tenant'), 100000000, 'manual_journals');
  perform pg_temp.assert(v_lvl.stage_id is null,
    '§6 an unconfigured company must not acquire a manual-journal limit by accident');

  -- A refund, by contrast, still falls back to the minimum control (Appendix B Q2).
  select * into v_lvl from public.platform_approval_required_level(
    pg_temp.id('tenant'), 1, 'insurance_refunds');
  perform pg_temp.assert(v_lvl.stage_id is null and v_lvl.approver_role = 'finance',
    '§6 the refund default must survive the engine being generalised');

<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
=======
>>>>>>> theirs
  -- 6b. Configure a two-level chain for manual journals only. Level 1 is the ordinary finance
  -- check; level 2 is reached above 50,000,000.
  insert into workflow_stages (tenant_id, name, sequence_order, approver_role, threshold_amount, applies_to, is_active)
    values (pg_temp.id('tenant'), 'Manual journal level 1', 1, 'finance', 0, 'manual_journals', true),
           (pg_temp.id('tenant'), 'Manual journal level 2', 2, 'admin', 50000000, 'manual_journals', true);
<<<<<<< ours
=======
  -- 6b. Configure a level-2 threshold for manual journals only.
  insert into workflow_stages (tenant_id, name, sequence_order, approver_role, threshold_amount, applies_to, is_active)
    values (pg_temp.id('tenant'), 'Manual journal level 2', 2, 'admin', 50000000, 'manual_journals', true);
>>>>>>> theirs
=======
=======
>>>>>>> theirs
  -- 6b. Configure a two-level chain for manual journals only. Level 1 is the ordinary finance
  -- check; level 2 is reached above 50,000,000.
  insert into workflow_stages (tenant_id, name, sequence_order, approver_role, threshold_amount, applies_to, is_active)
    values (pg_temp.id('tenant'), 'Manual journal level 1', 1, 'finance', 0, 'manual_journals', true),
           (pg_temp.id('tenant'), 'Manual journal level 2', 2, 'admin', 50000000, 'manual_journals', true);
<<<<<<< ours
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs

  select * into v_lvl from public.platform_approval_required_level(
    pg_temp.id('tenant'), 60000000, 'manual_journals');
  perform pg_temp.assert(v_lvl.level = 2,
    format('§6 a 60,000,000 journal must route to level 2, got level %s', coalesce(v_lvl.level::text, 'none')));

  select * into v_lvl from public.platform_approval_required_level(
    pg_temp.id('tenant'), 40000000, 'manual_journals');
  perform pg_temp.assert(v_lvl.stage_id is null or v_lvl.level < 2,
    '§6 a 40,000,000 journal must stay below the configured threshold');

<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
  -- 6c. A journal routed to level 2 can now be submitted, and one signature does not post it.
  --
  -- This section used to assert the opposite: that submission was REFUSED with
  -- FIN_MANUAL_JOURNAL_LEVEL, because multi-level approval was not built and approving such a
  -- journal at level 1 would have let it through on one signature. That refusal was the honest
  -- failure and it was still a wall. 20261124011700 builds the chain, so the assertion moves
  -- from "you may not submit it" to "you may not post it on one signature", which is the
  -- behaviour the pack actually asks for. The full chain is proved in
  -- test_fin_manual_journal_chain.sql; what belongs here is that this file's company keeps
  -- working and that the old refusal is gone on purpose rather than by accident.
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
=======
  -- 6c. And such a journal cannot be submitted: multi-level approval is not built, so
  -- approving it at level 1 would let it through on one signature.
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
  perform pg_temp.jwt(pg_temp.id('maker'));
  set local role authenticated;
  v_id := (public.fin_create_manual_journal(
             current_date, 'accrue the annual audit fee', 'INV-AUD-BIG',
             jsonb_build_array(
               jsonb_build_object('gl_account_id', pg_temp.id('exp'), 'debit', 60000000, 'description', 'audit fee'),
<<<<<<< ours
               jsonb_build_object('gl_account_id', pg_temp.id('ap'),  'credit', 60000000, 'description', 'audit fee payable')))).id;
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
               jsonb_build_object('gl_account_id', pg_temp.id('accr'), 'credit', 60000000, 'description', 'audit fee payable')))).id;
>>>>>>> theirs

  v_row := public.fin_submit_manual_journal(v_id);
  perform pg_temp.assert(v_row.status = 'pending_approval',
    '§6 a journal above a level-2 threshold must now be submittable and wait for approval');
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
  reset role;

  -- One signature at level 1 must not post it.
  perform pg_temp.jwt(pg_temp.id('checker'));
  set local role authenticated;
  v_row := public.fin_decide_manual_journal(v_id, 'approve', 'level one checked to the invoice');
  reset role;
  perform pg_temp.assert(v_row.status = 'pending_approval',
    '§6 level 1 of a level-2 journal must leave it pending, not post it');
  perform pg_temp.assert(v_row.journal_entry_id is null,
    '§6 level 1 of a level-2 journal must not produce a journal entry');
  perform pg_temp.assert(
    (select count(*) from public.journal_entries where source_id = v_id and source_type = 'manual') = 0,
    '§6 nothing may be posted to the ledger until the last level signs');

  raise notice 'PASS: §6 a configured manual-journal limit routes by amount, an unconfigured company is untouched, and a routed journal waits for every level instead of being refused outright';
=======
  perform pg_temp.expect_error(
    format($q$select public.fin_submit_manual_journal(%L)$q$, v_id),
    'FIN_MANUAL_JOURNAL_LEVEL',
    '§6 a journal above a configured level-2 threshold cannot be submitted until multi-level approval exists');
  reset role;

  raise notice 'PASS: §6 a configured manual-journal limit routes by amount, and an unconfigured company is untouched';
>>>>>>> theirs
=======
=======
>>>>>>> theirs
=======
>>>>>>> theirs
  reset role;

  -- One signature at level 1 must not post it.
  perform pg_temp.jwt(pg_temp.id('checker'));
  set local role authenticated;
  v_row := public.fin_decide_manual_journal(v_id, 'approve', 'level one checked to the invoice');
  reset role;
  perform pg_temp.assert(v_row.status = 'pending_approval',
    '§6 level 1 of a level-2 journal must leave it pending, not post it');
  perform pg_temp.assert(v_row.journal_entry_id is null,
    '§6 level 1 of a level-2 journal must not produce a journal entry');
  perform pg_temp.assert(
    (select count(*) from public.journal_entries where source_id = v_id and source_type = 'manual') = 0,
    '§6 nothing may be posted to the ledger until the last level signs');

  raise notice 'PASS: §6 a configured manual-journal limit routes by amount, an unconfigured company is untouched, and a routed journal waits for every level instead of being refused outright';
<<<<<<< ours
<<<<<<< ours
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
end $$;

-- ---------------------------------------------------------------------
-- §7 a per-user ceiling, independent of the stage
-- ---------------------------------------------------------------------
-- Section 11 asks for limits by role as well as amount. A user assigned a maximum cannot
-- sign off above it even when the stage alone would allow it -- the same rule B7 applies to
-- refunds.
do $$
declare
  v_id uuid;
  v_stage uuid;
begin
  select id into v_stage from workflow_stages
   where tenant_id = pg_temp.id('tenant') and applies_to = 'manual_journals' and is_active
   order by sequence_order limit 1;

  insert into approval_assignments (tenant_id, user_id, workflow_stage_id, scope_type, threshold_max)
    values (pg_temp.id('tenant'), pg_temp.id('checker'), v_stage, 'global', 1000000);

  perform pg_temp.assert(
    public.platform_approval_user_limit(pg_temp.id('tenant'), pg_temp.id('checker'), 'manual_journals') = 1000000,
    '§7 the per-user ceiling must be read for the manual_journals chain');

  -- A journal above the checker's own ceiling but below the stage threshold, so only the
  -- per-user limit can refuse it.
  perform pg_temp.jwt(pg_temp.id('maker'));
  set local role authenticated;
  v_id := (public.fin_create_manual_journal(
             current_date, 'accrue the quarterly audit fee', 'INV-AUD-MID',
             jsonb_build_array(
               jsonb_build_object('gl_account_id', pg_temp.id('exp'), 'debit', 5000000, 'description', 'audit fee'),
<<<<<<< ours
               jsonb_build_object('gl_account_id', pg_temp.id('ap'),  'credit', 5000000, 'description', 'audit fee payable')))).id;
=======
               jsonb_build_object('gl_account_id', pg_temp.id('accr'), 'credit', 5000000, 'description', 'audit fee payable')))).id;
>>>>>>> theirs
  perform public.fin_submit_manual_journal(v_id);
  reset role;

  perform pg_temp.jwt(pg_temp.id('checker'));
  set local role authenticated;
  perform pg_temp.expect_error(
    format($q$select public.fin_decide_manual_journal(%L, 'approve', 'looks fine to me')$q$, v_id),
    'FIN_MANUAL_JOURNAL_LIMIT',
    '§7 a checker cannot approve above their own assigned ceiling');
  reset role;

  raise notice 'PASS: §7 the per-user ceiling refuses a signature above it';
end $$;

<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
do $$ begin
  raise notice 'ALL PASS: manual journals cannot be unbalanced, self-approved, or posted to a control account without a resolving subledger reference, and they cannot be edited after posting';
end $$;

rollback;
