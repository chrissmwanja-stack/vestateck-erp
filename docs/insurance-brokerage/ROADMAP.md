# Insurance Brokerage: Roadmap and Decisions

Status: working document, first written 16 October 2026, status updated 17 October 2026 and again 7 November 2026 (see section 7b); the agent commission section was rewritten on 18 November 2026 (section 7c). Suggested repo path: `docs/insurance-brokerage/ROADMAP.md`.

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
| 10% withholding tax on commission paid to insurance agents (ITA s.134). **Final tax from 1 July 2026** (s.139(aa), Income Tax (Amendment) Act 2026); the 10% rate applied from 2020 but was not final before that date. | Confirmed for agent commission. Whether it applies to commission an insurer pays a broker is not settled. |
| Insurance brokerage fees are **VAT-exempt**: the VAT Act (Cap 344), Schedule 3, includes brokerage within insurance services, and insurance services are exempt supplies. Separate non-brokerage services may be standard-rated. | Confirmed 17 Nov 2026. Fees already invoiced with VAT keep it. |
| Client withholding on a brokerage fee is **not** 10% (that is agent commission). It would be assessed under ITA s.129 (professional fee) or s.136 (designated agent), both 6%, with s.129's regular-compliance exception. | **Open.** Whether a brokerage fee is a professional fee under s.129 needs accountant confirmation. Rate seeded unapproved. |
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

Hard limits found in the finance core (list as first written 16 Oct; see section 7 for what has since been built):

- ~~`fin_ledger_currency()` is a fixed function returning `UGX`.~~ **Built 16 Oct** (`20261016140000`): functional currency per tenant, existing tenants stay UGX.
- ~~Open items and settlements reject any other currency (`OPEN_ITEM_CURRENCY`, `SETTLEMENT_CURRENCY`).~~ **Built 19–20 Oct** (`20261019120000`, `20261019130000`, repaired `20261020090000`): open items and settlements may be in a foreign currency at the rate they were booked or settled at. The guard names remain where a currency is still wrong (a settlement must be in its bank account's currency).
- `ins_bind_policy` refuses non-ledger currency (`INS_CURRENCY_UNSUPPORTED`). **Lifted in slice 3d-2** (21 Oct 2026): a policy now binds in its own currency at the approved inception-date rate (`FX_RATE_MISSING` without one), and the policy page says so instead of disabling Bind.
- Bank accounts are checked against ledger currency. **Lifted in slices 3c/3d-2**: settlements and transfers work through accounts in their own currency (a transfer still requires both accounts in the same currency); the cancellation pipeline stays functional-currency until 3d-3.
- ~~Journal lines have a currency label but no base amount or exchange rate. There is no exchange-rate table.~~ **Built 16–17 Oct**: rate and base amounts on journal lines with a rounding role, approved `fx_rates` table, currency-aware posting gateway (`20261016140000`–`20261017140000`).
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
| A3 currency review | Done 18 Oct 2026, see `CURRENCY_REVIEW.md`. Finding F1 (live): the supplier invoice, receivable invoice and cash/bank posting triggers ignored the `currency` column, so a USD 1,000 supplier invoice posted as UGX 1,000 (proved by insert). Closed by slice 3a. Insurance flows are protected by six guards until slices 3c and 3d. |
| A3 slice 3a | Built (`20261017170000`), option B chosen: the three triggers pass the document currency to the gateway. UGX documents post as before; a foreign document posts in its currency at the approved rate, or is refused (`FX_RATE_MISSING`, `FX_RATE_STALE`, `REG_PARAM_MISSING`, `JOURNAL_ROUNDING_ACCOUNT_MISSING`) and nothing is kept. Rows already in production in a foreign currency were posted at face value and are not repaired; run the read-only query in the review. |
| A3 slice 3b | Built (`20261019100000`): posting roles `fx_gain_realised` and `fx_loss_realised`; the insurance template gets revenue account 4900 and expense account 5910 for them (codes are defaults for the accountant to confirm; existing insurance companies are backfilled unless the code is already in use). The gateway accepts a per-line rate source (`rate_from_entry`) that the line guard checks against the referenced entry. `platform_fx_settlement` is the calculation and `platform_fx_realised_line` books the result. The cash/bank trigger now settles a supplier-invoice payment or receivable-invoice receipt in a foreign currency at the invoice's original rate and books the difference as realised gain or loss, which removes the base-currency residue that 3a had documented. A transaction in a different currency from its invoice is refused (`CASH_CURRENCY_MISMATCH`), as is a foreign-currency payroll payment (`CASH_PAYROLL_CURRENCY`). Insurance settlements and credit notes are not yet covered (3c, 3d). |
| A3 slice 3c | Built, in two parts: 3c-1 open items (`20261019120000`) and 3c-2 settlements (`20261019130000`, repaired by `20261020090000` after it failed a fresh replay -- the repair rewrites the original migration so fresh databases match the remote). Open items and settlements may now be in a foreign currency at the rate they were booked or settled at, with realised gain or loss against the booked rates; the `OPEN_ITEM_CURRENCY` guard is gone and `SETTLEMENT_CURRENCY` now means "the settlement is in its bank account's currency". Both parts use the 3b calculation. |
| A3 slice 3d-1 | Built (`20261021140000`, 21 Oct 2026): credit notes may be foreign. The note takes the currency of the items it applies to; control lines sit at each item's booked rate, the offset line at the credit-date rate, and the difference books as realised gain or loss; the void reverses in reversal mode so a foreign note negates exactly. The guard now enforces the approved credit-date rate instead of refusing foreign currencies. Slice 3d-2 (built `20261021160000`, 21 Oct 2026) lifted `INS_CURRENCY_UNSUPPORTED` and converted the transfers and the insurance posting functions: policies bind in their own currency at the approved inception-date rate, commission transfers move money between same-currency accounts booking the trust side at each policy's bound rate and the difference as realised gain or loss, commission recognition (and its reversal) posts at the bound rate, claim recognition accrues in the policy's currency, and voiding a transfer reverses it exactly. Slice 3d-3 (built `20261021170000`, 21 Oct 2026) converted the cancellation pipeline and removed the guard: original-item credit notes return the items at their booked rate with the clearing side at the cancellation-date rate and the difference realised; the adjustment journal posts in the policy's currency; recognition happens at the bound rate; the clearing account nets to zero in the currency and in base, and the unearned commission keeps a small documented base residue that 3e's revaluation clears. Remaining: 3e period-end revaluation, then the UGX column defaults and the 8-versus-10-decimal rate question before any non-UGX company is enabled. Column defaults that assume UGX and the 8-versus-10-decimal rate must be resolved before any non-UGX company is enabled. |
| A3 slice 3e | Built (`20261021180000`, 21 Oct 2026): period-end revaluation. `fin_revalue_fx(as_of)` revalues every foreign monetary balance -- outstanding foreign open items on the six control roles, foreign bank GLs, and the unearned-commission account per currency -- to the approved closing rate of the run date in one balanced functional-currency journal, booking the difference to the new `fx_gain_unrealised`/`fx_loss_unrealised` roles (template accounts 4901/5911, backfilled for existing insurance companies). Refuses a future date, a same-day repeat (`FX_REVAL_EXISTS`) and any date without an approved rate, all before anything is written; a later run reverses the previous live journal before measuring, so one revaluation journal is live at a time and only what still moves reposts. Open items keep their booked rate and base -- history is never overwritten, the residue clears on the control GL. Void (`fin_void_fx_revaluation`) reverses exactly and frees the day. This clears the documented unearned base residue left by 3d-2/3d-3. Test: `supabase/tests/test_fx_revaluation.sql`. |
| Claims in foreign currency | Built (`20261021210000`, 21 Oct 2026): the claims path walked a USD policy end to end -- recognition at the recognition-date rate with booking-entry items, receipt into the USD client-money trust netting the receivable exactly, payout from the trust settling the claim, reconciliation with the bank position. One fix: the payout anti-fronting check now counts held funds per currency (it summed across currencies). Test: `test_foreign_claims.sql`. |
| A3 rest | Built (`20261021190000`, 21 Oct 2026): foreign-currency bank reconciliation. Statement imports are pinned to the registered account's currency (omitted defaults to the account's, wrong refused `BANK_STMT_CURRENCY`, unregistered names keep the legacy default); manual cash matches refuse mixed currencies; the candidate search (and so auto-match) filters the cash/bank branch by currency; and `fin_bank_reconciliation_position` reads a foreign account's GL in the account's own currency, reporting the 3b/3e functional FX legs separately as `fx_gl_movements`. A foreign settlement books its bank leg at the settlement-date rate, so the statement reconciles the money at its arrival rate. With 3e this closes A3: every currency touchpoint (gateway, settlements, open items, credit notes, bind, transfers, recognition, cancellation, period-end, bank reconciliation) is currency-true. Test: `supabase/tests/test_foreign_bank_reconciliation.sql`. Followed by `20261021200000` (F3/F4, 21 Oct 2026, owner-decided): the six 'UGX' currency column defaults are dropped -- the journal gateway derives an omitted line currency from the tenant's ledger and omission fails loudly -- and rates are 8-decimal end to end (approval rounds via a before-trigger; check constraints pin `rate = round(rate, 8)` on `fx_rates`, `journal_entry_lines` and `fin_settlements`). **A3 and F3/F4 together close the currency review: nothing blocks enabling a non-UGX company.** |
| Phase B slice 1 | Built (`20261016170000`): unremitted-premium report and alert, read-only, deadline from `remittance.deadline_working_days`. No default: with no approved value the report says `deadline_not_set`. Monday to Friday only, no public holidays. Receipt date is the earliest posted receipt (cash is not traced receipt by receipt), so the deadline errs early. |
| Phase B, claim recognition | Built (`20261017110000`), **criteria proposed, not yet approved by the accountant**: an approved brokerage-managed claim stays "approved, pending settlement" until the insurer's written confirmation that it will pay the brokerage is recorded (reference required); the receivable is posted on recognition, and receipts and payouts are refused until then. Claims already approved were backfilled as recognised. |
| Phase B, claim segregation | Built (`20261017120000`), **proposed, for the accountant to confirm**: the person who registered a claim cannot approve it; an approved claim can be un-approved with a reason only while nothing is recognised and nothing is paid. |
| Phase B, finance worklist | Built (`20261019090000`): a Finance worklist of premium receipts, insurer remittances and cancellation cash that are waiting on a second Finance approval, with a page panel on the insurance side. |
| Phase B, rest | Not started: commission recognition at placement and commission receivable, per-insurer settlement mode, statutory charge catalogue, `ACCOUNTANT_PACK.md` write-ups. Agent commission is **built** as of 18 November 2026 -- see section 7c. |

Generated types (`packages/shared/src/database.types.ts`) were regenerated on 17 Oct 2026 against the live project, whose migration history matches the repo through `20261016180000`. This added `journal_entry_lines.is_rounding` and removed `recognised_at`, `recognised_by` and `ins_recognise_claim_receivable`, which appeared in the committed file but in no migration and not in the live database. Nothing in `apps/` referenced them. A later regeneration covers the migrations through `20261017130000`. A replay of every migration on a scratch Postgres, run through the postgres-meta type generator, matched the committed file for every table, column, view, function and enum; only formatting that differs between generator versions differed. The CI check compares byte for byte against the pinned CLI, so that check remains the authority. It is also the reason the 20 Oct commit `7878c90` broke it: that commit replaced the types file with output in a newer generator's format (parenthesised helper types), though its message said the opposite. The file was restored from `992b898`, where the check had just gone green; content was unaffected (verified against the catalog after a full replay).


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

**Status (21 Oct 2026):** item 3 slice 1 -- the shared document store -- is built (`20261021100000`): a generic `documents` registry (entity type + id, bucket + path, sha-256, template code/version for generated documents) over a private per-tenant storage bucket, RPC-only writes (`documents_register` validates the tenant folder and the hash), module-gated reads (insurance/finance/PO), and a Documents panel on the policy page (manager-only uploads, signed-URL downloads, orphan cleanup when the registry refuses a row). The pack's first set is rendered by the `generate-ins-doc` edge function (21 Oct 2026, the `generate-po` pattern): client debit note, insurer commission debit note, risk note and renewal notice, pdf-lib v1 templates, each upload registered into the store with its template code and version, with the caller's insurance access and tenant re-checked server-side. Rendering runs on the deployed stack (Deno), so the four documents still need a first look on a real policy. Item 1 (reporting dimensions and the commission rate matrix) is built (`20261020210000`): `ins_policies` gained optional branch and agent (active-at-create checks, renewals copy them) plus a `transaction_type` stamp (`new_business`/`renewal`); a new `ins_insurer_product_rates` matrix holds one approved rate per insurer/product line/effective window (draft -> approved -> withdrawn or end-dated, entrant cannot approve their own rate, overlapping approvals refused, entries immutable once written). The New policy form offers branch and agent selects and pre-fills the commission from an approved matrix rate when it covers today, falling back to the insurer default. Item 2 (insured-risk register and certificate stock) is built (`20261017100000`); binding a policy in the motor product line now requires an issued motor certificate attached to the policy. Item 6 slice 1 (intermediary register, agents and sub-agents, **no money** -- no commission accrual, payables or withholding) is built (`20261017150000`). The production book and the first reports are built (`20261021120000`, 21 Oct 2026): `ins_production_book` (one row per written policy -- reversed excluded, drafts never counted -- with client, insurer, product line, branch and agent names resolved through definer views that re-check tenant and insurance access on every read, because `bd_clients` and `organizations` sit behind other modules' RLS) and `ins_client_statement` (billed on bind, cash actually received -- posted receipt requests only, pending ones are not money -- and the balance). The production book screen groups by client, insurer, branch, agent, product line, transaction type, status or month with per-currency totals and Excel/PDF export; the statements screen shows one client's statement of account or, across all clients, the aged subsidiary balances bucketed from the bound date (not yet due / 31-60 / 61-90 / over 90 days). A new policy's branch select now reads `ins_branch_options` (an insurance-gated RPC) instead of the finance-gated `organizations` table, which left the list silently empty for insurance-only users; edit mode asks for inactive branches too so a saved draft's branch stays selectable. The premiums-written trend is built (21 Oct 2026, client-side): a gross-premium-by-month strip on the production book (one bar per month per currency, scaled to the currency's own maximum, tooltips with the month total and policy count, and a Month grouping option for the table and exports) over the same server-gated view -- no new SQL, and currencies are never merged. Endorsements slice E1 is built (`20261021220000`): proposals with no posting -- an `ins_policy_endorsements` table with its event log and RLS, a read-only per-share calculation (pro-rata over the remaining days as the fallback, an insurer-agreed delta overriding it, the commission delta at the policy's immutable bound rate, a `requires_review` flag when a share's delta exceeds its whole premium), descriptive `changes` (sum insured / risk description / notes) stored before/after, idempotent `ins_propose_policy_endorsement` by request key, proposer-only withdrawal, an `ins_endorsement_review_position` that computes current values as bound plus posted deltas, cross-guard triggers shared with the cancellation pipeline in both directions, and a live endorsement blocking `ins_create_renewal_draft`. Endorsements slice E2 (posting) is built (`20261021230000`): Finance-only prepare-then-decide maker/checker (with an explicit exception checkbox when a share's delta exceeds its whole premium), and on approval three ledger legs -- a client receivable item (`ins_policy_endorsement`), one insurer payable item per share (`ins_policy_endorsement_insurer`) and a NEW deferred commission entry tied to its own insurer item through `source_open_item_id` (existing entries and the recognition schedule untouched, earned-when unchanged); additional premiums bill the client and fund the insurer share; return premiums raise a credit note at the policy's booked FX rates capped at the original item's outstanding, with any excess raised as recovery items; clawbacks are honest -- the deferred pool is reduced first and the earned remainder reverses through commission income, recorded in `ins_endorsement_clawbacks`, commission rows themselves never mutated. Approval stamps the `END-0000-0000` number like `CXL-` at cancellation, descriptive-only endorsements post nothing but their number, posted endorsements are refused by the cancellation pipeline until slice E4, and the client statement nets endorsements in billed and received. Slice E3 (`20261022080000`) lifts the currency gate on the proven 3d patterns: the additional side journals and items in the policy's currency at the posting-date rate (the line guard prices it from the approved table; items carry their booking entry), return-premium credit notes go through the 3d-1 machinery -- the control line at each original item's booked rate, the clearing offset at the credit-date rate, the difference booked as realised gain or loss -- and every adjustment leg (clawbacks and the clearing balance) rides the policy's currency so the clearing account nets to zero in the currency and in base, with the small unearned-commission base residue left to the 3e revaluation, exactly as the foreign cancellation documents. The UI ships with the slice: an Endorse dialog on the policy page (effective date, per-share agreed deltas, changed values, live server-side calculation preview), an endorsements list with status chips and withdraw for live proposals, and Finance prepare/review controls (clearing-account select, review note of at least five characters, approve/reject) gated behind finance-team membership, with the money math staying server-side. The policy row is still never mutated; `END-` numbering is stamped at posting (E2) like `CXL-` at cancellation approval. Still open on item 4: endorsements netted on the statement, and the co-insurer schedule; the remaining pack pieces wait on the accountant's commission-recognition answer. Since this paragraph was written, quotation, bulk renewals and outcomes, renewal notices, claims depth, notifications and the policy approval workflow have also been built: section 7b has the current status of every gap.

**Also landed 17–20 Oct, from the insurance screens review (not Phase C items):** client detail page with manager-only KYC decisions; edit for draft policies, with the client and product line locked while risks are linked and a refusal to point a draft at a deactivated insurer or product line (`20261019110000`, `20261020100000`); search and filters on clients, insurers, policies and claims; the unremitted-premium report gained client and insurer filters and Excel/PDF export; commission statements can be viewed one currency at a time; the Bind button is disabled with the reason for a foreign-currency draft; New policy warns when the chosen client's KYC is not verified or the risk rating is high (a warning, not a block -- the bind rule is still undecided).

1. Reporting dimensions on policies: branch, agent, transaction type. Commission rate matrix.
2. Insured-risk register and certificate stock.
3. Document pack, first set, with the shared document store.
4. Production book, statements of account, aged balances, unremitted funds.
5. Endorsements -- proposals (E1), posting (E2) and the foreign legs (E3) built; cancel-of-endorsement-items + the pack document (E4) remains. **Sized 19 November 2026** -- see E4 below; it is an engine change, not a removed guard.
6. Agents and sub-agents.
7. Quotation and placement pipeline.
8. Bulk renewals and renewal outcomes.
9. Claims depth and correspondence.
10. Role split and policy approval workflow.
11. Client merge and the account-per-client review.
12. Insurer statement reconciliation.

## 7b. Status snapshot (7 November 2026; in-force import and e2e specs updated 17 November 2026)

Checked against `main` at `04bf056` plus the unmerged in-force import step 1; the in-force import line below was re-checked against `main` at `a255cc8` on 10 November 2026. "Built" means code and a test exist; none of it is accountant-approved.

| # | Gap | Status | Where |
|---|---|---|---|
| 1 | Insured-risk register and certificate stock | Built | `20261017100000` |
| 2 | Endorsements | E1 to E3 built (proposals, posting, foreign legs); **E4 open** (see the sizing note below -- there are two blockers, not one) | `20261021220000`, `20261021230000`, `20261022100000` |
| 3 | Quotation and placement | Built; placement fix | `20261106170000`, `20261107120000` |
| 4 | Document pack | First set built (`generate-ins-doc`, shared document store); needs a first look on a real policy; co-insurer schedule open | `20261021100000` |
| 5 | Production book and reporting | Production book, client statements, aged balances, premiums trend built; server-side as-of and pagination open | `20261021120000` |
| 6 | Agents and sub-agents | **Built end to end** 18 Nov 2026: accrual, terms, register, maker-checker payments, withholding at payment, period returns and statements (`20261117240000`, `20261117250000`, `20261118120000`, `20261118140000`, `20261118160000`, `20261118180000`). See section 7c. | `20261017150000`, `20261117240000`, `20261117250000`, `20261118120000` to `20261118180000` |
| 7 | Commission rate matrix | Built | `20261020210000` |
| 8 | Bulk renewals, outcomes, notices | Built | `20261022080000`, `20261106200000` |
| 9 | Claims depth | Reserve revisions, excess handling and document checklist built; letters and withdrawal or recovery (accountant answer 22) open | `20261022090000`, `20261106210000` |
| 10 | Shared document store and notifications | Built | `20261021100000`, `20261022110000` |
| 11 | Client merge, groups, account-per-client | Not started | |
| 12 | Role split and policy approval workflow | Approval workflow built; bind requires an approved policy (with two repair migrations) | `20261106180000`, `20261106230000`, `20261107090000`, `20261107100000` |
| 13 | Multi-currency | Built; A3 and F3/F4 closed 21 October | see section 7 |

Also built outside the table: insurer statement reconciliation (`20261106220000`, entry screen still to improve), per-insurer remittance position (`20261106190000`), the operational hardening migrations of 6 and 7 November.

Built since this snapshot: the in-force portfolio import and opening balances (`IN_FORCE_IMPORT.md`; all five steps, `20261107140000` to `20261109110000`) and its Playwright spec (`apps/web/e2e/insurance-import.spec.ts`). Also built since: Playwright specs for the money flow from approval and bind to premium receipt, insurer remittance and commission transfer (`insurance-cash-commission.spec.ts`, which starts from the seeded draft policy rather than creating the client and policy through the UI) and for a claim paid through the brokerage (`insurance-claim-payment.spec.ts`); see `apps/web/e2e/README.md` for what they leave uncovered. **Corrected 19 November 2026:** commission recognition at placement and the per-insurer
settlement mode (gross/net) are **built**, not "not started" as this line said. The modes are
`20261117200000` (per-share settlement basis, gross posting) and `20261117210000` (recognition
modes with `at_placement`), and `20261119240000` added `on_premium_collection`. An earlier
snapshot of this file missed them; the code was read to confirm. Still not started from Phase B:
`over_policy_term` (an earned-over-time schedule), the statutory charge catalogue, and
period-close states.

## 7c. Agent commission: what is built, and what it cost to find out

Built across item 6 slice 1 and eight later migrations, finished 18 November 2026. Written down
because four of the defects below were invisible from the code and only appeared when a test could
see them.

### What exists

| Piece | Where | What it does |
|---|---|---|
| Intermediary register | `20261017150000` | Agents, sub-agents and insurer-appointed agents, with termination and licence dates. Insurer-appointed agents never enter the brokerage's books. |
| Commission terms | `20261117240000` | Versioned, never edited: to change an arrangement you end-date a term and enter a new one, so an accrual already made keeps the figures it was made with. Entry and approval are separate people. |
| Accrual subledger | `20261117240000` | `provisional → eligible → paid`, with a reversal that mirrors the entry exactly. One share per policy per term. |
| Withholding at payment | `20261117250000`, `20261118120000` | Computed from approved effective-dated parameters; the **rate did not change on 1 July 2026, the character did** (s.139(aa) made it final). Nothing is withheld at accrual, because nothing has been paid. |
| Maker-checker payment | `20261118140000` | Authorisation is a table row, not a status on the accrual: propose (figures frozen), approve by a different manager, release and post. `ins_agent_commission_pay` survives but is gated on an approved payment. |
| Period returns | `20261117250000` | Returns to URA on the **payment-month** basis, prepared, approved, paid with a reference, void releases its lines. |
| Position | `20261118160000` | What is withheld, what is on a return, what is paid — per currency. |
| Statements | `20261118180000` | One agent's account, per currency, on the payment date, printable to PDF. |

The page in `apps/web` mirrors this: Overview, Commission Terms, Accruals, Payments, Statements,
WHT Remittances. No tab is a placeholder.

### The four defects, and why they were invisible

1. **The rate was right and the character was wrong.** The build hard-coded withholding as
   non-final. The 10% never changed; its character did, on 1 July 2026. A test that only checked
   the percentage passed throughout.
2. **Nothing distinguished "no withholding" from "not yet determined".** An unpaid share carries
   `wht_amount = 0` because paying is when the tax is decided. The register read that as "no tax"
   and told agents so. The sentence is now *"determined when the agent is paid"*.
3. **The withholding position added unlike currencies together** (`20261118160000`). 500 USD of
   tax plus 900,000 UGX of tax came back as 900,500 of something. Every single-currency tenant
   passes that code path; the defect needed a two-currency fixture to appear.
4. **The statement window used the accrual's `created_at`, not `paid_on`** (`20261118180000`), and
   its detail included reversed shares while its totals excluded them. A statement whose lines do
   not add up to its own headline is worse than no statement.

### Two claims in an earlier draft of this file that measurement refuted

Recorded because they were plausible and wrong, and the record of a wrong claim is worth more than
a silent correction:

- **"`actor_id` is never populated on commission events."** False. The column is omitted from every
  insert, which means the DEFAULT (`auth.uid()`) applies. A trigger written to "fix" it was redundant
  and was removed; test §17 now pins the real behaviour, including the honest null outside a session.
- **"A filed return can outlive the withholding behind it, so `unreported` goes negative."** Not in
  this schema: a return's amount is the sum of the accrual lines it claims, a paid share cannot be
  reversed, and the withholding guard refuses post-hoc edits. The floor is kept as a guard against a
  state the database does not currently permit, and documented as such.

### Still open on this area

- ~~**`ACCOUNTANT_PACK.md`** does not yet describe agent commission.~~ **Closed 19 November 2026:**
  section 5.12 describes the accrual basis, the character change on 1 July 2026 and the
  payment-month return basis, and agent commission is now a row in the section 8 sign-off table --
  it was missing from that table entirely, so an item the owner asked to be documented had never
  actually been put in front of the accountant to approve.
- **Whether an insurer's commission paid to a **broker** is subject to the same 10%** (s.134) is
  still unsettled — see section 2. It is a different question from agent commission and it is not
  answered by anything built here.
- ~~**Commission recognition at placement and commission receivable** (Phase B) is untouched.~~
  **Out of date as of 19 November 2026:** `at_placement`, `on_premium_collection` and the gross
  basis with commission receivable (1110) are all built. What is genuinely open is which insurer
  agreements use which mode -- an accountant question, not a build (`ACCOUNTANT_PACK.md` 5.13).
- **Decision, not yet taken:** whether the Accruals tab may offer a manual *accrue* action. It has
  been deliberately left out of three bits so that the default stays "accrual follows recognition".

### Two traps worth writing down (19 November 2026)

Neither is an insurance fact; both cost a full pass to discover, and both would catch the next person.

1. **`npx vitest run` from the repo root does not run this suite.** The config lives at
   `apps/web/vitest.config.ts`, so from the root vitest finds no config, applies no jsdom
   environment, and reports 1063 "failures" that are all `document is not defined`. The real run is
   `cd apps/web && npx vitest run`. A wholesale regression is almost always the wrong working
   directory, not a broken branch -- check that before reading a single failure.
2. **`tsc -b` needs a larger heap than the default here.** `npm run build` died with a V8
   `AllocateRawWithRetryOrFailSlowPath` abort, which looks like the OOM kill this repo hits with no
   swap, but swap was already on. `NODE_OPTIONS=--max-old-space-size=3072 npm run build` passes.
   The abort is a heap ceiling, not the machine running out.

Also: `check-migration-policy.sh` catches things the SQL tests cannot, because the tests run as the
table owner and never exercise the grants. The charge catalogue's `CREATE POLICY` without
`to authenticated` passed 98 migrations and the whole SQL suite, and failed rule 10. Run the policy
check before believing a green test run.

### Statutory charge catalogue: what is built (19 November 2026)

Built in `20261120002000` and made extensible in `20261120003000`, tested in
`supabase/tests/test_ins_statutory_charge_catalogue.sql`.

**The first cut had the right table and the wrong vocabulary**, and it is worth recording because
the mistake is seductive: the columns were generic, so it *looked* extensible, while the engine
around them was not. `basis` was a CHECK of five names, `charge_class` a CHECK of four, the resolver
a `case` over the five, and "a statutory charge must be verified" was keyed off the literal class
name `'commercial_fee'`. Adding a levy on sum insured, a banded statutory premium, or simply a fifth
class of charge would each have needed DDL and a function rewrite. That is the redesign deferred
rather than avoided, and it was caught before anything consumed it.

**What is now a row, not a migration:**

| To add | Where |
|---|---|
| A charge of an existing kind | one `ins_charge_catalogue` row |
| A rate on any registered quantity (premium, net, commission, **sum insured**, counts) | `ins_charge_param` row + a catalogue row |
| A new class of charge, statutory or not | `ins_charge_class` row, with `is_statutory` |
| A cap, floor or rounding | fields on the formula |
| A whole new shape of formula (banded marginal rates, fixed-per-count) | one branch in `ins_charge_formula_valid` and the resolver |

`ins_charge_class.is_statutory` is what decides whether a rate must be verified against an instrument.
The first cut hard-coded `'commercial_fee'` as the exception, which would have silently started
filtering out the next non-statutory class someone added.

**Two integrity points the change exposed, both fixed:**

- The immutability guard froze `rate_pct` and `fixed_amount`. Once the formula became authoritative
  those columns are null on both sides, so a billed charge's rate could have been edited freely
  through `formula` -- the rule would have existed and stopped biting. The guard now watches the
  formula.
- A charge whose base quantity the caller did not supply **raises** rather than pricing zero. A levy
  silently not charged is under-billing nobody notices until an audit; a per-vehicle charge billed
  for one vehicle is the same mistake with a smaller number.

**Verified versus assumed, and why it matters here.** The training levy is 0.5% of gross direct
premium by Insurance Act s.141(3) and SI No. 100 of 2020 reg. 17(2), which states the rate in words;
it seeds `verified` and active. The 1.5% IRA levy and the UGX 35,000 general-policy stamp duty appear
in press summaries and could not be confirmed against an instrument in this pass. Both seed
**unverified and inactive**, with the unconfirmed figures recorded and no source invented, so the
accountant can see what is waiting and nobody can bill it.

**Still open, and named in the migration so it is not mistaken for done:** policy creation does not
call the resolver yet (the client still supplies charge lines), and the statutory payable roles --
`insurance_training_levy_payable`, `ira_levy_payable`, `stamp_duty_payable` -- have no template
accounts. Rule 5 of the owner's five (integration with issuance, endorsements, cancellations,
receipts, remittances and reports) is therefore **partly** delivered: the pricing point exists, the
call sites do not.

**Deliberately not in the catalogue:** VAT on a broker fee (it already has its own pathway, and a levy
on the total of other levies would be a genuinely new design), and IRA *minimum premium rates* --
those are a rate table by vehicle class, not a levy, and they belong with the pricing engine.

### E4 sizing (19 November 2026)

Recorded before any code is written, because the item is larger than the phrase
"cancel endorsement items" suggests and one of its two blockers has never been written down.

**Blocker 1, known:** `ins_endorsement_cross_guard` raises `INS_ENDORSEMENT_POSTED` when a
cancellation in (`proposed`, `prepared`, `posting`) exists on a policy with any posted endorsement.

**Blocker 2, found while sizing and not previously recorded:** even with that guard gone the
cancellation would fail later, with `INS_CANCELLATION_REVIEW_REQUIRED: existing policy credits
require Finance review`. `ins_preview_policy_cancellation` refuses a policy with any posted credit
note applied to its premium item. A return-premium endorsement always raises one
(`ins_decide_policy_endorsement` credits the original premium item, or raises an
`ins_policy_endorsement_recovery` item when the return exceeds what is outstanding). So the common
case -- policy with a mid-term reduction, then cancelled -- hits blocker 2 immediately. Anyone
removing only the guard would ship a path that fails in production on exactly the policies E4
exists to serve.

**Blocker 3, the arithmetic:** the preview reconciles the policy receivable as
`total_credit <= invoice`, single item, `ins_policy_premium` only, built from the bind-time
snapshot. A policy with posted endorsements has *additional* premium items
(`ins_policy_endorsement`, `ins_policy_endorsement_insurer`) and credit notes, none of which the
preview knows about. Its "credit the client for the unexpired cover" figure would be computed on
the original premium while the client was actually billed the endorsed one -- wrong in the
direction that pays money out.

**Proposed shape (not built).** Do not teach the cancellation engine about endorsements. Instead
unwind them as their own approved document first -- an endorsement cancellation that fully credits
each endorsement's premium item, mirrors its commission entry, and re-derives the policy's current
values from `ins_endorsement_review_position` (which already computes current = bound + posted
deltas, and exists for exactly this). The ordinary cancellation then runs on a policy whose
financial position is once again the bind position, with no change to a 10,000-character money path
that is the most safety-critical code in the module. The guard becomes "endorsements must be
unwound first", which is a rule about ordering rather than a wall.

This is a multi-step build with its own maker/checker and its own tests. It is not included in this
pass: the commission work above is complete and verified, and folding an untested rewrite of the
cancellation engine into the same delivery would put a working money path at risk to save a round
trip.

## 8. Design defaults (change on request)

- Exchange rates entered manually per day with an approval step. A feed can be added later.
- Foreign policies are priced and settled in their own currency. Commission follows the policy currency.
- Rounding differences go to a dedicated rounding account.
- Existing policies are not restated.
- Settlement mode defaults to gross pending legal confirmation.

## 9. Questions still open

1. Compliance adviser: current text of section 90, and whether a broker may hold premium at all.
2. Accountant: sign-off of the commission recognition change, refund liability method, and the IAS 8 classification for policies bound before the change.
3. Accountant: tax codes for commission, broker fees and pass-throughs, and withholding on commission received from insurers. **Partly answered 17 Nov 2026:** agent-commission withholding is settled (s.134, 10%, final from 1 July 2026) and brokerage fees are VAT-exempt. Still open: whether a client-paid brokerage fee is a s.129 professional fee, and WHT on commission received from insurers.
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