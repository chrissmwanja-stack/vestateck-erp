-- =====================================================================
-- Which insurance posting roles are still unmapped, and what that blocks
-- Accountant pack v2, B6/B8 follow-up; Appendix B Q1
-- =====================================================================
-- Appendix B Q1 asked for a contra-claims-expense account and the accountant's answer was
-- explicit: "Create a new code in the existing claims-expense range" -- and equally explicit
-- that they would not name a code without checking the live chart of accounts first.
--
-- So this migration deliberately does NOT create an account or seed
-- ins_claim_write_off_expense in the industry template. The template requires a concrete
-- account_code per posting rule, so seeding it would mean inventing a number in a live
-- client's chart. That is the one thing Q1 forbids.
--
-- What that leaves: until someone maps the role, ins_write_off_claim fails with
-- INS_WRITE_OFF_ACCOUNT -- correct, but only discoverable by attempting a write-off, i.e.
-- in front of a client. The same shape of problem B3's refusal had, and the same answer:
-- a readiness view, so the gap is visible before the difficult conversation rather than
-- during it.
--
-- Order of work this implies, and it is the accountant's, not the software's:
--   1. decide the code, within the existing claims-expense range;
--   2. create the account in each tenant;
--   3. map it to ins_claim_write_off_expense.
-- Step 1 blocks step 2, which is why no code appears anywhere in this repository.

-- ---------------------------------------------------------------------
-- 1. The roles a company must map for the claims controls to work
-- ---------------------------------------------------------------------
-- Only roles that (a) ship in the platform template as a role with no account, or (b) were
-- added by this pack and are therefore unmapped everywhere. A role whose account the
-- template already seeds is not a decision anyone has to make, so listing it would bury the
-- one line that matters.
create or replace function public.ins_posting_role_readiness()
returns table (
  account_role text,
  mapped       boolean,
  account_code text,
  account_name text,
  blocks       text,
  says         text
)
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
begin
  return query
  select r.account_role,
         g.id is not null,
         g.account_code,
         g.name,
         r.blocks,
         case
           when g.id is not null then 'mapped'
           else 'NOT MAPPED: ' || r.blocks || '. Create the account in the existing '
                || r.range_hint || ' range and map it to ' || r.account_role || '.'
         end
    from (values
            -- Appendix B Q1. Both a claim write-off (Q1) and a claim recovery (Q4) post
            -- here, which is why one role serves both and why the roles below are not
            -- interchangeable with default_expense.
            ('ins_claim_write_off_expense',
             'claim write-offs and claim recoveries',
             'claims-expense')
         ) as r(account_role, blocks, range_hint)
    left join lateral (
      select a.id, a.account_code, a.name
        from public.gl_posting_rules p
        join public.gl_accounts a on a.id = p.gl_account_id
       where p.tenant_id = v_tenant
         and p.account_role = r.account_role
       limit 1
    ) g on true
   order by r.account_role;
end $$;

revoke all on function public.ins_posting_role_readiness() from public, anon;
grant execute on function public.ins_posting_role_readiness() to authenticated;

comment on function public.ins_posting_role_readiness() is
  'Insurance posting roles that a company must map itself, whether each is mapped, and what stays broken until it is. Empty result for a caller with no tenant. Accountant pack v2 Appendix B Q1.';

-- ---------------------------------------------------------------------
-- 2. No proof block here, deliberately
-- ---------------------------------------------------------------------
-- get_my_tenant_id() is null at migration time, so any proof written here would take its
-- "no tenant" branch every single time and prove nothing -- while reading, in review, like
-- a checked control. The behaviour is proved in supabase/tests/test_ins_claims_account_readiness.sql,
-- where there is a session and a tenant to prove it against.
