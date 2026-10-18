# Insurance Brokerage: Roadmap and Decisions

Status: working document, first written 16 October 2026, status updated 17 October 2026. Suggested repo path: `docs/insurance-brokerage/ROADMAP.md`.

Sources: the IBS User Manual (Adelphi, Release 1.0, 2010), a clone of `vestateck-erp` at `ad159c7`, the accountant guidance in `Accountant.pdf`, and the existing docs `ANALYSIS.md`, `ACCOUNTANT_PACK.md` and `POLICY_REVERSAL.md`.

This file records what we found, what we decided, and the order of work. It does not replace the accountant pack, and nothing here is an accounting or legal sign-off.

---

## 1. Decisions taken (16 October 2026)

1. **Multi-currency is required.** The ledger is no longer UGX-only.
2. **No regulatory threshold, rate or deadline is hard-coded.** Stamp duty, levies, withholding rates, remittance deadlines, credit periods and retention periods live in data, with an effective date, a source reference and an approver.
3. **The accountant's written answers are the working basis.** Changes are made later if a qualified accountant or the compliance adviser says otherwise.

## 2. Caveats on the accountant guidance

- `Accountant.pdf` reads like AI-generated output, not a signed opinion (a stray citation marker, a final answer written as an offer to review the code, and "provisional" wording). Treat it as draft guidance.
- Section 8 of `ACCOUNTANT_PACK.md` stays unsigned until a qualified accountant confirms the treatments.
- Answer 22 (claim withdrawal, overpayment, recovery) is one line and needs real input.

Verification of the factual claims, done 16 October 2026 against public sources:

| Claim | Result |
|---|---|
| Brokers who receive premium must remit it by the next working day, without deducting commission (Insurance Act 2017, s.90(3)) | Confirmed in the 2017 text. Later amendments not checked. |
| Stamp duty UGX 35,000 per policy; group policies pay once; endorsements adding or removing beneficiaries not dutiable | Confirmed (URA schedule reports, Tax Appeals Tribunal ruling, 14 Feb 2025). Store as data, not constants. |
| 10% withholding tax on commission paid to insurance agents, final tax, since 1 July 2020 | Confirmed for agent commission. Whether it applies to commission an insurer pays a broker is not settled. |
| Ten-year record retention (s.106) | Not verified. |
| IRA circular for brokers dated 10 July 2026 | Not verified. |
| Insurance training levy rate | Not verified. Rate is set by the Authority. |

## 3. Open conflict: net versus gross remittance

Section 90(3) says remit "without any deductions of commissions". The current build does the opposite:

- Insurer payable is booked as gross minus commission.
- Commission is credited to unearned commission at bind.
- Earned commission stays in the client-money bank until a manager transfers it out.

The accountant's answers 3 and 6 also point to gross remittance with commission as a receivable from the insurer.

Press reports from 2018 said the Act would stop brokers collecting premiums at all. The 2017 text we found allows collecting and remitting. **Ask the compliance adviser or a lawyer** to confirm the current position. If brokers cannot hold premium, the cash module changes completely.

Working assumption until answered: build both settlement modes per insurer, default gross.

## 4. Where the repo stands

Built: clients, insurers, product lines, policy draft, bind, renewal; co-insurance shares and charges; premium cash approvals and insurer remittances; policy reversal; cancellation with pro-rata calculation, approval, posting and refund cash; claims with insurer-direct or via-broker payments; commission deferral, recognition and transfer with reconciliation; per-insurer commission statements; broker-fee tax view; 14 insurance SQL test files including tenant isolation.

Hard limits found in the finance core:

- `fin_ledger_currency()` is a fixed function returning `UGX`.
- Open items and settlements reject any other currency (`OPEN_ITEM_CURRENCY`, `SETTLEMENT_CURRENCY`).
- `ins_bind_policy` refuses non-ledger currency (`INS_CURRENCY_UNSUPPORTED`).
- Bank accounts are checked against ledger currency.
- Journal lines have a currency label but no base amount or exchange rate. There is no exchange-rate table.
- One `accounts` row is created per client (`ins_ensure_client_account`).
- Policies have no branch, agent or transaction-type column, and no expired or lapsed status was found.

## 5. Gaps against IBS (priority order)

| # | Gap | IBS reference | Priority |
|---|---|---|---|
| 1 | Insured-risk register and motor certificate stock | 7.1.2.1, 7.1.3 | High |
| 2 | Endorsements and transaction types | 7.1.5 to 7.1.8 | High |
| 3 | Quotation and placement pipeline | 7.1.4 | High |
| 4 | Document pack (debit and credit notes, risk note, co-insurer schedules, renewal notices) | 7.1.5 to 7.1.9 | High |
| 5 | Production book and reporting layer | Chapter 12 | High |
| 6 | Agents and sub-agents | 7.1.2.2, payroll | Medium to high |
| 7 | Commission rate matrix by insurer and product line | 7.1.5 | Quick win |
| 8 | Bulk renewals, outcomes, notices | 7.1.9 | Medium |
| 9 | Claims depth: excess, dates, document checklist, letters | Chapter 8 | Medium |
| 10 | Shared document store and notifications | n/a (seams 15, 16) | Medium |
| 11 | Client merge, groups, account-per-client scaling | 7.1.2.1, sundry debtors | Medium |
| 12 | Role split and policy approval workflow | Chapter 5 | Medium |
| 13 | Multi-currency | 1.3, 6.1.2.4 | **Required** |

Not to copy from IBS: posting unbalanced journals, free unposting of notes, workstation-level database credentials.

Beyond IBS: medical and group scheme member schedules, premium instalments, insurer statement reconciliation, client portal, KYC evidence, bulk import.

## 6. Accounting model after the accountant's answers

| Topic | Direction |
|---|---|
| Commission income | Recognise at placement or binding. Estimate a refund liability from the brokerage's own cancellation history, by class and contract type. No flat percentage without evidence. Track estimates separately from actual credit notes. |
| Commission receivable | Use it for earned but unpaid commission. A trust account and a receivable are different things. |
| Agent commission | Accrue when the contractual obligation arises, per the agency agreement. Configurable trigger. |
| Settlement | Support net and gross per insurer. Prevent double deduction and unauthorised retention. |
| Premium receivable | Book at binding when there is an enforceable right to collect. Record receipt separately. |
| Remittance | Flag premium received and not remitted by the deadline. Deadline read from the rules table. |
| Credit periods | Keep the customer deadline, insurer credit period, statutory remittance deadline and cover restrictions as separate rules. Warn, escalate, then optional block. A block never stops a required remittance, refund or correction. |
| Tax | Separate tax codes for premium, commission, broker fees, statutory charges and pass-throughs. No free VAT toggle on a transaction. |
| Statutory charges | Catalogue with basis, rate or amount, class, exemptions, collector, payable account, remittance status. Kept apart from commission income. |
| Cancellation | Configurable method: daily, monthly, short-rate, minimum retained. Show six components separately. Review exceptions. |
| Endorsements | Default to the original commission rate. Store the rate and agreement used on each transaction. |
| Corrections | Distinguish effective date, document date and accounting date. Never backdate silently into a closed period. |
| Restatement | Store an accounting-policy version on each posted transaction. Classification of the commission change under IAS 8 is for the accountant. |
| Claims | Do not book receivable and payable merely because a claim is approved. Add an "approved, pending settlement" state. Adjust approvals through linked entries, never overwriting. |
| Excess | Support four cases: deducted from insurer payment, collected from client, paid to provider, insurer pays in full and excess collected separately. Never brokerage income. |
| Foreign currency | Transaction-date rate at recognition. Closing rate for monetary items at period end. Differences to profit and loss. Original rates never overwritten. |
| Period close | Four states: open, closing, closed, reopened. Reopening needs a reason and a permanent audit event. |
| Approvals | Segregation of duties plus cumulative limits. Thresholds are configuration. |
| Retention | Configurable schedules, legal holds, audited disposal. Ten years is the unverified baseline. |
| Compliance | A calendar of obligations with owners, deadlines and evidence. Nothing hard-coded until verified. |

## 7. Work plan

### Phase A: foundations

**Status (17 Oct 2026):**

| Item | State |
|---|---|
| A1 rules table | Built, with seeded UNVERIFIED drafts for the UAT company (no approved values). Follow-up built (`20261016160000`): approval is by assignment, not by role. An approver must hold an assignment in force that covers the key or category; the Insurance Admin prepares drafts but approves nothing by role; company admins assign and withdraw approvers. |
| A2 accounting-policy version | Built. |
| A3 slice 1 | Built: functional currency setting, approved rate table. |
| A3 slice 2 | Built: rate and base amounts on journal lines, base-balance check. |
| A3 slice 2b | Built (`20261016180000`): base-currency rounding on foreign journals. New posting role `fx_rounding` (default account 5900, for the accountant to confirm); `journal_entry_lines.is_rounding` marks the system-added line; a foreign journal that needs rounding is refused if the company has no `fx_rounding` role. Differences beyond what per-line rounding can produce still raise `JOURNAL_BASE_UNBALANCED`. No guard removed. |
| A3 ledger view | Built (`20261017130000`, `20261017125000`): `v_account_ledger` exposes `fx_rate`, `base_debit`, `base_credit`, appended at the end so existing readers are unchanged. The view now runs with the caller's row-level security (`security_invoker`), so a user outside a company's finance team sees none of that company's ledger rows through it. |
| A3 slice 2c (gateway) | Built (`20261017140000`): `post_journal_entry` accepts a currency per line (none means functional currency; a supplied rate is ignored). `void_journal_entry` reverses at each line's original currency and rate and keeps a reversed rounding line flagged, so a voided foreign journal nets to zero in base; the USD 1,000 at 3,700 case that left +3,699,000 UGX now nets to zero. Reversal mode is an internal setting, `fin.reversal_of`, and the line guard accepts a supplied rate only if the entry being reversed used it (`JOURNAL_LINE_RATE`). No guard removed, and no module passes a currency yet. Still open: a line stores its rate to 8 decimals while `fx_rates` holds 10, and a line does not record which rate row it used. Before slice 3, each flow that reads or rebuilds journal lines needs a currency review: settlements, credit notes, bank reconciliation, commission deferral and transfers, cancellation posting and policy reversal (not yet audited one by one). |
| A3 currency review | Done 18 Oct 2026, see `CURRENCY_REVIEW.md`. **Live finding (F1):** the supplier invoice, receivable invoice and cash/bank posting triggers ignore the `currency` column, and nothing restricts it, so a USD 1,000 supplier invoice posts as UGX 1,000 (proved by insert). Insurance flows are protected by six guards. Decision needed on how to close F1 (refuse non-UGX, or post at the approved rate) and a read-only production query is in the review. |
| A3 slice 3 | Not started. Order: 3a close F1; 3b realised gain and loss roles and settlement calculation; 3c open items and settlements (remove those guards); 3d credit notes, bank accounts, transfers, policy bind and the insurance posting functions; 3e period-end revaluation. Column defaults that assume UGX and the 8-versus-10-decimal rate must be resolved before any non-UGX company is enabled. |
| A3 rest | Not started: realised gain and loss at settlement, period-end revaluation, foreign-currency bank reconciliation. |
| Phase B slice 1 | Built (`20261016170000`): unremitted-premium report and alert, read-only, deadline from `remittance.deadline_working_days`. No default: with no approved value the report says `deadline_not_set`. Monday to Friday only, no public holidays. Receipt date is the earliest posted receipt (cash is not traced receipt by receipt), so the deadline errs early. |
| Phase B, claim recognition | Built (`20261017110000`), **criteria proposed, not yet approved by the accountant**: an approved brokerage-managed claim stays "approved, pending settlement" until the insurer's written confirmation that it will pay the brokerage is recorded (reference required); the receivable is posted on recognition, and receipts and payouts are refused until then. Claims already approved were backfilled as recognised. |
| Phase B, claim segregation | Built (`20261017120000`), **proposed, for the accountant to confirm**: the person who registered a claim cannot approve it; an approved claim can be un-approved with a reason only while nothing is recognised and nothing is paid. |
| Phase B, rest | Not started: commission recognition at placement and commission receivable, per-insurer settlement mode, statutory charge catalogue, agent commission trigger, `ACCOUNTANT_PACK.md` write-ups. |

Generated types (`packages/shared/src/database.types.ts`) were regenerated on 17 Oct 2026 against the live project, whose migration history matches the repo through `20261016180000`. This added `journal_entry_lines.is_rounding` and removed `recognised_at`, `recognised_by` and `ins_recognise_claim_receivable`, which appeared in the committed file but in no migration and not in the live database. Nothing in `apps/` referenced them. A later regeneration covers the migrations through `20261017130000`. A replay of every migration on a scratch Postgres, run through the postgres-meta type generator, matched the committed file for every table, column, view, function and enum; only formatting that differs between generator versions differed. The CI check compares byte for byte against the pinned CLI, so that check remains the authority.


**A1. Rules table (`regulatory_parameters`)**
- Tenant-scoped, effective-dated key and value rows: key, value, unit, class, effective from and to, source reference, status (`draft`, `approved`), approver, approved at.
- Read through one function that resolves the value for a tenant and date. A missing value fails loudly.
- Seed values are editable and marked unverified.
- Tests: tenant isolation, overlapping dates refused, approval required before use, missing value raises.

**A2. Accounting-policy version**
- `accounting_policies` table (name, version, effective from, description, approved by).
- A policy-version column on journals and on the insurance transaction tables.
- Default to the current version. Old rows keep version 1.
- Tests: new postings carry the version, history is immutable.

**A3. Multi-currency core**
- Functional currency per tenant, replacing the fixed function. Existing tenants stay UGX.
- Exchange-rate table: date, from, to, rate, source, entered by, approved by. Rates are never edited, only superseded.
- Transaction currency, rate and base amount on journal lines, open items and settlements.
- Base amounts must balance per journal. A rounding account takes rate-rounding differences.
- Realised gain and loss at settlement.
- Period-end revaluation of open foreign balances, with unrealised gain and loss and a link to the revaluation run.
- Foreign-currency bank accounts and reconciliation in the account currency.
- New posting roles: realised FX gain or loss, unrealised FX gain or loss, FX rounding.
- Remove the currency guards one at a time, each with a regression test: `OPEN_ITEM_CURRENCY`, `SETTLEMENT_CURRENCY`, bank-account ledger-currency check, `INS_CURRENCY_UNSUPPORTED`.
- Tests: UGX tenants unchanged, balance by account in base currency, settlement at a different rate, revaluation, reversal, cross-tenant denial.
- Risk: this touches procurement, payments and the other modules. Flag it to their owners before merging.

### Phase B: insurance accounting re-baseline

- Commission recognised at placement, to commission income, with a commission receivable (1110) and a refund liability.
- Per-insurer settlement mode, gross or net, default gross, with checks against double deduction.
- Claim receivable and payable rules per section 6, and the "approved, pending settlement" state.
- Statutory charge catalogue driven from the rules table.
- Unremitted-premium alert and report, deadline from the rules table.
- Agent commission trigger setting.
- Update `ACCOUNTANT_PACK.md` with the four missing write-ups: premium cash, cancellations, co-insurance and VAT, claim payments. **Drafted** as sections 5.6 to 5.9 (not signed off). Section 5.4 corrected: approval posts nothing; recognition does.

### Phase C: features

**Status (17 Oct 2026):** item 2 (insured-risk register and certificate stock) is built (`20261017100000`); binding a policy in the motor product line now requires an issued motor certificate attached to the policy. Items 1 and 3 to 10 are not started.

1. Reporting dimensions on policies: branch, agent, transaction type. Commission rate matrix.
2. Insured-risk register and certificate stock.
3. Document pack, first set, with the shared document store.
4. Production book, statements of account, aged balances, unremitted funds.
5. Endorsements.
6. Agents and sub-agents.
7. Quotation and placement pipeline.
8. Bulk renewals and renewal outcomes.
9. Claims depth and correspondence.
10. Role split and policy approval workflow.
11. Client merge and the account-per-client review.
12. Insurer statement reconciliation.

## 8. Design defaults (change on request)

- Exchange rates entered manually per day with an approval step. A feed can be added later.
- Foreign policies are priced and settled in their own currency. Commission follows the policy currency.
- Rounding differences go to a dedicated rounding account.
- Existing policies are not restated.
- Settlement mode defaults to gross pending legal confirmation.

## 9. Questions still open

1. Compliance adviser: current text of section 90, and whether a broker may hold premium at all.
2. Accountant: sign-off of the commission recognition change, refund liability method, and the IAS 8 classification for policies bound before the change.
3. Accountant: tax codes for commission, broker fees and pass-throughs, and withholding on commission received from insurers.
4. Accountant: claim withdrawal, overpayment and recovery treatment (answer 22).
5. Compliance adviser: the current IRA broker circular, returns, client-money reporting and the retention rule.
6. Owner: whether any target clients need currencies other than USD at launch.

## 9a. Accountant answers re-read (16 Oct 2026)

Source: `Accountant.pdf` (16 pages, provisional, not signed). Recorded decisions and conflicts:

- **Remittance deadline conflict.** Answer 7 cites the Insurance Act: remit no later than the next working day. The UAT draft `remittance.deadline_working_days` is 3 working days (unverified). Decision: keep 3 for now; the compliance adviser decides. The alert built in Phase B slice 1 uses the approved value, so it will show the 3-day deadline until that value changes.
- **Claims (answers 20 to 22).** Approval alone does not create a receivable or payable. Deductibles are a claim adjustment, not brokerage income. Withdrawal or recovery is a linked adjustment, never an overwrite. Next Phase B slice.
- **Not yet built:** period-close states (answer 24), second-approver thresholds (25), premium age in the unremitted report (26), excess (21), closing-rate revaluation (23), commission receivable (3).
- **Still unverified:** the ten-year retention rule (answer 27 cites s.106), and the IRA circular dated 10 July 2026 (answer 28). Both need the compliance adviser.

## 10. Working rules

- Writes go through RPCs with `ins_via_rpc` guards. No direct client writes.
- Every new table gets tenant RLS, cross-tenant read and write denial tests, and an entry in the authorisation catalogue test.
- Every posting change has a balance-by-account assertion.
- Schema changes use `apply_migration`, never `execute_sql`.
- Changes to the shared finance core or `bd_clients` are flagged to the other module owners first.
- Run the full SQL suite on a fresh local stack and regenerate types before merging.
- No regulatory figure enters code. It enters the rules table, with a source and an approver.