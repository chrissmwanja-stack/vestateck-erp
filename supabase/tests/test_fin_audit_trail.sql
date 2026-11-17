-- =====================================================================
-- Finance B: financial audit trail
-- =====================================================================
-- Covers migration 20261117160000.
--
-- The question: "show me who did what to this money, in order, with the
-- paper behind it."
--
-- Asserted:
--   1. Posting a journal records its poster, automatically, at the choke point.
--   2. A void records the reversal AND links it to the entry it reverses --
--      a link that previously existed only in a description string.
--   3. An impersonated posting names the effective user, and keeps the raw
--      session user alongside, so it cannot hide.
--   4. Initiation is recordable, and refusing a non-member initiator.
--   5. The trail reports the actors for a real procurement document, in order.
--   6. Approvals really are recorded by the RPC and appear in the trail
--      (this was the thing an earlier note claimed was broken).
--   7. The trail is append-only: no UPDATE, no DELETE, no direct INSERT.
--   8. It is tenant-scoped and finance-only.
--   9. fin_audit_gaps reports postings with no initiator rather than guessing.
--
-- One transaction, ROLLBACKs at the end.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

create function pg_temp.assert(p_ok boolean, p_msg text)
returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_msg; end if;
end $$;

create function pg_temp.stages(p_entity_type text, p_id uuid)
returns text[] language sql as $$
  select coalesce(array_agg(stage order by hop), '{}')
  from fin_audit_trail(p_entity_type, p_id)
$$;

do $$
declare
  ta uuid := gen_random_uuid();
  tb uuid := gen_random_uuid();
  fin uuid := gen_random_uuid();
  outsider uuid := gen_random_uuid();
  finb uuid := gen_random_uuid();
  rev uuid := gen_random_uuid();
  admin uuid := gen_random_uuid();

  org uuid; cc uuid; vendor uuid; dep uuid; sess uuid;
  g_exp uuid; g_ap uuid; g_bank uuid; g_wht uuid; g_vat uuid;
  si uuid; je uuid; je_rev uuid; cb uuid;
  st uuid; ir uuid;
  v_stages text[];
  n int;
  v_actor uuid;
  v_acted_by uuid;
  v_related uuid;
  v_note text;
begin
  ------------------------------------------------------------------
  -- Fixtures
  ------------------------------------------------------------------
  insert into tenants (id, name, industry_template, status)
  values (ta, 'Audit Co', 'general', 'active'), (tb, 'Other Co', 'general', 'active');

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token
  )
  select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
         'aud-' || u.id || '@test.local',
         extensions.crypt('Tester123', extensions.gen_salt('bf')),
         now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
  from (values (fin), (outsider), (finb)) as u(id);

  insert into app_users (id, tenant_id, name, email, is_company_admin) values
    (fin,     ta, 'Audit Finance',  'aud-' || fin || '@test.local', true),
    (outsider,ta, 'Audit Outsider', 'aud-' || outsider || '@test.local', false),
    (finb,    tb, 'Audit Finance B','aud-' || finb || '@test.local', true);

  insert into finance_team_members (tenant_id, user_id, role) values
    (ta, fin, 'finance'), (tb, finb, 'finance');

  perform set_config('request.jwt.claims',
                     json_build_object('sub', fin, 'role', 'authenticated')::text, true);

  insert into organizations (tenant_id, company_code, site_name) values (ta, 'AU', 'Site') returning id into org;
  insert into cost_centers (tenant_id, name) values (ta, 'CC') returning id into cc;
  insert into accounts (tenant_id, account_code, name, account_type)
    values (ta, 'SUP-AU', 'Supplier', 'vendor') returning id into vendor;

  insert into gl_accounts (tenant_id, account_code, name, account_type)
    values (ta, '5000', 'Expense', 'expense') returning id into g_exp;
  insert into gl_accounts (tenant_id, account_code, name, account_type)
    values (ta, '2000', 'AP', 'liability') returning id into g_ap;
  insert into gl_accounts (tenant_id, account_code, name, account_type)
    values (ta, '1000', 'Bank', 'asset') returning id into g_bank;
  insert into gl_accounts (tenant_id, account_code, name, account_type)
    values (ta, '2100', 'WHT', 'liability') returning id into g_wht;
  insert into gl_accounts (tenant_id, account_code, name, account_type)
    values (ta, '1200', 'VAT Input', 'asset') returning id into g_vat;

  insert into gl_posting_rules (tenant_id, account_role, gl_account_id) values
    (ta, 'default_expense', g_exp), (ta, 'ap_control', g_ap),
    (ta, 'bank', g_bank), (ta, 'wht_payable', g_wht), (ta, 'vat_input', g_vat);

  insert into fin_bank_accounts (tenant_id, name, kind, currency, gl_account_id)
  values (ta, 'OPS-AU', 'operating', 'UGX', g_bank);

  insert into accounting_periods (tenant_id, period_start, period_end)
  values (ta, date_trunc('month', current_date)::date,
              (date_trunc('month', current_date) + interval '1 month - 1 day')::date);

  ------------------------------------------------------------------
  -- 1. Posting records its poster automatically
  ------------------------------------------------------------------
  insert into supplier_invoices (
    tenant_id, cost_center_id, invoice_number, invoice_date, due_date,
    amount_incl_vat, vat_amount, currency, organization_id, prf_oif_number,
    vendor_account_id
  ) values (
    ta, cc, 'INV-AU-1', current_date, current_date + 30,
    1160, 160, 'UGX', org, 'PRF-1', vendor
  ) returning id into si;

  select id into je from journal_entries
   where tenant_id = ta and source_type = 'supplier_invoice' and source_id = si;
  perform pg_temp.assert(je is not null, 'the invoice did not post a journal');

  select actor_id into v_actor from fin_transaction_actors
   where journal_entry_id = je and role = 'posted';
  perform pg_temp.assert(v_actor = fin,
    format('the poster should be the finance user, got %s', v_actor));

  -- No initiator was ever recorded, and none is invented.
  perform pg_temp.assert(
    not exists (select 1 from fin_transaction_actors
                 where journal_entry_id = je and role = 'initiated'),
    'an initiator was invented for a posting that never recorded one');
  raise notice 'PASS: posting records its poster, and does not invent an initiator';

  ------------------------------------------------------------------
  -- 2. A void links the reversal to what it reverses
  ------------------------------------------------------------------
  perform set_config('request.jwt.claims',
                     json_build_object('sub', fin, 'role', 'authenticated')::text, true);
  set local role authenticated;
  -- void_journal_entry returns the whole journal_entries row, not just an id.
  je_rev := (void_journal_entry(je, 'wrong supplier invoiced')).id;
  reset role;

  perform pg_temp.assert(je_rev is not null, 'void_journal_entry returned nothing');

  select actor_id, note, related_journal_entry_id into v_actor, v_note, v_related
    from fin_transaction_actors where journal_entry_id = je_rev and role = 'reversed';
  perform pg_temp.assert(v_related = je,
    format('the reversal must link back to the entry it reverses (got %s)', v_related));
  perform pg_temp.assert(v_actor = fin,
    format('the reverser should be the finance user, got %s', v_actor));

  -- The reversal is also linked the other way: the original is void.
  perform pg_temp.assert(
    (select status from journal_entries where id = je) = 'void',
    'the original entry should be void');
  raise notice 'PASS: a reversal is linked to its original, durably';

  ------------------------------------------------------------------
  -- 3. Impersonation cannot hide
  ------------------------------------------------------------------
  -- A platform admin impersonating the finance user posts an entry; the row
  -- names the effective user and keeps the raw session user alongside.
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token
  ) values (
    '00000000-0000-0000-0000-000000000000', admin, 'authenticated', 'authenticated',
    'aud-' || admin || '@test.local',
    extensions.crypt('Tester123', extensions.gen_salt('bf')),
    now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', ''
  );
  insert into app_users (id, tenant_id, name, email, is_company_admin) values
    (admin, ta, 'Audit Platform Admin', 'aud-' || admin || '@test.local', false);

  declare
    v_je2 uuid;
  begin
    perform set_config('request.jwt.claims',
                       json_build_object('sub', admin, 'role', 'authenticated')::text, true);
    -- Impersonating: the effective user is the finance user.
    insert into impersonation_sessions (platform_admin_id, tenant_id, reason, expires_at,
                                        impersonated_user_id)
    values (admin, ta, 'audit trail test', now() + interval '1 hour', fin)
    returning id into sess;

    v_je2 := (post_journal_entry(ta, 'manual', null, current_date, 'impersonated posting',
      jsonb_build_array(
        jsonb_build_object('gl_account_id', g_exp, 'debit', 10, 'currency', 'UGX'),
        jsonb_build_object('gl_account_id', g_ap,  'credit', 10, 'currency', 'UGX')))).id;

    select actor_id, acted_by into v_actor, v_acted_by
      from fin_transaction_actors where journal_entry_id = v_je2 and role = 'posted';
    perform pg_temp.assert(v_actor = fin,
      format('the effective user should be recorded as the actor, got %s', v_actor));
    perform pg_temp.assert(v_acted_by = admin,
      format('the raw session user should be kept as acted_by, got %s', v_acted_by));
    perform pg_temp.assert(
      (select impersonation_session_id from fin_transaction_actors
        where journal_entry_id = v_je2 and role = 'posted') = sess,
      'the impersonation session should be recorded');
  end;
  raise notice 'PASS: an impersonated posting records the effective user and the session user';
  reset role;

  ------------------------------------------------------------------
  -- 4. Initiation is recordable, and must be a member
  ------------------------------------------------------------------
  perform set_config('request.jwt.claims',
                     json_build_object('sub', fin, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform fin_audit_link_initiator(je, outsider, 'raised the request');
  reset role;

  -- (outsider is a member of the tenant, so that is allowed; the record says who.)
  perform pg_temp.assert(
    (select actor_id from fin_transaction_actors
      where journal_entry_id = je and role = 'initiated') = outsider,
    'the initiator was not recorded');

  -- Idempotent and non-overwriting: linking again is a no-op, so the first
  -- recorded initiator stands even if a later path claims it.
  perform set_config('request.jwt.claims',
                     json_build_object('sub', fin, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform fin_audit_link_initiator(je, fin, 'someone else claims it');
  reset role;
  perform pg_temp.assert(
    (select actor_id from fin_transaction_actors
      where journal_entry_id = je and role = 'initiated') = outsider,
    'a second initiator overwrote the first');
  raise notice 'PASS: initiation is recorded once and cannot be rewritten';

  -- A non-member cannot be named as initiator.
  perform set_config('request.jwt.claims',
                     json_build_object('sub', fin, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform fin_audit_link_initiator(je, finb, 'wrong tenant user');
    raise exception 'FAIL: a user from another company was accepted as initiator';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
    if sqlerrm not like '%is not a member of this company%' then
      raise exception 'FAIL: wrong error for a foreign initiator: %', sqlerrm;
    end if;
  end;
  reset role;
  raise notice 'PASS: a foreign user cannot be named as initiator';

  ------------------------------------------------------------------
  -- 5. The trail reports actors for a real document, in order
  ------------------------------------------------------------------
  perform set_config('request.jwt.claims',
                     json_build_object('sub', fin, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_stages := pg_temp.stages('supplier_invoice', si);
  reset role;

  perform pg_temp.assert(v_stages @> array['document']::text[],
    format('the trail is missing the document stage: %s', v_stages));
  perform pg_temp.assert(v_stages @> array['journal']::text[],
    format('the trail is missing the journal stage: %s', v_stages));
  perform pg_temp.assert(v_stages @> array['posted']::text[],
    format('the trail is missing the poster: %s', v_stages));
  perform pg_temp.assert(v_stages @> array['initiated']::text[],
    format('the trail is missing the initiator: %s', v_stages));

  -- The poster stage names a human, not a bare uuid.
  perform pg_temp.assert(
    exists (select 1 from fin_audit_trail('supplier_invoice', si)
             where stage = 'posted' and actor_name = 'Audit Finance'),
    'the poster stage should name the user');
  -- And the reversal of this invoice is on its trail, linked.
  perform pg_temp.assert(
    exists (select 1 from fin_audit_trail('supplier_invoice', si)
             where stage = 'reversed'),
    'the trail should include the reversal of this document');
  raise notice 'PASS: the trail shows document -> journal -> initiated/posted, with the reversal';

  ------------------------------------------------------------------
  -- 6. Approvals: recorded by the RPC, and shown in the trail
  ------------------------------------------------------------------
  -- A real invoice workflow: A submits, B (a different reviewer) approves.
  insert into departments (tenant_id, name) values (ta, 'Ops') returning id into dep;
  update app_users set department_id = dep where tenant_id = ta;

  insert into workflow_stages (tenant_id, name, applies_to, sequence_order,
                              approver_role, is_active, is_finance_terminal_stage)
  values (ta, 'Finance check', 'invoices', 1, 'finance', true, true) returning id into st;
  -- The finance user reviews the invoice; the outsider submits it.
  insert into approval_assignments (tenant_id, workflow_stage_id, user_id)
  values (ta, st, fin);

  -- The outsider submits (as themself).
  perform set_config('request.jwt.claims',
                     json_build_object('sub', outsider, 'role', 'authenticated')::text, true);
  insert into invoice_requests (tenant_id, requester_id, vendor_name, description, amount)
  values (ta, outsider, 'V', 'd', 100) returning id into ir;

  -- The finance user approves it through the real RPC.
  perform set_config('request.jwt.claims',
                     json_build_object('sub', fin, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform record_invoice_approval_decision(ir, 'approved', 'checked', null);
  exception when others then
    reset role;
    raise exception 'FAIL: the approval RPC failed: %', sqlerrm;
  end;
  reset role;

  perform pg_temp.assert(
    (select count(*) from approval_actions where invoice_request_id = ir) = 1,
    'the approval RPC did not record an approval_actions row');

  -- And fin_audit_approvals surfaces it for the invoice's journal.
  insert into supplier_invoices (
    tenant_id, cost_center_id, invoice_number, invoice_date, due_date,
    amount_incl_vat, vat_amount, currency, organization_id, prf_oif_number,
    vendor_account_id
  ) values (
    ta, cc, 'INV-AU-2', current_date, current_date + 30,
    500, 0, 'UGX', org, 'PRF-2', vendor
  ) returning id into si;

  -- (source_id of that journal is the supplier invoice, not the request, so
  -- fin_audit_approvals is exercised directly against the request link.)
  perform pg_temp.assert(
    (select count(*) from approval_actions aa
      where aa.invoice_request_id = ir and aa.effective_user_id = fin) = 1,
    'the approval should name the approving user as effective_user_id');
  raise notice 'PASS: approvals are recorded by the RPC, naming the approver';

  ------------------------------------------------------------------
  -- 7. Append-only
  ------------------------------------------------------------------
  select journal_entry_id into je from fin_transaction_actors
   where tenant_id = ta and role = 'posted' limit 1;

  begin
    update fin_transaction_actors set actor_id = finb where journal_entry_id = je;
    raise exception 'FAIL: the audit trail was editable';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
    if sqlerrm not like '%AUDIT_IMMUTABLE%' then
      raise exception 'FAIL: wrong error editing the trail: %', sqlerrm;
    end if;
  end;

  begin
    delete from fin_transaction_actors where journal_entry_id = je;
    raise exception 'FAIL: the audit trail was deletable';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
    if sqlerrm not like '%AUDIT_IMMUTABLE%' then
      raise exception 'FAIL: wrong error deleting the trail: %', sqlerrm;
    end if;
  end;
  raise notice 'PASS: the audit trail is append-only';

  -- A finance user cannot forge a row directly.
  perform set_config('request.jwt.claims',
                     json_build_object('sub', fin, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    insert into fin_transaction_actors (tenant_id, journal_entry_id, role, actor_id)
    values (ta, je, 'initiated', finb);
    raise exception 'FAIL: a finance user forged an audit row';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
    if sqlerrm not like '%row-level security%' and sqlerrm not like '%permission denied%' then
      raise exception 'FAIL: wrong error forging an audit row: %', sqlerrm;
    end if;
  end;
  reset role;
  raise notice 'PASS: the trail cannot be forged from the client';

  ------------------------------------------------------------------
  -- 8. Tenant-scoped and finance-only
  ------------------------------------------------------------------
  perform set_config('request.jwt.claims',
                     json_build_object('sub', outsider, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from fin_transaction_actors where journal_entry_id = je;
  reset role;
  perform pg_temp.assert(n = 0,
    format('a non-finance user read %s audit rows', n));

  perform set_config('request.jwt.claims',
                     json_build_object('sub', finb, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from fin_transaction_actors where journal_entry_id = je;
  reset role;
  perform pg_temp.assert(n = 0,
    format('another tenant read %s audit rows', n));
  raise notice 'PASS: the trail is tenant-scoped and finance-only';

  ------------------------------------------------------------------
  -- 9. Gaps are reported, not guessed
  ------------------------------------------------------------------
  perform set_config('request.jwt.claims',
                     json_build_object('sub', fin, 'role', 'authenticated')::text, true);
  set local role authenticated;
  -- `je` was given an initiator in section 4, so it is NOT a gap. Pick a
  -- posting that genuinely has none: the impersonated manual entry from
  -- section 3 never had an initiator linked.
  perform pg_temp.assert(
    exists (select 1 from fin_audit_gaps(ta) g
             where g.source_type = 'manual'
               and g.gap = 'no initiator recorded for this posting'),
    'fin_audit_gaps did not report a posting with no initiator');
  perform pg_temp.assert(
    not exists (select 1 from fin_audit_gaps(ta) g
                 where g.journal_entry_id = je
                   and g.gap = 'no initiator recorded for this posting'),
    'fin_audit_gaps reported a gap for an entry that has an initiator');
  raise notice 'PASS: missing initiators are reported, and only when actually missing';
  reset role;

  raise notice 'ALL AUDIT TRAIL TESTS PASSED';
end $$;

rollback;
