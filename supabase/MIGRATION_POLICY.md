# Migration policy

This file is the rulebook for `supabase/migrations/`. `scripts/check-migration-policy.sh` enforces the rules marked **(enforced)** against every migration file added since `origin/main`, and CI runs it on every push and pull request (`foundation-checks.yml`). Reviewers apply the rest.

The policy is referenced by `scripts/check-migration-policy.sh`, by `supabase/seed.sql`, and by the README. Rule numbers match the script's messages. Rules 3 and 7 are not written down anywhere in the repository, so they are not listed here; if you know their text, add it under its number.

## Enforced rules

**Rule 1 (enforced): no demo or test accounts in migrations.** A migration must not `insert into auth.users`. Demo and test accounts belong in `supabase/seed.sql`, which runs only locally.

**Rule 2 (enforced): no committed passwords.** A migration must not contain `crypt('<literal>', ...)`. Hashing a literal password commits that password to the repository.

**Rule 4 (enforced): no `FOR ALL` policies.** Row-level security policies must be written per command: `SELECT`, `INSERT`, `UPDATE` and `DELETE` each get their own policy.

**Rule 5 (enforced): tenant columns reference tenants.** A migration that adds a `tenant_id uuid not null` column must also contain a `references tenants(id)` foreign key in the same file.

**Rule 6 (enforced): no generated dumps.** Files named `*remote_schema.sql` (output of `supabase db dump` or Studio) are rejected. Write the actual change as a hand-authored migration. The three existing dump files are grandfathered.

**Rule 8 (enforced): no `DROP COLUMN`.** Deprecate first: rename the column to `<name>_deprecated`, stop reading it, and drop it in a separate migration in a later release.

**Destructive table drops (enforced).** A `DROP TABLE` on an existing `public` table is rejected unless the same file also creates a table. If a table is really being retired, the reviewer must confirm that with the owner, because the script cannot tell an existing table from one created earlier in the same file.

## Rules that apply by practice

**Applied migrations are never edited (fix forward).** Once a migration has run on a shared or live database, its file must not change. Supabase tracks migrations by their version (the timestamp prefix), so an edited file runs nowhere, and the database and the repository silently disagree. To change behaviour, add a new migration with a later timestamp that makes the change, and make it idempotent. Example: `20261016090000_ins_security_.hardening.sql` was applied live, so its follow-up is `20261016100000_ins_security_hardening_followup.sql`. *Proposed 16 October 2026 from that incident; confirm with the team.*

**Verify against a clean replay.** A new migration is checked by replaying every migration in order into an empty database and running the SQL tests (`supabase db reset`, then the `supabase/tests/*.sql` files with `psql -v ON_ERROR_STOP=1`). A migration that only works on a database that already has data does not count.

**Test every guard you add.** A new guard, grant or policy needs a test in `supabase/tests/` that checks it denies what it should. The security hardening test for `20261016090000` is the model: it checks the catalogue and makes real calls that must fail.

**Types follow the schema.** After a schema change, regenerate `packages/shared/src/database.types.ts` from a clean stack with the same Supabase CLI version as CI (currently 2.114.0). The drift check in `foundation-checks.yml` fails the build when the committed file differs from the migrations. On Windows, use `scripts/gen-types.ps1 -Local`.

**Seed data goes in `supabase/seed.sql`.** Demo tenants, users and sample records belong there, not in migrations. The seed is local only. Never apply it to a linked or production project.
