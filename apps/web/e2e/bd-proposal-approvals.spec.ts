import { test, expect } from '@playwright/test';
import { loginAs } from './utils/auth';

/**
 * Business Development proposal approvals -- the last untested module in
 * the P4 e2e sweep, against the seeded pending proposal from seed.sql
 * section 4 ("E2E Pending Approval Proposal", status pending_approval).
 *
 * Why a seeded pending row instead of a UI-created one: the BD UI can
 * only ever CREATE proposals as 'draft' (NewProposal hard-codes status:
 * "draft") and today no screen advances draft -> in_review ->
 * pending_approval -- that hop only exists as enum values + the status
 * tracker. Seeding the pending row lets the approval screen itself be
 * exercised end-to-end; the missing submit-for-approval hop is a known
 * roadmap gap.
 *
 * RERUN SAFETY: approving flips the seeded proposal permanently, so on a
 * second run the pending queue no longer contains it. The spec therefore
 * verifies whichever truthful state the project is in: pending -> approve
 * transition (first run), or the already-approved record persisting on
 * the proposals list (later runs). Either way it proves the approval
 * screen's decision actually landed -- which is the point of the spec.
 */
test.describe('BD proposal approvals', () => {
  test('a pending proposal can be approved (or is verifiably approved)', async ({ page }) => {
    const title = 'E2E Pending Approval Proposal';

    // The approve decision uses window.confirm(), not a MUI Dialog --
    // auto-accept it or the click hangs the whole spec.
    page.on('dialog', (d) => { void d.accept(); });

    await loginAs(page, 'bdOfficer');
    await page.goto('/business-development/proposals/approvals');

    const pendingRow = page.getByText(title, { exact: false });
    const isPending = await pendingRow
      .waitFor({ state: 'visible', timeout: 5_000 })
      .then(() => true)
      .catch(() => false);

    if (isPending) {
      await test.step('Approve the seeded pending proposal', async () => {
        const row = pendingRow.locator('xpath=ancestor::tr[1]');
        await row.getByRole('button', { name: /approve/i }).click();
        // Row leaves the pending-only queue once decided.
        await expect(pendingRow).toBeHidden({ timeout: 15_000 });
      });

      await test.step('It now shows approved on the proposals list', async () => {
        await page.goto('/business-development/proposals');
        const listRow = page.getByText(title, { exact: false });
        await expect(listRow).toBeVisible({ timeout: 15_000 });
        const row = listRow.locator('xpath=ancestor::tr[1]');
        await expect(
          row.getByText(/approved/i),
          'Approved decision did not stick -- proposal still shows a pending-ish status.'
        ).toBeVisible({ timeout: 10_000 });
      });
    } else {
      await test.step('Proposal already approved on a prior run -- verify persistence', async () => {
        await page.goto('/business-development/proposals');
        const listRow = page.getByText(title, { exact: false });
        await expect(
          listRow,
          'Seeded proposal is neither pending nor approved-and-listed. seed.sql ' +
            'section 4 seeds it; a partial/manual DB reset may have dropped it -- ' +
            'rerun `supabase db reset`.'
        ).toBeVisible({ timeout: 15_000 });
        const row = listRow.locator('xpath=ancestor::tr[1]');
        await expect(row.getByText(/approved/i)).toBeVisible({ timeout: 10_000 });
      });
    }
  });
});
