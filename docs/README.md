# Documentation index

Last reviewed: 21 November 2026 against `main` at `134da84`. When a doc and the code disagree, the code and its tests win; fix the doc in the same change.

## Root and platform

| File | What it is |
|---|---|
| `README.md` | Overview, module status, setup, testing and CI, known issues |
| `supabase/MIGRATION_POLICY.md` | Rules every new migration must follow (checked by `scripts/check-migration-policy.sh`) |
| `supabase/ROADMAP.md` | Dated log of the 2026-09-21 repo audit follow-ups (not rewritten as the repo grows) |
| `PHASE0_COUPLING_AUDIT.md` | Decision log for the shared-kernel and finance (D1 to D4) work |
| `FOUNDATION_PLAYBOOK.md` | Reconstruction of the foundation phases (see its own note) |
| `docs/BULK_IMPORT_NOTES.md` | Bulk-import file list and per-screen column specs |
| `supabase/SQUASH_RUNBOOK.md` | How to squash migrations into a new baseline and repair prod |
| `apps/web/e2e/README.md` | Playwright specs, what they cover and what they do not |
| `apps/web/docs/AUTHORIZATION_ARCHITECTURE.md` | Identities, RLS tiers, View-as, definer-function rules, separation of duties, and which test covers each rule |
| `supabase/catalog-snapshots/README.md` | The security catalog snapshot (grants, view options, RLS flags) and what to do when CI reports a diff |
| `.github/pull_request_template.md` | PR checklist (CI, migrations and types, tests, docs) |
| `docs/OPERATIONS.md` | Backups and the restore drill, monitoring, incident response, rollback, secrets inventory, post-deploy checks |
| `SECURITY.md` | How to report a vulnerability, and what is in scope |
| `.github/dependabot.yml` | Weekly dependency update PRs (npm and GitHub Actions) |

`docs/handoffs/` holds point-in-time hand-off notes: seven Finance notes (`FINANCE_A_PERIOD_CONTROLS.md`, `FINANCE_B_AUDIT_TRAIL.md`, `FINANCE_C_BANK_SUGGEST_CONFIRM.md`, `FINANCE_D_AS_AT_REPORTING.md`, `FINANCE_D4E_COMPLETION.md`, `FINANCE_E_END_TO_END_TRACE.md`, `FINANCE_E1_PROCUREMENT_SUBLEDGER.md`) written as each Finance item was finished (migrations dated 17 to 19 November 2026), and two TypeScript notes for the insurance cancellation work (`CANCELLATION_APPROVAL_HANDOFF.ts`, `CANCELLATION_CASH_HANDOFF.ts`). They are history, not maintained docs: where one disagrees with the code, the code wins.

## Insurance Brokerage (`docs/insurance-brokerage/`)

| File | What it is | Status |
|---|---|---|
| `INSURANCE_IMPLEMENTATION_STATUS.md` | What is implemented, and the test that covers it | **Operational reference**; updated in every insurance PR |
| `INSURANCE_ACCEPTANCE_PLAN.md` | Gates that must pass before production, with owners and evidence | **Operational reference** |
| `INSURANCE_DECISIONS_REGISTER.md` | Accounting, legal and regulatory decisions, owners, approval status | **Operational reference** |
| `ROADMAP.md` | Detailed history: decisions, accountant caveats, work plan, design notes | Detailed history; where it disagrees with the three files above, they win |
| `ANALYSIS.md` | Original design draft | Historical; the roadmap wins on conflict |
| `ACCOUNTANT_PACK.md` | Treatments and ledger map for the accountant | Draft, **not signed off**; section 9 lists changes since 16 October |
| `CURRENCY_REVIEW.md` | Currency touchpoint review (A3) | Closed 21 October |
| `POLICY_REVERSAL.md` | Restricted reverse-and-reissue | Built; pending accounting acceptance |
| `IN_FORCE_IMPORT.md` | Legacy portfolio import and opening balances | Built (steps 1 to 5: staging, commit, opening position, wizard, Playwright spec); pending accounting acceptance |

## Edge functions (`supabase/functions/`, config in `supabase/config.toml`)

| Function | Gateway JWT check | Purpose |
|---|---|---|
| `accept-invite` | on | Turns an invited person's pending invitation into app user and role rows |
| `bootstrap-admin` | on | One-time claim of the first platform admin (needs `BOOTSTRAP_ADMIN_CODE`) |
| `create-tenant` | on | Creates a tenant with service-role rights (no client INSERT policy exists) |
| `generate-ins-doc` | on | Renders an insurance document-pack PDF into the shared document store |
| `generate-po` | on | Renders and delivers a purchase order |
| `invite-user` | on | Sends a user invitation |
| `resend-invite` | on | Resends a pending or expired invitation |
| `send-operator-digest` | **off** | Scheduler endpoint; authenticates its own shared secret (`OPERATOR_DIGEST_SECRET`) and fails closed |

Functions that use the service-role key bypass RLS, so each re-checks the caller's tenant and access itself.

## CI gates that guard the repo

Described in the root `README.md` ("Testing & CI"): migration policy, merge-conflict markers, first-load bundle guard (`scripts/check-initial-load.mjs`), lint ratchets (`scripts/check-lint-ratchet.mjs`, baselines in `apps/web/eslint-*-baseline.json`), shadow replay with the SQL audits and security catalog snapshot, generated-types drift, and the insurance concurrency scripts.

## Keeping docs current

- Put a dated status line at the top of any working document and update it when you change the work it describes.
- Counts (migrations, test files) go stale first. Recount before quoting them: `ls supabase/migrations | wc -l`, `ls supabase/tests/*.sql | wc -l`.
- Nothing in `docs/insurance-brokerage/` is an accounting or legal sign-off unless a signed section says so.
- The platform's business day is Africa/Kampala (decision DR-46). In SQL use `business_today()` and `business_date(timestamptz)` (`ins_local_today()` and `ins_local_date()` are the same rule); in the web app use `apps/web/src/lib/businessDate.ts`. Never use `current_date`, `<column>_at::date` or `new Date().toISOString().slice(0, 10)`: tests fail on each.
