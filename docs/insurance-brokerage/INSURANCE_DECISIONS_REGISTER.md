# Insurance Brokerage: Decisions Register

**Authoritative for:** every accounting, legal, regulatory and commercial decision the module
depends on, who decides it, and whether it has been approved.
**Not authoritative for:** what is built (`INSURANCE_IMPLEMENTATION_STATUS.md`) or what must pass
before production (`INSURANCE_ACCEPTANCE_PLAN.md`).

Last reconciled: 20 November 2026.

## Approval vocabulary

| Status | Meaning |
|---|---|
| **Approved** | A qualified person has signed it. Requires a signed row in `ACCOUNTANT_PACK.md` section 8, or a written compliance-adviser opinion linked in the Evidence column. **Nothing is Approved today.** |
| **Owner-decided** | The owner has decided and the software follows it. The accountant or adviser has not confirmed it. |
| **Draft guidance** | Written guidance exists (`Accountant.pdf`, which is unsigned and reads as draft) but nobody has signed it. |
| **Open** | No decision. The software has a default or a gate. |
| **Unverified** | A factual claim about the law or a rate that has not been checked against the instrument. |

Owners: **Owner** = Chris Mwanja. **Accountant** and **Compliance adviser** are the external roles the
pack names; put their names here once engaged.

**Maintenance rule.** A decision moves to Approved only when the signature or opinion exists, and
the same change records the date and evidence. A PR that builds a decision's behaviour cites the DR
id in its description.

## Register

### Foundation

| ID | Decision or question | Type | Decider | Status | Built in | Next step |
|---|---|---|---|---|---|---|
| DR-01 | Multi-currency is required; the ledger is not UGX-only (16 Oct 2026) | Commercial | Owner | Owner-decided | Phase A3, `CURRENCY_REVIEW.md` | Accountant to sign FX treatments (5.11): rounding account 5900, void at original rate, accounts 4900/4901/5910/5911 are template defaults |
| DR-02 | No regulatory threshold, rate or deadline is hard-coded; each lives in data with effective date, source and approver (16 Oct 2026) | Regulatory | Owner | Owner-decided | Governance settings, `ins_charge_catalogue` | None |
| DR-03 | The accountant's written answers are the working basis (16 Oct 2026) | Accounting | Owner | Owner-decided | | `Accountant.pdf` is unsigned draft guidance; every treatment below still needs a real signature |
| DR-04 | Which target clients need currencies other than USD at launch | Commercial | Owner | Open | | Owner to answer |

### Pack section 3: decisions taken 11 Oct 2026 (confirm all seven)

| ID | Decision | Type | Decider | Status | Next step |
|---|---|---|---|---|---|
| DR-05 | Commission = `round(gross x rate / 100, 2)`; net to insurer is the remainder | Accounting | Owner, then Accountant | Owner-decided | Pack 8, section 3 |
| DR-06 | Bind books premium on inception date and locks the policy | Accounting | Owner, then Accountant | Owner-decided | Pack 8, section 3 |
| DR-07 | Commission credited to Unearned Commission (2020) at bind, not income | Accounting | Owner, then Accountant | Owner-decided | Pack 8, section 3 |
| DR-08 | Commission becomes income when a posted settlement fully pays the insurer's net item; credit notes do not count as paid | Accounting | Owner, then Accountant | Owner-decided | Superseded in part by DR-11 |
| DR-09 | Earned commission stays in client-money bank (1020) until a manager transfers it to operating (1000) | Accounting | Owner, then Accountant | Owner-decided | Pack 8, section 3 |
| DR-10 | No VAT or WHT on commission | Accounting | Owner, then Accountant | Owner-decided | See DR-15 and DR-16 for withholding on income received |
| DR-11 | Commission recognition follows the insurer agreement: earned at bind (unconditional), on the covering client receipt, or on insurer settlement (19 Nov 2026) | Accounting | Owner | Owner-decided | Accountant to classify each insurer agreement (pack 5.13). `over_policy_term` not built |
| DR-12 | Corrections to a bound policy are reverse and re-issue (v1); pre-`20261011090000` policies keep commission-to-income-at-bind and are not backfilled | Accounting | Owner | Owner-decided | Accountant to confirm IAS 8 classification of the legacy policies |

### Remittance, settlement and cash

| ID | Decision or question | Type | Decider | Status | Next step |
|---|---|---|---|---|---|
| DR-13 | Gross remittance: insurer payable booked for the whole premium, commission as receivable (1110); commission is never netted off what the insurer is owed. Netting survives only as a legal-review-gated configuration | Accounting, legal | Owner; Compliance adviser for the netting gate | Owner-decided | Pack 5.14 and the s.90(3) set-off question to the Accountant and adviser |
| DR-14 | Remittance deadline. Insurance Act s.90(3) as read in the 2017 text: next working day, without deducting commission. The configured default is 3 working days (`remittance.deadline_working_days`), unverified | Regulatory | Compliance adviser | **Unverified**, default 3 days in force | Adviser to confirm current s.90 text (later amendments not checked) and whether a broker may hold premium at all |
| DR-15 | Client-paid brokerage fee: is it a professional fee under ITA s.129 (6%, with the regular-compliance exception) or s.136, not the 10% agent rate? | Tax | Accountant | Open; rate seeded unapproved | Must be answered before production activation |
| DR-16 | Withholding on commission an insurer pays the broker | Tax | Accountant | Open | |
| DR-17 | Brokerage fees are VAT-exempt (VAT Act Cap 344, Sch. 3); non-brokerage services classified separately, with a stated reason. Fees invoiced with 18% VAT before 17 Nov 2026 keep it | Tax | Owner | Owner-decided; checked against public sources 17 Nov 2026 | Accountant confirmation |
| DR-18 | Gross-up: gross premium to AR (1100) at bind, or client money straight to premium trust (1020) on receipt | Accounting | Accountant | Open (pack section 4 question 1) | Current design books to 1100 |
| DR-19 | Template account names and VAT/WHT codes | Accounting | Accountant | Open (pack section 4 question 4) | |

### Agent commission

| ID | Decision or question | Type | Decider | Status | Next step |
|---|---|---|---|---|---|
| DR-20 | Agent commission withholding is 10% under ITA s.134, a final tax from 1 July 2026 (s.139(aa)); computed at payment from effective-dated parameters; returns on the payment-month basis | Tax | Accountant | Verified for agent commission against public sources; not signed | Pack 5.12: basis per agreement type, and expense (5010) versus netting |
| DR-21 | Does the same 10% apply to an insurer's commission paid to a broker? | Tax | Accountant | Open (same question as DR-16, different payee) | |
| DR-22 | Whether the Accruals tab may offer a manual accrue action | Commercial | Owner | Open | Left out deliberately; default is accrual follows recognition |

### Statutory charges

| ID | Decision or question | Type | Decider | Status | Next step |
|---|---|---|---|---|---|
| DR-23 | Insurance Training Levy 0.5% of gross direct premium (Insurance Act s.141(3), SI 100 of 2020 reg. 17(2)) | Regulatory | Compliance adviser | Verified against the instrument; active and billable | Adviser to confirm |
| DR-24 | IRA regulatory levy 1.5% | Regulatory | Compliance adviser | **Unverified** (press summaries only); inactive and unbillable | Cite an instrument, then activate |
| DR-25 | Stamp duty on a general policy, UGX 35,000 | Regulatory | Compliance adviser | **Unverified in the catalogue** (no instrument cited), inactive and unbillable. `ROADMAP.md` section 2 records press and tribunal sources that support it; the catalogue requires an instrument | Cite the instrument, then activate |
| DR-26 | Which statutory charges this brokerage must collect and remit, versus the insurer's obligation | Regulatory | Compliance adviser, Accountant | Open | Decides whether each charge belongs on the client invoice |
| DR-27 | Statutory charge enforcement: `advisory` (default) or `required`. `required` raises the premium of every policy bound afterwards | Commercial | Owner | Open; `advisory` in force | Owner to decide per company before go-live |

### Cancellation, claims, import and records

| ID | Decision or question | Type | Decider | Status | Next step |
|---|---|---|---|---|---|
| DR-28 | Endorsement cancellation (E4): void credit notes rather than delete; commission returns to unearned (2020), not income; refuse once money has moved (settlement reversal first) | Accounting | Accountant | Draft design, not approved; E4 is built and on `main` | Pack 5.15, three points |
| DR-29 | Pack section 4 question 3 (does the insurer remit only the net? "current design assumes yes") contradicts DR-13 (gross is the decided basis) | Accounting | Owner, Accountant | **Inconsistent documents** | Close question 3 as superseded by DR-13, or reopen DR-13 |
| DR-30 | Claim withdrawal, overpayment and recovery (accountant answer 22 is one line). Principle recorded: a linked adjustment, never an overwrite | Accounting | Accountant | Open | Needs real input before it is built |
| DR-31 | In-force import, Option A: earned commission to cut-over goes to opening balances, only the unearned remainder deferred; new accounts 3900 (opening balance clearing) and 3200 (retained earnings role) | Accounting | Accountant | Owner-decided, built, not approved | Pack section 9 |
| DR-32 | Ten-year record retention (s.106 as cited in accountant answer 27; which Act is not confirmed) | Regulatory | Compliance adviser | **Unverified** | |
| DR-33 | IRA circular for brokers dated 10 July 2026, returns and client-money reporting | Regulatory | Compliance adviser | **Unverified** | |

### Management reporting definitions

Proposed 21 November 2026 as the basis for the insurance reporting suite; the owner approved building
on them. They govern management reports, not postings, but the accountant should still confirm them so
that "written", "collected" and "outstanding" mean one thing everywhere.

| ID | Definition | Type | Decider | Status | Built in | Next step |
|---|---|---|---|---|---|---|
| DR-35 | Net written premium = premium bound, plus posted endorsement premium, less the premium of an endorsement later cancelled (E4), less return premium of posted cancellations, less the remaining net premium of a reversed policy. Each movement is dated by the day it took effect. Premium only: broker fees, charges and VAT are excluded | Accounting | Owner, then Accountant | Owner-decided | `ins_report_production` (`20261121090000`) | Accountant to confirm movement dating (bind date versus inception date) |
| DR-36 | Imported in-force policies are excluded from production by default, because opening a book is not writing it. A parameter includes them | Accounting | Owner | Owner-decided | `ins_report_production` | |
| DR-37 | Premium collected = receipts allocated to the client premium receivables (bind and endorsement), dated by settlement date. These receivables carry the whole client invoice, so the figure includes charges and VAT billed with the premium | Accounting | Owner, then Accountant | Owner-decided | `ins_report_premium_collected` | Accountant to confirm whether collections should be split into premium, fees and VAT |
| DR-38 | Outstanding premium = billed less received less credited, as at a date, from the receivable open items. An event dated after the as-at date is ignored; a settlement or credit note voided after that date still counts as it did on it. Age runs from the due date, or the document date when there is none | Accounting | Owner | Owner-decided | `ins_report_outstanding_premium` | |
| DR-39 | Commission earned = the movement on the commission income account (credits less debits) over a period, dated by journal entry date, so it equals the ledger. It is broken down by route: at placement, on insurer settlement or premium collection, reversals, cancellations, endorsements, other. A voided entry and its reversal both count. Commission still deferred (unearned commission, 2020) is not income and is not shown. Imported in-force policies and opening-balance journals are excluded by default, because opening a book is not earning it; a parameter includes them, and with it the total equals the ledger. Gross of any withholding the insurer deducts (DR-16, DR-21 are open) | Accounting | Owner, then Accountant | Owner-decided | `ins_report_commission_earned` (`20261121100000`) | Accountant to confirm the exclusion of imported policies and that the report should be gross of withholding. Insurer grouping not offered: under co-insurance it needs the share basis |
| DR-40 | Commission receivable = commission the insurer owes the broker, as at a date: open items with control role `commission_receivable`, billed less received less credited, with the as-at rule of DR-38. These exist only where the insurer settles on the gross basis (DR-13); under the net basis the broker withholds its commission and the report is empty by design | Accounting | Owner | Owner-decided | `ins_report_commission_receivable` (`20261121100000`) | Accountant to confirm, with DR-13 |
| DR-41 | Claims register, as at a date: status is the latest claim status event on or before the date (a claim notified on or before the date with no event yet counts as notified). Open = notified, assessing or approved; an approved claim stays open until fully paid. Outstanding = reserve for a notified or assessing claim, approved amount less payments for an approved claim, nothing for settled, repudiated or closed. Reserve is the latest reserve revision on or before the date. Payments are insurer-direct and client payouts by payment date, with the void-after-the-date rule of DR-38. The approved amount is not kept as history, so it is the current one | Claims | Owner | Owner-decided | `ins_report_claims_register` (`20261121110000`) | Claims manager to confirm that an approved claim counts as outstanding until paid, and whether the approved amount should be kept as history |
| DR-42 | Claims ageing = open claims from the register, aged from the notified date in the buckets 0-30, 31-60, 61-90, 91-180 and over 180 days, optionally grouped by insurer or product line. It is built on the register function, so its total is the register total. Insurer is the policy's lead insurer; the share basis for co-insurance belongs with the insurer performance report | Claims | Owner | Owner-decided | `ins_report_claims_ageing` (`20261121110000`) | Claims manager to confirm the bucket boundaries, and whether ageing should run from the loss date or the last activity instead |
| DR-43 | Cancelled business = posted policy cancellations dated by posting date, with return premium, commission clawed back, commission retained and the total insurer credit taken from the per-insurer adjustment rows. Proposed, prepared, rejected and withdrawn cancellations are not shown. Return premium equals the cancellations column of production for the same period and imported-policy setting (DR-36). A co-insured cancellation splits by insurer | Accounting | Owner | Owner-decided | `ins_report_cancellations`, `ins_report_cancellation_register` (`20261121120000`) | Accountant to confirm |
| DR-44 | Due for renewal = bound policies, active or renewed, whose expiry date falls in the period. Cancelled or reversed policies are in the cancellation report instead. Imported in-force policies are included by default, because they are the book that has to renew. Outcome = renewed when a bound policy has this one as its renewal_of_id; otherwise the recorded outcome (lost, declined, lapsed); otherwise upcoming if not yet expired, else unresolved. The report shows the position today; renewal outcomes are not kept as history, so there is no as-at date | Renewals | Owner | Owner-decided | `ins_report_renewals` (`20261121120000`) | Owner to confirm the imported-policy default |
| DR-45 | Renewal retention = renewed / (due less upcoming), by count; and renewal premium / expiring premium of the same matured policies. A policy not yet expired cannot have been lost, so it is left out of both denominators. Premium retention can exceed 100 when renewal premiums are higher. Built on the renewals function, so the counts are its rows, grouped | Renewals | Owner | Owner-decided | `ins_report_renewal_retention` (`20261121120000`) | Owner to confirm the definition of retention |

### Business day

Recorded 21 November 2026 from the migrations that implement it.

| ID | Definition | Type | Decider | Status | Built in | Next step |
|---|---|---|---|---|---|---|
| DR-46 | The business day is Africa/Kampala (UTC+3, no daylight saving), set in two helpers: `ins_local_date(timestamptz)` and `ins_local_today()`. Reports date timestamps by it, and 52 application functions use it for "today", future-date checks and posting dates (policy, cancellation, endorsement, claim, quote and commission functions, charge pricing, and the shared receipt and credit-note void and raise functions). A per-company time zone later means changing the two helpers. Not covered: 14 non-insurance functions and four column defaults, which still use the UTC date | Accounting | Owner, then Accountant | Built, decision recorded in the migrations; approval not recorded | `20261121140000_ins_reports_kampala_dating.sql`, `20261121150000_ins_app_dates_kampala.sql` | Accountant to confirm that posting dates, and void and raise dates on shared finance functions, follow the Kampala day. Owner to decide whether the remaining 14 functions move |

## Sign-off tracking

The signature form is `ACCOUNTANT_PACK.md` section 8 and stays unsigned until an accountant signs it.
This table maps each unsigned row to the register so a signature updates the right decisions.

| Pack 8 row | Register ids |
|---|---|
| Section 3, decisions 1 to 7 | DR-05 to DR-12 |
| Section 4 questions 1 to 4 | DR-18, DR-11, DR-29, DR-19 and DR-17 |
| Sections 5.1 to 5.11 | DR-01, DR-05 to DR-10 |
| Section 5.12 | DR-20, DR-21 |
| Section 5.13 | DR-11 |
| Section 5.13b | DR-24 to DR-27 |
| Section 5.14 | DR-13, DR-14 |
| Section 5.15 | DR-28 |
| Not yet a pack row: in-force import | DR-31 |
| Not yet a pack row: client brokerage-fee WHT and VAT | DR-15, DR-17 |
