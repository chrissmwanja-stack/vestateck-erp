# Finance E1 — procurement wired into the open-item subledger

**Migration:** `supabase/migrations/20261117150000_fin_procurement_open_item_subledger.sql`
**Tests:** `supabase/tests/test_fin_procurement_open_item.sql` (new, 8/8) and
`supabase/tests/test_fin_end_to_end_trace.sql` (tripwire inverted, 6/6)

This closes finding E1 from item E. It is the deliberate exception to "don't touch money flow
without a decision": you chose option 1, so procurement now lives in the subledger.

---

## The defect being closed

Two payment mechanisms, never joined:

- Procurement paid with `cash_bank_transactions` (`reference_type='supplier_invoice'`). The
  posting trigger wrote Dr AP / Cr Bank and never created a `fin_open_items` row.
- The open-item subledger (`fin_open_items` → `fin_settlements` → `fin_allocations`) was used by
  insurance and the Finance settlement screens, and posted **its own** journal per settlement.

Two consequences. No procurement document could produce an open-item or settlement hop; and any
payment booked both ways was **journaled twice**, double-debiting AP control.

## The design, and why it is this one

**Exactly one mechanism posts the GL; exactly one mechanism owns the open-item balance.**

| Concern | Owner |
|---|---|
| GL entry for a procurement payment | `trg_post_cash_bank_transaction` (unchanged) |
| Open-item balance | `fin_settlements` + `fin_allocations` (new) |
| The join between them | `fin_settlements.funding_transaction_id` |

So a procurement payment creates a settlement that carries **no journal of its own**
(`subledger_only = true`, `journal_entry_id` null, `funding_transaction_id` set). Nothing is
posted twice, and the money leg is still traceable in both directions. `bank_reconciliations`
already carried both `cash_bank_transaction_id` and `settlement_id`, so the reconciliation view
needed no schema change — the pairing was always intended.

### What was deliberately *not* done

**Payments are not rerouted through `fin_record_settlement`.** That RPC takes a
`fin_bank_accounts.id`, but `cash_bank_transactions.bank_account` is a **free-text field** (the
screen at `CashBankOperations.tsx` renders a plain text input) with no FK. There is no reliable
bank identity to pass. Rerouting would mean either inventing a mapping or changing every existing
payment screen, and would break the payment path if the name did not resolve. Instead the wiring
rides on the existing payment insert, and resolves the bank name tolerantly (trimmed,
case-insensitive, against `name` or `account_number`).

**No backfill.** Same reasoning as item D: a backfilled item would have to invent an outstanding
balance for money that may already have been paid, and historical payments cannot be paired to
historical invoices reliably after the fact. The gap report makes the omission visible instead of
guessing.

## Amounts and currency

The open item's amount is the **AP credit actually posted**, `amount_incl_vat - wht_amount`.
Withholding tax is not owed to the supplier, so it is not on the supplier's open item — and
including it would make the subledger disagree with AP control on every WHT invoice. Both facts
are asserted in the test (`INV-SUB-WHT`: item 940, AP credit 940).

Currency and rate come from the invoice's own journal line, via
`fin_create_open_item_fx(..., p_journal_entry_id => the invoice's entry)`, so a foreign-currency
item settles at the rate it was **booked** at rather than today's rate.

The payment's allocation amount is read back out of the payment's own journal (the functional
amount that actually hit AP), so a foreign payment allocates exactly what was relieved — no
rounding drift, no second rate lookup.

## Two behaviours worth knowing

**An unresolvable bank name does not corrupt anything.** The GL posts, the item stays open, and
`fin_trace_gaps()` reports `payment is not allocated to its open item`. Verified: with a bank name
matching no `fin_bank_accounts` row, the journal posted (1), no settlement was created, and the
gap was reported. The alternative — allocating against a guessed account — would be worse.

**An invoice with no `vendor_account_id` stays GL-only.** The column is nullable, though both
supplier invoice screens require it; `fin_allocations_guard` needs item party = settlement party,
so such an invoice cannot be settled. It is reported as
`posted but has no supplier account, so it has no open item`.

## Schema changes

| Change | Reason |
|---|---|
| `fin_settlements.subledger_only boolean not null default false` | marks a settlement whose GL entry belongs to a funding transaction |
| `fin_settlements.funding_transaction_id uuid` → `cash_bank_transactions` | names that transaction |
| unique index on `fin_open_items (tenant_id, source_type, source_id)` for invoice types | one item per document; a retried trigger cannot double the subledger |

The funding link sits on the **settlement**, not on `fin_open_items`, because open items are
strictly immutable (`fin_open_items_guard` rejects every UPDATE) — and rightly so.

**No CHECK constraint on the shape**, deliberately. `fin_record_settlement` inserts a settlement
posted with `journal_entry_id` null and attaches the journal on the next statement, so a
table-level check would reject the normal flow. The state machine lives in
`fin_settlements_guard()`, which sees both the insert and the later update: a subledger-only
settlement must name its funding transaction, must not carry a journal, can never acquire one,
and cannot be flipped after the fact.

## Bugs found on the way

The open-item hop in `fin_trace` read `fin_open_item_balances.amount_open` — **a column that does
not exist**. It never fired because no procurement document ever had an open item, which is
finding E1 itself. Fixed to use `settlement_status` / `outstanding_amount`.

## Verification

| Check | Result |
|---|---|
| Clean replay, baseline + all **61** migrations | ✔ succeeds |
| `test_procurement_open_item.sql` | **8/8 PASS** |
| `test_fin_end_to_end_trace.sql` (tripwire inverted) | **6/6 PASS** |
| Full SQL suite, **fresh** database | **121/122** — only `test_bind_config_snapshot` fails, pre-existing |
| Same suite on the pre-E1 baseline (119 files) | 116/119 — same single failure, so **zero regressions** |
| `BankReconciliation.test.tsx` | **13/13** (one new test: a procurement settlement is badged "From procurement") |
| Full `vitest` | **1,539 pass / 11 expected-fail**, 3 known env-only files |
| `tsc` on changed files | 0 errors |
| `lint:ratchet` | green — 0 new `any`, dialogs, swallowed errors or hook deps |
| `check_live_security_drift.sql` | PASS |

The earlier "5 pre-existing failures" were **accumulated state** in a long-lived database, not
real defects: on a fresh replay the HR tests pass. Worth remembering when reading old numbers.

`packages/shared/src/database.types.ts` gained the two settlement columns and the
`funding_transaction_id` relationship by hand, since `gen-types` needs a live project.

## Front-end

`apps/web/src/features/financial/bank-reconciliation/` — the book now selects
`subledger_only`/`funding_transaction_id` and badges such a row **"From procurement"** with the
tooltip *"Allocation only — the bank transaction posted the GL entry"*. Without this the
reconciliation screen would show a settlement that appears to have no journal, which is exactly
the ambiguity this work exists to remove.

## Still open (not this migration's scope)

- **Overpayment.** A payment exceeding the item is not allocated (the item is left open and the
  gap is reported); the GL still relieves AP. Supplier invoice screens cap the amount up front,
  and supplier credit notes exist for the rest, but a payment initiated outside the UI can still
  produce the divergence. Reported, not silently absorbed.
- **Payment void/reversal.** There is no void path for `cash_bank_transactions` at all, so there
  was nothing to keep in sync. When one is added, it must void the settlement and its allocation.
- `trg_settle_supplier_invoice_open_item` resolves the bank by name. If two operating accounts
  share a name, the older one wins; a real FK on `cash_bank_transactions.bank_account_id` would
  retire this heuristic, and is the clean follow-up.

## Next

Item **B** — `fin_transaction_actors` (initiator / approver / poster / reverser per journal
entry), triggers on the gateway and approval RPCs, then one audit screen that reuses `fin_trace`
for the document spine.
