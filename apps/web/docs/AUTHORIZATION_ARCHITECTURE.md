# Authorization Architecture

Status: draft for review. Derived from the live definitions in production
(`xownbroirovedkmqyybc`, 2026-10-01) and from `main` at `9eaeb79`. Where the two
could differ, production is authoritative (see `MIGRATION_POLICY.md`).

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

## 2. Role layers

```
Platform        is_platform_admin (app_users flag)
Tenant          is_company_admin  (app_users flag)  -> "Company Admin"
Module          staff_roles(module, role)           -> admin | manager | member
Workflow grants finance_team_members (finance | cost_control)
                hr_team_members, payroll_approvers
                approval_assignments / approval_delegations (procurement chain)
                material_receipt_assignments
```

- Modules: `hr, legal, bd, it, pmo, machine_operation, sustainability, procurement`
  (`staff_roles.module` CHECK, mirrored by `ModuleKey` in `RequireModule.tsx`).
  A module only applies to a tenant that has a `tenant_modules` row for it.
- Module roles allowed by the CHECK: `admin`, `manager`, `member`. Production
  currently holds only `admin` rows.
- Company Admin is **not** a module admin and not a superuser. It owns company
  configuration (departments, organizations, invitations). Module admins cannot invite.
- Finance and procurement access are workflow grants, not module roles.

## 3. Helper functions

All are `SECURITY DEFINER`, `STABLE`, with a pinned `search_path`.

| Function | True when | Platform admin |
|---|---|---|
| `is_platform_admin()` | `app_users.is_platform_admin` for **`auth.uid()`** | n/a (real identity) |
| `platform_admin_bypass()` | `is_platform_admin() AND impersonated_user_id() IS NULL` | true outside View-as **and** in company-level View-as |
| `require_platform_admin(action)` | raises `42501` unless platform admin; also raises if the admin has an MFA factor enrolled and the session is not `aal2` | n/a |
| `is_company_admin()` | `app_users.is_company_admin` for **`effective_user_id()`** | false (no bypass) |
| `is_tenant_admin()` | `platform_admin_bypass()` OR effective user is company admin | passes |
| `is_any_module_admin()` | bypass OR effective user has `role='admin'` in any module of the tenant | passes |
| `has_module_role(module, roles[])` | bypass OR (tenant has the module AND effective user holds one of `roles` in it) | passes |
| `is_finance_team_member(role?)` | bypass OR row in `finance_team_members` | passes |
| `can_access_finance()` | `has_po_access()` OR `is_finance_team_member(NULL)` | passes |
| `has_po_access()` | bypass OR assigned to a terminal approval stage (own or delegated) | passes |
| `is_hr_team_member(role?)` | bypass OR row in `hr_team_members` | passes |
| `is_payroll_approver()` | bypass OR active row in `payroll_approvers` | passes |
| `is_it_support()` | `has_module_role('it', admin/manager/member)` | passes |
| `has_receipt_access()` | row in `material_receipt_assignments` | **no bypass** |

Things to know before relying on these:

1. `is_company_admin()` and `is_tenant_admin()` differ for platform admins. Use
   `is_tenant_admin()` in policies; use `is_company_admin()` only to ask "is this
   user's own flag set".
2. `is_any_module_admin()` does not check `tenant_modules`, unlike `has_module_role()`.
   An admin row for a module the tenant no longer has still counts.
3. `has_receipt_access()` has no platform-admin bypass, unlike its siblings.
4. `require_platform_admin()` only enforces MFA if a factor is already enrolled. A
   platform admin with no enrolled factor passes without `aal2`.

Items 2 to 4 may be intentional. They are listed so each one is decided on purpose.

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
- Journal entries are immutable once posted; corrections go through `void_journal_entry`.
- Posting and period-close functions are internal or finance-gated, never
  client-callable with an arbitrary tenant id.

## 9. Where each rule is tested

| Concern | Test |
|---|---|
| Role and tenant matrix, Company Admin (section H), View-as | `supabase/tests/security_authorization.sql` |
| Definer callers and grants | `supabase/tests/test_definer_authorization.sql` |
| Numbering tenant isolation | `supabase/tests/test_next_doc_number_tenant_isolation.sql` |
| View-as actor attribution | `supabase/tests/test_impersonation_attribution.sql` |
| Read-only mode | `supabase/tests/test_tenant_read_only_guard.sql` |
| Production still matches the rules | `supabase/tests/check_live_security_drift.sql` (read-only, safe on prod) |
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

1. Should `require_platform_admin()` demand MFA even when no factor is enrolled?
2. Should `is_any_module_admin()` honour `tenant_modules`?
3. Should `has_receipt_access()` get the platform-admin bypass, or stay as is on purpose?
4. Manager and member roles exist in the schema but production only uses `admin`.
   Decide whether they are supported or should be removed from the CHECK.
5. A single permission matrix (role by capability) is still to be written once the
   points above are settled.