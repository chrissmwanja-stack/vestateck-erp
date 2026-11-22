# Claim approval revision history — design (sign-off required before build)

Status: **signed off 22 Nov 2026**. The owner confirmed the scope and the details recorded below and, with the same approval, approved the build. The status doc and the acceptance plan record the new gate as **Open/unrun** until the user runs the tests on their stack.

**Scope (agreed):** claims approval history and as-at reporting enhancement, not a general claims versioning project. Key requirement: a report for a past date must show the claim amount and approval position valid at that date — not the claim's current approved amount.

**Fields (agreed):** id, tenant_id, claim_id, kind (initial / revision / cleared — naming conventions for the repo are `kind` with those values, matching `ins_claim_reserve_history`), previous_amount, new_amount (null for cleared), reason, **note** (manager's exact note, nullable, kept separate from the system-generated reason so that a blank note is visibly a blank note), revised_by (the repo's actor convention in this table, `default auth.uid()`), effective_at (when the decision took effect — the approval event's time), created_at (when the record was written).

**Backfill (agreed):** existing approved/settled claims get one `initial` row, dated at the latest approval event for that claim (the only approval evidence the existing records carry — the status events), reason 'Approval at the time history was introduced'. Claims whose approval is not evident (un-approved claims, whose amount was cleared with no history) get no row; the amount is unknowable and is not reconstructed.

**Reason rules (agreed):** blank note on a first approval → store the system-generated reason 'Approved by claims manager', note stays NULL; manager's exact note is stored when provided; an approval revision (re-approval) requires a reason; an un-approval (cleared) requires a reason.

**Report (agreed):** `ins_report_claims_register` and `ins_report_claims_ageing` (built on the register) show the approved amount as-at from the history, like the reserve is. Status, open flag and ageing are unchanged.

**UI (kept in scope):** Claim Detail shows an "Approval history" section parallel to "Reserve history"; the approve step requires a reason when the claim has an approval decision already (the revision case), matching the RPC.

**Non-goals:** renewals history (item 9, not chosen), co-insurer schedule / certificate stock / claims checklist (item 10, not chosen), and the general claim-versioning project the scope excludes.

## Facts found (verified in `20261031235900_squashed_baseline.sql` and current migrations)

- `ins_claims.approved_amount` is mutated in place. In `ins_transition_claim(uuid, text, text, numeric)`:
  - approve (`assessing` → `approved`): `update ins_claims set status='approved', approved_amount=p_amount, payment_mode=v_mode`
  - un-approve (`approved` → `assessing`): `update ins_claims set status='assessing', approved_amount=null, payment_mode=null` (after manager + reason + not-recognised + not-paid guards)
- `ins_claim_events` records the status transition (`from_status`, `to_status`, `note`) but **not** the approved amount. The amount is gone once it is cleared.
- No claim-approval history table existed. The claims register used the **current** `approved_amount`; DR-41 recorded this explicitly: *"The approved amount is not kept as history, so it is the current one."*
- Reserve history is the established pattern: table (`ins_claim_reserve_history`, with `(tenant_id, claim_id)` composite FK, kind check, shape check, `revised_by`/`revised_at`), immutable via a guard (`ins_claim_reserve_history_guard`), written only via RPC, surfaced in `ClaimDetail.tsx`, and used by the claims register as `reserve_as_at`.
- The claims register already treated paid amounts as as-at (`ins_claim_payments` with the void-after-as_of rule) — only the approved amount was current.

## The as-built design — `ins_claim_approval_history` (see migration `20261123000000_ins_claim_approval_history.sql`)

New table, mirroring `ins_claim_reserve_history` exactly:

```sql
id             uuid default gen_random_uuid() not null
tenant_id      uuid not null references tenants(id) on delete cascade
claim_id       uuid not null
kind           text not null                      -- 'initial' | 'revision' | 'cleared'
previous_amount numeric(18,2)                     -- null only for 'initial'
new_amount     numeric(18,2)                      -- null only for 'cleared'
reason         text not null                      -- display reason, always non-blank
note           text                                -- the manager's exact note, nullable, kept separate from reason
revised_by     uuid default auth.uid()
effective_at   timestamptz default now() not null  -- when the decision took effect
created_at     timestamptz default now() not null  -- when the record was written
-- shape: initial -> previous null, new not null and > 0
--        revision -> previous not null, new not null and > 0
--        cleared -> previous not null, new null
-- composite FK (tenant_id, claim_id) -> ins_claims(tenant_id, id) on delete restrict
```

Rows are written inside `ins_transition_claim` (after the `ins.via_rpc` set, exactly like the reserve pattern):

| Transition | Row written |
|---|---|
| `assessing` → `approved` (first approval) | `initial`: previous null, new = `p_amount`, reason = the manager's exact note, or `'Approved by claims manager'` when no note was given, note as given (null when blank) |
| `assessing` → `approved` (re-approval — a revision) | `revision`: previous = the prior approved amount (the latest non-null new_amount before this decision), new = `p_amount`, reason = the manager's exact note (required — the RPC raises `INS_NOTE_REQUIRED` when it is blank), note as given |
| `approved` → `assessing` (un-approval) | `cleared`: previous = the approved amount being cleared, new = null, reason = the un-approval note (required), note as given |

`ins_claim_events` keeps recording the status transition exactly as today — events record the status move, the history records the decision and its amount. An approval that is not a revision (the first) and a revision that changes nothing still record a row — being a recorded decision, not a diff.

**Immutability & guards** (identical to reserve history):
- `ins_claim_approval_history_guard()`: non-RPC write is rejected (`42501`); UPDATE/DELETE are rejected.
- RLS select policy (tenant = `get_my_tenant_id()` and `can_access_insurance()`); `apply_tenant_read_only_guard()` at the end of the migration; grants mirror reserve history.
- No client insert path — writes only from `ins_transition_claim` and the backfill.

**Register** (`ins_report_claims_register` + `ins_report_claims_ageing`, unchanged signatures):
- The `approved_amount` output is the latest approval position on or before `p_as_of`, taken from the history with the same tie-break convention the register uses for events and reserves — a `cleared` row means the claim was not approved at that date, so the output is null. Status, open flag, reserve-as-at, payments-as-at, ageing and outstanding are unchanged; the outstanding figure for an approved claim is (approved-as-at) less payments.
- Ageing inherits this automatically (it is built on the register).

**Backfill** (at migration time): each claim with a non-null `approved_amount` (currently approved or settled) and no history row gets one `initial` row, `effective_at` = the claim's latest approval event time (the only evidence for the decision time the existing records carry), `revised_by` = that event's actor (fallback `ins_claims.created_by`), `created_at` = migration time, reason 'Approval at the time history was introduced', note = null. Claims with no approved amount get no row — their approval-time evidence is the status events alone, and no amount is reconstructed.

**UI** (kept in scope): `ClaimDetail.tsx` gains an "Approval history" section parallel to "Reserve history" (date, decision, amount, reason — `cleared` rows show `prior → withdrawn`). The approve step requires a reason when the claim already has an approval decision (the revision case), matching the RPC. New `ClaimApprovalEntry` type in `types.ts`.

**Tests** (`supabase/tests/test_claim_approval_history.sql`): initial row on first approval; blank-note fallback reason; register at today shows the approved amount, yesterday shows none; un-approval refuses a blank reason; un-approval writes a cleared row and clears the decision; re-approval refuses a blank reason; re-approval writes a revision row; register at today shows the re-approved amount, yesterday shows none; direct insert/update/delete are refused; the events trail survives; tenant isolation for the history and the register. The backfill is not exercised by the test (it runs at migration time against live data) and is therefore not claimed as tested.

## Non-goals

Renewal outcomes (item 9, not chosen); co-insurer schedule / motor certificate stock / claims checklist (item 10, not chosen); any general claim-versioning project.
