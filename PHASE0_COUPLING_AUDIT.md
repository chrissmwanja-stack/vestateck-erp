# Phase 0: Coupling Audit and Decision Log

**Repo:** chrissmwanja-stack/vestateck-erp, commit `2fc0c46` (2026-10-05, main)
**Purpose:** find every place where a standalone Insurance Brokerage tenant (core plus insurance only) would hit construction, procurement or BD coupling, and rank the seams to cut.
**Method:** static read of the repo (migrations, edge functions, web app). The live database was not queried in this pass (see "Not yet verified").

**Status (updated 2026-10-08, repo at `f1282d0`):** Phase 0 is closed; all decisions D1-D7 are confirmed. Sections 1-3 are the audit as it stood at `2fc0c46` and are kept as a historical record, so their present-tense statements describe that commit, not today's repo. Section 4 carries the decisions and Section 7 carries what has been built since.

---

## 1. Verdict

The platform is closer to vertical-ready than the plans assumed: templates are data, per-tenant flags and entitlements exist, and every table is tenant-scoped. But a template cannot currently produce an insurance tenant, for three reasons:

1. `seed_tenant_defaults` would fail on an `insurance` module item, because the module CHECK constraint rejects it.
2. `create-tenant` rejects any template other than `general` and `construction`.
3. An insurance user could not read clients without a BD role, because `bd_clients` RLS is gated on `is_business_dev()`.

Fixing those three plus the module registry gets milestone 1.

---

## 2. Coupling matrix (ranked)

Severity: **Blocker** = standalone insurance tenant impossible. **Major** = works but wrong or unsafe. **Minor** = fix when touched.

| # | Seam | Evidence | Severity |
|---|------|----------|----------|
| 1 | Module keys hard-coded in two DB CHECKs | `staff_roles_module_check` and `tenant_modules_module_check` list 8 keys (squashed baseline, ~L7683 and ~L7876). `platform_module_activity_sources` has a third copy that also includes `finance`. | Blocker |
| 2 | Template seeding writes template `module` items straight into `tenant_modules` | `seed_tenant_defaults` (20260923090000). An `insurance` item fails the CHECK in #1. | Blocker |
| 3 | `create-tenant` allow-list | `VALID_INDUSTRY_TEMPLATES = ['general','construction']` (index.ts L37, L74-77). `save_industry_template` can create other templates in the admin UI, but they can never be used for a new company. | Blocker |
| 4 | Client master gated on BD | `bd_clients` select/insert/update/delete all `tenant_id = get_my_tenant_id() AND is_business_dev()` (baseline). Insurance users would need the BD module and a BD role. | Blocker |
| 5 | Module list hard-coded in edge functions | `ALL_MODULES` in `accept-invite` (L22) and `invite-user` (L41, plus the validation message at L142). `accept-invite` gives a company admin roles on all 8 modules by design, so an insurance company admin would get inert rows for PMO, machine ops and so on. | Major |
| 6 | Module list hard-coded in the frontend | `ModuleKey` type in `RequireModule.tsx`, plus `ModulesDialog`, `CompanyCreateWizard`, `platformConfig`, `InviteMember`, `TeamMembersAdmin`, `moduleTreeData` (one `requiredModule` per node), and per-module route files. | Major |
| 7 | Finance access tied to PO access | `can_access_finance() = has_po_access() OR is_finance_team_member(NULL)`. `finance` is not a `tenant_modules` key; operator-console SQL treats `procurement` and `finance` as enabled together (onboarding_funnel and console_reads migrations). | Major (verify) |
| 8 | Receivables too thin for premium handling | `receivable_invoices`: status only `open`/`paid`; `amount_incl_vat > 0` (so no credit notes); `organization_id` and `prf_oif_number` NOT NULL; no payment or allocation table. `cost_center_id` is nullable. | Major |
| 9 | GL posting roles are a fixed list | `gl_posting_rules.account_role` CHECK has 13 roles. Insurance needs client-money bank, insurer payable, commission receivable, commission income, WHT receivable. The table comment says adding a role = CHECK update plus trigger-function change. | Major |
| 10 | Chart of accounts is not part of seeding | `seed_default_chart_of_accounts()` is only called from a button in `ChartOfAccountsAdmin.tsx` (L172). A new tenant starts with no CoA, and the default CoA is construction/general-shaped. | Major |
| 11 | Template item kinds are closed | `industry_template_items.kind` CHECK allows only `department`, `module`, `workflow_stage`. No GL accounts, posting rules, doc-number formats, flags or lookups. | Major |
| 12 | A pack cannot be re-applied to an existing tenant | `seed_tenant_defaults` returns early if any department or workflow stage exists. `apply_workflow_template` only handles workflow stages and refuses while requests are open. | Major |
| 13 | Workflow seeding is procurement-shaped | `platform_seed_workflow_from_template` writes `workflow_stages` for `applies_to='requests'` with offer-entry flags. Harmless for an insurance template with no stage items, but it is not reusable for policy approvals. | Minor |
| 14 | Approval tables are not a shared engine | `approval_actions` has a CHECK requiring exactly one of `request_id` / `invoice_request_id`; `approval_assignments` scope is department / cost_center / global. Insurance approvals should copy the Law pattern (`submit_*` / `decide_*`, decisions table). | Info |
| 15 | Notifications are entity-specific | `notifications` has `request_id`, `purchase_order_id`, `invoice_request_id` and no generic entity link. | Minor (Phase 2) |
| 16 | No generic document store | Only the PO documents bucket (recreated in 20260902150000); the web app has no other storage usage. | Phase 2 build |
| 17 | Nav is one static tree | `moduleTreeData.tsx` with `requiredModule` per node. No per-vertical landing page, branding or vocabulary layer found. Not examined in depth. | To examine in Phase 1 |

### Already in good shape (no change needed)
- `tenant_id` on every table, RLS via `get_my_tenant_id()` and `has_module_role()`.
- `industry_templates` and `industry_template_items` tables, template admin UI (`IndustryTemplatesAdmin.tsx`), `tenants.industry_template` column.
- Per-tenant feature flags (`tenant_feature_flags`) and `platform_job_runs` for sweeps.
- Law contract approval flow plus `test_law_contract_approval_flow.sql` (template for insurance approvals), and the cert-expiry sweep (template for renewals).
- Department seeding via template items, and the `set_department_defaults` trigger fix.

---

## 3. Correction to earlier statements

I earlier said `receivable_invoices` "requires cost_center, organization_id and prf_oif_number". The code shows `cost_center_id` is **nullable**; only `organization_id` and `prf_oif_number` are NOT NULL. The conclusion (it does not fit brokerage receivables) stands.

---

## 4. Decisions (all confirmed)

| ID | Decision | Rationale |
|----|----------|-----------|
| D1 | Add a `platform_modules` registry (key, name, tier: core / optional / vertical, vertical, route base, depends_on). Replace the CHECKs on `tenant_modules`, `staff_roles` and `platform_module_activity_sources` with foreign keys to it. | Cuts seams 1, 2. Adding a module becomes a row. |
| D2 | **CONFIRMED.** Client master: keep `bd_clients` for now, but gate it through a helper `can_access_client_master()` = `is_business_dev()` OR `has_module_role('insurance', ...)`. Revisit moving to a neutral core `clients` table once a third vertical needs it. | Cuts seam 4 with the smallest change; the helper makes the later move a swap, not a rewrite. |

### D2 scope (from the repo)
- `is_business_dev()` is just `has_module_role('bd', ['admin','manager','member'])`. Every BD table has 4 policies built on it (15 tables: leads, opportunities, proposals, tenders, activities, contacts, clients and their lookup tables).
- **Change only the client-master set:** `bd_clients`, `bd_contacts`, `bd_client_categories`. Leave leads, opportunities, proposals and tenders BD-only, so an insurance tenant never sees tender or pipeline data.
- `bd_activities`, `bd_opportunities`, `bd_proposals` and `bd_tenders` reference `bd_clients` with `ON DELETE SET NULL` and `bd_contacts` with `ON DELETE CASCADE`; the helper does not change these.
- **Write policies must be rebuilt from live `pg_policies`, not from the baseline.** `20260820130000_bd_admin_tier_lookup_table_rls`, two `remote_schema` migrations and `20260929064635_reapply_skipped_rls_hardening` all touched BD policies after the baseline, so the baseline text is not the current truth.
- **Depends on D1:** `has_module_role('insurance', ...)` only works once `insurance` is a valid module key.
- Row ownership ("my book of clients") is a later layer: `bd_clients.created_by` exists, and an `owner_id` on the `ins_client_profiles` extension table can drive owner-scoped read policies for insurance roles.
| D3 | Add `finance` to the registry as a core-tier key and confirm that `has_po_access()` is not needed for finance on a tenant without procurement. | Seam 7. |
| D4 | Build receipts, allocations and credit notes as **new shared finance tables**, not by relaxing `receivable_invoices`. | Avoids regressions in construction finance and its tests. |
| D5 | Add an idempotent `apply_template(tenant, template, mode)` that inserts missing modules, departments, flags, GL accounts and posting rules, and leaves workflow stages to `apply_workflow_template`. | Seams 11, 12. |
| D6 | Company-admin role rows are derived from the tenant's entitled modules, not a hard-coded list. | Seam 5. |
| D7 | Extend `industry_template_items.kind` to add `gl_account`, `posting_rule`, `doc_sequence`, `feature_flag`, `lookup`, and run CoA seeding as part of template application. | Seams 10, 11. |

### D4 breakdown (added when the work was split into steps)

D4 is built in lettered steps. Receipts are modelled as **settlements** (money in or out through a registered bank account), and each settlement is fully allocated to **open items** at posting time.

| Step | Scope | Status |
|------|-------|--------|
| D4a | `fin_bank_accounts` registry: operating vs client-money kind, each mapped to its own GL account | Done (`20261008120000`) |
| D4b-1 | `fin_open_items` subledger and `fin_open_item_balances` view | Done (`20261008202213`) |
| D4b-2 | Credit notes: `fin_credit_notes`, `fin_credit_applications`, `fin_raise_credit_note`, `fin_void_credit_note` | Done locally (`20261009001500`): `test_fin_credit_notes.sql` and `test_fin_settlements.sql` pass on a fresh `supabase db reset` (2026-10-09). Not yet confirmed in CI or applied to production |
| D4c | `fin_settlements`, `fin_allocations`, `fin_record_settlement`, `fin_void_settlement` | Done (`20261008202213`) |
| D4d | Reconciliation of settlements against bank statements | Not started |

### Where the build differs from the text above
- **D7:** the template item kinds actually added are `gl_account`, `posting_rule` and `feature_flag`. `doc_sequence` and `lookup` were not added.
- **Seam 9:** the posting-role list grew from 13 to 18 roles (adds `client_money_bank`, `insurer_payable`, `commission_receivable`, `commission_income`, `wht_receivable`).
- **D3:** `finance` is registered in `platform_modules` as a core key with `tenant_entitled = false`, so it cannot be entitled per tenant. That `has_po_access()` is not needed for finance on a tenant without procurement has **not** been re-verified (see Section 7).

---

## 5. Phase 1 work order (derived)

1. **Registry migration:** create `platform_modules`, backfill the 8 existing keys plus `finance`, add FKs, keep behaviour identical. Tests: existing suite plus a new registry test.
2. **Edge functions:** `accept-invite` and `invite-user` read the registry instead of `ALL_MODULES`; `create-tenant` validates against `industry_templates` (active rows).
3. **Frontend:** `ModuleKey` and the admin screens load from the registry; nav nodes keep `requiredModule` but validate against registry keys.
4. **Template extension (D7) and `apply_template` (D5).**
5. **Client-master helper (D2)** and policy swap on `bd_clients` and its child tables.
6. **Insurance Brokerage template v0:** departments, roles, modules (`insurance`, `hr`, `it` optional), empty workflow, CoA seed.
7. **Acceptance test v0:** create a tenant from the insurance template, assert it has only core plus insurance modules, no construction departments or workflow stages, and that PMO, machine ops and sustainability routes and RPCs are denied.

---

## 6. Not yet verified

- Live database state (this pass read the repo only). Re-check against production: current `bd_clients` policies after the BD admin-tier hardening migrations, the definitions of `has_po_access()` and `is_business_dev()`, and the live module CHECK definitions.
- Per-vertical landing page, branding and vocabulary support in the shell (seam 17).
- Whether FX or multi-currency is handled correctly in the GL (the `currency` column exists on `receivable_invoices`; GL behaviour not read).

---

## 7. Status since the audit (as of `f1282d0`)

Evidence is from the repo's migrations, edge functions and commit history, not a fresh run of the suite.

### Phase 1 work order
| # | Step | Status | Evidence |
|---|------|--------|----------|
| 1 | Registry migration | Done | `20261008061315_platform_modules_registry` (+ `061330`, `061337`) |
| 2 | Edge functions | Done for `invite-user` and `create-tenant` (registry / active `industry_templates`); `accept-invite` now defers to the registry-validated roles | `supabase/functions/*` |
| 3 | Frontend | Done | `b4459da`, `637c6a3` |
| 4 | Template extension (D7) and `apply_template` (D5) | Done, with the kinds noted in Section 4 | `20261008083846` |
| 5 | Client-master helper (D2) and policy swap | Done | `20261008094326`, `7ca31c6` |
| 6 | Insurance Brokerage template v0 | Done | `20261008100625`, `9efa5da` |
| 7 | Acceptance test v0 | Done, fixtures since corrected | `9ce91f4`, `a4017c9`, `768f99c`, `6319fa1` |

Also shipped: `insurance` registered as a module (`20261008085228`), the BD document-number uniqueness fix (`20261008130000`), and Phase 2 D4a, D4b-1 and D4c (Section 4).

### Seams closed or re-verified since the audit
- **7 (finance vs PO access): verified for access, two residual items.** Checked 2026-10-09 against the repo.
  - `can_access_finance()` is `has_po_access() OR is_finance_team_member(NULL)`. `is_finance_team_member` reads `finance_team_members` directly (tenant-scoped, roles `finance` / `cost_control`), with no dependency on procurement, workflow stages or `tenant_modules`. A tenant with no procurement gets finance access through that table alone, and `set_finance_role` (tenant admin) is how rows get there. D3's second half ("`has_po_access()` is not needed for finance without procurement") therefore holds.
  - The D4 objects (`fin_bank_accounts`, open items, settlements, allocations and their functions) authorize on `is_finance_team_member` only and never touch `has_po_access()`.
  - Residual 1 (fixed in the web app, not yet run in CI): `financeRoutes.tsx` put Purchase Orders (`/financial-management/purchase-orders`) and SAP Payment Approvals (`/sap/payment-approvals`) under the same `RequireFinanceTeam` guard as the finance screens, and their nav nodes carried `requiredAccess: "finance"` only, so a finance user in a tenant without `procurement` saw both and could open the URLs. Data was always protected by RLS; this was visibility and consistency. The fix is an entitlement-only check (a `tenant_modules` row exists; platform admins pass), not `requiredModule` / `RequireModule`, because those also test `staff_roles` and would hide the screens from construction finance users who are on the finance team but hold no procurement role. Built as `entitledModules` on `ModuleAccessState`, a `requiredEntitlement` field on nav nodes (validated against the registry like `requiredModule`), and a `RequireEntitlement` route guard wrapping the two routes.
  - Not reviewed, may be the same leak: other finance-group screens that look procurement-related (`supplier-invoice-po`, cost codes, and the finance-gated warehouse and material-receipt admin screens). They are left as they were; decide per screen whether they also need `requiredEntitlement: "procurement"`.
  - Residual 2 (fixed in `20261009010000`, not yet run in CI): the operator-console SQL treated `procurement` and `finance` as always enabled in `get_company_analytics()` and `get_platform_dashboard_stats()`. Only `finance` (core, not entitled per tenant) is now treated that way; `procurement` reads from `tenant_modules`. Tenants without a `procurement` row will show it as not enabled. `test_onboarding_funnel_and_usage.sql` was updated to match.
- **10 (chart of accounts in seeding): closed.** The insurance template v0 (`20261008100625`) carries 18 `gl_account` and 18 `posting_rule` items.

### Seams not yet closed
- **14-17 (shared approval engine, generic notifications, document store, per-vertical shell):** not started.
- **Open decision:** whether `apply_template` into an existing tenant should leave `tenants.industry_template` unchanged. The only relabel today is in `seed_tenant_defaults` (first run).

### D4b-2 design (confirmed 2026-10-09)
- A credit note is a separate document; `fin_open_items` stays immutable and positive-only.
- It is **fully applied to open items when raised**, so the GL control account always equals the sum of outstanding items (same rule as settlements). No unapplied credit and no cash refund in v1; a refund would be a later step (D4b-3).
- One credit note can be split across several items of the same party, side, control role and currency.
- Raising posts one journal (receivable: Dr offset / Cr control; payable: Dr control / Cr offset). The caller picks the offset account, which cannot be a control, bank or client-money account. Voiding posts the reversal and the applications stop counting.
- `fin_allocations_guard` is replaced so settlements and credit notes share one outstanding amount; `fin_open_item_balances` gains `credited_amount` (appended).

### Next
D4d (reconciliation of settlements), which needs a design pass first.