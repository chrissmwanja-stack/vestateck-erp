import { test, expect } from '@playwright/test';
import { loginAs, logout } from './utils/auth';

/**
 * Threshold-branch test for the procurement approval chain -- the HIGH
 * (above-threshold) side, which the happy-path spec deliberately avoids.
 *
 * Seeded workflow (supabase/seed.sql section 1):
 *   ... -> "Procurement: Offer Entry" -> Budget Controller
 *     -> stage "Control Chief/Manager" (threshold_amount = 5,000,000)
 *          quotation <= 5,000,000  -> next_stage_low  = Finance (PO lands)
 *          quotation >  5,000,000  -> next_stage_high = Project Manager
 *                                      -> Deputy General Manager -> Finance
 *
 * This spec logs competing offers both ABOVE 5M, approves them at the
 * Chief stage, and asserts the request stops first with the Project
 * Manager, then the Deputy General Manager, before Finance ever sees a
 * purchase order. The same correlation-marker idiom as
 * procurement-happy-path.spec.ts is used throughout.
 *
 * RERUN SAFETY: a completely fresh run works against the seeded tenant;
 * the marker is unique per run, so prior runs' approved POs never
 * collide with this run's assertions.
 */
test.describe('Procurement threshold branch (>5M)', () => {
  test('a high-value request routes through PM and GM before Finance', async ({ page }) => {
    const marker = `E2E threshold ${Date.now()}`;

    await test.step('Cost Control Engineer submits a request', async () => {
      await loginAs(page, 'costControlEngineer');
      await page.goto('/requests/new');

      await page.getByLabel('Description').fill(marker);

      const costCenterInput = page.getByRole('combobox', { name: 'Cost center' });
      await costCenterInput.click();
      await costCenterInput.fill('');
      const firstOption = page.getByRole('option').first();
      await expect(
        firstOption,
        'No cost center options rendered. seed.sql seeds 2 for the demo tenant; ' +
          'check that apps/web/.env points at the project you just "supabase db reset".'
      ).toBeVisible({ timeout: 10_000 });
      await firstOption.click();

      const materialInput = page.getByPlaceholder('Type or pick from catalog').first();
      await materialInput.fill('E2E threshold test material');
      const qtyInput = page.getByRole('spinbutton').first();
      await qtyInput.fill('1');

      await page.getByRole('button', { name: /submit request/i }).click();
      await expect(page.getByLabel('Description')).toHaveValue('', { timeout: 15_000 });
      await logout(page);
    });

    // Same two self-approval hops as the happy path -- the request starts
    // at the lowest workflow stage (Cost Control Engineer, seq 1), which
    // approval_assignments grants only to cce@test.local.
    for (const [key, label] of [
      ['costControlEngineer', 'Cost Control Engineer'],
      ['costControlManager', 'Cost Control Manager'],
    ] as const) {
      await test.step(`${label} approves`, async () => {
        await loginAs(page, key);
        await page.goto('/approvals');

        const row = page.getByText(marker, { exact: true });
        await expect(row).toBeVisible({ timeout: 15_000 });
        const card = row.locator('xpath=ancestor::*[.//button[normalize-space()="Approve"]][1]');
        await card.getByRole('button', { name: 'Approve' }).click();

        const dialog = page.getByRole('dialog');
        await dialog.getByRole('button', { name: /confirm/i }).click();
        await expect(dialog).toBeHidden({ timeout: 10_000 });
        await expect(row).toBeHidden({ timeout: 10_000 });
        await logout(page);
      });
    }

    await test.step('Procurement logs 2 competing offers ABOVE the 5M threshold', async () => {
      await loginAs(page, 'procurementOfferEntry');
      await page.goto('/offers/entry');

      await expect(
        page.getByText(/Not available to you/i),
        'Offer entry blocked by the procurement module guard -- rerun `supabase db reset`.'
      ).toBeHidden({ timeout: 15_000 });
      await expect(page.getByText(marker, { exact: true })).toBeVisible({ timeout: 15_000 });

      // Both quotations above 5,000,000: whichever wins, the request
      // must take the HIGH branch at the Control Chief/Manager stage.
      for (const [vendor, amount] of [
        ['E2E Threshold Vendor A', '6800000'],
        ['E2E Threshold Vendor B', '6500000'],
      ] as const) {
        await page.getByRole('button', { name: /add offer/i }).click();
        await page.getByLabel('Vendor name').fill(vendor);
        await page.getByLabel('Quotation amount').fill(amount);
        await page.getByRole('button', { name: /save offer/i }).click();
        await expect(page.getByRole('dialog')).toBeHidden({ timeout: 10_000 });
      }

      await expect(page.getByText('2 offers logged')).toBeVisible({ timeout: 10_000 });
      await page.getByRole('button', { name: /send to budget controller/i }).click();
      const sendDialog = page.getByRole('dialog');
      await sendDialog.getByRole('button', { name: /send for approval/i }).click();
      await expect(sendDialog).toBeHidden({ timeout: 10_000 });
      await expect(page.getByText(marker, { exact: true })).toBeHidden({ timeout: 10_000 });
      await logout(page);
    });

    await test.step('Procurement Chief picks the winning offer and approves', async () => {
      await loginAs(page, 'procurementChief');
      await page.goto('/offers/approval-po');

      await expect(
        page.getByText(/Not available to you/i),
        'Offer approval blocked by the procurement module guard -- rerun `supabase db reset`.'
      ).toBeHidden({ timeout: 15_000 });

      const row = page.getByText(marker, { exact: true });
      await expect(row).toBeVisible({ timeout: 15_000 });
      const tableRow = row.locator('xpath=ancestor::tr[1]');
      await tableRow.getByRole('button', { name: 'Approve' }).click();

      const dialog = page.getByRole('dialog');
      await dialog.getByText(/E2E Threshold Vendor B/i).click();
      await expect(dialog.getByRole('radio', { name: /E2E Threshold Vendor B/i })).toBeChecked({ timeout: 5_000 });
      await dialog.getByRole('button', { name: /confirm/i }).click();
      await expect(dialog).toBeHidden({ timeout: 10_000 });
      await logout(page);
    });

    await test.step('Finance does NOT see a PO yet (high branch pending)', async () => {
      // The winning 6.5M quotation exceeds the 5,000,000 threshold on the
      // Control Chief/Manager stage, so next_stage_high_id routes the
      // request to Project Manager -> Deputy General Manager BEFORE the
      // terminal Finance stage. A PO on Finance's list here would mean
      // the threshold branch leaked straight to Finance.
      await loginAs(page, 'finance');
      await page.goto('/financial-management/purchase-orders');
      await expect(
        page.getByText(marker, { exact: true }),
        'Finance already sees a PO for an above-threshold request -- the high ' +
          'approval branch (Project Manager / Deputy GM) was skipped.'
      ).toBeHidden({ timeout: 10_000 });
      await logout(page);
    });

    await test.step('Project Manager approves (first high-branch hop)', async () => {
      await loginAs(page, 'projectManager');
      await page.goto('/approvals');

      const row = page.getByText(marker, { exact: true });
      await expect(
        row,
        'Request never reached the Project Manager stage even though the winning ' +
          'offer exceeded the 5,000,000 threshold_amount on the Control Chief/Manager stage.'
      ).toBeVisible({ timeout: 15_000 });
      const card = row.locator('xpath=ancestor::*[.//button[normalize-space()="Approve"]][1]');
      await card.getByRole('button', { name: 'Approve' }).click();

      const dialog = page.getByRole('dialog');
      await dialog.getByRole('button', { name: /confirm/i }).click();
      await expect(dialog).toBeHidden({ timeout: 10_000 });
      await expect(row).toBeHidden({ timeout: 10_000 });
      await logout(page);
    });

    await test.step('Finance still does not see a PO (GM hop pending)', async () => {
      await loginAs(page, 'finance');
      await page.goto('/financial-management/purchase-orders');
      await expect(
        page.getByText(marker, { exact: true }),
        'Finance sees a PO before the Deputy General Manager hop completed.'
      ).toBeHidden({ timeout: 10_000 });
      await logout(page);
    });

    await test.step('Deputy General Manager approves (terminal high-branch hop)', async () => {
      await loginAs(page, 'generalManager');
      await page.goto('/approvals');

      const row = page.getByText(marker, { exact: true });
      await expect(
        row,
        'Request never reached the Deputy General Manager stage after the PM approval.'
      ).toBeVisible({ timeout: 15_000 });
      const card = row.locator('xpath=ancestor::*[.//button[normalize-space()="Approve"]][1]');
      await card.getByRole('button', { name: 'Approve' }).click();

      const dialog = page.getByRole('dialog');
      await dialog.getByRole('button', { name: /confirm/i }).click();
      await expect(dialog).toBeHidden({ timeout: 10_000 });
      await expect(row).toBeHidden({ timeout: 10_000 });
      await logout(page);
    });

    await test.step('ONLY NOW does Finance see the purchase order', async () => {
      await loginAs(page, 'finance');
      await page.goto('/financial-management/purchase-orders');

      await expect(
        page.getByText(marker, { exact: true }),
        'After PM + Deputy GM approvals, Finance should see the issued PO but does not.'
      ).toBeVisible({ timeout: 15_000 });
    });
  });
});
