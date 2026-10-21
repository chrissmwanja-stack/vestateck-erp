# Currency review before A3 slice 3

Date: 18 Oct 2026. Scope: every place that posts or rebuilds journal lines, and every
currency guard, as they stand on `main` after slice 2c (`20261017140000`).

**Update 18 Oct 2026: F1 is closed by option B** (migration `20261017170000_procurement_posting_currency.sql`,
test `test_procurement_posting_currency.sql`). The three posting triggers now pass the document
currency to the gateway. The rest of this document is the review as written before that change.

**Update 19 Oct 2026: realised gain and loss** (migration `20261019100000_realised_fx.sql`,
test `test_realised_fx.sql`). The base-currency residue that a foreign invoice paid at a different
rate left on its control account is removed: payments and receipts now settle at the invoice's
original rate and the difference is booked as realised gain or loss. The settlement calculation and
the realised line are reusable by slices 3c and 3d.

**Update 20 Oct 2026: slice 3c is built.** Open items may be foreign at their booked rate
(`20261019120000_foreign_open_items.sql`) and settlements foreign at their settled rate
(`20261019130000_foreign_settlements.sql`, which failed a fresh replay and was repaired in place by
`20261020090000_fix_foreign_settlements.sql`). `OPEN_ITEM_CURRENCY` is gone; `SETTLEMENT_CURRENCY`
now means only that a settlement must be in its bank account's currency. What remains of this
review's plan: slice 3d (credit notes, bank accounts, transfers, policy bind and the insurance
posting functions -- the insurance currency guards stand until then) and 3e (period-end
revaluation), plus the column defaults that assume UGX and the 8-versus-10-decimal rate question.

**Update 21 Oct 2026: slice 3d-1 is built.** Credit notes may be foreign
(`20261021140000_foreign_credit_notes.sql`, `test_foreign_credit_notes.sql`). `fin_credit_notes` carries
`fx_rate` (the credit-date rate the offset line is booked at), `base_amount` and `realised_result`; the
guard no longer refuses a foreign note but requires the approved credit-date rate at 8 decimals (a
functional note stays at rate 1 with no result). `platform_fin_raise_credit_note_impl` takes the note's
currency from the items it applies to (they must agree), books one control line per booking entry at the
rate that entry used (each naming the entry as its rate source), the offset at the note-date rate, and the
difference as realised gain or loss; the receivable side signs like a receipt, the payable side mirrors a
payment. `platform_fin_raise_policy_credit_note_impl` gets the same treatment for the policy-reversal
exemption, and `platform_fin_void_credit_note_impl` now voids in reversal mode so a foreign note negates
exactly, realised line included. What remains of this review's plan: slice 3d-2 (transfers between bank
accounts, policy bind and the insurance posting functions) and 3e (period-end revaluation), plus the
column defaults that assume UGX and the 8-versus-10-decimal rate question. Note: slices 3c's foreign
open-item and settlement paths still have no dedicated test file in `supabase/tests/` -- their guards and
functions are exercised indirectly by the suite, but a test on the model of `test_foreign_credit_notes.sql`
would close that gap.

**Update 21 Oct 2026, later: slice 3d-2 is built.** Policies bind in a foreign currency
(`20261021160000_foreign_bind_and_transfer.sql`, `test_foreign_bind_transfer.sql`). `INS_CURRENCY_UNSUPPORTED`
is gone: the bind journal posts in the policy's currency at the approved inception-date rate, and the premium
and insurer items are created with the bind entry (so they hold the bound rate). Commission transfers now
require both accounts in the same currency (and the commission's policies in it), book the trust side at each
policy's bound rate (naming the bind entry as its rate source) and the operating side at the transfer-date
rate, with the difference as realised gain or loss; voiding a transfer reverses it exactly. The commission
recognition triggers carry the item's currency (recognition at the bound rate via the booking entry; the
reversal reverses the recognition journal in reversal mode), and claim recognition accrues in the policy's
currency with its own booking entry. The cancellation pipeline is deliberately left functional-currency
behind an explicit `INS_CANCELLATION_CURRENCY` guard (a trigger on `ins_policy_cancellations`) until slice
3d-3 converts it. What remains of this review's plan: 3d-3 (the cancellation pipeline), 3e (period-end
revaluation), and the UGX column defaults plus the 8-versus-10-decimal rate question. `test_ins_core.sql`
was updated: its USD-bind refusal now expects `FX_RATE_MISSING` without a rate and a successful bind at the
rate once one is approved.

**Update 21 Oct 2026, latest: slice 3d-3 is built.** The cancellation pipeline may run on a foreign policy
(`20261021170000_foreign_cancellation.sql`, `test_foreign_cancellation.sql`), and the
`INS_CANCELLATION_CURRENCY` guard from 3d-2 is gone. The credit note against an original premium or insurer
item takes the item's currency: the control side returns the item at its booked rate (naming the booking
entry), the clearing side takes the cancellation-date rate, and the difference books as realised gain or
loss. The Finance decision journal posts every adjustment leg in the policy's currency at the
cancellation-date rate, so the clearing account still nets to zero in the currency AND in base; the refund
and insurer-recovery items are now created with their booking entry, and the retained-commission
recognition posts at the rate the policy was bound at (the bind entry is its rate source). Known residue,
documented and deliberate: the unearned-commission account keeps a small base difference (clawback at the
cancellation rate against a bind at the bound rate) -- period-end revaluation (3e) is what clears residues
like that. What remains of this review's plan: 3e (period-end revaluation), then the UGX column defaults
and the 8-versus-10-decimal rate question. `test_foreign_bind_transfer.sql` section 8 was flipped: a
foreign proposal is now accepted rather than refused.

**Update 21 Oct 2026, latest: slice 3e is built -- period-end revaluation.**
(`20261021180000_period_end_revaluation.sql`, `test_fx_revaluation.sql`.) Finance can now run
`fin_revalue_fx(as_of)` (and void a run with `fin_void_fx_revaluation(run_id, reason)`). One run
revalues every foreign monetary balance to the approved closing rate of the run date: the control
accounts that still carry outstanding foreign open items (receivable, payable, insurer payable,
commission receivable, insurer claim receivable, client claim payable), the foreign bank GLs, and the
unearned-commission account per currency. The run posts one balanced functional-currency journal: each
account moves onto `currency balance x closing rate` and the offset books the unrealised result to the
new `fx_gain_unrealised` (credit, template account 4901) and `fx_loss_unrealised` (debit, 5911) posting
roles; payable-side items enter the revaluation signed so a payable strengthens as a loss, not a gain.
A run refuses a future date (`FX_REVAL_INPUT`), a same-day repeat while one is live (`FX_REVAL_EXISTS`),
and any run date missing an approved rate -- all-or-nothing, before anything is written
(`FX_RATE_MISSING`). A later run first reverses the previous live journal (`fx_revaluation_void`) and
then measures, so exactly one revaluation journal is ever live and only what still differs from the
closing rate is posted again. Open items keep their booked rate and base: revaluation never overwrites
history, the residue lives on the control GL and is cleared there. That closes the loop 3d left open:
the unearned base residue from cancellations and recognition now clears at the next period-end, and the
period-end books translate the residual exposure once, in one place. The engine refuses tenants whose
template lacks the unrealised accounts (`FX_UNREALISED_ACCOUNT_MISSING`); insurance companies created
before this slice are backfilled. Remaining on this review: the UGX column defaults (F3) and the
8-versus-10-decimal rate question (F4) before any non-UGX company is enabled.

**Update 21 Oct 2026, latest: A3 is complete -- foreign-currency bank reconciliation.**
(`20261021190000_foreign_bank_reconciliation.sql`, `test_foreign_bank_reconciliation.sql`.) Bank
reconciliation was the last functional-currency-only corner. The statement importer now pins every
line to the registered account's currency: an omitted currency defaults to the account's (not UGX)
and a wrong one is refused (`BANK_STMT_CURRENCY`); unregistered names keep the legacy free-text
behaviour so old imports do not break. The manual cash matcher refuses a line and a transaction in
different currencies (the settlement and transfer matchers already checked), and the candidate
search filters its cash/bank branch by currency, so auto-match can no longer cross-match a USD line
with a UGX amount. The reconciliation position reads a foreign account's GL in the account's own
currency -- the only legs that can reconcile to its statement -- and reports the functional
side-effects (the 3e revaluation legs and 3b realised-FX legs) separately as `fx_gl_movements`;
functional accounts see exactly the five components they saw before. A foreign settlement books its
bank leg at the settlement-date rate, so the statement reconciles the money at the rate it arrived
and the period-end run only revalues what the account still carries. What remains of this review:
the UGX column defaults (F3) and the 8-versus-10-decimal rate question (F4) before any non-UGX
company is enabled.

Method: all migrations replayed on a scratch Postgres 16; current function definitions
read from the catalog (so later redefinitions are respected, not the first migration
that mentions a function); findings marked **proved** were reproduced by a real insert
or call, the rest are **read** from the function text.

## 1. Result in one paragraph

Insurance flows are protected by six currency guards, so they cannot post a foreign
amount today. Three non-insurance posting triggers are not protected and do not look at
currency at all: supplier invoices, receivable invoices and cash/bank transactions.
Their tables have a `currency` column with no constraint, so a USD amount is booked to
the ledger as UGX at face value. That is live today and independent of the multi-currency
work. It should be closed before any insurance guard is removed, because removing
guards makes foreign amounts normal.

## 2. Findings

### F1. Procurement and cash postings ignore currency (high, live)

**Proved** for supplier invoices: a supplier invoice entered as USD 1,000 posted
expense UGX 1,000 and accounts payable UGX 1,000, both labelled UGX. The ledger is
understated by the exchange rate and the currency label is wrong.

**Read** for the other two: `trg_post_receivable_invoice` and
`trg_post_cash_bank_transaction` also never mention currency.

| Table | `currency` column | Posting trigger | Reads currency |
|---|---|---|---|
| `supplier_invoices` | yes, no check | `trg_post_supplier_invoice` | no |
| `receivable_invoices` | yes, default UGX, no check | `trg_post_receivable_invoice` | no |
| `cash_bank_transactions` | yes, default UGX, no check | `trg_post_cash_bank_transaction` | no |

None of these three flows creates an open item (open items are created only by the
insurance functions listed below), so they have no dependency on the open-item guard.

Other tables carry a `currency` column and were not traced to a posting:
`purchase_orders`, `advance_payments`, `expenditure_slips`, `petty_cash_floats`,
`request_line_items`, `bank_statement_lines`, `hr_employee_compensation`. Payroll
approval posting (`trg_post_payroll_run_approval`) has no currency column on the payroll
tables it reads, so whether a USD compensation can flow into a UGX payroll journal is
not established. `trg_post_machine_fuel` and `transition_maintenance_request` have no
currency column to read.

### F2. Insurance and finance flows are guarded (no action until slice 3)

Six current functions refuse a currency other than the ledger currency:

| Function | Refuses |
|---|---|
| `fin_open_items_guard` (trigger) | open item in another currency |
| `fin_settlements_guard` (trigger) | settlement in another currency |
| `fin_credit_notes_guard` (trigger) | credit note in another currency |
| `platform_fin_record_settlement_impl` | settlement against a bank account in another currency |
| `platform_ins_bind_policy_legacy_impl` | policy bind in another currency |
| `platform_ins_transfer_before_cancellation_impl` | transfer between bank accounts in another currency |

Functions that post journals and sit behind those guards (read, not exercised with a
foreign amount): `ins_commission_on_settlement_posted`, `ins_commission_on_settlement_voided`,
`ins_decide_policy_cancellation`, `ins_recognise_claim_receivable`, `ins_void_commission_transfer`,
`platform_fin_raise_credit_note_impl`, `platform_fin_raise_policy_credit_note_impl`,
`platform_fin_record_settlement_impl`, `platform_fin_void_credit_note_impl`,
`platform_fin_void_settlement_impl`, `platform_ins_bind_policy_legacy_impl`,
`platform_ins_bind_policy_risk_legacy_impl`, `platform_ins_cancellation_cash_emit`,
`platform_ins_cancellation_cash_recognize`, `platform_ins_cancellation_credit`,
`platform_ins_transfer_before_cancellation_impl`.

None of them passes a currency to the gateway. Each needs the same change as the
guards: carry the document currency into the journal lines, and book realised gain or
loss where a settlement meets a rate different from the original.

### F3. Column defaults assume UGX

`journal_entry_lines.currency`, `fin_bank_accounts.currency`, `fin_open_items.currency`
and `ins_policies.currency` default to `'UGX'`. The functional-currency setter is not
enabled for clients, so this is harmless today. It must be resolved before any company
other than a UGX one is switched, otherwise a default `'UGX'` label looks like a foreign
currency to a USD company.

### F4. Already recorded in the roadmap

A line stores its rate to 8 decimals while `fx_rates` holds 10, and a line does not
record which rate row it used.

## 3. Decision needed from you: how to close F1

Option A, refuse. Add a check on the three tables that rejects a currency other than the
company's functional currency. Simple and safe, but it blocks any USD invoice that
users can enter today.

Option B, post correctly. Make the three triggers pass the document currency to the
gateway. UGX behaviour is identical. A foreign document posts in its currency at the
approved rate, or is refused loudly with `FX_RATE_MISSING` / `REG_PARAM_MISSING` when no
approved rate or age limit exists. Because no open item is involved, no other guard
blocks it. This is the better end state, but it turns on foreign accounting for
procurement, so the procurement owner should know first. Until realised gain and loss
existed (slice 3b, 19 Oct) a foreign invoice paid at a different rate left a base-currency
residue on the control account.

My recommendation: B, preceded by the production query below. If production holds foreign
rows already, they are currently misstated and need a decision from the accountant
before B goes live, because B changes how new rows post but does not repair old ones.

Production query (read-only):

```sql
select 'supplier_invoices' as source, coalesce(currency, 'UGX') as currency, count(*) as rows
from supplier_invoices where coalesce(currency, 'UGX') <> 'UGX' group by 2
union all
select 'receivable_invoices', coalesce(currency, 'UGX'), count(*)
from receivable_invoices where coalesce(currency, 'UGX') <> 'UGX' group by 2
union all
select 'cash_bank_transactions', coalesce(currency, 'UGX'), count(*)
from cash_bank_transactions where coalesce(currency, 'UGX') <> 'UGX' group by 2
union all
select 'purchase_orders', coalesce(currency, 'UGX'), count(*)
from purchase_orders where coalesce(currency, 'UGX') <> 'UGX' group by 2;
```

No rows means nothing has been misposted yet. The local seed data holds no non-UGX rows
in these tables.

## 4. Proposed order for slice 3

1. **3a, close F1** (option A or B above), with a test per trigger.
2. **3b, realised gain and loss:** posting roles for realised gain and loss, and the
   settlement calculation. Needed before any settlement guard can come off.
3. **3c, open items and settlements:** base amount and rate on open items and
   settlements; remove the open-item and settlement guards, one at a time, each with a test.
4. **3d, credit notes, bank accounts, transfers, policy bind:** remaining guards, one at a
   time, each with a test; make the insurance posting functions in F2 pass currency.
5. **3e, period-end revaluation:** unrealised gain and loss roles and the revaluation run.
6. Resolve F3 and the 8-versus-10-decimal point before any non-UGX company is enabled.

Each step ships with existing UGX companies behaving exactly as before, checked by the
existing suite.