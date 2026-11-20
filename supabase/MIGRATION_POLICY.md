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
   catalog as a shortcut. `20260824064800_remote_schema.sql` and six later dumps were grandfathered
   because they pre-dated this rule or landed before it was enforced. All seven
   were folded into the 2026-11 squash and now live only under
   `supabase/migrations_archive/2026-11/`; no `remote_schema.sql` remains in
   `supabase/migrations/`. `check-migration-policy.sh` matches on filename and
   fails any new one.

   Enforcement: as of 2026-11-17 `main` is protected on GitHub and requires the
   status checks `migration-policy`, `repo-hygiene`, `build`, `test`,
   `lint-ratchets`, `db-shadow-replay`, `insurance-concurrency` and `e2e`. The
   protection is enforced for non-admins, so an admin can still bypass a red
   check. (Read from GitHub's branch API; it is a repository setting, not
   something the code can pin, so re-check it if the rule seems not to bite.)

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
   `20260904090500_payroll_paye_nssf_workstream_f.sql` (both now under
   `migrations_archive/2026-11/`), which dropped
   and recreated `hr_payroll_items.{paye_amount,nssf_employee,
   nssf_employer}` back to back. Deprecate instead: rename the column
   to `<name>_deprecated`, stop reading/writing it in application code,
   and drop it in a separate, human-reviewed migration one release
   later, once you've confirmed nothing still depends on it.

9. **Applied migrations are never edited (fix forward).** Once a
   migration has run on a shared or live database, its file must not
   change. Supabase tracks migrations by version (the timestamp prefix),
   so an edited file runs nowhere, and the database and the repo silently
   disagree. To change behaviour, add a new migration with a later
   timestamp that makes the change, and make it idempotent. Example:
   `20261016090000_ins_security_.hardening.sql` was applied live, so its
   follow-up is `20261016100000_ins_security_hardening_followup.sql`.
   *Proposed 16 October 2026 from that incident; confirm with the team.*

10. **Every new `CREATE POLICY` names its role with `TO`.** A policy with
    no `TO` clause applies to `PUBLIC`, which includes `anon`. Write
    `to authenticated` (or `to service_role`, etc.) explicitly. The
    existing policies in the squashed baseline predate this rule and are
    not rewritten: since `20261112090000` `anon` holds no table privilege,
    so they cannot reach `anon` in practice. `scripts/check-migration-policy.sh`
    enforces this on new migration files, and
    `supabase/tests/test_anon_and_excess_table_privileges.sql` fails if `anon`
    ever regains table access.

11. **Every new migration filename starts with a valid UTC timestamp.**
    `YYYYMMDDHHMMSS_snake_case_name.sql`, with a real calendar date and every
    field in range: hour 00-23, minute 00-59, second 00-59. `20261117240000`,
    `20261117250000` and `20261117260000` used hour 24, which the Supabase CLI
    cannot parse (`migration list` shows the raw version instead of a date).
    They are applied, so they stay as they are; do not rename them. For an
    end-of-day slot use `235900`.

    The suffix is a *time*, not a counter. Four migrations on
    `feat/ins-accounting-acceptance` were numbered `20261120006000` to
    `20261120009000` after `005000`, which reads as minutes 60 to 90; the
    series only worked up to `005000`. They were renamed before merging, to
    `20261120235900` to `20261120235903`. To get several ordered slots on one
    day, step the hour (`010000`, `020000`, ...) or count up from `235900`
    (`235900`, `235901`, ...).

    `scripts/check-migration-policy.sh` enforces this on new migration files.
    It validates the whole value with `date(1)`, not just the digit count.

12. **Do not leave a trigger function without a trigger.** A function that
    `RETURNS trigger` can only be checked against the table its trigger is
    on. The "Static plpgsql lint (plpgsql_check)" step in
    `.github/workflows/foundation-checks.yml` does that, and for a trigger
    function with *no* trigger attached it raises `missing trigger relation`
    and fails the whole step. When a migration stops using a trigger function,
    drop it in that migration or the next:
    `drop function if exists public.<name>();`. Rule 8 is about columns and
    tables; dropping an unused function loses no data and is allowed. This
    happened with `ins_snapshot_bind_config_commission_only()`, left behind by
    `20261120235903` and removed by `20261120235905`.

    The way into that state is worth knowing. Two PostgreSQL behaviours were
    measured in that series (see the comments in `20261120235902` and
    `20261120235903`): `alter function ... rename to` does **not** repoint the
    triggers that call the function, and a trigger function cannot be called
    from another function ("trigger functions can only be called as
    triggers"). So to extend a trigger function, rewrite it as one function with
    `create or replace`; do not wrap a renamed copy of the original.

## Checklist for every new migration

The rules above say what goes into a migration. This is the order to work in
before you push one. CI enforces every step, but a red CI is a slower way to
learn it than doing it here.

1. **Replay locally from scratch:** `npx supabase@2.114.0 db reset --yes`
   (this applies every migration plus `seed.sql`, as CI does).
2. **Run the policy check:** `./scripts/check-migration-policy.sh origin/main`.
3. **Regenerate the types from the local stack, not from production:**
   `.\scripts\gen-types.ps1 -Local`, and commit the result. Run it after step 1,
   so the local database matches your migration. **Do not run it without
   `-Local`**: that reads the live project, which does not have your migration
   yet, so it silently writes the old types. CI regenerates from a fresh local
   replay and fails the `db-shadow-replay` job on any difference. Skip this only
   when the migration changes no table, column, view, enum or function signature
   (a data-only or body-only change), and say so in the PR.
4. **Run the SQL tests that touch what you changed**, and add one if you added
   behaviour: `psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/<file>.sql`.
   A test must fail by `RAISE EXCEPTION`; a `NOTICE: FAIL` fails the CI scan too.
5. **Check the web build:** `npm run build` (type errors from a changed
   `database.types.ts` show up here, not in the SQL jobs).
6. **Before you push a long-lived branch, diff it against `main`:**
   `git fetch origin && git merge origin/main`, then
   `git diff --stat origin/main` and read the file list. Every file in it
   should be one you meant to change. A branch built from an out-of-date
   working tree can commit old copies of files and silently revert fixes that
   are already on `main`. That happened on `feat/ins-accounting-acceptance`:
   `BankAdjustmentsPanel.tsx` went back to a foreign-key name that does not
   exist (so the panel's account picker loaded empty) and
   `bank-adjustments.spec.ts` went back to a version without the e2e fixes.
   Restore such a file with `git checkout origin/main -- <path>`.

## What this does not cover

This policy is about what goes **into** new migrations. It is not a review of
what the 2026-11 squash archived: the pre-November history, including
`0001_init_core_schema.sql` and the other early migrations that seeded
`@test.local` accounts directly, now lives only in `supabase/migrations_archive/`
for reference and must never be applied (see `SQUASH_RUNBOOK.md`). Rule 9 (fix
forward) is a convention reviewers apply; `check-migration-policy.sh` cannot see
whether a file was already applied somewhere.
