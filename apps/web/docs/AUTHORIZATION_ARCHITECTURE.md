# Authorization Architecture

Status: draft for review. Derived from the live definitions in production
(`xownbroirovedkmqyybc`, 2026-10-01) and from branch `fix/per-tenant-document-numbers`
at `ab8409e` (which is `main` at `9eaeb79` plus per-tenant document numbering). Where
the two could differ, production is authoritative (see `supabase/MIGRATION_POLICY.md`).

The rule behind everything below: **the database is the security boundary.**
React route guards decide what to show; RLS, grants and `SECURITY DEFINER` function
bodies decide what is allowed.

## 1. Identities

Three different "who" values exist in a request. Mixing them up is the most likely
source of an authorization bug.

| Value | Source | Meaning |
|---|---|---|
| `auth.uid()` | JWT `sub` | The **real actor**. Always the logged-in person, even during View-as. |
| `effective_user_id()` | `coalesce(impersonated_user_id(), auth.uid())` | The user whose **permissions apply**. Differs from the actor only during user-level View-as. |
| `get_my_tenant_id()` | active impersonation session's `tenant_id`, else the user's `app_users.tenant_id` (NULL if the tenant is `suspended`) | The tenant a request is scoped to. |

Convention: **permission checks use `effective_user_id()`; audit and
separation-of-duties checks record or compare `auth.uid()` as well.** Payroll is the
reference case: `generate_payroll_run` stores `prepared_by = auth.uid()`, and
`approve_payroll_run` compares the preparer against both the real actor and the
effective user (`20260929190000`).

## 2. Vocabulary

Four layers, from broadest to narrowest. Each term below has one meaning; the code
names that implement it follow.

```
Platform   Platform Admin        app_users.is_platform_admin
Tenant     Company Admin         app_users.is_company_admin
Module     Module Admin          staff_roles.role = 'admin'
           Module Manager        staff_roles.role = 'manager' (and admin)
           Module Member         staff_roles.role = 'member'  (and manager, admin)
Workflow   Finance               finance_team_members (finance | cost_control)
           Procurement approver  approval_assignments / approval_delegations
           Payroll approver      payroll_approvers
           HR team               hr_team_members
           Material receiver     material_receipt_assignments
```

### 2.1 The module tiers are cumulative

Production policies use exactly three role sets per module, and each set contains the
one above it:

| Tier | Roles in the policy | Meaning | Typical use |
|---|---|---|---|
| Admin | `admin` | configure the module | settings, destructive deletes |
| Manager | `admin`, `manager` | write and approve | create/update, approvals |
| Member | `admin`, `manager`, `member` | read and contribute | SELECT, own records |

Policy counts per module (`has_module_role(...)` in `pg_policies`, 2026-10-01):

| Module | Admin only | Admin + manager | All three |
|---|---|---|---|
| hr | 12 | 23 | 2 |
| legal | 8 | 19 | 9 |
| machine_operation | 8 | 20 | 7 |
| pmo | 8 | 27 | 10 |
| sustainability | 8 | 16 | 6 |
| bd, it | via `is_business_dev*` / `is_it_support` wrappers (below) | | |
| procurement | no `staff_roles` policies; governed by the approval workflow | | |

So `manager` and `member` are live in the policy layer even though production data
currently has only `admin` assignments. They should stay in the CHECK constraint.

### 2.2 Naming problem: "admin" means two things

In the frontend and in two SQL wrappers, "admin" really means **manager tier**:

| Name | Actual roles |
|---|---|
| `BD_ADMIN_ROLES`, `IT_ADMIN_ROLES`, `PMO_ADMIN_ROLES` | `admin`, `manager` |
| `LEGAL_APPROVER_ROLES` | `admin`, `manager` |
| `is_business_dev_admin()` | `admin`, `manager` |
| `is_business_dev()`, `is_it_support()` | all three (member tier) |
| `staff_roles.role = 'admin'` | admin only |

Someone reading `IT_ADMIN_ROLES` will assume admin-only. Recommended renames, with the
old names kept as aliases until callers move: `*_ADMIN_ROLES` to `*_MANAGER_ROLES`,
`is_business_dev_admin()` to `is_business_dev_manager()`. This is a naming change only;
no permissions move.

## 3. Helper functions

All are `SECURITY DEFINER`, `STABLE`, with a pinned `search_path`. "Policies" counts
RLS policies that call the helper; "Fn callers" counts other functions that do.

| Helper | True when | Platform admin | Policies | Fn callers |
|---|---|---|---|---|
| `has_module_role(module, roles[])` | bypass OR (tenant has module AND effective user holds one of `roles`) | passes | 149 | 19 |
| `is_finance_team_member(role?)` | bypass OR row in `finance_team_members` | passes | 65 | 12 |
| `is_business_dev()` / `_admin()` | `has_module_role('bd', ...)`, member / manager tier | passes | 39 / 21 | 0 |
| `is_platform_admin()` | flag on **`auth.uid()`** (real identity) | n/a | 27 | 22 |
| `has_po_access()` | bypass OR assigned to a terminal approval stage (own or delegated) | passes | 18 | 10 |
| `is_it_support()` | `has_module_role('it', admin/manager/member)` | passes | 17 | 46 |
| `is_tenant_admin()` | bypass OR effective user is company admin | passes | 16 | 8 |
| `is_hr_team_member(role?)` | bypass OR row in `hr_team_members` | passes | 4 | 7 |
| `can_act_on_stage(stage)` | bypass OR assigned to, or delegated for, that stage | passes | 4 | 4 |
| `platform_admin_bypass()` | `is_platform_admin() AND impersonated_user_id() IS NULL` | true outside View-as and in company-level View-as | 3 | 11 |
| `is_payroll_approver()` | bypass OR active row in `payroll_approvers` | passes | 2 | 3 |
| `require_platform_admin(action)` | raises `42501` unless platform admin; also raises if an enrolled MFA factor exists and the session is not `aal2` | n/a | 0 | 20 |
| `can_access_finance()` | `has_po_access()` OR `is_finance_team_member(NULL)` | passes | 0 | 2 |
| `can_manage_po_handoff(po)` | selected offer's submitter OR `has_po_access()` | via `has_po_access` | 0 | 2 |
| `has_receipt_access()` | row in `material_receipt_assignments` | **no bypass** | 0 | 2 |
| `can_view_payroll_approvals()` | `is_hr_team_member()` OR `is_payroll_approver()` | passes | 0 | 1 |

### 3.1 Which helper to use

- Module permission: `has_module_role(module, tier_roles)`. The `is_*` wrappers are
  shorthand for it and add nothing else.
- Company configuration: `is_tenant_admin()`. (`is_company_admin()` and `is_any_module_admin()`
  were removed in `20261002110000`; the `app_users.is_company_admin` column remains.)
- Platform-only operations: `require_platform_admin(action)` inside the function body.
  Use `is_platform_admin()` only to branch, not to authorize.
  Console reads that return rows (`list_*`, `get_*`) use `platform_admin_mfa_gate(action)` in
  the `where` clause instead: non-admins still get an empty set, admins with an enrolled factor
  on an `aal1` session get `PLATFORM_MFA_REQUIRED`.
- Cross-module finance reads: `can_access_finance()`.
- Anything involving approvals: the workflow helpers (`has_po_access`,
  `can_act_on_stage`, `is_payroll_approver`), not module roles.

### 3.2 Findings from the usage counts

1. **`is_company_admin()` and `is_any_module_admin()` were unused: removed.** No policy,
   function, view or edge function called either (re-verified against production
   before the drop). `is_any_module_admin()` was the old gate for department writes;
   `20261001120000` replaced it with `is_tenant_admin()`. Both had surprising semantics,
   so removing them was a safety gain, not just tidiness. `20261002110000` drops them;
   `check_live_security_drift.sql` fails if either comes back.
2. **`is_company_admin()` and `is_tenant_admin()` disagreed for platform admins**
   (false vs true). Resolved by 3.1 plus removing the former.
3. **`has_receipt_access()` has no platform-admin bypass** while its siblings do.
   It has no policy callers, only two functions. Decide whether that is deliberate.
4. **`require_platform_admin()` enforces MFA only when a factor is enrolled.**
   A platform admin with no factor passes without `aal2`.

## 4. Impersonation (View-as)

Sessions live in `impersonation_sessions` (`platform_admin_id`, `tenant_id`,
`impersonated_user_id`, `expires_at`, `ended_at`). The newest unexpired, unended
session for `auth.uid()` applies.

| Mode | `get_my_tenant_id()` | `effective_user_id()` | `platform_admin_bypass()` | Effect |
|---|---|---|---|---|
| Platform admin, no session | admin's home tenant | admin | true | Platform console only. Tenant-scoped policies require `tenant_id = get_my_tenant_id()`, so customer tenants' data is **not** writable. |
| Company-level View-as (`impersonated_user_id` NULL) | target tenant | admin | true | Passes role helpers, scoped to the target tenant. May write Company Admin tables. |
| User-level View-as | target tenant | target user | false | Exactly that user's permissions, nothing more. |

`RequireTenantAdmin` mirrors this: a platform admin outside View-as is refused
(`/company-admin/*` would otherwise act on the platform home tenant).

## 5. Row Level Security

- Every `public` table has RLS enabled (148 of 148 at time of writing).
- Standard policy shape: a role helper **and** a tenant clause, for example
  `has_module_role('hr', array['admin']) and tenant_id = get_my_tenant_id()`.
  A role check alone is never enough, and neither is a tenant check alone.
- Company Admin tables (`departments`, `organizations`): INSERT/UPDATE/DELETE require
  `is_tenant_admin()` plus the tenant clause. SELECT stays open to the Finance and
  PO workflows that need to read them.
- `doc_sequences` has RLS on and **no policies by design**, so it is default-deny for
  clients. Access is only through the numbering functions
  (`20260820065126_document_doc_sequences_no_policy_by_design.sql`).
- **Tenant read-only mode:** a `tenant_read_only_guard` trigger on every table with a
  `tenant_id` rejects writes from the `authenticated` role while `tenants.read_only`
  is set. It lets through `service_role`, platform admins outside View-as, and a small
  exempt list (`platform_audit_events`, impersonation tables, `tenant_notes`,
  `notifications`, `app_users`, `platform_digests`, `platform_job_runs`).
  `apply_tenant_read_only_guard()` reinstalls it and is migration-only.

### 5.1 Document numbering

Numbers are per tenant, and both halves are enforced:

- **Who may number:** the six numbering functions call `assert_tenant_access()`, so a
  caller can only draw numbers for its own tenant (`20261001150000`).
- **Uniqueness scope:** `assets.asset_tag`, `problems.problem_number` and
  `requests.mr_number` are unique per `(tenant_id, number)`, matching `it_tickets` and
  `material_catalog`. Before `20261001160000` they were globally unique, so a second
  tenant's first asset, problem or MR would have collided with the first tenant's.
- **Known limitation:** the `next_*` functions compute `max()+1` without a lock. Two
  concurrent inserts in the same tenant can pick the same number; the loser gets a
  `unique_violation`, not a silent duplicate. Serialising them is a separate change.

## 6. Rules for `SECURITY DEFINER` functions

A definer function is a privileged API. Every new one must have:

1. **Purpose and caller policy** stated in a header comment: who may call it, for
   which tenant, under what conditions.
2. **A tenant rule.** A tenant id argument is not authorization. Either derive the
   tenant from `get_my_tenant_id()` or call `assert_tenant_access(p_tenant_id)`.
3. **A pinned `search_path`** (`public, pg_temp`).
4. **Explicit grants.** Postgres grants EXECUTE to `PUBLIC` by default, so
   `REVOKE ... FROM anon` alone does nothing (this already bit us once, see
   `20260925124211`). Revoke from `public`, then grant to the roles that need it.
   Internal helpers are not granted to `authenticated` at all, since definer callers
   run as the owner.
5. **In-body caller checks that work.** Inside a definer function `current_user` is the
   function owner, not the caller. Use `auth.uid()` or the JWT role
   (`platform_request_role()`). Known dead check: `mark_platform_digest_delivered`
   tests `current_user not in ('postgres','supabase_admin')`, which can never be
   true. It is safe only because EXECUTE is limited to `service_role`.
6. **Tests**, positive and negative (section 9).

`assert_tenant_access(tenant_id)` passes for: no user session and a non-client role
(service role, cron, owner); the caller's effective tenant; a non-impersonating
platform admin. It denies `anon` and `authenticated` tokens that carry no `sub`.

Intentionally anon-callable: `health_check` and `get_platform_branding`. Everything
else should be `authenticated`-only or internal.

## 7. Frontend guards

Guards are navigation conveniences. Each one fails closed, and none replaces a policy.

| Guard | Backed by | Used for |
|---|---|---|
| `RequirePlatformAdmin` | `app_users.is_platform_admin` | `/admin/*` platform console |
| `RequireTenantAdmin` | `useTenantAdminAccess` + View-as state | `/company-admin/*` |
| `RequireModule module roles?` | RPC `has_module_role` (default roles admin/manager/member) | module portals; stricter `*_ADMIN_ROLES` sub-groups |
| `RequireFinanceTeam` | RPC `can_access_finance` | finance routes |
| `RequireRpcAccess` | an arbitrary access RPC | one-off gates |

Payroll approvals are deliberately outside `RequireModule` (they follow
`payroll_approvers`, not module roles). `App.tsx` carries the comments for each case.

## 8. Approval and separation of duties

- Procurement approvals follow configurable per-tenant `workflow_stages` and
  `approval_assignments`, with threshold branching and time-boxed delegations.
- Payroll: the preparer may not approve their own run, checked against both identities.
- Payroll approvers: an HR admin grants approver access to someone else, never to themselves
  (`grant_payroll_approver`, `set_payroll_approver_active`). Usually the approver is the HR manager.
- Salaries: `record_employee_compensation` requires an `hr_team_members` row **and** the HR
  module `manager` role.
- Journal entries are immutable once posted; corrections go through `void_journal_entry`.
- Posting and period-close functions are internal or finance-gated, never
  client-callable with an arbitrary tenant id.

## 9. Where each rule is tested

| Concern | Test |
|---|---|
| Role and tenant matrix, Company Admin (section H), View-as | `supabase/tests/security_authorization.sql` |
| Definer callers and grants | `supabase/tests/test_definer_authorization.sql` |
| Invitations are Company Admin only (RLS, `resend-invite` / `invite-user` edge functions) | `supabase/tests/test_invitations_authorization.sql` |
| `set_member_access` (Company Admin only, tenant-scoped, finance role handling) | `supabase/tests/test_set_member_access.sql` |
| Every console read refuses an enrolled operator on `aal1` (15 RPCs) | `supabase/tests/test_console_reads_require_mfa.sql` |
| Internal helpers not client-executable; salary and payroll-approver rules (section 8) | `supabase/tests/test_authorization_review_lockdown.sql` |
| Numbering tenant isolation (caller may only number its own tenant) | `supabase/tests/test_next_doc_number_tenant_isolation.sql` |
| Numbering uniqueness (same number allowed across tenants, not within one) | `supabase/tests/test_per_tenant_document_numbers.sql` |
| View-as actor attribution | `supabase/tests/test_impersonation_attribution.sql` |
| Read-only mode | `supabase/tests/test_tenant_read_only_guard.sql` |
| Production still matches the rules, including per-tenant numbering (check 13) | `supabase/tests/check_live_security_drift.sql` (read-only, safe on prod) |
| Heuristic exposure scan of client-callable definer functions | `supabase/scripts/audit_security_definer.sql` (CI fails on `CRITICAL`) |
| Company Admin screens, real HTTP path | `apps/web/e2e/company-admin-org-setup.spec.ts` |

## 10. Checklist for a new module or table

- [ ] `tenant_id` column, RLS enabled, a policy per command using role helper **and** tenant clause
- [ ] Module registered in `staff_roles` CHECK, `tenant_modules`, and `ModuleKey`
- [ ] Route group behind `RequireModule` (admin-only screens behind a stricter role list)
- [ ] Any definer function meets section 6
- [ ] Included in the read-only guard (automatic if it has `tenant_id`)
- [ ] SQL tests: allowed role, denied role, cross-tenant, View-as
- [ ] Added to `check_live_security_drift.sql` if it carries a hardening guarantee

## 11. Open decisions

1. ~~Remove `is_company_admin()` and `is_any_module_admin()`?~~ Done in `20261002110000`.
2. Rename `*_ADMIN_ROLES` and `is_business_dev_admin()` to say "manager"? (Section 2.2.)
3. Should `has_receipt_access()` get the platform-admin bypass, or stay as is on purpose?
4. Should `require_platform_admin()` demand MFA even when no factor is enrolled?
5. Procurement and IT/BD tiers: confirm that procurement staying outside `staff_roles`
   policies is intended, since it has `staff_roles` admin rows but no policies using them.
6. ~~Serialise the `next_*` numbering functions.~~ Done in `20261002100000`: the five
   `max()+1` functions take a per-(kind, tenant) advisory lock; `next_doc_number` was already
   an atomic upsert.
7. A single permission matrix (role by capability) is still to be written once the
   points above are settled.