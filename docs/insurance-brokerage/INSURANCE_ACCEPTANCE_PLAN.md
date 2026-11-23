# Insurance Brokerage: Acceptance Plan

**Authoritative for:** what must pass before a real tenant runs insurance accounting in production,
and who confirms each gate.
**Not authoritative for:** what is built (`INSURANCE_IMPLEMENTATION_STATUS.md`) or the approval
status of a decision (`INSURANCE_DECISIONS_REGISTER.md`; gates here cite its `DR-` ids).

Last reconciled: 21 November 2026, against `main` at `134da84`. Every gate below is **Open** unless a dated evidence link says
otherwise. Nobody has recorded a pass yet.

## Rules

1. A gate passes only with evidence recorded in its row: a CI run URL, a signed pack row, a dated
   adviser opinion, or a UAT walk-through note. "Built" is not evidence.
2. Gates in sections 1 and 2 are **blocking**: no production tenant until they pass. Sections 3 and 4
   are blocking unless the owner records a written exception with a date.
3. A PR that closes a gate edits its row in the same PR.

## 1. Accounting sign-off (blocking)

Confirmer: **Accountant**. Mechanism: sign `ACCOUNTANT_PACK.md` section 8; the register then moves the
mapped decisions to Approved.

| Gate | Criterion | Register | Status | Evidence |
|---|---|---|---|---|
| A1 | Core treatments confirmed: pack section 3 decisions 1 to 7, sections 5.1 to 5.11 | DR-05 to DR-12 | Open | |
| A2 | Commission recognition: each insurer agreement classified placement / collection / settlement | DR-11 | Open | |
| A3 | Gross remittance and commission receivable; s.90(3) set-off answered | DR-13 | Open | |
| A4 | Foreign currency: 5900 rounding, void at original rate, FX account codes | DR-01 | Open | |
| A5 | Agent commission: accrual basis, WHT character, expense versus netting | DR-20, DR-21 | Open | |
| A6 | Tax codes: brokerage fee VAT-exempt, WHT on client fee (s.129/136), WHT on insurer commission | DR-15, DR-16, DR-17 | Open | |
| A7 | Endorsement cancellation: three points in pack 5.15 | DR-28 | Open | |
| A8 | In-force import Option A and accounts 3900, 3200 (only if a tenant imports a book) | DR-31 | Open | |
| A9 | Claim withdrawal, overpayment, recovery treatment | DR-30 | Open | |
| A10 | Inconsistency DR-29 closed (net-of-commission versus gross) | DR-29 | Open | |

## 2. Regulatory and legal (blocking)

Confirmer: **Compliance adviser**.

| Gate | Criterion | Register | Status | Evidence |
|---|---|---|---|---|
| R1 | Current Insurance Act s.90 text; remittance deadline set to the confirmed value | DR-14 | Open | |
| R2 | IRA levy and stamp duty rates each cite an instrument, then are activated | DR-24, DR-25 | Open | |
| R3 | Which statutory charges the brokerage must collect and remit | DR-26 | Open | |
| R4 | Retention rule and IRA broker circular checked | DR-32, DR-33 | Open | |
| R5 | Owner decides `ins.statutory_charge_enforcement` for the launch company | DR-27 | Open | |

## 3. Engineering (blocking)

| Gate | Criterion | Status | Evidence |
|---|---|---|---|
| E1 | Branch `feat/ins-accounting-acceptance` merged to `main` through a PR with all required checks green (migration-policy, repo-hygiene, build, test, lint-ratchets, db-shadow-replay, insurance-concurrency, e2e) | Open | Merged into `main` by PRs #33 to #38 (merge commits on `main`). CI run URLs are not recorded here; add them to close this gate |
| E2 | `database.types.ts` regenerated for E4 and the generated-types drift check passes on the merge commit | Open | Regenerated on `main` in `80490f2` (E4) and `7802c5f` (`ins_local_date`, `ins_local_today`). The drift check result on the current merge commit is not recorded |
| E3 | Full SQL suite (`supabase/tests/*.sql`) passes on a fresh stack, including `test_endorsement_cancellation.sql` | Open | |
| E4 | Security catalog tests pass: `test_ins_security_hardening.sql`, `test_ins_authz_catalog.sql`, cross-tenant reads, writes and views | Open | |
| E5 | `generate-ins-doc` run once on a real policy on the deployed stack; output reviewed | Open | CI cannot cover it |
| E6 | Backup and restore drill recorded in `docs/OPERATIONS.md`, and a staging project exercised with the module | Open | Not verified in this pass |
| E7 | Local UAT tenant (Pearl Risk Brokers Ltd, `seed.sql` section 6) walked end to end by someone other than the builder | Open | |
| E8 | `test_ins_reports_batch1.sql` passes in CI, and every report total in it ties to the AR control balance | Open | Passed locally on PostgreSQL 16 on 21 Nov 2026; CI run not yet recorded |
| E9 | `test_ins_reports_batch2.sql` passes on a fresh stack, and commission earned ties to the commission income ledger | Open | Written 21 Nov 2026 and merged. An earlier note said it was only parse-checked; no run record has been entered since. Receivable with rows has no scenario yet |
| E10 | `test_ins_reports_batch3.sql` passes on a fresh stack, and the claims register ties to the paid amount and reserve history on the claim records | Open | Written 21 Nov 2026 and merged. An earlier note said it had not been run; no run record has been entered since. Back-dated claims and voided payments have no scenario yet |
| E11 | `test_ins_reports_batch4.sql` passes on a fresh stack, and the return premium in the cancellations report ties to the cancellations column of production for the same period (DR-43) | Open | Added 21 Nov 2026; no run record |
| E12 | The SQL suite passes both outside and inside the 21:00 to 24:00 UTC window, when the UTC date and the Kampala date differ (DR-46) | Open | Added 21 Nov 2026. Before `20261121150000` the report tests failed in that window. 22 Nov 2026: one run on a local PostgreSQL 16 harness with the clock set to 21:30 UTC (00:30 Kampala): 145 of 146 files pass; the one failure, `test_d4e_bank_adjustments_privileges.sql`, needs PostgreSQL 17's `MAINTAIN` privilege and is unrelated. The five tests fixed in `46a6eac` fail in that window in their earlier form. Not a CI run, so the gate stays Open: record a run inside the window on PostgreSQL 17, or in CI |
| E14 | Claim approval history (`20261123000000`): one row per approval decision and per un-approval, RPC-only and immutable, backfilled from claims already approved or settled; the claims register shows the approved amount as-at from the history | Open | Written 22 Nov 2026 (`test_claim_approval_history.sql`: initial row, blank-note fallback, register as-at before/after un-approval and revision, refused blank reasons and direct writes, events trail survives, tenant isolation). The SQL test is not yet run on a fresh stack; record the run before closing |

## 4. Playwright coverage (blocking unless excepted)

Specs that exist: `insurance-import`, `insurance-cash-commission`, `insurance-claim-payment`.
Each gap below needs a PR that adds the spec; put its number in the last column when it opens.
Document generation stays outside Playwright while the CI stack does not serve edge functions: E5
covers it manually.

| Gate | Flow not covered | Why it matters | PR | Status |
|---|---|---|---|---|
| P1 | Policy cancellation (calculation, approval, refund cash) | Money out; independent checker | | Open |
| P2 | Endorsement posting, then **E4 cancellation** | Newest-first rule and refusal after settlement | | Open |
| P3 | Claim where the insurer pays the client directly | Second claim-payment mode | | Open |
| P4 | Voiding a claim payment | Reversal path | | Open |
| P5 | Claim repudiation | State machine terminal | | Open |
| P6 | Independent bank reconciliation by the third finance user | Segregation of duties | | Open |
| P7 | Rejecting a cash request | Negative path | | Open |
| P8 | Statutory charges: price, acknowledge, bind refuses if the catalogue moved | Money collected for others | | Open |
| P9 | Commission recognition modes (placement, collection, settlement) | Three accounting paths | | Open |
| P10 | Agent commission payment with maker-checker and WHT | Tax at payment | | Open |
| P11 | Reports batch 1: run each of the three reports on seeded data and check the figures against the AR control account | The reports are only trusted if a person has seen them agree with the ledger | | Open |

P8 to P10 are not in `apps/web/e2e/README.md`'s uncovered list; they were added here because the
features shipped after that list was written.

## 5. Go-live conditions

| Gate | Criterion | Status |
|---|---|---|
| G1 | Sections 1 and 2 fully passed | Open |
| G2 | Sections 3 and 4 passed, or each exception recorded with owner, date and reason | Open |
| G3 | Any tenant with a legacy book has run the in-force import and the opening acceptance gate (`test_ins_opening_acceptance_gate.sql`) | Open |
| G4 | Owner records the go-live date and the register's Approved count in this file | Open |


---

## 6. Supplementary gates from the 23 November accountant reconciliation

**Reconciliation document:** `ACCOUNTANT_SIGN_OFF_RECONCILIATION.md`. These gates supplement, and do not close, the existing A/R/E/P/G gates. All are **Open** until evidence is recorded. The reconciliation branch is not a production approval.

### Accounting policy gates (blocking)

| Gate | Criterion | Confirmer | Status | Evidence |
|---|---|---|---|---|
| A11 | Pre-bind premium advances: approved liability account/role, receipt, allocation, refund and ageing journals | Accountant | Open | |
| A12 | Gross settlement as safe default; net settlement unavailable unless specific agreement has legal/compliance approval and accountant-approved journals | Accountant + Compliance adviser | Open | |
| A13 | Approved matrix for every supported combination of insurer settlement basis and commission recognition trigger | Accountant | Open | |
| A14 | Co-insurance accounting by insurer agreement, including mixed settings, return premiums and clawbacks | Accountant | Open | |
| A15 | Client-money bank/liability reconciliation equation, available-funds calculation and permitted commission transfer | Accountant + Compliance adviser | Open | |
| A16 | Claims excess, partial payments, overpayments, recoveries and write-offs | Accountant | Open | |
| A17 | FX policy-rate lock, pre-bind override, realised/unrealised FX and reversal treatment | Accountant | Open | |
| A18 | Opening balances, policy-level migration reconciliation and earned/unearned commission cut-over | Accountant | Open | |
| A19 | Period reopening, configurable approvals and manual journals to control accounts | Accountant | Open | |
| A20 | Reports/dashboard definitions and tie-outs to posted GL and subledgers | Accountant | Open | |

### Regulatory / compliance gates (blocking)

| Gate | Criterion | Confirmer | Status | Evidence |
|---|---|---|---|---|
| R6 | Written opinion on any insurer-specific contractual set-off and Insurance Act s.90(3); gross remains default pending opinion | Ugandan legal/compliance adviser | Open | |
| R7 | Client-money segregation, permitted withdrawals, daily reconciliation, shortage response and trust-account obligations | Ugandan legal/compliance adviser | Open | |
| R8 | Charge collector/remitter responsibility, instrument-backed rates, remittance and refundability for each statutory charge | Ugandan legal/compliance adviser | Open | |
| R9 | Tax treatment of client fees, insurer commission and intermediary commission confirmed against current law and facts | Accountant / tax adviser | Open | |

### Engineering and UAT gates (blocking)

| Gate | Criterion | Status | Evidence |
|---|---|---|---|
| E15 | Pre-bind client advances can be received, allocated to a subsequently bound policy, refunded and reconciled without duplicate cash or AR postings | Open | |
| E16 | Agreement-level settlement and recognition settings are snapshotted to each insurer policy share; unsupported combinations are blocked | Open | |
| E17 | Gross is default; net exception requires recorded agreement evidence, compliance approval, accountant-approved effective date and audit history | Open | |
| E18 | Co-insurance tests cover multiple insurers with different settlement/recognition settings and per-insurer cancellation/FX treatment | Open | |
| E19 | Claim overpayment and recovery workflow covers claimant, third party and insurer balances, receipts, disputes, instalments and write-offs | Open | |
| E20 | Daily client-money reconciliation has preparer/reviewer separation, ageing of unmatched items and escalation | Open | |
| E21 | Confirmed client-money shortage triggers restrictions and incident workflow; transient bank-feed delays do not falsely trigger; release is independently approved | Open | |
| E22 | Period reopening is maker-checker, fully audited and requires re-close with revised reports | Open | |
| E23 | Approval thresholds are configurable by transaction type/role/currency and anti-splitting controls are tested | Open | |
| E24 | Manual journals to control accounts require subledger references and produce a GL/subledger difference report | Open | |
| E25 | Financial exports/print layouts and dashboard figures are UAT-checked against ledger and report sources | Open | |
| E26 | Migration opening trial balance, policy/client/insurer/claim subledgers, banks and FX reconcile with zero unexplained material differences | Open | |

No gate in this supplement is marked passed by owner confirmation alone.
