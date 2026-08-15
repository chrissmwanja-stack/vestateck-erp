# Bulk Import — Employees, Accounts, Equipment, Leads

Built and validated against a fresh clone of `vestaportal` (typechecked with
`tsc -b` and a full `vite build` — both pass clean). Copy these files into
your repo at the matching paths, overwriting what's there.

## New files
- `apps/web/src/lib/csvParser.ts` — RFC4180-compliant CSV parser (handles
  quoted fields with embedded commas, escaped quotes, CRLF). The old
  `ImportLeads.tsx` used a naive `line.split(",")` that breaks on any
  quoted value; every screen now shares this one parser.
- `apps/web/src/components/bulk-import/BulkImportDialog.tsx` — the reusable
  bulk-import UI: upload → validate every row (required fields, enum
  values, FK name→id resolution against lookup tables, in-file duplicate
  detection) → preview with per-row errors → import the **full file** (not
  a 10-row slice) → per-row success/failure results table.

## Changed files
- `apps/web/src/modules/portals/hr/pages/employees/EmployeesList.tsx` —
  added "Bulk Import" button + dialog. CSV: `first_name, last_name, email,
  phone, hire_date, employment_status, department, position`. `employee_no`
  is never set (trigger-generated). `department`/`position` resolve by name
  against `departments`/`hr_positions`.
- `apps/web/src/modules/portals/machine-operation/pages/equipment/EquipmentList.tsx` —
  added "Bulk Import" button + dialog. CSV: `name, model, serial_number,
  status, location, type`. `machine_no` is never set (trigger-generated).
  `type` resolves by name against `machine_types`.
- `apps/web/src/features/admin/AccountsAdmin.tsx` — **fixed the latent bug**:
  `handleSave`'s insert payload had no `tenant_id`, which fails against
  `accounts.tenant_id uuid not null references tenants(id)` on create (this
  is why all 14 seed accounts were only ever inserted via SQL, never through
  the form). Now resolves `tenant_id` via `app_users` before insert, same
  pattern `EmployeesList.tsx` already used. Also added "Bulk Import". CSV:
  `account_code, name, account_type, contact_name, contact_phone,
  contact_email, category`. `account_code` **is required in the CSV** —
  unlike employees/equipment, there's no generator trigger for it.
  `category` resolves by code against `account_categories`.
- `apps/web/src/modules/portals/business-development/pages/leads/ImportLeads.tsx` —
  fully replaced. The old version only previewed and imported the first 10
  rows, used the naive comma-split parser, and always used
  `sources[0]` as the source for every row regardless of what the CSV said.
  Now uses the shared component: full-file import, real CSV parsing,
  `source` resolved by name against `bd_lead_sources` per row.

## Not touched (flagged for later, per the earlier audit)
- BD → Clients bulk import (parallels Leads, not built yet)
- Cost Centers/Cost Codes bulk import
- `material_catalog` has no CRUD screen at all yet, so bulk import doesn't
  apply there until create/edit exists

## Adding a bulk import to a new screen later
Only three things are needed per screen — everything else is shared:
1. A `BulkImportConfig` object (table name, CSV columns, FK lookups, a
   `buildPayload` function).
2. A `bulkOpen` state + "Bulk Import" button.
3. A `<BulkImportDialog open={bulkOpen} onClose={...} onImported={refetch}
   config={...} />` at the bottom of the component.

Use any of the four wired-up screens as a template.
