# Pending behaviour-change approval — AE5

**Status: awaiting reviewer approval. Not yet in the acceptance register.**

The register refuses to carry this row until a reviewer approves it (`approved: true`,
`approved_by` set), and it also refuses an unapproved row that carries evidence. Both rules are
correct, so the row has deliberately **not** been added. This document exists so the change is
specified and reviewable rather than left to be discovered, without the register claiming an
approval that has not happened.

Once approved, this becomes row **AE5** in
`docs/insurance-brokerage/signoff-register.json → acceptance_evidence.items`.

---

## The change

B12 (`supabase/migrations/20261124011700_fin_manual_journal_chain.sql`) replaces a refusal with an
approval chain.

A manual journal routed to a level above 1 used to be **refused at submission** with
`FIN_MANUAL_JOURNAL_LEVEL`. It is now accepted for submission and held: it posts only when every
level from 1 to the routed level has been approved, in order, by distinct people holding the role
each level names, none of them the person who raised it.

## Which actions become unavailable

* The action that becomes genuinely unavailable is the one that was never correct: **posting a
  routed journal on a single signature.** A user holding only the finance role can no longer
  complete a routed journal alone.
* **The person who raised a journal can no longer approve it at any level**, including as a company
  administrator. Previously a company admin who raised a journal could approve it when no chain
  was configured; that is now refused as `FIN_MANUAL_JOURNAL_SELF_APPROVAL`.
* **One person can no longer take two levels** of the same journal (`FIN_MANUAL_JOURNAL_DISTINCT`).
* **Approving a level whose role you do not hold** is refused, where before the journal was simply
  not submittable at all.
* Nothing that was previously allowed and correct becomes unavailable. Submitting a routed journal
  is the one refusal that was removed, and it was a wall rather than a control.

## Trigger condition

The company has active `workflow_stages` rows with `applies_to = 'manual_journals'` whose
`threshold_amount` the journal's `total_debit` reaches, and the highest such stage has
`sequence_order > 1`.

**With no stages configured nothing changes**: `required_level` is 0 and the pre-existing
single-checker rule applies unchanged. This is proved by §1 of the test file.

Also triggered by a gap in the configured sequence (for example levels 1 and 3 active, nothing at
2), which is refused as `FIN_MANUAL_JOURNAL_CHAIN_GAP` rather than becoming a level anyone may
sign.

## Observable effect

| Before | After |
|---|---|
| Submitting a routed journal raised `FIN_MANUAL_JOURNAL_LEVEL` | Submission returns `pending_approval` |
| One approval posted the journal | An approval below the routed level returns `pending_approval` and posts nothing; the last level posts |
| No record of who approved | `fin_manual_journal_approvals` holds one append-only row per level |

New error codes, each naming the problem: `FIN_MANUAL_JOURNAL_ROLE`,
`FIN_MANUAL_JOURNAL_ROLE_UNCONFIGURED`, `FIN_MANUAL_JOURNAL_DISTINCT`,
`FIN_MANUAL_JOURNAL_CHAIN_GAP`, `FIN_MANUAL_JOURNAL_STATE`. `FIN_MANUAL_JOURNAL_LEVEL` no longer
exists as a refusal.

## Harm prevented

An entry the company said needs higher authority passing on one signature — either by being approved
at level 1, or by a shell chain in which one determined person signs every level. Also prevents a
hole in the configured sequence turning into a level that anybody at all may sign.

## Authorised correction route

Three routes, none of which weakens the control:

1. **A level whose role nobody holds** — a company administrator may sign any level, and the error
   says so.
2. **A stranded or misconfigured chain** — change the stage `approver_role` through the existing RPC
   `update_workflow_stage_approver_role`, which is platform-admin only and refuses a blank role.
3. **A journal that should not proceed at all** — any user entitled to decide the current level may
   reject it, with a reason of at least five characters. The journal closes as `rejected` and
   nothing is posted.

There is no route that lets one person both raise and release a routed journal.

## Required evidence

* This specification, approved.
* Regression tests for the **permitted** action: a routed journal submits, each level approves in
  turn, the last posts exactly one balanced entry.
* Regression tests for the **prohibited** actions: the raiser approving any level; one person taking
  two levels; a wrong-role user signing; a hole in the sequence being signed; a direct insert into
  the approvals table.
* A run of those tests against a database.

## Evidence status

**Written, parse-checked, and NOT RUN.**

| Item | State |
|---|---|
| `supabase/migrations/20261124011700_fin_manual_journal_chain.sql` | Written. `platform_manual_journal_chain_state` and the gap detection were exercised against a live database while it was written; the full migration has not been applied. |
| `supabase/tests/test_fin_manual_journal_chain.sql` | Written, 45 assertions across 13 sections. **Never executed.** |
| `supabase/tests/test_fin_manual_journals.sql` §6c | Rewritten: the old assertion that a routed journal *cannot be submitted* is replaced by the assertion that it *waits for every level*. This is the visible record that the refusal was removed on purpose. **Never executed.** |

Not covered, and stated rather than discovered later:

* **Concurrent decisions at the same level.** The row lock on the journal should serialise them and
  the second should then be judged against the first, but this is untested, and the concurrency
  harness cannot run here (no Node ≥ 22, no `tsc`).
* **The UI.** `fin_manual_journals_awaiting_me()` provides the queue, but nothing has been
  demonstrated through a screen. This is why AE3 remains *not demonstrated* and AE4 remains
  *pending* regardless of this row.

## Three bugs found while building it

Recorded because each was a real defect in the first draft, caught before the migration was
committed:

1. **Wrong role for the level.** `chain_state` resolved the role from the stage the *amount* routes
   to rather than the stage for the level being signed. A 100,000,000 journal in a three-level chain
   would have demanded the level-3 role at level 1, telling every level-1 approver they held the
   wrong role. Caught against a live database.
2. **`required_level` written into `stage_id`.** The first draft inserted the level into the
   `stage_id uuid` column. Caught by reading the insert against the table definition.
3. **A gap meant anyone could sign.** A missing stage returns no role for that level, and a null
   role was read as "no role required", i.e. anyone. That silently turned a three-level chain into
   a two-level chain with a free signature in the middle. Now counted and refused.
