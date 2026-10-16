/**
 * HISTORICAL PHASE-2 HANDOFF. Superseded by CANCELLATION_CASH_HANDOFF.ts
 * once migration 20261015210000_ins_cancellation_cash.sql is installed.
 * The cash-disabled statements below describe the earlier increment only.
 *
 * Cancellation v1 — calculation + approval/accounting increment, 2026-10-15.
 * DEVELOPMENT HANDOFF ONLY. This is NOT the completed cash/refunds release.
 * No push, deployment, production migration, or live payment was performed.
 *
 * The cumulative patch applies to co-insurance baseline 592a218 and includes
 * the earlier calculation foundation (5bfafdf). Do not reapply an already
 * installed migration. Review/apply new migrations in timestamp order on a
 * disposable database before considering any production rollout.
 *
 * Supported here:
 * - Insurer-specific original allocation/commission calculations and explicit
 *   contractual cancellation methods; no assumed pro-rata permission.
 * - Separate pass-through recipient and broker-fee/VAT credit decisions.
 * - Durable proposals, Finance preparation and independent Finance checking;
 *   explicit acceptance of manual exceptions, tenant/role/RLS protections.
 * - Claims blocked both at preparation and atomically at final approval.
 * - Current-date, zero-clearing accounting: unpaid balance credits, insurer
 *   recovery receivables, client refund liabilities and commission adjustments.
 * - Original bind, journal, receipt and commission-transfer history preserved.
 * - Finance/Insurance review screens, retained commission/insurer statements,
 *   signed fee/VAT credit reporting, retry/stale-review protection.
 *
 * CASH EXECUTION IS INTENTIONALLY NOT IMPLEMENTED/ENABLED HERE:
 * - Insurer recovery receipts and client refund payments.
 * - Operating-to-client-money returns of transferred commission clawbacks.
 * - Remittance of retained insurer liabilities after cancellation.
 * New cancellation liabilities/receivables cannot be settled through generic
 * cash APIs; historical cash voids/transfers cannot erase the accounting trail.
 * Cancellation approval does NOT authorize or trigger any cash movement.
 * The old cash path is unavailable for a cancelled policy, so do not enable
 * this increment operationally until the dedicated cash phase is completed.
 *
 * Next cash phase must enforce server-side Finance maker/different checker/
 * third distinct reconciler, exact case/request linkage, actual policy- and
 * bank-specific funds, all retained obligations/reserves, pro-rata insurer
 * funding, partial payment limits, immutable evidence and bank-match/void
 * controls. An AR recovery receivable or reversed income is NOT actual cash.
 * Optional VAT is not tax-adviser confirmation; production treatment still
 * requires the appropriate accounting/tax review.
 *
 * Validation on disposable local PostgreSQL 17 and Node 22:
 * - 128 migrations + seed replayed from an empty database.
 * - All 51 SQL regression scripts passed (including deferred constraints).
 * - 739 web tests across 90 files passed; old regression tests unchanged.
 * - 8 new real two-session approval/receipt-void/claim/commission races passed.
 * - Existing 5 cash and 6 co-insurance two-session races passed unchanged.
 * - 375 insurer calculations + 2,201 exact-cent allocations matched TS/SQL.
 * - Tenant-FK audit returned no rows. Security-definer report reviewed:
 *   new public actions have server guards; private helpers are not executable
 *   by authenticated/anonymous users. Existing unrelated audit findings remain.
 * - TypeScript and production bundle passed. The 2GB sandbox required 1GB
 *   temporary local swap; existing circular/large-chunk warnings remain.
 * - No live-browser/end-to-end production environment test was performed.
 */
export const cancellationApprovalHandoff = {
  phase: 'calculation-and-approval-accounting-only',
  productionReady: false,
  cashExecutionEnabled: false,
  baselineCommit: '592a218',
  calculationFoundationCommit: '5bfafdf',
  validatedOn: '2026-10-15',
  migrations: [
    '20261015180000_ins_cancellation_calculation.sql',
    '20261015190000_ins_cancellation_approval_posting.sql',
  ],
  validation: {
    migrationCount: 128,
    sqlScriptsPassed: 51,
    webTestsPassed: 739,
    webTestFilesPassed: 90,
    cancellationRacesPassed: 8,
    existingCashRacesPassed: 5,
    existingCoInsuranceRacesPassed: 6,
    insurerCalculationParityCases: 375,
    exactCentAllocationParityCases: 2201,
    typecheck: 'passed',
    productionBundle: 'passed-with-existing-chunk-warnings',
  },
} as const;
