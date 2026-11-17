-- Insurance: per-insurer remittance detail in the in-force import
-- (20261117230000_ins_import_per_insurer_remittances.sql).
--
-- The gap this closes. A co-insured policy's remittances were only ever
-- recorded against the POLICY, so the opening position had to split them
-- between the insurers in proportion to each share's payable (last share taking
-- the rounding remainder -- the approximation IN_FORCE_IMPORT.md step 5 names).
-- Whenever the real money did not move that way, the opening position misstates
-- what is owed to EACH insurer, and misstates the commission earned at
-- cut-over, because a share's commission is earned only when that share is
-- fully remitted.
--
--   	R1  the defect, side by side       -> the same facts recorded both ways: the
--   	                                      policy-level split reports insurer A owed
--   	                                      189 it is not owed; the named history
--   	                                      reports A owed nothing and B owed 270
--   	R2  the share is resolved          -> the row stores the insurer AND its share
--   	R3  all or nothing                 -> named and policy-level history cannot
--   	                                      mix on one policy, refused both ways
--   	R4  the insurer must be on the policy -> and a receipt may not name one
--   	R5  capped per share, not per policy  -> 900 clears a 630 share? no.
--   	R6  a single-insurer policy may name its insurer
--   	R7  six-argument callers untouched   -> the previous signature still records
--   	                                      policy-level history, and the classifier
--   	                                      reads all three states
--
-- Run against a fresh local stack only (`supabase db reset`). One transaction,
-- ROLLBACK at the end; any RAISE EXCEPTION fails the run.

\set ON_ERROR_STOP on

begin;
-- Insurance brokerage: in-force import, step 3 (opening position from history)
-- (20261110120000_ins_import_opening_from_history.sql).
--
-- Covers the nine scenarios the 10 Nov review asks for before a real
-- portfolio is migrated, plus the defects found in the same functions:
--
--   	S1  no receipts, no remittances          -> full receivable, full payable, commission deferred
--   	S2  client partially paid                -> receivable reduced by the receipts
--   	S3  insurer partially remitted           -> payable reduced, commission still deferred
--   	S4  insurer fully paid before cut-over   -> no payable, commission earned (retained earnings, not P&L)
--   	S5  co-insured (two insurers)            -> one payable per share, split by share, both deferred
--   	S6  co-insured, insurer fully paid       -> every share's commission earned, per share
--   	S7  foreign currency + a mixed batch     -> per-currency lines, per-currency clearing, no crash,
--   	                                            items priced from the booking entry
--   	S8  idempotency                          -> history-first ordering posts; a second call is a no-op;
--   	                                            no duplicate journals, items or commission entries
--   	S9  inconsistent history is refused      -> receipts > premium, remittances > net, history after
--   	                                            cut-over, history after posting, wrong tenant, member tier
--
-- Also asserted: the opening entry is exactly one journal per batch carrying
-- every currency; each currency balances on its own so no fx_rounding line is
-- produced; the clearing account holds receipts minus remittances; and
-- receivable + remittances reconcile to the billed premium.
--
-- Run against a fresh local stack only (`supabase db reset`). One
-- transaction, ROLLBACK at the end; any RAISE EXCEPTION fails the run.

\set ON_ERROR_STOP on

begin;

create function pg_temp.expect_error(p_sql text, p_needle text, p_label text)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm like '%' || p_needle || '%' then return; end if;
    raise exception 'FAIL: % raised the wrong error: %', p_label, sqlerrm;
  end;
  raise exception 'FAIL: % succeeded but should have failed with %', p_label, p_needle;
end $$;

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

create function pg_temp.scalar(p_sql text) returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare v text;
begin
  execute p_sql into v;
  return v;
end $$;

-- One journal line amount for a batch, by account code and side.
create function pg_temp.line(p_batch uuid, p_code text, p_side text) returns numeric
language sql stable as $$
  select coalesce(sum(case when p_side = 'D' then l.debit else l.credit end), 0)
    from journal_entries j
    join journal_entry_lines l on l.journal_entry_id = j.id
    join gl_accounts a on a.id = l.gl_account_id
   where j.source_type = 'ins_import_opening' and j.source_id = p_batch
     and a.account_code = p_code;
$$;

create function pg_temp.line_ccy(p_batch uuid, p_code text, p_side text, p_ccy text) returns numeric
language sql stable as $$
  select coalesce(sum(case when p_side = 'D' then l.debit else l.credit end), 0)
    from journal_entries j
    join journal_entry_lines l on l.journal_entry_id = j.id
    join gl_accounts a on a.id = l.gl_account_id
   where j.source_type = 'ins_import_opening' and j.source_id = p_batch
     and a.account_code = p_code and l.currency = p_ccy;
$$;

create function pg_temp.count_code(p_batch uuid, p_code text) returns integer
language sql stable as $$
  select count(*)::int
    from journal_entries j
    join journal_entry_lines l on l.journal_entry_id = j.id
    join gl_accounts a on a.id = l.gl_account_id
   where j.source_type = 'ins_import_opening' and j.source_id = p_batch
     and a.account_code = p_code;
$$;

-- Open-item totals per batch and control role (policy_no is the document no).
create function pg_temp.items(p_batch uuid, p_role text) returns numeric
language sql stable as $$
  select coalesce(sum(i.amount), 0)
    from fin_open_items i
    join ins_policies p on p.policy_no = i.document_no
   where p.import_batch_id = p_batch and i.control_role = p_role;
$$;

create function pg_temp.items_n(p_batch uuid, p_role text) returns integer
language sql stable as $$
  select count(*)::int
    from fin_open_items i
    join ins_policies p on p.policy_no = i.document_no
   where p.import_batch_id = p_batch and i.control_role = p_role;
$$;

create function pg_temp.policy(p_no text) returns uuid
language sql stable as $$
  select id from ins_policies where policy_no = p_no and tenant_id = get_my_tenant_id();
$$;

-- Stage, validate and commit a batch as the signed-in user.
create function pg_temp.make_batch(p_label text, p_policies jsonb, p_shares jsonb default null)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid; v_rep jsonb;
begin
  select id into v_id from public.ins_import_create_batch(p_label, current_date);
  perform public.ins_import_stage_rows(v_id, 'policies', p_policies);
  if p_shares is not null then
    perform public.ins_import_stage_rows(v_id, 'shares', p_shares);
  end if;
  v_rep := public.ins_import_validate_batch(v_id);
  if (v_rep ->> 'error_count')::int <> 0 then
    raise exception 'fixture: batch "%" did not validate: %', p_label, v_rep::text;
  end if;
  perform public.ins_import_commit_policies(v_id);
  return v_id;
end $$;


-- One payable open item, per batch, policy and insurer. The existing items()
-- helper aggregates by control role only; these scenarios need per insurer.
create function pg_temp.payable_to(p_batch uuid, p_policy_no text, p_insurer uuid) returns numeric
language sql stable as $$
  select coalesce(sum(i.amount), 0)
    from fin_open_items i
    join ins_policies p on p.policy_no = i.document_no
    join ins_policy_insurer_shares s on s.id = i.source_id
   where p.import_batch_id = p_batch and p.policy_no = p_policy_no
     and i.control_role = 'insurer_payable' and s.insurer_id = p_insurer;
$$;

---------------------------------------------------------------------
-- Fixtures (as the table owner)
---------------------------------------------------------------------
create temp table pg_temp.o_ids as
select gen_random_uuid() as ta, gen_random_uuid() as tb,
       gen_random_uuid() as mgr, gen_random_uuid() as mem,
       gen_random_uuid() as mgr_b, gen_random_uuid() as adm;

insert into tenants (id, name)
select ta, 'Opening Brokerage A' from pg_temp.o_ids
union all select tb, 'Opening Brokerage B' from pg_temp.o_ids;

insert into auth.users (instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token)
select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
  'impo-' || u.id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
  now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
from (select mgr as id from pg_temp.o_ids union all select mem from pg_temp.o_ids
      union all select mgr_b from pg_temp.o_ids union all select adm from pg_temp.o_ids) u;

insert into app_users (id, tenant_id, name, email, is_company_admin)
select i.mgr, i.ta, 'Opening Manager A', 'impo-' || i.mgr || '@test.local', false from pg_temp.o_ids i
union all select i.mem, i.ta, 'Opening Member A', 'impo-' || i.mem || '@test.local', false from pg_temp.o_ids i
union all select i.adm, i.ta, 'Opening Admin A', 'impo-' || i.adm || '@test.local', true from pg_temp.o_ids i
union all select i.mgr_b, i.tb, 'Opening Manager B', 'impo-' || i.mgr_b || '@test.local', false from pg_temp.o_ids i;

insert into tenant_modules (tenant_id, module)
select ta, 'insurance' from pg_temp.o_ids union all select tb, 'insurance' from pg_temp.o_ids;

insert into staff_roles (tenant_id, user_id, module, role)
select ta, mgr, 'insurance', 'manager' from pg_temp.o_ids
union all select ta, mem, 'insurance', 'member' from pg_temp.o_ids
union all select tb, mgr_b, 'insurance', 'manager' from pg_temp.o_ids;

-- Chart of accounts and the five posting rules the opening position needs.
insert into gl_accounts (tenant_id, account_code, name, account_type, is_control_account)
select i.ta, v.code, v.name, v.type, v.control
from pg_temp.o_ids i,
     (values ('1100', 'Accounts Receivable Control', 'asset', true),
             ('2010', 'Insurer Payable (Premiums)', 'liability', true),
             ('2400', 'Unearned Commission', 'liability', true),
             ('3200', 'Retained Earnings', 'equity', false),
             ('3900', 'Opening Balance Clearing', 'equity', false)) v(code, name, type, control);

insert into gl_posting_rules (tenant_id, account_role, gl_account_id)
select i.ta, v.role, a.id
from pg_temp.o_ids i
cross join (values ('ar_control', '1100'), ('insurer_payable', '2010'),
                   ('unearned_commission', '2400'), ('retained_earnings', '3200'),
                   ('opening_balance_clearing', '3900')) v(role, code)
join gl_accounts a on a.tenant_id = i.ta and a.account_code = v.code;

-- Approved FX rate for today (the cut-over date) and the staleness parameter.
select set_config('reg.via_rpc', 'on', true);
select set_config('fx.via_rpc', 'on', true);
create temp table pg_temp.o_fx as
select (select i.ta from pg_temp.o_ids i) as ta,
       (select i.adm from pg_temp.o_ids i) as approver;
do $$
declare r uuid; f uuid; i pg_temp.o_fx;
begin
  select * into i from pg_temp.o_fx;
  insert into regulatory_parameters
    (tenant_id, parameter_key, value_num, effective_from, source_ref)
  values (i.ta, 'fx.rate_max_age_days', 90, date '2000-01-01', 'UNVERIFIED: test fixture')
  returning id into r;
  update regulatory_parameters set status = 'approved', approved_by = i.approver, approved_at = now()
   where id = r;

  insert into fx_rates (tenant_id, currency, rate_date, rate, source)
  values (i.ta, 'USD', current_date, 3800, 'fixture') returning id into f;
  update fx_rates set status = 'approved', approved_by = i.approver, approved_at = now()
   where id = f;
end $$;
select set_config('reg.via_rpc', 'off', true);
select set_config('fx.via_rpc', 'off', true);

-- Master data: three insurers, two product lines, one client.
select set_config('ins.via_rpc', 'on', true);
create temp table pg_temp.o_master as
with i1 as (insert into ins_insurers (tenant_id, code, name, is_active)
            select ta, 'OPNINS1', 'Opening Insurer One', true from pg_temp.o_ids returning id),
     i2 as (insert into ins_insurers (tenant_id, code, name, is_active)
            select ta, 'OPNINS2', 'Opening Insurer Two', true from pg_temp.o_ids returning id),
     i3 as (insert into ins_insurers (tenant_id, code, name, is_active)
            select ta, 'OPNINS3', 'Opening Insurer Three', true from pg_temp.o_ids returning id),
     pl as (insert into ins_product_lines (tenant_id, code, name, class, is_active)
            select ta, 'GEN', 'General', 'general', true from pg_temp.o_ids returning id),
     bd as (insert into bd_clients (tenant_id, name)
            select ta, 'Opening Client' from pg_temp.o_ids returning id, tenant_id),
     cl as (insert into ins_clients (tenant_id, client_id, client_type, kyc_status)
            select tenant_id, id, 'corporate', 'verified' from bd returning id)
select i1.id as insurer1, i2.id as insurer2, i3.id as insurer3,
       pl.id as product_line_id, cl.id as client_id
  from i1, i2, i3, pl, cl;
select set_config('ins.via_rpc', 'off', true);


-- These scenarios post several opening positions in one company, which a real
-- migration never does (a company cuts over once). The acceptance gate
-- (20261117220000, item #3) allows one opening per company and refuses new
-- binding until it is accepted -- correct for production, and in the way of a
-- test that plays several cut-overs. This shim uses that migration's own
-- reopen API to open the door between scenarios, and is a no-op on a database
-- where the gate has not been applied, so this file runs either way.
create function pg_temp.next_opening(p_reason text) returns void
language plpgsql as $$
declare v_prev uuid;
begin
  if to_regprocedure('public.ins_import_reopen_opening(uuid,text)') is null then
    return;
  end if;
  select j.source_id into v_prev
    from journal_entries j
   where j.tenant_id = get_my_tenant_id() and j.source_type = 'ins_import_opening'
   order by j.created_at desc
   limit 1;
  if v_prev is not null then
    perform public.ins_import_reopen_opening(v_prev, p_reason);
  end if;
end $$;

---------------------------------------------------------------------
-- Scenarios
---------------------------------------------------------------------
-- Every scenario uses a co-insured policy: OPNINS1 at 70%, OPNINS2 at 30%, on
-- a 1000 premium with 10% commission. So the shares are:
--
--    A (70%)  payable 630,  commission 70
--    B (30%)  payable 270,  commission 30
--
-- and the policy's net premium is 900.
do $$
declare
  o     pg_temp.o_ids;
  m     pg_temp.o_master;
  bx    uuid;   -- a policy-level batch
  bn    uuid;   -- a named batch
  pxl   uuid;   -- the policy-level policy
  pnm   uuid;   -- the named policy
  rep   jsonb;
  ins1  uuid;
  ins2  uuid;
  sh1   uuid;
  sh2   uuid;
  nm    text;
  pl_n  integer;
  b3    uuid;
begin
  select * into o from pg_temp.o_ids;
  select * into m from pg_temp.o_master;
  ins1 := m.insurer1;
  ins2 := m.insurer2;
  perform pg_temp.jwt(o.mgr);

  -------------------------------------------------------------------
  -- R1. The defect, side by side: policy-level history versus named
  -------------------------------------------------------------------
  -- Identical facts, recorded the two possible ways: insurer A was paid its
  -- 630 in full, insurer B was paid nothing.
  --
  --   policy-level  -> the opening splits 630 pro rata (441 / 189): BOTH
  --                    insurers look partly paid and BOTH look partly owed.
  --   named         -> A owes nothing, B owes its full 270.
  --
  -- A receivable at cut-over is 1000 from the same client either way, so this
  -- is not a matter of taste: one of the two is simply wrong about who is owed.

  bx := pg_temp.make_batch('R1 policy-level', $j$[
    {"legacy_policy_no":"R1-P1","client_name":"Opening Client","insurer":"OPNINS1","product_line":"GEN",
     "inception_date":"2026-01-01","expiry_date":"2026-12-31","currency":"UGX",
     "gross_premium":"1000","commission_rate_pct":"10"}]$j$::jsonb, $j$[
    {"legacy_policy_no":"R1-P1","insurer":"OPNINS1","share_pct":"70"},
    {"legacy_policy_no":"R1-P1","insurer":"OPNINS2","share_pct":"30"}]$j$::jsonb);
  pxl := pg_temp.policy('R1-P1');
  insert into ins_import_remittances (tenant_id, batch_id, policy_id, remit_date, reference, amount)
  values (o.ta, bx, pxl, current_date - 40, 'REMIT-PL', 630);

  bn := pg_temp.make_batch('R1 named', $j$[
    {"legacy_policy_no":"R1-P2","client_name":"Opening Client","insurer":"OPNINS1","product_line":"GEN",
     "inception_date":"2026-01-01","expiry_date":"2026-12-31","currency":"UGX",
     "gross_premium":"1000","commission_rate_pct":"10"}]$j$::jsonb, $j$[
    {"legacy_policy_no":"R1-P2","insurer":"OPNINS1","share_pct":"70"},
    {"legacy_policy_no":"R1-P2","insurer":"OPNINS2","share_pct":"30"}]$j$::jsonb);
  pnm := pg_temp.policy('R1-P2');
  rep := public.ins_import_record_history(bn, '[]'::jsonb, jsonb_build_array(
    jsonb_build_object('policy_id', pnm, 'remit_date', current_date - 40,
                       'reference', 'REMIT-NAMED', 'amount', 630, 'insurer', 'OPNINS1')));
  perform pg_temp.assert((rep ->> 'remittances_recorded')::int = 1,
    'R1 a remittance naming its insurer is recorded: ' || rep::text);
  perform pg_temp.assert((rep ->> 'remittances_naming_an_insurer')::int = 1,
    'R1 the report counts how many remittances named an insurer');

  perform pg_temp.next_opening('R-scenarios: a separate cut-over for this scenario');

  perform public.ins_import_post_opening_position(bx);
  perform pg_temp.next_opening('R-scenarios: a separate cut-over for this scenario');
  rep := public.ins_import_post_opening_position(bn);

  -- the policy-level batch: the approximation is visible and is wrong per insurer
  perform pg_temp.assert(pg_temp.payable_to(bx, 'R1-P1', ins1) = 189,
    'R1 policy-level: the pro rata split leaves insurer A owed 189 that it is not owed (expected 630-441)');
  perform pg_temp.assert(pg_temp.payable_to(bx, 'R1-P1', ins2) = 81,
    'R1 policy-level: and reports insurer B owed 81 that it is owed (expected 270-189)');
  perform pg_temp.assert(pg_temp.line(bx, '2010', 'C') = 270,
    'R1 policy-level: only 270 of the 900 payable is cleared, though 630 was paid');

  -- the named batch: each insurer's own position
  perform pg_temp.assert(pg_temp.payable_to(bn, 'R1-P2', ins1) = 0,
    'R1 named: insurer A was paid in full, so it is owed nothing');
  perform pg_temp.assert(pg_temp.payable_to(bn, 'R1-P2', ins2) = 270,
    'R1 named: insurer B was paid nothing, so it is owed its whole 270');
  perform pg_temp.assert(pg_temp.line(bn, '2010', 'C') = 270,
    'R1 named: the same total payable, correctly attributed');
  perform pg_temp.assert(pg_temp.items_n(bn, 'insurer_payable') = 1,
    'R1 named: one payable open item, for the insurer actually owed, not one per share');

  -- and the commission follows the insurer, not the average
  perform pg_temp.assert(pg_temp.line(bn, '3200', 'C') = 70,
    'R1 named: insurer A''s 70 commission is earned because its share was fully remitted');
  perform pg_temp.assert(pg_temp.line(bn, '2400', 'C') = 30,
    'R1 named: insurer B''s 30 stays deferred because nothing was remitted to it');
  perform pg_temp.assert(pg_temp.line(bx, '3200', 'C') = 0 and pg_temp.line(bx, '2400', 'C') = 100,
    'R1 policy-level: the split earns nothing, deferring all 100 -- the approximation again');
  raise notice 'PASS: R1 named detail attributes payable and earned commission per insurer';

  -------------------------------------------------------------------
  -- R2. The share reference is resolved and stored with the row
  -------------------------------------------------------------------
  select s.id into sh1 from ins_policy_insurer_shares s
   where s.policy_id = pnm and s.insurer_id = ins1;
  perform pg_temp.assert(sh1 is not null,
    'R2 fixture: the named policy has a share row for insurer A');
  perform pg_temp.assert(
    (select r.insurer_share_id from ins_import_remittances r
      where r.policy_id = pnm) = sh1,
    'R2 the remittance stores the share it belongs to, not just the insurer');
  perform pg_temp.assert(
    (select r.insurer_id from ins_import_remittances r where r.policy_id = pnm) = ins1,
    'R2 and the insurer it was paid to');
  perform pg_temp.assert(
    (select count(*) from ins_import_remittances r
      where r.policy_id = pxl and r.insurer_id is null and r.insurer_share_id is null) = 1,
    'R2 a policy-level remittance still carries no insurer and no share');

  -------------------------------------------------------------------
  -- R3. All or nothing, refused by name in both directions
  -------------------------------------------------------------------
  -- a fresh batch: the policy-level row goes in first, then a named one is
  -- refused for the SAME policy -- the two levels cannot be mixed.
  b3 := pg_temp.make_batch('R3 mixed', $j$[
    {"legacy_policy_no":"R3-P1","client_name":"Opening Client","insurer":"OPNINS1","product_line":"GEN",
     "inception_date":"2026-01-01","expiry_date":"2026-12-31","currency":"UGX",
     "gross_premium":"1000","commission_rate_pct":"10"}]$j$::jsonb, $j$[
    {"legacy_policy_no":"R3-P1","insurer":"OPNINS1","share_pct":"70"},
    {"legacy_policy_no":"R3-P1","insurer":"OPNINS2","share_pct":"30"}]$j$::jsonb);
  perform public.ins_import_record_history(b3, '[]'::jsonb, jsonb_build_array(
    jsonb_build_object('policy_id', pg_temp.policy('R3-P1'), 'remit_date', current_date - 40,
                       'reference', 'PL-FIRST', 'amount', 100)));
  perform pg_temp.expect_error(
    format($q$select public.ins_import_record_history(%L, '[]'::jsonb, %L::jsonb)$q$, b3,
      jsonb_build_array(jsonb_build_object('policy_id', pg_temp.policy('R3-P1'),
        'remit_date', current_date - 30, 'reference', 'NAMED-AFTER', 'amount', 100,
        'insurer', 'OPNINS1'))),
    'INS_IMPORT_REMITTANCE_MIXED',
    'a named remittance on a policy that already has policy-level history');

  -- and the other way round, on its own batch
  b3 := pg_temp.make_batch('R3 mixed reverse', $j$[
    {"legacy_policy_no":"R3-P2","client_name":"Opening Client","insurer":"OPNINS1","product_line":"GEN",
     "inception_date":"2026-01-01","expiry_date":"2026-12-31","currency":"UGX",
     "gross_premium":"1000","commission_rate_pct":"10"}]$j$::jsonb, $j$[
    {"legacy_policy_no":"R3-P2","insurer":"OPNINS1","share_pct":"70"},
    {"legacy_policy_no":"R3-P2","insurer":"OPNINS2","share_pct":"30"}]$j$::jsonb);
  perform public.ins_import_record_history(b3, '[]'::jsonb, jsonb_build_array(
    jsonb_build_object('policy_id', pg_temp.policy('R3-P2'), 'remit_date', current_date - 40,
                       'reference', 'NAMED-FIRST', 'amount', 100, 'insurer', 'OPNINS1')));
  perform pg_temp.expect_error(
    format($q$select public.ins_import_record_history(%L, '[]'::jsonb, %L::jsonb)$q$, b3,
      jsonb_build_array(jsonb_build_object('policy_id', pg_temp.policy('R3-P2'),
        'remit_date', current_date - 30, 'reference', 'PL-AFTER', 'amount', 100))),
    'INS_IMPORT_REMITTANCE_MIXED',
    'a policy-level remittance on a policy whose history already names insurers');

  -------------------------------------------------------------------
  -- R4. A named remittance must name an insurer that is on the policy
  -------------------------------------------------------------------
  b3 := pg_temp.make_batch('R4 wrong insurer', $j$[
    {"legacy_policy_no":"R4-P1","client_name":"Opening Client","insurer":"OPNINS1","product_line":"GEN",
     "inception_date":"2026-01-01","expiry_date":"2026-12-31","currency":"UGX",
     "gross_premium":"1000","commission_rate_pct":"10"}]$j$::jsonb, $j$[
    {"legacy_policy_no":"R4-P1","insurer":"OPNINS1","share_pct":"70"},
    {"legacy_policy_no":"R4-P1","insurer":"OPNINS2","share_pct":"30"}]$j$::jsonb);
  perform pg_temp.expect_error(
    format($q$select public.ins_import_record_history(%L, '[]'::jsonb, %L::jsonb)$q$, b3,
      jsonb_build_array(jsonb_build_object('policy_id', pg_temp.policy('R4-P1'),
        'remit_date', current_date - 30, 'reference', 'NOT-ON-POLICY', 'amount', 100,
        'insurer', 'OPNINS3'))),
    'INS_IMPORT_REMITTANCE_INSURER',
    'a remittance naming an insurer that does not participate in the policy');

  -- and an insurer code the company does not have is refused too, not silently null
  perform pg_temp.expect_error(
    format($q$select public.ins_import_record_history(%L, '[]'::jsonb, %L::jsonb)$q$, b3,
      jsonb_build_array(jsonb_build_object('policy_id', pg_temp.policy('R4-P1'),
        'remit_date', current_date - 30, 'reference', 'NO-SUCH', 'amount', 100,
        'insurer', 'NOSUCHINS'))),
    'INS_IMPORT_REMITTANCE_INSURER',
    'a remittance naming an insurer code the company does not have');

  -- a receipt is client money and cannot name an insurer
  perform pg_temp.expect_error(
    format($q$select public.ins_import_record_history(%L, %L::jsonb, '[]'::jsonb)$q$, b3,
      jsonb_build_array(jsonb_build_object('policy_id', pg_temp.policy('R4-P1'),
        'receipt_date', current_date - 30, 'reference', 'CLIENT-NAMED', 'amount', 100,
        'insurer', 'OPNINS1'))),
    'INS_IMPORT_HISTORY_INSURER',
    'a receipt may not name an insurer');

  -------------------------------------------------------------------
  -- R5. Each insurer is capped by its own share, not by the policy total
  -------------------------------------------------------------------
  -- insurer A's share is 630. 900 against the policy is within the 900 net
  -- premium, so the old policy-level cap would let it through; the named cap
  -- catches it, which is the point of knowing who was paid.
  perform pg_temp.expect_error(
    format($q$select public.ins_import_record_history(%L, '[]'::jsonb, %L::jsonb)$q$, b3,
      jsonb_build_array(jsonb_build_object('policy_id', pg_temp.policy('R4-P1'),
        'remit_date', current_date - 30, 'reference', 'OVER-A', 'amount', 631,
        'insurer', 'OPNINS1'))),
    'INS_IMPORT_REMITTANCES_EXCEED_PAYABLE',
    'a remittance over-remitting one insurer''s own share');

  -- the same insurer can be paid in instalments as long as they fit the share
  rep := public.ins_import_record_history(b3, '[]'::jsonb, jsonb_build_array(
    jsonb_build_object('policy_id', pg_temp.policy('R4-P1'), 'remit_date', current_date - 60,
                       'reference', 'A-1', 'amount', 400, 'insurer', 'OPNINS1'),
    jsonb_build_object('policy_id', pg_temp.policy('R4-P1'), 'remit_date', current_date - 50,
                       'reference', 'A-2', 'amount', 230, 'insurer', 'OPNINS1')));
  perform pg_temp.assert((rep ->> 'remittances_recorded')::int = 2,
    'R5 an insurer paid in two instalments totalling its share is accepted: ' || rep::text);

  -- R4-P1 is now all-named; posting it must clear insurer A completely and
  -- leave insurer B its whole share.
  perform pg_temp.next_opening('R-scenarios: a separate cut-over for this scenario');
  perform public.ins_import_post_opening_position(b3);
  perform pg_temp.assert(pg_temp.payable_to(b3, 'R4-P1', ins1) = 0,
    'R5 the instalments cleared insurer A exactly');
  perform pg_temp.assert(pg_temp.payable_to(b3, 'R4-P1', ins2) = 270,
    'R5 insurer B is untouched by money paid to insurer A');
  perform pg_temp.assert(pg_temp.line(b3, '3200', 'C') = 70,
    'R5 insurer A''s commission is earned on the strength of its own instalments');
  raise notice 'PASS: R5 the cap and the commission are per insurer share';

  -------------------------------------------------------------------
  -- R6. A single-insurer policy may still name its insurer
  -------------------------------------------------------------------
  -- A policy with one insurer records no share row. Naming that insurer is
  -- still allowed and is not a silent no-op: it is the policy's only share.
  b3 := pg_temp.make_batch('R6 single insurer', $j$[
    {"legacy_policy_no":"R6-P1","client_name":"Opening Client","insurer":"OPNINS1","product_line":"GEN",
     "inception_date":"2026-01-01","expiry_date":"2026-12-31","currency":"UGX",
     "gross_premium":"1000","commission_rate_pct":"10"}]$j$::jsonb);
  rep := public.ins_import_record_history(b3, '[]'::jsonb, jsonb_build_array(
    jsonb_build_object('policy_id', pg_temp.policy('R6-P1'), 'remit_date', current_date - 40,
                       'reference', 'SINGLE', 'amount', 900, 'insurer', 'OPNINS1')));
  perform pg_temp.assert((rep ->> 'remittances_recorded')::int = 1,
    'R6 a single-insurer policy may name its insurer: ' || rep::text);
  perform pg_temp.next_opening('R-scenarios: a separate cut-over for this scenario');
  perform public.ins_import_post_opening_position(b3);
  perform pg_temp.assert(pg_temp.line(b3, '2010', 'C') = 0, 'R6 the whole payable is cleared');
  perform pg_temp.assert(pg_temp.line(b3, '3200', 'C') = 100, 'R6 the whole commission is earned');

  -------------------------------------------------------------------
  -- R7. Six-argument callers are untouched
  -------------------------------------------------------------------
  -- ins_import_promote_history and anything else written before this migration
  -- calls history_add with six arguments. It must still work and still record
  -- policy-level history -- silently, not as an error.
  b3 := pg_temp.make_batch('R7 legacy call', $j$[
    {"legacy_policy_no":"R7-P1","client_name":"Opening Client","insurer":"OPNINS1","product_line":"GEN",
     "inception_date":"2026-01-01","expiry_date":"2026-12-31","currency":"UGX",
     "gross_premium":"1000","commission_rate_pct":"10"}]$j$::jsonb);
  nm := public.ins_import_history_add(b3, pg_temp.policy('R7-P1'), 'remittance',
          current_date - 40, 'LEGACY-6ARG', 900::numeric);
  perform pg_temp.assert(nm = 'recorded',
    'R7 the six-argument history writer still records, got ' || coalesce(nm, 'null'));
  perform pg_temp.assert(
    (select count(*) from ins_import_remittances r
      where r.policy_id = pg_temp.policy('R7-P1')
        and r.insurer_id is null and r.insurer_share_id is null) = 1,
    'R7 the six-argument call records policy-level history, with no insurer');
  perform pg_temp.assert(
    public.ins_import_remittance_detail_state(o.ta, b3, pg_temp.policy('R7-P1')) = 'none',
    'R7 and the classifier reads that history as policy-level');

  -- the classifier itself, on the three states
  perform pg_temp.assert(
    public.ins_import_remittance_detail_state(o.ta, bn, pnm) = 'all',
    'R7 an all-named history classifies as all');
  perform pg_temp.assert(
    public.ins_import_remittance_detail_state(o.ta, b3, gen_random_uuid()) = 'none',
    'R7 a policy with no history at all classifies as none');
  raise notice 'PASS: R7 the previous signature and the classifier agree';

  raise notice 'PASS: per-insurer remittance detail (all scenarios)';
end $$;

-- The new columns are one fact, never half of one.
select pg_temp.assert(
  (select count(*) = 1 from pg_constraint
    where conname = 'ins_import_remittances_insurer_pair_chk'
      and conrelid = 'public.ins_import_remittances'::regclass),
  'the insurer / share columns are constrained to be set together');

-- Catalog-level: widening the writer must not widen who may call it. Both
-- signatures stay owner-only -- clients reach remittances through
-- ins_import_record_history, which is where the permission check lives -- and
-- the classifier is internal for the same reason.
select pg_temp.assert(
  (select count(*) = 0 from information_schema.routine_privileges
    where routine_schema = 'public'
      and routine_name in ('ins_import_history_add', 'ins_import_remittance_detail_state')
      and grantee in ('anon', 'authenticated', 'PUBLIC')),
  'both ins_import_history_add signatures and the classifier are owner-only');
select pg_temp.assert(
  (select count(*) = 0 from information_schema.routine_privileges
    where routine_schema = 'public' and routine_name = 'ins_import_record_history'
      and grantee in ('anon', 'PUBLIC')),
  'anon / PUBLIC have no EXECUTE on the history RPC');
select pg_temp.assert(
  (select count(*) = 1 from information_schema.routine_privileges
    where routine_schema = 'public' and routine_name = 'ins_import_record_history'
      and grantee = 'authenticated' and privilege_type = 'EXECUTE'),
  'authenticated still reaches history through ins_import_record_history');

rollback;
