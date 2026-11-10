## What and why

<!-- One or two sentences. -->

## Checks

- [ ] CI is green on this branch (all jobs, including `db-shadow-replay`, `e2e` and `insurance-concurrency`)
- [ ] **If this adds a migration:** replayed locally with `db reset`, and regenerated types with `.\scripts\gen-types.ps1 -Local` (never without `-Local`), or the migration changes no schema/signatures (say so here)
- [ ] New or changed behaviour has a test (SQL test that fails by `RAISE EXCEPTION`, Vitest, or e2e)
- [ ] Docs updated in the same change if a count, status or behaviour they state is now different

See `supabase/MIGRATION_POLICY.md` ("Checklist for every new migration").
