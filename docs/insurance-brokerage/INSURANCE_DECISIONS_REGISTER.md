# Insurance Brokerage: Decisions Register

**Authoritative for:** every accounting, legal, regulatory and commercial decision the module
depends on, who decides it, and whether it has been approved.
**Not authoritative for:** what is built (`INSURANCE_IMPLEMENTATION_STATUS.md`) or what must pass
before production (`INSURANCE_ACCEPTANCE_PLAN.md`).

Last reconciled: 23 November 2026.

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
| DR-41 | Claims register, as at a date: status is the latest claim status event on or before the date (a claim notified on or before the date with no event yet counts as notified). Open = notified, assessing or approved; an approved claim stays open until fully paid. Outstanding = reserve for a notified or assessing claim, approved amount less payments for an approved claim, nothing for settled, repudiated or closed. Reserve is the latest reserve revision on or before the date. Payments are insurer-direct and client payouts by payment date, with the void-after-the-date rule of DR-38. The approved amount is kept as history (`ins_claim_approval_history`, 2026-11-22), so it is the latest approval position on or before the as-at date: an initial or revision row gives that amount, a cleared row means the claim was not approved at that date and the figure is nothing | Claims | Owner | Owner-decided | `ins_report_claims_register` (`20261123000000`) | Resolved 22 Nov 2026: the approved amount is kept as history (`20261123000000`; see the 2026-11-22 design note). Still open: confirm an approved claim counts as outstanding until fully paid |
| DR-42 | Claims ageing = open claims from the register, aged from the notified date in the buckets 0-30, 31-60, 61-90, 91-180 and over 180 days, optionally grouped by insurer or product line. It is built on the register function, so its total is the register total. Insurer is the policy's lead insurer; the share basis for co-insurance belongs with the insurer performance report | Claims | Owner | Owner-decided | `ins_report_claims_ageing` (`20261121110000`) | Claims manager to confirm the bucket boundaries, and whether ageing should run from the loss date or the last activity instead |
| DR-43 | Cancelled business = posted policy cancellations dated by posting date, with return premium, commission clawed back, commission retained and the total insurer credit taken from the per-insurer adjustment rows. Proposed, prepared, rejected and withdrawn cancellations are not shown. Return premium equals the cancellations column of production for the same period and imported-policy setting (DR-36). A co-insured cancellation splits by insurer | Accounting | Owner | Owner-decided | `ins_report_cancellations`, `ins_report_cancellation_register` (`20261121120000`) | Accountant to confirm |
| DR-44 | Due for renewal = bound policies, active or renewed, whose expiry date falls in the period. Cancelled or reversed policies are in the cancellation report instead. Imported in-force policies are included by default, because they are the book that has to renew. Outcome = renewed when a bound policy has this one as its renewal_of_id; otherwise the recorded outcome (lost, declined, lapsed); otherwise upcoming if not yet expired, else unresolved. The report shows the position today; renewal outcomes are not kept as history, so there is no as-at date | Renewals | Owner | Owner-decided | `ins_report_renewals` (`20261121120000`) | Owner to confirm the imported-policy default |
| DR-45 | Renewal retention = renewed / (due less upcoming), by count; and renewal premium / expiring premium of the same matured policies. A policy not yet expired cannot have been lost, so it is left out of both denominators. Premium retention can exceed 100 when renewal premiums are higher. Built on the renewals function, so the counts are its rows, grouped | Renewals | Owner | Owner-decided | `ins_report_renewal_retention` (`20261121120000`) | Owner to confirm the definition of retention |

### Business day

Recorded 21 November 2026 from the migrations that implement it.

| ID | Definition | Type | Decider | Status | Built in | Next step |
|---|---|---|---|---|---|---|
| DR-46 | The business day is Africa/Kampala (UTC+3, no daylight saving), set in two platform helpers, `business_date(timestamptz)` and `business_today()`; `ins_local_date(timestamptz)` and `ins_local_today()` delegate to them. Reports date timestamps by it, and 52 application functions use it for "today", future-date checks and posting dates (policy, cancellation, endorsement, claim, quote and commission functions, charge pricing, and the shared receipt and credit-note void and raise functions). From `20261122090000` and `20261122100000` the rule also covers 31 non-insurance functions (accounting settings, bank adjustments, finance reports, journal void, FX revaluation and rate checks, regulatory parameters, payroll posting, maintenance, sustainability, procurement tracking dates) and four more column defaults. The web app and edge functions use the same rule (`apps/web/src/lib/businessDate.ts`). A per-company time zone later means changing `business_date()` and `BUSINESS_TIME_ZONE` in the web helper. No function or column default in the `public` schema uses the UTC date now; `test_platform_business_date.sql` fails on any new use | Accounting | Owner, then Accountant | Built, decision recorded in the migrations; approval not recorded | `20261121140000_ins_reports_kampala_dating.sql`, `20261121150000_ins_app_dates_kampala.sql`, `20261122090000_platform_business_date.sql`, `20261122100000_business_date_procurement.sql` | Accountant to confirm that posting dates, and void and raise dates on shared finance functions, follow the Kampala day. Owner decided that the remaining functions move (built in `20261122090000` and `20261122100000`); accountant to confirm that the payroll posting date, the closed-period test in `void_journal_entry` and the future-rate check on FX rates follow the Kampala day |
| DR-47 | Statutory charges can be remitted to the authority by the insurer or by the brokerage, set by charge type and legal responsibility. A charge whose collector is the insurer is remitted by the insurer, and the brokerage's obligation ends when the money reaches the insurer. Any other collector means the brokerage holds and remits it. The catalogue's `collector` already records this | Reports | Owner | Owner-decided | The report derives the remitter from the charge's `collector` (`ins_report_statutory_charges`, `20261123010000`). A brokerage-held remittance to an authority is **not built**: no active catalogue charge needs it yet | Build it, with posting to the statutory payable accounts, before any charge is collected by the brokerage |
| DR-48 | A partial receipt, and a partial remittance to an insurer, covers a statutory charge pro rata to its share of the invoice (receipt) or of the insurer's payable (remittance), with an auditable breakdown. Cents are allocated by largest remainder so the parts add up to the whole | Reports | Owner | Owner-decided | `ins_report_statutory_charge_trace` writes the working of every split; `test_ins_statutory_charge_trace.sql` | Accountant to confirm pro rata as the permanent rule. Collections allocated to premium and VAT components are not derived |
| DR-49 | A statutory charge is reversed or retained on cancellation according to its legal refundability. Charges are not all refunded automatically | Reports | Owner | Owner-decided | **Not built.** A cancelled policy keeps its allocation rows and the report shows its status | Add a refundability attribute to the versioned catalogue, then change the cancellation posting. Legal input needed per charge (stamp duty is typically not refundable) |
| DR-50 | Core bind posting is not changed for statutory charges until the accounting model is agreed. Detail is added around it: a charge allocation record written when the policy becomes active, and reports on top | Reports | Owner | Owner-decided | `ins_policy_charge_allocations` and its trigger (`20261123010000`). Bind posts statutory pass-through into insurer payable as before; the statutory payable accounts remain unused | Revisit if the brokerage collects a charge itself, or if the current posting cannot represent a charge correctly |
| DR-51 | Insurer performance is a cohort view: policies bound in the period, by insurer. Premium placed and commission are each insurer's own recorded share on the policy. Claims on those policies, as at the end date from the claims register, are attributed to insurers pro rata by share, to the cent, so a co-insured claim is carried by every participating insurer. Loss ratio = claims incurred (paid plus outstanding) / premium placed. Premium is gross of later cancellations, which are counted separately | Reports | Owner | Owner-decided | `ins_report_insurer_performance` (`20261123020000`), `test_ins_reports_insurer_performance.sql` | Accountant to confirm the cohort basis against an earned-premium basis. Remittance timeliness and cancellation credits by insurer are not included |
| DR-52 | The dashboard's financial figures come from one server function that calls the same report functions as the reports screens, per currency: premium written (gross, endorsements, cancellations and reversals, net), commission earned, premium collected, outstanding premium as at the end date with its overdue part, and open claims outstanding. Gross and net are both shown, so cancelled business sits beside gross premium and nothing is hidden. Written, commission and collected are movements in the period; outstanding premium and claims are positions as at the end date. Nothing is stored or typed in. Commission is shown as not available when the company has no commission income posting rule, not as zero | Reports | Owner | Owner-decided | `ins_dashboard_summary` (`20261123030000`), `test_ins_dashboard_summary.sql`, `InsuranceDashboard.test.tsx` | Owner to confirm the default period (month to date) and whether to keep both gross and net |

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


---

## Owner-confirmed requirements: accountant reconciliation, 23 November 2026

These entries record the owner's requirements confirmed during the 23 November accountant-signoff discussion. They do not replace earlier DR rows, approve accounting treatments or constitute legal advice. The detailed treatment and outstanding professional decisions are in `ACCOUNTANT_SIGN_OFF_RECONCILIATION.md`.

| ID | Owner-confirmed requirement | Type | Decider | Status | Next step |
|---|---|---|---|---|---|
| OR-01 | Insurer settlement arrangement varies by the particular insurer agreement; selection is made separately for each insurer agreement | Commercial / Accounting | Owner | Owner-confirmed; professional approval pending | Gross safe default; net exception requires legal/compliance and accountant approval. Reconcile with DR-13 and DR-29 |
| OR-02 | All three commission recognition triggers are acceptable and are selected separately for each insurer agreement | Accounting | Owner | Owner-confirmed; accountant approval pending | Approve full settlement/recognition combination matrix; reconcile DR-08 and DR-11 |
| OR-03 | Co-insurance must preserve each insurer's own participation and financial arrangement | Accounting / Commercial | Owner | Owner-confirmed; accountant approval pending | Validate per-insurer journals, rounding, returns and clawbacks |
| OR-04 | Support insurer-direct and brokerage-managed claims | Claims / Accounting | Owner | Owner-confirmed; accountant approval pending | Confirm recognition, excess and cash-handling journals |
| OR-05 | Excess rules are configurable; authorised overrides require a reason and audit trail | Claims / Control | Owner | Owner-confirmed | Verify implementation and UAT |
| OR-06 | Support partial claim receipts and payments, balances, reversals and reconciliation | Claims / Accounting | Owner | Owner-confirmed | Verify end-to-end and UAT |
| OR-07 | Support recovery of claim overpayments from claimants and recoveries from third parties | Claims / Accounting | Owner | Owner-confirmed; not evidenced as built | Design recovery subledger and accountant-approved journals |
| OR-08 | Policy transaction currency is separate from UGX functional books; policy FX rate is fixed at policy take-up unless an alternative is agreed | Accounting / Commercial | Owner | Owner-confirmed; accountant approval pending | Approve FX measurement and revaluation treatment |
| OR-09 | Authorised pre-bind FX overrides are permitted with reason, approval and audit history | Control | Owner | Owner-confirmed | Verify implementation and tests |
| OR-10 | Migration cut-over is the day immediately before production go-live; new transactions run in Vesta Portal from go-live | Commercial / Accounting | Owner | Owner-confirmed | Set actual date at launch and reconcile opening balances |
| OR-11 | Opening migration balances must fully reconcile, including trial balance and all supporting control subledgers | Accounting | Owner | Owner-confirmed; accountant approval pending | Complete migration acceptance gate |
| OR-12 | Closed accounting periods may be reopened through a controlled process | Accounting / Control | Owner | Owner-confirmed | Define maker-checker and period re-close controls |
| OR-13 | Period reopening requires two different people: requester and approver | Control | Owner | Owner-confirmed | Engineering and UAT evidence required |
| OR-14 | Financial approval thresholds vary by transaction type and approval role | Control | Owner | Owner-confirmed; not evidenced as fully built | Implement configurable limits, escalation and anti-splitting |
| OR-15 | Manual journals may target GL control accounts subject to approval, supporting references and audit controls | Accounting / Control | Owner | Owner-confirmed; accountant approval pending | Confirm subledger safeguards and UAT |
| OR-16 | Financial reports support Excel, PDF and print-friendly output | Reporting | Owner | Owner-confirmed | Verify coverage and report-to-ledger tie-outs |
| OR-17 | Management dashboard shows premium production, commission, insurer balances, claims, cash and profitability | Reporting | Owner | Owner-confirmed | Verify dashboard scope and tie-outs |
| OR-18 | Client money and brokerage operating funds must remain strictly separated; transfers must not leave beneficiary obligations underfunded | Regulatory / Accounting | Owner | Owner-confirmed; legal/accountant approval pending | Confirm statutory trust rules and available-funds calculation |
| OR-19 | Client-money accounts require mandatory daily reconciliation with separate preparer and reviewer | Control / Regulatory | Owner | Owner-confirmed | Verify frequency, workflow and UAT |
| OR-20 | Confirmed client-money shortages trigger restrictions, alerts and incident management; release requires independent approval | Control / Regulatory | Owner | Owner-confirmed; implementation and legal review pending | Build verified-shortage detection, exception and release workflow |

**Important:** OR-01 and OR-02 are independent settings. The system must not assume that gross/net settlement determines when commission is earned. Net settlement is not enabled by this owner confirmation; it remains subject to the separate legal/compliance gate and accountant approval. All OR entries remain distinct from **Approved** status until the required professional evidence is attached.
