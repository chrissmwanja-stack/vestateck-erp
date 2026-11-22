-- Guards the UAT tenant built by supabase/seed.sql section 6
-- (Pearl Risk Brokers Ltd, 00000000-0000-0000-0000-00000000b001).
--
-- Read-only against the seeded database. Fails if a seed change leaves the
-- tenant incomplete: template not applied, wrong shape, or a tester login
-- that cannot see its own insurance data.
-- Skips (with a notice) when the seed skipped the tenant, e.g. no platform admin.

\set ON_ERROR_STOP on
begin;

do $$
declare
  v_t uuid := '00000000-0000-0000-0000-00000000b001';
  n integer;
begin
  if not exists (select 1 from tenants where id = v_t) then
    raise notice 'SKIP: UAT tenant not seeded in this database';
    return;
  end if;

  perform 1 from tenants where id = v_t and industry_template = 'insurance';
  if not found then raise exception 'FAIL: UAT tenant industry_template is not insurance'; end if;

  select count(*) into n from tenant_modules where tenant_id = v_t and module in ('insurance','hr','it','legal');
  if n <> 4 then raise exception 'FAIL: UAT tenant modules: expected insurance, hr, it, legal (got %)', n; end if;

  select count(*) into n from departments where tenant_id = v_t;
  if n <> 8 then raise exception 'FAIL: UAT tenant departments: expected 8, got %', n; end if;

  -- the chart the insurance template gives: one account per posting role, so
  -- the expected count follows platform_gl_posting_roles() rather than a
  -- literal that has to be edited whenever a role is added -- plus the seed's own
  -- endorsement clearing account (2090), checked next.
  select count(*) into n from gl_accounts where tenant_id = v_t and account_code <> '2090';
  if n <> array_length(platform_gl_posting_roles(), 1) then
    raise exception 'FAIL: UAT tenant GL accounts: expected one per posting role (%), got %',
      array_length(platform_gl_posting_roles(), 1), n;
  end if;

  -- The clearing account must be usable as a credit-note offset when an endorsement
  -- is cancelled: active, not a control account, not a bank account.
  select count(*) into n from gl_accounts g
   where g.tenant_id = v_t and g.account_code = '2090' and g.is_active and not g.is_control_account
     and not exists (select 1 from fin_bank_accounts b where b.tenant_id = g.tenant_id and b.gl_account_id = g.id);
  if n <> 1 then raise exception 'FAIL: UAT endorsement clearing account 2090 missing or not a plain account'; end if;

  select count(*) into n from app_users where tenant_id = v_t;
  if n <> 8 then raise exception 'FAIL: UAT tenant users: expected 8, got %', n; end if;

  -- Two hybrid users (insurance manager + Finance member) drive the endorsement
  -- settlement e2e (b107 maker, b108 checker); they must hold both authorities.
  select count(*) into n from staff_roles s
   where s.tenant_id = v_t and s.module = 'insurance' and s.role = 'manager'
     and s.user_id in ('00000000-0000-0000-0000-00000000b107',
                       '00000000-0000-0000-0000-00000000b108')
     and exists (select 1 from finance_team_members f
                  where f.tenant_id = s.tenant_id and f.user_id = s.user_id and f.role = 'finance');
  if n <> 2 then raise exception 'FAIL: UAT hybrid insurance-manager + finance users: expected 2, got %', n; end if;

  -- Three distinct Finance users are needed for the third-person rule
  -- (INS_CASH_THIRD_PERSON / INS_CXL_CASH_THIRD_PERSON): maker, checker, reconciler.
  select count(distinct user_id) into n from finance_team_members
  where tenant_id = v_t and role = 'finance'
    and user_id in ('00000000-0000-0000-0000-00000000b104',
                    '00000000-0000-0000-0000-00000000b105',
                    '00000000-0000-0000-0000-00000000b106');
  if n <> 3 then raise exception 'FAIL: UAT Finance maker/checker/reconciler: expected 3 distinct, got %', n; end if;

  select count(*) into n from ins_policies where tenant_id = v_t and status = 'active';
  if n <> 3 then raise exception 'FAIL: UAT tenant active policies: expected 3, got %', n; end if;

  select count(*) into n from ins_policies where tenant_id = v_t and status = 'draft';
  if n <> 1 then raise exception 'FAIL: UAT tenant draft policies: expected 1, got %', n; end if;

  select count(*) into n from ins_claims where tenant_id = v_t;
  if n <> 1 then raise exception 'FAIL: UAT tenant claims: expected 1, got %', n; end if;

  -- Every bound policy must have posted (bind creates journals).
  select count(*) into n from ins_policies p
  where p.tenant_id = v_t and p.status = 'active'
    and not exists (select 1 from journal_entries j where j.tenant_id = v_t and j.source_id = p.id);
  if n <> 0 then raise exception 'FAIL: % active UAT policies have no journal entry', n; end if;

  -- The account manager login must see the tenant's insurance data through RLS.
  perform set_config('request.jwt.claims',
    json_build_object('sub', '00000000-0000-0000-0000-00000000b102', 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from ins_policies;
  reset role;
  if n <> 4 then raise exception 'FAIL: UAT account manager sees % policies, expected 4', n; end if;

  -- Regulatory values are drafts only: never approved by the seed.
  select count(*) into n from regulatory_parameters where tenant_id = v_t and status = 'draft';
  if n <> 8 then raise exception 'FAIL: UAT regulatory drafts: expected 8, got %', n; end if;

  -- Every seeded value must be honest about how far it has been checked. Four are
  -- still UNVERIFIED guesses from the roadmap. The two withholding-tax rows were
  -- confirmed by the company accountant (s.134 rate, s.139(aa) character), and
  -- must say so -- a row claiming to be verified without that being true is worse
  -- than one admitting it is a guess.
  select count(*) into n from regulatory_parameters
   where tenant_id = v_t and parameter_key not like 'tax.wht_agent_commission_%'
     and (status <> 'draft' or source_ref not like 'UNVERIFIED:%');
  if n <> 0 then raise exception 'FAIL: unconfirmed regulatory rows must stay unverified drafts (found %)', n; end if;

  -- Three rows: the rate, and the two character windows.
  select count(*) into n from regulatory_parameters
   where tenant_id = v_t and parameter_key like 'tax.wht_agent_commission_%';
  if n <> 3 then raise exception 'FAIL: accountant-confirmed WHT rows: expected 3, got %', n; end if;

  -- None of them may be anything but a verified draft.
  select count(*) into n from regulatory_parameters
   where tenant_id = v_t and parameter_key like 'tax.wht_agent_commission_%'
     and (status <> 'draft' or source_ref not like 'VERIFIED:%');
  if n <> 0 then raise exception 'FAIL: WHT rows must be verified drafts, not approved or unverified (found %)', n; end if;

  -- Rate and character must each cover the whole time since the tax applied,
  -- with no gap: a payment date landing in a hole would be refused at the till.
  select count(*) into n from regulatory_parameters
   where tenant_id = v_t and parameter_key = 'tax.wht_agent_commission_is_final';
  if n <> 2 then raise exception 'FAIL: expected two character windows, got %', n; end if;
  select count(*) into n from regulatory_parameters
   where tenant_id = v_t and parameter_key = 'tax.wht_agent_commission_is_final'
     and value_text not in ('true', 'false');
  if n <> 0 then raise exception 'FAIL: character must be true or false (found %)', n; end if;

  raise notice 'PASS: UAT brokerage seed is complete';
end $$;

rollback;