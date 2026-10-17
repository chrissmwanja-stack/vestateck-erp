# Insurance Brokerage: Accountant Sign-off Pack

Status: **draft for accountant review. Not approved.** Nothing in this pack is an accounting sign-off. Until the accountant signs section 8, the treatments below are the software's current design, not agreed policy.

Prepared 16 October 2026 from the repo at `origin/main` 9f73349 plus the work on `security/hardening-consolidated`. It draws on `ANALYSIS.md` (the design draft), `POLICY_REVERSAL.md` and the migrations named in each section.

## 1. What the accountant is asked to do

1. Confirm the decided treatments in section 3 (owner decisions taken 11 October 2026).
2. Answer the open questions in section 4.
3. Review the ledger map in section 2, including the account names and the VAT and WHT accounts.
4. Review the event treatments in section 5. Any that differ from the expected practice should be marked in section 8.
5. Sign section 8 or return it with comments.

## 2. Ledger map (insurance template)

The Insurance Brokerage industry template (`20261008100625_insurance_brokerage_template_v0.sql`) creates 21 accounts. The app maps each to a posting role. The bind refuses to run if a required role is missing (`INS_POSTING_RULE_MISSING`).

| Code | Account (template name) | Type | Posting role | Used by |
|---|---|---|---|---|
| 1000 | Operating Bank | asset | `bank` | Operating bank accounts, commission transfers in |
| 1020 | Client Money Bank (Premium Trust) | asset | `client_money_bank` | Client money; earned commission held until moved |
| 1100 | Accounts Receivable Control | asset | `ar_control` | Gross premium at bind |
| 1110 | Commission Receivable | asset | not used by bind (see Q2) | Open question |
| 1120 | Claims Receivable from Insurers | asset | `insurer_claim_receivable` | Claims approved for payment through the brokerage |
| 1200 | VAT Input | asset | `vat_input` | Not used on commission (decision 6); see Q4 |
| 1210 | WHT Receivable | asset | `wht_receivable` | Not used on commission (decision 6); see Q4 |
| 2010 | Insurer Payable (Premiums) | liability | `insurer_payable` | Net premium owed to the insurer |
| 2020 | Unearned Commission | liability | `unearned_commission` | Commission at bind, until the insurer is paid in full |
| 2030 | Claims Payable to Clients | liability | `client_claim_payable` | Claim proceeds owed to the client |
| 2100 | VAT Output | liability | `vat_output` | Not used on commission; see Q4 |
| 2200 | WHT Payable | liability | `wht_payable` | Not used on commission; see Q4 |
| 4000 | Commission Income | revenue | `commission_income` | Earned commission (recognised on settlement) |
| 4100 | Brokerage Fees & Other Income | revenue | no posting role identified | Broker-fee charge lines; see Q4 |
| 5000 | General Expense | expense | general | Not used by insurance flows |

Other template accounts (cash, payroll, and so on) are not used by the insurance flows in this pack.

## 3. Decisions taken (owner, 11 October 2026)

These are built in migrations `20261011090000`, `20261011100000` and `20261012090000`. The accountant is asked to confirm them.

1. Commission is `round(gross × rate / 100, 2)`. The net to the insurer is the remainder.
2. The bind books the premium on the inception date and locks the policy.
3. Commission is credited to **Unearned Commission (2020)** at bind, not to income.
4. Commission becomes income (Dr 2020, Cr 4000) when a posted settlement fully pays the insurer's net item. Recognition counts payments only. A credit note on the insurer item does not count as paid.
5. Earned commission stays in the client-money bank (1020) until a manager moves it to an operating bank (1000) with a transfer batch. Each side is reconciled separately against bank statement lines.
6. No VAT or WHT on commission.
7. Corrections to a bound policy are "reverse and re-issue" for v1. Policies bound before `20261011090000` keep the old treatment (commission to income at bind) and are not backfilled.

## 4. Open questions

From `ANALYSIS.md` section 7. Questions 2, 5 and 6 are decided (section 3 above). Question 4 is partly decided.

1. **Gross-up (open).** Should gross premium go to AR (1100) at bind, as now? Or should client money go straight to the premium trust (1020) when received? The current bind books to 1100. Cash collection into 1020 and remittance out of it are not in the bind journal.
2. **Commission timing (decided in part).** The current design earns commission at bind into 2020, with recognition on insurer settlement. Confirm this, or say whether commission receivable (1110) should be used at bind instead.
3. **Net-of-commission (open).** Does the insurer remit only the net, so the broker never pays the gross on? The current design assumes yes.
4. **Account names and VAT/WHT (partly open).** Confirm the template names, and whether broker fees (4100) and any VAT or WHT apply.
5. **Corrections (decided for v1).** A bound policy cannot be edited. Corrections use a reversing journal, described in section 6.

## 5. Event treatments

### 5.1 Policy bind (`ins_policy_bind`, inception date)

With gross premium G and commission C, net to insurer N = G − C:

| Account | Debit | Credit |
|---|---|---|
| 1100 Accounts Receivable Control | G | |
| 2010 Insurer Payable (Premiums) | | N |
| 2020 Unearned Commission | | C |

Worked example: G = 1,000,000 UGX, rate 10%. C = 100,000, N = 900,000. Dr 1100 1,000,000 · Cr 2010 900,000 · Cr 2020 100,000. Balanced.

Two open items are created: an AR item for the client (`ins_policy_premium`, G) and a payable item for the insurer (`ins_policy_insurer`, N).

### 5.2 Commission recognised (on insurer settlement)

When a posted settlement fully pays the insurer's net item, commission moves from liability to income: Dr 2020 Unearned Commission, Cr 4000 Commission Income, for C.

### 5.3 Earned commission transfer

A manager moves earned commission from the client-money bank to an operating bank with a transfer batch (`ins_transfer_earned_commission`). The transfer can be voided (`ins_void_commission_transfer`). Each side is reconciled separately.

### 5.4 Claim approval and recognition, paid through the brokerage

Applies when the insurer's claim payment mode is `via_broker`.

**Approval posts nothing.** Approving a claim for amount A creates no journal and no open item. The approval is a decision, not an entitlement to money.

**Recognition** is a separate step, taken by an insurance manager once the insurer has confirmed the claim in writing. The confirmation reference is required. On recognition:

| Account | Debit | Credit |
|---|---|---|
| 1120 Claims Receivable from Insurers | A | |
| 2030 Claims Payable to Clients | | A |

Two open items are created at recognition: funds due from the insurer (`insurer_claim_receivable`) and proceeds due to the client (`client_claim_payable`). Receipts and payouts are refused until recognition has happened (section 5.9).

Claims paid directly by the insurer (`insurer_direct`) create no journal in this flow. Payments on these claims are recorded as evidence only (section 5.9).

### 5.5 Policy reversal ("reverse and re-issue", `20261014170000`)

Scope: active policies only, and only when no claim, renewal, posted settlement or credit application touches the policy, and no commission has been earned or transferred. The current period must be open. For a gross 1,000,000, net 900,000, commission 100,000 policy:

1. Premium credit note: Dr historical commission offset 1,000,000 / Cr AR control 1,000,000.
2. Insurer credit note: Dr insurer payable 900,000 / Cr the same offset 900,000.

Combined: Dr 2010 900,000, Dr commission 100,000, Cr 1100 1,000,000. The RPC checks that the original bind and both notes net to zero **by account**. It does not post a third reversal journal. Accounting date is the current date, not the inception date. Reissue is optional and creates a linked draft, never a bound policy.

Zero-commission policies use a `none` treatment.

### 5.6 Premium cash: receipts and remittances

Premium cash uses the standard Finance settlements, allocations and journals. The insurance cash request is an approval and audit record, not a second cash ledger.

| Movement | Debit | Credit | Journal source |
|---|---|---|---|
| Client pays premium into a client-money bank | 1020 Client Money Bank | 1100 AR Control | Finance settlement (`fin_settlement`) |
| Brokerage remits to an insurer | 2010 Insurer Payable | 1020 Client Money Bank | Finance settlement (`fin_settlement`) |

Controls:

- The bank must be an active client-money bank in the policy currency, with a mapped GL account.
- A cash request is made by one Finance user and approved by a different Finance user. The approval is bound to the exact settlement, so a generic Finance settlement cannot bypass it.
- A receipt is capped at the client's outstanding premium.
- A remittance is capped at the lower of (a) collected premium less remitted premium less commission already transferred, and (b) the insurer's outstanding payable. Commission is therefore not withdrawn before it is funded by collections (section 5.3).
- Partial receipts may fund the whole net insurer payable before they fund any commission. They never fund another policy's commission.
- Co-insurance remittances are per insurer share. Partial funding is rounded down to the cent; the final full collection releases the remaining cents. Broker fees and their VAT never fund insurer remittances.
- Generic Finance voids cannot remove a receipt that already funds a remittance or a commission withdrawal. The funded items must be reversed first.
- A bank line is matched to one posted settlement, and reconciliation needs a third Finance user (not the maker, checker or poster).

Read-only views (`ins_policy_cash_position`, cash totals per policy) show collected, remitted, commission transferred and the outstanding balances. They post nothing.

### 5.7 Co-insurance, charges and VAT (bind)

Applies to policies bound through the extended bind (`20261015150000`). Single-insurer policies with no charges use the unchanged legacy bind, which posts the same accounts without the charge lines.

- The gross premium is split across the insurers by share percentage. Amounts are rounded to the cent by largest remainder, with a deterministic tie-break by insurer ID. The lead insurer has no rounding privilege.
- For each insurer: payable = premium − commission + pass-through charges.
- VAT is charged only on broker fees marked VAT-exclusive, rounded to the cent per fee. Pass-through charges carry no VAT.

Bind journal (source `ins_policy_bind`):

| Account | Debit | Credit |
|---|---|---|
| 1100 AR Control | Total = gross premium + charges + VAT | |
| 2010 Insurer Payable (Premiums) | | Sum of insurer payables |
| 2020 Unearned Commission | | Sum of commission |
| Revenue account, per broker fee | | Fee amount |
| VAT output (liability) | | VAT |

Worked example: gross 1,000,000 UGX, commission 10%, two insurers at 60% and 40%, one broker fee of 50,000 UGX with 18% VAT.

- Insurer A: premium 600,000, commission 60,000, payable 540,000.
- Insurer B: premium 400,000, commission 40,000, payable 360,000.
- VAT = 9,000. Total invoiced = 1,000,000 + 50,000 + 9,000 = 1,059,000.
- Dr 1100 1,059,000 · Cr 2010 900,000 · Cr 2020 100,000 · Cr fee revenue 50,000 · Cr VAT output 9,000. Balanced.

The bind checks that the total equals payable + commission + fees + VAT. It refuses the bind unless the shares total 100% with exactly one lead, every share has been reviewed, each broker fee has an active revenue account, and VAT output is mapped to an active liability account. The bound configuration cannot be changed afterwards.

Open items: one AR item for the client's total, and one payable item per insurer share.

Reversal of a policy with co-insurance or any charge line, including a zero line, is refused by the reversal RPC and goes through the cancellation workflow (section 5.8).

### 5.8 Cancellations

A Finance maker prepares the cancellation from a calculation (a preview of the amounts). A different Finance checker approves or rejects it. Approval is refused if:

- the current accounting period is closed;
- the figures or collection position have changed since preparation (`INS_CANCELLATION_STALE`);
- an original insurer item has a posted credit, which needs separate review; or
- the accounting mappings have changed.

Manual exceptions require explicit acceptance by the checker and are recorded. Postings are dated on the approval day, not on the cancellation's effective date.

The approval posts these journals:

1. **Original item credits** (posted as credit notes, source `fin_credit_note`). Against the client's premium receivable: Dr cancellation clearing, Cr 1100 AR Control, for the amount applied. Against an insurer payable: Dr 2010 Insurer Payable, Cr cancellation clearing, for the amount applied.
2. **Adjustments journal** (source `ins_policy_cancellation`), with these lines where the amounts are non-zero:
   - Client refund due: Dr cancellation clearing, Cr refund payable. A payable item is created for the client.
   - Insurer recovery, where the insurer's item was already paid and cannot be credited: Dr 1100 AR Control, Cr cancellation clearing.
   - Commission clawback: Dr 2020 Unearned Commission if the commission was still deferred; otherwise Dr 4000 Commission Income.
   - Broker fee refund: Dr the fee's revenue account for the refunded base, and Dr VAT output for the refunded VAT.
   - The cancellation clearing account is credited with the total debits on this journal.
3. **Retained commission** (source `ins_policy_cancellation`). If commission was deferred and part of it is retained on the cancelled policy: Dr 2020 Unearned Commission, Cr 4000 Commission Income, for the retained amount.

Each journal balances on its own. The clearing account is the balancing account between the original items and the adjustments. **The write-up does not claim that the clearing account nets to zero.** The reviewer must confirm that.

If commission has already been transferred to the operating bank, the clawback is recorded as an amount due (`transferred_clawback_due`) and is not netted from cash. The reviewer must confirm this treatment.

### 5.9 Claim payments

**Insurer-direct claims** (`insurer_direct`). The insurer pays the client. The brokerage records each payment as evidence only. Each record needs an insurer payment reference, a date between the notified date and today, and an amount no greater than the approved amount less what has been paid. No journal is posted, and voiding a payment record posts no journal either.

**Brokerage-managed claims** (`via_broker`). Approval and recognition are in section 5.4. After recognition:

| Movement | Debit | Credit | Journal source |
|---|---|---|---|
| Insurer pays the brokerage into a client-money bank | 1020 Client Money Bank | 1120 Claims Receivable from Insurers | Finance settlement |
| Brokerage pays the client from a client-money bank | 2030 Claims Payable to Clients | 1020 Client Money Bank | Finance settlement |

- A receipt is refused until the claim is recognised. It is capped at the insurer's outstanding amount on the claim.
- A payout is refused until the claim is recognised. It is also capped at the cash received from the insurer and not yet paid out. The brokerage does not pay a client ahead of the insurer.
- The bank must be a client-money bank.
- Voiding a receipt or payout uses the Finance settlement void, which reverses its journal. Voids are refused on a closed claim.

### 5.10 Claim controls (`20261017110000`, `20261017120000`)

Proposed, for the accountant to confirm.

- **Recognition criteria.** A brokerage-managed claim stays "approved, pending settlement" until a manager records the insurer's written confirmation that it will pay the brokerage. The confirmation reference is required and stored on the claim history. Only then does the journal in section 5.4 post. Claims approved before `20261017110000` were accrued at approval and are treated as recognised.
- **Segregation of duties.** The person who registered a claim cannot approve it. Recognition and payment are not restricted by this rule.
- **Un-approval.** An approved claim can return to "assessing" with a reason, but only while nothing has been recognised and nothing has been paid. Nothing is reversed, because nothing was posted. After recognition or any payment, un-approval is refused.
- **Not built:** withdrawal, overpayment and recovery of a recognised claim (accountant answer 22), and excess or deductible handling (answer 21).

### 5.11 Foreign currency (Phase A3, in progress)

Built so far, with no effect on any company that has no foreign-currency lines (every company is UGX today, and no module yet passes a currency to the posting gateway):

- **Functional currency and rates** (`20261016140000`). Each company has a functional currency (UGX when unset), locked once the company has posted a journal. Exchange rates are dated, entered as a draft, approved by a different person, never edited once approved, and corrected by a correcting entry. A missing rate raises `FX_RATE_MISSING`. A rate older than the approved maximum age raises `FX_RATE_STALE`, and there is deliberately no default age.
- **Base-currency rounding** (`20261016180000`). Base amounts are rounded per line, so a journal that balances in its own currency can differ by a cent in base currency. The system adds a rounding line to the `fx_rounding` account (template default 5900 "Foreign Exchange Rounding", a code chosen for the accountant to confirm). It does this only within what per-line rounding can produce, and larger differences are refused (`JOURNAL_BASE_UNBALANCED`). Rounding differences do not go to FX gain or loss.
- **Void at the original rate** (`20261017140000`). A voided foreign journal reverses each line at its original currency and rate, so base amounts net to zero and a reversed rounding line stays flagged as rounding.
- **Ledger view** (`20261017130000`). The general ledger view shows rate and base debit and credit.

Not built: realised gain or loss at settlement, period-end revaluation at the closing rate, foreign-currency open items, settlements and bank reconciliation. The expected policy (transaction-date rate at recognition, closing rate for monetary items, differences to profit and loss, original rates never overwritten) is recorded in `ROADMAP.md` section 6 and is not yet implemented or signed off.

## 6. Reporting

- Broker fee tax report: `ins_broker_fee_tax_report` (a view). Broker-fee credit rows for cancellations are dated at posting.
- Insurer commission statements: `ins_insurer_commission_statement_data`, one per insurer.
- Policy cash position: section 5.6. Cancellation cash workflow (`20261015210000`): covered in section 5.8, with the cash-side controls not repeated here.

## 7. Coverage

Sections 5.6 to 5.9 were added after the 11 October review. They summarise the premium cash, co-insurance and VAT, cancellation and claim payment accounting. They are drafts for the accountant to check and have not been signed off. The reviewer should in particular confirm the cancellation clearing account (section 5.8) and the treatment of commission already transferred on a cancelled policy.

## 8. Sign-off

| Item | Accountant's decision | Comments |
|---|---|---|
| Section 3, decisions 1 to 7 | | |
| Section 4, open question 1 (gross-up) | | |
| Section 4, open question 2 (commission timing) | | |
| Section 4, open question 3 (net-of-commission) | | |
| Section 4, open question 4 (account names, VAT/WHT) | | |
| Section 5.1 to 5.11 | | |
| Sections 5.6 to 5.9 (premium cash, co-insurance and VAT, cancellations, claim payments) | | |
| Section 5.10 (claim recognition criteria, segregation of duties, un-approval) | | |
| Section 5.11 (foreign currency: rounding account 5900, void at original rate) | | |

Accountant name: ______________________ Date: ____________ Signature: ______________________

## 9. Pointers for the reviewer

- Design draft and decision history: `ANALYSIS.md`.
- Reversal rules and accounting: `POLICY_REVERSAL.md`.
- Test evidence: `supabase/tests/test_ins_*.sql` (run in CI), including `test_ins_commission*.sql` and `test_ins_policy_reversal.sql`.
- Local UAT data: the Pearl Risk Brokers Ltd (UAT) tenant in `supabase/seed.sql` section 6 holds bound policies and a claim for walk-through. It is local only and uses fictional data.
