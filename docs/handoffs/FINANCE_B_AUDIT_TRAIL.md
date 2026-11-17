# Finance B — the financial audit trail

**Migration:** `supabase/migrations/20261117160000_fin_audit_trail_actors.sql`
**Tests:** `supabase/tests/test_fin_audit_trail.sql` (11 sections), `FinancialAuditTrail.test.tsx` (5)
**Screen:** `/financial-management/reports/audit-trail`

This is the last of the five. It answers the question you posed for B: for one money movement,
who initiated it, who approved it, who posted it, who reversed it, what it posted, and what paper
backs it — in one place, in order.

---

## What recon found — including one thing I got wrong

I told you I suspected `approval_actions` was unrecordable and forgeable. **That was wrong**, and
probes on the live harness settled it:

| Probe | Result |
|---|---|
| `record_invoice_approval_decision` security mode | **SECURITY DEFINER** (I had assumed invoker) |
| A different reviewer approves through the RPC | **succeeds**, persists 1 `approval_actions` row, `effective_user_id` = the approver |
| A user submits their own invoice, then approves it | **denied**: "you submitted this invoice -- a different reviewer must act on it" |
| Direct forged `INSERT` into `approval_actions` | **denied, 42501** (RLS: no INSERT policy, and RLS *errors* rather than passing on INSERT) |
| Direct `UPDATE`/`DELETE` of approval history | 0 rows affected — verified with a real seeded row, which survived |

So there was no approval bug to fix. `approval_actions` is sound: real approvals are recorded, and
the history is neither forgeable nor erasable from the client. You said "confirm and fix if it's
real" — it wasn't real, so I fixed nothing, and I'm telling you rather than quietly shipping a
fix for a non-problem.

**What genuinely was missing** (all three verified):
1. No journal entry recorded **who initiated** it. Only the poster.
2. The link from a reversal to its original existed **only** in a transaction-local GUC
   (`fin.reversal_of`) and a description string (`'Reversal of <uuid> — …'`). Never persisted.
3. Nothing joined any of that to the document, the paper, or the period.

## The design

`fin_transaction_actors` — one row per (journal entry, role), roles `initiated | approved |
posted | reversed`, plus `related_journal_entry_id` so a reversal names its original as a real FK.

**Actor semantics (your decision):** every row names the **effective** identity —
`effective_user_id()`, i.e. the impersonated user under impersonation, else `auth.uid()`. That is
whose authority actually counted, and it is what `is_finance_team_member()` and the
segregation-of-duties checks already use. For impersonated work the raw session user and the
impersonation session are kept alongside, so it is visible rather than hidden.

**Capture point (your decision: the posting core):** an `AFTER INSERT` trigger on
`journal_entries`, which is the choke point every module posts through — no per-module wiring, and
it covers the reversal posts the void paths make. I used a trigger rather than editing
`post_journal_entry` because that function is SECURITY DEFINER with a long body; re-typing it
would risk drifting from the original for no gain. `prevent_journal_mutation` keeps entries
immutable, so INSERT is the only way one comes into existence — coverage is complete.

**Two things deliberately not done:**
- **No invented initiators.** `initiated` and `approved` are not backfilled: neither fact was ever
  recorded, and inventing them is precisely what this work exists to stop. `fin_audit_gaps()`
  reports postings with no initiator, so the gap is visible and countable.
- **`posted` and `reversed` *are* backfilled**, from `posted_by`, `voided_by` and the reversal
  description. Those facts really were recorded; it would be strange for the trail to claim nobody
  posted a 2024 entry. The description parse is the weakness this table removes, done once for old
  rows and never again.

**Append-only by construction:** RLS is SELECT-only, `INSERT/UPDATE/DELETE` are revoked from
`authenticated`, and a trigger raises `AUDIT_IMMUTABLE` on any UPDATE or DELETE. Only SECURITY
DEFINER functions write here, and none of them is granted to clients except
`fin_audit_link_initiator`, which is scoped to the caller's tenant and cannot overwrite an
existing initiator (`ON CONFLICT DO NOTHING`).

## The screen

`fin_audit_trail(entity_type, entity_id)` composes what already exists rather than duplicating it:
the document spine and money legs from `fin_trace` (item E), the actors from the new table,
approvals from `approval_actions` (both the invoice and material-request trails), the paper from
`documents`, and the period state. The screen is read-only and shows a one-line "initiated /
approved / posted / reversed" summary, then the ordered hops, then tenant-wide postings with
incomplete history.

## Verification

| Check | Result |
|---|---|
| Clean replay, baseline + all **62** migrations | ✔ |
| `test_fin_audit_trail.sql` | **11/11 PASS** |
| Full SQL suite, fresh database, **123** files | **122 pass / 1 fail** |
| The one failure | `test_bind_config_snapshot` — pre-existing, untouched by this work |
| `FinancialAuditTrail.test.tsx` | **5/5** |
| Finance frontend trio (audit trail + reconciliation + periods) | **23/23** |
| Full `vitest` | **1,544 pass / 11 expected-fail**, same 3 env-only files |
| `tsc` on changed files | 0 errors |
| `lint:ratchet` | green — 0 new `any` / dialogs / swallowed errors / hook deps |
| `check_live_security_drift.sql` | PASS |
| `A/B/D` tests unaffected | 8/8, 6/6, 5/5 |

Bugs found and fixed while building this: my first draft put `reversed` on the *wrong side* of the
reversal (it would have said the voided original was reversed, rather than recording the reverser
on the reversal); a `join` on a `FROM a, t JOIN b` clause that Postgres rejects; and three test
fixtures that were wrong in ways that made them prove nothing (posting rules missing `vat_input`,
so no journal posted at all; the approval RPC called before `approval_assignments` existed; and an
idempotency assertion that asserted the opposite of the intended behaviour).

## Honest limits

- **Initiation is not automatic.** It has to be linked (`fin_audit_link_initiator`) by whatever
  knows who raised the document. I did not wire it into every creation path, because the creating
  tables hold the fact and the wiring is per-module. Until that is done, new postings will appear
  in `fin_audit_gaps()` as having no initiator — which is the honest state, not a silent one.
  Wiring the two obvious ones (`invoice_requests.requester_id`, `requests.requester_id`) is the
  natural next step and is deliberately not guessed at here.
- **Approvals are resolved at read time**, not copied onto the journal entry: an approval is
  recorded before the document it approves is posted, so there is usually no journal entry to
  attach it to yet.
- **`fin_audit_trail` inherits `fin_trace`'s entity list**, so it covers the five document types
  `fin_trace` supports. Anything else is refused with a clear message rather than half-reported.

## The five, done

| | Item | State |
|---|---|---|
| **A** | Period controls | done — close/reopen/delete guarded, RPCs, SoD |
| **B** | Audit trail | **done — this migration** |
| **C** | Bank reconciliation | mostly delivered by PR #7; suggest-and-confirm and the server-side third-user rule remain |
| **D** | As-at reporting | done — reproducible as at a historical date |
| **E** | Integration testing | done — one procurement payment traced end to end; finding E1 closed |

The one item still short of its original scope is **C**: the third-user rule is still enforced only
in the client. That is the remaining piece of the agenda.
