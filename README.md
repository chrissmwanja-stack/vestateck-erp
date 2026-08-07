# ERP Platform

Multi-tenant ERP covering HR, Procurement, Finance, and Cost Control, built around a
configurable approval workflow (request → cost control → procurement → offer entry →
approval → threshold branch → finance → purchase order).

## Structure

```
apps/web            React + Vite + TypeScript + MUI frontend
supabase/migrations  SQL schema (tenants, departments, users, workflow, requests, approvals...)
supabase/functions   Edge Functions: submit-request, approve-stage, generate-po, resolve-delegation
packages/shared      TypeScript types shared between the web app and edge functions
```

## Getting started

1. Install dependencies from the repo root:
   ```
   npm install
   ```
2. Copy `apps/web/.env.example` to `apps/web/.env` and fill in your Supabase project URL
   and anon key once a Supabase project exists.
3. Apply the migrations in `supabase/migrations/` to your Supabase project (via the
   Supabase CLI or dashboard) once you're ready to stand up real infrastructure.
4. Run the web app:
   ```
   npm run dev
   ```

## Status

This is a local scaffold — no live Supabase project has been created yet, and
Row Level Security policies have intentionally not been written yet (RLS design
is a deliberately separate step, to be done once the schema stabilizes).

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
