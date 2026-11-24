# Account Mapping Appendix (insurance template)

**Companion to** `ACCOUNTANT_PACK.md`. Every accounting-policy paragraph in the pack is mapped
here to its posting role, its chart-of-accounts code, its debit/credit treatment and the
migration that wires it.

**Source of truth.** Every code in the chart table below was read from the live insurance
template (`industry_template_items`, `kind='gl_account'` and `kind='posting_rule'`, template
`insurance`) on 23 November 2026 — 32 template items, 29 of which carry a posting rule. No
account code in this appendix was written from memory or inferred from prose. If a code here
disagrees with the database, the database is right and this file is a bug.

**How the template works.** A template row pairs an account (kind `gl_account`: name and type)
with a posting rule (kind `posting_rule`: the account code that role resolves to). Both are
matched on `sort_order`. A tenant's chart is created from this template at company creation by
`apply_template`, so a code that is wrong here is wrong for every new insurance company.

---

## 1. The insurance chart of accounts

| Code | Account | Type | Posting role | Used for |
|---|---|---|---|---|
| 1000 | Operating Bank | asset | `bank` | Brokerage's own money |
| 1010 | Cash | asset | `cash` | Petty/office cash |
| 1020 | Client Money Bank (Premium Trust) | asset | `client_money_bank` | Client money; premium held for insurers and clients |
| 1100 | Accounts Receivable Control | asset | `ar_control` | Gross premium receivable from the client at bind |
| 1110 | Commission Receivable | asset | `commission_receivable` | Commission owed by the insurer (gross settlement) |
| 1120 | Claims Receivable from Insurers | asset | `insurer_claim_receivable` | Brokerage-managed claims funded by the insurer |
| 1200 | VAT Input | asset | `vat_input` | Input tax on taxable purchases |
| 1210 | WHT Receivable | asset | `wht_receivable` | Tax withheld from us — an asset, never reduced revenue |
| 2000 | Accounts Payable Control | liability | `ap_control` | Suppliers (non-insurer) |
| 2010 | Insurer Payable (Premiums) | liability | `insurer_payable` | Premium owed to the insurer — **gross** under the decided basis |
| 2020 | Unearned Commission | liability | `unearned_commission` | Commission held back until the earning event |
| 2030 | Claims Payable to Clients | liability | `client_claim_payable` | Claim money held for the claimant |
| 2100 | VAT Output | liability | `vat_output` | Output tax on taxable supplies |
| 2200 | WHT Payable | liability | `wht_payable` | Tax we withhold and owe onward |
| 2300 | Salaries Payable | liability | `salaries_payable` | Net pay owed to staff |
| 2310 | PAYE Payable | liability | `paye_payable` | PAYE due to URA |
| 2320 | NSSF Payable | liability | `nssf_payable` | NSSF contributions due |
| 2060 | Insurance Training Levy Payable | liability | `insurance_training_levy_payable` | ITL collected on policies, held for remittance |
| 2070 | IRA Levy Payable | liability | `ira_levy_payable` | IRA levy — **inactive until the rate is verified** |
| 2080 | Stamp Duty Payable | liability | `stamp_duty_payable` | Stamp duty — **inactive until the rate is verified** |
| 3200 | Retained Earnings | equity | `retained_earnings` | Earned commission carried into opening balances |
| 3900 | Opening Balance Clearing | equity | `opening_balance_clearing` | Migration balancing account; must net to zero |
| 4000 | Commission Income | revenue | `commission_income` | Commission when earned |
| 4100 | Brokerage Fees & Other Income | revenue | `default_revenue` | Brokerage fees; VAT-exempt by default |
| 4900 | Realised FX Gain | revenue | `fx_gain_realised` | Realised gain at settlement |
| 4901 | Unrealised FX Gain | revenue | `fx_gain_unrealised` | Period-end revaluation gain |
| 5000 | General Expense | expense | `default_expense` | Operating expenses |
| 5010 | Agent Commission | expense | `agent_commission_expense` | Agent's share — an expense, never a netting of our commission |
| 5100 | Salaries Expense | expense | `salaries_expense` | Payroll cost |
| 5900 | Foreign Exchange Rounding | expense | `fx_rounding` | Rounding difference |
| 5910 | Realised FX Loss | expense | `fx_loss_realised` | Realised loss at settlement |
| 5911 | Unrealised FX Loss | expense | `fx_loss_unrealised` | Period-end revaluation loss |

Three template accounts (Operating Bank, Cash, Client Money Bank) are flagged
`is_control_account: true`, as are the three statutory payable accounts 2060–2080.

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
**2040 Unallocated Client Advances** — added by
`20261124010300_ins_client_advances_2040.sql` as a liability control account, posting role
`client_advance_payable`. It was a *proposal* in the first issue of this appendix and is now
created, for existing insurance tenants and in the template for new ones. The migration refuses
to finish if any insurance tenant cannot be mapped rather than choosing an account for it, and
it leaves an existing 2040 of a different account type alone.

<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
=======
>>>>>>> theirs
Line 3 below (allocating the advance to the policy) is **not yet implementable**: the subledger
has no cross-control-account reclass source. The debit/credit is correct as accounting, but the
mechanism does not exist, so this appendix states what the posting must be while B11 records that
it cannot yet be made. See B11 in the register.
<<<<<<< ours
=======
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
Line 3 below (allocating the advance to the policy) is now implementable. It was not, until B11:
the subledger could move a party balance only by cash (a settlement) or a same-role credit note,
and this is neither. B11 added a third source, `fin_open_item_dispositions`, for a non-cash
movement between two party balances, and `fin_open_item_consumed()` counts it alongside the other
two, so every existing balance and guard sees the reduced figure without being changed. The
posting is Dr 2040 / Cr 1100 with the bank untouched, forced by double entry rather than chosen by
the caller.
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
>>>>>>> theirs
=======
**Not in the chart today.** There is no account for **unallocated client advances** — the
liability B2/A1 require. The pack proposes **2040 Unallocated Client Advances** (liability,
posting role `client_advance_payable`). That code is a *proposal pending the accountant's
confirmation*, not an existing code, and it is marked as such wherever it appears.
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs

---

## 2. Policy paragraph → posting role → debit/credit

Debits left, credits right. Amounts in the transaction currency unless FX is noted.

### 2.1 A1 — Premium at bind, and pre-binding receipts (pack §3)

| # | Event | Debit | Credit |
|---|---|---|---|
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
=======
>>>>>>> theirs
=======
>>>>>>> theirs
| 1 | Receipt with no policy yet **— built** | 1020 Client Money Bank | **2040** Unallocated Client Advances |
| 2 | Policy binds (gross basis) | 1100 AR Control — gross | 2010 Insurer Payable — gross |
| 2b | …and commission, if earned at bind | 1110 Commission Receivable | 4000 Commission Income |
| 2c | …or if deferred | 1110 Commission Receivable | 2020 Unearned Commission |
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
| 3 | Allocate the advance to the policy **— not built (B11)** | **2040** Unallocated Client Advances | 1100 AR Control |
=======
| 3 | Allocate the advance to the policy **— built (B11)** | **2040** Unallocated Client Advances | 1100 AR Control |
>>>>>>> theirs
=======
| 1 | Receipt with no policy yet | 1020 Client Money Bank | **2040** Unallocated Client Advances *(proposed)* |
| 2 | Policy binds (gross basis) | 1100 AR Control — gross | 2010 Insurer Payable — gross |
| 2b | …and commission, if earned at bind | 1110 Commission Receivable | 4000 Commission Income |
| 2c | …or if deferred | 1110 Commission Receivable | 2020 Unearned Commission |
| 3 | Allocate the advance to the policy | **2040** Unallocated Client Advances | 1100 AR Control |
>>>>>>> theirs
=======
| 1 | Receipt with no policy yet **— built** | 1020 Client Money Bank | **2040** Unallocated Client Advances |
| 2 | Policy binds (gross basis) | 1100 AR Control — gross | 2010 Insurer Payable — gross |
| 2b | …and commission, if earned at bind | 1110 Commission Receivable | 4000 Commission Income |
| 2c | …or if deferred | 1110 Commission Receivable | 2020 Unearned Commission |
| 3 | Allocate the advance to the policy **— not built (B11)** | **2040** Unallocated Client Advances | 1100 AR Control |
>>>>>>> theirs
=======
| 3 | Allocate the advance to the policy **— built (B11)** | **2040** Unallocated Client Advances | 1100 AR Control |
>>>>>>> theirs
=======
| 3 | Allocate the advance to the policy **— built (B11)** | **2040** Unallocated Client Advances | 1100 AR Control |
>>>>>>> theirs
=======
| 3 | Allocate the advance to the policy **— built (B11)** | **2040** Unallocated Client Advances | 1100 AR Control |
>>>>>>> theirs
| 4 | Client pays after bind | 1020 Client Money Bank | 1100 AR Control |
| 5 | Remit premium to the insurer (gross) | 2010 Insurer Payable | 1020 Client Money Bank |

*Roles:* `client_money_bank`, `ar_control`, `insurer_payable`, `commission_receivable`,
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
`commission_income`, `unearned_commission`, `client_advance_payable`.

Line 1 is built and posts Dr 1020 / Cr 2040 with no receivable, which is what stops AR being
<<<<<<< ours
=======
`commission_income`, `unearned_commission`, `client_advance_payable`.

Line 1 is built and posts Dr 1020 / Cr 2040 with no receivable, which is what stops AR being
<<<<<<< ours
>>>>>>> theirs
overstated by money taken before placement. Line 3 is **not built**: a party balance can only fall
by cash (a settlement) or a same-role credit note, and this is neither, so 2040 cannot yet be
cleared against a policy. The reclass needs a third subledger source; B11 sets out the options and
why the obvious ones fail. Until then an advance is refundable but not applicable.
<<<<<<< ours
=======
=======
>>>>>>> theirs
=======
`commission_income`, `unearned_commission`, `client_advance_payable`.

Line 1 is built and posts Dr 1020 / Cr 2040 with no receivable, which is what stops AR being
>>>>>>> theirs
=======
`commission_income`, `unearned_commission`, `client_advance_payable`.

Line 1 is built and posts Dr 1020 / Cr 2040 with no receivable, which is what stops AR being
>>>>>>> theirs
overstated by money taken before placement. Line 3 is built as of B11 and posts Dr 2040 / Cr 1100
with the bank untouched, so an advance is now refundable *and* applicable. Four routes were
considered for it and three were rejected: releasing it by credit note moves 2040 against AR in
the wrong direction, a bare reclass journal has no subledger row so the party balance would not
move, and running it as a settlement would invent cash that never arrived. A disposition is a
movement of a party balance that is neither cash nor a credit note, which is exactly what line 3
is.
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
>>>>>>> theirs
=======
`commission_income`, `unearned_commission`. Line 1 and 3 need the proposed `client_advance_payable`.
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs

### 2.2 A3/A4 — Commission recognition, four modes (pack §4.3)

| Mode | At bind | On the earning event |
|---|---|---|
| `at_placement` | Dr 1110 · Cr 4000 | — |
| `on_premium_collection` (binary) | Dr 1110 · Cr 2020 | On the receipt that covers the premium: Dr 2020 · Cr 4000 |
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
| `pro_rata_on_collection` **(not built — B1)** | Dr 1110 · Cr 2020 | On each receipt: Dr 2020 · Cr 4000 for the proportion collected |
=======
| `pro_rata_on_collection` **(built — B1)** | Dr 1110 · Cr 2020 | On each receipt: Dr 2020 · Cr 4000 for the proportion collected |
>>>>>>> theirs
=======
| `pro_rata_on_collection` **(not built — B1)** | Dr 1110 · Cr 2020 | On each receipt: Dr 2020 · Cr 4000 for the proportion collected |
>>>>>>> theirs
=======
| `pro_rata_on_collection` **(built — B1)** | Dr 1110 · Cr 2020 | On each receipt: Dr 2020 · Cr 4000 for the proportion collected |
>>>>>>> theirs
=======
| `pro_rata_on_collection` **(built — B1)** | Dr 1110 · Cr 2020 | On each receipt: Dr 2020 · Cr 4000 for the proportion collected |
>>>>>>> theirs
=======
| `pro_rata_on_collection` **(built — B1)** | Dr 1110 · Cr 2020 | On each receipt: Dr 2020 · Cr 4000 for the proportion collected |
>>>>>>> theirs
| `on_insurer_settlement` | Dr 1110 · Cr 2020 | When the insurer's item is settled: Dr 2020 · Cr 4000 |

Voiding a receipt reverses the recognition through 2020 at the **same booked rate** — income is
never carried on money that came back.

### 2.3 A2 — Insurer settlement basis (pack §4.1–4.2)

| Basis | Bind | Settlement |
|---|---|---|
| `gross_premium` (decided) | Dr 1100 gross · Cr 2010 gross · Dr 1110 commission · Cr 4000/2020 | Insurer paid the full premium; commission collected separately against 1110 |
| `net_of_commission` (controlled exception) | Dr 1100 gross · Cr 2010 **net** · Cr 4000/2020 | Insurer remits net; 2010 clears in full |

The gross premium and the commission are preserved as separate records under both bases. Netting
never erases the gross contractual position.

### 2.4 A5 — Co-insurance (pack §6)

No separate accounts: each participating insurer's share posts to its own 2010/1110 subledger
item, in proportion to `share_pct`, with exactly one lead insurer and shares totalling 100%.
Cancellation and clawback follow the same shares.

### 2.5 A6/A18 — Cancellation, return premium, clawback (pack §5)

| # | Event | Debit | Credit |
|---|---|---|---|
| 1 | Return premium approved by the insurer | 2010 Insurer Payable | 1100 AR Control (credit note, capped at the item's outstanding) |
| 2 | Refund paid to the client | 1100 AR Control | 1020 Client Money Bank |
| 3 | Insurer retains short-period premium | 2010 Insurer Payable | *(stays with the insurer — not income)* |
| 4 | Brokerage cancellation fee, if contractually authorised | 1100 AR Control | 4100 Brokerage Fees |
| 5 | Commission clawback — deferred pool first | 2020 Unearned Commission | 1110 Commission Receivable |
| 6 | …then recognised income | 4000 Commission Income | 1110 Commission Receivable |
| 7 | …then recoverable from operating funds | 1100 AR Control *(recoverable)* | 1110 Commission Receivable |
| 8 | Replenish client money where it fell short | 1020 Client Money Bank | 1000 Operating Bank |

Clawback is proportional to the **approved** return premium and may never exceed commission
previously recognised. The difference between original and return premium is never automatically
brokerage income — line 3 is the test of that.

### 2.6 A7 — Claims (pack §7)

| Model / event | Debit | Credit |
|---|---|---|
| Insurer-direct: any stage | *no journal* | *no journal* — administration only, no brokerage cash |
| Brokerage-managed: insurer confirmed | 1120 Claims Receivable from Insurers | 2030 Claims Payable to Clients |
| Brokerage-managed: funds received | 1020 Client Money Bank | 1120 Claims Receivable |
| Brokerage-managed: paid to claimant | 2030 Claims Payable to Clients | 1020 Client Money Bank |
| Internal approval only | *no journal* — approval is not recognition | — |

### 2.7 A13 — Statutory charges (pack §12)

| Event | Debit | Credit |
|---|---|---|
| Charge applied on the policy | 1100 AR Control | 2060 / 2070 / 2080 (by charge class) |
| Charge remitted to the recipient | 2060 / 2070 / 2080 | 1020 Client Money Bank |

One payable role per charge, never a single bucket: a report must distinguish a levy held for the
College from a tax collected for URA. Only 2060 carries a verified rate today.

### 2.8 A14/A20 — Broker fees and withholding (pack §12.1–12.2, §13)

| Event | Debit | Credit |
|---|---|---|
| Brokerage fee invoiced (exempt) | 1100 AR Control | 4100 Brokerage Fees |
| Brokerage fee invoiced (other taxable service) | 1100 AR Control | 4100 + 2100 VAT Output |
| Fee received | 1020 Client Money Bank | 1100 AR Control |
| Client withholds tax from a fee | 1210 WHT Receivable | 1100 AR Control |
| Agent commission accrued | 5010 Agent Commission | 2200 / agent payable |
| Agent commission paid, WHT withheld | 2200 / agent payable | 1210/2200 WHT Payable + 1000 Operating Bank |

Withheld tax is an asset (1210), never a reduction of revenue and never a liability of the
brokerage.

### 2.9 A8 — Foreign currency (pack §8)

| Event | Debit | Credit |
|---|---|---|
| Realised gain at settlement | 2010 / 1020 | 4900 Realised FX Gain |
| Realised loss at settlement | 5910 Realised FX Loss | 2010 / 1020 |
| Unrealised gain at revaluation | 1100 / 2010 | 4901 Unrealised FX Gain |
| Unrealised loss at revaluation | 5911 Unrealised FX Loss | 1100 / 2010 |
| Rounding difference | 5900 FX Rounding | *balancing* |

The binding rate is preserved and is not replaced by a later market rate except through an
authorised amendment or reversal.

### 2.10 A19 — Migration and opening position (pack §9)

| Event | Debit | Credit |
|---|---|---|
| Opening receivables | 1100 AR Control | 3900 Opening Balance Clearing |
| Opening insurer payables | 3900 Opening Balance Clearing | 2010 Insurer Payable |
| Commission earned up to cut-over | 3900 Opening Balance Clearing | 3200 Retained Earnings |
| Commission unearned at cut-over | 3900 Opening Balance Clearing | 2020 Unearned Commission |
| Opening client money | 1020 Client Money Bank | 3900 Opening Balance Clearing |

3900 must net to zero across the opening position before the position is accepted. A correction
after posting requires an explicit reopen with a recorded reason.

### 2.11 A12 — Client money (pack §14)

Segregation is enforced in the schema, not by convention: a bank account cannot change between
operating and client money, and two bank accounts cannot share a GL account. Transfers of earned
commission move money 1020 → 1000 and are reversible, each side matched in bank reconciliation.

---

## 3. What the accountant is asked to confirm here

1. **Account 2040** (unallocated client advances) — the code, the name, and that a pre-bind
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
   receipt is a liability rather than unearned income. Created on 24 Nov 2026; the treatment still
<<<<<<< ours
   needs sign-off, and the release mechanism that line 3 needs is B11.
=======
   needs sign-off. The release mechanism line 3 needed is built (B11), so the only open point here
   is whether 2040 is the account the accountant wants it on and whether an unapplied advance is
   eventually released or forfeited (Appendix B, Q2).
>>>>>>> theirs
=======
   receipt is a liability rather than unearned income. *This code does not exist yet.*
>>>>>>> theirs
=======
   receipt is a liability rather than unearned income. Created on 24 Nov 2026; the treatment still
<<<<<<< ours
   needs sign-off, and the release mechanism that line 3 needs is B11.
>>>>>>> theirs
=======
   needs sign-off. The release mechanism line 3 needed is built (B11), so the only open point here
   is whether 2040 is the account the accountant wants it on and whether an unapplied advance is
   eventually released or forfeited (Appendix B, Q2).
>>>>>>> theirs
=======
=======
>>>>>>> theirs
   receipt is a liability rather than unearned income. Created on 24 Nov 2026; the treatment still
   needs sign-off. The release mechanism line 3 needed is built (B11), so the only open point here
   is whether 2040 is the account the accountant wants it on and whether an unapplied advance is
   eventually released or forfeited (Appendix B, Q2).
<<<<<<< ours
>>>>>>> theirs
=======
>>>>>>> theirs
2. **The three statutory payables** 2060/2070/2080 — that separating them by recipient (rather
   than one "statutory payable") is what the brokerage's reporting must show.
3. **4100 for brokerage fees** and that `default_revenue` is the right role for it, given the
   VAT-exempt default.
4. **5010 for agent commission** — an expense rather than a deduction from 4000, and the
   consequence that gross commission and agent cost are both visible.
5. **3900/3200 in the opening position** — that earned-at-cut-over goes to retained earnings and
   only the unearned remainder to 2020.
6. **The FX account split** (4900/4901 gains, 5910/5911 losses, 5900 rounding) — realised and
   unrealised kept apart.

Each answer should be recorded against the matching A-ref in `signoff-register.json`.
