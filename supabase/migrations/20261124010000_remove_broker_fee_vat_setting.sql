-- =====================================================================
-- Accountant sign-off pack v2, decision 5:
-- remove ins.broker_fee_vat
-- =====================================================================
-- WHAT THIS KEY WAS
--   A company-level enum (vat_applicable | not_applicable) seeded with the
--   default 'vat_applicable', flagged requires_legal_review. It was intended
--   to say whether brokerage fees carry VAT.
--
-- WHY IT IS WRONG
--   The decision recorded on 17 November 2026 is that a genuine insurance
--   brokerage fee is VAT-EXEMPT (VAT Act Cap 344, Schedule 3 -- insurance
--   services are exempt supplies). A separate non-brokerage service may be
--   standard-rated, but that is a property of the SUPPLY, not of the company.
--   A single company-wide switch cannot express "this fee is exempt and that
--   one is taxable", so the key was answering the wrong question.
--
--   It was also dead. No function ever read it: the classification that
--   actually governs the treatment is ins_policy_fees.fee_class, introduced by
--   20261117260000_ins_client_broker_fees.sql, which defaults to
--   'insurance_brokerage' (exempt) and requires a stated reason to depart from
--   it. Meanwhile the seeded default said 'vat_applicable' -- i.e. the settings
--   table advertised 18% VAT on brokerage fees as the platform default, for a
--   supply the policy says is exempt. A reviewer reading
--   accounting_setting_definitions would have drawn the opposite conclusion to
--   the one the software implements.
--
-- WHY REMOVE RATHER THAN REPOINT
--   Repointing the default to 'not_applicable' would leave a company-wide
--   switch over a per-supply decision: still wrong, just less wrong. Because
--   the key is requires_legal_review, a repointed key that is later read by
--   anything would raise ACCT_LEGAL_UNREVIEWED until somebody approved a value
--   that should not exist as a setting at all. Decision 5 is to delete it and
--   keep the reasoning in the documentation (ACCOUNTANT_PACK.md A14/A20,
--   ACCOUNT_MAPPING_APPENDIX.md section 2.8).
--
-- SAFETY
--   Company-level values are removed first. Any tenant that somehow approved a
--   value loses a setting no code path reads, so no ledger behaviour changes.
--   The removal is recorded in a comment rather than silently: a future reader
--   who finds 'ins.broker_fee_vat' in an old snapshot or an old document needs
--   to know where it went and why.
--
-- Idempotent. Deletes rows only; no table, column or accounting data is touched.
-- =====================================================================

-- 1. Any per-company values. There is no FK to the definition in every
--    deployment, so delete values before the definition.
delete from public.company_accounting_settings
 where setting_key = 'ins.broker_fee_vat';

-- 2. The definition itself.
delete from public.accounting_setting_definitions
 where key = 'ins.broker_fee_vat';

-- 3. Nothing may reference the key any more. This is a guard, not a mutation:
--    if a later migration reintroduces a reader, that reader must not silently
--    resolve to nothing.
do $$
begin
  if exists (select 1 from public.accounting_setting_definitions
              where key = 'ins.broker_fee_vat') then
    raise exception 'BROKER_FEE_VAT_STILL_PRESENT: removal did not take effect';
  end if;
  raise notice 'PASS: ins.broker_fee_vat is removed; fee treatment is governed by ins_policy_fees.fee_class';
end $$;
