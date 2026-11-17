# Finance item A — done (period close/reopen controls)

**Migration:** `supabase/migrations/20261117130000_fin_period_close_controls.sql`
**Test:** `supabase/tests/test_fin_period_controls.sql` (8 assertions)

---

## What was actually wrong

The *posting* half of A was already built. `post_journal_entry()` refuses to post into a
closed period, and every module funnels through it — I verified all 40 functions touching
`journal_entries`, and only the gateway inserts directly. Procurement, payroll, bind, cancel,
endorse, claims, FX revaluation and opening balances were all covered.

The hole was **period administration**:

```
grant:  DELETE, INSERT, SELECT, UPDATE  to authenticated
policy: is_finance_team_member('finance') and tenant_id = get_my_tenant_id()
```

Any single Finance user could reopen a closed period — or delete the period row outright —
with one PostgREST `PATCH`/`DELETE`. No second pair of eyes, no reason, no audit row. The
admin screen did exactly that: `supabase.from('accounting_periods').update({status})`.

This matters more now than it did last week: an as-at report is only reproducible if a
closed period actually stays closed. That is the link to item D.

## What the migration does

1. **`accounting_period_events`** — append-only log of every close/reopen/delete, with actor,
   email, reason, before/after status, and the period's date range snapshotted.
2. **`fin_close_accounting_period(id, note)`** — finance role, idempotent, logged.
3. **`fin_reopen_accounting_period(id, reason)`** — reason required (≥10 chars) **and** the
   caller must be a *different* finance user from the one who closed it
   (`SEGREGATION_OF_DUTIES`). Also refuses if no second finance user exists at all.
4. **`fin_delete_accounting_period(id, reason)`** — refuses if any journal entry falls inside
   the period; otherwise finance + reason + logged.
5. **`fin_period_events(period_id)`** — the timeline, readable by the tenant's finance team.
6. **Grants tightened so the RPCs are the only way in:**
   - `accounting_periods`: `UPDATE`, `DELETE` revoked from `authenticated`/`anon`
   - `journal_entries`, `journal_entry_lines`: `DELETE` revoked — immutability no longer rests
     on `prevent_journal_mutation` alone

`INSERT` on `accounting_periods` is deliberately kept: the admin screen and several SQL tests
create periods client-side, and an insert cannot reopen anything (overlaps are already
rejected by `check_accounting_period_no_overlap` + the tenant range unique index). `INSERT` on
the journal tables is kept because four existing tests insert journal rows as `authenticated`
to exercise the line guards.

## Two flaws I found in my own work while testing

1. **The audit log cascaded away.** I first wrote
   `period_id ... references accounting_periods(id) on delete cascade` — so deleting a period
   deleted the very event recording that it was deleted. Caught by the test. Fixed to
   `ON DELETE SET NULL` with `period_start`/`period_end` snapshotted, so a delete event
   survives and stays fully described. An audit log that dies with its subject is not an
   audit log.
2. **Missing tenant read-only guard.** `check_live_security_drift.sql` failed the build:
   *"tenant_read_only_guard missing on accounting_period_events"*. Fixed with the repo's own
   `select public.apply_tenant_read_only_guard()` one-liner, the same call the 20261109 and
   20261111 migrations used for their new tables.

Both were caught by gates that already existed — the same argument for item E.

## Verification

| Check | Result |
|---|---|
| Clean replay (baseline + all **59** migrations) | ✔ succeeds |
| `test_fin_period_controls.sql` | **8/8 PASS** |
| `test_fin_as_at_reporting.sql` | 5/5 PASS (still green alongside) |
| Full SQL suite (120 files) | **115 pass / 5 fail** — the same 5 that fail on an unpatched replay |
| `AccountingPeriodsAdmin.test.tsx` (**new**) | 5/5 pass |
| `TrialBalance.test.tsx` | 8/8 pass |
| Whole frontend suite | **1,538 pass**, 11 expected-fail, same 3 env-only suites |
| `tsc` on changed files | 0 errors |
| `lint:ratchet` | all green, **0 new `any`** |

Everything above was re-run on a **fresh clone with the patch applied**, not just in the
working copy.

## UI changes

`AccountingPeriodsAdmin.tsx` now calls the RPCs instead of patching the table, and the reopen
dialog gained a required **reason** field with the copy explaining that a second finance user
must do it. New test file pins down: the RPC used (not `.update()`), the client-side reason
guard, and that a server-side `SEGREGATION_OF_DUTIES` rejection is surfaced rather than
swallowed.

## Deliberately not done

- **No enforcement that a closed period's results were "reported externally"** (e.g. blocking
  reopen after a filing). That needs a policy decision about what evidence counts; the reason
  field and audit row are the minimum that makes it auditable either way.
- **`closed_by` can be null** for periods closed before `stamp_accounting_period_close`
  existed. Those fall through to the reason requirement rather than becoming impossible to
  reopen.
- **Insurance transaction-date vs posting-date** (risk date vs period date for bind/cancel/
  endorse) is still a design conversation, as flagged in the roadmap. Not a bug, so not touched.

## Next

Item **E** — the end-to-end procurement trace (`fin_trace()` helper: procurement transaction →
supplier open item → settlement → bank reconciliation line → GL). ~1 day, and the helper is
most of item **B**'s backend.
