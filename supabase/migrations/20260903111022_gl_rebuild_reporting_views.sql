-- Workstream A, phase 1 continued: point v_trial_balance and
-- v_account_ledger at the real journal (journal_entry_lines joined to
-- gl_accounts) instead of the UNION ALL over supplier_invoices /
-- receivable_invoices / cash_bank_transactions.
--
-- Frontend impact: none required. TrialBalance.tsx selects
-- account_id, account_code, account_name, category_name, currency,
-- total_debit, total_credit, balance from v_trial_balance -- this
-- rebuild keeps that exact column shape (category_name now carries
-- the gl_account's account_type, since gl_accounts has no separate
-- category table the way the vendor/client `accounts` table does).
--
-- Caveat: for a tenant that hasn't called seed_default_chart_of_accounts()
-- yet (or has it but with invoices recorded before the GL triggers
-- existed), this view legitimately returns nothing or an incomplete
-- picture -- there's no backfill of historical subledger rows into
-- opening journal entries yet. That backfill is a separate, deliberately
-- un-automated follow-up (production data, needs a dry run against a
-- branch first), not part of this migration.

create or replace view "public"."v_account_ledger" with ("security_invoker" = 'true') as
select
  jel.tenant_id,
  jel.gl_account_id as account_id,
  je.source_type,
  je.source_id,
  je.description as reference_no,
  je.entry_date as transaction_date,
  jel.debit,
  jel.credit,
  jel.currency
from public.journal_entry_lines jel
join public.journal_entries je on je.id = jel.journal_entry_id
where je.status = 'posted';

create or replace view "public"."v_trial_balance" with ("security_invoker" = 'true') as
select
  a.tenant_id,
  a.id as account_id,
  a.account_code,
  a.name as account_name,
  a.account_type as category_name,
  l.currency,
  sum(l.debit) as total_debit,
  sum(l.credit) as total_credit,
  (sum(l.debit) - sum(l.credit)) as balance
from public.gl_accounts a
left join public.v_account_ledger l on l.account_id = a.id
group by a.tenant_id, a.id, a.account_code, a.name, a.account_type, l.currency;

grant select on public.v_account_ledger to authenticated;
grant select on public.v_trial_balance to authenticated;
