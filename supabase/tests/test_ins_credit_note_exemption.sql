-- Review of the policy reversal's credit-note exemption (analysis §8 item 4).
--
-- The exemption lets the reversal offset a policy's premium and insurer open items
-- against the policy's own commission account, which is a control-flagged account.
-- The review asks three things, and this file tests each one:
--
--   A. The allowlist is narrow. The exempt offset account is not a client input:
--      ins_reverse_policy() takes no account argument, and the offset is derived from
--      the policy's own bind journal (unearned_commission or commission_income only).
--      Ordinary credit notes still reject a control-account offset.
--
--   B. The exemption cannot be reached from a direct client call. The internal helpers
--      and the private credit-note writer are not executable by authenticated or anon.
--      The client cannot write the reversal record that the exemption needs. Setting
--      the transaction flag ins.via_rpc does not open the exemption.
--
--   C. The exemption is limited to a building reversal in the same transaction. That
--      is tested by the existing policy reversal suite (INS_REVERSAL_INTERNAL and
--      INS_REVERSAL_OFFSET); this file only checks that no client path bypasses it.
--
-- Run only on a disposable local/test database; the transaction rolls back.

\set ON_ERROR_STOP on
begin;

create function pg_temp.assert(p_ok boolean, p_msg text)
returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_msg; end if;
end $$;

-- Runs a statement that must fail with the given SQLSTATE.
create function pg_temp.expect_state(p_sql text, p_state text, p_label text)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlstate = p_state then return; end if;
    raise exception 'FAIL: % raised sqlstate % (%), expected %', p_label, sqlstate, sqlerrm, p_state;
  end;
  raise exception 'FAIL: % succeeded but should have failed with sqlstate %', p_label, p_state;
end $$;

create function pg_temp.jwt(p_uid uuid)
returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
$$;

do $$
declare
  ta uuid := gen_random_uuid();
  mgr uuid := gen_random_uuid();
begin
  -- A. Allowlist ---------------------------------------------------------------

  -- A1. The exempt offset is not a client input. The reversal RPC takes a policy, a
  -- reason, a reissue flag and a request id, and nothing else.
  perform pg_temp.assert(not exists(
    select 1 from pg_proc p, unnest(p.proargnames) a
     where p.proname = 'ins_reverse_policy' and p.pronamespace = 'public'::regnamespace
       and a ilike '%offset%'),
    'ins_reverse_policy accepts an offset or account argument; the exempt account must not be client-chosen');

  -- A2. The exemption offset is derived from the policy's bind journal. The current
  -- context is a wrapper: it refuses co-insurance and charge-line policies, and
  -- delegates to the legacy context, which takes the offset only from the two allowed
  -- commission roles. Checked on the source text of the functions as they are now.
  perform pg_temp.assert(exists(
    select 1 from pg_proc p
     where p.proname = 'ins_policy_reversal_context' and p.pronamespace = 'public'::regnamespace
       and p.prosrc like '%INS_REVERSAL_COMPLEX%'
       and p.prosrc like '%platform_ins_policy_reversal_legacy_context%'),
    'ins_policy_reversal_context no longer refuses complex policies before the legacy path');
  perform pg_temp.assert(exists(
    select 1 from pg_proc p
     where p.proname = 'platform_ins_policy_reversal_legacy_context' and p.pronamespace = 'public'::regnamespace
       and p.prosrc like '%get_posting_account(p.tenant_id,''unearned_commission'')%'
       and p.prosrc like '%get_posting_account(p.tenant_id,''commission_income'')%'
       and p.prosrc like '%INS_REVERSAL_HISTORY: historical commission mapping cannot be identified%'),
    'legacy reversal context no longer limits the offset to the two allowed commission roles');

  -- B. Direct client calls -----------------------------------------------------

  -- B1. Internal helpers are not executable by any client role.
  perform pg_temp.assert(not has_function_privilege('authenticated',
    'public.ins_policy_reversal_context(uuid,boolean)', 'execute')
    and not has_function_privilege('anon', 'public.ins_policy_reversal_context(uuid,boolean)', 'execute'),
    'ins_policy_reversal_context is executable by a client role');
  perform pg_temp.assert(not has_function_privilege('authenticated',
    'public.platform_ins_policy_reversal_legacy_context(uuid,boolean)', 'execute')
    and not has_function_privilege('anon',
    'public.platform_ins_policy_reversal_legacy_context(uuid,boolean)', 'execute'),
    'platform_ins_policy_reversal_legacy_context is executable by a client role');
  perform pg_temp.assert(not has_function_privilege('authenticated',
    'public.platform_fin_raise_policy_credit_note_impl(uuid,text,uuid,numeric,date,uuid,jsonb,text,text,uuid)', 'execute')
    and not has_function_privilege('anon',
    'public.platform_fin_raise_policy_credit_note_impl(uuid,text,uuid,numeric,date,uuid,jsonb,text,text,uuid)', 'execute'),
    'platform_fin_raise_policy_credit_note_impl is executable by a client role');

  -- Fixture: a tenant and an insurance manager. No policy, no reversal.
  insert into tenants(id, name) values (ta, 'Exemption review');
  insert into auth.users(id, email, raw_user_meta_data, raw_app_meta_data, aud, role, created_at, updated_at)
    values (mgr, 'exempt-'||mgr||'@test.local', '{}', '{}', 'authenticated', 'authenticated', now(), now());
  insert into app_users(id, tenant_id, name, email)
    values (mgr, ta, 'Exemption manager', 'exempt-'||mgr||'@test.local');
  insert into tenant_modules(tenant_id, module) values (ta, 'insurance');
  insert into staff_roles(tenant_id, user_id, module, role) values (ta, mgr, 'insurance', 'manager');

  -- B2. As the manager, no client path reaches the helper, even with the flag set.
  perform pg_temp.jwt(mgr); set local role authenticated;
  perform set_config('ins.via_rpc', 'on', true);
  perform pg_temp.expect_state(format('select ins_policy_reversal_context(%L, true)', gen_random_uuid()),
    '42501', 'direct call to the reversal context with the in-progress flag');
  perform pg_temp.expect_state(format('select platform_fin_raise_policy_credit_note_impl(%L,''ar_control'',%L,1,current_date,%L,''[]''::jsonb,''x'',null,%L)',
    ta, gen_random_uuid(), gen_random_uuid(), gen_random_uuid()),
    '42501', 'direct call to the private policy credit-note writer');
  perform set_config('ins.via_rpc', 'off', true);

  -- B3. The client cannot write the reversal record the exemption depends on.
  perform pg_temp.expect_state(format('insert into ins_policy_reversals(tenant_id, original_policy_id, outcome, operation_txid, reversed_by) values (%L,%L,''building'',txid_current(),%L)',
    ta, gen_random_uuid(), mgr), '42501', 'client insert of a building reversal row');
  perform pg_temp.expect_state('update ins_policy_reversals set outcome = ''complete''',
    '42501', 'client update of reversal outcome');
  reset role;

  raise notice 'PASS: credit-note exemption review: narrow allowlist, no direct client path, flag cannot open the exemption';
end $$;

rollback;
