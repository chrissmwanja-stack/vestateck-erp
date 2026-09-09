# E2E smoke tests

Playwright tests for the 3 money-flow paths, run against a real Supabase
backend (no mocking): **Procurement** (request → offer entry → PO),
**Finance** (supplier invoice → cash/bank settlement), and **Payroll**
(run → approval → disbursement). These are separate from the Vitest
component-test suite (`npm test`) and are not wired into CI yet — run them
explicitly.

## One-time setup

```bash
cd apps/web
npm install
npx playwright install --with-deps chromium
```

## What they need to run

1. **Your own local `supabase start` stack, seeded via `supabase db reset`.**
   Do **not** point these at a live/linked project — `supabase/seed.sql`
   has a hard warning against ever being applied there (the seeded
   password is public in this repo).

   ```bash
   supabase start        # boots the local stack if not already running
   supabase status        # copy the API URL and anon key it prints
   supabase db reset      # (re)applies migrations + seed.sql locally
   ```

   Then, in `apps/web/`, copy `.env.e2e.example` to `.env.e2e` and paste
   in those values. `playwright.config.ts` loads `.env.e2e` and passes it
   to the `npm run dev` server it boots for the test run — it does **not**
   touch `apps/web/.env`, so your normal day-to-day dev setup (which may
   point at a live project) is untouched.

   If you already have a `npm run dev` running on :5173 from earlier,
   **stop it first** — Playwright will otherwise reuse that already-running
   instance (started with whatever `.env` said at the time) instead of
   booting a fresh one with `.env.e2e` applied.
2. **Seeded @test.local accounts**, all with password `Tester123` unless
   overridden (see `e2e/utils/auth.ts`):
   `cce@test.local`, `cost.control@test.local`,
   `procurement.offer@test.local`, `procurement@test.local`,
   `finance@test.local`, `hr@test.local`, `pm@test.local`.
3. **`pm@test.local` is seeded as a payroll approver** directly in
   `supabase/seed.sql` (payroll approval rights are a separate grant
   from job title/`approval_assignments`, via `/hr/admin/payroll-approvers`
   normally). No manual step needed as long as seed.sql has been applied.
4. None of the seeded accounts have MFA enabled. If you've since enrolled
   one of them in TOTP, the login helper doesn't handle the challenge
   screen — use a non-MFA account or extend `loginAs()`.

## Running

```bash
# against your local dev server (starts `npm run dev` automatically)
npm run test:e2e

# against an already-running instance (e.g. a deployed preview)
E2E_BASE_URL=https://your-preview-url npm run test:e2e

# interactive UI mode, useful while writing/debugging a spec
npm run test:e2e:ui
```

Traces, screenshots, and video are captured only on failure
(`playwright-report/`, `test-results/` — gitignored).

## Notes on how these are written

- Tests correlate a request/invoice/run across screens by a **unique
  marker string** (timestamped description, invoice number, or period)
  rather than a database id, since the UI itself doesn't surface ids on
  approval queues — matching what a human doing the same smoke check
  would actually see.
- Dropdowns that depend on environment-specific seed data (cost centers,
  vendor accounts, organizations) select **whichever option comes up
  first** rather than a hardcoded name, so the specs aren't coupled to
  one tenant's specific seed rows.
- The payroll spec derives its period from the current date, so reruns in
  a new calendar month won't collide with a prior run. Reruns *within*
  the same month will hit whatever duplicate-period validation the
  backend applies — clear out the prior test run first, or run it once
  per month.
- `fullyParallel: false` / `workers: 1` in `playwright.config.ts` is
  deliberate: each spec is a single multi-role workflow moving one
  record through several approval stages, not independent parallelizable
  cases.