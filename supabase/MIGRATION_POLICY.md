# Migration policy

Rules for every file added to `supabase/migrations/` from this commit
forward. Established by Foundation Playbook Phase 0. See
`FOUNDATION_PLAYBOOK.md` at the repo root for why (that file is a
reconstruction, not the original — see its own header note).

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
   new files; reference the existing convention instead. That
   convention only stays safe if `seed.sql` never runs against the
   linked/remote project -- see the warning at the top of that file
   before running `supabase db reset` with `--linked`, or hand-running
   it via psql/Studio.

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
   Not just the column -- the constraint. `hr_*`, `pmo_*`, `machines`, and
   `sustainability_*` were missing this and were backfilled in Phase 3
   (confirmed clean against production 2026-08-18); this rule and the
   `scripts/audit_tenant_fk.sql` CI check exist so it doesn't regress, not
   because the gap is still open.

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
   `20260901135345_remote_schema.sql` were grandfathered as pre-dating
   this rule.

   **That grandfather list has since grown to seven files, not three:**
   `20260903112116_remote_schema.sql`, `20260904082722_remote_schema.sql`,
   `20260910113534_remote_schema.sql`, and `20260910133254_remote_schema.sql`
   all landed on `main` *after* this rule and its CI check existed. This
   isn't a checker bug -- `check-migration-policy.sh` does match on
   filename and does fire on new `remote_schema.sql` files (confirmed: the
   commit that added `20260910113534_remote_schema.sql` shows
   `migration-policy` as a **failing** check on GitHub). The actual gap is
   that `main` has no branch protection requiring that check to pass, so a
   red `migration-policy` run doesn't block the push. Until that's turned
   on (Settings -> Branches -> require status checks to pass, for
   `migration-policy` at minimum), this rule is advisory, not enforced,
   and the grandfather list will keep growing. Treat all seven as
   grandfathered for now -- rewriting them is Phase 1.5 (squash), not a
   one-off fix -- but do not add an eighth, and turning on branch
   protection is the real fix, not a longer list here.

7. **Run `scripts/check-migration-policy.sh` before you push.** CI runs
   it too (`.github/workflows/foundation-checks.yml`), but catching it
   locally is faster than waiting on a failed check.

8. **No `DROP COLUMN` or `DROP TABLE` on an existing table in a new
   migration.** `db-shadow-replay` applies migrations to an empty
   database, so a drop-then-recreate sequence looks harmless there --
   it's invisible on a database with no rows to lose. On a database
   *with* data (production), the same sequence silently destroys
   whatever was stored in that column or table before recreating it
   empty. This is exactly what happened in
   `20260904082722_remote_schema.sql` /
   `20260904090500_payroll_paye_nssf_workstream_f.sql`, which dropped
   and recreated `hr_payroll_items.{paye_amount,nssf_employee,
   nssf_employer}` back to back. Deprecate instead: rename the column
   to `<name>_deprecated`, stop reading/writing it in application code,
   and drop it in a separate, human-reviewed migration one release
   later, once you've confirmed nothing still depends on it.

## What this does not cover

This policy is about what goes **into** new migrations. It does not
retroactively fix `0001_init_core_schema.sql` or the other three
migrations that already seed `@test.local` accounts directly --
rewriting those breaks shadow replay for anything that FKs to those
user ids (see Foundation Playbook, "Why this order"). That cleanup is
Phase 1.5 (squash), done once, deliberately, not as an ongoing rule.
It also does not retroactively fix the seven grandfathered
`remote_schema.sql` dumps (rule 6) -- replacing them is part of the
same squash cleanup, not something to hand-patch in isolation.
