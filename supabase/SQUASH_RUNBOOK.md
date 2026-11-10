# Migration squash runbook

How to collapse old migrations into a new baseline, and how to repair production afterwards. Written after the 2026-11 squash (`20261031235900_squashed_baseline.sql`, 172 migrations archived to `supabase/migrations_archive/2026-11/`). When this and `scripts/squash-2026-11.ps1` disagree, the script wins; fix this file in the same change.

## What is kept, and why

Only two files drive a squash:

| File | Role |
|---|---|
| `scripts/squash-2026-11.ps1` | Does the whole squash and proves it (see below). Copy it to `squash-<yyyy-mm>.ps1`, then change `$tag`, `$cutoff`, `$baseline`, `$archive`. |
| `scripts/squash/baseline-post.sql` | Hand-maintained block appended to the generated dump (things `pg_dump` cannot express). Edit this, never the baseline file. |

Everything else the 2026-11 run produced (fingerprint patches, ACL generators, one-off diagnostics) was either inlined into the script or was scratch work. It is in git history before the cleanup commit if ever needed. Do not re-add scratch files to the repo root or `scripts/squash/`.

The generated baseline (`supabase/migrations/<cutoff-1min>_squashed_baseline.sql`) is output, not source. Never hand-edit it.

## When to squash

When replay time or migration count hurts (`supabase start` and the `db-shadow-replay` / `e2e` / `insurance-concurrency` CI jobs all replay everything). Not before a release, and not while open branches carry migrations (see "Branches").

## Part 1: squash (local, no production contact)

1. Merge or close open PRs that touch `supabase/migrations/`. Anything left will conflict (see "Branches").
2. Start from a clean `main`: `git pull`, `git status` clean, CI green on that commit.
3. Start the local stack with the current (old) layout fully applied:
   ```
   npx supabase@2.114.0 start
   npx supabase@2.114.0 db reset --yes
   ```
4. From the repo root (the script refuses to run elsewhere): `powershell -ExecutionPolicy Bypass -File scripts\squash-2026-11.ps1`
5. The script creates the safety tag, archives pre-cutoff migrations, dumps the pre-cutoff schema plus reference data, appends `baseline-post.sql` and generated privileges, replays `baseline + tail`, then compares a catalog fingerprint of the old layout (A) with the new one (B).
   - **`CATALOG EQUIVALENT.` is the only pass.** Any other ending writes `squash-catalog-diff.txt` (gitignored) listing `OLD ONLY` / `NEW ONLY` objects.
   - Row counts are informational only (audit/log tables may legitimately differ).
   - It is re-runnable if it fails before the final `db reset`. If it fails after, restore the old tree (`git checkout -- supabase/migrations supabase/migrations_archive`), `db reset --yes`, then re-run.
6. Push the safety tag, because the script only creates it locally: `git push origin pre-squash-2026-11`. Check it points at the last pre-squash commit: `git rev-parse pre-squash-2026-11^{commit}`.
7. Open a PR with the squash. CI on that PR must be green on **all** jobs (`db-shadow-replay`, `e2e`, `insurance-concurrency` replay from scratch and are the real test). Regenerate `packages/shared/src/database.types.ts` if the types check fails (`scripts/gen-types.ps1`, which writes UTF-8).

## Part 2: production repair (only after Part 1 is merged and green)

Production's `supabase_migrations.schema_migrations` still lists the archived versions as applied. The repair tells it those are gone and the baseline is applied, without running any SQL against the data.

**Backup first.** Do not skip; `migration repair` edits the history table and cannot be undone by re-running anything.

```
mkdir backups                      # keep this OUTSIDE the repo or gitignored
# full-fidelity logical backup (use the direct/session connection string)
pg_dump "$PROD_DB_URL" -Fc -f backups/prod-pre-squash.dump
# the history table on its own, so the repair can be reversed by hand
psql "$PROD_DB_URL" -c "\copy (select * from supabase_migrations.schema_migrations order by version) to 'backups/schema_migrations.csv' csv header"
```

Also confirm a Supabase dashboard backup or PITR point exists from just before the change. Storage object files are not in the database dump; they are untouched by this procedure, but note it if you rely on the dump as your only copy.

Then, with the repo on the merged squash commit:

1. `git pull`
2. Link to prod (`npx supabase@2.114.0 link --project-ref <ref>`) and record the current state: `npx supabase@2.114.0 migration list > backups/migration-list-before.txt`
3. Mark every archived version reverted. Derive the list from the archive directory rather than copying it by hand:
   ```
   for v in $(ls supabase/migrations_archive/2026-11 | cut -d_ -f1 | sort -u); do
     npx supabase@2.114.0 migration repair --status reverted "$v"
   done
   ```
   (The script also prints this list when it finishes.)
4. `npx supabase@2.114.0 migration repair --status applied 20261031235900`
5. `npx supabase@2.114.0 migration list` should now show the baseline applied and the tail migrations pending or applied exactly as before. Then `npx supabase@2.114.0 migration up`.

**Never run `supabase db push` before step 3.** It sees the archived files as not applied and tries to replay them on top of production.

Verify afterwards: `migration list` shows no remote-only or local-only rows, the app loads, and `supabase/scripts/audit_tenant_fk.sql` and `supabase/scripts/audit_security_definer.sql` return clean against prod (read-only).

Rollback: restore `schema_migrations` from `backups/schema_migrations.csv` (the data itself was never touched), or restore from the dump if anything else went wrong.

## Branches

A branch cut before the squash that adds or edits migrations will conflict with the new layout, because the files it was built on now live in `migrations_archive/`.

- **Fully merged branches** (0 commits ahead of `main`) just get deleted: `git push origin --delete <branch>`.
- **Branches with real work:** rebase onto the squashed `main`, drop any migration files that already exist under `migrations_archive/2026-11/`, keep only your own new ones, and make sure their timestamps are later than the latest tail migration. Then re-run `scripts/check-migration-policy.sh origin/main`.
- Announce the squash before running Part 2 so nobody pushes a pre-squash migration afterwards.

## After

- Update the migration counts in `README.md` and the "Last reviewed" line in `docs/README.md`.
- Run `npm run lint:any --workspace=apps/web` and the full CI once more on `main`.
