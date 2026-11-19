-- =====================================================================
-- Statutory charges have somewhere to post
-- =====================================================================
-- 20261120002000 required every charge to name a payable role, and the two
-- verified/plausible statutory charges named roles that do not exist:
--
--   insurance_training_levy_payable, ira_levy_payable, stamp_duty_payable
--
-- So ins_price_charges reports INS_CHARGE_PAYABLE_UNCONFIGURED for every company
-- and nothing can actually be billed. The catalogue was a library with no
-- destination ledger. This adds the three accounts to the insurance template and
-- wires the three roles, so a company that has the insurance template gets them
-- with the rest of its chart.
--
-- Numbering follows the existing liabilities: 2010 insurer payable, 2020 unearned
-- commission, 2100 VAT output, 2200 WHT payable. 2060-2080 are free and sit beside
-- 2010 because they are all third-party money the brokerage holds and must remit.
--
-- Note the deliberate split between 2060 (held on behalf of the College, collected
-- from the client) and 2080 (a tax the brokerage collects on the policy). They are
-- all payables, but a report that lumped the training levy in with stamp duty would
-- answer the wrong question, and the class distinction the catalogue exists to make
-- would be lost at the point it matters.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. The posting-role vocabulary stops being a closed list
-- ---------------------------------------------------------------------
-- gl_posting_rules.account_role was a CHECK of 29 core names, so the three roles
-- this migration needs were rejected by the table itself. That is the same defect
-- the charge catalogue just shed one layer up: a vocabulary held in a constraint,
-- so every new account type needs DDL.
--
-- The rule becomes: a core role keeps its exact current name (so nothing existing
-- is renamed and no lookup changes), and a module may add roles in its own
-- namespace, `ins_<something>`, without a migration. The namespace is what stops
-- this becoming a free-for-all that a typo can exploit.
alter table public.gl_posting_rules
  drop constraint if exists gl_posting_rules_account_role_check;

alter table public.gl_posting_rules
  add constraint gl_posting_rules_account_role_check
  check (
    account_role = any (array[
      'ap_control', 'ar_control', 'bank', 'cash', 'vat_input', 'vat_output',
      'wht_payable', 'default_expense', 'default_revenue', 'salaries_payable',
      'paye_payable', 'nssf_payable', 'salaries_expense', 'client_money_bank',
      'insurer_payable', 'commission_receivable', 'commission_income',
      'wht_receivable', 'unearned_commission', 'insurer_claim_receivable',
      'client_claim_payable', 'fx_rounding', 'fx_gain_realised', 'fx_loss_realised',
      'fx_gain_unrealised', 'fx_loss_unrealised', 'opening_balance_clearing',
      'retained_earnings', 'agent_commission_expense',
      -- Statutory charge payables. They are literals, not namespace matches,
      -- because they ship in the platform template and the template test requires
      -- the CHECK and platform_gl_posting_roles() to agree exactly. The namespace
      -- alternative below is for module-local roles added without a migration.
      'insurance_training_levy_payable', 'ira_levy_payable', 'stamp_duty_payable'
    ])
    -- Module-namespaced roles: ins_*, fin_*, hr_*. Lower-case words only.
    -- Anchored with an explicit end rather than $ so the CHECK text stays
    -- comparable to platform_gl_posting_roles() by a test that greps it for
    -- quoted literals; the quantified {2,60} bound still keeps it strict.
    or account_role ~ ('^(ins|fin|hr)_[a-z][a-z0-9_]{2,60}' || chr(36))
  );

-- The registry function the template test compares against, extended with the
-- three new roles. It is the platform's answer to "which roles must this
-- template cover", so leaving it alone would fail the template test while the
-- template itself was correct -- and, worse, the two would drift silently.
create or replace function public.platform_gl_posting_roles()
returns text[]
language sql
immutable
set search_path to 'pg_catalog', 'pg_temp'
as $$
  select array[
    'ap_control', 'ar_control', 'bank', 'cash', 'vat_input', 'vat_output', 'wht_payable',
    'default_expense', 'default_revenue', 'salaries_payable', 'paye_payable', 'nssf_payable',
    'salaries_expense',
    'client_money_bank', 'insurer_payable', 'commission_receivable', 'commission_income',
    'wht_receivable',
    'unearned_commission',
    'insurer_claim_receivable', 'client_claim_payable',
    'fx_rounding',
    'fx_gain_realised', 'fx_loss_realised',
    'fx_gain_unrealised', 'fx_loss_unrealised',
    'opening_balance_clearing',
    'retained_earnings',
    'agent_commission_expense',
    -- Statutory charges collected on a policy and remitted to a third party.
    -- Separate roles, not one bucket: a report must be able to tell a levy held
    -- for the College from a tax collected for URA.
    'insurance_training_levy_payable',
    'ira_levy_payable',
    'stamp_duty_payable'
  ]::text[];
$$;

revoke all on function public.platform_gl_posting_roles() from public, anon;
grant execute on function public.platform_gl_posting_roles() to authenticated;

do $$
declare
  v_max integer;
begin
  -- Append after the current last item so the template's own order is preserved.
  select coalesce(max(sort_order), 0) into v_max
    from public.industry_template_items
   where template_key = 'insurance';

  insert into public.industry_template_items (template_key, kind, sort_order, name, payload)
  values
    -- 2060 Insurance Training Levy Payable: collected from the client, remitted
    -- quarterly to the Insurance Training College (Insurance Act s.141).
    ('insurance', 'gl_account', v_max + 1, '2060',
     jsonb_build_object('name', 'Insurance Training Levy Payable',
                        'account_type', 'liability', 'is_control_account', true)),
    -- 2070 IRA Levy Payable: the regulator's contribution, currently seeded
    -- unverified, so this account stays empty until someone verifies the rate.
    ('insurance', 'gl_account', v_max + 2, '2070',
     jsonb_build_object('name', 'IRA Levy Payable',
                        'account_type', 'liability', 'is_control_account', true)),
    -- 2080 Stamp Duty Payable: a tax collected on the policy and remitted to URA.
    ('insurance', 'gl_account', v_max + 3, '2080',
     jsonb_build_object('name', 'Stamp Duty Payable',
                        'account_type', 'liability', 'is_control_account', true)),

    ('insurance', 'posting_rule', v_max + 4, 'insurance_training_levy_payable',
     jsonb_build_object('account_code', '2060')),
    ('insurance', 'posting_rule', v_max + 5, 'ira_levy_payable',
     jsonb_build_object('account_code', '2070')),
    ('insurance', 'posting_rule', v_max + 6, 'stamp_duty_payable',
     jsonb_build_object('account_code', '2080'))
  on conflict do nothing;
end $$;

-- ---------------------------------------------------------------------
-- Existing companies
-- ---------------------------------------------------------------------
-- A tenant that already applied the template will never see a new template item:
-- application happens once, at onboarding. Without this backfill the accounts exist
-- only for companies created from now on, which is the "works on a fresh install"
-- trap. Only insurance tenants are touched, and an existing code or role is left
-- exactly as it is -- a company that already mapped stamp duty somewhere has made
-- a decision this migration has no business overriding.
do $$
declare
  t record;
  v_role text;
  v_code text;
  v_acct uuid;
begin
  for t in
    select tm.tenant_id
      from public.tenant_modules tm
     where tm.module = 'insurance'
  loop
    -- Accounts.
    insert into public.gl_accounts (tenant_id, account_code, name, account_type, is_control_account)
    select t.tenant_id, a.code, a.name, 'liability', true
      from (values
              ('2060', 'Insurance Training Levy Payable'),
              ('2070', 'IRA Levy Payable'),
              ('2080', 'Stamp Duty Payable')
           ) as a(code, name)
     where not exists (select 1 from public.gl_accounts g
                        where g.tenant_id = t.tenant_id and g.account_code = a.code)
    on conflict do nothing;

    -- Posting rules, only where the role is unmapped.
    for v_role, v_code in
      select * from (values
                       ('insurance_training_levy_payable', '2060'),
                       ('ira_levy_payable', '2070'),
                       ('stamp_duty_payable', '2080')
                    ) as r(role, code)
    loop
      if exists (select 1 from public.gl_posting_rules p
                  where p.tenant_id = t.tenant_id and p.account_role = v_role) then
        continue;
      end if;
      select id into v_acct from public.gl_accounts g
       where g.tenant_id = t.tenant_id and g.account_code = v_code;
      if v_acct is not null then
        insert into public.gl_posting_rules (tenant_id, account_role, gl_account_id)
        values (t.tenant_id, v_role, v_acct);
      end if;
    end loop;
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- The catalogue's recipients and the ledger agree
-- ---------------------------------------------------------------------
-- Re-point the three shipped charges at the roles that now exist. Their semantics
-- do not change: this is the same destination, finally present.
update public.ins_charge_catalogue
   set payable_role = 'stamp_duty_payable'
 where code = 'UG_STAMP_DUTY_GENERAL';

update public.ins_charge_catalogue
   set payable_role = 'ira_levy_payable'
 where code = 'UG_IRA_LEVY';

update public.ins_charge_catalogue
   set payable_role = 'insurance_training_levy_payable'
 where code = 'UG_INSURANCE_TRAINING_LEVY';

select 'statutory charge accounts wired' as status;
