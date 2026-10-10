# Insurance Brokerage: Analysis and Working Draft

Status: **draft, not reviewed by an accountant.** The core is on `main` (schema, RPCs, UI, `test_ins_core.sql`, hardening and currency/KYC migrations). Do not enable it for a real tenant until the section 7 questions are answered.

## 1. Scope

Add an Insurance Brokerage management system to VestaPortal. It covers the agency's core workflow:

- register clients and insurers
- draft a policy, then bind it, which books the premium and commission
- track renewals before expiry
- notify and assess claims against bound policies

**Out of this draft:** claim cash payments and their ledger posting, endorsements, cancellation of bound policies, a policy approval workflow, and collection or remittance of cash. Each is a deliberate scope cut and is listed in section 8.

The request said "all of those". No attachments were provided, so this analysis is based on the repository contents.

## 2. What already exists in the repo

| Area | Finding | Source |
|---|---|---|
| Platform | Multi-tenant ERP. React 18, Vite 6, TypeScript, MUI 5 in `apps/web`. Supabase Postgres with RLS and SECURITY DEFINER RPCs. Deno edge functions. Default currency UGX. | `README.md`, `apps/web/package.json` |
| Module registry | `platform_modules` lists modules. `insurance` is registered as a `vertical` module with route base `/insurance`. | `20261008061315_platform_modules_registry.sql`, `20261008085228_register_insurance_module.sql` |
| Industry template | `insurance` template v0: modules insurance, hr, it, legal. 8 departments. 18 GL accounts (1000 to 5100) and 18 posting rules. | `20261008100625_insurance_brokerage_template_v0.sql` |
| Client master | `bd_clients` is shared with Business Development. Access helpers `can_access_client_master()` and `can_manage_client_master()` already accept insurance members. | `20261008094326_client_master_access_helpers.sql` |
| Finance | GL core, posting rules, open-items subledger (`fin_open_items`), `fin_create_open_item`, `post_journal_entry`, and the journal source-type check. | `20260903110944_gl_core_schema.sql`, `20260904100000_gl_posting_rules.sql`, `20261008202213_fin_open_items_settlements_allocations.sql` |
| Frontend pattern | Vertical portals are built as lazy routes (`routes/*Routes.tsx`) under `RequireModule`, with nav trees in `ShellConfigs.tsx` and portal entries in `moduleTreeData.tsx`. | `apps/web/src/App.tsx`, `apps/web/src/modules/portals/law-compliance/` |
| Route guard checks | `validateNavModules.test.ts` checks every nav and route guard key against `REGISTRY_FIXTURE`. | `apps/web/src/features/navigation/` |

The repo's own audit doc (`PHASE0_COUPLING_AUDIT.md`) says D4d (bank reconciliation) is "not started". The git log shows D4d-1 and D4d-2 commits and a reconciliation migration, so that doc is probably stale. It does not affect this draft.

## 3. Design

### 3.1 Data model (migration `20261010100000_insurance_brokerage_core.sql`)

| Table | Purpose | Key rules |
|---|---|---|
| `ins_product_lines` | Lines of business (motor, fire, medical, ...). | Admin and manager write. Members read. |
| `ins_insurers` | Insurance companies. Default commission rate. | Guarded. Party account created on first bind. |
| `ins_clients` | Insurance profile on top of `bd_clients`: client type, TIN, risk rating, KYC status. | Guard checks the BD client is in the same tenant. |
| `ins_policies` | Policy header. Statuses: `draft`, `active`, `renewed`. Premium, commission and net stored on bind. | Inserts go through `ins_create_policy`. Bound rows are locked by a guard. |
| `ins_claims` | Claim header. Reserve, approved and paid amounts. | Status moves go through `ins_transition_claim`. |
| `ins_claim_events` | Append-only claim history. | Written by RPCs. |

Views: `ins_renewal_pipeline` (`security_invoker = true`, so the caller's RLS applies).

Functions: 16 in total. The client-callable RPCs are `ins_register_client`, `ins_create_policy`, `ins_create_renewal_draft`, `ins_bind_policy`, `ins_create_claim`, and `ins_transition_claim`. The rest are internal helpers, guards, and triggers.

### 3.2 Policy lifecycle

```
draft --(ins_bind_policy)--> active --(renewal bound)--> renewed
```

- `ins_create_renewal_draft` copies the client, insurer, product, sum insured and premium from an active policy. The new draft starts on the old expiry date. The old policy becomes `renewed` only when the renewal is bound.
- Only drafts can be edited or deleted. Bound policies are locked by the guard, even for the table owner.

### 3.3 Claim lifecycle

```
notified --> assessing --> approved --> settled --> closed
    |             |
    +--> repudiated --> closed
```

- Notify and assess: any insurance member.
- Approve, settle, repudiate, close: admin and manager.
- Approval amount must be above zero and at most the sum insured. Repudiation requires a reason.
- `settled` sets `paid_amount = approved_amount` and records the settlement date. **No cash is posted.** That is a status change only, so the UI labels it "Mark settled" and states that no cash is posted.

### 3.4 Accounting treatment (requires accountant sign-off)

On bind, with gross premium G and commission rate r:

- Commission C = round(G × r / 100, 2)
- Net to insurer N = G − C

The bind creates one balanced journal entry (source type `ins_policy_bind`, dated on the inception date):

| Account (role) | Code | Debit | Credit |
|---|---|---|---|
| Accounts Receivable Control (`ar_control`) | 1100 | G | |
| Insurer Payable (`insurer_payable`) | 2010 | | N |
| Commission Income (`commission_income`) | 4000 | | C |

It also creates two open items (`fin_create_open_item`):

- AR open item for the client, source type `ins_policy_premium`, amount G.
- Payable open item for the insurer, source type `ins_policy_insurer`, amount N.

The two source types are distinct so they do not collide with the unique index on (tenant, source_type, source_id).

**Worked example.** G = 1,000,000 UGX, r = 10%. C = 100,000, N = 900,000.
Dr 1100 1,000,000 · Cr 2010 900,000 · Cr 4000 100,000. Balanced.

**Template check.** The three roles resolve to the template's accounts: `ar_control` → 1100, `insurer_payable` → 2010, `commission_income` → 4000. The template also holds client money in 1020 (Client Money Bank, premium trust), and the comment says client premiums "sit in 1020 / 2010". The draft follows that for the bind, but cash collection into 1020 and remittance out of it are not in this draft. The accountant should confirm both points below.

### 3.5 Access model

| Tier | Roles | Can |
|---|---|---|
| Member | admin, manager, member (`can_access_insurance()`) | View, draft, register clients and policies, notify and assess claims, start renewals |
| Manager | admin, manager (`can_manage_insurance()`) | Bind policies, decide claims, manage masters, delete drafts |

The server is the enforcement point. The UI only shows or hides buttons. `has_module_role()` matches exact role strings with no hierarchy, so the manager tier lists both values explicitly.

## 4. Frontend draft

Location: `apps/web/src/modules/portals/insurance/`

| File | Contents |
|---|---|
| `access.ts` | `useInsuranceAccess()`, `INS_ADMIN_ROLES` |
| `types.ts` | Row shapes for the tables and views, typed by hand because the generated DB types predate them |
| `logic.ts` | Pure helpers: claim transition map, commission split, renewal buckets, input validation, money formatting, error cleanup |
| `db.ts` | Thin wrappers around the untyped Supabase client (`table`, `rows`, `write`, `rpc`) |
| `shared.tsx` | Page header, status chips, error banner, empty row |
| `logic.test.ts` | 12 vitest cases for the pure helpers |
| `pages/InsuranceDashboard.tsx` | KPIs: policies in force, premium and commission in force, renewals due, open claims, open reserves |
| `pages/clients/ClientsList.tsx` | Clients, with a create dialog that calls `ins_register_client` |
| `pages/insurers/InsurersList.tsx` | Insurers, with create and edit for managers |
| `pages/policies/PoliciesList.tsx` | Policies, filterable by status |
| `pages/policies/NewPolicy.tsx` | Draft policy form with a live bind preview |
| `pages/policies/PolicyDetail.tsx` | Detail, bind with a confirmation showing the three ledger lines, start renewal, delete draft, claims on the policy |
| `pages/renewals/RenewalsList.tsx` | Expiries in 120 days, bucketed (overdue, 0–30, 31–60, 61–90, 91–120) |
| `pages/claims/ClaimsList.tsx` | Claims, filterable |
| `pages/claims/NewClaim.tsx` | Notify a loss against a bound policy, with date and sum-insured checks |
| `pages/claims/ClaimDetail.tsx` | Claim detail with transition buttons, reason and amount dialogs, and history |
| `pages/admin/ProductLinesAdmin.tsx` | Product lines (admin and manager) |

Wiring:

- `apps/web/src/routes/insuranceRoutes.tsx`: lazy routes under `RequireModule module="insurance"`. Product-line admin is nested under `roles={INS_ADMIN_ROLES}`. Mounted in `App.tsx`.
- `apps/web/src/modules/portals/ShellConfigs.tsx`: `insuranceNodes`. The Admin node carries `requiredRoles: INS_ADMIN_ROLES`.
- `apps/web/src/features/navigation/moduleTreeData.tsx`: portal entry with `requiredModule: "insurance"`.
- `apps/web/src/test/moduleRegistryMock.ts`: `insurance` row in `REGISTRY_FIXTURE`.
- `apps/web/vitest.config.ts`: the `lib` project now also includes `src/modules/**/*.test.ts`, so pure module logic is tested.

## 5. Verification status

| Check | Result | Notes |
|---|---|---|
| SQL behaviour, `supabase/tests/test_ins_core.sql` | About 100 assertions in the repo suite, run by `scripts/run-sql-tests.ps1` and CI | Replaces the earlier 21-case PGlite harness, which lived outside the repo. One `GAP:` notice remains: commission stays in client money (section 7, question 6). |
| Existing repo insurance SQL tests (`supabase/tests/test_insurance_*.sql`) | **Not run** | They need a real database (CI db-shadow-replay). They cover the template, module registration and client master, none of which this migration changes. |
| TypeScript (`tsc --noEmit`) | **Pass** | Needed a larger heap (`NODE_OPTIONS=--max-old-space-size=6144`). The default heap runs out. |
| Vitest, full web suite | **526/526 pass** (69 files) | Needs `--experimental-websocket` on Node 20. The repo targets Node 22. |
| Production build (`vite build`) | **Pass with `--minify false`** | The sandbox has about 2 GB of RAM. Minified rollup was killed by the OS, even with a 1.5 GB heap. Not a code error. CI should run the full `npm run build`. |
| Migration policy script | **Pass** | `scripts/check-migration-policy.sh 367ccb8` on the commit. |
| Page-level UI | **Not tested in a browser** | Pages compile and their pure logic is tested. No component tests for the new pages yet. |

Dependencies: `npm ci` was run in the background with `npm_config_engine_strict=false`. Its exit code was not captured, but `tsc`, `vite` and `vitest` all ran against `node_modules`.

## 6. Decisions

Decisions already made in this draft:

1. Commission is computed as `round(gross × rate / 100, 2)`, and the net to the insurer is the remainder.
2. Binding books the premium on the inception date, and the policy is locked afterwards.
3. Insurance policies live under the insurance vertical and reuse `bd_clients` as the client master, with the D4 open-items subledger for receivables and payables.
4. The bind requires the posting roles `ar_control`, `insurer_payable`, and `commission_income`. If any is missing, the bind stops with `INS_POSTING_RULE_MISSING`.

## 7. Open questions for the accountant

1. **Gross-up:** should gross premium be booked to AR (1100) at bind, as in this draft? Or should client money go straight to the premium trust account (1020) when it is received?
2. **Commission timing:** is commission earned at bind (this draft), or only when the insurer pays? If the latter, the commission receivable account (1110) would be used at bind instead of income.
3. **Net-of-commission:** does the insurer remit the net, so the broker never pays the gross on? This draft assumes yes.
4. **Account names and VAT/WHT:** the template's names and the VAT and WHT accounts still need confirmation.
5. **Corrections:** a bound policy cannot be edited. The fix is a reversing journal entry, which is not built yet. Confirm that is acceptable for v1.
6. **Commission out of client money:** if the client pays the gross premium into the client-money account (1020) and only the net is remitted to the insurer, the commission stays in 1020. The settlement rules stop a client-money account settling anything except AR receipts and insurer payments, and no client-money-to-operating transfer exists. How should the broker's commission leave client money: a transfer entry on a schedule, at the time the premium is received, or a settlement against a commission receivable (which would also change question 2)? `test_ins_core.sql` reports this as a `GAP:` notice until it is answered.

## 8. Not in this draft

- Claim cash payments, and their ledger posting (claim payable, payment through 1020 or the bank)
- Endorsements, mid-term changes, and cancellation or refund of bound policies
- Policy approval workflow (the shared approval engine is an open audit seam, 14 to 17)
- Cash collection from clients and remittance to insurers, with reconciliation against the open items
- Commission statements per insurer, and a commission receivable process
- Document attachments (policy wordings, claim documents). The generic document store is an open audit seam.
- Notifications for expiries and claim decisions (the generic notifications seam is open)
- Regenerating `packages/shared/src/database.types.ts`. The loose client in `db.ts` covers the gap.
- Reports beyond the dashboard
- Checks on a real Supabase project: the migration has not been applied anywhere, and the RLS has been tested only on PGlite with stubs

## 9. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Accounting treatment not signed off | Wrong ledger entries once live | Section 7 must be answered before the bind goes to production |
| Posting roles missing on a tenant that did not use the insurance template | Bind fails with `INS_POSTING_RULE_MISSING` | Roles are checked before any write. Consider a check in the tenant's setup flow |
| Harness uses stubs | Real RLS or grant differences could surface only on Supabase | Run the migration on a Supabase branch, and run the existing insurance tests (`supabase/tests/test_insurance_*.sql`) |
| Loose client typing in `db.ts` | Typos in table or RPC names reach runtime | Regenerate `database.types.ts` after the migration is applied |
| Commission rounding | Off-by-a-cent differences between preview and ledger | The preview uses the same rounding rule. The server value is authoritative |

## 10. Next steps

1. Get the accountant's answers to section 7, starting with question 6 (how commission leaves client money).
2. Regenerate DB types and remove the loose client in `db.ts`.
3. Decide whether policies in other currencies should be supported; until then the bind refuses them.
4. Add component tests for the bind and claim dialogs.
5. Build the deferred items in section 8, in the order the accountant's answers require.