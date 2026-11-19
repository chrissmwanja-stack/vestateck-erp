-- D4e fix-forward: approving a bank adjustment has never worked.
--
-- The CI log from the first real run of supabase/tests/test_d4e_*.sql shows the
-- failure at approve_bank_adjustment, step "post the adjustment":
--
--   ERROR: new row for relation "bank_reconciliations" violates check
--   constraint "bank_reconciliations_match_type_check"
--   DETAIL: Failing row contains (..., match_type = adjustment, ...)
--
-- The check allows match_type in ('manual','auto') and always has. Two
-- migrations written the same day (20261119210000 and 20261119220000) insert
-- 'adjustment' there, and 20261119235950 copied the same line into the reversal
-- branch. Every path that posts an adjustment therefore raises a check
-- violation, and the RPC has been dead since 'adjustment' was introduced.
--
-- 'adjustment' is the better value on the merits: "how was this line matched"
-- answered with manual/auto loses the fact that a bank adjustment cleared it,
-- and the rows are already findable by bank_adjustment_id anyway. So the fix is
-- to allow the value rather than to write a lie. Nothing reads match_type for
-- equality except the suggestion queries, which compare against 'auto' and
-- 'manual' and are unaffected by one more permitted value.
--
-- Note the detail column in the log also shows cash_bank_transaction_id = null
-- as the *only* non-null reference, which means bank_reconciliations_one_source_check
-- was satisfied only because the check still counts the three original columns
-- plus bank_adjustment_id (see 20261119064626). Both checks are pinned by the
-- test in supabase/tests/test_d4e_bank_adjustments_completion.sql.

begin;

alter table public.bank_reconciliations
  drop constraint if exists bank_reconciliations_match_type_check;

alter table public.bank_reconciliations
  add constraint bank_reconciliations_match_type_check
  check (match_type in ('manual', 'auto', 'adjustment'));

comment on column public.bank_reconciliations.match_type is
  'How the statement line was cleared: manual (a person chose the book entry), auto (a suggestion was confirmed), or adjustment (a posted bank adjustment cleared it; see bank_adjustment_id).';

commit;
