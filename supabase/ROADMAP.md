# Roadmap — repo audit follow-ups

Working plan from the 2026-09-21 full-repo audit (screens, RLS, tests).
Ordered by priority; check items off as they land, one commit group per
line where possible.

## Priority 1 — Security / RLS ✅ DONE (2026-09-21)

- [x] Verify the README-flagged HR gaps (compensation, team members,
      payroll approvers) — **already closed** by 20260819–20260821
      migrations; README was stale. README status row updated.
- [x] Full-schema RLS audit: all 131 tables have RLS enabled; every
      frontend `.from().insert/update/delete()` cross-checked against
      effective policies. Findings:
  - `hr_job_applications` SELECT was tenant-wide → candidate PII readable
    by any authenticated tenant user. Tightened to HR membership.
  - `hr_trainings` SELECT was tenant-wide. Tightened to HR membership.
    (Table is a course catalog — has no `employee_id`; if per-employee
    training records are ever added, gate them on self OR HR like
    appraisals/attendance.)
  - `hr_attendance` had no DELETE policy → `AttendanceList.tsx`'s delete
    button was an RLS-denied no-op in production. Fixed (admin/manager,
    mirroring UPDATE).
  - All 26 tables in Law / PMO / Machine Operation / Sustainability had
    tenant-wide SELECT (module non-members could read everything via the
    API despite route guards). Tightened to
    `has_module_role('<module>', [admin,manager,member])`.
    `pmo_tasks.SELECT` keeps its `assignee_id = auth.uid()` exception so
    task assignees without a pmo role can still read their own tasks.
- [x] Migration + regression test:
      `supabase/migrations/20260921090000_hr_select_tightening_and_attendance_delete.sql`,
      `supabase/migrations/20260921093000_young_module_select_tightening.sql`,
      `supabase/tests/test_rls_select_tightening.sql`
      (run against a fresh local stack: `psql -f`, same as other tests).
- [x] `scripts/check-migration-policy.sh` passes on both migrations.
- [ ] Apply to production via the normal migration flow, then re-verify
      each module's screens as its own roles (hr manager, legal member,
      pmo member, machine member, sustainability member) once.

### Deliberately unchanged (documented so nobody "fixes" them later)
- `hr_employees` tenant-wide SELECT — it's the people directory used
  cross-module (org chart, approver/assignee pickers); no bank/TIN-style
  columns exist on it. Sensitives live in `hr_employee_compensation` /
  `hr_appraisals` / `hr_attendance` / payroll, all role- or self-gated.
- `hr_job_postings`, `hr_positions`, `hr_leave_types` tenant-wide SELECT —
  internal job board / lookups.
- `hr_team_members`, `payroll_approvers` tenant-wide SELECT with
  RPC-only writes (admin RPCs added 2026-08-21) — write path is the
  sensitive part and it's locked.
- HR managerial writes stay `admin/manager`-only; member tier is
  read-oriented by design.

## Priority 2 — Feature depth (CRUD → real workflows)

- [x] **Law & Compliance** ✅ (2026-09-21): real contract approval flow —
      `law_contract_decisions` audit trail, `submit_contract_for_approval`
      / `decide_contract` RPCs (admin/manager tier, creator self-approval
      refused, rejection requires notes, notifications carry the reason),
      `rejected` joins the status enum (previously "Reject" wrote a
      misleading `terminated`); filings gained a server-enforced
      state machine (`transition_filing`), `law_filing_events` history,
      `due_date`; `/law-compliance/contracts/approvals` route moved to a
      `LEGAL_APPROVER_ROLES` tier (BD/IT pattern); ContractsList's dead
      View button fixed. Tests: `test_law_contract_approval_flow.sql`,
      `ContractApprovals.test.tsx` (5 specs).
- [x] **PMO** ✅ (2026-09-21): project approval flow — `pmo_project_decisions`
      audit, `submit_pmo_project_for_approval` / `decide_pmo_project` RPCs
      (approver tier, creator self-approval refused, rejection requires
      notes, creator notified), `pending_approval`/`rejected` statuses,
      `created_by` now tracked on projects; `/pmo/approvals` screen +
      `PMO_ADMIN_ROLES` tier. Real ledger behind Budget vs Actual:
      `pmo_time_entries` (own-row RLS, hourly_rate snapshotted from the
      logger's active allocation via trigger — NEW `hourly_rate` column
      on `pmo_resource_allocations`) + `pmo_cost_entries` (admin/manager
      money tier). The report's "actual" was previously earned value in
      disguise — variance could never go negative. ProjectDetail gains
      the Budget & Actuals panel, LogTimeDialog (also on TasksList rows),
      approval actions; NewProject no longer lets you birth a project
      "completed". Tests: `test_pmo_approval_and_ledger.sql`,
      `PMOApprovals.test.tsx` (5 specs); existing TasksList/Gantt/
      ProjectStatusReport suites re-run green.
- [x] **Machine Operation**: maintenance scheduling + notifications;
      cost rollup into Finance (fuel/maintenance costs → GL). Fixed by
      `20260921120000_machine_maintenance_workflow.sql`: request status
      is now a state machine (`transition_maintenance_request` —
      scheduled → in_progress → completed, or cancelled), audited in
      `machine_maintenance_events` (machine-role readable), with
      `assigned_to` and requester/assignee notifications on every move;
      completing **with a cost** is admin/manager-only, stamps
      `completed_date`, and posts Dr default-expense / Cr AP-control
      through `post_journal_entry` (gl_posting_rules resolved, skipped
      silently when the tenant's rules are incomplete). Overdue alerting
      is `machine_maintenance_overdue_sweep()` — a cronless cron the
      Schedule screen calls on mount; every past-due open request pings
      requester+assignee exactly once (`overdue_notified_at`). Fuel
      costs now auto-post to the GL on insert (same legs, source_type
      `machine_fuel_log`) — the `journal_entries.source_type` CHECK was
      widened accordingly (without it the posts — and with them the
      fuel insert / maintenance completion — would roll back).
      MaintenanceRequests lost its free status select and direct-update
      Start button; both screens drive the RPC, completion captures
      actual cost in a dialog. Tests: `test_machine_maintenance_workflow.sql`
      (10 scenarios incl. GL-leg assertions, sweep idempotency and
      no-posting-rules skip) — full replay + suite green; full Vitest
      suite 47 files / 334 tests re-run green.
- [x] **Sustainability**: edit depth; real report exports. On inspection
      the screens already had full CRUD + exports everywhere; the honest
      gaps were certification lifecycle depth and the report's grouping.
      `20260921130000_sustainability_cert_expiry.sql` adds
      `sustainability_cert_expiry_sweep()` (same cronless-cron shape as
      machines): past-due `valid` certs lapse to `expired` once and
      certs expiring within 30 days get one renewal reminder
      (`renewal_reminded_at` marker), notifying the creator +
      sustainability admins/managers; CertificationsList runs it on
      mount. SustainabilityReport now groups per metric TYPE (one bucket
      per category mixed metrics and units), has a recorded_date
      From/To filter that drives both the charts and the exports
      (filenames/title carry the range). Test:
      `test_sustainability_cert_expiry.sql` (lapse flip + reminder
      audience + idempotency + outsider silence).
- [x] **Business Development**: opportunity math RPCs; tender submission
      management. `20260921140000_bd_pipeline_math_and_tender_submissions.sql`:
      a probability guard trigger coalesces NULLs from the tenant's stage
      default on insert AND update (weighted math can never see NULL/NaN
      again — it was re-implemented in four screens with no server-side
      guarantee); `bd_pipeline_summary()` is now the single server-side
      source of per-stage count/total/weighted (honours the tenant's
      stage lookup; outsiders get an empty summary) and PipelineReport +
      RevenueForecast consume/coexist with hardened null math;
      `bd_tender_submissions` (RLS read-only for bd members, written
      only by the RPC) plus `transition_tender()` — open → submitted
      (records the portal/tracking ref + note + officer) →
      under_evaluation → awarded | lost (notifies the creator when a
      colleague decides); invalid skips refused. TendersList lost its
      free Status select; lifecycle buttons + Submit dialog drive the
      RPC. Test: `test_bd_pipeline_and_tenders.sql` (guard on insert/
      update, hand-checked summary math, submission recorded once,
      terminal awarded, audience checks).
- [x] SQL tests alongside each of the above (all 5 existing SQL tests
      are Finance — kept the pattern: Law, PMO and Machine Operation
      SQL tests landed with their workstreams in
      `supabase/tests/test_law_contract_approval_flow.sql`,
      `test_pmo_approval_and_ledger.sql` and
      `test_machine_maintenance_workflow.sql`).

## Priority 3 — Code hygiene

- [x] HR route aliases: `/hr/employees/new` auto-opens the New Employee
      dialog (`isNewRoute` route state in EmployeesList) and
      `/hr/leaves/approvals` renders LeaveRequestsList as a
      pending-only approval workbench (title, empty state and rows all
      switch on `isApprovalsRoute`).
- [x] URL taxonomy: `/finance/purchase-orders` moved to
      `/financial-management/purchase-orders`; the old path is a
      `<Navigate replace>` redirect so bookmarks keep working, and the
      ModuleTree link points straight at the new path. **Warehouse
      decision (made): keep `/warehouse/*` under the `procurement`
      guard** — goods issue / stock balances are procurement's store-keeping
      edge, their tables' RLS is already keyed to the procurement module,
      and a separate `warehouse` module would leave every existing
      tenant without access until staff_roles were backfilled. If store
      staff ever need separating from buyers, that's a deliberate
      migration + role-backfill project, not a route shuffle.
- [x] `engines.node >= 22` — already pinned at the repo root and in
      `apps/web` (`"node": ">=22.0.0"`); the "relax or document"
      question resolves to: keep 22 (Vite 7 baseline), verified pinned.

## Priority 4 — Test coverage

- [x] e2e beyond the original 3 specs (now 6):
      `procurement-threshold-branch.spec.ts` walks an above-threshold
      (>5M winning offer) request through the high branch — Project
      Manager → Deputy GM — asserting Finance sees NO purchase order
      until both hops complete (gm@test.local added to
      `e2e/utils/auth.ts`; it was already seeded for stage 7 but unused);
      `payroll-approval-reject.spec.ts` drives the reject branch
      (empty-reason guard, `reject_payroll_run` RPC, HR sees the
      rejected chip plus the reason on the expanded row) with a
      next-month period so it never collides with the disbursement
      spec; `bd-proposal-approvals.spec.ts` approves a seeded
      pending proposal — seeded in seed.sql §4 along with the first BD
      test account (bd@test.local), an E2E client, and the tenant's 8
      `bd_proposal_statuses` rows (the FK `(tenant_id, status)` means
      even draft saves fail on unseeded tenants — flagged as a
      follow-up for a submit-for-approval hop, since the UI today only
      ever writes `draft`). The spec is rerun-safe (pending → approve
      on first run, approved-persistence assertion afterwards). Happy
      path updated for the `/financial-management/purchase-orders`
      move; `tsc --noEmit -p e2e/tsconfig.json` clean across all 6.
- [x] SQL tests for young modules once their workflows land (see P2) —
      landed alongside each P2 module fix (law, PMO, machine operation,
      sustainability, business development): 5 new suites, 10 total
      SQL suites all green on a full-fresh replay.
