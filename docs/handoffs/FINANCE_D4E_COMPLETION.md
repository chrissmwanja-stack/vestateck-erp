# Finance D4e — completion pass

**Migration:** `supabase/migrations/20261119210000_d4e_bank_adjustments_completion.sql`
**SQL test:** `supabase/tests/test_d4e_bank_adjustments_completion.sql`
**Screens:** `BankAdjustmentsPanel` (reworked), `BankAdjustmentRegister`,
`BankAdjustmentUnusualAccounts`
**E2E:** `apps/web/e2e/bank-adjustments.spec.ts` + seed fixtures (§3b of `seed.sql`)

This is the follow-up to `20261119064626` (applied) and the six fix-forward
migrations that followed it. Nothing applied was edited; every change is a new
migration (rule 9).

---

## What changed, in the order the brief listed it

### 1. Header-account classification and account filtering

The counter-account picker offered every active `gl_accounts` row, including
header accounts and AR/AP control accounts, and the server refused them only
after the click. The picker now selects `is_header` and `is_control_account`,
disables those options with the reason inline ("not available: a control
account (receivables/payables) cannot be the other side"), and shows the reason
under the field when one is somehow chosen. `counterAccountBlockReason()` in
`bank-reconciliation/types.ts` is the single client-side mirror of
`bank_adjustment_validate_counter()`.

Bank/cash GL accounts are still refused, by the server only: the client cannot
see `gl_posting_rules` or `fin_bank_accounts.gl_account_id` without a second
read, and the server's refusal names the account, so the message is enough.

Filtering to the account on screen stays client-side, and the register gained a
bank-account filter of its own.

### 2. One-person exception usable in the UI when authorised

- New RPC `bank_adjustment_can_self_approve()` — stable, definer, finance-only,
  no tenant argument. It is **false** when there is no tenant, no finance role,
  no approved setting, or on any error (a failed permission read is never a
  "yes").
- The panel asks it on load. When true: an "one-person exception active" chip, a
  banner explaining the audit consequence, and Approve enabled on your own row.
  The confirm dialog repeats the warning for your own row.
- When false, Approve stays disabled on your own row and a hint says how many
  of your proposals are waiting for someone else.
- The server records the decision: `bank_adjustments.approval_mode` is
  `two_person` or `one_person_exception`, with a CHECK that the flag and the
  mode agree in both directions. Until now `self_approved` was set but "two
  people did this" was only implicit.

### 3. Linked rework for rejected adjustments

`create_bank_adjustment` already accepted `p_reworked_from`; the panel never
sent it. A rejected row owned by the reader now has a **Rework** button that
loads the line back into the selector, prefills the reason and the counter
account, and sends `p_reworked_from`. The new row carries a "reworked" chip, and
the event log records `reworked` with the origin id.

### 4. Adjustment event history on the screen

New RPC `bank_adjustment_history(p_adjustment_id)` returns the events in order
with the actor's name. Every **History** button opens it. `bank_adjustment_events`
gained `actor_name` (snapshot at write time) so the history does not depend on
`app_users`' narrower read policy; `bank_adjustment_history()` falls back to a
live join, then to "Unknown user".

### 5. Register and unusual-account report screens

- `/financial-management/reports/bank-adjustments` — every adjustment and
  reversal, who proposed, who decided, how it was allowed to post, filters for
  self-approved / status / bank account, and a banner counting self-approved
  rows for the accountant.
- `/financial-management/reports/bank-adjustment-unusual-accounts` — posted
  adjustments whose counter-account is not on the company's usual-accounts
  list, with add/remove of the list itself (through
  `bank_adjustment_add_usual_account` / `..._remove_usual_account` /
  `..._list_usual_accounts`, so no table write grant is needed). While the list
  is empty the screen says so instead of implying every posting is anomalous.

Both are finance-only at the RLS layer and use the same `db` handle as the rest
of the bank-reconciliation feature.

### 6. Adjustments against unregistered bank accounts

`create_bank_adjustment` now resolves the line's bank in `fin_bank_accounts`
before writing and raises `ADJ_BANK_UNREGISTERED` with the account name when it
is missing, or `ADJ_BANK_GL_MISSING` when the registry row has no GL account.
The stored `bank_account` is the registry name. Previously the proposal was
accepted and then failed at approval with `ADJ_BANK_MISSING`, which meant a
reconciler could propose an adjustment that could never post.

### 7. Tax codes: decided, deferred

**Decision (19 Nov 2026): no tax support on bank adjustments for now.**
Rationale recorded in the migration header: a bank charge or interest posting is
not re-declared for VAT here, and building it without an agreed treatment would
put an unverified tax figure in the ledger.

What adding it later would require, so the decision can be revisited cheaply:

1. the VAT account to post to, and whether the counter-account receives the gross
   or the net (this changes the journal, not just a field);
2. the rate source — a statutory-rate row, or per-line entry;
3. whether the bank's charge document is the tax invoice (which decides whether
   this system issues anything);
4. who reviews the treatment (the `requires_legal_review` mechanism already
   exists for settings);
5. a decision on partially exempt apportionment if the company has any.

### 8. Playwright coverage

`apps/web/e2e/bank-adjustments.spec.ts`, three serial tests that use two real
finance users:

1. maker proposes → the maker's own Approve is **disabled** → the checker approves
   → the register shows `posted`, approved by the checker, **not** self-approved
   → the statement line is matched;
2. maker proposes → checker rejects with a reason → maker reworks → the new row
   is linked and the history shows "Reworked from a rejected proposal";
3. the unusual-account report explains an empty usual-accounts list, then adding
   the usual account removes the flag, and a control account is not offered.

Seed support: `supabase/seed.sql` §3b imports two unmatched PEARL-OPERATING
lines (`D4E-CHARGE-1` −45,000, `D4E-INTEREST-1` +12,000) through
`import_bank_statement_batch` as the reconciler, so the spec does not have to
import a statement first. The spec consumes both lines; a second run on the same
database needs `supabase db reset` (same contract as
`insurance-cash-commission.spec.ts`).

**These specs have not been executed** — this environment has no Docker, so no
local Supabase stack and no browser. They typecheck (`tsc -p e2e/tsconfig.json`)
and follow the existing specs' selectors and login helper. Run
`npm run test:e2e -- bank-adjustments` against a fresh stack before relying on
them.

---

## Verification performed here

| Check | Result |
|---|---|
| `check-migration-policy.sh origin/main` | 1 new migration, OK |
| Migration + SQL test parse (pglast, real PG grammar) | 36 and 56 statements, clean |
| Panel tests | 11 passed (was 6) |
| New report-screen tests | 8 passed |
| Bank reconciliation screen tests | 16 passed |
| Full web suite | 182 files / 1778 passed, 11 expected-fail, 0 failed |
| `tsc --noEmit` (src) and `tsc -p e2e` | clean |
| Lint ratchets (any / dialogs / swallowed / hook-deps) | none over baseline |

**Not run here:** `supabase db reset`, the SQL test files, `npm run build`
(the sandbox has 2 GB RAM; `vite build` is OOM-killed, and CI builds fine).
`database.types.ts` was **not** regenerated: this migration adds columns, three
RPCs and no view/table signature the web app reads through the committed
types — the D4e objects are still read through the untyped `db` handle. If CI's
type check disagrees, run `gen-types.ps1 -Local` on a machine with the stack
and commit the result (policy step 3).

---

## Follow-ups, and what happened to them

Both items this handoff originally listed as deliberately out of scope are now
done, in their own commits after the main pass.

### Table privileges — done, and the earlier report was wrong

`20261119230000_d4e_bank_adjustments_surface_hardening.sql`.

**Correction:** an earlier version of this handoff said `anon` held
INSERT/UPDATE/DELETE on the D4e tables. It does not. `20261112090000` revoked
all table privileges from `anon` and set the default privileges to match, so the
three tables were born with no anon access; the live catalog lists only
`authenticated`, `postgres` and `service_role`. The claim came from
`has_table_privilege('anon', …)` being true, which was an artifact of an `aclitem`
cast in a quick query, not a real grant.

What was actually true, and is now fixed:

| Role | Before | After |
|---|---|---|
| `anon` | nothing | nothing (unchanged, now pinned by a test) |
| `authenticated` | SELECT, INSERT, UPDATE, DELETE, MAINTAIN | **SELECT only** |

Writes are now RPC-only in fact: every write already went through
`create_/approve_/reject_/request_bank_adjustment_reversal` and, since
`20261119210000`, the usual-account add/remove RPCs. MAINTAIN is revoked too
(PostgreSQL 17 only; the revoke is guarded so replay on older servers is a
no-op). `supabase/tests/test_d4e_bank_adjustments_privileges.sql` pins both
directions and that the write RPCs stay callable.

### `acct_setting_approve` and legal review — done, as a D4e gate

`20261119220000_d4e_self_approval_requires_review.sql`.

Rather than change the settings workflow (approve now, review later, which
`acct_assert_reviewed` already defends at the point of use — and which
`test_acct_config_stabilisation.sql` asserts), the gate moved to where D4e
depends on it: `approve_bank_adjustment` now reads
`allow_self_approved_bank_adjustments` through `acct_assert_reviewed`, so the
one-person exception only counts when the approved value has a recorded
compliance review. `bank_adjustment_can_self_approve()` uses the same call, so
the screen cannot offer what the server will refuse.

`supabase/tests/test_d4e_self_approval_requires_review.sql` covers the three
states: no setting (refused), approved-but-unreviewed (refused, while a
different finance user can still approve), and reviewed (allowed, recorded as
`one_person_exception`).

### Still open, unchanged

- **Panel reads base tables rather than `bank_adjustment_register`.** The view
  exists and is tested; the panel's embedded select predates it. A small
  refactor, not a behaviour change.
- **The settings workflow itself** still allows approving a
  `requires_legal_review` key before its review is recorded. That is by design —
  the review can be recorded on an approved choice, and readers enforce it — but
  if the intent is "no approval without a review", the change belongs in
  `acct_setting_approve`, with `test_acct_config_stabilisation.sql` updated.
