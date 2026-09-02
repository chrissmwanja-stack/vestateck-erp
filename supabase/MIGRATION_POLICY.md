# Migration policy

Rules for every file added to `supabase/migrations/` from this commit
forward. Established by Foundation Playbook Phase 0. See
`FOUNDATION_PLAYBOOK.md` at the repo root for why.

## The rules

1. **No `INSERT INTO auth.users` in a migration.** Demo/test accounts go
   in `supabase/seed.sql`, which `supabase db reset` runs automatically
   after migrations. A migration is permanent, replayed on every
   environment including production; `seed.sql` is not.

2. **No plaintext or near-plaintext passwords committed anywhere**,
   including inside `extensions.crypt('literal', ...)` calls. If a
   migration or seed file needs a demo login, the convention in this
   repo is `Tester123` for every account, documented once in
   `seed.sql`'s header comment -- do not repeat the literal string in
   new files; reference the existing convention instead.

3. **No dashboard-only SQL.** If you run something in the Supabase
   Studio SQL editor, Table Editor, or Auth panel that changes schema
   or seeds data, commit the equivalent migration (or `seed.sql` entry)
   the same day. `gm@test.local` and `pm@test.local` existed on the live
   project for two weeks with zero migration trace before this policy
   existed -- that gap is exactly what this rule prevents.

4. **No `FOR ALL` RLS policies on new tables.** Split into separate
   `FOR SELECT` / `FOR INSERT` / `FOR UPDATE` / `FOR DELETE` policies,
   even when the `USING` / `WITH CHECK` clause is identical across all
   of them. A single collapsed policy is harder to reason about and
   harder to tighten one verb at a time later.

5. **Every new tenant-scoped table gets a real foreign key**:
   `tenant_id uuid not null references tenants(id) on delete cascade`.
   Not just the column -- the constraint. Tables missing this today
   (`hr_*`, `pmo_*`, `machines`, `sustainability_*`) are a known gap
   being backfilled in Phase 3, not a pattern to repeat.

6. **No `supabase db dump`/Studio-generated `remote_schema.sql` files
   in `supabase/migrations/`.** These dump the entire remote catalog
   (thousands of lines of `DROP TRIGGER`/`DROP POLICY` followed by a
   full recreate) instead of the actual one- or two-statement change
   that was made. That makes shadow replay depend on dump-ordering
   luck, can silently undo a migration that landed between the dump
   and the apply, and buries the real change inside noise a reviewer
   won't read. If you made a change in Studio, write the equivalent
   hand-authored migration the same day (rule 3) -- don't dump the
   catalog as a shortcut. `20260824064800_remote_schema.sql`,
   `20260824110748_remote_schema.sql`, and
   `20260901135345_remote_schema.sql` are grandfathered (pre-date this
   rule); do not add a fourth.

7. **Run `scripts/check-migration-policy.sh` before you push.** CI runs
   it too (`.github/workflows/foundation-checks.yml`), but catching it
   locally is faster than waiting on a failed check.

## What this does not cover

This policy is about what goes **into** new migrations. It does not
retroactively fix `0001_init_core_schema.sql` or the other three
migrations that already seed `@test.local` accounts directly --
rewriting those breaks shadow replay for anything that FKs to those
user ids (see Foundation Playbook, "Why this order"). That cleanup is
Phase 1.5 (squash), done once, deliberately, not as an ongoing rule.
It also does not retroactively fix the three grandfathered
`remote_schema.sql` dumps (rule 6) -- replacing them is part of the
same squash cleanup, not something to hand-patch in isolation.
