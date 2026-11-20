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
| 1110 | Commission Receivable | asset | `commission_receivable` | Commission owed by the insurer under gross settlement (section 5.14). Unused under net, where a company still defaults until it chooses |
| 1120 | Claims Receivable from Insurers | asset | `insurer_claim_receivable` | Claims approved for payment through the brokerage |
| 1200 | VAT Input | asset | `vat_input` | Not used on commission (decision 6); see Q4 |
| 1210 | WHT Receivable | asset | `wht_receivable` | Not used on commission (decision 6); see Q4 |
| 2010 | Insurer Payable (Premiums) | liability | `insurer_payable` | Premium owed to the insurer: **gross** under the decided basis, net only for a company still on the historic default (section 5.14) |
| 2020 | Unearned Commission | liability | `unearned_commission` | Commission held back at bind under net settlement, or under recognition cases 2 and 3, until the event that earns it (section 5.13) |
| 2030 | Claims Payable to Clients | liability | `client_claim_payable` | Claim proceeds owed to the client |
| 2100 | VAT Output | liability | `vat_output` | Not used on commission; see Q4 |
| 2200 | WHT Payable | liability | `wht_payable` | Not used on commission; see Q4 |
| 4000 | Commission Income | revenue | `commission_income` | Earned commission: at bind in case 1, on the client's receipt in case 2, on the insurer's settlement in case 3 (section 5.13) |
| 4100 | Brokerage Fees & Other Income | revenue | no posting role identified | Broker-fee charge lines; see Q4 |
| 5000 | General Expense | expense | general | Not used by insurance flows |

Other template accounts (cash, payroll, and so on) are not used by the insurance flows in this pack.

Added after this table was written (see section 9): 3900 Opening Balance Clearing for the in-force import, and the foreign-exchange accounts 4900, 4901, 5910, 5911 and 5900.

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
2. **Commission timing — answered by the owner, 19 November 2026.** Recognition follows the insurer agreement, in three cases, not one rule (section 5.13): an unconditional entitlement is earned at bind; an entitlement conditional on the policyholder paying is earned on the covering receipt; one that follows the insurer's settlement is earned then. Gross settlement with commission receivable (1110) is the decided basis (section 5.14). What remains for the accountant is the *classification* of each insurer agreement, and the s.90(3) set-off question. The previous wording of this question — confirm net-until-settlement, or use 1110 at bind — is therefore closed.
3. **Net-of-commission (open).** Does the insurer remit only the net, so the broker never pays the gross on? The current design assumes yes.
4. **Account names and VAT/WHT (VAT and the brokerage-fee treatment decided; template names still open).** Confirm the template names. On broker fees (4100), see the clarification below.

**Broker fees: VAT and withholding (clarified 17 November 2026).** Genuine
insurance brokerage fees charged to clients are treated as **VAT-exempt**. The
VAT Act (Cap 344), Schedule 3, includes brokerage within insurance services, and
insurance services are exempt supplies. Separate non-brokerage services must be
classified independently and may attract standard-rated VAT, so a fee carries an
explicit classification (`insurance_brokerage` or `other_taxable_service`) and
the second requires a stated reason. The standard rate is held in governance as
`tax.vat_standard_rate_percent` for the taxable categories and is never the
default for a brokerage fee. Until 17 November 2026 every broker fee was charged
18% VAT, which is now understood to have been wrong; fees already invoiced keep
their VAT because that output tax has been declared.

Client withholding tax is **not** automatically applied at the insurance-agent
commission rate. Incoming WHT must be assessed against sections 129 and 136 of
the Income Tax Act, including payer status, the nature of the fee and the
applicable exemptions, and section 129 also has a regular-compliance exception
for the payer. Being VAT-exempt does not settle the withholding question:
whether a client-paid brokerage fee is a professional fee under s.129 needs
accountant confirmation before production activation, and the rate is seeded
unapproved for that reason. Withheld tax is an asset (`wht_receivable`, 1210),
never a reduction of revenue and never a liability of the brokerage.

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

> **This is case 3 of section 5.13 and is no longer the only treatment.** It remains the
> default for a company that has not chosen, and it is the correct treatment for insurers
> whose agreements make entitlement follow settlement. See 5.13 for the placement and
> collection cases.

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
- **Not built:** withdrawal, overpayment and recovery of a recognised claim (accountant answer 22). Excess handling (answer 21) was built in `20261106210000` (see section 9).

### 5.11 Foreign currency (Phase A3, closed 21 October 2026)

> **Update 7 November 2026:** the first-draft text below is superseded. Realised gain or loss, period-end revaluation, foreign-currency open items, settlements, bank reconciliation, policy bind, endorsements and claims are all built. See `ROADMAP.md` section 7 and `CURRENCY_REVIEW.md`, and section 9 below for what to review.

Built so far, with no effect on any company that has no foreign-currency lines (every company is UGX today, and no module yet passes a currency to the posting gateway):

- **Functional currency and rates** (`20261016140000`). Each company has a functional currency (UGX when unset), locked once the company has posted a journal. Exchange rates are dated, entered as a draft, approved by a different person, never edited once approved, and corrected by a correcting entry. A missing rate raises `FX_RATE_MISSING`. A rate older than the approved maximum age raises `FX_RATE_STALE`, and there is deliberately no default age.
- **Base-currency rounding** (`20261016180000`). Base amounts are rounded per line, so a journal that balances in its own currency can differ by a cent in base currency. The system adds a rounding line to the `fx_rounding` account (template default 5900 "Foreign Exchange Rounding", a code chosen for the accountant to confirm). It does this only within what per-line rounding can produce, and larger differences are refused (`JOURNAL_BASE_UNBALANCED`). Rounding differences do not go to FX gain or loss.
- **Void at the original rate** (`20261017140000`). A voided foreign journal reverses each line at its original currency and rate, so base amounts net to zero and a reversed rounding line stays flagged as rounding.
- **Ledger view** (`20261017130000`). The general ledger view shows rate and base debit and credit.

Not built when this section was written (all since built, see the update above): realised gain or loss at settlement, period-end revaluation at the closing rate, foreign-currency open items, settlements and bank reconciliation. The expected policy (transaction-date rate at recognition, closing rate for monetary items, differences to profit and loss, original rates never overwritten) is recorded in `ROADMAP.md` section 6 and is not yet implemented or signed off.

### 5.12 Agent commission: accrual, withholding and returns (item 6, finished 18 November 2026)

> **Status: built, not signed off.** This section describes what the software does. Section 7c of
> `ROADMAP.md` lists what is still unconfirmed.

**What is being accounted for.** A sub-agent or referral partner earns a share of the brokerage's
commission on a policy. The share is a cost of the brokerage, not a reduction of revenue: netting it
against commission income would hide both figures, so it posts to its own expense account (5010,
role `agent_commission_expense`) with a credit to the agent payable. **An agent appointed by an
insurer is not on the brokerage's books at all** — that agent is paid by the insurer, and the system
refuses the transaction by name rather than recording a zero.

**The lifecycle, and why it has three states.**

| State | Meaning | Ledger |
|---|---|---|
| `accrued` (the provisional step) | The brokerage's commission on the policy has been recognised, so an obligation to the agent exists but is not yet payable. | Expense and payable posted. |
| `eligible` | Settlement conditions are met: the policy is bound and nothing is in dispute. | Nothing further. |
| `paid` | Money has left, through a separate approver, at the payment date. | Payable cleared, withholding credited to `wht_payable`. |
| `reversed` | The share is undone before payment, with a reason. Reverse and re-enter, never edit. | The original entry is mirrored exactly. A **paid** share cannot be reversed; recovering money from an agent is a decision, not a journal. |

**Withholding: the rate did not change, the character did.** Withholding is 10% under ITA s.134 and
has been since 2020. What changed on **1 July 2026** is that s.139(aa) of the Income Tax (Amendment)
Act 2026 made it a **final** tax. The system holds both the rate and the character as effective-dated
approved parameters, and the sentence an agent is shown differs accordingly: "final tax" means the
agent does not declare it again; "payment on account" means they still do. Both are 10%; presenting
them as one thing is what the earlier build did, and it was wrong in a way no percentage check
would catch.

On the accountant's own example: gross share 300,000, withholding 30,000, net 270,000 —
`Dr Agent commission expense 300,000 / Cr Agent payable 300,000` at accrual, then
`Dr Agent payable 300,000 / Cr Bank 270,000 / Cr WHT payable (URA) 30,000` at payment.

**Withholding happens at payment, not at accrual.** No money has moved at accrual, so no tax has been
withheld; the accrual carries `wht_amount = 0` to mean *not yet determined*, not *no tax owed*. The
agent register says which, in words.

**The return period follows the payment.** A share earned in November and paid in December belongs on
December's return. The remittance is prepared by one manager, approved by a second, and paid with the
URA reference recorded; a voided return releases its lines so a later return can claim the tax.

**Maker-checker on the payment itself.** One manager proposes the payment and the tax is fixed at that
moment; a *different* manager approves those exact figures; only then is it released and posted. An
approved payment whose figures were recomputed at release time would not be an approved payment.

**Statements.** Each agent's statement runs on the payment date, states each currency separately
(they are never added together), and says whether the tax withheld was final or on account.

**What the accountant is asked to confirm here.** The accrual basis for each agreement type
(percentage of the brokerage's commission, fixed amount, tiered, product-specific, shared split); that
the agent-share expense treatment above is right rather than a netting against commission income; and
that the 1 July 2026 character change is reflected correctly for shares paid across that boundary.

### 5.13 Commission recognition: three cases, one switch (19 November 2026)

> **Status: built; the baseline needs your signature.** The owner has decided the shape
> (below); what remains for you is to confirm which insurers fall in case 2.

**The distinction being drawn.** When the brokerage has *earned* its commission and
when it has *collected* the money are two different events, and the software must not
treat them as one. What decides the recognition point is the insurer agreement: whether
the brokerage's entitlement is unconditional once the policy is placed, or conditional
on something that happens later.

| Case | Agreement says | Mode | Earned at | Journal at bind |
|---|---|---|---|---|
| 1 | Entitlement is unconditional on placement/bind | `at_placement` | bind date | Dr 1100 gross · Cr 2010 net · Cr 4000 commission |
| 2 | Entitlement is conditional on the policyholder paying | `on_premium_collection` | the receipt that covers the premium | Dr 1100 gross · Cr 2010 net · Cr 2020 unearned |
| 3 | Entitlement follows the insurer's settlement | `on_insurer_settlement` | settlement of the insurer's item | as case 2, then Dr 2020 · Cr 4000 on settlement |

Case 3 is the historic behaviour and remains the **default** for a company that has not
chosen. Cases 1 and 2 exist because recognising case-2 agreements at placement would
overstate both revenue and the amount recoverable — the commission would be booked
before the contingency that creates it has cleared.

**Case 2 in detail, because it is the one you are being asked to populate.**

- **The condition is the client's payment, not the insurer's.** A receipt that leaves the
  client's premium item fully covered earns the whole commission, in one movement, on the
  receipt date. **A partial receipt earns nothing**: the agreement is binary, and
  recognising a proportion on a part payment would invent an entitlement the agreement
  does not create. If any insurer agreement is in fact pro-rata on collection, that is a
  fourth case and it needs a schedule, not a switch.
- **The unearned balance stays in 2020 until then**, which is what makes the deferred
  position visible to you between bind and collection.
- **Voiding the receipt un-earns it.** The reversing journal goes back through 2020 at
  the *same booked rate*, and the deferred entry is restored. Income is never carried on
  money that came back.
- **A credit note does not earn it on its own.** Coverage is tested as receipts plus
  credit notes, because a fully credited item can never be collected and leaving it
  deferred forever is a worse error than recognising it — but the recognition event is
  the **receipt**. Please confirm you are content with that treatment for a cancelled sale
  that is credited rather than refunded.
- **Gross settlement and case 2 cannot coexist.** Under gross the premium crosses in full
  at placement, so there is nothing left to collect; the system refuses the combination by
  name at bind rather than silently choosing one.

**What the accountant is asked to confirm here.**

1. Which insurer agreements are case 1, which are case 2, and which are case 3. Today
   every company defaults to case 3 unless it chooses otherwise, so a misclassification
   is not something the software will catch.
2. That the case-2 trigger is the **client's** receipt — not the insurer's settlement and
   not the credit note.
3. That a voided receipt reverses the recognition rather than leaving it earned.
4. Whether any agreement is pro-rata on collection, which would need a schedule and is
   not built.

### 5.13b Statutory charges on the policy (19 November 2026)

> **Status: built; the rate classification needs your confirmation.**

Charges on a policy used to be free text: a description, an amount, and a flag for
whether the money passes through to an insurer. That is enough to bill a client and
not enough to account for a levy, because nothing recorded what class of charge it
was, who collects it, who receives it, which account it is payable to, or which
version of the law set the rate.

**The catalogue.** Statutory charges are rows in `ins_charge_catalogue`, versioned
and immutable once billed. A charge says its class (statutory tax, statutory levy,
regulatory contribution, commercial fee), its formula, the collector, the recipient,
the payable account, and its exemptions. A statutory rate must name the instrument
that verified it: "verified" without a source reference is refused, which is what
stops it meaning "someone typed it".

**On a policy.** Pricing is explicit -- `ins_apply_statutory_charges` -- and the
manager then acknowledges the resulting figures. The acknowledgement is not
ceremony: a levy is money collected for someone else, and if a verified rate changes
between drafting and binding, the policy would otherwise bind at the old figure with
nothing to show for it. Bind re-prices and refuses if the figures moved.

**Three seeded charges, and which of them you can rely on.**

| Charge | Rate | Verified? | Billed? |
|---|---|---|---|
| Insurance Training Levy | 0.5% of gross direct premium | **Yes** -- Insurance Act s.141(3) and SI No. 100 of 2020 reg. 17(2), which states the rate in words | Yes |
| IRA regulatory levy | 1.5% (unconfirmed) | No -- press summaries only | **No**, inactive until verified |
| Stamp duty, general policy | UGX 35,000 (unconfirmed) | No -- press summaries only | **No**, inactive until verified |

**What you are asked to confirm here.**

1. The two unconfirmed rates, or the instruments that state them. Until then they are
   visible in the catalogue and cannot be billed, which is deliberate: an unverified
   figure that could be billed would end up on a client invoice.
2. Which charges this brokerage is actually obliged to collect and remit, and which
   are the insurer's obligation. The distinction decides whether the charge belongs
   in the client's invoice at all.
3. Whether enforcement should be on. The company setting
   `ins.statutory_charge_enforcement` is **advisory** by default, meaning charges are
   priced and recorded when asked but a policy binds without them. Turning on
   `required` makes bind refuse a policy whose statutory charges were not priced and
   acknowledged -- and, importantly, **raises the premium of every policy bound from
   then on**. That is a commercial decision, not a configuration detail, which is why
   it is not the default.

### 5.14 Gross versus net remittance, and what the software does now (19 November 2026)

> **Status: build follows the owner's decision; one legal question stays open.**

The insurer payable is booked **gross** and commission is a separate receivable from the
insurer — never a deduction from what the insurer is owed. The bind posts
Dr 1100 gross · Cr 2010 gross · Dr 1110 Commission receivable · Cr 4000 Commission
income, and the insurer is paid in full.

**This differs from section 5.1 and 5.2**, which describe the net treatment (payable =
gross − commission, commission to 2020). Those sections remain in this pack because the
net basis is still a selectable position — `ins.insurer_remittance_basis` is a
legal-review-gated setting with both values — but **a company that has not chosen still
gets net**, which is the historic behaviour. Why the difference matters:

- Insurance Act s.90(3) requires premium to be remitted "without any deductions of
  commissions". Booking the payable net of commission is the opposite of that sentence.
- The owner has therefore ruled that gross is the intended basis, and that the system
  should **not** offer commission netting as a standard settlement method — no generic
  net-settlement switch exists to accommodate an insurer's statement.

**The one question left open for legal/accounting confirmation:** may a particular insurer
agreement create a lawful contractual set-off, and if so under what circumstances can it
operate without conflicting with s.90(3)? Until that is answered, netting is a
configuration a company must deliberately choose (and have compliance-reviewed), not a
default.

**Consequences you should check in the ledger map.** Gross settlement needs account 1110
Commission Receivable (posting role `commission_receivable`). It also means the client's
premium and the insurer's payable are the same amount, so the trust account holds the
whole premium until remitted, and commission income does not depend on remittance at all.

### 5.15 Cancelling an endorsement (E4, 19 November 2026)

> **Status: built and tested. The reversal arithmetic is the part to check.**

A posted endorsement can now be cancelled, which is what makes it possible to cancel a policy that
has one. Until this, a policy with any posted endorsement could not be cancelled at all -- the system
refused, because a return endorsement leaves a credit note on the premium item and the cancellation
engine will not run over one.

**The shape, and why.** Rather than teach the cancellation engine about endorsements, the endorsement
is unwound first as its own document (numbered `ENDC-0000-0000`), and only then does the ordinary
cancellation run, on a policy whose position is once again the position at bind. Nothing about the
cancellation engine changed.

**What the cancellation posts, for an endorsement that added premium.** Suppose an endorsement added
100,000 premium at 10% commission: at posting it debited the client receivable 100,000, credited the
insurer payable 90,000 and credited unearned commission 10,000. The cancellation does the opposite:

| | Debit | Credit |
|---|---|---|
| Client receivable | | 100,000 |
| Insurer payable | 90,000 | |
| Unearned commission | 10,000 | |
| Endorsement clearing | | 10,000 |

and a matching credit note against the clearing account debits clearing 10,000, leaving it at zero.
(In practice the client and insurer legs are written by those credit notes, and the journal carries
the commission leg; the net effect is the table above.)

**For an endorsement that returned premium**, its credit notes are voided -- restoring what the
premium item showed before -- and the clawback journal is mirrored line for line at the original
rates, so a foreign policy keeps its history rather than being re-priced.

**Three things to confirm:**

1. **Voiding a credit note is the right inverse of raising one.** It leaves both documents in the
   ledger, each dated, rather than deleting the refund. The client's statement shows the note and its
   void.
2. **The commission goes back to unearned (`2020`), not to income.** The endorsement's commission was
   credited to unearned when it posted and had not been earned, so un-earning it means debiting
   unearned. If your treatment of an endorsement's commission differs from the bind commission's,
   say so -- the software currently treats them identically.
3. **A cancellation is refused once the money has moved.** If any item the endorsement created has
   been settled, or a note belonging to something else credits it, or the commission has been
   transferred to the agent, the system refuses and names the movement to reverse first. It never
   nudges a settled position. That is deliberate, but it does mean an endorsement paid by the client
   and then disputed needs a settlement reversal before it can be cancelled -- worth confirming that
   is the procedure you want.

**Ordering.** Only the newest posted endorsement with a premium change can be cancelled, and the
sequence is newest-first. Reasons are in `ROADMAP.md` under "E4 delivered".

## 6. Reporting

- Broker fee tax report: `ins_broker_fee_tax_report` (a view). Broker-fee credit rows for cancellations are dated at posting.
- Insurer commission statements: `ins_insurer_commission_statement_data`, one per insurer.
- Agent commission: `ins_agent_commission_statement(intermediary, from, to)` gives one agent's account per currency, and the register's WHT position is `ins_wht_position()` (per currency). Both are also on screen, and the agent statement prints to PDF from the browser with no server round trip.
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
| Section 5.12 (agent commission: accrual, withholding character, returns) | | |
| **Section 5.13 (commission recognition: which insurers are placement / collection / settlement)** | | |
| **Section 5.14 (gross remittance and commission receivable; the s.90(3) set-off question)** | | |
| **Section 5.13b (statutory charges: the two unverified rates, and whether enforcement should be required)** | | |
| **Section 5.15 (cancelling an endorsement: void rather than delete, commission back to unearned, refusal once the money has moved)** | | |

Accountant name: ______________________ Date: ____________ Signature: ______________________

## 9. Changes since 16 October 2026 (for review, not approved)

Each item below is the software's current design and needs the accountant's confirmation. Details are in `ROADMAP.md` section 7 and the migrations named.

- **Foreign currency, completed** (`20261017170000` to `20261021200000`): realised gain or loss at settlement and on credit notes, period-end revaluation to the closing rate with unrealised gain or loss (`fin_revalue_fx`), foreign-currency bank reconciliation, rates held to 8 decimals, no UGX column defaults. Account codes 4900, 4901, 5910, 5911 and 5900 are template defaults for the accountant to confirm.
- **Endorsements** (`20261021220000`, `20261021230000`, `20261022100000`): additional premium bills the client and funds the insurer share; return premium raises a credit note capped at the original item's outstanding, with any excess raised as recovery items; commission clawbacks reduce the deferred pool first and the earned remainder reverses through commission income, recorded separately. Endorsement commission defaults to the original rate.
- **Claim excess and documents** (`20261106210000`): four excess handling modes stored on the claim; excess is never brokerage income. **Reserve revisions** (`20261022090000`) keep a history of every reserve.
- **Policy approval workflow** (`20261106180000` and repairs): binding requires an approved policy; segregation of duties applies to approval.
- **Insurer statement reconciliation** (`20261106220000`): insurer-reported premium, claims and commission compared line by line with the brokerage's records. Read-only; it adjusts nothing.
- **Agent commission** (`20261117240000` to `20261118180000`): accrual at recognition of the brokerage's commission, agent share as an expense (5010), withholding at payment from approved effective-dated parameters with the character change on 1 July 2026, maker-checker payment, per-period returns to URA on the payment-month basis, and per-currency statements. Section 5.12 describes the treatment; the basis for each agreement type and the expense-versus-netting question need the accountant's confirmation.
- **Commission recognition modes** (`20261117210000`, `20261119240000`): `at_placement` and
  `on_insurer_settlement` were joined by `on_premium_collection`, which earns the commission on the
  client's receipt that covers the premium, earns nothing on a part payment, and un-earns on a void.
  `over_policy_term` remains unimplemented and unselectable. Section 5.13.
- **Endorsement cancellation** (`20261120235910`): an endorsement is unwound as its own approved
  document (`ENDC-`) before a policy can be cancelled; its credit notes are voided, its items cleared
  through the endorsement clearing account, and the commission it booked returned to unearned.
  Section 5.15. Needs the accountant's confirmation of the three points listed there.
- **Gross remittance** (`20261117200000`): the insurer payable is booked for the whole premium with
  commission as a receivable (1110), per the owner's decision that commission is never netted off
  what an insurer is owed. Netting survives as a legal-review-gated configuration, not a default.
  Section 5.14.
- **In-force portfolio import** (`IN_FORCE_IMPORT.md`, section 3): earned commission up to cut-over is carried in opening balances and only the unearned remainder is deferred, under the existing event-based rule (Option A); full billed amount and receipts to date are migrated without re-posting cash; migrated policies keep accounting-policy version 1. Built (all five steps, `20261107140000` to `20261111100000`), not accountant-approved. New accounts and posting roles for review: account 3900 Opening Balance Clearing (equity, role `opening_balance_clearing`, template default, backfilled to existing insurance tenants by `20261109090000`) and a `retained_earnings` role that receives earned commission up to cut-over (account 3200 per `IN_FORCE_IMPORT.md` section 4).

## 10. Pointers for the reviewer

- Design draft and decision history: `ANALYSIS.md`.
- Reversal rules and accounting: `POLICY_REVERSAL.md`.
- Test evidence: `supabase/tests/test_ins_*.sql` (run in CI), including `test_ins_commission*.sql` and `test_ins_policy_reversal.sql`.
- Local UAT data: the Pearl Risk Brokers Ltd (UAT) tenant in `supabase/seed.sql` section 6 holds bound policies and a claim for walk-through. It is local only and uses fictional data.
