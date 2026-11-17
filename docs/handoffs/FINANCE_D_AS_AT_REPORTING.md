# Finance item D — done (as-at reporting + void double-count)

**Branch state:** uncommitted changes on `main` @ `0d550eb`. Five files, one migration, one SQL test.
**Migration:** `supabase/migrations/20261117120000_fin_as_at_reporting_and_void_netting.sql`
**Test:** `supabase/tests/test_fin_as_at_reporting.sql`

---

## The bug was bigger than "no as-at date"

While auditing, I found the Trial Balance was **wrong today**, not just irreproducible.

`void_journal_entry()` does two things: it sets the original entry's `status` to `'void'`, **and** posts a new `'posted'` reversal entry that swaps every debit/credit. But `v_account_ledger` included only `je.status = 'posted'`. So on every void, the reversal counted and the original vanished:

| Step | Account 1000 balance |
|---|---|
| post 100 debit | **+100** ✔ |
| void it | **−100** ✘ (should be 0) |

Demonstrated on a pre-fix replay (database `prefix`, no migration applied):

```
PRE-FIX after post: 1000 balance = 100  (expected 100)
PRE-FIX after void: 1000 balance = -100  (expected 0 -> BUG if -100)
```

Every void path funnels through that one function — `platform_fin_void_settlement_impl`, `platform_fin_void_credit_note_impl`, `fin_void_fx_revaluation`, `ins_void_commission_transfer`, `ins_void_claim_payment` — so **every voided settlement, credit note, FX revaluation, commission transfer and claim payment was being reported as its own negative** in the trial balance.

No SQL test asserted anything against `v_trial_balance` (only a frontend test with a stubbed client), which is why it survived.

## Root cause and fix

The original was marked void **destructively**. A void is not a state change to history; it is a new event — the reversal — that happens at a point in time. That is the same principle the append-only subledger follows everywhere else, applied to the GL.

1. **Void provenance recorded.** `journal_entries` gains `voided_at`, `voided_by`, `void_reason`, written by `void_journal_entry`. History is now dated rather than overwritten.
2. **No double count.** `v_account_ledger` counts posted *and* voided lines, because a voided entry's offset lives in its posted reversal. Verified: post → +100, void → **0**.
3. **As-at is then just a date filter.** Because both the original and the reversal are ordinary dated rows, `transaction_date <= p_as_of` slices history correctly with no special void logic. A void recorded *after* the reporting date cannot retroactively change the report.
4. **As-at API.** New `fin_trial_balance(p_as_of date)` and `fin_account_ledger(p_as_of date)` (both `security invoker`, `search_path` pinned, granted to `authenticated`). `v_trial_balance` is kept as an "as of today" shim so nothing that reads it breaks.
5. **UI.** `TrialBalance.tsx` calls the new RPC, gets an **"As at"** date picker defaulting to today, and shows the date so a printed report can't be mistaken for today's.

## Verification

Run against a Docker-free PostgreSQL 17 replay of the real baseline + all 57 migrations (`scripts/pgharness/build.sh`).

| Check | Result |
|---|---|
| Migration applies as part of a clean replay | ✔ |
| `test_fin_as_at_reporting.sql` | **5/5 PASS** |
| Full SQL suite (118 files) | **114 pass, 5 fail** |
| The 5 failures, on a pre-fix replay | **identical 5 fail** — pre-existing on this harness, not mine |
| `vitest` (whole frontend) | **1,533 passed**, 11 expected-fail, same 3 env-only suites (Node 20 `WebSocket`) |
| `TrialBalance.test.tsx` | 8 tests, incl. 3 new as-at cases |
| `tsc` on changed files | clean |
| `lint:ratchet` | all green, **0 new `any`** |

**Two regressions I caught and fixed mid-way**, both found by existing gates:

- `test_journal_base_amounts` failed with *"v_account_ledger does not use security_invoker"* — a plain `CREATE OR REPLACE VIEW` **does not preserve reloptions**, so replacing the definition silently dropped `security_invoker`. This repo already had this exact bug once (migration `20261106130000`). Fixed with an explicit `alter view ... set (security_invoker = true)` on both views, unconditionally, in the same transaction.
- `test_production_invariants` failed for the same reason (view invoker ratchet).

Both now pass. Worth noting: your existing gates did their job — which is the strongest argument for item E.

## Not done, deliberately

- **No backfill** of `voided_at` for entries voided before this migration. That timestamp was never recorded and cannot be reconstructed; guessing it would be worse than a null. Those rows keep exactly today's behaviour in as-at reports.
- **`void_journal_entry` posts its reversal at `current_date`, not the original's date.** Correct for the append-only model, but it means a void "moves" the offset into the current period. If Finance wants voids booked *into* the original period (some jurisdictions require it), that's a policy decision — flag it, don't guess.

## Two follow-ups this exposed

1. **`accounting_periods` can be reopened or deleted by any single Finance user** (plain RLS `UPDATE`/`DELETE`, no maker-checker) — item **A**. It matters more now: a reproducible report rests on closed periods actually staying closed.
2. **`v_trial_balance` never had a SQL test** until now. Any report that only has a stubbed frontend test is unverified. That is item **E**'s argument in one sentence.

## Next

Item **A**: guarded `close_accounting_period` / `reopen_accounting_period` RPCs with maker-checker + audit event, and revoke direct `UPDATE`/`DELETE` on `accounting_periods` (and `DELETE` on the journal tables, so immutability isn't resting on one trigger). ~1 day.
