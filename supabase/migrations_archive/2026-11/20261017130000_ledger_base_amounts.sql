-- Base-currency amounts on the general ledger view.
--
-- journal_entry_lines already stores fx_rate, base_debit and base_credit (see
-- 20261016150000_journal_base_amounts.sql). The ledger view did not expose them.
-- The new columns are appended at the end, so existing readers are unchanged.
-- For a functional-currency line the base amounts equal debit and credit exactly.

create or replace view public.v_account_ledger with (security_invoker = true) as
  select jel.tenant_id,
         jel.gl_account_id as account_id,
         je.source_type,
         je.source_id,
         je.description as reference_no,
         je.entry_date as transaction_date,
         jel.debit,
         jel.credit,
         jel.currency,
         jel.base_debit,
         jel.base_credit,
         jel.fx_rate
    from public.journal_entry_lines jel
    join public.journal_entries je on je.id = jel.journal_entry_id
   where je.status = 'posted';

grant select on public.v_account_ledger to authenticated;
