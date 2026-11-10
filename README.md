# VestaPortal

Multi-tenant enterprise platform covering Procurement, Finance, HR, IT Support,
Business Development, Law & Compliance, PMO, Machine Operation, Sustainability,
and Insurance Brokerage. Tenants are created from an industry template
(`general`, `construction`, `insurance`) that decides which modules, departments
and chart of accounts they start with. The flagship workflow is Procurement's configurable approval pipeline (request →
cost control → procurement → offer entry → approval → threshold branch → finance →
purchase order).

All monetary values across the platform are denominated in **UGX (Ugandan
Shilling)** by default. A handful of Business Development and cross-border
finance screens (tenders, contracts, invoices) support alternate currencies
(USD, EUR) as an explicit per-record choice, but UGX is the default in every
form and the assumed currency wherever no selector is shown. Each
company has a functional (ledger) currency, UGX unless set otherwise. The Finance
ledger and open-item subledger (receipts, payments, credit notes, bank
reconciliation) are multi-currency: dated, approved exchange rates, base amounts
on journal lines, realised gain or loss at settlement and period-end revaluation.
A settlement must be in its bank account's currency (`SETTLEMENT_CURRENCY`). See
`docs/insurance-brokerage/CURRENCY_REVIEW.md` and `ROADMAP.md` section 7 (A3).

## Structure

```
apps/web             React + Vite + TypeScript + MUI frontend
  src/modules/portals   Module UIs, one folder per business area (see below)
  src/features          Shared cross-module features (financial, procurement,
                         approvals, requests, offers, reports, IT support, etc.)
supabase/migrations   SQL schema and RLS policies — a single squashed baseline
                       (tenants, departments, users, workflow, requests,
                       approvals, and every module through mid-Aug 2026) plus
                       incremental migrations layered on top as work (the count grows;
                       see `ls supabase/migrations`, the baseline is the first file)
                       (supabase/migrations_archive/2026-11 holds the 172
                       pre-squash migrations, kept for history; see
                       supabase/SQUASH_RUNBOOK.md). Verified
                       2026-09-16: replaying every tracked migration from an
                       empty database matched production's tables, function
                       signatures and bodies, and RLS policies (including
                       USING/WITH CHECK clauses). View options were not
                       compared, and a later check found they differed: the
                       grandfathered remote_schema dumps reset
                       security_invoker on 15 views, and migration
                       20261106130000 restores it. Grants and other catalog
                       settings are not covered by that verification either.
                       See "Notes on the schema" below.
supabase/functions    Edge Functions: accept-invite, bootstrap-admin, create-tenant,
                       generate-ins-doc, generate-po, invite-user, resend-invite,
                       send-operator-digest (JWT verification is declared per
                       function in supabase/config.toml; see docs/README.md)
packages/shared       TypeScript types shared between the web app and edge functions
scripts               Repo tooling: migration-policy check, run-sql-tests.ps1 (local
                       per-file pass/fail for supabase/tests), and others
docs/                 Documentation index in docs/README.md. Insurance Brokerage:
                       ROADMAP.md (decisions, status, work plan), ANALYSIS.md
                       (original design draft), ACCOUNTANT_PACK.md (unsigned
                       sign-off pack), CURRENCY_REVIEW.md, POLICY_REVERSAL.md,
                       IN_FORCE_IMPORT.md (legacy portfolio import spec)
PHASE0_COUPLING_AUDIT.md   Decision log for the shared-kernel and finance (D1-D4) work
FOUNDATION_PLAYBOOK.md     Reconstruction of the foundation phases (see its own note)
docs/BULK_IMPORT_NOTES.md  Bulk-import file list and per-screen column specs
```

### Modules (`apps/web/src/modules/portals/`)

| Module | Status |
|---|---|
| Procurement → PO (`src/features/procurement`) | Most mature — request → cost control → offers → threshold approvals → PO → receipts → goods issue → stock, with email delivery via edge function and component test coverage |
| Finance / GL | Very strong — supplier/receivable invoices, advances, expenditure slips, petty cash, bank ops + reconciliation, full GL (chart of accounts, posting rules, period close), payroll disbursement, PAYE/NSSF/WHT/VAT reports, trial balance. Also the shared open-item subledger: bank accounts registry (operating vs client money, segregated by GL account), open items, settlements with allocations, credit notes, and reconciliation of settlements against bank statement lines (all immutable, voided by reversing journal). Deepest SQL test coverage in the repo |
| Platform / Admin | Complete — two admin layers. Platform admin console: companies, tenant impersonation, health, annual renewals, module registry and entitlements (nav and routes are gated on entitlement, e.g. Purchase Orders and Payment Approvals require procurement), industry templates (company creation wizard reads them from the database), invites/bootstrap. Company Admin shell (`/company-admin/*`): departments, organizations, members, invites, approval workflow admin, setup readiness. Plus delegations and accounting-period/chart admin |
| IT Support | Complete — tickets, SLAs, teams, access, assets, KB/FAQs, full RLS/RPC coverage |
| Business Development | Broad but uneven — leads, clients, opportunities, tenders, proposals fully surfaced (incl. report exports); some RPCs and deeper workflows (opportunity math, tender submission management) still landing |
| HR | Mostly built — employees, attendance, leaves, payroll, performance, recruitment, org chart; RLS coverage for compensation, team members and payroll approvers is in place (closed by the 20260819–20260821 migrations) |
| Law & Compliance | Real workflow — cases, contracts, compliance register, filings; contract approval via `submit_contract_for_approval`/`decide_contract` RPCs with decision audit trail, self-approval refused; filings run through a server-side `transition_filing` state machine |
| PMO | Real workflow — projects, tasks, milestones, resources, Gantt with dependencies/critical path; project approval RPCs plus a real time/cost ledger (`pmo_time_entries`, `pmo_cost_entries`) backing the budget-vs-actual report |
| Machine Operation | Real workflow — equipment, logs, fuel, maintenance; `transition_maintenance_request` state machine with an overdue sweep, and fuel/maintenance costs auto-post to GL |
| Sustainability | Operational — metrics, audits, certifications (with expiry sweep), initiatives; no targets/baselines or emission-factor computation yet |
| Insurance Brokerage (`modules/portals/insurance`) | Broad slice built; the accounting treatment is **not yet signed off by an accountant** (see `docs/insurance-brokerage/ACCOUNTANT_PACK.md`). Built: clients with KYC decisions, insurers, product lines, intermediaries (agents and sub-agents, no money yet); policies with branch, agent and transaction type, an insured-risk register and motor certificate stock, co-insurance shares and charges; a quotation pipeline (placing a quote creates the draft policy); a policy approval workflow (draft → pending approval → approved or rejected, and **bind requires an approved policy**); binding through RPCs only, posting one journal and creating the premium receivable and insurer payable in the open-item subledger. Renewals (120-day window, bulk drafts, outcomes, renewal notices); endorsements (proposals, Finance maker-checker posting, foreign-currency legs); cancellation with pro-rata calculation, approval and refund cash; restricted reverse-and-reissue (`docs/insurance-brokerage/POLICY_REVERSAL.md`); premium cash approvals, insurer remittances, the unremitted-premium report and a per-insurer remittance position. Commission is deferred at bind and recognised when a posted settlement fully pays the insurer's net item (reversed if that settlement is voided); earned commission stays in client money until a manager transfers it (`ins_transfer_earned_commission`, voidable, each side matched in bank reconciliation); per-insurer commission statements and an approved insurer/product rate matrix. Policies bound before `20261011090000` keep the old treatment (commission to income at bind). Claims follow a server-side state machine with an audit trail, reserve revisions with history, excess handling (four modes) and a document checklist; claim payments are per-insurer in one of two modes (insurer pays the client directly, or the brokerage pays through client money after the insurer's written confirmation). Insurer statement reconciliation, a production book, client statements and aged balances, a shared document store with a generated document pack (`generate-ins-doc`), and notifications. Multi-currency: policies bind and settle in their own currency at approved rates, with realised and unrealised FX (`docs/insurance-brokerage/CURRENCY_REVIEW.md`). Still open: the in-force portfolio import and opening balances (specified in `docs/insurance-brokerage/IN_FORCE_IMPORT.md`; step 1, staging and validation, is written but unmerged), commission recognition at placement and per-insurer settlement mode, a statutory charge catalogue, agent commission, client merge, period-close states, endorsement item cancellation (E4) and an insurance Playwright spec |
## Getting started

1. Install dependencies from the repo root:
   ```
   npm install
   ```
2. Copy `apps/web/.env.example` to `apps/web/.env` and fill in your Supabase
   project URL and anon key.
3. Apply the migrations in `supabase/migrations/` to your Supabase project with
   the Supabase CLI (`supabase db push`, or `supabase start` for a local
   stack). `supabase/migrations/` holds a squashed baseline
   (`20261031235900_squashed_baseline.sql`) followed by incremental migrations;
   they apply in timestamp order. Do not apply `supabase/migrations_archive/` —
   it is the pre-squash history, kept for reference only. New migrations must
   pass `scripts/check-migration-policy.sh` (see
   `supabase/MIGRATION_POLICY.md`; `DROP TABLE`/`DROP COLUMN` are banned).
   For a fresh database, `supabase/seed.sql` provides test tenants and accounts.
   Run `supabase migrations list` periodically to check local/remote drift — if a migration
   was ever applied directly against the database (SQL editor, hotfix, etc.) without a
   matching local file, it'll show up as an unmatched row in the `Remote` column.
4. Edge Function secrets (only needed if you deploy the functions): set
   `ALLOWED_ORIGINS` (comma-separated frontend origins; defaults to the Vite
   dev server), `BOOTSTRAP_ADMIN_CODE` (one-shot first platform admin), and,
   for the operator digest email leg, `OPERATOR_DIGEST_SECRET` (any long
   random string; the scheduler sends it in an `x-digest-secret` header) plus
   `RESEND_API_KEY` / `RESEND_FROM_EMAIL`. Example:
   ```
   supabase secrets set OPERATOR_DIGEST_SECRET=$(openssl rand -hex 32)
   ```
5. Run the web app:
   ```
   npm run dev
   ```

## Status

This is a live, actively developed platform with a running Supabase project.
Row Level Security is implemented per-module as each one matures — Procurement,
IT Support, the Finance open-item subledger and Insurance Brokerage have RLS/RPC
coverage that is exercised by dedicated SQL tests (`tenant_id =
get_my_tenant_id()` isolation, role-tier checks, `SECURITY DEFINER` RPCs that
refuse cross-tenant callers, no `anon` access); HR compensation, team-member and
payroll-approver tables were closed by the 20260819–20260821 migrations; the
remaining modules are at varying stages of hardening. Don't assume a table is
RLS-protected just because the platform is live — check the relevant migration
and its test before treating any given table as safe for broad client-side access.

Note that the baseline sets default privileges so every new table in `public`
gives `authenticated` full DML. A migration's `grant select` therefore does not
make a table read-only: RLS is the barrier, and a table with only a SELECT
policy (e.g. `ins_claim_events`) is read-only because of that policy alone.

As of 2026-09-16, the financial-write `SECURITY DEFINER` functions
(`post_journal_entry`, `import_bank_statement_lines`, and others) are no longer
`EXECUTE`-able by `anon` (unauthenticated) — Postgres's default grant-to-PUBLIC
had exposed them to direct RPC calls (`/rest/v1/rpc/...`). The CI exposure audit
(`supabase/scripts/audit_security_definer.sql`) keeps this visible; the only
intentionally anon-executable functions are `health_check`, `keepalive_ping` and
`get_platform_branding`.
`scripts/check-migration-policy.sh` also now rejects any new migration
containing `DROP COLUMN` or `DROP TABLE` on an existing object — see
`supabase/MIGRATION_POLICY.md` rule 8 — after a drop-then-recreate pair in
an earlier migration was found capable of destroying payroll statutory data
on any environment where a real payroll run had posted (production itself
was unaffected: no payroll run or GL posting had occurred at the time).

## License

Proprietary — all rights reserved (see `LICENSE`). The repository is public
for reference/visibility, not as an open-source release; no permission is
granted to copy, modify, or redistribute without Vestateck's consent.

## Health check & monitoring

`public.health_check()` is a trivial, anon-executable RPC (`select
public.health_check();` via `/rest/v1/rpc/health_check`) that does one
real DB read and returns `{status, checked_at}` — point an uptime monitor
(UptimeRobot, Better Stack, etc.) at it instead of just pinging
PostgREST's root, which only proves the edge is up, not the database.

## Testing & CI

`npm run build --workspace=apps/web` (`tsc -b && vite build`) and
`npm run test --workspace=apps/web` (Vitest) are the web checks. Vitest runs the test files under
`apps/web/src` and `packages` (the `test` job in `foundation-checks.yml` shows
the current passing count), and `db-shadow-replay` runs every SQL test file in
`supabase/tests/`. Counts are left out on purpose: they went stale with almost
every commit. Coverage
is concentrated where it matters most: Procurement, Finance/GL (including the
open-item subledger, credit notes and reconciliation), IT Support,
Platform/Admin and Insurance Brokerage's database layer have the deepest SQL
coverage; shallower modules (PMO, Machine Operation, Sustainability) have less.
The Insurance Brokerage screens have unit tests for their pure logic and component
tests for most pages (policy list, detail and new, cash panel, commission, quotes
and others). The insurance in-force import has a Playwright spec (`insurance-import.spec.ts`); the main policy money flow does not yet.

### SQL tests

Each file in `supabase/tests/` is a plain `psql` script, not pgTAP: it runs in
one `BEGIN … ROLLBACK`, prints `NOTICE: PASS: …` lines, and `RAISE`s on the first
failed assertion so `psql -v ON_ERROR_STOP=1` exits non-zero. Run them only
against a fresh **local** stack, never a linked project.

- CI runs every file (see `foundation-checks.yml`).
- Locally on Windows, `scripts/run-sql-tests.ps1` runs every file inside the
  `supabase_db_erp-platform` container and prints PASS/FAIL per file with a
  count of PASS lines. If you use `supabase test db` instead, its pgTAP runner
  reports "No plan found in TAP output" for these files and ends with
  `Result: FAIL` even when they pass; judge a file by its exit status
  (`Wstat: 768`/"Dubious" marks a real failure).
- A test failing with "function does not exist" right after you pulled new
  migrations usually means your local database is behind: run
  `supabase db reset` before debugging.
- The insurance security tests (`test_ins_security_hardening.sql`, `test_ins_authz_catalog.sql`)
  check the grants on every insurance function and real cross-tenant denials; run them
  after any change to an `ins_` or `platform_ins_` function.
- Some tests print `GAP:` notices. A gap notice never fails the run; it records
  something the schema currently allows but probably should not
  (`security_authorization.sql` and `test_ins_core.sql` use this convention).
  When a gap is fixed, its probe prints PASS instead.

Migrations follow `supabase/MIGRATION_POLICY.md`. In particular, a migration that
has already been applied to a shared or live database is never edited; a fix goes
in a new migration with a later timestamp. The generated types file is checked for
drift against the migrations, and that check blocks the build.

Two GitHub Actions workflows run on every push/PR to `main`:
`foundation-checks.yml` (migration policy diff, build+typecheck, unit tests,
from-scratch migration replay against a local Supabase stack, the tenant_id
FK audit from `supabase/scripts/audit_tenant_fk.sql`, the SECURITY DEFINER
exposure audit from `supabase/scripts/audit_security_definer.sql`, and every
`supabase/tests/*.sql` functional test) and `e2e.yml` (eight Playwright specs
in `apps/web/e2e/`: procurement happy path and threshold branch, finance
invoice payment, payroll approve/reject and disbursement, BD proposal
approvals, and company-admin member/invitation and organization setup). A third
workflow, `supabase-keepalive.yml`, calls `keepalive_ping()` with the anon key on a
schedule (see `20261029053936` and `20261106120000`).

### Local UAT tenant

`supabase/seed.sql` section 6 creates Pearl Risk Brokers Ltd (UAT), a fictional insurance
brokerage with a full chart of accounts, users, bank accounts, insurers, clients, bound and
draft policies, and a claim. It is built with the app's own RPCs and is local only; the
logins use the public `Tester123` password. Sign in as `ins.manager@test.local` to walk
through the insurance flows.

## Known issues

- **Insurance — commission sign-off and legacy policies.** Commission is now
  deferred at bind and recognised when the insurer's net item is fully paid, and
  a manager moves earned commission out of client money with a transfer batch
  (see the module table). The remaining caveats: the accountant has not signed
  off the treatment (open questions in `docs/insurance-brokerage/ANALYSIS.md`; the draft sign-off pack is `docs/insurance-brokerage/ACCOUNTANT_PACK.md`);
  policies bound before `20261011090000` keep the old treatment and are not
  backfilled; recognition counts payments only, so a credit note on an insurer
  item does not make it "fully settled"; and bound-policy corrections remain
  "reverse and re-issue".
- **Insurance — foreign currency is built but not yet used by a real tenant.**
  Policies bind in their own currency at the approved inception-date rate
  (`FX_RATE_MISSING` without one) and the currency review is closed
  (`docs/insurance-brokerage/CURRENCY_REVIEW.md`), but the accountant has not
  signed off the FX treatments, and the `generate-ins-doc` PDFs still need a
  first look on a real policy (they render on the deployed Deno stack).
- **Insurance — aged balances are bucketed in the browser.** The client statement
  rows are aged client-side from the bound date; server-side as-of reporting and
  pagination for the production book and statements are not built.
- `xlsx` (SheetJS) is installed from SheetJS's own patched tarball
  (`https://cdn.sheetjs.com/xlsx-0.20.3/xlsx-0.20.3.tgz`, 0.20.3) rather than
  the abandoned npm registry release (0.18.5), which carries an unfixed
  prototype-pollution and ReDoS advisory. Trade-off: `npm audit` and
  Dependabot cannot see inside a URL dependency, so check
  https://cdn.sheetjs.com for new releases manually when bumping.
- The `supabase/migrations_archive/` seed-account data previously named real
  Ugandan companies and government agencies (URA, KCCA, etc.) with invented
  contact people; the working tree was neutralised to fictitious org names
  on 2026-09-16. Older git commits still contain the originals — a full
  purge needs a `git filter-repo`/BFG history rewrite, not yet done.
- Icon-only `IconButton`s across the app now carry `aria-label` (fixed
  2026-09-16 — was the top accessibility gap; screen readers previously
  announced these as unlabeled "button"). Accessibility is otherwise still
  largely unaudited beyond this fix.

## Notes on the schema

- Every tenant-owned table carries a `tenant_id` column so RLS can scope access later.
- `workflow_stages.next_stage_low_id` / `next_stage_high_id` encode the threshold branch
  (e.g. Control Chief/Manager approval → Finance directly, or → Project Manager →
  Deputy General Manager → Finance) without hardcoding it in application code.
- Rejections are terminal: `requests.status` moves to `rejected` at whatever stage it
  died on. There is no automatic bounce-back; the initiator submits a new request.
- Delegation (`approval_delegations`) is capped at the delegator's own authority —
  the delegate simply steps into the delegator's existing `approval_assignments`
  threshold for the duration of the delegation.
- `material_catalog` (and its lookup tables `material_types`, `material_groups`) enforce a
  unique `(tenant_id, code)` constraint — material codes are stable business keys per tenant,
  not just free text. Seed data for the Test Company tenant (6 sample materials across
  Consumable/Equipment types) lives in a dedicated, idempotent migration for local dev and
  demo purposes.
- Bulk-import tooling (Employees, Accounts, Equipment, Leads) shares one RFC4180 CSV parser
  and a reusable `BulkImportDialog` (validate → preview per-row errors → import full file →
  per-row results). See `docs/BULK_IMPORT_NOTES.md` for the file list and per-screen column specs.
- The Finance open-item subledger (`fin_open_items`, `fin_settlements`,
  `fin_allocations`, `fin_credit_notes`, `fin_credit_applications`, view
  `fin_open_item_balances`) is append-only: rows are never edited, a void posts a
  reversing journal and frees the allocations, and a settlement must be fully
  allocated when recorded. Other modules create open items through the internal
  `fin_create_open_item`, which clients cannot call.
- Insurance tables (`ins_*`) are written through RPCs only. The RPCs set a
  transaction-local flag (`ins.via_rpc`) that the guard triggers check, so direct
  inserts and status changes by a client are refused even where RLS would allow
  the row. The flag stays on for the rest of the transaction; the SQL test clears
  it before probing the guards.
- `journal_entries.source_type` is a CHECK list that each module widens by
  dropping and re-adding the constraint. When adding a source type, start from the
  latest migration's list so no existing value is dropped.