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

### 5.4 Claim approval, paid through the brokerage

Applies when the insurer's claim payment mode is `via_broker`. On approval for amount A:

| Account | Debit | Credit |
|---|---|---|
| 1120 Claims Receivable from Insurers | A | |
| 2030 Claims Payable to Clients | | A |

Two open items are created: funds due from the insurer and proceeds due to the client. Claims paid directly by the insurer (`insurer_direct`) create no journal in this flow.

Claim payments (receipts and payouts through client money) are recorded per payment and can be voided. Their treatment is in `20261013090000_ins_claim_payments.sql`. **Not yet summarised here** (see section 7).

### 5.5 Policy reversal ("reverse and re-issue", `20261014170000`)

Scope: active policies only, and only when no claim, renewal, posted settlement or credit application touches the policy, and no commission has been earned or transferred. The current period must be open. For a gross 1,000,000, net 900,000, commission 100,000 policy:

1. Premium credit note: Dr historical commission offset 1,000,000 / Cr AR control 1,000,000.
2. Insurer credit note: Dr insurer payable 900,000 / Cr the same offset 900,000.

Combined: Dr 2010 900,000, Dr commission 100,000, Cr 1100 1,000,000. The RPC checks that the original bind and both notes net to zero **by account**. It does not post a third reversal journal. Accounting date is the current date, not the inception date. Reissue is optional and creates a linked draft, never a bound policy.

Zero-commission policies use a `none` treatment.

## 6. Reporting

- Broker fee tax report: `ins_broker_fee_tax_report` (a view). Broker-fee credit rows for cancellations are dated at posting.
- Insurer commission statements: `ins_insurer_commission_statement_data`, one per insurer.
- Policy cash position and cancellation cash workflows exist (`20261015120000`, `20261015210000`). Their accounting is **not yet summarised here** (see section 7).

## 7. Not yet covered by this pack

These are built in the software but their accounting has not been written up for review. The accountant should be asked to review them before sign-off:

- Premium cash collection into 1020 and remittance to insurers (`ins_policy_cash_*`, `20261015*`).
- Cancellation refunds, recovery and the cancellation posting (`ins_cancellation_*`).
- Co-insurance charges and broker fee VAT (`20261015150000_ins_coinsurance_charges.sql`).
- Claim payments in detail (`20261013090000`).

## 8. Sign-off

| Item | Accountant's decision | Comments |
|---|---|---|
| Section 3, decisions 1 to 7 | | |
| Section 4, open question 1 (gross-up) | | |
| Section 4, open question 2 (commission timing) | | |
| Section 4, open question 3 (net-of-commission) | | |
| Section 4, open question 4 (account names, VAT/WHT) | | |
| Section 5.1 to 5.5 | | |
| Section 7 (items not yet covered) | | |

Accountant name: ______________________ Date: ____________ Signature: ______________________

## 9. Pointers for the reviewer

- Design draft and decision history: `ANALYSIS.md`.
- Reversal rules and accounting: `POLICY_REVERSAL.md`.
- Test evidence: `supabase/tests/test_ins_*.sql` (run in CI), including `test_ins_commission*.sql` and `test_ins_policy_reversal.sql`.
- Local UAT data: the Pearl Risk Brokers Ltd (UAT) tenant in `supabase/seed.sql` section 6 holds bound policies and a claim for walk-through. It is local only and uses fictional data.
