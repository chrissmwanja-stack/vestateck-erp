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