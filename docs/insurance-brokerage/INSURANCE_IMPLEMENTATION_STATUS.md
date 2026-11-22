# Insurance Brokerage: Implementation Status

**Authoritative for:** what is implemented and what test exists for it.
**Not authoritative for:** whether anything is accounting- or legal-approved (see
`INSURANCE_DECISIONS_REGISTER.md`) or what must pass before production (see
`INSURANCE_ACCEPTANCE_PLAN.md`).

Last reconciled: 21 November 2026, against `main` at `134da84`. The work formerly on
`feat/ins-accounting-acceptance` is on `main` (PRs #33 to #38).

## How to read this file

| Status | Meaning |
|---|---|
| **Built, tested** | Migration or code exists and a named SQL test, unit test or Playwright spec covers it. A passing CI run for the current head is a separate fact: record it in the acceptance plan, not here. |
| **Built, untested** | Code exists, no dedicated automated test found. |
| **Partial** | Some call sites or modes exist; the gap is stated. |
| **Not started** | Nothing in the repo. |

"Built" never means accountant-approved. Approval status lives only in the decisions register.

**Maintenance rule.** Any PR that adds, changes or removes insurance behaviour updates the matching
row in the same PR. Dates and migration numbers are evidence, not narrative: put the story in
`ROADMAP.md`.

## Merge state

| Item | On `main` |
|---|---|
| Commission recognition declared cases (`20261120001000`) | Yes |
| Statutory charge catalogue, accounts, on-policy pricing, enforcement setting (`20261120002000` to `20261120235905`) | Yes |
| Endorsement cancellation, E4 (`20261120235910`), with its RPCs and `cancellation_*` columns in `database.types.ts` | Yes |
| Reports batches 1 to 4 (`20261121090000` to `20261121130000`) | Yes |
| Business-day dating: `ins_local_date()`, `ins_local_today()` and the report change (`20261121140000`, types in `7802c5f`), then the application functions (`20261121150000`), then the platform helpers and the remaining functions (`20261122090000`, `20261122100000`) | Yes |

## Implemented

| Area | Status | Evidence | Known gaps |
|---|---|---|---|
| Clients, KYC decisions, insurers, product lines, intermediaries | Built, tested | `test_ins_core.sql`, `test_ins_intermediaries.sql`, `clientKyc.test.ts` | Client merge, groups, account-per-client: **Not started** |
| Insured-risk register, motor certificate stock | Built, tested | `20261017100000`, `test_ins_risk_register.sql`, `test_ins_product_line_certificate.sql` | |
| Quotation and placement | Built, tested | `20261106170000`, `20261107120000`, `test_ins_quotes.sql` | |
| Policy approval workflow (bind requires an approved policy) | Built, tested | `20261106180000`, `test_ins_policy_approval.sql` | |
| Bind: one journal, premium receivable, insurer payable | Built, tested | `test_ins_core.sql`, `test_ins_policy_cash.sql` | |
| Co-insurance shares and charges | Built, tested | `test_ins_coinsurance_charges.sql`, `test-ins-coinsurance-concurrency.ts` | Co-insurer schedule document: open |
| Premium cash, remittances, unremitted-premium report | Built, tested | `test_ins_policy_cash.sql`, `test_ins_unremitted_premium.sql`, `test-ins-policy-cash-concurrency.ts` | Premium age in the unremitted report: not built (accountant answer 26) |
| Renewals, bulk drafts, outcomes, notices | Built, tested | `test_ins_renewal_outcomes.sql`, `test_ins_renewal_notices.sql` | |
| Endorsements E1 to E3 (proposals, posting, foreign legs) | Built, tested | `test_endorsement_proposals.sql`, `test_endorsement_posting.sql` | Endorsements netted on the statement: open |
| **Endorsement cancellation E4** | Built, tested | `20261120235910`, `test_endorsement_cancellation.sql` | Newest-first only; refused once money has moved. No Playwright spec |
| Policy cancellation (pro-rata, approval, refund cash) | Built, tested | `test_ins_cancellation_calculation.sql`, `_cash.sql`, `_posting.sql`, three concurrency scripts | No Playwright spec |
| Policy reversal (reverse and re-issue) | Built, tested | `test_ins_policy_reversal.sql`, `POLICY_REVERSAL.md` | v1 restricted |
| Commission: deferred at bind, recognition modes `at_placement`, `on_premium_collection`, `on_insurer_settlement`; per-share gross settlement basis | Built, tested | `20261117200000`, `20261117210000`, `20261119240000`, `20261120001000`; `test_ins_commission*.sql`, `test_ins_settlement_basis.sql` | `over_policy_term`: **Not started**, unselectable. Which insurer agreement uses which mode is a decision, not a build |
| Earned-commission transfer, voidable, bank-reconciled | Built, tested | `test_ins_commission_reconciliation.sql` | |
| Commission statements, approved insurer/product rate matrix | Built, tested | `20261020210000` | |
| Agent commission end to end (terms, accrual, register, maker-checker payment, WHT at payment, period returns, PDF statements) | Built, tested | `test_ins_agent_commission.sql`, `agentCommission*.test.ts`, `agentStatementPdf.test.ts` | Manual "accrue" action deliberately omitted (decision pending) |
| Statutory charge catalogue (versioned, immutable once billed, extensible formula) | Built, tested | `20261120002000`, `20261120003000`, `test_ins_statutory_charge_catalogue.sql` | Two seeded rates unverified and unbillable (see register) |
| Statutory charge accounts (training levy, IRA levy, stamp duty payables) | Built | `20261120004000` | Covered only through the two statutory tests |
| Statutory charges on the policy (price, acknowledge, bind re-checks) and enforcement setting | Built, tested | `20261120005000`, `20261120235900` to `20261120235905`, `test_ins_statutory_charges_on_policy.sql` | Enforcement defaults to **advisory**; `required` is an undecided commercial setting |
| Claims: state machine, reserve revisions, excess modes, document checklist, payments (two modes) | Built, tested | `test_ins_claim_payments.sql`, `_reserve_revisions.sql`, `_documents.sql` | Letters, withdrawal, overpayment, recovery: **Not started** |
| Insurer statement reconciliation | Built, tested | `20261106220000`, `test_ins_insurer_statements.sql` | Read-only; entry screen to improve |
| Production book, client statements, aged balances | Built, tested | `test_ins_production_statement.sql` | Ageing is done in the browser; server-side as-of and pagination: open |
| Reports batch 1: production netted for endorsements, cancellations and reversals; premium collected; outstanding premium as at a date. Server functions and three screens (`/insurance/reports/production`, `/premium-collected`, `/outstanding-premium`) with Excel and PDF export | Built, tested | `20261121090000_ins_reports_batch1.sql`, `test_ins_reports_batch1.sql` (each total is tied to the AR control balance); `ProductionReport.test.tsx`, `PremiumCollected.test.tsx`, `OutstandingPremium.test.tsx` | Definitions DR-35 to DR-38. Not exercised by a scenario yet: endorsements and E4 in production, policy reversal, a void dated after the as-at date, imported policies. Insurer grouping is not offered (co-insurance needs the share basis). The older Production Book and the dashboard still compute in the browser and still exclude cancelled business; they are not yet replaced |
| Reports batch 2: commission earned (read from the commission income account, by route, with a month, client, product line, branch or agent grouping) and commission receivable (as at a date, from the commission receivable open items). Server functions and two screens (`/insurance/reports/commission-earned`, `/commission-receivable`) with Excel and PDF export | Built, partly tested | `20261121100000_ins_reports_batch2_commission.sql`, `test_ins_reports_batch2.sql` (earned at placement, ledger tie-out, after a cancellation, receivable empty on the net basis; run record: acceptance plan E9); `CommissionEarned.test.tsx`, `CommissionReceivable.test.tsx` | Definitions DR-39, DR-40. Not exercised by a scenario yet: commission on insurer settlement or premium collection and its reversal, endorsements, imported policies, and receivable with rows (needs the gross-basis fixture in `test_ins_settlement_basis.sql`). Insurer grouping is not offered |
| Reports batch 3: claims register (status, reserve, approved, paid and outstanding as at a date, open or all claims) and claims ageing (open claims by age bucket, optionally by insurer or product line, built on the register). Server functions and two screens (`/insurance/reports/claims-register`, `/claims-ageing`) with Excel and PDF export | Built, partly tested | `20261121110000_ins_reports_batch3_claims.sql`, `20261121130000_ins_reports_batch3_claims_tiebreak.sql`, `test_ins_reports_batch3.sql` (run record: acceptance plan E10); `ClaimsRegister.test.tsx`, `ClaimsAgeing.test.tsx` (passing) | Definitions DR-41, DR-42. Not exercised by a scenario yet: a back-dated claim, a payment voided after the as-at date, brokerage-managed claims, ageing beyond the first bucket, co-insured policies |
| Reports batch 4: cancellations (posted cancellations with return premium, commission clawed back and retained, and insurer credit), the cancellation register, renewals due (with outcome) and renewal retention. Server functions `ins_report_cancellations`, `ins_report_cancellation_register`, `ins_report_renewals`, `ins_report_renewal_retention` and four screens (`/insurance/reports/cancellations`, `/cancellation-register`, `/renewals`, `/renewal-retention`) | Built, tested | `20261121120000_ins_reports_batch4_cancellations_renewals.sql`, `test_ins_reports_batch4.sql` (run record: acceptance plan E11); `CancellationsReport.test.tsx`, `CancellationRegister.test.tsx`, `RenewalsReport.test.tsx`, `RenewalRetention.test.tsx` | Definitions DR-43 to DR-45. Renewal outcomes are not kept as history, so renewals has no as-at date |
| Reports still to build | Not started | | Statutory charges, insurer performance, and a dashboard on one summary function |
| Business day: dates follow Africa/Kampala. `business_date(timestamptz)` and `business_today()` (`20261122090000`) hold the rule; `ins_local_date(timestamptz)` and `ins_local_today()` delegate to them and date report timestamps and default as-at dates (`20261121140000`: 7 report functions). `20261121150000` moves 52 application functions to the same helpers (107 expressions): 37 `ins_*` functions, 8 insurance-path functions, and 7 shared finance functions that void or raise settlements and credit notes, plus three insurance column defaults. `20261122090000` moves 27 non-insurance functions (accounting settings, bank adjustments, finance reports, `void_journal_entry`, FX, regulatory parameters, payroll posting, maintenance, sustainability) and four column defaults to the platform helpers; `20261122100000` moves 4 procurement tracking functions | Built, tested | `20261121140000_ins_reports_kampala_dating.sql`, `20261121150000_ins_app_dates_kampala.sql`, `20261122090000_platform_business_date.sql`, `20261122100000_business_date_procurement.sql`; 12 SQL test files call `ins_local_today()` (reports batches 1 to 4, cancellation, claim payments, commission recognition, import staging, policy cash, policy reversal) | Decision DR-46. No test calls `ins_local_date()` directly. The 7 shared finance functions now date by the Kampala day for every module. No function or column default in `public` uses the UTC date now: `test_platform_business_date.sql` fails on any new `current_date` or `<column>_at::date`. Five other SQL test files compare with `business_today()`, because they fail inside the 21:00 to 24:00 UTC window otherwise |
| Multi-currency (own-currency bind and settle, realised and unrealised FX, revaluation, FX bank reconciliation) | Built | `CURRENCY_REVIEW.md` | No real tenant uses it yet; not accountant-signed |
| In-force portfolio import and opening balances | Built, tested | `20261107140000` to `20261111100000`, `test_ins_import_*.sql`, `insurance-import.spec.ts` | |
| Document pack (`generate-ins-doc`), shared document store | Built, untested end to end | `supabase/functions/generate-ins-doc` | Not exercised in CI (the CI stack does not serve edge functions); needs a first look on a real policy |
| Notifications | Built, tested | `test_ins_notifications.sql` | |
| Security: RPC-only writes, tenant RLS, authorisation catalogue, invoker views | Built, tested | `test_ins_security_hardening.sql`, `test_ins_authz_catalog.sql`, `test_ins_authz_cross_tenant_*.sql`, `test_ins_views_invoker.sql` | |
| Period-close states for insurance (accountant answer 24) | Not started | | Core finance has period controls (`test_fin_period_controls.sql`); insurance-specific states not confirmed |
| Second-approver thresholds (answer 25) | Not started | | |

## Playwright coverage

Specs in `apps/web/e2e/` that exist for insurance: `insurance-import.spec.ts`,
`insurance-cash-commission.spec.ts`, `insurance-claim-payment.spec.ts`. The uncovered list and the
PRs that close it are tracked in `INSURANCE_ACCEPTANCE_PLAN.md` (section 4), not repeated here.

## Documentation that was out of date at this reconciliation

Corrected in the same change as this file, or flagged here for the next reader:

- `README.md` module table listed the statutory charge catalogue and endorsement cancellation (E4) as
  "still open". The catalogue is built; E4 is built on the branch and not yet on `main`.
- `ROADMAP.md` section 7b said the statutory charge catalogue was not started, and section 7c said
  policy creation does not call the resolver and the statutory payable accounts do not exist. Both were
  closed by `20261120004000` and `20261120005000`.
- `ROADMAP.md` section 9a "Not yet built" lists excess, closing-rate revaluation and commission
  receivable; all three are built. Section 9a is history and is left as written.
- `ACCOUNTANT_PACK.md` section 4 question 3 (net-of-commission, "the current design assumes yes")
  contradicts section 5.14 (gross remittance with commission receivable is the decided basis). Logged as
  DR-29 in the decisions register for the owner and accountant to close.

At the 21 November 2026 reconciliation, corrected: the branch table and E4 row in this file (E4 is on
`main`); the `README.md` insurance row (same) and its Playwright count (twelve specs, not eleven;
`bank-adjustments.spec.ts` was missing); the review stamp and hand-off note in `docs/README.md`; the
status of DR-28 in the decisions register; and the evidence for gates E1, E2, E9 and E10 in the
acceptance plan.
