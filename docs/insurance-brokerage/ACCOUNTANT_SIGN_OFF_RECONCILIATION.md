# Insurance Brokerage: Accountant Sign-off Reconciliation

**Status: owner-confirmed requirements and proposed treatments for professional review. NOT accountant-approved, not legal advice, and not a production authorisation.**

**Repository baseline:** `main` at `323aee28d4bfd9ea34cdfd35a87ec714bd4904ec` (23 November 2026).

**Purpose:** Consolidate the owner's 26-topic requirements discussion, identify conflicts in the existing accountant pack, and give the accountant and compliance adviser a precise review agenda. This document supplements rather than silently overwrites historical decision records. Where it conflicts with older descriptions, the reconciliation below identifies the issue and the required decision.

Related documents:
- `ACCOUNTANT_PACK.md` — existing ledger/event design and historic accountant questions.
- `INSURANCE_DECISIONS_REGISTER.md` — existing DR decision history.
- `INSURANCE_ACCEPTANCE_PLAN.md` — blocking evidence gates.
- `INSURANCE_IMPLEMENTATION_STATUS.md` — implementation inventory (not acceptance evidence).

## 1. Decision-status vocabulary

| Status | Meaning |
|---|---|
| Owner-confirmed requirement | The owner confirmed the intended business practice or system behaviour in the November 2026 discussion. It is not professional accounting or legal approval. |
| Proposed accounting treatment | A suggested ledger treatment requiring accountant review. |
| Implemented (verify) | Repository documentation or code indicates functionality exists; fresh-stack tests and UAT evidence may still be outstanding. |
| Engineering gap | Required behaviour is not evidenced as implemented and needs engineering assessment. |
| Accountant approval pending | A qualified accountant must approve the accounting policy and journal treatment. |
| Legal/compliance approval pending | A qualified Ugandan legal or compliance adviser must confirm statutory interpretation, permissions, obligations or rates. |

No item in this reconciliation is marked accountant-approved or legally approved merely because the owner agreed with it.

## 2. Executive accounting position

### 2.1 Insurer settlement basis

**Owner-confirmed direction:** settlement treatment may vary by insurer agreement and must be selected separately for each insurer agreement (and applied per participating insurer where a policy is co-insured).

**Safe default proposed for the system:** gross insurer payable/remittance. Do not silently deduct broker commission from the amount due to the insurer. A company/insurer agreement must not switch to net settlement merely because a configuration option exists.

**Net settlement exception:** permit only where the specific written insurer agreement has been reviewed and the brokerage's Ugandan compliance/legal adviser has documented that the contractual set-off is lawful in the circumstances, including its relationship to Insurance Act section 90(3). Accountant approval of the resulting accounting treatment is also required. Record the agreement, evidence, approver, effective dates and review/expiry date. If approval is absent, use gross.

This resolves the owner's operational requirement that arrangements vary while preserving the gross basis as the controlled default. It does **not** assert that a net arrangement is lawful.

### 2.2 Commission entitlement/recognition

**Owner-confirmed direction:** the recognition trigger is selectable separately for each insurer agreement. The three modes to be supported are:

1. `at_placement`: commission is unconditional and earned at the agreed placement/binding event.
2. `on_premium_collection`: commission is earned only when the policyholder pays the qualifying premium amount, subject to a precise partial-payment rule approved by the accountant.
3. `on_insurer_settlement`: commission is earned when the insurer settlement event specified in the agreement occurs.

The signed agreement must support the selected trigger. The system must store the trigger and effective date on the agreement and snapshot it onto the policy/insurer share at binding. Later agreement edits must not silently restate existing policies. Voids, credit notes, cancellations, endorsements, clawbacks and partial settlements must reverse or recognise commission consistently with the approved mode.

**Critical distinction:** commission recognition and insurer settlement basis are separate dimensions. Do not infer one from the other. The implementation must support only combinations for which the accountant has approved coherent journals and controls. A configuration matrix and tests are required before production.

### 2.3 Premium received before binding

The existing pack's ordinary receipt entry (Dr 1020 Client Money Bank / Cr 1100 AR) presumes an AR item already exists. It must not be used for money received before the policy receivable is recognised.

**Proposed treatment for accountant review:**
- On receipt before binding: Dr client-money bank; Cr a dedicated client premium advance/unallocated client funds liability (account code and posting role to be confirmed by the accountant).
- On valid policy binding: recognise the policy receivable and insurer obligation/commission under the approved settlement and recognition combination; allocate the advance against the policy receivable through a controlled subledger allocation/reclassification. The exact journal sequence must avoid recognising the same client cash twice.
- If the proposal never binds, refund or allocate the advance under an approved workflow, with full audit trail.

The accountant must confirm whether the client advance is a trust/client-money liability, the appropriate control-account design and how it reconciles to bank and beneficiary balances. Do not invent an account code before reviewing the chart of accounts.

## 3. Owner-confirmed requirements and proposed accounting/control treatment

The numbered topics below record the owner's confirmed direction. Where the item is operational rather than an accounting policy, it remains an ERP requirement and may require legal/accountant review where noted.

| Topic | Owner-confirmed requirement | Treatment / review status |
|---|---|---|
| 1. Premium recognition and collection | Brokerage normally collects premium before or at issuance; exceptional unpaid policies must still be handled. | Bind and receivable recognition must follow enforceable policy/insurer arrangements. Pre-bind receipts require the advance-liability workflow in §2.3. Accountant to confirm recognition point, trust treatment and gross-up. |
| 2. Insurer settlement | Varies by the particular insurer agreement. | Settlement basis selected per agreement. Gross default; net only as documented legal/compliance-approved exception and accountant-approved accounting treatment. |
| 3. Commission recognition | All three triggers are acceptable; selected separately per insurer agreement. | Agreement-level trigger with policy snapshot. Accountant to approve all supported trigger/settlement combinations and partial-payment/reversal mechanics. |
| 4. Co-insurance | Each insurer's participation and financial arrangement is independently represented. | Per-insurer share, lead flag, commission rate, settlement basis and recognition trigger; shares total 100%, exactly one lead. Confirm per-share journals, rounding, return premiums and clawbacks. |
| 5. Claims payment route | Support insurer-direct and brokerage-managed claims. | Insurer-direct: evidence only for cash never handled by broker. Via-broker: recognise insurer receivable/client payable only at approved recognition point; then receipt and payout. |
| 6. Claims excess/deductible | Rules configurable by policy/class/insurer agreement; authorised overrides require reasons. | Show gross approved claim, excess, insurer liability, other deductions and net claimant amount. Accountant to confirm treatment where brokerage handles the funds; legal/claims adviser to confirm policy wording and limits. |
| 7. Partial claim payments | Support multiple partial receipts and payouts, balances, reversals and reconciliation. | Preserve original claim and individual cash movements; do not mark settled until obligations are discharged or adjusted. |
| 8. Claim recoveries | Support claimant overpayment recovery and third-party recoveries. | Engineering gap in current acceptance plan: recovery receivable, repayment schedules, receipts, disputes, write-offs and accounting treatment need design/accountant approval. Distinguish insurer recovery from claimant/third-party recovery. |
| 9. Foreign currency | Policy/agreement may use foreign currency; books remain UGX. Policy rate fixed at the rate taken/agreed for the policy, not later market movements unless agreed. | Store immutable bind rate and UGX equivalent. Pre-bind override allowed to authorised users with reason/approval and full history. Subsequent FX revaluation/realised differences are separate accounting events and do not reprice policy. Accountant to approve monetary-item revaluation and FX journals. |
| 10. Migration cut-over | Adopt formal migration and preserve existing policies as existing business. | Cut-over date is the day immediately before production go-live; new transactions are processed in Vesta Portal from go-live. Preserve inception/expiry, historical transactions and policy version. |
| 11. Migration opening balances | Complete reconciliation is mandatory. | Debits equal credits; each control account ties to policy/client/insurer/claim subledgers; bank balances tie to statements; FX by currency; exceptions resolved before acceptance. |
| 12. Period reopening | Closed periods may be reopened through a controlled process. | Maker-checker: requester and approver different people; reason, evidence, audit trail, impacted transactions and revised reports retained; period reclosed. Accountant to approve period-adjustment policy. |
| 13. Approval limits | Different limits by transaction type and approval role. | Configurable amount/currency/role/branch/effective date and multi-level approvals; prevent transaction splitting; maker-checker and escalation. |
| 14. Manual journals | Permit journals to GL accounts including control accounts, with safeguards. | Balanced journals, maker-checker, reason/evidence, subledger references for control accounts; posted journals immutable and corrected by reversal/adjustment. Prevent unreconciled GL/subledger drift. |
| 15. Financial reports | Excel, PDF and print-friendly outputs. | Reconcile to posted records; identify report date, period, filters and preparer; distinguish draft/pending from posted/approved figures. |
| 16. Management dashboard | Configurable dashboard with production, commission, insurer balances, claims, cash and profitability. | Drill-down and role-based access; actuals separate from forecasts/pending; figures sourced from reconciled reports/posted ledger. |
| 17. Client-money segregation | Strict separation of client money and operating funds; prevent transfers leaving obligations underfunded. | Maintain client-money bank and corresponding liability/subledger; only release legitimately earned commission; enforce availability after all relevant obligations and pending movements. Accountant/compliance adviser to confirm trust structure and permitted transfers. |
| 18. Daily reconciliation | Mandatory daily reconciliation with preparer and independent reviewer. | Reconcile bank, cashbook and beneficiary liabilities; unmatched items, evidence, reviewer and escalation recorded. Define business-day/holiday and bank-feed delay rules. |
| 19. Client-money shortage | Automatically restrict transfers/withdrawals if a shortage is detected. | Confirm shortage against reliable bank/ledger evidence (not a transient feed delay); block commission and non-essential withdrawals, alert management, incident and remediation record; controlled exception only for legally required/essential payments; independent release approval. |

**Numbering note:** the discussion covered 26 sequential topics; this table groups related requirements into 19 control areas for readability. It is not a deletion or reversal of any owner-confirmed requirement.

## 4. Required journal scenarios for accountant review

The following are design scenarios, not final account mappings. Amounts and account codes must be reconciled to the approved chart of accounts and actual application posting rules.

### 4.1 Premium paid before policy bind

Example: client pays UGX 1,000,000 before a policy exists.

| Event | Proposed debit | Proposed credit |
|---|---|---|
| Advance receipt | Client Money Bank | Client Premium Advances / Unallocated Client Funds liability (new role/code to approve) |
| Policy subsequently binds | Recognise AR and insurer/commission balances according to approved agreement settings; allocate the advance against AR without a second cash receipt | Exact journal sequence to be approved |

Accountant to decide whether the liability is held at client, policy proposal, insurer or suspense subledger level and how unmatched advances are aged and refunded.

### 4.2 Gross settlement illustration

Example only: gross premium UGX 1,000,000 and commission UGX 100,000.

Under a gross model, the insurer payable is not reduced by commission. The gross payable and commission receivable/entitlement must be represented separately according to the approved commission-recognition trigger. If entitlement is not yet earned, it must not be credited prematurely to commission income. The existing pack's section 5.14 entry (Dr AR gross; Cr insurer payable gross; Dr commission receivable; Cr commission income) must therefore be reconciled with the agreement's commission trigger and the underlying receivable/payable subledgers before being treated as universal.

### 4.3 Net settlement exception illustration

Example only: gross premium UGX 1,000,000, commission UGX 100,000, net cash remitted UGX 900,000.

Do not enable this treatment until the specific written agreement and legal/compliance opinion support set-off under applicable Ugandan law, and the accountant approves the journals. The system must preserve gross premium, gross insurer entitlement, commission amount, set-off amount and net cash movement as separately traceable facts. Do not hide netting by recording only a UGX 900,000 payable.

### 4.4 Claims

For brokerage-managed claims, the existing pack proposes Dr insurer claims receivable / Cr claims payable when insurer written confirmation is recorded, followed by Dr client-money bank / Cr insurer claims receivable on receipt and Dr claims payable / Cr client-money bank on payout. Accountant to confirm recognition criteria, excess allocation, partial receipts, overpayments and recoveries.

### 4.5 Client-money control

The accountant must approve the complete reconciliation equation, including:
- bank balances and outstanding bank items;
- client/insurer/beneficiary obligations;
- unallocated client advances;
- statutory amounts held for remittance;
- claims funds held for claimants;
- commission that is earned and legally available for transfer;
- pending transfers, reversals and refunds.

Do not equate bank cash with freely available brokerage funds.

## 5. Contradictions and corrections required in the legacy pack

| Existing pack location | Conflict / risk | Required resolution |
|---|---|---|
| §3 decision 1 and §5.1 | Describes commission as deducted from gross to calculate a net insurer payable. | Superseded as a universal rule by agreement-specific settlement basis; gross is safe default. Preserve historic policy snapshots and explicitly approved net exceptions. |
| §3 decisions 3–4 and §5.2 | Describes all commission as deferred until full insurer settlement. | Superseded as universal rule by three agreement-level recognition triggers. Define partial receipt, void, credit note and partial settlement behaviour for each mode. |
| §4 Q3 and §5.14 | Q3 describes net remittance as current assumption; §5.14 says gross is owner's decision and net is legal-review gated. | Rewrite Q3 as a legal/compliance question on whether a specific written agreement may lawfully provide set-off under s.90(3). Gross remains default. |
| §5.14 bind journal | Recognises commission receivable and income at bind, potentially contradicting collection- or settlement-trigger agreements. | Journal must be conditional on recognition trigger; separate entitlement/receivable from earned income and deferred commission. Accountant to approve complete matrix. |
| §5.6 receipt entry | Credits AR on all receipts, including the possibility of a pre-bind advance. | Add a distinct advance/unallocated receipt path; do not credit AR before the receivable exists. |
| §5.6 remittance cap | Legacy cap deducts commission already transferred and uses net cash logic. | Reconcile with gross default, agreement-specific set-off exceptions and client-money availability equation. |
| §5.7 co-insurance | Uses payable = share premium − commission + pass-through charges. | Reconcile each insurer share to its own settlement basis and recognition trigger. Ensure statutory pass-through treatment is not confused with brokerage commission. |
| §5.8 cancellation | Clearing account, transferred clawback due and retained commission are not fully accountant-approved. | Accountant must approve cancellation journal examples by trigger, gross/net basis, settlement status, cash movement and commission-transfer status. |
| §5.10 claims | Withdrawal, overpayment and recovery explicitly not built. | Add recovery accounting and acceptance gates before brokerage-managed claims can be considered fully complete. |
| §5.13 commission modes | Recognition modes are described, but their interaction with gross settlement/commission receivable is unclear. | Replace narrative with a validated combination matrix and worked journals. |
| §5.14 statutory remittance | Says statutory payable accounts remain unused; brokerage-held statutory remittance not built. | No charge collected by brokerage may be activated until liability, remittance, reconciliation and cancellation treatment are built and legally validated. |

## 6. Accountant decisions required

The accountant should respond to each item in writing and reference the exact agreement, policy or statutory basis where applicable.

| Ref | Decision requested | Evidence / deliverable |
|---|---|---|
| ACC-01 | Approve premium recognition point and enforceable receivable criteria at bind. | Written accounting policy and bind journal. |
| ACC-02 | Approve pre-bind client advance liability, subledger and allocation/refund workflow. | Account code/role, journal examples and reconciliation. |
| ACC-03 | Approve gross settlement as standard accounting basis and the gross payable/commission receivable presentation. | Signed journal examples and balance-sheet presentation. |
| ACC-04 | Confirm whether any insurer-specific contractual set-off may be recognised, conditional on separate legal opinion. | Accountant's treatment plus legal opinion; no net option without both. |
| ACC-05 | Approve all commission trigger modes and their interactions with gross/net basis, co-insurance, partial collections, voids, credit notes and cancellations. | Decision matrix and worked journals for every supported combination. |
| ACC-06 | Confirm co-insurance share accounting, rounding, return premium and insurer-by-insurer settlement. | Worked multi-insurer examples. |
| ACC-07 | Confirm client-money bank/liability accounting and available-funds calculation, including advances, statutory collections and claim funds. | Approved trust/client-money reconciliation equation. |
| ACC-08 | Confirm cancellation clearing, retained commission, clawback of earned/transferred commission and refund journals. | Worked cases for unsettled, partially settled and settled policies. |
| ACC-09 | Confirm claim recognition, excess, partial settlements, overpayments, recoveries and write-offs. | Claim accounting policy and journal scenarios. |
| ACC-10 | Confirm FX policy: transaction rate lock, revaluation, realised differences, voids at original rate and rounding. | Currency journal examples and account mapping. |
| ACC-11 | Confirm opening-balance and in-force migration accounting, including earned/unearned commission and existing receipts. | Opening trial balance and policy-level reconciliation design. |
| ACC-12 | Confirm period close/reopen, backdating and adjustment journal policy. | Close/reopen control policy. |
| ACC-13 | Confirm manual journal access to control accounts and required subledger safeguards. | Approved journal control matrix. |
| ACC-14 | Confirm VAT/WHT and broker-fee classification, insurer commission and intermediary commission tax treatment. | Current tax advice and approved tax-code matrix. |
| ACC-15 | Confirm statutory charge accounting, recipient, collector, payable accounts, refunds and remittance. | Instrument-backed charge schedule and journals. |
| ACC-16 | Confirm reporting basis and reconciliation of dashboard/report measures to the GL. | Approved report definitions and tie-out evidence. |

## 7. Legal and compliance decisions required

These are not questions for the accountant alone.

1. Obtain a current Ugandan legal/compliance opinion on Insurance Act section 90(3), including the gross remittance requirement and whether a particular insurer agreement can lawfully create set-off.
2. Confirm which statutory charges the brokerage itself must collect and remit, versus charges collected/remitted by insurers.
3. Verify every rate and effective date against the actual legal instrument before enabling billing.
4. Confirm client-money/trust account obligations, segregation, permitted withdrawals, reconciliation frequency and shortage response under current Ugandan law and IRA requirements.
5. Confirm cancellation/return-premium rules and statutory charge refundability by charge type.
6. Confirm retention and recordkeeping requirements, including any IRA circulars and statutory retention periods.
7. Confirm any requirements for intermediary/agent commission, WHT, sub-agency and payment restrictions before enabling those workflows.

No rate, tax character, remittance deadline or legal exception should be activated solely because it is present in seeded configuration or mentioned in an older draft.

## 8. Engineering and UAT work required

The acceptance plan remains authoritative for production gates. Add or retain explicit gates for:

- Pre-bind client advances and allocation/refund.
- Agreement-level settlement and commission-recognition matrix, with immutable policy snapshots.
- Gross default and blocked net exception unless agreement evidence and legal/compliance approval are recorded.
- Co-insurance combinations across different insurer agreements.
- Claim recovery, overpayment and third-party recovery.
- Daily client-money reconciliation with independent reviewer.
- Confirmed shortage restrictions, incident workflow and controlled release.
- Two-person period reopening.
- Configurable approval thresholds and anti-splitting controls.
- Manual journals to control accounts with subledger tie-out safeguards.
- Report exports, print output and dashboard-to-ledger tie-outs.
- Migration opening balance, policy and currency reconciliation.
- Fresh-stack SQL, component, integration and Playwright evidence.

A feature being present in code or a test being written is not a passed acceptance gate. Record the run URL, environment, commit SHA, date, result and reviewer.

## 9. Accountant sign-off form

The accountant should complete this section after reviewing the underlying chart of accounts, migrations, posting functions, reports, sample transactions and UAT evidence.

| Ref | Accountant decision (Approve / Amend / Reject) | Conditions / comments | Name and qualification | Signature | Date |
|---|---|---|---|---|---|
| ACC-01 to ACC-04 | | | | | |
| ACC-05 to ACC-08 | | | | | |
| ACC-09 to ACC-12 | | | | | |
| ACC-13 to ACC-16 | | | | | |

**Overall conclusion:** ☐ Approved for UAT only ☐ Approved for production subject to listed conditions ☐ Not approved

**Conditions outstanding:** 

**Accountant's confirmation:** I have reviewed the accounting policies and example postings identified above. My approval applies only to the stated scope and conditions; it does not certify legal compliance, software security, operational readiness or matters outside my professional engagement.

Name: ______________________________

Professional designation / membership: ______________________________

Signature: ______________________________

Date: ______________________________

## 10. Owner confirmation

The owner confirms the business requirements in section 3 as the intended direction for Vesta Portal. This confirmation is not accountant sign-off or legal approval.

Owner: ______________________________

Signature: ______________________________

Date: ______________________________
