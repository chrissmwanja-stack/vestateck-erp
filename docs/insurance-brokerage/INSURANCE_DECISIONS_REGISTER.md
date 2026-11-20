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
| DR-28 | Endorsement cancellation (E4): void credit notes rather than delete; commission returns to unearned (2020), not income; refuse once money has moved (settlement reversal first) | Accounting | Accountant | Draft design, not approved; E4 is on the branch, not `main` | Pack 5.15, three points |
| DR-29 | Pack section 4 question 3 (does the insurer remit only the net? "current design assumes yes") contradicts DR-13 (gross is the decided basis) | Accounting | Owner, Accountant | **Inconsistent documents** | Close question 3 as superseded by DR-13, or reopen DR-13 |
| DR-30 | Claim withdrawal, overpayment and recovery (accountant answer 22 is one line). Principle recorded: a linked adjustment, never an overwrite | Accounting | Accountant | Open | Needs real input before it is built |
| DR-31 | In-force import, Option A: earned commission to cut-over goes to opening balances, only the unearned remainder deferred; new accounts 3900 (opening balance clearing) and 3200 (retained earnings role) | Accounting | Accountant | Owner-decided, built, not approved | Pack section 9 |
| DR-32 | Ten-year record retention (s.106 as cited in accountant answer 27; which Act is not confirmed) | Regulatory | Compliance adviser | **Unverified** | |
| DR-33 | IRA circular for brokers dated 10 July 2026, returns and client-money reporting | Regulatory | Compliance adviser | **Unverified** | |

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
