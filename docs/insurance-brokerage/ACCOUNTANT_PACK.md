# Insurance Brokerage: Accounting Policy & Sign-off Pack

**Document version:** 2.0
**Date:** 23 November 2026
**Status:** Draft — for Accountant and Legal review
**Supersedes:** `ACCOUNTANT_PACK_v1_superseded.md` (the 16 October 2026 pack, kept for history and not to be reviewed)
**Companion documents:**
- `ACCOUNT_MAPPING_APPENDIX.md` — every policy paragraph mapped to its posting role and account code
- `signoff-register.json` — the machine-readable register; section 16 below is generated from it
- `INSURANCE_DECISIONS_REGISTER.md` — owner decisions DR-1 onwards

---

## 1. What the reviewer is being asked to do

Approve the **accounting policy for production** — the treatments, mappings, recognition rules and
financial controls this brokerage intends to use. Version 2 is the policy of record; version 1 is
withdrawn.

Three approvals are deliberately kept separate, because they fail for different reasons:

| Gate | Who | What it means |
|---|---|---|
| **1. Accounting policy approval** | Accountant (+ legal/tax where A-ref says so) | The intended treatment, account mappings, recognition rules and controls are professionally acceptable. Does **not** require every feature to be built. |
| **2. UAT acceptance** | Business / finance users | The implemented workflows work as the policy describes, including the committed-but-unbuilt items scoped into UAT. |
| **3. Production go-live** | Engineering, finance, compliance jointly | Every control the policy treats as mandatory is implemented and tested. No B-item blocking go-live is open. |

This means the accountant can approve the policy while controls in section 16.2 are still being
built — that is intentional and is what the B-register is for. It also means nothing in 16.2 that
blocks go-live may be quietly dropped: it is a production gate, not a wish list.

**A caution the reviewer should read before signing.** The software is already opinionated. Where
this policy differs from what is built, the difference is recorded against the item: `code_state`
is `built`, `partial` or `not_built`, and every `partial`/`not_built` appears in the B-register. A
green CI run on the register proves the settings and evidence files exist; it does **not** prove the
accounting behaves as described. Only the evidence files and the reviewer's own checks do that.

---

## 2. Accounting design principles

1. Gross premium, insurer liability and brokerage commission must be separately identifiable.
2. Commission recognition follows the agreed contractual trigger for that insurer agreement.
3. Client money is separate from brokerage operating money, in the bank and in the ledger.
4. Receipts, payments, reversals and adjustments carry a complete audit trail; posted entries are
   never edited, only reversed.
5. Every entry reconciles to its underlying policy, insurer, client or claim record.
6. Historical transactions are not duplicated during migration.
7. Treatments that vary by insurer agreement are configurable — but configuration may never be
   silent. Where the policy requires a choice, the software must refuse to proceed without one.
8. Financial postings are subject to maker-checker controls.
9. No configuration may override a statutory or contractual requirement.
10. Unapproved treatments remain identifiable and are never represented as professionally approved.

Principle 7 is new in version 2 and is the substance of decision 2 below: an accounting setting
with a default that nobody chose is indistinguishable from a decision nobody made.

---

## 3. Premium recognition and collection

### 3.1 Policy

Premium is normally collected before or at issuance.

- Once a policy is validly bound, recognise the premium and the insurer obligation under the
  approved settlement basis (§4).
- Where the client pays after bind, allocate the receipt against the client receivable.
- Where the client pays **before** bind, record the amount as an unallocated client advance — a
  liability — not as revenue and not as unallocated cash.
- When the policy binds, allocate the advance to that policy's receivable.
- Outstanding client balances remain visible until settled.

### 3.2 Flow

**Before bind**

| Account | Debit | Credit |
|---|---|---|
| 1020 Client Money Bank | amount received | |
| **2040 Unallocated Client Advances** | | amount received |

**At bind** — recognise under §4, then allocate the advance against the policy receivable
(Dr 2040 · Cr 1100).

**After bind**

| Account | Debit | Credit |
|---|---|---|
| 1020 Client Money Bank | receipt | |
| 1100 AR Control | | receipt |

Account 2040 does not exist in the chart today; it is proposed in the mapping appendix, and the
release-on-bind path is B2.

### 3.3 Confirmations required

Recognition date for premium receivables and for insurer obligations; treatment of unallocated
advances; client-money liability presentation; treatment of unpaid and partially paid premiums.

---

## 4. Insurer settlement and commission

### 4.1 Gross settlement — the basis

The insurer payable is booked **gross**, with commission a separate receivable from the insurer —
never a deduction from what the insurer is owed. The bind posts Dr 1100 gross · Cr 2010 gross ·
Dr 1110 commission · Cr 4000 or 2020.

Gross is the decided basis: Insurance Act s.90(3) requires premium to be remitted "without any
deductions of commissions". The software setting is `ins.insurer_remittance_basis`, default
`gross_premium`, legal-review-gated.

### 4.2 Net settlement — controlled exception

Net settlement may be configured only where a documented insurer agreement supports it, legal
review confirms it is permissible, the accountant approves the treatment, the configuration is
specific to that insurer agreement, and it carries an effective date and audit history. It never
erases the gross premium and commission records.

**Open for legal:** whether any insurer agreement may lawfully set off commission without
conflicting with s.90(3), and in what circumstances.

### 4.3 Commission recognition — four modes

Selectable per insurer agreement.

| Mode | Earned when | At bind |
|---|---|---|
| `at_placement` | policy validly bound, entitlement unconditional | Dr 1110 · Cr 4000 |
| `on_premium_collection` | the client's receipt covers the premium (binary — a partial receipt earns nothing) | Dr 1110 · Cr 2020 |
| `pro_rata_on_collection` | proportionally to premium collected | Dr 1110 · Cr 2020, released per receipt |
| `on_insurer_settlement` | the insurer's item is settled | Dr 1110 · Cr 2020, then Dr 2020 · Cr 4000 |
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs

**Pro-rata worked example (the mode that is not built yet — B1)**

| Description | Amount |
|---|---|
| Premium | UGX 1,000,000 |
| Commission rate | 10% |
| Total commission | UGX 100,000 |
| First collection | UGX 500,000 |
| Commission recognised | UGX 50,000 |
| Commission deferred (2020) | UGX 50,000 |

Receipt reversals and refunds trigger corresponding commission adjustments at the same booked
rate. Voiding a receipt un-earns what that receipt earned and never leaves income standing on
money that came back.

### 4.4 No silent default
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours

Every policy must have an explicit recognition mode in force at bind. Binding a policy whose
insurer agreement has no configured mode **fails** and names the insurer and the missing setting.
`on_insurer_settlement` remains available but must be chosen; it is no longer a fallback. This is
B3, and it is the change that makes the per-agreement classification in this section actually
load-bearing.

### 4.5 Settlement and recognition are separate dimensions

Not every combination is sensible. Gross settlement with `on_premium_collection` or
`pro_rata_on_collection` cannot coexist — under gross the premium crosses in full, so there is
nothing left to collect — and the software refuses the combination by name at bind rather than
silently choosing one. The remainder of the compatibility matrix is for the accountant to approve,
particularly where net settlement changes the timing or legal basis of the entitlement.

### 4.6 Confirmations required

Which insurer agreements are `at_placement`, `on_premium_collection`, `pro_rata_on_collection` or
`on_insurer_settlement`; that the collection triggers are the **client's** receipt and not the
insurer's settlement or a credit note; that a voided receipt reverses recognition; the
compatibility matrix; and the deferred-commission and income accounts.

---

## 5. Cancellations, refunds and clawbacks

### 5.1 Principles

A cancellation preserves the original policy and financial history. The system records three
separate dates: cancellation requested, cancellation effective, and financial settlement. The
effective date must be supported by insurer confirmation or another appropriate authority.
Backdated cancellations require evidence, a reason and authorised approval. Closed periods are
never silently rewritten.

Three dates are policy; only `effective_date` is modelled today — that is B4.

### 5.2 Return premium

Distinguish: return premium requested, approved, actually received or credited; client refund
payable; client refund actually paid; deductions and charges. An approved refund is never treated
as cash received, and no insurer receivable is created merely because a refund was requested. A
separate client refund obligation may still arise where the brokerage has an independent
contractual or legal duty to refund.

### 5.3 Deductions are never automatically income

| Deduction | Belongs to |
|---|---|
| Insurer-retained short-period premium | the insurer |
| Brokerage cancellation fee | the brokerage, only where contractually authorised |
| Statutory charges | the relevant statutory recipient |
| Other authorised deductions | the appropriate beneficiary |

The difference between original and return premium never becomes brokerage income by default.

### 5.4 Commission clawback

Proportional to the **approved** return premium, and never more than commission previously
recognised. Where commission has already been transferred to operating funds, record the clawback
against the original transaction, identify what is recoverable from operating funds, replenish
client money where necessary, block further transfers if the client-money position is deficient,
and require approval with a retained audit trail.

In the ledger the clawback is absorbed in a fixed order: the deferred pool (2020) first, then
recognised income (4000), then a recoverable from operating funds. Those are three different
movements, not one.

### 5.5 Confirmations required

Credit-note and reversal entries; whether returned commission goes back to deferred or reverses
income; treatment of transferred commission; approved-but-unpaid return premiums; the accounting
date for a backdated cancellation; cancellation after insurer settlement.

---

## 6. Co-insurance

Each participating insurer has independent records for participation percentage, lead status,
commission rate, settlement method, recognition trigger, tax treatment, receipts and outstanding
balances, and cancellation adjustments. Shares must total 100% with exactly one lead insurer;
both are enforced at bind.

The accountant must approve the allocation of premium, commission, insurer liabilities, receipts,
remittances and cancellation adjustments across participants.

---

## 7. Claims

### 7.1 Operating models

**Insurer-direct** — the insurer pays the claimant. The system records administration, the
insurer's decision and payment evidence, and creates **no** brokerage cash, bank or payable entry
for funds it never handled.

**Brokerage-managed** — the brokerage receives insurer funds and pays claimants. The system
records the insurer receivable (1120), funds received, the claimant payable (2030) and payments.

### 7.2 Stages

The policy recognises eight stages — reported, assessed, internally approved, insurer confirmed,
funded, partially paid, fully paid, closed — plus two states, **Coverage under review** and
**Payment disputed**. Internal approval alone never creates a payment posting.

Today the schema has six (`notified, assessing, approved, settled, repudiated, closed`) and
neither review state. The extension is B5 and blocks UAT acceptance.

### 7.3–7.7 Review, late notification, death claims, instalments, recoveries

A claim arising while a cancellation effective date is disputed is registered and marked
*Coverage under review*; it is never auto-rejected and no insurer liability is recognised before
confirmation. A claim registered after expiry is accepted where the insured event occurred during
cover, recording incident date, client notification, insurer notification and insurer
acknowledgement, and is flagged for review rather than rejected.

Authorised representatives may report a claim after the policyholder's death. Multiple
beneficiaries are supported on percentage or fixed allocations; percentages must total 100%;
disputed shares are held until insurer confirmation or legal determination while undisputed shares
may proceed; disputed shares are never redistributed automatically.

Instalments each carry their own expected date, actual payment date, amount and evidence, and a
subsequent receipt settles the existing approved balance rather than creating fresh recognition. A
disputed direct payment is marked *Payment disputed* until resolved, with the original evidence and
the dispute retained.

Excess rules are configurable by policy terms, class, insurer agreement and claim type; authorised
overrides require reasons and audit history. Recoveries cover overpayments, third-party recoveries,
insurer underpayments, instalment recoveries, disputes and authorised write-offs.

Beneficiaries, death claims, instalments, extended stages and recoveries are all unbuilt — B10,
B5, B8. They are in the register precisely so that approving this section is not mistaken for
certifying them.

### 7.8 Confirmations required

Recognition date and entries for insurer-confirmed claims, brokerage-managed claims, excess,
recoveries, overpayments, write-offs and claim reversals.

---

## 8. Foreign currency

The books remain in UGX. The rate used at bind is preserved and is not replaced by later market
rates except through an authorised amendment or reversal. The system tracks the transaction
currency and value, the UGX equivalent at bind, the settlement rate and realised and unrealised
gain or loss separately.

Rate overrides before bind require authority, reason and audit history; once bound the rate is
locked. Realised and unrealised are separate accounts (4900/4901 gains, 5910/5911 losses, 5900
rounding).

The accountant must confirm exchange-rate sources, revaluation frequency, entries and presentation.

---

## 9. Migration and opening balances

### 9.1 Cut-over

The cut-over date is the day before production go-live. Transactions after cut-over go through the
system. Existing policies are imported as existing business with original inception and expiry
preserved — never as newly issued. Migrated policies retain accounting-policy version 1 unless an
approved migration process says otherwise. Every migrated record carries a migration identifier and
traceable source.

### 9.2 What the migration must distinguish

Historical premium bills, historical receipts, outstanding client receivables, outstanding insurer
payables, commission earned before cut-over, commission deferred at cut-over, claims receivable and
payable, statutory liabilities and foreign-currency balances. Receipts and bills already represented
in opening balances are not re-posted.

### 9.3 Reconciliation before approval

| Area | Required reconciliation |
|---|---|
| General ledger | balanced trial balance |
| Client receivables | to client and policy records |
| Insurer payables | to insurer and policy records |
| Bank balances | to bank statements |
| Commission | earned and deferred, per policy/agreement |
| Claims | receivable and payable per claim |
| Statutory liabilities | balances per recipient |
| Foreign currency | balances per currency |

Material unexplained differences prevent migration approval. Opening balances post through 3900,
which must net to zero, with commission earned up to cut-over carried in 3200 and only the unearned
remainder in 2020.

---

## 10. Accounting periods and manual journals

### 10.1 Period reopening

A closed period may be reopened only with a documented reason, appropriate senior finance approval,
independent maker-checker approval, audit history of all changes, period reclosure and retention of
the revised period-end reports. The requester never approves their own reopening.

### 10.2 Manual journals

Balanced entries; finance maker and independent checker; supporting evidence and reason; subledger
references for control-account journals; immutable posted entries; reversal or authorised adjustment
instead of editing; additional approval for restricted accounts. A manual journal must never silently
create a difference between the general ledger and an operational subledger.

There is no manual-journal path today (B6); corrections outside the documented flows currently
require raw SQL, which has no maker-checker and no subledger reference. That is why it blocks go-live.

### 10.3 Business day (DR-46)

Accounting dates follow the **Africa/Kampala** business day, not the database's UTC date. Posting
dates, the voidable date of a receipt, the closed-period test, accounting-setting lookups and
statutory-parameter lookups all resolve against the Kampala day. This decides which period a
transaction between 00:00 and 03:00 Kampala time falls into, and it applies platform-wide from
migrations `20261122090000` and `20261122100000`. A17.

---

## 11. Financial approval limits

Thresholds are configurable by transaction type, amount, currency, role, approval level and branch,
and apply separately to refunds, insurer remittances, commission transfers, claim payments,
intermediary commissions and manual journals, with multi-level approval, escalation, effective dates
and audit history. Splitting a transaction to stay under a threshold must be prevented.

Maker-checker per transaction type exists; amount-based limits and split detection do not (B7), and
this is the item most likely to block the production gate.

---

## 12. Statutory charges and taxation

### 12.1 The catalogue

Each charge names its legal basis, applicable class, calculation basis, rate or fixed amount,
exemptions, collection responsibility, remittance responsibility, statutory recipient, liability
account and effective date. A rate cannot be marked verified without citing the instrument that
verified it.

| Charge | Rate | Verified | Billed |
|---|---|---|---|
| Insurance Training Levy | 0.5% of gross direct premium | **Yes** — Insurance Act s.141(3), SI No. 100 of 2020 reg. 17(2) | Yes |
| IRA regulatory levy | 1.5% (unconfirmed) | No — press summaries only | **No**, inactive |
| Stamp duty, general policy | UGX 35,000 (unconfirmed) | No — press summaries only | **No**, inactive |

No unverified charge is active as a mandatory production charge. Enforcement is `advisory` by
default: turning it to `required` makes bind refuse a policy whose charges were not priced and
acknowledged, and raises the premium of every policy bound from then on — a commercial decision,
which is why it is not the default.

### 12.2 Brokerage fees

A brokerage fee is a distinct supply from premium and from a statutory charge, recognised in 4100,
and is **VAT-exempt by default** as an insurance service (VAT Act Cap 344, Schedule 3). A separate
non-brokerage service is classified `other_taxable_service` with a stated reason and is
standard-rated. Classification, not a company-wide switch, governs the treatment — the former
`ins.broker_fee_vat` setting is withdrawn (decision 5).

Fees invoiced before 17 November 2026 under the old 18% treatment keep their VAT, because that
output tax was declared.

### 12.3 Intermediary commission taxation

Treatment is configurable per agreement; the system does not assume every intermediary commission
carries identical withholding. Withheld tax is an asset (1210), never a reduction of revenue and
never a liability of the brokerage.

---

## 13. Intermediary commission

Intermediary registration, agency agreements and commission accrual/payment are separate concerns.
The register distinguishes insurer-appointed agents, independent brokers, sub-agents and referral
partners, each agreement carrying its own rates, tax settings and accrual trigger. The agent's share
is an **expense (5010)**, not a netting of the brokerage's own commission, so both the gross
commission and the agent cost remain visible. Agents are never treated as employees.

Accrual and payment remain subject to the accountant's approval of the treatment and legal
confirmation of applicable Ugandan sub-agency requirements.

---

## 14. Client-money protection

### 14.1 Separation
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs

Separate client-money and operating bank accounts, corresponding liability and control accounts,
tracking of funds owed to insurers, clients and beneficiaries, prevention of transfers that would
leave the client-money account short, commission transfers only where entitlement is established,
and approvals with audit history.

Segregation is enforced in the schema today: a bank account cannot change between operating and
client money, and two bank accounts cannot share a GL account.
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours

### 14.2 Daily reconciliation

A designated finance officer completes a daily client-money reconciliation comparing bank balance,
cashbook, client-money liabilities, unallocated advances, available commission and unmatched items;
a separate person independently reviews it; missed reconciliations are escalated.

### 14.3 Shortage response

A suspected shortage raises a high-priority alert and an incident record, notifies management,
restricts commission transfers and non-essential withdrawals, and requires independent approval to
release those restrictions. The system must distinguish a genuine shortage from a delayed bank feed.
Essential or legally required payments follow a controlled exception process.

The position test at transfer time, the daily artefact, reviewer independence and the incident flow
are B9 and block go-live.

---

## 15. Financial reporting

PDF and Excel exports and printable layouts; filters for date and period, branch, class, insurer,
client and currency; every report identifies its generation date and user and distinguishes draft,
pending, approved and posted.

=======

Separate client-money and operating bank accounts, corresponding liability and control accounts,
tracking of funds owed to insurers, clients and beneficiaries, prevention of transfers that would
leave the client-money account short, commission transfers only where entitlement is established,
and approvals with audit history.

Segregation is enforced in the schema today: a bank account cannot change between operating and
client money, and two bank accounts cannot share a GL account.

### 14.2 Daily reconciliation

A designated finance officer completes a daily client-money reconciliation comparing bank balance,
cashbook, client-money liabilities, unallocated advances, available commission and unmatched items;
a separate person independently reviews it; missed reconciliations are escalated.

### 14.3 Shortage response

A suspected shortage raises a high-priority alert and an incident record, notifies management,
restricts commission transfers and non-essential withdrawals, and requires independent approval to
release those restrictions. The system must distinguish a genuine shortage from a delayed bank feed.
Essential or legally required payments follow a controlled exception process.

The position test at transfer time, the daily artefact, reviewer independence and the incident flow
are B9 and block go-live.

---

## 15. Financial reporting

PDF and Excel exports and printable layouts; filters for date and period, branch, class, insurer,
client and currency; every report identifies its generation date and user and distinguishes draft,
pending, approved and posted.

>>>>>>> theirs
The dashboard covers premium production, earned and deferred commission, client receivables, insurer
balances and remittances, claims exposure, cancellations and refunds, client-money and operating-bank
positions, foreign exchange, and profitability by branch, insurer and class, with actual, forecast and
pending amounts distinguished.

All financial reports reconcile to the general ledger and supporting subledgers.

---

## 16. Sign-off register

The tables below are generated from `signoff-register.json`. The JSON is the source of truth; CI
checks that every setting named exists, that the value claimed as approved is one the database
allows, and that every evidence file cited exists. Edit the JSON and run
`node scripts/gen-signoff-register.mjs`; never edit the block by hand.

<!-- BEGIN GENERATED: SIGN-OFF REGISTER -->
<!-- Do not edit by hand. Edit docs/insurance-brokerage/signoff-register.json and run
     node scripts/gen-signoff-register.mjs -->

### 16.1 Accounting policy items (A-register)

Each item is the accounting treatment the software is expected to implement. `reviewed_at`
is filled only when the appointed reviewer has signed that item in section 18.

| Ref | Decision area | Approver | Code | Selected settings | Required before | Evidence |
|---|---|---|---|---|---|---|
| **A1** | Premium recognition and pre-binding advances | accountant | Partly built | — | UAT acceptance | — |
| **A2** | Insurer settlement: gross basis and net exceptions | accountant + legal | Built | `ins.insurer_remittance_basis` = **gross_premium** | production go-live | `test_ins_settlement_basis.sql`<br>`test_ins_commission.sql` |
| **A3** | Commission recognition methods | accountant | Partly built | `ins.commission_recognition` = **explicit_per_agreement** *(not yet implemented)* | UAT acceptance | `test_ins_commission_recognition_mode.sql`<br>`test_ins_commission_on_premium_collection.sql`<br>`test_ins_commission_pro_rata.sql` |
| **A4** | Partial collection and commission clawbacks | accountant | Partly built | `ins.commission_recognition` = **pro_rata_on_collection** *(not yet implemented)* | UAT acceptance | `test_ins_commission_pro_rata.sql`<br>`test_ins_cancellation_posting.sql` |
| **A5** | Co-insurance accounting | accountant | Built | — | production go-live | `test_ins_coinsurance_charges.sql` |
| **A6** | Cancellation, refunds and return premium | accountant | Built | `ins.cancellation_treatment` = **pro_rata_refund** | production go-live | `test_ins_cancellation_calculation.sql`<br>`test_ins_cancellation_posting.sql`<br>`test_ins_cancellation_cash.sql` |
| **A7** | Claims accounting and recoveries | accountant | Partly built | — | production go-live | `test_ins_claim_payments.sql`<br>`test_ins_claim_reserve_revisions.sql`<br>`test_ins_claim_documents.sql` |
| **A8** | Foreign currency and revaluation | accountant | Built | — | production go-live | `test_foreign_bind_transfer.sql`<br>`test_foreign_cancellation.sql`<br>`test_foreign_claims.sql` |
| **A9** | Migration and opening balances | accountant | Built | `migration.earned_commission_treatment` = **opening_balances**<br>`migration.partially_paid_import` = **full_billed_plus_receipts** | production go-live | `test_ins_import_opening_from_history.sql`<br>`test_ins_import_control_totals.sql`<br>`test_ins_opening_acceptance_gate.sql` |
| **A10** | Accounting periods and manual journals | accountant | Partly built | — | production go-live | `test_fin_period_controls.sql` |
| **A11** | Financial approval limits | accountant | Not built | — | production go-live | `test_ins_finance_pending_approvals.sql` |
| **A12** | Client-money accounting and reconciliation | accountant | Partly built | — | production go-live | `test_fin_bank_accounts.sql`<br>`test_bank_reconciliation.sql`<br>`test_ins_policy_cash.sql` |
| **A13** | Statutory charges and remittances | accountant + legal | Built | `ins.statutory_charge_enforcement` = **advisory** | production go-live | `test_ins_statutory_charge_catalogue.sql`<br>`test_ins_statutory_charges_on_policy.sql`<br>`test_ins_statutory_charge_trace.sql` |
| **A14** | VAT, withholding tax and broker-fee classification | accountant + tax | Built | `ins.agent_commission_taxable` = **taxable**<br>`ins.agent_commission_wht` = **applicable**<br>`ins.agent_commission_basis` = **gross_commission** | production go-live | `test_ins_client_broker_fees.sql`<br>`test_ins_agent_commission.sql`<br>`test_wht_posting.sql` |
| **A15** | Intermediary commission accounting | accountant + legal | Built | — | production go-live | `test_ins_agent_commission.sql`<br>`test_ins_intermediaries.sql` |
| **A16** | Financial reporting and reconciliation | accountant | Built | — | production go-live | `test_ins_reports_batch1.sql`<br>`test_ins_reports_batch2.sql`<br>`test_ins_reports_batch3.sql`<br>`test_ins_reports_batch4.sql`<br>`test_ins_dashboard_summary.sql` |
| **A17** | Business day and posting-date rules (DR-46) | accountant | Built | — | production go-live | `test_fin_period_controls.sql`<br>`test_ins_reports_batch1.sql` |
| **A18** | Endorsement cancellation and financial reversal | accountant | Built | — | production go-live | `test_endorsement_cancellation.sql`<br>`test_endorsement_posting.sql` |
| **A19** | Opening position, retained earnings and migration balancing | accountant | Built | `migration.earned_commission_treatment` = **opening_balances** | production go-live | `test_ins_import_opening_from_history.sql`<br>`test_ins_opening_acceptance_gate.sql` |
| **A20** | Broker-fee classification and its accounting and tax treatment | accountant + tax | Built | — | production go-live | `test_ins_client_broker_fees.sql` |

### 16.2 Committed but not built (B-register)

These are controls and features the policy assumes. **They are not built.** The reviewer is
asked to approve the *policy* in §16.1 while acknowledging these as committed work with the
gate shown. An item blocking "production go-live" must be complete before live posting; an
item blocking "UAT acceptance" must be complete before the business signs UAT.

| Ref | Feature | Status | Depends on | Blocks | Acceptance criteria |
|---|---|---|---|---|---|
| **B1** | pro_rata_on_collection commission recognition | Not built | A3, A4 | UAT acceptance | A partial collection of 50% of premium earns exactly 50% of commission, the remainder stays in 2020, a further collection earns the balance, and voiding a receipt reverses only the portion that receipt earned. |
| **B2** | Unallocated client advances | Not built | A1 | UAT acceptance | A receipt with no policy creates a 2040 credit and no receivable; binding a policy allocates it and clears 2040; an unallocated advance is visible on the client statement as a liability and is refundable. |
| **B3** | Fail-closed commission-mode selection | Not built | A3 | UAT acceptance | A policy on an insurer with no configured mode cannot bind and the error names the insurer and the missing setting; configuring the mode allows the bind and the chosen mode is frozen into the accounting snapshot. |
| **B4** | Three cancellation dates | Not built | A6 | UAT acceptance | A cancellation requested in period 1, effective in period 2 and settled in period 3 posts to the settlement period while reporting its effective date; a backdated effective date without evidence is refused. |
| **B5** | Claim stage model and the two review states (built) | built | A7 | UAT acceptance | A claim moves through all eight stages with an audit row each; internal approval creates no journal; insurer confirmation creates the receivable; partial payment leaves a visible balance; a disputed payment is excluded from settled totals. |
| **B6** | Manual journals with maker-checker | Not built | A10 | production go-live | A manual journal cannot post unbalanced, cannot be approved by its maker, cannot post to a control account without a subledger reference, and cannot be edited after posting. |
| **B7** | Approval limits and split prevention | Not built | A11 | production go-live | A refund above a user's limit routes to the next level; the same user cannot approve it; two same-day refunds to the same payee just under the limit are flagged as a possible split. |
| **B8** | Claims recoveries and write-offs | Not built | A7 | production go-live | A recovery is raised against a claim, allocated when received, and never touches commission accounts; a write-off requires approval and posts to an identifiable account. |
| **B9** | Daily client-money reconciliation and shortage response | Not built | A12 | production go-live | A transfer that would leave the client-money position negative is refused; two consecutive missed reconciliations escalate; a shortage raises an incident and blocks further transfers until independently released. |
| **B10** | Beneficiaries, death claims and instalment settlements | Not built | A7 | UAT acceptance | A death claim records the representative and beneficiaries; percentages must total 100%; a disputed share is held while undisputed shares pay; a second instalment reduces the balance without a new claim accrual. |
<<<<<<< ours
<<<<<<< ours
| **B11** | Subledger cross-control reclass -- releasing a client advance to a policy | Not built | B2 | production go-live | A release of 750,000 leaves 2040 down by 750,000 and AR down by 750,000 with the bank unchanged; both open items show the consumption; releasing more than available is refused; releasing across clients is refused; voiding the reclass restores both balances. |
=======
>>>>>>> theirs
=======
| **B11** | Subledger cross-control reclass -- releasing a client advance to a policy | Not built | B2 | production go-live | A release of 750,000 leaves 2040 down by 750,000 and AR down by 750,000 with the bank unchanged; both open items show the consumption; releasing more than available is refused; releasing across clients is refused; voiding the reclass restores both balances. |
>>>>>>> theirs

<!-- END GENERATED: SIGN-OFF REGISTER -->

---

## 17. Review outcome

For each A-item the reviewer selects one: **Approved** · **Approved subject to conditions** ·
**Amend and resubmit** · **Not approved** · **Further information required**.

Conditions and outstanding actions are recorded against the item. Approval at the policy gate does
not constitute UAT acceptance or production approval, and the three gates in §1 are signed
separately.

---

## 18. Formal sign-off

**Appointed Accountant**

Name: ______________________________________________

Professional qualification: _________________________

Professional registration (if applicable): __________

Signature: _________________________________________

Date: ______________________________________________

**Legal adviser (where applicable)**

Name: ______________________________________________

Qualification / organisation: _______________________

Signature: _________________________________________

Date: ______________________________________________

**Tax adviser (where applicable)**

Name: ______________________________________________

Signature: _________________________________________

Date: ______________________________________________

**System owner**

Name: ______________________________________________

Signature: _________________________________________

Date: ______________________________________________

### Gate 1 — Accounting policy approval

- [ ] Approved for production accounting policy, subject to conditions
- [ ] Approved for production accounting policy without outstanding conditions
- [ ] Amend and resubmit

### Gate 2 — UAT acceptance

- [ ] UAT accepted for the B-items scoped to UAT (§16.2)
- [ ] UAT accepted with conditions: ______________________

### Gate 3 — Production go-live

- [ ] All B-items blocking go-live closed and evidenced
- [ ] Go-live approved

**Conditions / outstanding matters:**

_______________________________________________________________________

_______________________________________________________________________

_______________________________________________________________________

---

## Appendix A — Decisions taken in version 2

| # | Decision | Effect on the software |
|---|---|---|
| 1 | `pro_rata_on_collection` is a fourth recognition mode; binary collection behaviour preserved for agreements that are all-or-nothing | New mode + branch in the recognition trigger (B1) |
| 2 | Recognition mode is fail-closed: no policy binds without an explicit mode for its insurer agreement | Removes the silent `on_insurer_settlement` fallback (B3) |
| 3 | Claims: build the stage model and the two review states now; beneficiaries, death claims, instalments and recoveries are committed-but-unbuilt | B5 in UAT scope; B8/B10 registered |
| 4 | Unallocated client advances are built now — new liability account, receipt tracking, allocation and release on bind | New account 2040, role `client_advance_payable` (B2) |
| 5 | `ins.broker_fee_vat` is removed rather than retained; the decision history stays in documentation | Migration deletes the setting |
| 6 | Version 2 replaces `ACCOUNTANT_PACK.md`; version 1 archived as `ACCOUNTANT_PACK_v1_superseded.md` | This document |
| 7 | The register is machine-readable and CI validates settings against implemented values | `signoff-register.json` + two scripts |
| 8 | Sign-off is for the production accounting policy, with UAT acceptance and go-live as separate gates | §1 |

## Appendix B — What version 1 said that version 2 changes

=======

### 14.2 Daily reconciliation

A designated finance officer completes a daily client-money reconciliation comparing bank balance,
cashbook, client-money liabilities, unallocated advances, available commission and unmatched items;
a separate person independently reviews it; missed reconciliations are escalated.

### 14.3 Shortage response

A suspected shortage raises a high-priority alert and an incident record, notifies management,
restricts commission transfers and non-essential withdrawals, and requires independent approval to
release those restrictions. The system must distinguish a genuine shortage from a delayed bank feed.
Essential or legally required payments follow a controlled exception process.

The position test at transfer time, the daily artefact, reviewer independence and the incident flow
are B9 and block go-live.

---

## 15. Financial reporting

PDF and Excel exports and printable layouts; filters for date and period, branch, class, insurer,
client and currency; every report identifies its generation date and user and distinguishes draft,
pending, approved and posted.

The dashboard covers premium production, earned and deferred commission, client receivables, insurer
balances and remittances, claims exposure, cancellations and refunds, client-money and operating-bank
positions, foreign exchange, and profitability by branch, insurer and class, with actual, forecast and
pending amounts distinguished.

All financial reports reconcile to the general ledger and supporting subledgers.

---

## 16. Sign-off register

The tables below are generated from `signoff-register.json`. The JSON is the source of truth; CI
checks that every setting named exists, that the value claimed as approved is one the database
allows, and that every evidence file cited exists. Edit the JSON and run
`node scripts/gen-signoff-register.mjs`; never edit the block by hand.

<!-- BEGIN GENERATED: SIGN-OFF REGISTER -->
<!-- Do not edit by hand. Edit docs/insurance-brokerage/signoff-register.json and run
     node scripts/gen-signoff-register.mjs -->

### 16.1 Accounting policy items (A-register)

Each item is the accounting treatment the software is expected to implement. `reviewed_at`
is filled only when the appointed reviewer has signed that item in section 18.

| Ref | Decision area | Approver | Code | Selected settings | Required before | Evidence |
|---|---|---|---|---|---|---|
| **A1** | Premium recognition and pre-binding advances | accountant | Partly built | — | UAT acceptance | — |
| **A2** | Insurer settlement: gross basis and net exceptions | accountant + legal | Built | `ins.insurer_remittance_basis` = **gross_premium** | production go-live | `test_ins_settlement_basis.sql`<br>`test_ins_commission.sql` |
| **A3** | Commission recognition methods | accountant | Partly built | `ins.commission_recognition` = **explicit_per_agreement** *(not yet implemented)* | UAT acceptance | `test_ins_commission_recognition_mode.sql`<br>`test_ins_commission_on_premium_collection.sql`<br>`test_ins_commission_pro_rata.sql` |
| **A4** | Partial collection and commission clawbacks | accountant | Partly built | `ins.commission_recognition` = **pro_rata_on_collection** *(not yet implemented)* | UAT acceptance | `test_ins_commission_pro_rata.sql`<br>`test_ins_cancellation_posting.sql` |
| **A5** | Co-insurance accounting | accountant | Built | — | production go-live | `test_ins_coinsurance_charges.sql` |
| **A6** | Cancellation, refunds and return premium | accountant | Built | `ins.cancellation_treatment` = **pro_rata_refund** | production go-live | `test_ins_cancellation_calculation.sql`<br>`test_ins_cancellation_posting.sql`<br>`test_ins_cancellation_cash.sql` |
| **A7** | Claims accounting and recoveries | accountant | Partly built | — | production go-live | `test_ins_claim_payments.sql`<br>`test_ins_claim_reserve_revisions.sql`<br>`test_ins_claim_documents.sql` |
| **A8** | Foreign currency and revaluation | accountant | Built | — | production go-live | `test_foreign_bind_transfer.sql`<br>`test_foreign_cancellation.sql`<br>`test_foreign_claims.sql` |
| **A9** | Migration and opening balances | accountant | Built | `migration.earned_commission_treatment` = **opening_balances**<br>`migration.partially_paid_import` = **full_billed_plus_receipts** | production go-live | `test_ins_import_opening_from_history.sql`<br>`test_ins_import_control_totals.sql`<br>`test_ins_opening_acceptance_gate.sql` |
| **A10** | Accounting periods and manual journals | accountant | Partly built | — | production go-live | `test_fin_period_controls.sql` |
| **A11** | Financial approval limits | accountant | Not built | — | production go-live | `test_ins_finance_pending_approvals.sql` |
| **A12** | Client-money accounting and reconciliation | accountant | Partly built | — | production go-live | `test_fin_bank_accounts.sql`<br>`test_bank_reconciliation.sql`<br>`test_ins_policy_cash.sql` |
| **A13** | Statutory charges and remittances | accountant + legal | Built | `ins.statutory_charge_enforcement` = **advisory** | production go-live | `test_ins_statutory_charge_catalogue.sql`<br>`test_ins_statutory_charges_on_policy.sql`<br>`test_ins_statutory_charge_trace.sql` |
| **A14** | VAT, withholding tax and broker-fee classification | accountant + tax | Built | `ins.agent_commission_taxable` = **taxable**<br>`ins.agent_commission_wht` = **applicable**<br>`ins.agent_commission_basis` = **gross_commission** | production go-live | `test_ins_client_broker_fees.sql`<br>`test_ins_agent_commission.sql`<br>`test_wht_posting.sql` |
| **A15** | Intermediary commission accounting | accountant + legal | Built | — | production go-live | `test_ins_agent_commission.sql`<br>`test_ins_intermediaries.sql` |
| **A16** | Financial reporting and reconciliation | accountant | Built | — | production go-live | `test_ins_reports_batch1.sql`<br>`test_ins_reports_batch2.sql`<br>`test_ins_reports_batch3.sql`<br>`test_ins_reports_batch4.sql`<br>`test_ins_dashboard_summary.sql` |
| **A17** | Business day and posting-date rules (DR-46) | accountant | Built | — | production go-live | `test_fin_period_controls.sql`<br>`test_ins_reports_batch1.sql` |
| **A18** | Endorsement cancellation and financial reversal | accountant | Built | — | production go-live | `test_endorsement_cancellation.sql`<br>`test_endorsement_posting.sql` |
| **A19** | Opening position, retained earnings and migration balancing | accountant | Built | `migration.earned_commission_treatment` = **opening_balances** | production go-live | `test_ins_import_opening_from_history.sql`<br>`test_ins_opening_acceptance_gate.sql` |
| **A20** | Broker-fee classification and its accounting and tax treatment | accountant + tax | Built | — | production go-live | `test_ins_client_broker_fees.sql` |

### 16.2 Committed but not built (B-register)

=======

### 14.2 Daily reconciliation

A designated finance officer completes a daily client-money reconciliation comparing bank balance,
cashbook, client-money liabilities, unallocated advances, available commission and unmatched items;
a separate person independently reviews it; missed reconciliations are escalated.

### 14.3 Shortage response

A suspected shortage raises a high-priority alert and an incident record, notifies management,
restricts commission transfers and non-essential withdrawals, and requires independent approval to
release those restrictions. The system must distinguish a genuine shortage from a delayed bank feed.
Essential or legally required payments follow a controlled exception process.

The position test at transfer time, the daily artefact, reviewer independence and the incident flow
are B9 and block go-live.

---

## 15. Financial reporting

PDF and Excel exports and printable layouts; filters for date and period, branch, class, insurer,
client and currency; every report identifies its generation date and user and distinguishes draft,
pending, approved and posted.

The dashboard covers premium production, earned and deferred commission, client receivables, insurer
balances and remittances, claims exposure, cancellations and refunds, client-money and operating-bank
positions, foreign exchange, and profitability by branch, insurer and class, with actual, forecast and
pending amounts distinguished.

All financial reports reconcile to the general ledger and supporting subledgers.

---

## 16. Sign-off register

The tables below are generated from `signoff-register.json`. The JSON is the source of truth; CI
checks that every setting named exists, that the value claimed as approved is one the database
allows, and that every evidence file cited exists. Edit the JSON and run
`node scripts/gen-signoff-register.mjs`; never edit the block by hand.

<!-- BEGIN GENERATED: SIGN-OFF REGISTER -->
<!-- Do not edit by hand. Edit docs/insurance-brokerage/signoff-register.json and run
     node scripts/gen-signoff-register.mjs -->

### 16.1 Accounting policy items (A-register)

Each item is the accounting treatment the software is expected to implement. `reviewed_at`
is filled only when the appointed reviewer has signed that item in section 18.

| Ref | Decision area | Approver | Code | Selected settings | Required before | Evidence |
|---|---|---|---|---|---|---|
| **A1** | Premium recognition and pre-binding advances | accountant | Partly built | — | UAT acceptance | — |
| **A2** | Insurer settlement: gross basis and net exceptions | accountant + legal | Built | `ins.insurer_remittance_basis` = **gross_premium** | production go-live | `test_ins_settlement_basis.sql`<br>`test_ins_commission.sql` |
| **A3** | Commission recognition methods | accountant | Partly built | `ins.commission_recognition` = **explicit_per_agreement** *(not yet implemented)* | UAT acceptance | `test_ins_commission_recognition_mode.sql`<br>`test_ins_commission_on_premium_collection.sql`<br>`test_ins_commission_pro_rata.sql` |
| **A4** | Partial collection and commission clawbacks | accountant | Partly built | `ins.commission_recognition` = **pro_rata_on_collection** *(not yet implemented)* | UAT acceptance | `test_ins_commission_pro_rata.sql`<br>`test_ins_cancellation_posting.sql` |
| **A5** | Co-insurance accounting | accountant | Built | — | production go-live | `test_ins_coinsurance_charges.sql` |
| **A6** | Cancellation, refunds and return premium | accountant | Built | `ins.cancellation_treatment` = **pro_rata_refund** | production go-live | `test_ins_cancellation_calculation.sql`<br>`test_ins_cancellation_posting.sql`<br>`test_ins_cancellation_cash.sql` |
| **A7** | Claims accounting and recoveries | accountant | Partly built | — | production go-live | `test_ins_claim_payments.sql`<br>`test_ins_claim_reserve_revisions.sql`<br>`test_ins_claim_documents.sql` |
| **A8** | Foreign currency and revaluation | accountant | Built | — | production go-live | `test_foreign_bind_transfer.sql`<br>`test_foreign_cancellation.sql`<br>`test_foreign_claims.sql` |
| **A9** | Migration and opening balances | accountant | Built | `migration.earned_commission_treatment` = **opening_balances**<br>`migration.partially_paid_import` = **full_billed_plus_receipts** | production go-live | `test_ins_import_opening_from_history.sql`<br>`test_ins_import_control_totals.sql`<br>`test_ins_opening_acceptance_gate.sql` |
| **A10** | Accounting periods and manual journals | accountant | Partly built | — | production go-live | `test_fin_period_controls.sql` |
| **A11** | Financial approval limits | accountant | Not built | — | production go-live | `test_ins_finance_pending_approvals.sql` |
| **A12** | Client-money accounting and reconciliation | accountant | Partly built | — | production go-live | `test_fin_bank_accounts.sql`<br>`test_bank_reconciliation.sql`<br>`test_ins_policy_cash.sql` |
| **A13** | Statutory charges and remittances | accountant + legal | Built | `ins.statutory_charge_enforcement` = **advisory** | production go-live | `test_ins_statutory_charge_catalogue.sql`<br>`test_ins_statutory_charges_on_policy.sql`<br>`test_ins_statutory_charge_trace.sql` |
| **A14** | VAT, withholding tax and broker-fee classification | accountant + tax | Built | `ins.agent_commission_taxable` = **taxable**<br>`ins.agent_commission_wht` = **applicable**<br>`ins.agent_commission_basis` = **gross_commission** | production go-live | `test_ins_client_broker_fees.sql`<br>`test_ins_agent_commission.sql`<br>`test_wht_posting.sql` |
| **A15** | Intermediary commission accounting | accountant + legal | Built | — | production go-live | `test_ins_agent_commission.sql`<br>`test_ins_intermediaries.sql` |
| **A16** | Financial reporting and reconciliation | accountant | Built | — | production go-live | `test_ins_reports_batch1.sql`<br>`test_ins_reports_batch2.sql`<br>`test_ins_reports_batch3.sql`<br>`test_ins_reports_batch4.sql`<br>`test_ins_dashboard_summary.sql` |
| **A17** | Business day and posting-date rules (DR-46) | accountant | Built | — | production go-live | `test_fin_period_controls.sql`<br>`test_ins_reports_batch1.sql` |
| **A18** | Endorsement cancellation and financial reversal | accountant | Built | — | production go-live | `test_endorsement_cancellation.sql`<br>`test_endorsement_posting.sql` |
| **A19** | Opening position, retained earnings and migration balancing | accountant | Built | `migration.earned_commission_treatment` = **opening_balances** | production go-live | `test_ins_import_opening_from_history.sql`<br>`test_ins_opening_acceptance_gate.sql` |
| **A20** | Broker-fee classification and its accounting and tax treatment | accountant + tax | Built | — | production go-live | `test_ins_client_broker_fees.sql` |

### 16.2 Committed but not built (B-register)

>>>>>>> theirs
These are controls and features the policy assumes. **They are not built.** The reviewer is
asked to approve the *policy* in §16.1 while acknowledging these as committed work with the
gate shown. An item blocking "production go-live" must be complete before live posting; an
item blocking "UAT acceptance" must be complete before the business signs UAT.

| Ref | Feature | Status | Depends on | Blocks | Acceptance criteria |
|---|---|---|---|---|---|
| **B1** | pro_rata_on_collection commission recognition | Not built | A3, A4 | UAT acceptance | A partial collection of 50% of premium earns exactly 50% of commission, the remainder stays in 2020, a further collection earns the balance, and voiding a receipt reverses only the portion that receipt earned. |
| **B2** | Unallocated client advances | Not built | A1 | UAT acceptance | A receipt with no policy creates a 2040 credit and no receivable; binding a policy allocates it and clears 2040; an unallocated advance is visible on the client statement as a liability and is refundable. |
| **B3** | Fail-closed commission-mode selection | Not built | A3 | UAT acceptance | A policy on an insurer with no configured mode cannot bind and the error names the insurer and the missing setting; configuring the mode allows the bind and the chosen mode is frozen into the accounting snapshot. |
| **B4** | Three cancellation dates | Not built | A6 | UAT acceptance | A cancellation requested in period 1, effective in period 2 and settled in period 3 posts to the settlement period while reporting its effective date; a backdated effective date without evidence is refused. |
| **B5** | Claim stage model and the two review states (built) | built | A7 | UAT acceptance | A claim moves through all eight stages with an audit row each; internal approval creates no journal; insurer confirmation creates the receivable; partial payment leaves a visible balance; a disputed payment is excluded from settled totals. |
| **B6** | Manual journals with maker-checker | Not built | A10 | production go-live | A manual journal cannot post unbalanced, cannot be approved by its maker, cannot post to a control account without a subledger reference, and cannot be edited after posting. |
| **B7** | Approval limits and split prevention | Not built | A11 | production go-live | A refund above a user's limit routes to the next level; the same user cannot approve it; two same-day refunds to the same payee just under the limit are flagged as a possible split. |
<<<<<<< ours
| **B8** | Claims recoveries (not built) and write-offs (built) | partial | A7 | production go-live | A recovery is raised against a claim, allocated when received, and never touches commission accounts; a write-off requires approval and posts to an identifiable account. |
=======
| **B8** | Claims recoveries and write-offs (built) | built | A7 | production go-live | A recovery is raised against a claim, allocated when received, and never touches commission accounts; a write-off requires approval and posts to an identifiable account. |
>>>>>>> theirs
| **B9** | Daily client-money reconciliation and shortage response | Not built | A12 | production go-live | A transfer that would leave the client-money position negative is refused; two consecutive missed reconciliations escalate; a shortage raises an incident and blocks further transfers until independently released. |
| **B10** | Beneficiaries, death claims and instalment settlements (built) | built | A7 | UAT acceptance | A death claim records the representative and beneficiaries; percentages must total 100%; a disputed share is held while undisputed shares pay; a second instalment reduces the balance without a new claim accrual. |
| **B11** | Non-cash party-balance movement (dispositions) -- built | built | B2 | production go-live | A release of 250,000 leaves 2040 down by 250,000 and AR down by 250,000 with the bank unchanged; the open item shows the consumption; over-release is refused; a write-off reduces 2030 into the named expense account; commission accounts are refused; a control account cannot be the counterparty; a disposition cannot be edited or deleted. |

<!-- END GENERATED: SIGN-OFF REGISTER -->

---

## 17. Review outcome

For each A-item the reviewer selects one: **Approved** · **Approved subject to conditions** ·
**Amend and resubmit** · **Not approved** · **Further information required**.

Conditions and outstanding actions are recorded against the item. Approval at the policy gate does
not constitute UAT acceptance or production approval, and the three gates in §1 are signed
separately.

---

## 18. Formal sign-off

**Appointed Accountant**

Name: ______________________________________________

Professional qualification: _________________________

Professional registration (if applicable): __________

Signature: _________________________________________

Date: ______________________________________________

**Legal adviser (where applicable)**

Name: ______________________________________________

Qualification / organisation: _______________________

Signature: _________________________________________

Date: ______________________________________________

**Tax adviser (where applicable)**

Name: ______________________________________________

Signature: _________________________________________

Date: ______________________________________________

**System owner**

Name: ______________________________________________

Signature: _________________________________________

Date: ______________________________________________

### Gate 1 — Accounting policy approval

- [ ] Approved for production accounting policy, subject to conditions
- [ ] Approved for production accounting policy without outstanding conditions
- [ ] Amend and resubmit

### Gate 2 — UAT acceptance

- [ ] UAT accepted for the B-items scoped to UAT (§16.2)
- [ ] UAT accepted with conditions: ______________________

### Gate 3 — Production go-live

- [ ] All B-items blocking go-live closed and evidenced
- [ ] Go-live approved

**Conditions / outstanding matters:**

_______________________________________________________________________

_______________________________________________________________________

_______________________________________________________________________

---

## Appendix A — Decisions taken in version 2

| # | Decision | Effect on the software |
|---|---|---|
| 1 | `pro_rata_on_collection` is a fourth recognition mode; binary collection behaviour preserved for agreements that are all-or-nothing | New mode + branch in the recognition trigger (B1) |
| 2 | Recognition mode is fail-closed: no policy binds without an explicit mode for its insurer agreement | Removes the silent `on_insurer_settlement` fallback (B3) |
| 3 | Claims: build the stage model and the two review states now; beneficiaries, death claims, instalments and recoveries are committed-but-unbuilt | B5 in UAT scope; B8/B10 registered |
| 4 | Unallocated client advances are built now — new liability account, receipt tracking, allocation and release on bind | New account 2040, role `client_advance_payable` (B2) |
| 5 | `ins.broker_fee_vat` is removed rather than retained; the decision history stays in documentation | Migration deletes the setting |
| 6 | Version 2 replaces `ACCOUNTANT_PACK.md`; version 1 archived as `ACCOUNTANT_PACK_v1_superseded.md` | This document |
| 7 | The register is machine-readable and CI validates settings against implemented values | `signoff-register.json` + two scripts |
| 8 | Sign-off is for the production accounting policy, with UAT acceptance and go-live as separate gates | §1 |

## Appendix B — open questions the code refuses to answer for you

These are accounting-policy choices. The software now makes each one *expressible*
without choosing it, because guessing would be the software writing policy — the
thing this pack exists to prevent. Each needs an answer before the gate shown.

| # | Question | Where the software stands | Needed by |
|---|---|---|---|
| Q1 | **Which account absorbs a claim write-off?** A claim balance on 2030 has to go somewhere when it is written off. Options: a bad-debt expense, a dedicated "claim write-offs" expense, or against commission income (rejected in code — see below). | `ins_write_off_claim()` requires the caller to name the account. It must be a real, non-control expense or revenue account, and commission accounts (4000, 2020, 1110) are **refused by name**. No default exists. | production go-live (B8) |
| Q2 | **Is an unapplied client advance released or forfeited?** If a client pays before placement and the policy never binds, the money is a liability until refunded. If the brokerage is entitled to keep it, that is a `advance_forfeit` — a different posting from a release, and taxable in a way a release is not. | Both kinds exist (`advance_release`, `advance_forfeit`). `advance_release` is forced by double entry to Dr 2040 / Cr AR. `advance_forfeit` has no built caller: no one has said when forfeiture is appropriate. | UAT acceptance (B2) |
| Q3 | **Repudiation is a ninth state.** §7.2 lists eight stages and omits it. | `repudiated` exists in the schema, is required, and is reported by `ins_claim_stage()`. It was kept rather than dropped to match the list. | policy approval |
<<<<<<< ours
=======
| Q4 | **Which account absorbs a recovery credit?** A recovery raised against a claim credits *some* account when it is recognised. Recovery income, a contra against the loss the claim created, or netted into the insurer's account are all defensible, and the choice changes both the income statement and the net claim cost. | `ins_raise_claim_recovery()` requires the caller to name a real, non-control account. Commission accounts are refused. Writing the recovery off later charges the loss back to the same account, which is stored on the row rather than derived. No default. | production go-live (B8) |
>>>>>>> theirs

On Q1, the reason commission accounts are refused in code rather than left to
judgement: §7.7 says a recovery "never touches commission accounts". A write-off is
absorbed by a loss account; charging it to commission income would restate brokerage
revenue for a claim the brokerage never earned on, and would do so silently in the
period the write-off was made rather than the period the claim arose.

## Appendix B — What version 1 said that version 2 changes

<<<<<<< ours
>>>>>>> theirs
=======
>>>>>>> theirs
=======

### 14.2 Daily reconciliation

A designated finance officer completes a daily client-money reconciliation comparing bank balance,
cashbook, client-money liabilities, unallocated advances, available commission and unmatched items;
a separate person independently reviews it; missed reconciliations are escalated.

### 14.3 Shortage response

A suspected shortage raises a high-priority alert and an incident record, notifies management,
restricts commission transfers and non-essential withdrawals, and requires independent approval to
release those restrictions. The system must distinguish a genuine shortage from a delayed bank feed.
Essential or legally required payments follow a controlled exception process.

The position test at transfer time, the daily artefact, reviewer independence and the incident flow
are B9 and block go-live.

---

## 15. Financial reporting

PDF and Excel exports and printable layouts; filters for date and period, branch, class, insurer,
client and currency; every report identifies its generation date and user and distinguishes draft,
pending, approved and posted.

The dashboard covers premium production, earned and deferred commission, client receivables, insurer
balances and remittances, claims exposure, cancellations and refunds, client-money and operating-bank
positions, foreign exchange, and profitability by branch, insurer and class, with actual, forecast and
pending amounts distinguished.

All financial reports reconcile to the general ledger and supporting subledgers.

---

## 16. Sign-off register

The tables below are generated from `signoff-register.json`. The JSON is the source of truth; CI
checks that every setting named exists, that the value claimed as approved is one the database
allows, and that every evidence file cited exists. Edit the JSON and run
`node scripts/gen-signoff-register.mjs`; never edit the block by hand.

<!-- BEGIN GENERATED: SIGN-OFF REGISTER -->
<!-- Do not edit by hand. Edit docs/insurance-brokerage/signoff-register.json and run
     node scripts/gen-signoff-register.mjs -->

### 16.1 Accounting policy items (A-register)

Each item is the accounting treatment the software is expected to implement. `reviewed_at`
is filled only when the appointed reviewer has signed that item in section 18.

| Ref | Decision area | Approver | Code | Selected settings | Required before | Evidence |
|---|---|---|---|---|---|---|
| **A1** | Premium recognition and pre-binding advances | accountant | Partly built | — | UAT acceptance | — |
| **A2** | Insurer settlement: gross basis and net exceptions | accountant + legal | Built | `ins.insurer_remittance_basis` = **gross_premium** | production go-live | `test_ins_settlement_basis.sql`<br>`test_ins_commission.sql` |
| **A3** | Commission recognition methods | accountant | Partly built | `ins.commission_recognition` = **explicit_per_agreement** *(not yet implemented)* | UAT acceptance | `test_ins_commission_recognition_mode.sql`<br>`test_ins_commission_on_premium_collection.sql`<br>`test_ins_commission_pro_rata.sql` |
| **A4** | Partial collection and commission clawbacks | accountant | Partly built | `ins.commission_recognition` = **pro_rata_on_collection** *(not yet implemented)* | UAT acceptance | `test_ins_commission_pro_rata.sql`<br>`test_ins_cancellation_posting.sql` |
| **A5** | Co-insurance accounting | accountant | Built | — | production go-live | `test_ins_coinsurance_charges.sql` |
| **A6** | Cancellation, refunds and return premium | accountant | Built | `ins.cancellation_treatment` = **pro_rata_refund** | production go-live | `test_ins_cancellation_calculation.sql`<br>`test_ins_cancellation_posting.sql`<br>`test_ins_cancellation_cash.sql` |
| **A7** | Claims accounting and recoveries | accountant | Partly built | — | production go-live | `test_ins_claim_payments.sql`<br>`test_ins_claim_reserve_revisions.sql`<br>`test_ins_claim_documents.sql` |
| **A8** | Foreign currency and revaluation | accountant | Built | — | production go-live | `test_foreign_bind_transfer.sql`<br>`test_foreign_cancellation.sql`<br>`test_foreign_claims.sql` |
| **A9** | Migration and opening balances | accountant | Built | `migration.earned_commission_treatment` = **opening_balances**<br>`migration.partially_paid_import` = **full_billed_plus_receipts** | production go-live | `test_ins_import_opening_from_history.sql`<br>`test_ins_import_control_totals.sql`<br>`test_ins_opening_acceptance_gate.sql` |
| **A10** | Accounting periods and manual journals | accountant | Partly built | — | production go-live | `test_fin_period_controls.sql` |
| **A11** | Financial approval limits | accountant | Not built | — | production go-live | `test_ins_finance_pending_approvals.sql` |
| **A12** | Client-money accounting and reconciliation | accountant | Partly built | — | production go-live | `test_fin_bank_accounts.sql`<br>`test_bank_reconciliation.sql`<br>`test_ins_policy_cash.sql` |
| **A13** | Statutory charges and remittances | accountant + legal | Built | `ins.statutory_charge_enforcement` = **advisory** | production go-live | `test_ins_statutory_charge_catalogue.sql`<br>`test_ins_statutory_charges_on_policy.sql`<br>`test_ins_statutory_charge_trace.sql` |
| **A14** | VAT, withholding tax and broker-fee classification | accountant + tax | Built | `ins.agent_commission_taxable` = **taxable**<br>`ins.agent_commission_wht` = **applicable**<br>`ins.agent_commission_basis` = **gross_commission** | production go-live | `test_ins_client_broker_fees.sql`<br>`test_ins_agent_commission.sql`<br>`test_wht_posting.sql` |
| **A15** | Intermediary commission accounting | accountant + legal | Built | — | production go-live | `test_ins_agent_commission.sql`<br>`test_ins_intermediaries.sql` |
| **A16** | Financial reporting and reconciliation | accountant | Built | — | production go-live | `test_ins_reports_batch1.sql`<br>`test_ins_reports_batch2.sql`<br>`test_ins_reports_batch3.sql`<br>`test_ins_reports_batch4.sql`<br>`test_ins_dashboard_summary.sql` |
| **A17** | Business day and posting-date rules (DR-46) | accountant | Built | — | production go-live | `test_fin_period_controls.sql`<br>`test_ins_reports_batch1.sql` |
| **A18** | Endorsement cancellation and financial reversal | accountant | Built | — | production go-live | `test_endorsement_cancellation.sql`<br>`test_endorsement_posting.sql` |
| **A19** | Opening position, retained earnings and migration balancing | accountant | Built | `migration.earned_commission_treatment` = **opening_balances** | production go-live | `test_ins_import_opening_from_history.sql`<br>`test_ins_opening_acceptance_gate.sql` |
| **A20** | Broker-fee classification and its accounting and tax treatment | accountant + tax | Built | — | production go-live | `test_ins_client_broker_fees.sql` |

### 16.2 Committed but not built (B-register)

These are controls and features the policy assumes. **They are not built.** The reviewer is
asked to approve the *policy* in §16.1 while acknowledging these as committed work with the
gate shown. An item blocking "production go-live" must be complete before live posting; an
item blocking "UAT acceptance" must be complete before the business signs UAT.

| Ref | Feature | Status | Depends on | Blocks | Acceptance criteria |
|---|---|---|---|---|---|
| **B1** | pro_rata_on_collection commission recognition | Not built | A3, A4 | UAT acceptance | A partial collection of 50% of premium earns exactly 50% of commission, the remainder stays in 2020, a further collection earns the balance, and voiding a receipt reverses only the portion that receipt earned. |
| **B2** | Unallocated client advances | Not built | A1 | UAT acceptance | A receipt with no policy creates a 2040 credit and no receivable; binding a policy allocates it and clears 2040; an unallocated advance is visible on the client statement as a liability and is refundable. |
| **B3** | Fail-closed commission-mode selection | Not built | A3 | UAT acceptance | A policy on an insurer with no configured mode cannot bind and the error names the insurer and the missing setting; configuring the mode allows the bind and the chosen mode is frozen into the accounting snapshot. |
| **B4** | Three cancellation dates | Not built | A6 | UAT acceptance | A cancellation requested in period 1, effective in period 2 and settled in period 3 posts to the settlement period while reporting its effective date; a backdated effective date without evidence is refused. |
| **B5** | Claim stage model and the two review states (built) | built | A7 | UAT acceptance | A claim moves through all eight stages with an audit row each; internal approval creates no journal; insurer confirmation creates the receivable; partial payment leaves a visible balance; a disputed payment is excluded from settled totals. |
| **B6** | Manual journals with maker-checker | Not built | A10 | production go-live | A manual journal cannot post unbalanced, cannot be approved by its maker, cannot post to a control account without a subledger reference, and cannot be edited after posting. |
| **B7** | Approval limits and split prevention | Not built | A11 | production go-live | A refund above a user's limit routes to the next level; the same user cannot approve it; two same-day refunds to the same payee just under the limit are flagged as a possible split. |
| **B8** | Claims recoveries and write-offs (built) | built | A7 | production go-live | A recovery is raised against a claim, allocated when received, and never touches commission accounts; a write-off requires approval and posts to an identifiable account. |
| **B9** | Daily client-money reconciliation and shortage response | Not built | A12 | production go-live | A transfer that would leave the client-money position negative is refused; two consecutive missed reconciliations escalate; a shortage raises an incident and blocks further transfers until independently released. |
| **B10** | Beneficiaries, death claims and instalment settlements (built) | built | A7 | UAT acceptance | A death claim records the representative and beneficiaries; percentages must total 100%; a disputed share is held while undisputed shares pay; a second instalment reduces the balance without a new claim accrual. |
| **B11** | Non-cash party-balance movement (dispositions) -- built | built | B2 | production go-live | A release of 250,000 leaves 2040 down by 250,000 and AR down by 250,000 with the bank unchanged; the open item shows the consumption; over-release is refused; a write-off reduces 2030 into the named expense account; commission accounts are refused; a control account cannot be the counterparty; a disposition cannot be edited or deleted. |

<!-- END GENERATED: SIGN-OFF REGISTER -->

---

## 17. Review outcome

For each A-item the reviewer selects one: **Approved** · **Approved subject to conditions** ·
**Amend and resubmit** · **Not approved** · **Further information required**.

Conditions and outstanding actions are recorded against the item. Approval at the policy gate does
not constitute UAT acceptance or production approval, and the three gates in §1 are signed
separately.

---

## 18. Formal sign-off

**Appointed Accountant**

Name: ______________________________________________

Professional qualification: _________________________

Professional registration (if applicable): __________

Signature: _________________________________________

=======

**Pro-rata worked example (the mode that is not built yet — B1)**

| Description | Amount |
|---|---|
| Premium | UGX 1,000,000 |
| Commission rate | 10% |
| Total commission | UGX 100,000 |
| First collection | UGX 500,000 |
| Commission recognised | UGX 50,000 |
| Commission deferred (2020) | UGX 50,000 |

Receipt reversals and refunds trigger corresponding commission adjustments at the same booked
rate. Voiding a receipt un-earns what that receipt earned and never leaves income standing on
money that came back.

### 4.4 No silent default

Every policy must have an explicit recognition mode in force at bind. Binding a policy whose
insurer agreement has no configured mode **fails** and names the insurer and the missing setting.
`on_insurer_settlement` remains available but must be chosen; it is no longer a fallback. This is
B3, and it is the change that makes the per-agreement classification in this section actually
load-bearing.

### 4.5 Settlement and recognition are separate dimensions

Not every combination is sensible. Gross settlement with `on_premium_collection` or
`pro_rata_on_collection` cannot coexist — under gross the premium crosses in full, so there is
nothing left to collect — and the software refuses the combination by name at bind rather than
silently choosing one. The remainder of the compatibility matrix is for the accountant to approve,
particularly where net settlement changes the timing or legal basis of the entitlement.

### 4.6 Confirmations required

Which insurer agreements are `at_placement`, `on_premium_collection`, `pro_rata_on_collection` or
`on_insurer_settlement`; that the collection triggers are the **client's** receipt and not the
insurer's settlement or a credit note; that a voided receipt reverses recognition; the
compatibility matrix; and the deferred-commission and income accounts.

---

## 5. Cancellations, refunds and clawbacks

### 5.1 Principles

A cancellation preserves the original policy and financial history. The system records three
separate dates: cancellation requested, cancellation effective, and financial settlement. The
effective date must be supported by insurer confirmation or another appropriate authority.
Backdated cancellations require evidence, a reason and authorised approval. Closed periods are
never silently rewritten.

Three dates are policy; only `effective_date` is modelled today — that is B4.

### 5.2 Return premium

Distinguish: return premium requested, approved, actually received or credited; client refund
payable; client refund actually paid; deductions and charges. An approved refund is never treated
as cash received, and no insurer receivable is created merely because a refund was requested. A
separate client refund obligation may still arise where the brokerage has an independent
contractual or legal duty to refund.

### 5.3 Deductions are never automatically income

| Deduction | Belongs to |
|---|---|
| Insurer-retained short-period premium | the insurer |
| Brokerage cancellation fee | the brokerage, only where contractually authorised |
| Statutory charges | the relevant statutory recipient |
| Other authorised deductions | the appropriate beneficiary |

The difference between original and return premium never becomes brokerage income by default.

### 5.4 Commission clawback

Proportional to the **approved** return premium, and never more than commission previously
recognised. Where commission has already been transferred to operating funds, record the clawback
against the original transaction, identify what is recoverable from operating funds, replenish
client money where necessary, block further transfers if the client-money position is deficient,
and require approval with a retained audit trail.

In the ledger the clawback is absorbed in a fixed order: the deferred pool (2020) first, then
recognised income (4000), then a recoverable from operating funds. Those are three different
movements, not one.

### 5.5 Confirmations required

Credit-note and reversal entries; whether returned commission goes back to deferred or reverses
income; treatment of transferred commission; approved-but-unpaid return premiums; the accounting
date for a backdated cancellation; cancellation after insurer settlement.

---

## 6. Co-insurance

Each participating insurer has independent records for participation percentage, lead status,
commission rate, settlement method, recognition trigger, tax treatment, receipts and outstanding
balances, and cancellation adjustments. Shares must total 100% with exactly one lead insurer;
both are enforced at bind.

The accountant must approve the allocation of premium, commission, insurer liabilities, receipts,
remittances and cancellation adjustments across participants.

---

## 7. Claims

### 7.1 Operating models

**Insurer-direct** — the insurer pays the claimant. The system records administration, the
insurer's decision and payment evidence, and creates **no** brokerage cash, bank or payable entry
for funds it never handled.

**Brokerage-managed** — the brokerage receives insurer funds and pays claimants. The system
records the insurer receivable (1120), funds received, the claimant payable (2030) and payments.

### 7.2 Stages

The policy recognises eight stages — reported, assessed, internally approved, insurer confirmed,
funded, partially paid, fully paid, closed — plus two states, **Coverage under review** and
**Payment disputed**. Internal approval alone never creates a payment posting.

Today the schema has six (`notified, assessing, approved, settled, repudiated, closed`) and
neither review state. The extension is B5 and blocks UAT acceptance.

### 7.3–7.7 Review, late notification, death claims, instalments, recoveries

A claim arising while a cancellation effective date is disputed is registered and marked
*Coverage under review*; it is never auto-rejected and no insurer liability is recognised before
confirmation. A claim registered after expiry is accepted where the insured event occurred during
cover, recording incident date, client notification, insurer notification and insurer
acknowledgement, and is flagged for review rather than rejected.

Authorised representatives may report a claim after the policyholder's death. Multiple
beneficiaries are supported on percentage or fixed allocations; percentages must total 100%;
disputed shares are held until insurer confirmation or legal determination while undisputed shares
may proceed; disputed shares are never redistributed automatically.

Instalments each carry their own expected date, actual payment date, amount and evidence, and a
subsequent receipt settles the existing approved balance rather than creating fresh recognition. A
disputed direct payment is marked *Payment disputed* until resolved, with the original evidence and
the dispute retained.

Excess rules are configurable by policy terms, class, insurer agreement and claim type; authorised
overrides require reasons and audit history. Recoveries cover overpayments, third-party recoveries,
insurer underpayments, instalment recoveries, disputes and authorised write-offs.

Beneficiaries, death claims, instalments, extended stages and recoveries are all unbuilt — B10,
B5, B8. They are in the register precisely so that approving this section is not mistaken for
certifying them.

### 7.8 Confirmations required

Recognition date and entries for insurer-confirmed claims, brokerage-managed claims, excess,
recoveries, overpayments, write-offs and claim reversals.

---

## 8. Foreign currency

The books remain in UGX. The rate used at bind is preserved and is not replaced by later market
rates except through an authorised amendment or reversal. The system tracks the transaction
currency and value, the UGX equivalent at bind, the settlement rate and realised and unrealised
gain or loss separately.

Rate overrides before bind require authority, reason and audit history; once bound the rate is
locked. Realised and unrealised are separate accounts (4900/4901 gains, 5910/5911 losses, 5900
rounding).

The accountant must confirm exchange-rate sources, revaluation frequency, entries and presentation.

---

## 9. Migration and opening balances

### 9.1 Cut-over

The cut-over date is the day before production go-live. Transactions after cut-over go through the
system. Existing policies are imported as existing business with original inception and expiry
preserved — never as newly issued. Migrated policies retain accounting-policy version 1 unless an
approved migration process says otherwise. Every migrated record carries a migration identifier and
traceable source.

### 9.2 What the migration must distinguish

Historical premium bills, historical receipts, outstanding client receivables, outstanding insurer
payables, commission earned before cut-over, commission deferred at cut-over, claims receivable and
payable, statutory liabilities and foreign-currency balances. Receipts and bills already represented
in opening balances are not re-posted.

### 9.3 Reconciliation before approval

| Area | Required reconciliation |
|---|---|
| General ledger | balanced trial balance |
| Client receivables | to client and policy records |
| Insurer payables | to insurer and policy records |
| Bank balances | to bank statements |
| Commission | earned and deferred, per policy/agreement |
| Claims | receivable and payable per claim |
| Statutory liabilities | balances per recipient |
| Foreign currency | balances per currency |

Material unexplained differences prevent migration approval. Opening balances post through 3900,
which must net to zero, with commission earned up to cut-over carried in 3200 and only the unearned
remainder in 2020.

---

## 10. Accounting periods and manual journals

### 10.1 Period reopening

A closed period may be reopened only with a documented reason, appropriate senior finance approval,
independent maker-checker approval, audit history of all changes, period reclosure and retention of
the revised period-end reports. The requester never approves their own reopening.

### 10.2 Manual journals

Balanced entries; finance maker and independent checker; supporting evidence and reason; subledger
references for control-account journals; immutable posted entries; reversal or authorised adjustment
instead of editing; additional approval for restricted accounts. A manual journal must never silently
create a difference between the general ledger and an operational subledger.

There is no manual-journal path today (B6); corrections outside the documented flows currently
require raw SQL, which has no maker-checker and no subledger reference. That is why it blocks go-live.

### 10.3 Business day (DR-46)

Accounting dates follow the **Africa/Kampala** business day, not the database's UTC date. Posting
dates, the voidable date of a receipt, the closed-period test, accounting-setting lookups and
statutory-parameter lookups all resolve against the Kampala day. This decides which period a
transaction between 00:00 and 03:00 Kampala time falls into, and it applies platform-wide from
migrations `20261122090000` and `20261122100000`. A17.

---

## 11. Financial approval limits

Thresholds are configurable by transaction type, amount, currency, role, approval level and branch,
and apply separately to refunds, insurer remittances, commission transfers, claim payments,
intermediary commissions and manual journals, with multi-level approval, escalation, effective dates
and audit history. Splitting a transaction to stay under a threshold must be prevented.

Refunds of client advances now route through that engine (B7): a limit per stage, a limit per user in
addition to the stage, maker-checker that refuses self-approval, and a split flag. The refund function
itself refuses when an approved request does not cover the amount, so the workflow is enforced rather
than advisory. Three gaps are recorded rather than glossed: the routing key is **amount only**, so
currency, branch and department are not yet part of it; only client-advance refunds are routed, and
insurer remittances, commission transfers, claim payments and manual journals are not; and a split is
flagged for the approver rather than blocked, which is what this section asks for but leaves the
judgement with a person.

---

## 12. Statutory charges and taxation

### 12.1 The catalogue

Each charge names its legal basis, applicable class, calculation basis, rate or fixed amount,
exemptions, collection responsibility, remittance responsibility, statutory recipient, liability
account and effective date. A rate cannot be marked verified without citing the instrument that
verified it.

| Charge | Rate | Verified | Billed |
|---|---|---|---|
=======

Every policy must have an explicit recognition mode in force at bind. Binding a policy whose
insurer agreement has no configured mode **fails** and names the insurer and the missing setting.
`on_insurer_settlement` remains available but must be chosen; it is no longer a fallback. This is
B3, and it is the change that makes the per-agreement classification in this section actually
load-bearing.

The mode is recorded **against the insurer**, as a term of the agreement, with the clause it rests
on, an effective period and two approving signatures. The company-wide setting remains as the
fallback for insurers with no negotiated term on file, and an agreement always outranks it. The
order applied at bind is: the gross-settlement override, then a deliberate per-policy override,
then the insurer's terms, then the company setting, then refusal. A per-insurer readiness report
shows which insurers are covered and which will refuse to bind, and why.

Two consequences worth stating before go-live. There is **no backfill**: existing insurers are not
seeded with whatever mode they happen to be on today, because stamping a decision nobody made is
the failure this control exists to prevent. Until each insurer is covered by terms or by a reviewed
company default, policies for that insurer **will not bind** — that is the control working, but it
is a deliberate outage risk and must be timed. And the existing `ins.commission_recognition`
registry still advertises a fourth value, `over_policy_term`, which has no reader and cannot be
chosen; the implemented modes are the four in this section.

### 4.5 Settlement and recognition are separate dimensions

Not every combination is sensible. Gross settlement with `on_premium_collection` or
`pro_rata_on_collection` cannot coexist — under gross the premium crosses in full, so there is
nothing left to collect — and the software refuses the combination by name at bind rather than
silently choosing one. The remainder of the compatibility matrix is for the accountant to approve,
particularly where net settlement changes the timing or legal basis of the entitlement.

### 4.6 Confirmations required

Which insurer agreements are `at_placement`, `on_premium_collection`, `pro_rata_on_collection` or
`on_insurer_settlement`; that the collection triggers are the **client's** receipt and not the
insurer's settlement or a credit note; that a voided receipt reverses recognition; the
compatibility matrix; and the deferred-commission and income accounts.

---

## 5. Cancellations, refunds and clawbacks

### 5.1 Principles

A cancellation preserves the original policy and financial history. The system records three
separate dates: cancellation requested, cancellation effective, and financial settlement. The
effective date must be supported by insurer confirmation or another appropriate authority.
Backdated cancellations require evidence, a reason and authorised approval. Closed periods are
never silently rewritten.

Three dates are policy and all three are now modelled (B4). The request date is the moment the
cancellation was entered; the effective date is the coverage date; the settlement date is the period
the cancellation financially falls into. The settlement date is derived from the cash rather than typed
in, so a person cannot move a cancellation between periods by editing a field. A backdated effective
date requires dated evidence, and is refused at submission and again at posting.

### 5.2 Return premium

Distinguish: return premium requested, approved, actually received or credited; client refund
payable; client refund actually paid; deductions and charges. An approved refund is never treated
as cash received, and no insurer receivable is created merely because a refund was requested. A
separate client refund obligation may still arise where the brokerage has an independent
contractual or legal duty to refund.

### 5.3 Deductions are never automatically income

| Deduction | Belongs to |
|---|---|
| Insurer-retained short-period premium | the insurer |
| Brokerage cancellation fee | the brokerage, only where contractually authorised |
| Statutory charges | the relevant statutory recipient |
| Other authorised deductions | the appropriate beneficiary |

The difference between original and return premium never becomes brokerage income by default.

### 5.4 Commission clawback

Proportional to the **approved** return premium, and never more than commission previously
recognised. Where commission has already been transferred to operating funds, record the clawback
against the original transaction, identify what is recoverable from operating funds, replenish
client money where necessary, block further transfers if the client-money position is deficient,
and require approval with a retained audit trail.

In the ledger the clawback is absorbed in a fixed order: the deferred pool (2020) first, then
recognised income (4000), then a recoverable from operating funds. Those are three different
movements, not one.

### 5.5 Confirmations required

Credit-note and reversal entries; whether returned commission goes back to deferred or reverses
income; treatment of transferred commission; approved-but-unpaid return premiums; the accounting
date for a backdated cancellation; cancellation after insurer settlement.

---

## 6. Co-insurance

Each participating insurer has independent records for participation percentage, lead status,
commission rate, settlement method, recognition trigger, tax treatment, receipts and outstanding
balances, and cancellation adjustments. Shares must total 100% with exactly one lead insurer;
both are enforced at bind.

The accountant must approve the allocation of premium, commission, insurer liabilities, receipts,
remittances and cancellation adjustments across participants.

---

## 7. Claims

### 7.1 Operating models

**Insurer-direct** — the insurer pays the claimant. The system records administration, the
insurer's decision and payment evidence, and creates **no** brokerage cash, bank or payable entry
for funds it never handled.

**Brokerage-managed** — the brokerage receives insurer funds and pays claimants. The system
records the insurer receivable (1120), funds received, the claimant payable (2030) and payments.

### 7.2 Stages

The policy recognises eight stages — reported, assessed, internally approved, insurer confirmed,
funded, partially paid, fully paid, closed — plus two states, **Coverage under review** and
**Payment disputed**. Internal approval alone never creates a payment posting.

Today the schema has six (`notified, assessing, approved, settled, repudiated, closed`) and
neither review state. The extension is B5 and blocks UAT acceptance.

### 7.3–7.7 Review, late notification, death claims, instalments, recoveries

A claim arising while a cancellation effective date is disputed is registered and marked
*Coverage under review*; it is never auto-rejected and no insurer liability is recognised before
confirmation. A claim registered after expiry is accepted where the insured event occurred during
cover, recording incident date, client notification, insurer notification and insurer
acknowledgement, and is flagged for review rather than rejected.

Authorised representatives may report a claim after the policyholder's death. Multiple
beneficiaries are supported on percentage or fixed allocations; percentages must total 100%;
disputed shares are held until insurer confirmation or legal determination while undisputed shares
may proceed; disputed shares are never redistributed automatically.

Instalments each carry their own expected date, actual payment date, amount and evidence, and a
subsequent receipt settles the existing approved balance rather than creating fresh recognition. A
disputed direct payment is marked *Payment disputed* until resolved, with the original evidence and
the dispute retained.

Excess rules are configurable by policy terms, class, insurer agreement and claim type; authorised
overrides require reasons and audit history. Recoveries cover overpayments, third-party recoveries,
insurer underpayments, instalment recoveries, disputes and authorised write-offs.

Beneficiaries, death claims, instalments, extended stages and recoveries are all unbuilt — B10,
B5, B8. They are in the register precisely so that approving this section is not mistaken for
certifying them.

### 7.8 Confirmations required

Recognition date and entries for insurer-confirmed claims, brokerage-managed claims, excess,
recoveries, overpayments, write-offs and claim reversals.

---

## 8. Foreign currency

The books remain in UGX. The rate used at bind is preserved and is not replaced by later market
rates except through an authorised amendment or reversal. The system tracks the transaction
currency and value, the UGX equivalent at bind, the settlement rate and realised and unrealised
gain or loss separately.

Rate overrides before bind require authority, reason and audit history; once bound the rate is
locked. Realised and unrealised are separate accounts (4900/4901 gains, 5910/5911 losses, 5900
rounding).

The accountant must confirm exchange-rate sources, revaluation frequency, entries and presentation.

---

## 9. Migration and opening balances

### 9.1 Cut-over

The cut-over date is the day before production go-live. Transactions after cut-over go through the
system. Existing policies are imported as existing business with original inception and expiry
preserved — never as newly issued. Migrated policies retain accounting-policy version 1 unless an
approved migration process says otherwise. Every migrated record carries a migration identifier and
traceable source.

### 9.2 What the migration must distinguish

Historical premium bills, historical receipts, outstanding client receivables, outstanding insurer
payables, commission earned before cut-over, commission deferred at cut-over, claims receivable and
payable, statutory liabilities and foreign-currency balances. Receipts and bills already represented
in opening balances are not re-posted.

### 9.3 Reconciliation before approval

| Area | Required reconciliation |
|---|---|
| General ledger | balanced trial balance |
| Client receivables | to client and policy records |
| Insurer payables | to insurer and policy records |
| Bank balances | to bank statements |
| Commission | earned and deferred, per policy/agreement |
| Claims | receivable and payable per claim |
| Statutory liabilities | balances per recipient |
| Foreign currency | balances per currency |

Material unexplained differences prevent migration approval. Opening balances post through 3900,
which must net to zero, with commission earned up to cut-over carried in 3200 and only the unearned
remainder in 2020.

---

## 10. Accounting periods and manual journals

### 10.1 Period reopening

A closed period may be reopened only with a documented reason, appropriate senior finance approval,
independent maker-checker approval, audit history of all changes, period reclosure and retention of
the revised period-end reports. The requester never approves their own reopening.

### 10.2 Manual journals

Balanced entries; finance maker and independent checker; supporting evidence and reason; subledger
references for control-account journals; immutable posted entries; reversal or authorised adjustment
instead of editing; additional approval for restricted accounts. A manual journal must never silently
create a difference between the general ledger and an operational subledger.

There is no manual-journal path today (B6); corrections outside the documented flows currently
require raw SQL, which has no maker-checker and no subledger reference. That is why it blocks go-live.

### 10.3 Business day (DR-46)

Accounting dates follow the **Africa/Kampala** business day, not the database's UTC date. Posting
dates, the voidable date of a receipt, the closed-period test, accounting-setting lookups and
statutory-parameter lookups all resolve against the Kampala day. This decides which period a
transaction between 00:00 and 03:00 Kampala time falls into, and it applies platform-wide from
migrations `20261122090000` and `20261122100000`. A17.

---

## 11. Financial approval limits

Thresholds are configurable by transaction type, amount, currency, role, approval level and branch,
and apply separately to refunds, insurer remittances, commission transfers, claim payments,
intermediary commissions and manual journals, with multi-level approval, escalation, effective dates
and audit history. Splitting a transaction to stay under a threshold must be prevented.

Refunds of client advances now route through that engine (B7): a limit per stage, a limit per user in
addition to the stage, maker-checker that refuses self-approval, and a split flag. The refund function
itself refuses when an approved request does not cover the amount, so the workflow is enforced rather
than advisory. Three gaps are recorded rather than glossed: the routing key is **amount only**, so
currency, branch and department are not yet part of it; only client-advance refunds are routed, and
insurer remittances, commission transfers, claim payments and manual journals are not; and a split is
flagged for the approver rather than blocked, which is what this section asks for but leaves the
judgement with a person.

---

## 12. Statutory charges and taxation

### 12.1 The catalogue

Each charge names its legal basis, applicable class, calculation basis, rate or fixed amount,
exemptions, collection responsibility, remittance responsibility, statutory recipient, liability
account and effective date. A rate cannot be marked verified without citing the instrument that
verified it.

| Charge | Rate | Verified | Billed |
|---|---|---|---|
>>>>>>> theirs
| Insurance Training Levy | 0.5% of gross direct premium | **Yes** — Insurance Act s.141(3), SI No. 100 of 2020 reg. 17(2) | Yes |
| IRA regulatory levy | 1.5% (unconfirmed) | No — press summaries only | **No**, inactive |
| Stamp duty, general policy | UGX 35,000 (unconfirmed) | No — press summaries only | **No**, inactive |

No unverified charge is active as a mandatory production charge. Enforcement is `advisory` by
default: turning it to `required` makes bind refuse a policy whose charges were not priced and
acknowledged, and raises the premium of every policy bound from then on — a commercial decision,
which is why it is not the default.

### 12.2 Brokerage fees

A brokerage fee is a distinct supply from premium and from a statutory charge, recognised in 4100,
and is **VAT-exempt by default** as an insurance service (VAT Act Cap 344, Schedule 3). A separate
non-brokerage service is classified `other_taxable_service` with a stated reason and is
standard-rated. Classification, not a company-wide switch, governs the treatment — the former
`ins.broker_fee_vat` setting is withdrawn (decision 5).

Fees invoiced before 17 November 2026 under the old 18% treatment keep their VAT, because that
output tax was declared.

### 12.3 Intermediary commission taxation

Treatment is configurable per agreement; the system does not assume every intermediary commission
carries identical withholding. Withheld tax is an asset (1210), never a reduction of revenue and
never a liability of the brokerage.

---

## 13. Intermediary commission

Intermediary registration, agency agreements and commission accrual/payment are separate concerns.
The register distinguishes insurer-appointed agents, independent brokers, sub-agents and referral
partners, each agreement carrying its own rates, tax settings and accrual trigger. The agent's share
is an **expense (5010)**, not a netting of the brokerage's own commission, so both the gross
commission and the agent cost remain visible. Agents are never treated as employees.

Accrual and payment remain subject to the accountant's approval of the treatment and legal
confirmation of applicable Ugandan sub-agency requirements.

---

## 14. Client-money protection

### 14.1 Separation

Separate client-money and operating bank accounts, corresponding liability and control accounts,
tracking of funds owed to insurers, clients and beneficiaries, prevention of transfers that would
leave the client-money account short, commission transfers only where entitlement is established,
and approvals with audit history.

Segregation is enforced in the schema today: a bank account cannot change between operating and
client money, and two bank accounts cannot share a GL account.

### 14.2 Daily reconciliation
<<<<<<< ours

A designated finance officer completes a daily client-money reconciliation comparing bank balance,
cashbook, client-money liabilities, unallocated advances, available commission and unmatched items;
a separate person independently reviews it; missed reconciliations are escalated.

### 14.3 Shortage response

A suspected shortage raises a high-priority alert and an incident record, notifies management,
restricts commission transfers and non-essential withdrawals, and requires independent approval to
release those restrictions. The system must distinguish a genuine shortage from a delayed bank feed.
Essential or legally required payments follow a controlled exception process.

The position test at transfer time, the daily artefact, reviewer independence and the incident flow
are B9 and block go-live.

---

## 15. Financial reporting

PDF and Excel exports and printable layouts; filters for date and period, branch, class, insurer,
client and currency; every report identifies its generation date and user and distinguishes draft,
pending, approved and posted.

The dashboard covers premium production, earned and deferred commission, client receivables, insurer
balances and remittances, claims exposure, cancellations and refunds, client-money and operating-bank
positions, foreign exchange, and profitability by branch, insurer and class, with actual, forecast and
pending amounts distinguished.

All financial reports reconcile to the general ledger and supporting subledgers.

---

## 16. Sign-off register

The tables below are generated from `signoff-register.json`. The JSON is the source of truth; CI
checks that every setting named exists, that the value claimed as approved is one the database
allows, and that every evidence file cited exists. Edit the JSON and run
`node scripts/gen-signoff-register.mjs`; never edit the block by hand.

<!-- BEGIN GENERATED: SIGN-OFF REGISTER -->
<!-- Do not edit by hand. Edit docs/insurance-brokerage/signoff-register.json and run
     node scripts/gen-signoff-register.mjs -->

### 16.1 Accounting policy items (A-register)

Each item is the accounting treatment the software is expected to implement. `reviewed_at`
is filled only when the appointed reviewer has signed that item in section 18.

| Ref | Decision area | Approver | Code | Selected settings | Required before | Evidence |
|---|---|---|---|---|---|---|
| **A1** | Premium recognition and pre-binding advances | accountant | Partly built | — | UAT acceptance | — |
| **A2** | Insurer settlement: gross basis and net exceptions | accountant + legal | Built | `ins.insurer_remittance_basis` = **gross_premium** | production go-live | `test_ins_settlement_basis.sql`<br>`test_ins_commission.sql` |
| **A3** | Commission recognition methods | accountant | Partly built | `ins.commission_recognition` = **explicit_per_agreement** *(not yet implemented)* | UAT acceptance | `test_ins_commission_recognition_mode.sql`<br>`test_ins_commission_on_premium_collection.sql`<br>`test_ins_commission_pro_rata.sql` |
| **A4** | Partial collection and commission clawbacks | accountant | Partly built | `ins.commission_recognition` = **pro_rata_on_collection** *(not yet implemented)* | UAT acceptance | `test_ins_commission_pro_rata.sql`<br>`test_ins_cancellation_posting.sql` |
| **A5** | Co-insurance accounting | accountant | Built | — | production go-live | `test_ins_coinsurance_charges.sql` |
| **A6** | Cancellation, refunds and return premium | accountant | Built | `ins.cancellation_treatment` = **pro_rata_refund** | production go-live | `test_ins_cancellation_calculation.sql`<br>`test_ins_cancellation_posting.sql`<br>`test_ins_cancellation_cash.sql` |
| **A7** | Claims accounting and recoveries | accountant | Partly built | — | production go-live | `test_ins_claim_payments.sql`<br>`test_ins_claim_reserve_revisions.sql`<br>`test_ins_claim_documents.sql` |
| **A8** | Foreign currency and revaluation | accountant | Built | — | production go-live | `test_foreign_bind_transfer.sql`<br>`test_foreign_cancellation.sql`<br>`test_foreign_claims.sql` |
| **A9** | Migration and opening balances | accountant | Built | `migration.earned_commission_treatment` = **opening_balances**<br>`migration.partially_paid_import` = **full_billed_plus_receipts** | production go-live | `test_ins_import_opening_from_history.sql`<br>`test_ins_import_control_totals.sql`<br>`test_ins_opening_acceptance_gate.sql` |
| **A10** | Accounting periods and manual journals | accountant | Partly built | — | production go-live | `test_fin_period_controls.sql` |
| **A11** | Financial approval limits | accountant | Not built | — | production go-live | `test_ins_finance_pending_approvals.sql` |
| **A12** | Client-money accounting and reconciliation | accountant | Partly built | — | production go-live | `test_fin_bank_accounts.sql`<br>`test_bank_reconciliation.sql`<br>`test_ins_policy_cash.sql` |
| **A13** | Statutory charges and remittances | accountant + legal | Built | `ins.statutory_charge_enforcement` = **advisory** | production go-live | `test_ins_statutory_charge_catalogue.sql`<br>`test_ins_statutory_charges_on_policy.sql`<br>`test_ins_statutory_charge_trace.sql` |
| **A14** | VAT, withholding tax and broker-fee classification | accountant + tax | Built | `ins.agent_commission_taxable` = **taxable**<br>`ins.agent_commission_wht` = **applicable**<br>`ins.agent_commission_basis` = **gross_commission** | production go-live | `test_ins_client_broker_fees.sql`<br>`test_ins_agent_commission.sql`<br>`test_wht_posting.sql` |
| **A15** | Intermediary commission accounting | accountant + legal | Built | — | production go-live | `test_ins_agent_commission.sql`<br>`test_ins_intermediaries.sql` |
| **A16** | Financial reporting and reconciliation | accountant | Built | — | production go-live | `test_ins_reports_batch1.sql`<br>`test_ins_reports_batch2.sql`<br>`test_ins_reports_batch3.sql`<br>`test_ins_reports_batch4.sql`<br>`test_ins_dashboard_summary.sql` |
| **A17** | Business day and posting-date rules (DR-46) | accountant | Built | — | production go-live | `test_fin_period_controls.sql`<br>`test_ins_reports_batch1.sql` |
| **A18** | Endorsement cancellation and financial reversal | accountant | Built | — | production go-live | `test_endorsement_cancellation.sql`<br>`test_endorsement_posting.sql` |
| **A19** | Opening position, retained earnings and migration balancing | accountant | Built | `migration.earned_commission_treatment` = **opening_balances** | production go-live | `test_ins_import_opening_from_history.sql`<br>`test_ins_opening_acceptance_gate.sql` |
| **A20** | Broker-fee classification and its accounting and tax treatment | accountant + tax | Built | — | production go-live | `test_ins_client_broker_fees.sql` |

### 16.2 Committed but not built (B-register)

These are controls and features the policy assumes. **They are not built.** The reviewer is
asked to approve the *policy* in §16.1 while acknowledging these as committed work with the
gate shown. An item blocking "production go-live" must be complete before live posting; an
item blocking "UAT acceptance" must be complete before the business signs UAT.

| Ref | Feature | Status | Depends on | Blocks | Acceptance criteria |
|---|---|---|---|---|---|
| **B1** | pro_rata_on_collection commission recognition | Not built | A3, A4 | UAT acceptance | A partial collection of 50% of premium earns exactly 50% of commission, the remainder stays in 2020, a further collection earns the balance, and voiding a receipt reverses only the portion that receipt earned. |
| **B2** | Unallocated client advances | Not built | A1 | UAT acceptance | A receipt with no policy creates a 2040 credit and no receivable; binding a policy allocates it and clears 2040; an unallocated advance is visible on the client statement as a liability and is refundable. |
| **B3** | Fail-closed commission-mode selection | Not built | A3 | UAT acceptance | A policy on an insurer with no configured mode cannot bind and the error names the insurer and the missing setting; configuring the mode allows the bind and the chosen mode is frozen into the accounting snapshot. |
| **B4** | Three cancellation dates | Not built | A6 | UAT acceptance | A cancellation requested in period 1, effective in period 2 and settled in period 3 posts to the settlement period while reporting its effective date; a backdated effective date without evidence is refused. |
| **B5** | Claim stage model and the two review states (built) | built | A7 | UAT acceptance | A claim moves through all eight stages with an audit row each; internal approval creates no journal; insurer confirmation creates the receivable; partial payment leaves a visible balance; a disputed payment is excluded from settled totals. |
| **B6** | Manual journals with maker-checker | Not built | A10 | production go-live | A manual journal cannot post unbalanced, cannot be approved by its maker, cannot post to a control account without a subledger reference, and cannot be edited after posting. |
| **B7** | Approval limits and split prevention (built) | built | A11 | production go-live | A refund above a user's limit routes to the next level; the same user cannot approve it; two same-day refunds to the same payee just under the limit are flagged as a possible split. |
| **B8** | Claims recoveries and write-offs (built) | built | A7 | production go-live | A recovery is raised against a claim, allocated when received, and never touches commission accounts; a write-off requires approval and posts to an identifiable account. |
| **B9** | Daily client-money reconciliation and shortage response | Not built | A12 | production go-live | A transfer that would leave the client-money position negative is refused; two consecutive missed reconciliations escalate; a shortage raises an incident and blocks further transfers until independently released. |
| **B10** | Beneficiaries, death claims and instalment settlements (built) | built | A7 | UAT acceptance | A death claim records the representative and beneficiaries; percentages must total 100%; a disputed share is held while undisputed shares pay; a second instalment reduces the balance without a new claim accrual. |
| **B11** | Non-cash party-balance movement (dispositions) -- built | built | B2 | production go-live | A release of 250,000 leaves 2040 down by 250,000 and AR down by 250,000 with the bank unchanged; the open item shows the consumption; over-release is refused; a write-off reduces 2030 into the named expense account; commission accounts are refused; a control account cannot be the counterparty; a disposition cannot be edited or deleted. |

<!-- END GENERATED: SIGN-OFF REGISTER -->

---

## 17. Review outcome

For each A-item the reviewer selects one: **Approved** · **Approved subject to conditions** ·
**Amend and resubmit** · **Not approved** · **Further information required**.

Conditions and outstanding actions are recorded against the item. Approval at the policy gate does
not constitute UAT acceptance or production approval, and the three gates in §1 are signed
separately.

---

## 18. Formal sign-off

**Appointed Accountant**

Name: ______________________________________________

Professional qualification: _________________________

Professional registration (if applicable): __________

Signature: _________________________________________

>>>>>>> theirs
Date: ______________________________________________

**Legal adviser (where applicable)**

Name: ______________________________________________

Qualification / organisation: _______________________

Signature: _________________________________________

Date: ______________________________________________

**Tax adviser (where applicable)**

Name: ______________________________________________

Signature: _________________________________________

Date: ______________________________________________

**System owner**

Name: ______________________________________________

Signature: _________________________________________

Date: ______________________________________________

### Gate 1 — Accounting policy approval

- [ ] Approved for production accounting policy, subject to conditions
- [ ] Approved for production accounting policy without outstanding conditions
- [ ] Amend and resubmit

### Gate 2 — UAT acceptance

- [ ] UAT accepted for the B-items scoped to UAT (§16.2)
- [ ] UAT accepted with conditions: ______________________

### Gate 3 — Production go-live

- [ ] All B-items blocking go-live closed and evidenced
- [ ] Go-live approved

**Conditions / outstanding matters:**

_______________________________________________________________________

_______________________________________________________________________

_______________________________________________________________________

---

## Appendix A — Decisions taken in version 2

| # | Decision | Effect on the software |
|---|---|---|
| 1 | `pro_rata_on_collection` is a fourth recognition mode; binary collection behaviour preserved for agreements that are all-or-nothing | New mode + branch in the recognition trigger (B1) |
| 2 | Recognition mode is fail-closed: no policy binds without an explicit mode for its insurer agreement | Removes the silent `on_insurer_settlement` fallback (B3) |
| 3 | Claims: build the stage model and the two review states now; beneficiaries, death claims, instalments and recoveries are committed-but-unbuilt | B5 in UAT scope; B8/B10 registered |
| 4 | Unallocated client advances are built now — new liability account, receipt tracking, allocation and release on bind | New account 2040, role `client_advance_payable` (B2) |
| 5 | `ins.broker_fee_vat` is removed rather than retained; the decision history stays in documentation | Migration deletes the setting |
| 6 | Version 2 replaces `ACCOUNTANT_PACK.md`; version 1 archived as `ACCOUNTANT_PACK_v1_superseded.md` | This document |
| 7 | The register is machine-readable and CI validates settings against implemented values | `signoff-register.json` + two scripts |
| 8 | Sign-off is for the production accounting policy, with UAT acceptance and go-live as separate gates | §1 |

## Appendix B — open questions the code refuses to answer for you

These are accounting-policy choices. The software now makes each one *expressible*
without choosing it, because guessing would be the software writing policy — the
thing this pack exists to prevent. Each needs an answer before the gate shown.

| # | Question | Where the software stands | Needed by |
|---|---|---|---|
| Q1 | **Which account absorbs a claim write-off?** A claim balance on 2030 has to go somewhere when it is written off. Options: a bad-debt expense, a dedicated "claim write-offs" expense, or against commission income (rejected in code — see below). | `ins_write_off_claim()` requires the caller to name the account. It must be a real, non-control expense or revenue account, and commission accounts (4000, 2020, 1110) are **refused by name**. No default exists. | production go-live (B8) |
| Q2 | **Is an unapplied client advance released or forfeited?** If a client pays before placement and the policy never binds, the money is a liability until refunded. If the brokerage is entitled to keep it, that is a `advance_forfeit` — a different posting from a release, and taxable in a way a release is not. | Both kinds exist (`advance_release`, `advance_forfeit`). `advance_release` is forced by double entry to Dr 2040 / Cr AR. `advance_forfeit` has no built caller: no one has said when forfeiture is appropriate. | UAT acceptance (B2) |
| Q3 | **Repudiation is a ninth state.** §7.2 lists eight stages and omits it. | `repudiated` exists in the schema, is required, and is reported by `ins_claim_stage()`. It was kept rather than dropped to match the list. | policy approval |
| Q4 | **Which account absorbs a recovery credit?** A recovery raised against a claim credits *some* account when it is recognised. Recovery income, a contra against the loss the claim created, or netted into the insurer's account are all defensible, and the choice changes both the income statement and the net claim cost. | `ins_raise_claim_recovery()` requires the caller to name a real, non-control account. Commission accounts are refused. Writing the recovery off later charges the loss back to the same account, which is stored on the row rather than derived. No default. | production go-live (B8) |

On Q1, the reason commission accounts are refused in code rather than left to
judgement: §7.7 says a recovery "never touches commission accounts". A write-off is
absorbed by a loss account; charging it to commission income would restate brokerage
revenue for a claim the brokerage never earned on, and would do so silently in the
period the write-off was made rather than the period the claim arose.

## Appendix B — What version 1 said that version 2 changes

<<<<<<< ours
>>>>>>> theirs
=======
>>>>>>> theirs
=======

**Pro-rata worked example (the mode that is not built yet — B1)**

| Description | Amount |
|---|---|
| Premium | UGX 1,000,000 |
| Commission rate | 10% |
| Total commission | UGX 100,000 |
| First collection | UGX 500,000 |
| Commission recognised | UGX 50,000 |
| Commission deferred (2020) | UGX 50,000 |

Receipt reversals and refunds trigger corresponding commission adjustments at the same booked
rate. Voiding a receipt un-earns what that receipt earned and never leaves income standing on
money that came back.

### 4.4 No silent default

Every policy must have an explicit recognition mode in force at bind. Binding a policy whose
insurer agreement has no configured mode **fails** and names the insurer and the missing setting.
`on_insurer_settlement` remains available but must be chosen; it is no longer a fallback. This is
B3, and it is the change that makes the per-agreement classification in this section actually
load-bearing.

### 4.5 Settlement and recognition are separate dimensions

Not every combination is sensible. Gross settlement with `on_premium_collection` or
`pro_rata_on_collection` cannot coexist — under gross the premium crosses in full, so there is
nothing left to collect — and the software refuses the combination by name at bind rather than
silently choosing one. The remainder of the compatibility matrix is for the accountant to approve,
particularly where net settlement changes the timing or legal basis of the entitlement.

### 4.6 Confirmations required

Which insurer agreements are `at_placement`, `on_premium_collection`, `pro_rata_on_collection` or
`on_insurer_settlement`; that the collection triggers are the **client's** receipt and not the
insurer's settlement or a credit note; that a voided receipt reverses recognition; the
compatibility matrix; and the deferred-commission and income accounts.

---

## 5. Cancellations, refunds and clawbacks

### 5.1 Principles

A cancellation preserves the original policy and financial history. The system records three
separate dates: cancellation requested, cancellation effective, and financial settlement. The
effective date must be supported by insurer confirmation or another appropriate authority.
Backdated cancellations require evidence, a reason and authorised approval. Closed periods are
never silently rewritten.

Three dates are policy and all three are now modelled (B4). The request date is the moment the
cancellation was entered; the effective date is the coverage date; the settlement date is the period
the cancellation financially falls into. The settlement date is derived from the cash rather than typed
in, so a person cannot move a cancellation between periods by editing a field. A backdated effective
date requires dated evidence, and is refused at submission and again at posting.

### 5.2 Return premium

Distinguish: return premium requested, approved, actually received or credited; client refund
payable; client refund actually paid; deductions and charges. An approved refund is never treated
as cash received, and no insurer receivable is created merely because a refund was requested. A
separate client refund obligation may still arise where the brokerage has an independent
contractual or legal duty to refund.

### 5.3 Deductions are never automatically income

| Deduction | Belongs to |
|---|---|
| Insurer-retained short-period premium | the insurer |
| Brokerage cancellation fee | the brokerage, only where contractually authorised |
| Statutory charges | the relevant statutory recipient |
| Other authorised deductions | the appropriate beneficiary |

The difference between original and return premium never becomes brokerage income by default.

### 5.4 Commission clawback

Proportional to the **approved** return premium, and never more than commission previously
recognised. Where commission has already been transferred to operating funds, record the clawback
against the original transaction, identify what is recoverable from operating funds, replenish
client money where necessary, block further transfers if the client-money position is deficient,
and require approval with a retained audit trail.

In the ledger the clawback is absorbed in a fixed order: the deferred pool (2020) first, then
recognised income (4000), then a recoverable from operating funds. Those are three different
movements, not one.

### 5.5 Confirmations required

Credit-note and reversal entries; whether returned commission goes back to deferred or reverses
income; treatment of transferred commission; approved-but-unpaid return premiums; the accounting
date for a backdated cancellation; cancellation after insurer settlement.

---

## 6. Co-insurance

Each participating insurer has independent records for participation percentage, lead status,
commission rate, settlement method, recognition trigger, tax treatment, receipts and outstanding
balances, and cancellation adjustments. Shares must total 100% with exactly one lead insurer;
both are enforced at bind.

The accountant must approve the allocation of premium, commission, insurer liabilities, receipts,
remittances and cancellation adjustments across participants.

---

## 7. Claims

### 7.1 Operating models

**Insurer-direct** — the insurer pays the claimant. The system records administration, the
insurer's decision and payment evidence, and creates **no** brokerage cash, bank or payable entry
for funds it never handled.

**Brokerage-managed** — the brokerage receives insurer funds and pays claimants. The system
records the insurer receivable (1120), funds received, the claimant payable (2030) and payments.

### 7.2 Stages

The policy recognises eight stages — reported, assessed, internally approved, insurer confirmed,
funded, partially paid, fully paid, closed — plus two states, **Coverage under review** and
**Payment disputed**. Internal approval alone never creates a payment posting.

Today the schema has six (`notified, assessing, approved, settled, repudiated, closed`) and
neither review state. The extension is B5 and blocks UAT acceptance.

### 7.3–7.7 Review, late notification, death claims, instalments, recoveries

A claim arising while a cancellation effective date is disputed is registered and marked
*Coverage under review*; it is never auto-rejected and no insurer liability is recognised before
confirmation. A claim registered after expiry is accepted where the insured event occurred during
cover, recording incident date, client notification, insurer notification and insurer
acknowledgement, and is flagged for review rather than rejected.

Authorised representatives may report a claim after the policyholder's death. Multiple
beneficiaries are supported on percentage or fixed allocations; percentages must total 100%;
disputed shares are held until insurer confirmation or legal determination while undisputed shares
may proceed; disputed shares are never redistributed automatically.

Instalments each carry their own expected date, actual payment date, amount and evidence, and a
subsequent receipt settles the existing approved balance rather than creating fresh recognition. A
disputed direct payment is marked *Payment disputed* until resolved, with the original evidence and
the dispute retained.

Excess rules are configurable by policy terms, class, insurer agreement and claim type; authorised
overrides require reasons and audit history. Recoveries cover overpayments, third-party recoveries,
insurer underpayments, instalment recoveries, disputes and authorised write-offs.

Beneficiaries, death claims, instalments, extended stages and recoveries are all unbuilt — B10,
B5, B8. They are in the register precisely so that approving this section is not mistaken for
certifying them.

### 7.8 Confirmations required

Recognition date and entries for insurer-confirmed claims, brokerage-managed claims, excess,
recoveries, overpayments, write-offs and claim reversals.

---

## 8. Foreign currency

The books remain in UGX. The rate used at bind is preserved and is not replaced by later market
rates except through an authorised amendment or reversal. The system tracks the transaction
currency and value, the UGX equivalent at bind, the settlement rate and realised and unrealised
gain or loss separately.

Rate overrides before bind require authority, reason and audit history; once bound the rate is
locked. Realised and unrealised are separate accounts (4900/4901 gains, 5910/5911 losses, 5900
rounding).

The accountant must confirm exchange-rate sources, revaluation frequency, entries and presentation.

---

## 9. Migration and opening balances

### 9.1 Cut-over

The cut-over date is the day before production go-live. Transactions after cut-over go through the
system. Existing policies are imported as existing business with original inception and expiry
preserved — never as newly issued. Migrated policies retain accounting-policy version 1 unless an
approved migration process says otherwise. Every migrated record carries a migration identifier and
traceable source.

### 9.2 What the migration must distinguish

Historical premium bills, historical receipts, outstanding client receivables, outstanding insurer
payables, commission earned before cut-over, commission deferred at cut-over, claims receivable and
payable, statutory liabilities and foreign-currency balances. Receipts and bills already represented
in opening balances are not re-posted.

### 9.3 Reconciliation before approval

| Area | Required reconciliation |
|---|---|
| General ledger | balanced trial balance |
| Client receivables | to client and policy records |
| Insurer payables | to insurer and policy records |
| Bank balances | to bank statements |
| Commission | earned and deferred, per policy/agreement |
| Claims | receivable and payable per claim |
| Statutory liabilities | balances per recipient |
| Foreign currency | balances per currency |

Material unexplained differences prevent migration approval. Opening balances post through 3900,
which must net to zero, with commission earned up to cut-over carried in 3200 and only the unearned
remainder in 2020.

---

## 10. Accounting periods and manual journals

### 10.1 Period reopening

A closed period may be reopened only with a documented reason, appropriate senior finance approval,
independent maker-checker approval, audit history of all changes, period reclosure and retention of
the revised period-end reports. The requester never approves their own reopening.

### 10.2 Manual journals

Balanced entries; finance maker and independent checker; supporting evidence and reason; subledger
references for control-account journals; immutable posted entries; reversal or authorised adjustment
instead of editing; additional approval for restricted accounts. A manual journal must never silently
create a difference between the general ledger and an operational subledger.

There is no manual-journal path today (B6); corrections outside the documented flows currently
require raw SQL, which has no maker-checker and no subledger reference. That is why it blocks go-live.

### 10.3 Business day (DR-46)

Accounting dates follow the **Africa/Kampala** business day, not the database's UTC date. Posting
dates, the voidable date of a receipt, the closed-period test, accounting-setting lookups and
statutory-parameter lookups all resolve against the Kampala day. This decides which period a
transaction between 00:00 and 03:00 Kampala time falls into, and it applies platform-wide from
migrations `20261122090000` and `20261122100000`. A17.

---

## 11. Financial approval limits

Thresholds are configurable by transaction type, amount, currency, role, approval level and branch,
and apply separately to refunds, insurer remittances, commission transfers, claim payments,
intermediary commissions and manual journals, with multi-level approval, escalation, effective dates
and audit history. Splitting a transaction to stay under a threshold must be prevented.

Refunds of client advances now route through that engine (B7): a limit per stage, a limit per user in
addition to the stage, maker-checker that refuses self-approval, and a split flag. The refund function
itself refuses when an approved request does not cover the amount, so the workflow is enforced rather
than advisory. Three gaps are recorded rather than glossed: the routing key is **amount only**, so
currency, branch and department are not yet part of it; only client-advance refunds are routed, and
insurer remittances, commission transfers, claim payments and manual journals are not; and a split is
flagged for the approver rather than blocked, which is what this section asks for but leaves the
judgement with a person.

---

## 12. Statutory charges and taxation

### 12.1 The catalogue

Each charge names its legal basis, applicable class, calculation basis, rate or fixed amount,
exemptions, collection responsibility, remittance responsibility, statutory recipient, liability
account and effective date. A rate cannot be marked verified without citing the instrument that
verified it.

| Charge | Rate | Verified | Billed |
|---|---|---|---|
| Insurance Training Levy | 0.5% of gross direct premium | **Yes** — Insurance Act s.141(3), SI No. 100 of 2020 reg. 17(2) | Yes |
| IRA regulatory levy | 1.5% (unconfirmed) | No — press summaries only | **No**, inactive |
| Stamp duty, general policy | UGX 35,000 (unconfirmed) | No — press summaries only | **No**, inactive |

No unverified charge is active as a mandatory production charge. Enforcement is `advisory` by
default: turning it to `required` makes bind refuse a policy whose charges were not priced and
acknowledged, and raises the premium of every policy bound from then on — a commercial decision,
which is why it is not the default.

### 12.2 Brokerage fees

A brokerage fee is a distinct supply from premium and from a statutory charge, recognised in 4100,
and is **VAT-exempt by default** as an insurance service (VAT Act Cap 344, Schedule 3). A separate
non-brokerage service is classified `other_taxable_service` with a stated reason and is
standard-rated. Classification, not a company-wide switch, governs the treatment — the former
`ins.broker_fee_vat` setting is withdrawn (decision 5).

Fees invoiced before 17 November 2026 under the old 18% treatment keep their VAT, because that
output tax was declared.

### 12.3 Intermediary commission taxation

Treatment is configurable per agreement; the system does not assume every intermediary commission
carries identical withholding. Withheld tax is an asset (1210), never a reduction of revenue and
never a liability of the brokerage.

---

## 13. Intermediary commission

Intermediary registration, agency agreements and commission accrual/payment are separate concerns.
The register distinguishes insurer-appointed agents, independent brokers, sub-agents and referral
partners, each agreement carrying its own rates, tax settings and accrual trigger. The agent's share
is an **expense (5010)**, not a netting of the brokerage's own commission, so both the gross
commission and the agent cost remain visible. Agents are never treated as employees.

Accrual and payment remain subject to the accountant's approval of the treatment and legal
confirmation of applicable Ugandan sub-agency requirements.

---

## 14. Client-money protection

### 14.1 Separation

Separate client-money and operating bank accounts, corresponding liability and control accounts,
tracking of funds owed to insurers, clients and beneficiaries, prevention of transfers that would
leave the client-money account short, commission transfers only where entitlement is established,
and approvals with audit history.

Segregation is enforced in the schema today: a bank account cannot change between operating and
client money, and two bank accounts cannot share a GL account.

### 14.2 Daily reconciliation

A designated finance officer completes a daily client-money reconciliation comparing bank balance,
cashbook, client-money liabilities, unallocated advances, available commission and unmatched items;
a separate person independently reviews it; missed reconciliations are escalated.

### 14.3 Shortage response

A suspected shortage raises a high-priority alert and an incident record, notifies management,
restricts commission transfers and non-essential withdrawals, and requires independent approval to
release those restrictions. The system must distinguish a genuine shortage from a delayed bank feed.
Essential or legally required payments follow a controlled exception process.

The position test at transfer time, the daily artefact, reviewer independence and the incident flow
are B9 and block go-live.

---

## 15. Financial reporting

PDF and Excel exports and printable layouts; filters for date and period, branch, class, insurer,
client and currency; every report identifies its generation date and user and distinguishes draft,
pending, approved and posted.

=======

A designated finance officer completes a daily client-money reconciliation comparing bank balance,
cashbook, client-money liabilities, unallocated advances, available commission and unmatched items;
a separate person independently reviews it; missed reconciliations are escalated.

### 14.3 Shortage response

A suspected shortage raises a high-priority alert and an incident record, notifies management,
restricts commission transfers and non-essential withdrawals, and requires independent approval to
release those restrictions. The system must distinguish a genuine shortage from a delayed bank feed.
Essential or legally required payments follow a controlled exception process.

The position test at transfer time, the daily artefact, reviewer independence and the incident flow
are B9 and block go-live.

---

## 15. Financial reporting

PDF and Excel exports and printable layouts; filters for date and period, branch, class, insurer,
client and currency; every report identifies its generation date and user and distinguishes draft,
pending, approved and posted.

>>>>>>> theirs
The dashboard covers premium production, earned and deferred commission, client receivables, insurer
balances and remittances, claims exposure, cancellations and refunds, client-money and operating-bank
positions, foreign exchange, and profitability by branch, insurer and class, with actual, forecast and
pending amounts distinguished.

All financial reports reconcile to the general ledger and supporting subledgers.

---

## 16. Sign-off register

The tables below are generated from `signoff-register.json`. The JSON is the source of truth; CI
checks that every setting named exists, that the value claimed as approved is one the database
allows, and that every evidence file cited exists. Edit the JSON and run
`node scripts/gen-signoff-register.mjs`; never edit the block by hand.

<!-- BEGIN GENERATED: SIGN-OFF REGISTER -->
<!-- Do not edit by hand. Edit docs/insurance-brokerage/signoff-register.json and run
     node scripts/gen-signoff-register.mjs -->

### 16.1 Accounting policy items (A-register)

Each item is the accounting treatment the software is expected to implement. `reviewed_at`
is filled only when the appointed reviewer has signed that item in section 18.

| Ref | Decision area | Approver | Code | Selected settings | Required before | Evidence |
|---|---|---|---|---|---|---|
| **A1** | Premium recognition and pre-binding advances | accountant | Partly built | — | UAT acceptance | — |
| **A2** | Insurer settlement: gross basis and net exceptions | accountant + legal | Built | `ins.insurer_remittance_basis` = **gross_premium** | production go-live | `test_ins_settlement_basis.sql`<br>`test_ins_commission.sql` |
<<<<<<< ours
| **A3** | Commission recognition methods | accountant | Partly built | `ins.commission_recognition` = **explicit_per_agreement** *(not yet implemented)* | UAT acceptance | `test_ins_commission_recognition_mode.sql`<br>`test_ins_commission_on_premium_collection.sql`<br>`test_ins_commission_pro_rata.sql` |
=======
| **A3** | Commission recognition methods | accountant | Partly built | `ins.commission_recognition` = **explicit_per_agreement** *(not yet implemented)* | UAT acceptance | `test_ins_commission_recognition_mode.sql`<br>`test_ins_commission_on_premium_collection.sql`<br>`test_ins_commission_pro_rata.sql`<br>`test_ins_insurer_commission_terms.sql` |
>>>>>>> theirs
| **A4** | Partial collection and commission clawbacks | accountant | Partly built | `ins.commission_recognition` = **pro_rata_on_collection** *(not yet implemented)* | UAT acceptance | `test_ins_commission_pro_rata.sql`<br>`test_ins_cancellation_posting.sql` |
| **A5** | Co-insurance accounting | accountant | Built | — | production go-live | `test_ins_coinsurance_charges.sql` |
| **A6** | Cancellation, refunds and return premium | accountant | Built | `ins.cancellation_treatment` = **pro_rata_refund** | production go-live | `test_ins_cancellation_calculation.sql`<br>`test_ins_cancellation_posting.sql`<br>`test_ins_cancellation_cash.sql` |
| **A7** | Claims accounting and recoveries | accountant | Partly built | — | production go-live | `test_ins_claim_payments.sql`<br>`test_ins_claim_reserve_revisions.sql`<br>`test_ins_claim_documents.sql` |
| **A8** | Foreign currency and revaluation | accountant | Built | — | production go-live | `test_foreign_bind_transfer.sql`<br>`test_foreign_cancellation.sql`<br>`test_foreign_claims.sql` |
| **A9** | Migration and opening balances | accountant | Built | `migration.earned_commission_treatment` = **opening_balances**<br>`migration.partially_paid_import` = **full_billed_plus_receipts** | production go-live | `test_ins_import_opening_from_history.sql`<br>`test_ins_import_control_totals.sql`<br>`test_ins_opening_acceptance_gate.sql` |
| **A10** | Accounting periods and manual journals | accountant | Partly built | — | production go-live | `test_fin_period_controls.sql` |
| **A11** | Financial approval limits | accountant | Not built | — | production go-live | `test_ins_finance_pending_approvals.sql` |
| **A12** | Client-money accounting and reconciliation | accountant | Partly built | — | production go-live | `test_fin_bank_accounts.sql`<br>`test_bank_reconciliation.sql`<br>`test_ins_policy_cash.sql` |
| **A13** | Statutory charges and remittances | accountant + legal | Built | `ins.statutory_charge_enforcement` = **advisory** | production go-live | `test_ins_statutory_charge_catalogue.sql`<br>`test_ins_statutory_charges_on_policy.sql`<br>`test_ins_statutory_charge_trace.sql` |
| **A14** | VAT, withholding tax and broker-fee classification | accountant + tax | Built | `ins.agent_commission_taxable` = **taxable**<br>`ins.agent_commission_wht` = **applicable**<br>`ins.agent_commission_basis` = **gross_commission** | production go-live | `test_ins_client_broker_fees.sql`<br>`test_ins_agent_commission.sql`<br>`test_wht_posting.sql` |
| **A15** | Intermediary commission accounting | accountant + legal | Built | — | production go-live | `test_ins_agent_commission.sql`<br>`test_ins_intermediaries.sql` |
| **A16** | Financial reporting and reconciliation | accountant | Built | — | production go-live | `test_ins_reports_batch1.sql`<br>`test_ins_reports_batch2.sql`<br>`test_ins_reports_batch3.sql`<br>`test_ins_reports_batch4.sql`<br>`test_ins_dashboard_summary.sql` |
| **A17** | Business day and posting-date rules (DR-46) | accountant | Built | — | production go-live | `test_fin_period_controls.sql`<br>`test_ins_reports_batch1.sql` |
| **A18** | Endorsement cancellation and financial reversal | accountant | Built | — | production go-live | `test_endorsement_cancellation.sql`<br>`test_endorsement_posting.sql` |
| **A19** | Opening position, retained earnings and migration balancing | accountant | Built | `migration.earned_commission_treatment` = **opening_balances** | production go-live | `test_ins_import_opening_from_history.sql`<br>`test_ins_opening_acceptance_gate.sql` |
| **A20** | Broker-fee classification and its accounting and tax treatment | accountant + tax | Built | — | production go-live | `test_ins_client_broker_fees.sql` |

### 16.2 Committed but not built (B-register)

These are controls and features the policy assumes. **They are not built.** The reviewer is
asked to approve the *policy* in §16.1 while acknowledging these as committed work with the
gate shown. An item blocking "production go-live" must be complete before live posting; an
item blocking "UAT acceptance" must be complete before the business signs UAT.

| Ref | Feature | Status | Depends on | Blocks | Acceptance criteria |
|---|---|---|---|---|---|
| **B1** | pro_rata_on_collection commission recognition | Not built | A3, A4 | UAT acceptance | A partial collection of 50% of premium earns exactly 50% of commission, the remainder stays in 2020, a further collection earns the balance, and voiding a receipt reverses only the portion that receipt earned. |
| **B2** | Unallocated client advances | Not built | A1 | UAT acceptance | A receipt with no policy creates a 2040 credit and no receivable; binding a policy allocates it and clears 2040; an unallocated advance is visible on the client statement as a liability and is refundable. |
<<<<<<< ours
| **B3** | Fail-closed commission-mode selection | Not built | A3 | UAT acceptance | A policy on an insurer with no configured mode cannot bind and the error names the insurer and the missing setting; configuring the mode allows the bind and the chosen mode is frozen into the accounting snapshot. |
=======
| **B3** | Fail-closed commission-mode selection (built) | built | A3 | UAT acceptance | A policy on an insurer with no configured mode cannot bind and the error names the insurer and the missing setting; configuring the mode allows the bind and the chosen mode is frozen into the accounting snapshot. |
>>>>>>> theirs
| **B4** | Three cancellation dates (built) | built | A6 | UAT acceptance | A cancellation requested in period 1, effective in period 2 and settled in period 3 posts to the settlement period while reporting its effective date; a backdated effective date without evidence is refused. |
| **B5** | Claim stage model and the two review states (built) | built | A7 | UAT acceptance | A claim moves through all eight stages with an audit row each; internal approval creates no journal; insurer confirmation creates the receivable; partial payment leaves a visible balance; a disputed payment is excluded from settled totals. |
| **B6** | Manual journals with maker-checker | Not built | A10 | production go-live | A manual journal cannot post unbalanced, cannot be approved by its maker, cannot post to a control account without a subledger reference, and cannot be edited after posting. |
| **B7** | Approval limits and split prevention (built) | built | A11 | production go-live | A refund above a user's limit routes to the next level; the same user cannot approve it; two same-day refunds to the same payee just under the limit are flagged as a possible split. |
| **B8** | Claims recoveries and write-offs (built) | built | A7 | production go-live | A recovery is raised against a claim, allocated when received, and never touches commission accounts; a write-off requires approval and posts to an identifiable account. |
| **B9** | Daily client-money reconciliation and shortage response | Not built | A12 | production go-live | A transfer that would leave the client-money position negative is refused; two consecutive missed reconciliations escalate; a shortage raises an incident and blocks further transfers until independently released. |
| **B10** | Beneficiaries, death claims and instalment settlements (built) | built | A7 | UAT acceptance | A death claim records the representative and beneficiaries; percentages must total 100%; a disputed share is held while undisputed shares pay; a second instalment reduces the balance without a new claim accrual. |
| **B11** | Non-cash party-balance movement (dispositions) -- built | built | B2 | production go-live | A release of 250,000 leaves 2040 down by 250,000 and AR down by 250,000 with the bank unchanged; the open item shows the consumption; over-release is refused; a write-off reduces 2030 into the named expense account; commission accounts are refused; a control account cannot be the counterparty; a disposition cannot be edited or deleted. |

<!-- END GENERATED: SIGN-OFF REGISTER -->

---

## 17. Review outcome

For each A-item the reviewer selects one: **Approved** · **Approved subject to conditions** ·
**Amend and resubmit** · **Not approved** · **Further information required**.

Conditions and outstanding actions are recorded against the item. Approval at the policy gate does
not constitute UAT acceptance or production approval, and the three gates in §1 are signed
separately.

---

## 18. Formal sign-off

**Appointed Accountant**

Name: ______________________________________________

Professional qualification: _________________________

Professional registration (if applicable): __________

Signature: _________________________________________

Date: ______________________________________________

**Legal adviser (where applicable)**

Name: ______________________________________________

Qualification / organisation: _______________________

Signature: _________________________________________

Date: ______________________________________________

**Tax adviser (where applicable)**

Name: ______________________________________________

Signature: _________________________________________

Date: ______________________________________________

**System owner**

Name: ______________________________________________

Signature: _________________________________________

Date: ______________________________________________

### Gate 1 — Accounting policy approval

- [ ] Approved for production accounting policy, subject to conditions
- [ ] Approved for production accounting policy without outstanding conditions
- [ ] Amend and resubmit

### Gate 2 — UAT acceptance

- [ ] UAT accepted for the B-items scoped to UAT (§16.2)
- [ ] UAT accepted with conditions: ______________________

### Gate 3 — Production go-live

- [ ] All B-items blocking go-live closed and evidenced
- [ ] Go-live approved

**Conditions / outstanding matters:**

_______________________________________________________________________

_______________________________________________________________________

_______________________________________________________________________

---

## Appendix A — Decisions taken in version 2

| # | Decision | Effect on the software |
|---|---|---|
| 1 | `pro_rata_on_collection` is a fourth recognition mode; binary collection behaviour preserved for agreements that are all-or-nothing | New mode + branch in the recognition trigger (B1) |
| 2 | Recognition mode is fail-closed: no policy binds without an explicit mode for its insurer agreement | Removes the silent `on_insurer_settlement` fallback (B3) |
| 3 | Claims: build the stage model and the two review states now; beneficiaries, death claims, instalments and recoveries are committed-but-unbuilt | B5 in UAT scope; B8/B10 registered |
| 4 | Unallocated client advances are built now — new liability account, receipt tracking, allocation and release on bind | New account 2040, role `client_advance_payable` (B2) |
| 5 | `ins.broker_fee_vat` is removed rather than retained; the decision history stays in documentation | Migration deletes the setting |
| 6 | Version 2 replaces `ACCOUNTANT_PACK.md`; version 1 archived as `ACCOUNTANT_PACK_v1_superseded.md` | This document |
| 7 | The register is machine-readable and CI validates settings against implemented values | `signoff-register.json` + two scripts |
| 8 | Sign-off is for the production accounting policy, with UAT acceptance and go-live as separate gates | §1 |

## Appendix B — open questions the code refuses to answer for you

These are accounting-policy choices. The software now makes each one *expressible*
without choosing it, because guessing would be the software writing policy — the
thing this pack exists to prevent. Each needs an answer before the gate shown.

| # | Question | Where the software stands | Needed by |
|---|---|---|---|
| Q1 | **Which account absorbs a claim write-off?** A claim balance on 2030 has to go somewhere when it is written off. Options: a bad-debt expense, a dedicated "claim write-offs" expense, or against commission income (rejected in code — see below). | `ins_write_off_claim()` requires the caller to name the account. It must be a real, non-control expense or revenue account, and commission accounts (4000, 2020, 1110) are **refused by name**. No default exists. | production go-live (B8) |
| Q2 | **Is an unapplied client advance released or forfeited?** If a client pays before placement and the policy never binds, the money is a liability until refunded. If the brokerage is entitled to keep it, that is a `advance_forfeit` — a different posting from a release, and taxable in a way a release is not. | Both kinds exist (`advance_release`, `advance_forfeit`). `advance_release` is forced by double entry to Dr 2040 / Cr AR. `advance_forfeit` has no built caller: no one has said when forfeiture is appropriate. | UAT acceptance (B2) |
| Q3 | **Repudiation is a ninth state.** §7.2 lists eight stages and omits it. | `repudiated` exists in the schema, is required, and is reported by `ins_claim_stage()`. It was kept rather than dropped to match the list. | policy approval |
| Q4 | **Which account absorbs a recovery credit?** A recovery raised against a claim credits *some* account when it is recognised. Recovery income, a contra against the loss the claim created, or netted into the insurer's account are all defensible, and the choice changes both the income statement and the net claim cost. | `ins_raise_claim_recovery()` requires the caller to name a real, non-control account. Commission accounts are refused. Writing the recovery off later charges the loss back to the same account, which is stored on the row rather than derived. No default. | production go-live (B8) |

On Q1, the reason commission accounts are refused in code rather than left to
judgement: §7.7 says a recovery "never touches commission accounts". A write-off is
absorbed by a loss account; charging it to commission income would restate brokerage
revenue for a claim the brokerage never earned on, and would do so silently in the
period the write-off was made rather than the period the claim arose.

## Appendix B — What version 1 said that version 2 changes

<<<<<<< ours
>>>>>>> theirs
=======
>>>>>>> theirs
=======

Every policy must have an explicit recognition mode in force at bind. Binding a policy whose
insurer agreement has no configured mode **fails** and names the insurer and the missing setting.
`on_insurer_settlement` remains available but must be chosen; it is no longer a fallback. This is
B3, and it is the change that makes the per-agreement classification in this section actually
load-bearing.

The mode is recorded **against the insurer**, as a term of the agreement, with the clause it rests
on, an effective period and two approving signatures. The company-wide setting remains as the
fallback for insurers with no negotiated term on file, and an agreement always outranks it. The
order applied at bind is: the gross-settlement override, then a deliberate per-policy override,
then the insurer's terms, then the company setting, then refusal. A per-insurer readiness report
shows which insurers are covered and which will refuse to bind, and why.

Two consequences worth stating before go-live. There is **no backfill**: existing insurers are not
seeded with whatever mode they happen to be on today, because stamping a decision nobody made is
the failure this control exists to prevent. Until each insurer is covered by terms or by a reviewed
company default, policies for that insurer **will not bind** — that is the control working, but it
is a deliberate outage risk and must be timed. And the existing `ins.commission_recognition`
registry still advertises a fourth value, `over_policy_term`, which has no reader and cannot be
chosen; the implemented modes are the four in this section.

### 4.5 Settlement and recognition are separate dimensions

Not every combination is sensible. Gross settlement with `on_premium_collection` or
`pro_rata_on_collection` cannot coexist — under gross the premium crosses in full, so there is
nothing left to collect — and the software refuses the combination by name at bind rather than
silently choosing one. The remainder of the compatibility matrix is for the accountant to approve,
particularly where net settlement changes the timing or legal basis of the entitlement.

### 4.6 Confirmations required

Which insurer agreements are `at_placement`, `on_premium_collection`, `pro_rata_on_collection` or
`on_insurer_settlement`; that the collection triggers are the **client's** receipt and not the
insurer's settlement or a credit note; that a voided receipt reverses recognition; the
compatibility matrix; and the deferred-commission and income accounts.

---

## 5. Cancellations, refunds and clawbacks

### 5.1 Principles

A cancellation preserves the original policy and financial history. The system records three
separate dates: cancellation requested, cancellation effective, and financial settlement. The
effective date must be supported by insurer confirmation or another appropriate authority.
Backdated cancellations require evidence, a reason and authorised approval. Closed periods are
never silently rewritten.

Three dates are policy and all three are now modelled (B4). The request date is the moment the
cancellation was entered; the effective date is the coverage date; the settlement date is the period
the cancellation financially falls into. The settlement date is derived from the cash rather than typed
in, so a person cannot move a cancellation between periods by editing a field. A backdated effective
date requires dated evidence, and is refused at submission and again at posting.

### 5.2 Return premium

Distinguish: return premium requested, approved, actually received or credited; client refund
payable; client refund actually paid; deductions and charges. An approved refund is never treated
as cash received, and no insurer receivable is created merely because a refund was requested. A
separate client refund obligation may still arise where the brokerage has an independent
contractual or legal duty to refund.

### 5.3 Deductions are never automatically income

| Deduction | Belongs to |
|---|---|
| Insurer-retained short-period premium | the insurer |
| Brokerage cancellation fee | the brokerage, only where contractually authorised |
| Statutory charges | the relevant statutory recipient |
| Other authorised deductions | the appropriate beneficiary |

The difference between original and return premium never becomes brokerage income by default.

### 5.4 Commission clawback

Proportional to the **approved** return premium, and never more than commission previously
recognised. Where commission has already been transferred to operating funds, record the clawback
against the original transaction, identify what is recoverable from operating funds, replenish
client money where necessary, block further transfers if the client-money position is deficient,
and require approval with a retained audit trail.

In the ledger the clawback is absorbed in a fixed order: the deferred pool (2020) first, then
recognised income (4000), then a recoverable from operating funds. Those are three different
movements, not one.

### 5.5 Confirmations required

Credit-note and reversal entries; whether returned commission goes back to deferred or reverses
income; treatment of transferred commission; approved-but-unpaid return premiums; the accounting
date for a backdated cancellation; cancellation after insurer settlement.

---

## 6. Co-insurance

Each participating insurer has independent records for participation percentage, lead status,
commission rate, settlement method, recognition trigger, tax treatment, receipts and outstanding
balances, and cancellation adjustments. Shares must total 100% with exactly one lead insurer;
both are enforced at bind.

The accountant must approve the allocation of premium, commission, insurer liabilities, receipts,
remittances and cancellation adjustments across participants.

---

## 7. Claims

### 7.1 Operating models

**Insurer-direct** — the insurer pays the claimant. The system records administration, the
insurer's decision and payment evidence, and creates **no** brokerage cash, bank or payable entry
for funds it never handled.

**Brokerage-managed** — the brokerage receives insurer funds and pays claimants. The system
records the insurer receivable (1120), funds received, the claimant payable (2030) and payments.

### 7.2 Stages

The policy recognises eight stages — reported, assessed, internally approved, insurer confirmed,
funded, partially paid, fully paid, closed — plus two states, **Coverage under review** and
**Payment disputed**. Internal approval alone never creates a payment posting.

Today the schema has six (`notified, assessing, approved, settled, repudiated, closed`) and
neither review state. The extension is B5 and blocks UAT acceptance.

### 7.3–7.7 Review, late notification, death claims, instalments, recoveries

A claim arising while a cancellation effective date is disputed is registered and marked
*Coverage under review*; it is never auto-rejected and no insurer liability is recognised before
confirmation. A claim registered after expiry is accepted where the insured event occurred during
cover, recording incident date, client notification, insurer notification and insurer
acknowledgement, and is flagged for review rather than rejected.

Authorised representatives may report a claim after the policyholder's death. Multiple
beneficiaries are supported on percentage or fixed allocations; percentages must total 100%;
disputed shares are held until insurer confirmation or legal determination while undisputed shares
may proceed; disputed shares are never redistributed automatically.

Instalments each carry their own expected date, actual payment date, amount and evidence, and a
subsequent receipt settles the existing approved balance rather than creating fresh recognition. A
disputed direct payment is marked *Payment disputed* until resolved, with the original evidence and
the dispute retained.

Excess rules are configurable by policy terms, class, insurer agreement and claim type; authorised
overrides require reasons and audit history. Recoveries cover overpayments, third-party recoveries,
insurer underpayments, instalment recoveries, disputes and authorised write-offs.

Beneficiaries, death claims, instalments, extended stages and recoveries are all unbuilt — B10,
B5, B8. They are in the register precisely so that approving this section is not mistaken for
certifying them.

### 7.8 Confirmations required

Recognition date and entries for insurer-confirmed claims, brokerage-managed claims, excess,
recoveries, overpayments, write-offs and claim reversals.

---

## 8. Foreign currency

The books remain in UGX. The rate used at bind is preserved and is not replaced by later market
rates except through an authorised amendment or reversal. The system tracks the transaction
currency and value, the UGX equivalent at bind, the settlement rate and realised and unrealised
gain or loss separately.

Rate overrides before bind require authority, reason and audit history; once bound the rate is
locked. Realised and unrealised are separate accounts (4900/4901 gains, 5910/5911 losses, 5900
rounding).

The accountant must confirm exchange-rate sources, revaluation frequency, entries and presentation.

---

## 9. Migration and opening balances

### 9.1 Cut-over

The cut-over date is the day before production go-live. Transactions after cut-over go through the
system. Existing policies are imported as existing business with original inception and expiry
preserved — never as newly issued. Migrated policies retain accounting-policy version 1 unless an
approved migration process says otherwise. Every migrated record carries a migration identifier and
traceable source.

### 9.2 What the migration must distinguish

Historical premium bills, historical receipts, outstanding client receivables, outstanding insurer
payables, commission earned before cut-over, commission deferred at cut-over, claims receivable and
payable, statutory liabilities and foreign-currency balances. Receipts and bills already represented
in opening balances are not re-posted.

### 9.3 Reconciliation before approval

| Area | Required reconciliation |
|---|---|
| General ledger | balanced trial balance |
| Client receivables | to client and policy records |
| Insurer payables | to insurer and policy records |
| Bank balances | to bank statements |
| Commission | earned and deferred, per policy/agreement |
| Claims | receivable and payable per claim |
| Statutory liabilities | balances per recipient |
| Foreign currency | balances per currency |

Material unexplained differences prevent migration approval. Opening balances post through 3900,
which must net to zero, with commission earned up to cut-over carried in 3200 and only the unearned
remainder in 2020.

---

## 10. Accounting periods and manual journals

### 10.1 Period reopening

A closed period may be reopened only with a documented reason, appropriate senior finance approval,
independent maker-checker approval, audit history of all changes, period reclosure and retention of
the revised period-end reports. The requester never approves their own reopening.

### 10.2 Manual journals

Balanced entries; finance maker and independent checker; supporting evidence and reason; subledger
references for control-account journals; immutable posted entries; reversal or authorised adjustment
instead of editing; additional approval for restricted accounts. A manual journal must never silently
create a difference between the general ledger and an operational subledger.

A governed manual-journal path exists (B6). Balance and immutability were never actually at risk — both
had real controls long before this: balance is a deferred constraint trigger that no role can bypass, and
both journal tables reject UPDATE and DELETE for everyone. What was missing was the feature, and the two
controls that matter once a person can write entries at all:

- **Nobody approves their own journal.** Approval and posting happen in one step, so there is no window
  where a journal is approved but unposted, or posted but unapproved.
- **A control account needs a subledger reference, and it has to resolve.** A line on AR or AP control
  must name an open item that exists in this company on a role posting to that same account. A reference
  that resolves to nothing is refused, because it looks reconciled while being nothing. This is checked at
  creation, at submission and again at approval.

Figures freeze the moment a journal leaves draft, so the lines approved are the lines that post. Two gaps
are recorded rather than glossed: there is **no amount-based approval limit** on manual journals — section
11 asks for one and B7 built that engine for refunds only, so a very large journal needs exactly one second
person; and **no additional approval tier for restricted accounts**, which this section also asks for.

### 10.3 Business day (DR-46)

Accounting dates follow the **Africa/Kampala** business day, not the database's UTC date. Posting
dates, the voidable date of a receipt, the closed-period test, accounting-setting lookups and
statutory-parameter lookups all resolve against the Kampala day. This decides which period a
transaction between 00:00 and 03:00 Kampala time falls into, and it applies platform-wide from
migrations `20261122090000` and `20261122100000`. A17.

---

## 11. Financial approval limits

Thresholds are configurable by transaction type, amount, currency, role, approval level and branch,
and apply separately to refunds, insurer remittances, commission transfers, claim payments,
intermediary commissions and manual journals, with multi-level approval, escalation, effective dates
and audit history. Splitting a transaction to stay under a threshold must be prevented.

Refunds of client advances now route through that engine (B7): a limit per stage, a limit per user in
addition to the stage, maker-checker that refuses self-approval, and a split flag. The refund function
itself refuses when an approved request does not cover the amount, so the workflow is enforced rather
than advisory. Three gaps are recorded rather than glossed: the routing key is **amount only**, so
currency, branch and department are not yet part of it; only client-advance refunds are routed, and
insurer remittances, commission transfers, claim payments and manual journals are not; and a split is
flagged for the approver rather than blocked, which is what this section asks for but leaves the
judgement with a person.

---

## 12. Statutory charges and taxation

### 12.1 The catalogue

Each charge names its legal basis, applicable class, calculation basis, rate or fixed amount,
exemptions, collection responsibility, remittance responsibility, statutory recipient, liability
account and effective date. A rate cannot be marked verified without citing the instrument that
verified it.

| Charge | Rate | Verified | Billed |
|---|---|---|---|
| Insurance Training Levy | 0.5% of gross direct premium | **Yes** — Insurance Act s.141(3), SI No. 100 of 2020 reg. 17(2) | Yes |
| IRA regulatory levy | 1.5% (unconfirmed) | No — press summaries only | **No**, inactive |
| Stamp duty, general policy | UGX 35,000 (unconfirmed) | No — press summaries only | **No**, inactive |

No unverified charge is active as a mandatory production charge. Enforcement is `advisory` by
default: turning it to `required` makes bind refuse a policy whose charges were not priced and
acknowledged, and raises the premium of every policy bound from then on — a commercial decision,
which is why it is not the default.

### 12.2 Brokerage fees

A brokerage fee is a distinct supply from premium and from a statutory charge, recognised in 4100,
and is **VAT-exempt by default** as an insurance service (VAT Act Cap 344, Schedule 3). A separate
non-brokerage service is classified `other_taxable_service` with a stated reason and is
standard-rated. Classification, not a company-wide switch, governs the treatment — the former
`ins.broker_fee_vat` setting is withdrawn (decision 5).

Fees invoiced before 17 November 2026 under the old 18% treatment keep their VAT, because that
output tax was declared.

### 12.3 Intermediary commission taxation

Treatment is configurable per agreement; the system does not assume every intermediary commission
carries identical withholding. Withheld tax is an asset (1210), never a reduction of revenue and
never a liability of the brokerage.

---

## 13. Intermediary commission

Intermediary registration, agency agreements and commission accrual/payment are separate concerns.
The register distinguishes insurer-appointed agents, independent brokers, sub-agents and referral
partners, each agreement carrying its own rates, tax settings and accrual trigger. The agent's share
is an **expense (5010)**, not a netting of the brokerage's own commission, so both the gross
commission and the agent cost remain visible. Agents are never treated as employees.

Accrual and payment remain subject to the accountant's approval of the treatment and legal
confirmation of applicable Ugandan sub-agency requirements.

---

## 14. Client-money protection

### 14.1 Separation

Separate client-money and operating bank accounts, corresponding liability and control accounts,
tracking of funds owed to insurers, clients and beneficiaries, prevention of transfers that would
leave the client-money account short, commission transfers only where entitlement is established,
and approvals with audit history.

Segregation is enforced in the schema today: a bank account cannot change between operating and
client money, and two bank accounts cannot share a GL account.

### 14.2 Daily reconciliation

A designated finance officer completes a daily client-money reconciliation comparing bank balance,
cashbook, client-money liabilities, unallocated advances, available commission and unmatched items;
a separate person independently reviews it; missed reconciliations are escalated.

### 14.3 Shortage response

A suspected shortage raises a high-priority alert and an incident record, notifies management,
restricts commission transfers and non-essential withdrawals, and requires independent approval to
release those restrictions. The system must distinguish a genuine shortage from a delayed bank feed.
Essential or legally required payments follow a controlled exception process.

The position test at transfer time, the daily artefact, reviewer independence and the incident flow
are B9 and block go-live.

=======

Every policy must have an explicit recognition mode in force at bind. Binding a policy whose
insurer agreement has no configured mode **fails** and names the insurer and the missing setting.
`on_insurer_settlement` remains available but must be chosen; it is no longer a fallback. This is
B3, and it is the change that makes the per-agreement classification in this section actually
load-bearing.

The mode is recorded **against the insurer**, as a term of the agreement, with the clause it rests
on, an effective period and two approving signatures. The company-wide setting remains as the
fallback for insurers with no negotiated term on file, and an agreement always outranks it. The
order applied at bind is: the gross-settlement override, then a deliberate per-policy override,
then the insurer's terms, then the company setting, then refusal. A per-insurer readiness report
shows which insurers are covered and which will refuse to bind, and why.

Two consequences worth stating before go-live. There is **no backfill**: existing insurers are not
seeded with whatever mode they happen to be on today, because stamping a decision nobody made is
the failure this control exists to prevent. Until each insurer is covered by terms or by a reviewed
company default, policies for that insurer **will not bind** — that is the control working, but it
is a deliberate outage risk and must be timed. And the existing `ins.commission_recognition`
registry still advertises a fourth value, `over_policy_term`, which has no reader and cannot be
chosen; the implemented modes are the four in this section.

### 4.5 Settlement and recognition are separate dimensions

Not every combination is sensible. Gross settlement with `on_premium_collection` or
`pro_rata_on_collection` cannot coexist — under gross the premium crosses in full, so there is
nothing left to collect — and the software refuses the combination by name at bind rather than
silently choosing one. The remainder of the compatibility matrix is for the accountant to approve,
particularly where net settlement changes the timing or legal basis of the entitlement.

### 4.6 Confirmations required

Which insurer agreements are `at_placement`, `on_premium_collection`, `pro_rata_on_collection` or
`on_insurer_settlement`; that the collection triggers are the **client's** receipt and not the
insurer's settlement or a credit note; that a voided receipt reverses recognition; the
compatibility matrix; and the deferred-commission and income accounts.

---

## 5. Cancellations, refunds and clawbacks

### 5.1 Principles

A cancellation preserves the original policy and financial history. The system records three
separate dates: cancellation requested, cancellation effective, and financial settlement. The
effective date must be supported by insurer confirmation or another appropriate authority.
Backdated cancellations require evidence, a reason and authorised approval. Closed periods are
never silently rewritten.

Three dates are policy and all three are now modelled (B4). The request date is the moment the
cancellation was entered; the effective date is the coverage date; the settlement date is the period
the cancellation financially falls into. The settlement date is derived from the cash rather than typed
in, so a person cannot move a cancellation between periods by editing a field. A backdated effective
date requires dated evidence, and is refused at submission and again at posting.

### 5.2 Return premium

Distinguish: return premium requested, approved, actually received or credited; client refund
payable; client refund actually paid; deductions and charges. An approved refund is never treated
as cash received, and no insurer receivable is created merely because a refund was requested. A
separate client refund obligation may still arise where the brokerage has an independent
contractual or legal duty to refund.

### 5.3 Deductions are never automatically income

| Deduction | Belongs to |
|---|---|
| Insurer-retained short-period premium | the insurer |
| Brokerage cancellation fee | the brokerage, only where contractually authorised |
| Statutory charges | the relevant statutory recipient |
| Other authorised deductions | the appropriate beneficiary |

The difference between original and return premium never becomes brokerage income by default.

### 5.4 Commission clawback

Proportional to the **approved** return premium, and never more than commission previously
recognised. Where commission has already been transferred to operating funds, record the clawback
against the original transaction, identify what is recoverable from operating funds, replenish
client money where necessary, block further transfers if the client-money position is deficient,
and require approval with a retained audit trail.

In the ledger the clawback is absorbed in a fixed order: the deferred pool (2020) first, then
recognised income (4000), then a recoverable from operating funds. Those are three different
movements, not one.

### 5.5 Confirmations required

Credit-note and reversal entries; whether returned commission goes back to deferred or reverses
income; treatment of transferred commission; approved-but-unpaid return premiums; the accounting
date for a backdated cancellation; cancellation after insurer settlement.

---

## 6. Co-insurance

Each participating insurer has independent records for participation percentage, lead status,
commission rate, settlement method, recognition trigger, tax treatment, receipts and outstanding
balances, and cancellation adjustments. Shares must total 100% with exactly one lead insurer;
both are enforced at bind.

The accountant must approve the allocation of premium, commission, insurer liabilities, receipts,
remittances and cancellation adjustments across participants.

---

## 7. Claims

### 7.1 Operating models

**Insurer-direct** — the insurer pays the claimant. The system records administration, the
insurer's decision and payment evidence, and creates **no** brokerage cash, bank or payable entry
for funds it never handled.

**Brokerage-managed** — the brokerage receives insurer funds and pays claimants. The system
records the insurer receivable (1120), funds received, the claimant payable (2030) and payments.

### 7.2 Stages

The policy recognises eight stages — reported, assessed, internally approved, insurer confirmed,
funded, partially paid, fully paid, closed — plus two states, **Coverage under review** and
**Payment disputed**. Internal approval alone never creates a payment posting.

Today the schema has six (`notified, assessing, approved, settled, repudiated, closed`) and
neither review state. The extension is B5 and blocks UAT acceptance.

### 7.3–7.7 Review, late notification, death claims, instalments, recoveries

A claim arising while a cancellation effective date is disputed is registered and marked
*Coverage under review*; it is never auto-rejected and no insurer liability is recognised before
confirmation. A claim registered after expiry is accepted where the insured event occurred during
cover, recording incident date, client notification, insurer notification and insurer
acknowledgement, and is flagged for review rather than rejected.

Authorised representatives may report a claim after the policyholder's death. Multiple
beneficiaries are supported on percentage or fixed allocations; percentages must total 100%;
disputed shares are held until insurer confirmation or legal determination while undisputed shares
may proceed; disputed shares are never redistributed automatically.

Instalments each carry their own expected date, actual payment date, amount and evidence, and a
subsequent receipt settles the existing approved balance rather than creating fresh recognition. A
disputed direct payment is marked *Payment disputed* until resolved, with the original evidence and
the dispute retained.

Excess rules are configurable by policy terms, class, insurer agreement and claim type; authorised
overrides require reasons and audit history. Recoveries cover overpayments, third-party recoveries,
insurer underpayments, instalment recoveries, disputes and authorised write-offs.

Beneficiaries, death claims, instalments, extended stages and recoveries are all unbuilt — B10,
B5, B8. They are in the register precisely so that approving this section is not mistaken for
certifying them.

### 7.8 Confirmations required

Recognition date and entries for insurer-confirmed claims, brokerage-managed claims, excess,
recoveries, overpayments, write-offs and claim reversals.

---

## 8. Foreign currency

The books remain in UGX. The rate used at bind is preserved and is not replaced by later market
rates except through an authorised amendment or reversal. The system tracks the transaction
currency and value, the UGX equivalent at bind, the settlement rate and realised and unrealised
gain or loss separately.

Rate overrides before bind require authority, reason and audit history; once bound the rate is
locked. Realised and unrealised are separate accounts (4900/4901 gains, 5910/5911 losses, 5900
rounding).

The accountant must confirm exchange-rate sources, revaluation frequency, entries and presentation.

---

## 9. Migration and opening balances

### 9.1 Cut-over

The cut-over date is the day before production go-live. Transactions after cut-over go through the
system. Existing policies are imported as existing business with original inception and expiry
preserved — never as newly issued. Migrated policies retain accounting-policy version 1 unless an
approved migration process says otherwise. Every migrated record carries a migration identifier and
traceable source.

### 9.2 What the migration must distinguish

Historical premium bills, historical receipts, outstanding client receivables, outstanding insurer
payables, commission earned before cut-over, commission deferred at cut-over, claims receivable and
payable, statutory liabilities and foreign-currency balances. Receipts and bills already represented
in opening balances are not re-posted.

### 9.3 Reconciliation before approval

| Area | Required reconciliation |
|---|---|
| General ledger | balanced trial balance |
| Client receivables | to client and policy records |
| Insurer payables | to insurer and policy records |
| Bank balances | to bank statements |
| Commission | earned and deferred, per policy/agreement |
| Claims | receivable and payable per claim |
| Statutory liabilities | balances per recipient |
| Foreign currency | balances per currency |

Material unexplained differences prevent migration approval. Opening balances post through 3900,
which must net to zero, with commission earned up to cut-over carried in 3200 and only the unearned
remainder in 2020.

---

## 10. Accounting periods and manual journals

### 10.1 Period reopening

A closed period may be reopened only with a documented reason, appropriate senior finance approval,
independent maker-checker approval, audit history of all changes, period reclosure and retention of
the revised period-end reports. The requester never approves their own reopening.

### 10.2 Manual journals

Balanced entries; finance maker and independent checker; supporting evidence and reason; subledger
references for control-account journals; immutable posted entries; reversal or authorised adjustment
instead of editing; additional approval for restricted accounts. A manual journal must never silently
create a difference between the general ledger and an operational subledger.

A governed manual-journal path exists (B6). Balance and immutability were never actually at risk — both
had real controls long before this: balance is a deferred constraint trigger that no role can bypass, and
both journal tables reject UPDATE and DELETE for everyone. What was missing was the feature, and the two
controls that matter once a person can write entries at all:

- **Nobody approves their own journal.** Approval and posting happen in one step, so there is no window
  where a journal is approved but unposted, or posted but unapproved.
- **A control account needs a subledger reference, and it has to resolve.** A line on AR or AP control
  must name an open item that exists in this company on a role posting to that same account. A reference
  that resolves to nothing is refused, because it looks reconciled while being nothing. This is checked at
  creation, at submission and again at approval.

Figures freeze the moment a journal leaves draft, so the lines approved are the lines that post. Two gaps
are recorded rather than glossed: there is **no amount-based approval limit** on manual journals — section
11 asks for one and B7 built that engine for refunds only, so a very large journal needs exactly one second
person; and **no additional approval tier for restricted accounts**, which this section also asks for.

### 10.3 Business day (DR-46)

Accounting dates follow the **Africa/Kampala** business day, not the database's UTC date. Posting
dates, the voidable date of a receipt, the closed-period test, accounting-setting lookups and
statutory-parameter lookups all resolve against the Kampala day. This decides which period a
transaction between 00:00 and 03:00 Kampala time falls into, and it applies platform-wide from
migrations `20261122090000` and `20261122100000`. A17.

---

## 11. Financial approval limits

Thresholds are configurable by transaction type, amount, currency, role, approval level and branch,
and apply separately to refunds, insurer remittances, commission transfers, claim payments,
intermediary commissions and manual journals, with multi-level approval, escalation, effective dates
and audit history. Splitting a transaction to stay under a threshold must be prevented.

Refunds of client advances now route through that engine (B7): a limit per stage, a limit per user in
addition to the stage, maker-checker that refuses self-approval, and a split flag. The refund function
itself refuses when an approved request does not cover the amount, so the workflow is enforced rather
than advisory. Three gaps are recorded rather than glossed: the routing key is **amount only**, so
currency, branch and department are not yet part of it; only client-advance refunds are routed, and
insurer remittances, commission transfers, claim payments and manual journals are not; and a split is
flagged for the approver rather than blocked, which is what this section asks for but leaves the
judgement with a person.

---

## 12. Statutory charges and taxation

### 12.1 The catalogue

Each charge names its legal basis, applicable class, calculation basis, rate or fixed amount,
exemptions, collection responsibility, remittance responsibility, statutory recipient, liability
account and effective date. A rate cannot be marked verified without citing the instrument that
verified it.

| Charge | Rate | Verified | Billed |
|---|---|---|---|
| Insurance Training Levy | 0.5% of gross direct premium | **Yes** — Insurance Act s.141(3), SI No. 100 of 2020 reg. 17(2) | Yes |
| IRA regulatory levy | 1.5% (unconfirmed) | No — press summaries only | **No**, inactive |
| Stamp duty, general policy | UGX 35,000 (unconfirmed) | No — press summaries only | **No**, inactive |

No unverified charge is active as a mandatory production charge. Enforcement is `advisory` by
default: turning it to `required` makes bind refuse a policy whose charges were not priced and
acknowledged, and raises the premium of every policy bound from then on — a commercial decision,
which is why it is not the default.

### 12.2 Brokerage fees

A brokerage fee is a distinct supply from premium and from a statutory charge, recognised in 4100,
and is **VAT-exempt by default** as an insurance service (VAT Act Cap 344, Schedule 3). A separate
non-brokerage service is classified `other_taxable_service` with a stated reason and is
standard-rated. Classification, not a company-wide switch, governs the treatment — the former
`ins.broker_fee_vat` setting is withdrawn (decision 5).

Fees invoiced before 17 November 2026 under the old 18% treatment keep their VAT, because that
output tax was declared.

### 12.3 Intermediary commission taxation

Treatment is configurable per agreement; the system does not assume every intermediary commission
carries identical withholding. Withheld tax is an asset (1210), never a reduction of revenue and
never a liability of the brokerage.

---

## 13. Intermediary commission

Intermediary registration, agency agreements and commission accrual/payment are separate concerns.
The register distinguishes insurer-appointed agents, independent brokers, sub-agents and referral
partners, each agreement carrying its own rates, tax settings and accrual trigger. The agent's share
is an **expense (5010)**, not a netting of the brokerage's own commission, so both the gross
commission and the agent cost remain visible. Agents are never treated as employees.

Accrual and payment remain subject to the accountant's approval of the treatment and legal
confirmation of applicable Ugandan sub-agency requirements.

---

## 14. Client-money protection

### 14.1 Separation

Separate client-money and operating bank accounts, corresponding liability and control accounts,
tracking of funds owed to insurers, clients and beneficiaries, prevention of transfers that would
leave the client-money account short, commission transfers only where entitlement is established,
and approvals with audit history.

Segregation is enforced in the schema today: a bank account cannot change between operating and
client money, and two bank accounts cannot share a GL account.

### 14.2 Daily reconciliation

A designated finance officer completes a daily client-money reconciliation comparing bank balance,
cashbook, client-money liabilities, unallocated advances, available commission and unmatched items;
a separate person independently reviews it; missed reconciliations are escalated.

### 14.3 Shortage response

A suspected shortage raises a high-priority alert and an incident record, notifies management,
restricts commission transfers and non-essential withdrawals, and requires independent approval to
release those restrictions. The system must distinguish a genuine shortage from a delayed bank feed.
Essential or legally required payments follow a controlled exception process.

All of this is built (B9), with one operational gap that is stated rather than glossed.

The **position test** applies at transfer time and is fail-closed: a transfer is refused when it
would leave the position negative, where the position is client money held *less* the money already
owed to clients, insurers and claimants. That is stronger than the balance test it sits beside, and
the difference is the whole point — a trust account can hold a large balance and still be short,
because the balance belongs to other people. The two tests are kept together because they state
different things: one says the money is there, the other says it is free.

A negative position raises a **shortage incident** and blocks every commission transfer in that
currency, including one that would otherwise fit. It is released only by someone other than the
person who raised it, and only once the position is no longer negative — a release that leaves the
money short is a note, not a control.

**Missed reconciliations** are counted in business days without a *reviewed* daily reconciliation.
A reconciliation that has been prepared but not reviewed does not count, which is the four-eyes
failure this section names. Two consecutive missed days escalate, raising one incident that is
refreshed daily rather than a new one every morning.

Two things to know before go-live:

- **Nothing runs the daily check on a schedule yet.** The functions exist and are callable, but the
  repository has no job that calls them each morning. Until that is wired, escalation happens only
  when something invokes it. This is the one part of B9 that is real work still outstanding, and it
  lives outside a migration.
- **There is a documented escape hatch**, because some regulators require commission to be banked in
  client money. `ins.client_money_position_test` defaults to enforcing the position test and can be
  set to permissive only through company accounting settings, proposed and approved by two different
  people. It is a signed decision, not a code path.

**Open for the accountant:** the free-money figure treats receivables from insurers
(`insurer_claim_receivable`, `commission_receivable`) as calls on client money alongside
`insurer_payable`. That is a judgement about what the account is holding the money for and should be
confirmed rather than assumed.

>>>>>>> theirs
---

## 15. Financial reporting

PDF and Excel exports and printable layouts; filters for date and period, branch, class, insurer,
client and currency; every report identifies its generation date and user and distinguishes draft,
pending, approved and posted.

The dashboard covers premium production, earned and deferred commission, client receivables, insurer
balances and remittances, claims exposure, cancellations and refunds, client-money and operating-bank
positions, foreign exchange, and profitability by branch, insurer and class, with actual, forecast and
pending amounts distinguished.

All financial reports reconcile to the general ledger and supporting subledgers.

---

## 16. Sign-off register

The tables below are generated from `signoff-register.json`. The JSON is the source of truth; CI
checks that every setting named exists, that the value claimed as approved is one the database
allows, and that every evidence file cited exists. Edit the JSON and run
`node scripts/gen-signoff-register.mjs`; never edit the block by hand.

<!-- BEGIN GENERATED: SIGN-OFF REGISTER -->
<!-- Do not edit by hand. Edit docs/insurance-brokerage/signoff-register.json and run
     node scripts/gen-signoff-register.mjs -->

### 16.1 Accounting policy items (A-register)

Each item is the accounting treatment the software is expected to implement. `reviewed_at`
is filled only when the appointed reviewer has signed that item in section 18.

| Ref | Decision area | Approver | Code | Selected settings | Required before | Evidence |
|---|---|---|---|---|---|---|
| **A1** | Premium recognition and pre-binding advances | accountant | Partly built | — | UAT acceptance | — |
| **A2** | Insurer settlement: gross basis and net exceptions | accountant + legal | Built | `ins.insurer_remittance_basis` = **gross_premium** | production go-live | `test_ins_settlement_basis.sql`<br>`test_ins_commission.sql` |
| **A3** | Commission recognition methods | accountant | Partly built | `ins.commission_recognition` = **explicit_per_agreement** *(not yet implemented)* | UAT acceptance | `test_ins_commission_recognition_mode.sql`<br>`test_ins_commission_on_premium_collection.sql`<br>`test_ins_commission_pro_rata.sql`<br>`test_ins_insurer_commission_terms.sql` |
| **A4** | Partial collection and commission clawbacks | accountant | Partly built | `ins.commission_recognition` = **pro_rata_on_collection** *(not yet implemented)* | UAT acceptance | `test_ins_commission_pro_rata.sql`<br>`test_ins_cancellation_posting.sql` |
| **A5** | Co-insurance accounting | accountant | Built | — | production go-live | `test_ins_coinsurance_charges.sql` |
| **A6** | Cancellation, refunds and return premium | accountant | Built | `ins.cancellation_treatment` = **pro_rata_refund** | production go-live | `test_ins_cancellation_calculation.sql`<br>`test_ins_cancellation_posting.sql`<br>`test_ins_cancellation_cash.sql` |
| **A7** | Claims accounting and recoveries | accountant | Partly built | — | production go-live | `test_ins_claim_payments.sql`<br>`test_ins_claim_reserve_revisions.sql`<br>`test_ins_claim_documents.sql` |
| **A8** | Foreign currency and revaluation | accountant | Built | — | production go-live | `test_foreign_bind_transfer.sql`<br>`test_foreign_cancellation.sql`<br>`test_foreign_claims.sql` |
| **A9** | Migration and opening balances | accountant | Built | `migration.earned_commission_treatment` = **opening_balances**<br>`migration.partially_paid_import` = **full_billed_plus_receipts** | production go-live | `test_ins_import_opening_from_history.sql`<br>`test_ins_import_control_totals.sql`<br>`test_ins_opening_acceptance_gate.sql` |
| **A10** | Accounting periods and manual journals | accountant | Partly built | — | production go-live | `test_fin_period_controls.sql` |
<<<<<<< ours
| **A11** | Financial approval limits | accountant | Not built | — | production go-live | `test_ins_finance_pending_approvals.sql` |
=======
| **A11** | Financial approval limits | accountant | Partly built | — | production go-live | `test_ins_finance_pending_approvals.sql` |
>>>>>>> theirs
| **A12** | Client-money accounting and reconciliation | accountant | Partly built | — | production go-live | `test_fin_bank_accounts.sql`<br>`test_bank_reconciliation.sql`<br>`test_ins_policy_cash.sql` |
| **A13** | Statutory charges and remittances | accountant + legal | Built | `ins.statutory_charge_enforcement` = **advisory** | production go-live | `test_ins_statutory_charge_catalogue.sql`<br>`test_ins_statutory_charges_on_policy.sql`<br>`test_ins_statutory_charge_trace.sql` |
| **A14** | VAT, withholding tax and broker-fee classification | accountant + tax | Built | `ins.agent_commission_taxable` = **taxable**<br>`ins.agent_commission_wht` = **applicable**<br>`ins.agent_commission_basis` = **gross_commission** | production go-live | `test_ins_client_broker_fees.sql`<br>`test_ins_agent_commission.sql`<br>`test_wht_posting.sql` |
| **A15** | Intermediary commission accounting | accountant + legal | Built | — | production go-live | `test_ins_agent_commission.sql`<br>`test_ins_intermediaries.sql` |
| **A16** | Financial reporting and reconciliation | accountant | Built | — | production go-live | `test_ins_reports_batch1.sql`<br>`test_ins_reports_batch2.sql`<br>`test_ins_reports_batch3.sql`<br>`test_ins_reports_batch4.sql`<br>`test_ins_dashboard_summary.sql` |
| **A17** | Business day and posting-date rules (DR-46) | accountant | Built | — | production go-live | `test_fin_period_controls.sql`<br>`test_ins_reports_batch1.sql` |
| **A18** | Endorsement cancellation and financial reversal | accountant | Built | — | production go-live | `test_endorsement_cancellation.sql`<br>`test_endorsement_posting.sql` |
| **A19** | Opening position, retained earnings and migration balancing | accountant | Built | `migration.earned_commission_treatment` = **opening_balances** | production go-live | `test_ins_import_opening_from_history.sql`<br>`test_ins_opening_acceptance_gate.sql` |
| **A20** | Broker-fee classification and its accounting and tax treatment | accountant + tax | Built | — | production go-live | `test_ins_client_broker_fees.sql` |

### 16.2 Committed but not built (B-register)

These are controls and features the policy assumes. **They are not built.** The reviewer is
asked to approve the *policy* in §16.1 while acknowledging these as committed work with the
gate shown. An item blocking "production go-live" must be complete before live posting; an
item blocking "UAT acceptance" must be complete before the business signs UAT.

| Ref | Feature | Status | Depends on | Blocks | Acceptance criteria |
|---|---|---|---|---|---|
<<<<<<< ours
| **B1** | pro_rata_on_collection commission recognition | Not built | A3, A4 | UAT acceptance | A partial collection of 50% of premium earns exactly 50% of commission, the remainder stays in 2020, a further collection earns the balance, and voiding a receipt reverses only the portion that receipt earned. |
| **B2** | Unallocated client advances | Not built | A1 | UAT acceptance | A receipt with no policy creates a 2040 credit and no receivable; binding a policy allocates it and clears 2040; an unallocated advance is visible on the client statement as a liability and is refundable. |
=======
| **B1** | pro_rata_on_collection commission recognition (built) | built | A3, A4 | UAT acceptance | A partial collection of 50% of premium earns exactly 50% of commission, the remainder stays in 2020, a further collection earns the balance, and voiding a receipt reverses only the portion that receipt earned. |
| **B2** | Unallocated client advances (built) | built | A1 | UAT acceptance | A receipt with no policy creates a 2040 credit and no receivable; binding a policy allocates it and clears 2040; an unallocated advance is visible on the client statement as a liability and is refundable. |
>>>>>>> theirs
| **B3** | Fail-closed commission-mode selection (built) | built | A3 | UAT acceptance | A policy on an insurer with no configured mode cannot bind and the error names the insurer and the missing setting; configuring the mode allows the bind and the chosen mode is frozen into the accounting snapshot. |
| **B4** | Three cancellation dates (built) | built | A6 | UAT acceptance | A cancellation requested in period 1, effective in period 2 and settled in period 3 posts to the settlement period while reporting its effective date; a backdated effective date without evidence is refused. |
| **B5** | Claim stage model and the two review states (built) | built | A7 | UAT acceptance | A claim moves through all eight stages with an audit row each; internal approval creates no journal; insurer confirmation creates the receivable; partial payment leaves a visible balance; a disputed payment is excluded from settled totals. |
| **B6** | Manual journals with maker-checker (built) | built | A10 | production go-live | A manual journal cannot post unbalanced, cannot be approved by its maker, cannot post to a control account without a subledger reference, and cannot be edited after posting. |
| **B7** | Approval limits and split prevention (built) | built | A11 | production go-live | A refund above a user's limit routes to the next level; the same user cannot approve it; two same-day refunds to the same payee just under the limit are flagged as a possible split. |
| **B8** | Claims recoveries and write-offs (built) | built | A7 | production go-live | A recovery is raised against a claim, allocated when received, and never touches commission accounts; a write-off requires approval and posts to an identifiable account. |
<<<<<<< ours
| **B9** | Daily client-money reconciliation and shortage response | Not built | A12 | production go-live | A transfer that would leave the client-money position negative is refused; two consecutive missed reconciliations escalate; a shortage raises an incident and blocks further transfers until independently released. |
=======
| **B9** | Daily client-money reconciliation and shortage response (built) | built | A12 | production go-live | A transfer that would leave the client-money position negative is refused; two consecutive missed reconciliations escalate; a shortage raises an incident and blocks further transfers until independently released. |
>>>>>>> theirs
| **B10** | Beneficiaries, death claims and instalment settlements (built) | built | A7 | UAT acceptance | A death claim records the representative and beneficiaries; percentages must total 100%; a disputed share is held while undisputed shares pay; a second instalment reduces the balance without a new claim accrual. |
| **B11** | Non-cash party-balance movement (dispositions) -- built | built | B2 | production go-live | A release of 250,000 leaves 2040 down by 250,000 and AR down by 250,000 with the bank unchanged; the open item shows the consumption; over-release is refused; a write-off reduces 2030 into the named expense account; commission accounts are refused; a control account cannot be the counterparty; a disposition cannot be edited or deleted. |

<!-- END GENERATED: SIGN-OFF REGISTER -->

---

## 17. Review outcome

For each A-item the reviewer selects one: **Approved** · **Approved subject to conditions** ·
**Amend and resubmit** · **Not approved** · **Further information required**.

Conditions and outstanding actions are recorded against the item. Approval at the policy gate does
not constitute UAT acceptance or production approval, and the three gates in §1 are signed
separately.

---

## 18. Formal sign-off

**Appointed Accountant**

Name: ______________________________________________

Professional qualification: _________________________

Professional registration (if applicable): __________

Signature: _________________________________________

Date: ______________________________________________

**Legal adviser (where applicable)**

Name: ______________________________________________

Qualification / organisation: _______________________

Signature: _________________________________________

Date: ______________________________________________

**Tax adviser (where applicable)**

Name: ______________________________________________

Signature: _________________________________________

Date: ______________________________________________

**System owner**

Name: ______________________________________________

Signature: _________________________________________

Date: ______________________________________________

### Gate 1 — Accounting policy approval

- [ ] Approved for production accounting policy, subject to conditions
- [ ] Approved for production accounting policy without outstanding conditions
- [ ] Amend and resubmit

### Gate 2 — UAT acceptance

- [ ] UAT accepted for the B-items scoped to UAT (§16.2)
- [ ] UAT accepted with conditions: ______________________

### Gate 3 — Production go-live

- [ ] All B-items blocking go-live closed and evidenced
- [ ] Go-live approved

**Conditions / outstanding matters:**

_______________________________________________________________________

_______________________________________________________________________

_______________________________________________________________________

---

## Appendix A — Decisions taken in version 2

| # | Decision | Effect on the software |
|---|---|---|
| 1 | `pro_rata_on_collection` is a fourth recognition mode; binary collection behaviour preserved for agreements that are all-or-nothing | New mode + branch in the recognition trigger (B1) |
| 2 | Recognition mode is fail-closed: no policy binds without an explicit mode for its insurer agreement | Removes the silent `on_insurer_settlement` fallback (B3) |
| 3 | Claims: build the stage model and the two review states now; beneficiaries, death claims, instalments and recoveries are committed-but-unbuilt | B5 in UAT scope; B8/B10 registered |
| 4 | Unallocated client advances are built now — new liability account, receipt tracking, allocation and release on bind | New account 2040, role `client_advance_payable` (B2) |
| 5 | `ins.broker_fee_vat` is removed rather than retained; the decision history stays in documentation | Migration deletes the setting |
| 6 | Version 2 replaces `ACCOUNTANT_PACK.md`; version 1 archived as `ACCOUNTANT_PACK_v1_superseded.md` | This document |
| 7 | The register is machine-readable and CI validates settings against implemented values | `signoff-register.json` + two scripts |
| 8 | Sign-off is for the production accounting policy, with UAT acceptance and go-live as separate gates | §1 |

## Appendix B — open questions the code refuses to answer for you

These are accounting-policy choices. The software now makes each one *expressible*
without choosing it, because guessing would be the software writing policy — the
thing this pack exists to prevent. Each needs an answer before the gate shown.

| # | Question | Where the software stands | Needed by |
|---|---|---|---|
| Q1 | **Which account absorbs a claim write-off?** A claim balance on 2030 has to go somewhere when it is written off. Options: a bad-debt expense, a dedicated "claim write-offs" expense, or against commission income (rejected in code — see below). | `ins_write_off_claim()` requires the caller to name the account. It must be a real, non-control expense or revenue account, and commission accounts (4000, 2020, 1110) are **refused by name**. No default exists. | production go-live (B8) |
| Q2 | **Is an unapplied client advance released or forfeited?** If a client pays before placement and the policy never binds, the money is a liability until refunded. If the brokerage is entitled to keep it, that is a `advance_forfeit` — a different posting from a release, and taxable in a way a release is not. | Both kinds exist (`advance_release`, `advance_forfeit`). `advance_release` is forced by double entry to Dr 2040 / Cr AR. `advance_forfeit` has no built caller: no one has said when forfeiture is appropriate. | UAT acceptance (B2) |
| Q3 | **Repudiation is a ninth state.** §7.2 lists eight stages and omits it. | `repudiated` exists in the schema, is required, and is reported by `ins_claim_stage()`. It was kept rather than dropped to match the list. | policy approval |
| Q4 | **Which account absorbs a recovery credit?** A recovery raised against a claim credits *some* account when it is recognised. Recovery income, a contra against the loss the claim created, or netted into the insurer's account are all defensible, and the choice changes both the income statement and the net claim cost. | `ins_raise_claim_recovery()` requires the caller to name a real, non-control account. Commission accounts are refused. Writing the recovery off later charges the loss back to the same account, which is stored on the row rather than derived. No default. | production go-live (B8) |
<<<<<<< ours
=======
| Q5 | **What counts as a call on client money?** The free-position figure subtracts client refunds, insurer payable and claim payable from the money held — those are unarguable. It also subtracts receivables the *brokerage* is owed by insurers (`insurer_claim_receivable`, `commission_receivable`). Whether money the firm has not yet received should reduce what it treats as free is a judgement: treating it as a call is prudent, but it can refuse transfers that would in fact have been covered. | `platform_ins_client_money_position()` currently counts them. Changing the list is a one-line change to one function; the control-role list is the whole policy. | production go-live (B9) |
>>>>>>> theirs

On Q1, the reason commission accounts are refused in code rather than left to
judgement: §7.7 says a recovery "never touches commission accounts". A write-off is
absorbed by a loss account; charging it to commission income would restate brokerage
revenue for a claim the brokerage never earned on, and would do so silently in the
period the write-off was made rather than the period the claim arose.

## Appendix B — What version 1 said that version 2 changes

<<<<<<< ours
>>>>>>> theirs
=======
>>>>>>> theirs
| v1 position | v2 position | Why |
|---|---|---|
| Commission credited to Unearned Commission at bind and recognised only when a settlement fully pays the insurer's net item (one rule) | Four modes, chosen per insurer agreement, with no silent default | One rule cannot describe agreements whose entitlements differ |
| Net settlement described as the default in §3 while §5.14 called gross the decided basis | Gross is the basis throughout; net is a controlled exception | The pack contradicted itself |
| "Does the insurer remit only the net?" left as an open question | Closed — gross is the basis; the residual question is legal set-off under s.90(3) | Answered by the gross decision |
| Broker fee VAT default `vat_applicable` | VAT-exempt by default, classification per fee | The 18% default was wrong and is withdrawn |
| No sign-off register | 20 A-items and 10 B-items, machine-validated | A flat list of "changes for review" had no owner or outcome |
