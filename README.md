# Vestateck ERP

Multi-tenant enterprise platform covering Procurement, Finance, HR, IT Support,
Business Development, Law & Compliance, PMO, Machine Operation, and Sustainability.
The flagship workflow is Procurement's configurable approval pipeline (request →
cost control → procurement → offer entry → approval → threshold branch → finance →
purchase order).

All monetary values across the platform are denominated in **UGX (Ugandan
Shilling)** by default. A handful of Business Development and cross-border
finance screens (tenders, contracts, invoices) support alternate currencies
(USD, EUR) as an explicit per-record choice, but UGX is the default in every
form and the assumed currency wherever no selector is shown.

## Structure

```
apps/web             React + Vite + TypeScript + MUI frontend
  src/modules/portals   Module UIs, one folder per business area (see below)
  src/features          Shared cross-module features (financial, procurement,
                         approvals, requests, offers, reports, IT support, etc.)
supabase/migrations   SQL schema and RLS policies (100+ migrations; tenants,
                       departments, users, workflow, requests, approvals, and
                       one or more migrations per module as it's built out)
supabase/functions    Edge Functions (e.g. generate-po; others are deployed
                       directly via the Supabase CLI/dashboard as they're added)
packages/shared       TypeScript types shared between the web app and edge functions
```

### Modules (`apps/web/src/modules/portals/`)

| Module | Status |
|---|---|
| Procurement (`src/features/procurement`) | Most mature — full threshold-based approval workflow, PO generation, email delivery |
| IT Support | Complete — admin, report screens, RLS/RPC patterns in place |
| Business Development | Schema and numbering layer complete; leads, opportunities, tenders, proposals, clients, reports UI built; RPCs and some screens still in progress |
| HR | Employees, org, attendance, leaves, payroll, performance, recruitment, reports; RLS policies still being resolved on some tables |
| Law & Compliance | Cases, contracts, compliance, reports |
| PMO | Projects, tasks, resources, reports |
| Machine Operation | Equipment, logs, maintenance, reports |
| Sustainability | Metrics, audits, initiatives, reports |

This list reflects the modules present in the codebase as of writing — some are
further along than others. Check `supabase/migrations/` (sorted by timestamp)
for the most current picture of what schema exists per module.

## Getting started

1. Install dependencies from the repo root:
   ```
   npm install
   ```
2. Copy `apps/web/.env.example` to `apps/web/.env` and fill in your Supabase
   project URL and anon key.
3. Apply the migrations in `supabase/migrations/` to your Supabase project (via
   the Supabase CLI or dashboard) — migrations are ordered by timestamp prefix
   and should be applied in order.
4. Run the web app:
   ```
   npm run dev
   ```

## Status

This is a live, actively developed platform with a running Supabase project.
Row Level Security is implemented per-module as each one matures — Procurement
and IT Support have complete RLS/RPC coverage (`is_it_support()`, `tenant_id =
get_my_tenant_id()` isolation, `SECURITY DEFINER` RPCs); other modules (e.g. HR)
have partial coverage and are still being hardened. Don't assume a table is
RLS-protected just because the platform is live — check the relevant migration
before treating any given table as safe for broad client-side access.

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
