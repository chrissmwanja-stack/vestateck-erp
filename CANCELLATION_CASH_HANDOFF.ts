/**
 * Cancellation cash v1 — 2026-10-15.
 * Supersedes the CASH-DISABLED operational limitations in the historical
 * CANCELLATION_APPROVAL_HANDOFF.ts. No push, production migration, deployment,
 * bank instruction or live payment was performed by this implementation.
 *
 * INCREMENTAL DELIVERY: apply AFTER the previous 25-file cancellation update
 * (local reference commit 20fe73d). This patch does not recreate the calculation
 * foundation or modify the already-issued 1800/1900 migrations. Install only
 * the new 20261015210000_ins_cancellation_cash.sql through your normal reviewed
 * local/staging migration process. Confirm the earlier migrations exist first.
 * Do not apply the old cumulative patch again or overwrite unrelated work.
 *
 * IMPLEMENTED:
 * - Insurer recovery receipts against the exact approved recovery receivable.
 * - Remaining client-premium receipts against the retained original AR balance.
 * - Client refunds against the exact approved client refund liability.
 * - Retained insurer remittances against each insurer's original payable.
 * - Returns of transferred commission from its original operating bank into
 *   client money: two native Finance settlements, one atomic zero-clearing pair.
 * - Partial withdrawals of retained earned commission, likewise an atomic pair.
 * - Correction void proposals checked by another Finance user; both legs reverse
 *   atomically, with immutable history and retained-recognition reversal.
 * - Finance workbench cash controls; Insurance routes remain cash-read-only.
 * - Original bind/share/commission/transfer evidence is never rewritten.
 *
 * CONTROLS:
 * - Separate Finance maker/different checker; request creation never moves cash.
 * - Third distinct Finance reconciler through the existing bank workbench.
 * - Exact zero-variance bank, currency, amount and actor evidence required for
 *   new movements. Both commission-return legs must match before incoming cash
 *   becomes available. Original premium receipts must also have exact matches.
 * - Native Finance settlements/allocations remain the cash ledger. AR recovery,
 *   income reversals, pending requests and unmatched receipts are not funding.
 * - Policy-specific cash and actual uniquely mapped bank-book cash are checked.
 *   An unattributed client-bank shortfall blocks outgoing payments rather than
 *   borrowing another policy's or a claim's native cash. Native bank balances
 *   include unrelated Finance/claim settlements and original commission moves.
 * - Current-date/open-period postings only; cancel/recreate stale-date proposals.
 * - Requests reserve nothing. Approval rechecks balances under policy/bank locks;
 *   a tenant journal mutex serializes bank-book changes with the funds check.
 * - Retained funding uses each insurer's original allocated premium and explicit
 *   pass-through allocation LESS its independently approved returns. Multiply
 *   that retained gross by the verified net-client-collection/retained-invoice
 *   ratio (capped at one), then deduct that insurer's net remittances and cash
 *   commission withdrawals/returns. This never changes the bound share records.
 * - Refunds reserve all outstanding retained insurer liabilities, unwithdrawn
 *   retained commission and retained broker-fee/VAT amounts. Deferred commission
 *   does not introduce a new blanket reserve into partial insurer funding.
 * - Generic settlement/credit/void APIs cannot settle or erase these new cash
 *   balances without the exact current-transaction independent approval context.
 * - Funding evidence cannot be unmatched/voided while downstream cancellation
 *   payments remain posted. Reverse downstream uses first. Voiding retained
 *   remittances is blocked while their retained commission remains withdrawn.
 * - Used bank name/kind/currency/GL identity is frozen against silent remapping.
 *
 * FINANCE UAT BEFORE OPERATIONAL ROLLOUT:
 * 1. Confirm at least three distinct authorized Finance users and correct bank
 *    segregation/unique asset GLs, ledger currency and original posting mappings.
 * 2. Open Finance > Insurance premium cash, select the cancelled policy and use
 *    Cancellation recoveries & payments. Insurance shows status only.
 * 3. Match historical premium receipts accurately. Record recoveries and returns
 *    as separate proposals; another Finance user approves each. A third matches
 *    actual statement lines, including both sides of internal transfers.
 * 4. Refresh limits, prepare/check the client refund and retained insurer payments;
 *    verify liability balances, bank books, clearing, commission and audit history.
 * 5. Test lost-response retries, insufficient cash, partial receipts, different
 *    co-insurer returns, mismatches, stale-date/closed-period requests and a
 *    correction void in the required downstream-first order.
 *
 * LIMITS / NO IMPLIED EXPANSION:
 * - These are approved accounting cash bookings, NOT online bank instructions.
 *   Independently verify real beneficiary details and actual bank transactions.
 * - A void corrects a mistaken booking; it does not recover a real payment.
 * - Bank matching remains one-to-one; grouped/batch statement matching is not
 *   introduced. Never fabricate split statement lines to manufacture funding.
 * - Retained broker-fee/VAT cash remains reserved; automatic fee sweeps, tax cash
 *   payments, EFRIS and tax-adviser confirmation are not provided by this patch.
 * - Claims remain blocked for cancellation v1. No FX, agents, quotation workflow,
 *   printable insurance documents or new general statutory-payee engine added.
 * - No live-browser/staging deployment UAT or external bank integration tested.
 *   Production rollout still requires that review; local automated tests alone
 *   are not a declaration of operational readiness.
 *
 * LOCAL VALIDATION:
 * - Fresh PostgreSQL 17 replay: 129 migrations plus seed.
 * - All 52 SQL scripts, including security/read-only and deferred integrity tests.
 * - 773 web tests / 92 files; TypeScript and production bundle passed.
 * - 13 new real two-session cancellation cash races plus unchanged 5 premium-cash,
 *   6 co-insurance and 8 cancellation-approval races passed (32 total).
 * - Exact-cent calculator parity preserved; foundation calculations unchanged.
 * - Tenant-FK audit: no rows. New public RPCs have server authorization; private
 *   helpers have no authenticated/anonymous grants. Existing unrelated security-
 *   definer audit findings and bundle circular/large-chunk warnings remain.
 * - Temporary 1GB local swap was used in the 2GB validation sandbox only.
 */
export const cancellationCashHandoff = {
  incrementalBase: '20fe73d',
  migration: '20261015210000_ins_cancellation_cash.sql',
  cashBookingWorkflowImplemented: true,
  automaticBankInstructionsEnabled: false,
  operationalFinanceUatRequired: true,
  productionDeploymentPerformed: false,
  validation: {
    migrations: 129,
    sqlScripts: 52,
    webTests: 773,
    webTestFiles: 92,
    cashConcurrencyRaces: 13,
    existingConcurrencyRaces: 19,
    typecheck: 'passed',
    productionBundle: 'passed-with-existing-warnings',
  },
} as const;
