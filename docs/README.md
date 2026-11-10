# Documentation index

Last reviewed: 7 November 2026 against `main` at `04bf056` plus the unmerged in-force import step 1. When a doc and the code disagree, the code and its tests win; fix the doc in the same change.

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

## Insurance Brokerage (`docs/insurance-brokerage/`)

| File | What it is | Status |
|---|---|---|
| `ROADMAP.md` | Decisions, accountant caveats, work plan, status snapshot (section 7b) | Current |
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

## Keeping docs current

- Put a dated status line at the top of any working document and update it when you change the work it describes.
- Counts (migrations, test files) go stale first. Recount before quoting them: `ls supabase/migrations | wc -l`, `ls supabase/tests/*.sql | wc -l`.
- Nothing in `docs/insurance-brokerage/` is an accounting or legal sign-off unless a signed section says so.
