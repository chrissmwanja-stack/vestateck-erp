# Security catalog snapshot

`security-catalog.txt` is a deterministic fingerprint of the security-relevant
catalog state of schema `public`, produced by
`supabase/scripts/catalog_security_snapshot.sql`:

- schema `USAGE` / `CREATE` for `anon`, `authenticated`, `service_role`, PUBLIC
- per table / view / materialized view: RLS enabled and forced, `reloptions`
  (`security_invoker`, `security_barrier`, ...), effective privileges
- sequences, column-level grants
- per function: `SECURITY DEFINER`, `proconfig` (search_path pin), effective
  `EXECUTE` for each role above
- default privileges for objects created later

CI (`foundation-checks.yml`, step "Check security catalog snapshot") replays
every migration, regenerates the file and fails on any difference.

## When it fails

A diff means a migration changed one of those facts. Read the diff:

- **Unintended** (e.g. a `CREATE OR REPLACE VIEW` dropped `security_invoker`, a
  new function missing its `REVOKE`): fix the migration.
- **Intended**: regenerate and commit the snapshot in the same PR, so a
  reviewer sees exactly which grants moved:

  ```
  scripts/catalog-snapshot.sh postgresql://postgres:postgres@127.0.0.1:54322/postgres --update
  ```

Generate the committed file against the same Supabase CLI version CI pins, or
take it from the `security-catalog-snapshot` artifact of a green CI run.

## Checking production

The query is read-only, so it is safe against a linked project:

```
scripts/catalog-snapshot.sh "$PROD_DATABASE_URL" --check
```

Expect to triage a few differences the first time (for example `defacl` lines
for Supabase-managed roles). After that, any new difference means production
has drifted from the migrations, or the other way round.
