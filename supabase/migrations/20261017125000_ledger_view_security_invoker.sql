-- v_account_ledger ran with its owner's rights (no security_invoker option), so it
-- read every company's journal lines and did not apply the caller's row-level security.
-- With security_invoker the view applies the caller's RLS on journal_entries and
-- journal_entry_lines, which allow only the caller's company and finance team members.
--
-- Effect: a user who is not on the finance team of a company sees no ledger rows from
-- that company through this view. Check any non-finance page that reads it before merging.

alter view public.v_account_ledger set (security_invoker = true);
