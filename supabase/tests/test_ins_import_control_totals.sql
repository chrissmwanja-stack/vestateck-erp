-- Insurance brokerage: control totals are recorded, compared and binding
-- (20261110170000_ins_import_control_totals.sql).
--
-- Covered:
--   C1  the staged sheet reaches ins_import_batches.control_totals, canonically
--       (uppercase currency, "1,000,000" parsed, unrecorded measures absent)
--   C2  reconciliation is per currency: a two-currency batch does not show
--       each currency the other's receipts (the batch-wide scalar defect)
--   C3  recorded and equal -> match true; unrecorded -> control null, match null
--   C4  recorded and different -> match false, and commit is refused
--   C5  a batch with no control totals sheet still commits, and says "not recorded"
--   C6  the uploader cannot approve a difference; another manager can, then commit
--   C7  an approval is bound to the numbers it approved: move a total and the
--       commit is refused again
--   C8  approving when nothing differs, or without a reason, is refused
--   C9  access: members can read the reconciliation, cannot approve; another
--       tenant sees nothing
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

-- One reconciliation cell as "imported|control|match", with nulls spelled out.
create function pg_temp.recon(p_batch uuid, p_currency text, p_measure text) returns text
language sql stable as $$
  select format('%s|%s|%s', trim_scale(r.imported_amount),
                coalesce(trim_scale(r.control_amount)::text, 'null'),
                coalesce(r.match::text, 'null'))
    from public.ins_import_reconciliation(p_batch) r
   where r.currency = p_currency and r.measure = p_measure;
$$;

create function pg_temp.totals(p_batch uuid) returns jsonb
language sql stable as $$
  select control_totals from ins_import_batches where id = p_batch and tenant_id = get_my_tenant_id();
$$;

---------------------------------------------------------------------
-- Fixtures (as the table owner)
---------------------------------------------------------------------
create temp table pg_temp.c_ids as
select gen_random_uuid() as ta, gen_random_uuid() as tb,
       gen_random_uuid() as mgr, gen_random_uuid() as mgr2,
       gen_random_uuid() as mem, gen_random_uuid() as mgr_b;

insert into tenants (id, name)
select ta, 'Control Brokerage A' from pg_temp.c_ids
union all select tb, 'Control Brokerage B' from pg_temp.c_ids;

insert into auth.users (instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token)
select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
  'ctl-' || u.id || '@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
  now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
from (select mgr as id from pg_temp.c_ids union all select mgr2 from pg_temp.c_ids
      union all select mem from pg_temp.c_ids union all select mgr_b from pg_temp.c_ids) u;

insert into app_users (id, tenant_id, name, email, is_company_admin)
select i.mgr, i.ta, 'Control Manager A', 'ctl-' || i.mgr || '@test.local', false from pg_temp.c_ids i
union all select i.mgr2, i.ta, 'Control Reviewer A', 'ctl-' || i.mgr2 || '@test.local', true from pg_temp.c_ids i
union all select i.mem, i.ta, 'Control Member A', 'ctl-' || i.mem || '@test.local', false from pg_temp.c_ids i
union all select i.mgr_b, i.tb, 'Control Manager B', 'ctl-' || i.mgr_b || '@test.local', false from pg_temp.c_ids i;

insert into tenant_modules (tenant_id, module)
select ta, 'insurance' from pg_temp.c_ids union all select tb, 'insurance' from pg_temp.c_ids;

insert into staff_roles (tenant_id, user_id, module, role)
select ta, mgr, 'insurance', 'manager' from pg_temp.c_ids
union all select ta, mgr2, 'insurance', 'manager' from pg_temp.c_ids
union all select ta, mem, 'insurance', 'member' from pg_temp.c_ids
union all select tb, mgr_b, 'insurance', 'manager' from pg_temp.c_ids;

select set_config('ins.via_rpc', 'on', true);
create temp table pg_temp.c_master as
with i1 as (insert into ins_insurers (tenant_id, code, name, is_active)
            select ta, 'CTLINS1', 'Control Insurer One', true from pg_temp.c_ids returning id),
     pl as (insert into ins_product_lines (tenant_id, code, name, class, is_active)
            select ta, 'GEN', 'General', 'general', true from pg_temp.c_ids returning id),
     bd as (insert into bd_clients (tenant_id, name)
            select ta, 'Control Client' from pg_temp.c_ids returning id, tenant_id),
     cl as (insert into ins_clients (tenant_id, client_id, client_type, kyc_status)
            select tenant_id, id, 'corporate', 'verified' from bd returning id)
select i1.id as insurer1, pl.id as product_line_id, cl.id as client_id from i1, pl, cl;
select set_config('ins.via_rpc', 'off', true);

-- Approved USD rate at the cut-over date: validation refuses a foreign-currency
-- policy without one (FX_RATE_MISSING), and the cut-over is today.
select set_config('reg.via_rpc', 'on', true);
select set_config('fx.via_rpc', 'on', true);
do $$
declare r uuid; f uuid; ta uuid; approver uuid;
begin
  select c.ta, c.mgr2 into ta, approver from pg_temp.c_ids c;
  insert into regulatory_parameters
    (tenant_id, parameter_key, value_num, effective_from, source_ref)
  values (ta, 'fx.rate_max_age_days', 90, date '2000-01-01', 'UNVERIFIED: test fixture')
  returning id into r;
  update regulatory_parameters set status = 'approved', approved_by = approver, approved_at = now()
   where id = r;

  insert into fx_rates (tenant_id, currency, rate_date, rate, source)
  values (ta, 'USD', current_date, 3800, 'fixture') returning id into f;
  update fx_rates set status = 'approved', approved_by = approver, approved_at = now()
   where id = f;
end $$;
select set_config('reg.via_rpc', 'off', true);
select set_config('fx.via_rpc', 'off', true);

---------------------------------------------------------------------
-- Scenarios
---------------------------------------------------------------------
do $$
declare
  o    pg_temp.c_ids;
  b1   uuid; b2   uuid; b3   uuid; b4   uuid; b5   uuid; b6   uuid;
  r    jsonb;
  n    integer;
begin
  select * into o from pg_temp.c_ids;
  perform pg_temp.jwt(o.mgr);

  -------------------------------------------------------------------
  -- C1 + C2 + C3. Totals recorded, compared per currency, matched
  -------------------------------------------------------------------
  select id into b1 from public.ins_import_create_batch('C1 recorded totals', current_date);
  perform public.ins_import_stage_rows(b1, 'policies', $j$[
    {"legacy_policy_no":"C1-UGX","client_name":"Control Client","insurer":"CTLINS1","product_line":"GEN",
     "inception_date":"2026-01-01","expiry_date":"2026-12-31","currency":"UGX",
     "gross_premium":"1000000","commission_rate_pct":"10"},
    {"legacy_policy_no":"C1-USD","client_name":"Control Client","insurer":"CTLINS1","product_line":"GEN",
     "inception_date":"2026-01-01","expiry_date":"2026-12-31","currency":"USD",
     "gross_premium":"10000","commission_rate_pct":"10"}]$j$::jsonb);
  perform public.ins_import_stage_rows(b1, 'receipts', $j$[
    {"legacy_policy_no":"C1-UGX","receipt_date":"2026-02-01","reference":"CU","amount":"100"},
    {"legacy_policy_no":"C1-USD","receipt_date":"2026-02-01","reference":"CD","amount":"50"}]$j$::jsonb);
  perform public.ins_import_stage_rows(b1, 'control_totals', $j$[
    {"currency":"ugx","policy_count":"1","gross_premium":"1,000,000","commission":"100000","receipts":"100"},
    {"currency":"USD","policy_count":"1","gross_premium":"10,000","commission":"1000","receipts":"50"}]$j$::jsonb);

  -- C1: before validation the rows are not valid, so nothing is claimed yet
  perform pg_temp.assert(pg_temp.totals(b1) = '[]'::jsonb,
    'C1 unvalidated control rows are not treated as totals');

  r := public.ins_import_validate_batch(b1);
  perform pg_temp.assert((r ->> 'error_count')::int = 0, 'C1 batch validates: ' || r::text);

  perform pg_temp.assert(jsonb_array_length(pg_temp.totals(b1)) = 2,
    'C1 both currencies reach the batch: ' || pg_temp.totals(b1)::text);
  perform pg_temp.assert((select e.obj ->> 'currency' from jsonb_array_elements(pg_temp.totals(b1)) as e(obj)
                           where e.obj ->> 'currency' = 'UGX') = 'UGX',
    'C1 the currency is canonicalised to upper case');
  perform pg_temp.assert((select (e.obj ->> 'gross_premium')::numeric from jsonb_array_elements(pg_temp.totals(b1)) as e(obj)
                           where e.obj ->> 'currency' = 'UGX') = 1000000,
    'C1 thousands separators are parsed: ' || pg_temp.totals(b1)::text);
  perform pg_temp.assert((select (e.obj ->> 'policy_count')::numeric from jsonb_array_elements(pg_temp.totals(b1)) as e(obj)
                           where e.obj ->> 'currency' = 'UGX') = 1,
    'C1 the policy count is kept');
  perform pg_temp.assert(not exists (select 1 from jsonb_array_elements(pg_temp.totals(b1)) as e(obj)
                                      where e.obj ? 'receivables'),
    'C1 a measure the sheet did not supply is absent, not zero');
  perform pg_temp.assert((select control_totals_synced_at from ins_import_batches where id = b1) is not null,
    'C1 the sync is stamped');

  perform public.ins_import_commit_policies(b1);

  -- C2: per currency, not batch-wide
  perform pg_temp.assert(pg_temp.recon(b1, 'UGX', 'receipts_to_date') = '100|100|true',
    'C2 UGX receipts compare against UGX control only: ' || pg_temp.recon(b1, 'UGX', 'receipts_to_date'));
  perform pg_temp.assert(pg_temp.recon(b1, 'USD', 'receipts_to_date') = '50|50|true',
    'C2 USD receipts compare against USD control only: ' || pg_temp.recon(b1, 'USD', 'receipts_to_date'));

  -- C3: matched measures say true, unrecorded ones say nothing
  perform pg_temp.assert(pg_temp.recon(b1, 'UGX', 'gross_premium') = '1000000|1000000|true',
    'C3 gross premium matches');
  perform pg_temp.assert(pg_temp.recon(b1, 'USD', 'commission') = '1000|1000|true',
    'C3 commission matches');
  perform pg_temp.assert(pg_temp.recon(b1, 'UGX', 'remittances_to_date') = '0|null|null',
    'C3 an unrecorded measure reports null, not a false difference');
  raise notice 'PASS: C1-C3 totals are recorded, canonical, per-currency and matched';

  -------------------------------------------------------------------
  -- C4. A recorded difference stops the commit
  -------------------------------------------------------------------
  select id into b2 from public.ins_import_create_batch('C4 mismatch', current_date);
  perform public.ins_import_stage_rows(b2, 'policies', $j$[
    {"legacy_policy_no":"C4-P1","client_name":"Control Client","insurer":"CTLINS1","product_line":"GEN",
     "inception_date":"2026-01-01","expiry_date":"2026-12-31","currency":"UGX",
     "gross_premium":"1000","commission_rate_pct":"10"}]$j$::jsonb);
  perform public.ins_import_stage_rows(b2, 'control_totals', $j$[
    {"currency":"UGX","gross_premium":"1250","commission":"100"}]$j$::jsonb);
  perform public.ins_import_validate_batch(b2);

  perform pg_temp.assert(pg_temp.recon(b2, 'UGX', 'gross_premium') = '1000|1250|false',
    'C4 the difference is reported: ' || pg_temp.recon(b2, 'UGX', 'gross_premium'));

  perform pg_temp.expect_error(format('select public.ins_import_commit_policies(%L)', b2),
    'INS_IMPORT_CONTROL_MISMATCH', 'C4 a recorded difference blocks commit');
  perform pg_temp.assert((select status from ins_import_batches where id = b2) = 'validated',
    'C4 the refused batch stays validated');
  perform pg_temp.assert(not exists (select 1 from ins_policies where import_batch_id = b2),
    'C4 the refused commit created no policies');
  raise notice 'PASS: C4 a recorded difference is reported and blocks the commit';

  -------------------------------------------------------------------
  -- C5. No sheet at all: commit is allowed, and reconciliation says so
  -------------------------------------------------------------------
  select id into b3 from public.ins_import_create_batch('C5 no totals', current_date);
  perform public.ins_import_stage_rows(b3, 'policies', $j$[
    {"legacy_policy_no":"C5-P1","client_name":"Control Client","insurer":"CTLINS1","product_line":"GEN",
     "inception_date":"2026-01-01","expiry_date":"2026-12-31","currency":"UGX",
     "gross_premium":"500","commission_rate_pct":"10"}]$j$::jsonb);
  perform public.ins_import_validate_batch(b3);
  perform public.ins_import_commit_policies(b3);
  perform pg_temp.assert((select status from ins_import_batches where id = b3) = 'committed',
    'C5 a batch without control totals still commits');
  perform pg_temp.assert(pg_temp.recon(b3, 'UGX', 'gross_premium') = '500|null|null',
    'C5 and the report says "not recorded" rather than "DIFF"');
  raise notice 'PASS: C5 totals are optional, and optional is not the same as ignored';

  -------------------------------------------------------------------
  -- C6. The difference is approved by someone other than the uploader
  -------------------------------------------------------------------
  perform pg_temp.expect_error(
    format($q$select public.ins_import_override_control_totals(%L, 'I checked the ledger myself')$q$, b2),
    'INS_IMPORT_CONTROL_OVERRIDE_SELF', 'C6 the uploader cannot approve their own difference');

  perform pg_temp.jwt(o.mgr2);
  r := public.ins_import_override_control_totals(b2, 'Legacy ledger shows 1,250: two policies were merged into one row');
  perform pg_temp.assert(jsonb_array_length(r -> 'approved_differences') = 1
                         and (r -> 'approved_differences' -> 0 ->> 'measure') = 'gross_premium',
    'C6 approving records the difference it approved: ' || r::text);
  perform pg_temp.assert((select control_override_by from ins_import_batches where id = b2) = o.mgr2,
    'C6 the approver is recorded');
  perform public.ins_import_commit_policies(b2);
  perform pg_temp.assert((select status from ins_import_batches where id = b2) = 'committed',
    'C6 the approved batch commits');
  raise notice 'PASS: C6 an approved difference unblocks the commit, and only a second person can approve';

  -------------------------------------------------------------------
  -- C7. The approval is bound to the numbers it approved
  -------------------------------------------------------------------
  perform pg_temp.jwt(o.mgr);   -- back to the uploader after C6 approved as the reviewer
  select id into b4 from public.ins_import_create_batch('C7 approval drift', current_date);
  perform public.ins_import_stage_rows(b4, 'policies', $j$[
    {"legacy_policy_no":"C7-P1","client_name":"Control Client","insurer":"CTLINS1","product_line":"GEN",
     "inception_date":"2026-01-01","expiry_date":"2026-12-31","currency":"UGX",
     "gross_premium":"1000","commission_rate_pct":"10"}]$j$::jsonb);
  perform public.ins_import_stage_rows(b4, 'control_totals', $j$[
    {"currency":"UGX","gross_premium":"1250","commission":"100"}]$j$::jsonb);
  perform public.ins_import_validate_batch(b4);
  perform pg_temp.jwt(o.mgr2);
  perform public.ins_import_override_control_totals(b4, 'Ledger total includes a cancelled policy');
  perform pg_temp.jwt(o.mgr);

  -- the sheet is corrected to a different (still different) set of numbers
  perform public.ins_import_stage_rows(b4, 'control_totals', $j$[
    {"currency":"UGX","gross_premium":"9000","commission":"100"}]$j$::jsonb, true);
  perform public.ins_import_validate_batch(b4);
  perform pg_temp.assert(pg_temp.recon(b4, 'UGX', 'gross_premium') = '1000|9000|false',
    'C7 the corrected sheet is a new difference');
  perform pg_temp.expect_error(format('select public.ins_import_commit_policies(%L)', b4),
    'INS_IMPORT_CONTROL_MISMATCH', 'C7 a stale approval does not carry over to new numbers');
  raise notice 'PASS: C7 an approval covers the numbers it saw, not whatever comes next';

  -------------------------------------------------------------------
  -- C8. Nothing to approve, or no reason
  -------------------------------------------------------------------
  select id into b5 from public.ins_import_create_batch('C8 nothing to approve', current_date);
  perform public.ins_import_stage_rows(b5, 'policies', $j$[
    {"legacy_policy_no":"C8-P1","client_name":"Control Client","insurer":"CTLINS1","product_line":"GEN",
     "inception_date":"2026-01-01","expiry_date":"2026-12-31","currency":"UGX",
     "gross_premium":"800","commission_rate_pct":"10"}]$j$::jsonb);
  perform public.ins_import_stage_rows(b5, 'control_totals', $j$[
    {"currency":"UGX","gross_premium":"800","commission":"80"}]$j$::jsonb);
  perform public.ins_import_validate_batch(b5);
  perform pg_temp.jwt(o.mgr2);   -- a different manager, so the self-check does not mask the answer
  perform pg_temp.expect_error(
    format($q$select public.ins_import_override_control_totals(%L, 'nothing to see here')$q$, b5),
    'INS_IMPORT_CONTROL_NO_DIFFERENCE', 'C8 approving a batch that already matches');
  perform pg_temp.jwt(o.mgr);

  select id into b6 from public.ins_import_create_batch('C8 short reason', current_date);
  perform public.ins_import_stage_rows(b6, 'policies', $j$[
    {"legacy_policy_no":"C8-P2","client_name":"Control Client","insurer":"CTLINS1","product_line":"GEN",
     "inception_date":"2026-01-01","expiry_date":"2026-12-31","currency":"UGX",
     "gross_premium":"800","commission_rate_pct":"10"}]$j$::jsonb);
  perform public.ins_import_stage_rows(b6, 'control_totals', $j$[
    {"currency":"UGX","gross_premium":"9999"}]$j$::jsonb);
  perform public.ins_import_validate_batch(b6);
  perform pg_temp.expect_error(
    format($q$select public.ins_import_override_control_totals(%L, 'oops')$q$, b6),
    'INS_IMPORT_CONTROL_REASON', 'C8 a one-word reason is not an explanation');
  raise notice 'PASS: C8 there is nothing to approve without a difference, and no approval without a reason';

  -------------------------------------------------------------------
  -- C9. Access
  -------------------------------------------------------------------
  perform pg_temp.jwt(o.mem);
  perform pg_temp.assert((select count(*) from public.ins_import_reconciliation(b1)) = 8,
    'C9 a member can read the reconciliation (2 currencies x 4 measures)');
  perform pg_temp.expect_error(
    format($q$select public.ins_import_override_control_totals(%L, 'member should not approve')$q$, b6),
    'INS_ACCESS_DENIED', 'C9 a member cannot approve a difference');

  perform pg_temp.jwt(o.mgr_b);
  perform pg_temp.expect_error(format('select public.ins_import_reconciliation(%L)', b1),
    'INS_IMPORT_BATCH_NOT_FOUND', 'C9 another tenant cannot reconcile this batch');

  perform pg_temp.jwt(o.mgr);
  raise notice 'PASS: C9 access to totals is insurance-wide read, manager-only write';
end $$;

-- Catalog: the internals stay internal, the three entry points are reachable.
select pg_temp.assert(
  (select count(*) = 0 from information_schema.routine_privileges
   where routine_schema = 'public'
     and routine_name in ('ins_import_sync_control_totals', 'ins_import_control_rows',
                          'ins_import_control_diff', 'ins_import_pick_num')
     and grantee in ('anon', 'authenticated', 'PUBLIC')),
  'the control-total helpers are not executable by clients');
select pg_temp.assert(
  (select count(*) = 2 from information_schema.routine_privileges
   where routine_schema = 'public'
     and routine_name in ('ins_import_reconciliation', 'ins_import_override_control_totals')
     and grantee = 'authenticated' and privilege_type = 'EXECUTE'),
  'reconciliation and approval are executable by managers');

rollback;
