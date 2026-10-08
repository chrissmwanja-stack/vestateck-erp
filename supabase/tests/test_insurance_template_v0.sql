-- Regression test for:
--   supabase/migrations/20261008100625_insurance_brokerage_template_v0.sql
--
-- Verifies, against a fully-migrated fresh stack, that the Insurance Brokerage
-- template is intact:
--   1. Template exists, is active and is not the default.
--   2. Modules are exactly hr, insurance, it, legal and are active and
--      entitlable in the registry.
--   3. 8 departments, no workflow stages, no feature flags.
--   4. 18 GL accounts and 18 posting rules; account payloads are valid; every
--      rule points at an account in the template; the rules cover exactly
--      platform_gl_posting_roles() (all 13 existing roles incl. the required
--      ones, plus the 5 insurance roles); no two roles share an account.
--   5. Client money is balance-sheet: 1020 is an asset, 2010 a liability.
--
-- Run against a fresh local stack only -- never against a linked project.

\set ON_ERROR_STOP on

begin;

do $$
declare
  v_roles text[]; v_bad text;
begin
  if not exists (select 1 from industry_templates where key = 'insurance' and is_active and not is_default and name = 'Insurance Brokerage') then
    raise exception 'FAIL: insurance template missing, inactive or default';
  end if;

  if (select array_agg(name order by name) from industry_template_items where template_key = 'insurance' and kind = 'module')
     is distinct from array['hr','insurance','it','legal'] then
    raise exception 'FAIL: modules are not exactly hr, insurance, it, legal';
  end if;
  if exists (select 1 from industry_template_items i where i.template_key = 'insurance' and i.kind = 'module'
             and not exists (select 1 from platform_modules m where m.key = i.name and m.is_active and m.tenant_entitled)) then
    raise exception 'FAIL: a template module is not active and entitlable in the registry';
  end if;

  if (select count(*) from industry_template_items where template_key = 'insurance' and kind = 'department') <> 8 then
    raise exception 'FAIL: expected 8 departments';
  end if;
  if exists (select 1 from industry_template_items where template_key = 'insurance' and kind in ('workflow_stage', 'feature_flag')) then
    raise exception 'FAIL: v0 ships no workflow stages or feature flags';
  end if;

  if (select count(*) from industry_template_items where template_key = 'insurance' and kind = 'gl_account') <> 18
     or (select count(*) from industry_template_items where template_key = 'insurance' and kind = 'posting_rule') <> 18 then
    raise exception 'FAIL: expected 18 accounts and 18 posting rules';
  end if;

  -- Account payloads: name present, type valid, control flag boolean when present.
  select string_agg(name, ', ') into v_bad from industry_template_items
   where template_key = 'insurance' and kind = 'gl_account'
     and (coalesce(btrim(payload ->> 'name'), '') = ''
          or payload ->> 'account_type' not in ('asset', 'liability', 'equity', 'revenue', 'expense')
          or (payload ? 'is_control_account' and jsonb_typeof(payload -> 'is_control_account') <> 'boolean')
          or name !~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,19}$');
  if v_bad is not null then raise exception 'FAIL: invalid account items: %', v_bad; end if;

  -- Every posting rule points at an account in this template.
  select string_agg(name, ', ') into v_bad from industry_template_items r
   where r.template_key = 'insurance' and r.kind = 'posting_rule'
     and not exists (select 1 from industry_template_items a
                      where a.template_key = 'insurance' and a.kind = 'gl_account'
                        and a.name = r.payload ->> 'account_code');
  if v_bad is not null then raise exception 'FAIL: posting rules pointing nowhere: %', v_bad; end if;

  -- Rules cover exactly the platform's 18 roles (13 existing, incl. all required, + 5 insurance).
  select array_agg(name order by name) into v_roles from industry_template_items
   where template_key = 'insurance' and kind = 'posting_rule';
  if v_roles is distinct from (select array_agg(r order by r) from unnest(platform_gl_posting_roles()) r) then
    raise exception 'FAIL: posting rule roles do not match platform_gl_posting_roles()';
  end if;

  -- No two rules share an account (one role per account in this chart).
  if (select count(distinct payload ->> 'account_code') from industry_template_items
       where template_key = 'insurance' and kind = 'posting_rule') <> 18 then
    raise exception 'FAIL: two roles share an account';
  end if;

  -- Client money stays off income: the premium accounts are balance-sheet accounts.
  if (select account_type from (select payload ->> 'account_type' as account_type from industry_template_items
        where template_key = 'insurance' and kind = 'gl_account' and name = '1020') x) <> 'asset'
     or (select payload ->> 'account_type' from industry_template_items
          where template_key = 'insurance' and kind = 'gl_account' and name = '2010') <> 'liability' then
    raise exception 'FAIL: client money accounts must be asset (1020) and liability (2010)';
  end if;
end $$;

rollback;
