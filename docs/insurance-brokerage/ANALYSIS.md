# Insurance Brokerage: Analysis and Working Draft

Status: **draft, not reviewed by an accountant.**

**Policy reversal update, 14 October 2026:** restricted current-date reversal and optional draft reissue are implemented locally in `20261014170000`; see `POLICY_REVERSAL.md` for exact eligibility, paired-credit accounting and outstanding rollout/acceptance gates. The core is on `main` (schema, RPCs, UI, `test_ins_core.sql`, hardening and currency/KYC migrations). Do not enable it for a real tenant until the section 7 questions are answered.

**Update 2026-10-12:** the commission decisions in section 6 (items 5 to 9) were confirmed on 2026-10-11 and are built (`20261011090000`, `20261011100000`, `20261012090000`), which settles section 7 questions 2, 5 and 6 and part of question 4. Whether an accountant has signed off the full treatment is not recorded in the repo, so the "do not enable" rule above still stands until questions 1 and 3 are answered. The text below was written for the first draft; where a later migration changed it, the section says so.

## 1. Scope

Add an Insurance Brokerage management system to VestaPortal. It covers the agency's core workflow:

- register clients and insurers
- draft a policy, then bind it, which books the premium and commission
- track renewals before expiry
- notify and assess claims against bound policies

**Out of this draft:** endorsements, cancellation of bound policies, a policy approval workflow, and collection or remittance of cash. Each is a deliberate scope cut and is listed in section 8.

The request said "all of those". No attachments were provided, so this analysis is based on the repository contents.

## 2. What already exists in the repo

| Area | Finding | Source |
|---|---|---|
| Platform | Multi-tenant ERP. React 18, Vite 6, TypeScript, MUI 5 in `apps/web`. Supabase Postgres with RLS and SECURITY DEFINER RPCs. Deno edge functions. Default currency UGX. | `README.md`, `apps/web/package.json` |
| Module registry | `platform_modules` lists modules. `insurance` is registered as a `vertical` module with route base `/insurance`. | `20261008061315_platform_modules_registry.sql`, `20261008085228_register_insurance_module.sql` |
| Industry template | `insurance` template v0: modules insurance, hr, it, legal. 8 departments. 19 GL accounts (1000 to 5100, plus 2020 Unearned Commission) and 19 posting rules (v0 shipped 18 of each; 2020 and its rule were added by `20261011090000`). | `20261008100625_insurance_brokerage_template_v0.sql`, `20261011090000_ins_commission_deferral.sql` |
| Client master | `bd_clients` is shared with Business Development. Access helpers `can_access_client_master()` and `can_manage_client_master()` already accept insurance members. | `20261008094326_client_master_access_helpers.sql` |
| Finance | GL core, posting rules, open-items subledger (`fin_open_items`), `fin_create_open_item`, `post_journal_entry`, and the journal source-type check. | `20260903110944_gl_core_schema.sql`, `20260904100000_gl_posting_rules.sql`, `20261008202213_fin_open_items_settlements_allocations.sql` |
| Frontend pattern | Vertical portals are built as lazy routes (`routes/*Routes.tsx`) under `RequireModule`, with nav trees in `ShellConfigs.tsx` and portal entries in `moduleTreeData.tsx`. | `apps/web/src/App.tsx`, `apps/web/src/modules/portals/law-compliance/` |
| Route guard checks | `validateNavModules.test.ts` checks every nav and route guard key against `REGISTRY_FIXTURE`. | `apps/web/src/features/navigation/` |

When this draft was written, `PHASE0_COUPLING_AUDIT.md` still listed D4d (bank reconciliation) as "not started". That doc has since been updated: D4d is done, and `20261012090000` extends it to commission transfers.

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
| `ins_claim_payments` | One row per claim payment, receipt or payout. | Written by RPCs and a settlement-void trigger. See 3.4. |

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
- Approve, repudiate, close: admin and manager. Recording claim payments is also admin and manager. A claim settles by itself when its payments cover the approved amount.
- Approval amount must be above zero and at most the sum insured. Repudiation requires a reason.
- `settled` can no longer be set by hand. `ins_transition_claim(..., 'settled')` is refused with `INS_CLAIM_PAYMENT_REQUIRED` unless payments already cover the approved amount; the payment functions settle the claim themselves. Voiding a payment on a settled claim moves it back to `approved`.

### 3.4 Claim payments (`20261013090000_ins_claim_payments.sql`)

Each insurer has `claim_payment_mode`: `insurer_direct` (default) or `via_broker`. Approval copies it to `ins_claims.payment_mode`, so a later change to the insurer never alters a claim already approved.

- **Insurer-direct:** the insurer pays the client. `ins_record_claim_payment` records the payment with a required insurer reference. Nothing is posted: the brokerage never holds the money. Partial payments are allowed.
- **Brokerage-managed:** approval posts `Dr insurer_claim_receivable (1120) / Cr client_claim_payable (2030)` for the approved amount (source type `ins_claim_accrual`) and opens a receivable item against the insurer and a payable item to the client. `ins_record_claim_receipt` takes the insurer's money into a client-money account; `ins_record_claim_payout` pays the client out of it. Both are ordinary settlements, so they reconcile to the bank like any other.
- **Controls:** the brokerage cannot pay out more than it has received for the claim (`INS_CLAIM_FUNDS_NOT_RECEIVED`). A receipt that has been paid out cannot be voided, from the claim or from Finance (`INS_CLAIM_FUNDS_PAID_OUT`). The settlement engine accepts the two claim roles only when called from the claim functions, so Finance cannot settle a claim item from the generic screen. Claim money goes through a client-money bank account only.
- **Records:** `ins_claim_payments` (RPC-written, one row per payment, receipt or payout, voidable) and the view `ins_claim_cash_position` (received, paid to client, held for the client, due from the insurer).
- **Posting roles:** `insurer_claim_receivable` and `client_claim_payable` bring the platform total to 21. The insurance template and existing insurance tenants gain accounts 1120 and 2030.
- **Not covered:** un-approving a brokerage-managed claim (approval posts the accrual and there is no reversal), credit notes on claim items, overpayment or recovery. Booking at approval rather than at receipt follows how premium is booked at bind and needs the same accountant sign-off as the commission rules.

### 3.4 Accounting treatment (requires accountant sign-off)

> **Superseded for new policies (2026-10-11).** Since `20261011090000` the bind credits the commission to **Unearned Commission** (`unearned_commission`, account 2020) instead of Commission Income (4000), so the bind journal is Dr 1100 G, Cr 2010 N, Cr 2020 C. Commission moves to income (Dr 2020, Cr 4000) when a posted settlement fully pays the insurer's net item, and the open items are unchanged. The first-draft treatment below still applies to policies bound before that migration.

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
| `pages/claims/ClaimPayments.tsx` | The payment panel on an approved claim: both modes, record, receipt, payout and void dialogs. Has a component test, `ClaimPayments.test.tsx` |
| `pages/admin/ProductLinesAdmin.tsx` | Product lines (admin and manager) |
| `pages/commission/CommissionPage.tsx` | Commission entries and position, plus transfers of earned commission out of client money and voiding them (managers). Has a component test, `CommissionPage.test.tsx` |

Wiring:

- `apps/web/src/routes/insuranceRoutes.tsx`: lazy routes under `RequireModule module="insurance"`. Product-line admin is nested under `roles={INS_ADMIN_ROLES}`. Mounted in `App.tsx`.
- `apps/web/src/modules/portals/ShellConfigs.tsx`: `insuranceNodes`. The Admin node carries `requiredRoles: INS_ADMIN_ROLES`.
- `apps/web/src/features/navigation/moduleTreeData.tsx`: portal entry with `requiredModule: "insurance"`.
- `apps/web/src/test/moduleRegistryMock.ts`: `insurance` row in `REGISTRY_FIXTURE`.
- `apps/web/vitest.config.ts`: the `lib` project now also includes `src/modules/**/*.test.ts`, so pure module logic is tested.

## 5. Verification status

| Check | Result | Notes |
|---|---|---|
| SQL behaviour, `supabase/tests/test_ins_core.sql` | About 100 assertions in the repo suite, run by `scripts/run-sql-tests.ps1` and CI | Replaces the earlier 21-case PGlite harness, which lived outside the repo. The commission-stays-in-client-money gap that this row originally reported was closed by `20261011090000`; three other `GAP:` notices remain (a member can set `renewal_of_id` on a draft, a claim's `loss_date` can be edited outside the policy period, and a manager can reach the claim DELETE path). |
| Existing repo insurance SQL tests (`supabase/tests/test_insurance_*.sql`) | **Not run** | They need a real database (CI db-shadow-replay). They cover the template, module registration and client master, none of which this migration changes. |
| TypeScript (`tsc --noEmit`) | **Pass** | Needed a larger heap (`NODE_OPTIONS=--max-old-space-size=6144`). The default heap runs out. |
| Vitest, full web suite | **526/526 pass** (69 files) | Needs `--experimental-websocket` on Node 20. The repo targets Node 22. |
| Production build (`vite build`) | **Pass with `--minify false`** | The sandbox has about 2 GB of RAM. Minified rollup was killed by the OS, even with a 1.5 GB heap. Not a code error. CI should run the full `npm run build`. |
| Migration policy script | **Pass** | `scripts/check-migration-policy.sh 367ccb8` on the commit. |
| Page-level UI | **Not tested in a browser** | Pages compile and their pure logic is tested. No component tests for the new pages yet. |

The rows above record the sandbox run made when the draft was written. On 2026-10-12 the full CI run (build, unit tests, from-scratch migration replay and every `supabase/tests/*.sql` file) was reported green after the insurance tests were updated for the 19-role template; the web suite is now 70 test files and there are 44 SQL test files.

Dependencies: `npm ci` was run in the background with `npm_config_engine_strict=false`. Its exit code was not captured, but `tsc`, `vite` and `vitest` all ran against `node_modules`.

## 6. Decisions

Decisions already made in this draft:

1. Commission is computed as `round(gross × rate / 100, 2)`, and the net to the insurer is the remainder.
2. Binding books the premium on the inception date, and the policy is locked afterwards.
3. Insurance policies live under the insurance vertical and reuse `bd_clients` as the client master, with the D4 open-items subledger for receivables and payables.
4. The bind requires the posting roles `ar_control`, `insurer_payable`, `unearned_commission` and `commission_income` (the last was the only commission role in the first draft). If any is missing, the bind stops with `INS_POSTING_RULE_MISSING`.

Commission decisions confirmed 2026-10-11 and built in `20261011090000`:

5. Commission is credited to an unearned-commission liability when the policy is bound, not to income.
6. It is recognised as income when the insurer's net item for that policy is fully settled, meaning the broker has paid the insurer. Recognition counts payments only; a credit note on an insurer item does not make it "fully settled".
7. Earned commission stays in the client-money bank account until a manager moves it to an operating bank account with a transfer batch (`ins_transfer_earned_commission`, voidable with `ins_void_commission_transfer`). Each side of a transfer is reconciled separately against bank statement lines (`20261012090000`).
8. No VAT or WHT lines on commission.
9. Corrections to a bound policy stay "reverse and re-issue" for v1. Policies bound before the deferral migration keep the old treatment (commission to income at bind) and are not backfilled.

## 7. Open questions for the accountant

Status as of 2026-10-12: questions 2, 5 and 6 are decided (section 6, items 5 to 9) and question 4 is half decided (no VAT or WHT on commission; account names are still unconfirmed). Questions 1 and 3 are open. The original wording is kept below.

1. **Gross-up:** should gross premium be booked to AR (1100) at bind, as in this draft? Or should client money go straight to the premium trust account (1020) when it is received?
2. **Commission timing:** is commission earned at bind (this draft), or only when the insurer pays? If the latter, the commission receivable account (1110) would be used at bind instead of income.
3. **Net-of-commission:** does the insurer remit the net, so the broker never pays the gross on? This draft assumes yes.
4. **Account names and VAT/WHT:** the template's names and the VAT and WHT accounts still need confirmation.
5. **Corrections:** a bound policy cannot be edited. The fix is a reversing journal entry, which is not built yet. Confirm that is acceptable for v1.
6. **Commission out of client money:** if the client pays the gross premium into the client-money account (1020) and only the net is remitted to the insurer, the commission stays in 1020. The settlement rules stop a client-money account settling anything except AR receipts and insurer payments, and no client-money-to-operating transfer exists. How should the broker's commission leave client money: a transfer entry on a schedule, at the time the premium is received, or a settlement against a commission receivable (which would also change question 2)? `test_ins_core.sql` reports this as a `GAP:` notice until it is answered.

## 8. Not in this draft

- Endorsements, mid-term changes, and cancellation or refund of bound policies
- Policy approval workflow (the shared approval engine is an open audit seam, 14 to 17)
- Cash collection from clients and remittance to insurers, with reconciliation against the open items
- A commission receivable process (the deferral, recognition and transfer mechanics are built; see section 6). Per-insurer commission statements are built as a client-side report with Excel and PDF export (13 Oct 2026)
- Document attachments (policy wordings, claim documents). The generic document store is an open audit seam.
- Notifications for expiries and claim decisions (the generic notifications seam is open)
- Typed row shapes in `db.ts`. Types are regenerated and `db.ts` now checks table, view and RPC names against them; row shapes stay `any`.
- Reports beyond the dashboard
- Checks on a real Supabase project: as of this draft the migration had not been applied anywhere and the RLS had been tested only on PGlite with stubs. The SQL tests now run in CI against a local Supabase stack; whether the insurance migrations have been applied to a hosted project is not recorded in the repo

## 9. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Accounting treatment not signed off | Wrong ledger entries once live | Section 7 must be answered before the bind goes to production |
| Posting roles missing on a tenant that did not use the insurance template | Bind fails with `INS_POSTING_RULE_MISSING` | Roles are checked before any write. Consider a check in the tenant's setup flow |
| Harness uses stubs | Real RLS or grant differences could surface only on Supabase | Run the migration on a Supabase branch, and run the existing insurance tests (`supabase/tests/test_insurance_*.sql`) |
| Loose client typing in `db.ts` | Typos in table or RPC names reach runtime | Regenerate `database.types.ts` after the migration is applied |
| Commission rounding | Off-by-a-cent differences between preview and ledger | The preview uses the same rounding rule. The server value is authoritative |

## 10. Next steps

1. Get the accountant's answers to the open section 7 questions (1 and 3) and a sign-off of the deferred-commission treatment in section 6.
2. Regenerate DB types and remove the loose client in `db.ts`.
3. Decide whether policies in other currencies should be supported; until then the bind refuses them.
4. Add component tests for the bind and claim dialogs (the Commission page already has one).
5. Build the deferred items in section 8, in the order the accountant's answers require.