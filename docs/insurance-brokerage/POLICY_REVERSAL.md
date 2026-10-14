# Restricted policy reversal and draft reissue

Implementation prepared against `00aa643` on 14 October 2026. This is source work pending PR CI, a real test Supabase rollout and accountant acceptance; it is not evidence of production deployment.

## Confirmed owner choices

- Two consuming credit notes and their two linked journals in one transaction.
- Reversal accounting date is database `current_date`, not the original inception date. A closed original period does not by itself block; a closed current period does.
- Previously voided payments, credit applications, recognition and transfers are not permanent blockers if no effective movement remains and the original accounting reconciles.
- Reissue defaults off. When selected, it creates a linked draft, never auto-binds it.

## Database entry points

Migration: `20261014170000_ins_policy_reversal.sql`.

- `ins_policy_reversal_eligibility(p_policy_id)` returns `{eligible, reason}`. This is advisory and rechecked by the write RPC. Managers/admins only; another tenant receives not-found rather than protected details.
- `ins_reverse_policy(p_policy_id, p_reason, p_reissue, p_request_key)` returns the authoritative reversal row.
- `platform_fin_raise_policy_credit_note_impl(...)` is private: EXECUTE is revoked from public, anon and authenticated. It validates the exact policy, mapped historical commission offset, complete open-item application and a private in-progress operation record. No client flag or public Boolean bypass is added to ordinary credit notes. The general credit-note API remains unchanged.
- `ins_policy_reversals` is SELECT-only for insurance users under tenant RLS. Its completed records are immutable through exposed APIs and incomplete operations cannot commit.

## Eligibility and safety

Refuses:

- Non-active policies, claims in any state, policy renewal chains.
- Posted settlement allocations or posted credit applications on either policy open item.
- Commission records still earned/transferred, with earned date or transfer link remaining.
- Closed current period, missing/void bind journal, unexpected journal shape or unreconciled amounts.
- Changed historical control/commission mappings: restricted v1 refuses rather than reversing the wrong accounts.
- User-level impersonation. Real actor is recorded; normal tenant-level platform support uses existing permission semantics.

Policies and both items are locked; claim and renewal insert guards coordinate on the policy lock. Equivalent retries return the existing result; changed payloads/request keys for a completed original policy are refused. Finance cannot independently void either reversal note or its journal. Generic journal voiding of policy bind journals is also refused; policy accounting must use its dedicated workflow.

## Accounting

For gross 1,000,000, net 900,000, commission 100,000:

1. Premium note: Dr historical commission offset 1,000,000 / Cr AR control 1,000,000.
2. Insurer note: Dr insurer payable 900,000 / Cr same offset 900,000.

Combined: Dr payable 900,000 / Dr commission 100,000 / Cr AR 1,000,000.

The RPC checks that original plus both note journals net to zero **by account**, not merely overall. It does not post a third reversal journal. Both open items are fully consumed through existing credit applications.

Deferred journals use unearned commission. Legacy journals use commission income, detected from the original bind lines rather than a migration date. Zero-commission journals use `none` treatment and equal offset legs cancel; this path requires a distinct commission-income mapping even if the original zero-commission bind did not require one.

Commission evidence is retained, but reversed originals are excluded from active commission ledger/position views. Per-insurer statements label reversed originals, preserve their historical amounts and exclude those amounts from active totals. Statements remain bound-date reports using current status, not historical as-of snapshots. This work does not fix their broader pagination issue.

## UI

Policy detail shows the manager/admin action on active policies, obtains server eligibility, requires a reason of at least five characters and explains accounting/no-refund consequences. The replacement checkbox is unchecked each time a new dialog opens. A retained request key allows retry after an uncertain response. Successful reissue opens the replacement draft. Original and replacement detail pages expose their audit link; reversed originals do not offer claims, renewal or reactivation.

## Tests and rollout

- New SQL regression suite: `supabase/tests/test_ins_policy_reversal.sql`.
- New component suites: `PolicyReversalAction.test.tsx`, `PolicyDetail.test.tsx`.
- Statement logic regression added to `logic.test.ts`.
- Existing Foundation CI automatically runs the SQL and Vitest files after push/PR.

Required test rollout:

1. Push a review branch/PR and require its CI checks. Do not confuse upstream-main success with checks on this patch.
2. Apply all migrations to a fresh disposable **test** Supabase project/local stack. Never run fixture suites against production.
3. Regenerate complete schema types from that stack (`scripts/gen-types.ps1 -Local`), compare with migrations, and investigate drift. The supplied type entries were synchronized for the added objects using local schema metadata; a full Supabase CLI regeneration was not performed here.
4. Run every SQL test with `psql -v ON_ERROR_STOP=1`, web tests, build and a real browser workflow.
5. Obtain accountant approval of the paired gross-offset notes, legacy/zero-commission behavior and reporting.
6. Verify hosted catalog/migration state and release the migration before the frontend that calls its RPCs.

Rejected RPC attempts roll back and do not leave a database audit row; durable rejection logging needs the project's request/external audit channel. Existing unrelated invitation/report/bundle-hardening findings are not closed by this feature.
