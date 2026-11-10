# In-force portfolio import and opening balances

Status: built, updated 10 November 2026 (originally a draft specification of 7 November). **Option A chosen (7 Nov 2026).** All five build steps exist: staging, mapping profile and validation (`20261107140000_ins_import_staging.sql`), policy commit (`20261107160000`), opening position and reconciliation (`20261108030000`, with prerequisites and fixes in `20261109090000`, `20261109100000`, `20261109110000`), the import wizard (`ImportWizard.tsx`) and the Playwright spec (`apps/web/e2e/insurance-import.spec.ts`). SQL tests: `test_ins_import_staging.sql`, `test_ins_import_commit.sql`. Treatments in section 3 are working decisions, not an accountant's sign-off (see `ROADMAP.md` section 9).

Source: a spreadsheet exported from a legacy broker system. We have no sample yet, so section 2 defines our own canonical template. A mapping step (section 4, step 1) adapts the real export to it once we have headers.

---

## 1. Why the existing bulk import is not enough

- `BulkImportDialog` inserts rows straight into a table from the browser. Insurance writes go through RPCs with `ins_via_rpc` guards.
- A policy becomes `active` only through `ins_bind_policy`, which posts the client receivable, the insurer payable and the deferred commission, needs an approved policy, and needs an issued certificate for motor lines. Running it on migrated policies would duplicate balances already in the legacy books and force fake approvals.

So migrated policies enter through a dedicated import path that posts no per-policy bind journal.

## 2. Canonical import template

One workbook, one sheet per file below (or one CSV each). Dates are ISO `YYYY-MM-DD`. Amounts are plain numbers in the policy currency.

**policies** (one row per policy, current values after endorsements)

| Column | Required | Notes |
|---|---|---|
| legacy_policy_no | yes | Becomes `policy_no`. Unique per tenant. |
| client_name, client_tax_id | name or tax id | Match by tax id when it finds exactly one client, otherwise by exact name (case-insensitive) against the client master. `bd_clients` has no client number. Unmatched or ambiguous clients are listed, not auto-created. |
| insurer | yes | Matched by name or code. |
| product_line | yes | Matched by name or code. |
| inception_date, expiry_date | yes | `expiry > inception`. |
| currency | yes | ISO code. |
| sum_insured | no | |
| gross_premium | yes | Total billed to the client. |
| commission_amount or commission_rate_pct | yes | One of the two; the other is derived. |
| branch, agent | no | Matched to existing dimensions if present. |
| risk_description, notes | no | |

**receipts** (history only): `legacy_policy_no, receipt_date, reference, amount`.

**remittances** (history only): `legacy_policy_no, remit_date, reference, amount`.

**shares** (co-insured policies only): `legacy_policy_no, insurer, share_pct`.

**control_totals**: one row per currency with policy count, gross premium, commission, receipts to date, remittances to date, receivables, insurer payables and unearned commission, taken from the legacy ledger or reports at cut-over.

## 3. Treatments (working decisions)

1. **Earned commission.** Commission earned up to the cut-over date is reflected in the opening position, with the prior-period result flowing into opening retained earnings. It is not posted as a standalone equity entry, and it is never recognised again under the new schedule. Only the unearned remainder is carried forward as deferred commission. Each policy carries a reconciliation line showing earned and unearned.
2. **Partially paid policies.** Import the full billed amount and the receipts and remittances to date. Show the outstanding receivable (billed minus receipts). Receipts and remittances are stored as history and reconcile to the opening ledger. They are **not posted a second time**, because their cash effect is already in the opening bank balances.
3. **Policy version.** Migrated policies carry accounting-policy version 1 and are not restated. A migrated policy never changes version silently.

### 3.1 Two conflicts with the current build (need your decision)

**a. How "earned" is defined.** Decision 1 reads as time-apportioned (earned over the policy period). The live model is event-based: commission is credited to unearned commission at bind and recognised as income when the insurer's net item is fully settled (`20261011090000_ins_commission_deferral.sql`). A time schedule is the Phase B re-baseline in `ROADMAP.md`, which is not built. If migrated deferred balances sit under the live rule, the first insurer settlement after go-live would recognise the whole entry. So the choice is:

- **Option A (chosen 7 Nov 2026):** use the live rule. A migrated policy whose insurer net is fully remitted at cut-over is already earned (opening position). Otherwise its commission is carried as one `deferred` entry for the unearned remainder, recognised when the insurer item is settled. No new accounting engine is needed.
- **Option B:** time-apportioned. Build the Phase B commission recognition and schedule first, then import against it.

Per-policy time-apportioned earned amounts can still be computed and shown on the reconciliation as information, so Option A can be reviewed against Option B before sign-off.

**b. Version stamping.** The version is stamped from the posting date through `platform_accounting_policy_version(tenant, date)`. A policy loaded now would be stamped with whatever version is approved today, not 1. The import needs an explicit, audited override to version 1 for migrated rows (a session marker honoured by the stamping trigger, available only to the import RPC), plus a test that a version-2 tenant still stores 1.

## 4. Design

1. **Mapping.** An import profile maps legacy headers to the canonical columns (saved per tenant). The wizard offers it after upload.
2. **Staging.** `ins_import_batches` (tenant, cut-over date, status, uploaded by, control totals, accounting-policy version = 1) and `ins_import_rows` (batch, sheet, line, raw JSON, mapped values, resolved IDs, errors). Nothing touches live tables yet. RPC-only writes, tenant RLS, cross-tenant denial tests, and an entry in the authorisation catalogue test.
3. **Validation RPC.** Checks:
   - duplicate or existing policy numbers
   - unknown insurer, product line or client
   - dates and positive amounts
   - `commission + net = gross`
   - receipts not exceeding gross premium, remittances not exceeding net premium
   - share totals of 100 percent
   - currency has an approved rate at the cut-over date where the tenant is not UGX

   It returns a dry-run report per row and per batch.
4. **Commit RPC (policies).** One transaction. Creates policies as `active` flagged with the batch ID and `migrated_at`, using a marker like `ins.binding_policy` so the guards allow it. It skips the approval workflow and certificate checks. It posts no bind journal. Failure rolls back the whole batch.
5. **Opening journals.** One balanced journal per batch, dated at the cut-over date, with its lines split by currency (the journal's balance check is then satisfied currency by currency, so no FX rounding line is involved):
   - client receivable open items per policy, carrying the original bound date so ageing works
   - insurer payable open items per policy and share
   - unearned commission, per policy, as `ins_commission_entries` (status `deferred`; for Option A only policies whose insurer net is not yet fully paid)
   - client-money bank balances, taken from control totals
   - the offset to an `opening_balance_clearing` account, which must net to zero after commit

   Receipts and remittances are written to history tables only and posted nowhere.

   *As built (10 Nov 2026, `20261110120000_ins_import_opening_from_history.sql`).* Legs 1-3 are live and computed from the imported payment history rather than the policy header: receivable is billed minus receipts, payable is each share's net premium minus the remittances allocated to it, and commission is earned (to `retained_earnings`, account 3200) for any share fully remitted at cut-over, deferred otherwise. `journal_entries_source_unique` allows one opening entry per batch, so a batch containing several currencies posts one journal with per-currency lines, not one journal per currency. Remittances are recorded against the policy, so they are allocated across a co-insured policy's shares in proportion to each share's payable, the last share taking the rounding remainder; per-insurer remittance detail in the template would remove the approximation. Staged receipts and remittances are promoted into `ins_import_receipts` / `ins_import_remittances` by `ins_import_commit_policies`, in the transaction that creates the policies (`20261110140000`), so a batch imported through the wizard carries its history before anything is posted; `ins_import_record_history` stays as the adjustment path and shares the same rules. Leg 4 (bank balances from control totals) shipped on 10 Nov in `20261110190000_ins_import_client_money_bank.sql`: the float the history implies is receipts minus remittances per currency, the client-money bank account (`client_money_bank`, 1020 in the template) is debited with the balance the reviewer counted at cut-over, and `opening_balance_clearing` carries only what the history cannot explain — so the clearing account nets to zero whenever the counted balance and the history agree, and shows the gap in a named account when they do not. The leg stays optional: a batch that records no balance posts exactly as before. The counted balance is a control total like the others, so reconciliation compares it with the float before posting and a disagreement blocks the commit until someone other than the uploader approves it.
6. **Reconciliation.** Commit is refused unless the staged totals match `control_totals` per currency, or each difference is explained and approved by someone other than the uploader. After commit, a report compares open items by account, the opening journal and the legacy totals, and lists the per-policy earned and unearned split.
7. **UI.** Upload, map, validate (error table with downloadable rejects), enter control totals, review reconciliation, commit. Replaces nothing in `BulkImportDialog`; reuses `csvParser` and `xlsxParser`.

*As built (10 Nov 2026, `20261110170000_ins_import_control_totals.sql`).* The staged `control_totals` sheet is copied into `ins_import_batches.control_totals` by a trigger on the staged rows, so there is no separate sync step to forget; the canonical form is one object per currency holding the measures the sheet actually supplied (a missing measure stays absent, not zero, and the reconciliation reports it as `match = null` — "not recorded" — instead of a false difference). Reconciliation is computed per currency from one function (`ins_import_control_rows`) that reads the staged book before commit and the typed history after it. A recorded difference blocks the commit through a trigger on the batch, and `ins_import_override_control_totals` lets a manager who did not upload the batch approve exactly the differences they were shown: the approval stores that difference set and stops applying as soon as the numbers move. Totals remain optional — a batch without the sheet commits as before — but once supplied they are binding.

*As built (10 Nov 2026, `apps/web/src/modules/portals/insurance/pages/admin/ImportWizard.tsx`).* The wizard stages the whole workbook, not just its first sheet: `parseXlsx` returns every sheet (`ParsedWorkbook.sheets`) and the wizard feeds whichever of policies, receipts, remittances, shares and control_totals are present to `ins_import_stage_rows`. The commit step reconciles before committing — "Compare with control totals" reads the same `ins_import_reconciliation` the SQL report uses, and the three states are rendered differently, so a measure the reviewer never supplied reads "not recorded" rather than `DIFF`. When a total genuinely disagrees the wizard offers the honest way out instead of an RPC name: a reason (at least 10 characters, enforced by the button and again by the server) and an "Approve difference" button that calls `ins_import_override_control_totals`. Because the approver must be someone other than the uploader, the batch id travels in the URL (`?batch=`), so the uploader can send the approver a link and the wizard reopens on the step the batch's status implies; without that the two-person rule would exist in SQL and be unreachable through the UI. `apps/web/e2e/insurance-import.spec.ts` builds a real four-sheet workbook and covers both paths (totals that agree through to the posted ledger, and a difference that refuses the commit until a second manager explains it).

## 5. Build order

1. Staging tables, mapping profile and validation RPC (no posting, safe to ship). — built (`20261107140000`).
2. Policy commit with the version-1 override. — built (`20261110120000`, history promoted by `20261110140000`).
3. Opening journals and reconciliation. — built (`20261110120000` legs 1-3 and `20261110190000` leg 4; reconciled per currency by `20261110170000`).
4. Wizard UI. — built (`ImportWizard.tsx`: multi-sheet staging, compare-before-commit, reason + approve, `?batch=` resume).
5. Insurance E2E spec covering upload, validate, commit and reconcile. — built (`apps/web/e2e/insurance-import.spec.ts`, both the agreeing and the refused-then-approved path).

Each step ships with SQL tests: tenant isolation, balance by account, rollback on failure, idempotent re-run, version 1 stored on a version-2 tenant, and opening clearing account nets to zero.

## 6. Open items

- ~~Decide Option A or B (3.1a).~~ Option A chosen.
- Cut-over date and the date the legacy books are frozen.
- Whether legacy co-insurance and endorsement history is imported or only current values (this draft: current values only).
- Real export headers, to replace the canonical template mapping.
- Accountant sign-off of section 3 before any real tenant is loaded.
