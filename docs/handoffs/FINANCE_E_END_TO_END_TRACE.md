# Finance item E — done (end-to-end trace), plus finding E1

**Migration:** `supabase/migrations/20261117140000_fin_end_to_end_trace.sql`
**Test:** `supabase/tests/test_fin_end_to_end_trace.sql`

---

## What it adds

`fin_trace(entity_type, entity_id)` returns one row per hop of a document's financial life:

```
document → purchase order (when present) → journal entries (incl. reversals)
        → cash/bank payments → open items → settlements → bank match
        → accounting period state
```

Supported today: `supplier_invoice`, `receivable_invoice`, `fin_settlement`,
`cash_bank_transaction`, `ins_policy`. Read-only, **`security invoker`** (RLS applies to the
caller, so it cannot leak across tenants), finance-only via RLS, and it refuses unknown types
with a clear message.

`fin_trace_gaps(tenant)` is the companion report — documents whose money flow is not fully
accounted for:

- a supplier invoice with **no journal** (posting skipped because posting rules were incomplete
  — a real code path: `trg_post_supplier_invoice` returns early when a required role is unmapped)
- a bank payment **not matched** to a statement line
- a payment **matched with a variance**
- a posting dated **inside a closed period** (should be impossible — any row means the guard
  was bypassed)

## Finding E1 — the two payment mechanisms do not meet (CLOSED)

This was the substantive discovery: your example ("one procurement payment traceable through the
procurement transaction, supplier open item, settlement, bank reconciliation and GL") could not
be fully satisfied, because the two money mechanisms never met.

| Path | What it did |
|---|---|
| **Procurement**: `cash_bank_transactions` with `reference_type='supplier_invoice'` | `trg_post_cash_bank_transaction` posted Dr AP / Cr Bank (plus realised FX). **No `fin_open_items` row was created.** |
| **Open-item subledger**: `fin_open_items` → `fin_settlements` → `fin_allocations` | Used by insurance and the Finance settlements screens. Posted its own journal per settlement. |

So procurement had no open item and no settlement hop, and booking a payment as a settlement
journaled the same event **twice**.

### Decision: option 1 — wire procurement into the subledger

Built in `supabase/migrations/20261117150000_fin_procurement_open_item_subledger.sql`; see
`docs/handoffs/FINANCE_E1_PROCUREMENT_SUBLEDGER.md` for the full design. In short:

- `trg_post_supplier_invoice` now raises the AP open item (amount = the AP credit actually
  posted, i.e. net of withholding tax; currency and rate taken from the invoice's own journal).
- A supplier payment settles that item **without a second journal**: the settlement is created
  `subledger_only` with `funding_transaction_id` pointing at the payment. The payment's journal
  remains the only GL entry for the money.
- `fin_trace` now returns `open_item` and `settlement` hops for procurement, and
  `fin_trace_gaps()` gained two gap classes (posted invoice with no open item, payment not
  allocated).

`test_fin_end_to_end_trace.sql` asserted the *absence* of those hops as a deliberate tripwire.
That assertion is now **inverted** — it asserts presence — so a regression in the wiring fails
the test, exactly as the tripwire intended.

## Verification

| Check | Result |
|---|---|
| Clean replay — baseline + all **60** migrations | ✔ succeeds |
| `test_fin_end_to_end_trace.sql` | **6/6 PASS** |
| Full SQL suite (121 files) | **116 pass / 5 fail** — the same 5 pre-existing harness failures |
| `tsc` on changed files | 0 errors |
| `lint:ratchet` | green, 0 new `any` |

A latent bug was found and fixed while closing E1: the open-item hop read
`fin_open_item_balances.amount_open`, a column that does not exist. It never fired, because no
procurement document had an open item to reach that branch — the same finding E1. The hop now
reads `settlement_status` and `outstanding_amount`.

Bugs found and fixed while building it: a `bigint`/`integer` mismatch on the hop number
(`row_number()` returns bigint), and two wrong column references (`cash_bank_transactions` has
`description`/`reference_id`, not `reference`). Both were caught by running the test rather than
by reading the SQL.

Also worth noting for future test fixtures: several tables (`organizations`, `cost_centers`,
`requests`…) have `BEFORE INSERT` triggers that overwrite `tenant_id` from
`get_my_tenant_id()`, so fixture inserts need a `request.jwt.claims` claim set even when
inserting as the owner. `organizations` will fail with *"could not determine tenant_id for
current user"* otherwise. That cost a few iterations.

## Deliberately not done

- **The PO hop is supported but not exercised by the test.** Creating a purchase order means
  creating a `requests` row, which requires a configured procurement workflow (stages,
  approvals) — a separate fixture surface from the financial chain. Covered indirectly by the
  procurement specs.
- **No UI.** A "trace this document" panel would be the natural front-end for this, and is most
  of item B's screen. Left for B so the two share one component.

## Next

Item **B** — `fin_transaction_actors` (initiator / approver / poster / reverser per journal
entry), filled by triggers on the gateway and the approval RPCs, then one audit screen that
joins it to `fin_trace`'s output. That is the last of the five.
