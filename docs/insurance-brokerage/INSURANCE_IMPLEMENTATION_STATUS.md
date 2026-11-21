# Insurance Brokerage: Implementation Status

**Authoritative for:** what is implemented and what test exists for it.
**Not authoritative for:** whether anything is accounting- or legal-approved (see
`INSURANCE_DECISIONS_REGISTER.md`) or what must pass before production (see
`INSURANCE_ACCEPTANCE_PLAN.md`).

Last reconciled: 20 November 2026, against branch `feat/ins-accounting-acceptance` at `cb46e8b`
(9 commits ahead of `main`; `main` has no commits the branch lacks).

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

## Branch state

| Item | On `main` | On `feat/ins-accounting-acceptance` |
|---|---|---|
| Commission recognition declared cases (`20261120001000`) | Yes | Yes |
| Statutory charge catalogue, accounts, on-policy pricing, enforcement setting (`20261120002000` to `20261120235905`) | Yes | Yes |
| **Endorsement cancellation, E4** (`20261120235910`) | **No** | Yes |
| Regenerated `database.types.ts` for E4 (3 RPCs, 6 `cancellation_*` columns) | No | Needed: the committed file lacked these and failed `tsc -b` and the types-drift check |

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
| **Endorsement cancellation E4** | Built, tested (branch only) | `20261120235910`, `test_endorsement_cancellation.sql` | Newest-first only; refused once money has moved. Not merged to `main`. No Playwright spec |
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
| Reports batch 2: commission earned (read from the commission income account, by route, with a month, client, product line, branch or agent grouping) and commission receivable (as at a date, from the commission receivable open items). Server functions and two screens (`/insurance/reports/commission-earned`, `/commission-receivable`) with Excel and PDF export | Built, partly tested | `20261121100000_ins_reports_batch2_commission.sql`, `test_ins_reports_batch2.sql` (earned at placement, ledger tie-out, after a cancellation, receivable empty on the net basis; **not yet run on the full stack**); `CommissionEarned.test.tsx`, `CommissionReceivable.test.tsx` | Definitions DR-39, DR-40. Not exercised by a scenario yet: commission on insurer settlement or premium collection and its reversal, endorsements, imported policies, and receivable with rows (needs the gross-basis fixture in `test_ins_settlement_basis.sql`). Insurer grouping is not offered |
| Reports batch 3: claims register (status, reserve, approved, paid and outstanding as at a date, open or all claims) and claims ageing (open claims by age bucket, optionally by insurer or product line, built on the register). Server functions and two screens (`/insurance/reports/claims-register`, `/claims-ageing`) with Excel and PDF export | Built, partly tested | `20261121110000_ins_reports_batch3_claims.sql`, `test_ins_reports_batch3.sql` (**not yet run against a database**); `ClaimsRegister.test.tsx`, `ClaimsAgeing.test.tsx` (passing) | Definitions DR-41, DR-42. Not exercised by a scenario yet: a back-dated claim, a payment voided after the as-at date, brokerage-managed claims, ageing beyond the first bucket, co-insured policies |
| Reports still to build | Not started | | Cancellations, statutory charges, claims register and ageing, renewal retention, insurer performance, and a dashboard on one summary function |
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
