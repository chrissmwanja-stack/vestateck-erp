# Foundation Playbook

> **Note on this file:** it is not the original Foundation Playbook — that
> document was never committed to this repo, only referenced from it. This
> is a reconstruction of the phases other files point to
> (`supabase/MIGRATION_POLICY.md`, `supabase/seed.sql`,
> `supabase/scripts/strip-demo-data.sql`, and a comment in
> `supabase/migrations_archive/20260814055702_approval_assignments_unique_assignment.sql`),
> assembled so those references resolve to something. Treat the phase
> descriptions below as "what the rest of the repo implies this phase did or
> will do," not as a verbatim recovery of whatever the original said.
> Replace this note once the real document is located or rewritten.

## Phase 0 — Migration hygiene foundation (landed 2026-08-14)

Established the ground rules for everything added to `supabase/migrations/`
going forward: `supabase/seed.sql` as the single target for demo/test
account data, `supabase/MIGRATION_POLICY.md`'s numbered rules, and
`scripts/check-migration-policy.sh` + the `migration-policy` CI job to
check new migrations against those rules automatically.

## Phase 1.5 — Squash cleanup (not yet done)

A one-time, deliberate rewrite of the migration history to fix what Phase 0
intentionally left alone:
- `0001_init_core_schema.sql` and three other pre-Phase-0 migrations that
  seed `@test.local` accounts directly via `INSERT INTO auth.users`
  (Phase 0's rule 1 stops new instances of this, it doesn't rewrite the
  existing ones — rewriting them breaks shadow replay for anything that
  foreign-keys to those user ids).
- The grandfathered `remote_schema.sql` dumps in `supabase/migrations/`
  (see `MIGRATION_POLICY.md` rule 6) — replaced with hand-authored
  equivalents as part of the same squash, not patched individually.

**Status as of 2026-09-24:** still pending. The grandfathered-dump list in
rule 6 has grown from 3 to 7 files since Phase 0 landed, which makes this
squash more overdue, not less — see the note added to rule 6.

## Phase 3 — Tenant-scoped foreign keys

Backfilled a real `tenant_id uuid not null references tenants(id) on
delete cascade` constraint (not just the column) onto every tenant-scoped
table. `MIGRATION_POLICY.md` rule 5 names `hr_*`, `pmo_*`, `machines`, and
`sustainability_*` as tables that were missing this.

**Status as of 2026-09-24:** appears complete and is now enforced, not just
aspirational — `scripts/audit_tenant_fk.sql` runs in the `db-shadow-replay`
CI job on every push/PR and was confirmed clean (0 unconstrained
`tenant_id` columns) against production on 2026-08-18. Rule 5's "known gap
... not a pattern to repeat" wording predates that backfill; it describes
history, not a current gap.

## Phase 4 — Demo data hardening

Step 3: strip real-looking organization names and other demo/seed data
that shouldn't ship in a public repo (`supabase/scripts/strip-demo-data.sql`).

**Status as of 2026-09-24:** the script exists and runs, but git history
still contains the original real org names from before it was introduced —
that's a separate cleanup (a `git filter-repo` pass), not something
`strip-demo-data.sql` itself can fix retroactively.
