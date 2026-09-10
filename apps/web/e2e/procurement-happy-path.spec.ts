import { test, expect } from '@playwright/test';
import { loginAs, logout } from './utils/auth';

/**
 * Smoke test for the procurement money-flow path:
 *   Cost Control Engineer submits a request
 *     -> Cost Control Manager approves it (advances to offer entry)
 *     -> Procurement logs 2 vendor offers (MIN_OFFERS_REQUIRED)
 *     -> Procurement & Logistics Chief picks the winning offer and approves
 *     -> (below threshold) it lands on Finance's Purchase Orders list
 *
 * This exercises the same 4 screens covered by the component-test suite
 * (RequestSubmissionForm, ApprovalQueue, OfferEntry, OfferApprovalPO) but
 * end-to-end against a real Supabase backend, so it catches integration
 * breaks the component tests can't (RLS gaps, RPC signature drift, the
 * actual notification triggers firing, real threshold routing).
 *
 * A unique description is used as the correlation key across screens
 * instead of hunting for a request id, since the UI surfaces the
 * description, not the id, on every stage's queue.
 */
test.describe('Procurement happy path', () => {
  test('a request moves from submission to an issued PO', async ({ page }) => {
    const marker = `E2E smoke ${Date.now()}`;

    await test.step('Cost Control Engineer submits a request', async () => {
      await loginAs(page, 'costControlEngineer');
      await page.goto('/requests/new');

      await page.getByLabel('Description').fill(marker);

      // getByLabel matches both the combobox input and, once opened, the
      // MUI listbox (it's aria-labelledby the same label). getByRole with
      // the combobox role disambiguates regardless of open/closed state.
      const costCenterInput = page.getByRole('combobox', { name: 'Cost center' });
      await costCenterInput.click();
      await costCenterInput.fill('');
      // Type nothing further -- just open the list and take whichever
      // cost center comes up first, since real seeded cost centers vary
      // by environment and we don't want this test coupled to one name.
      const firstOption = page.getByRole('option').first();
      // Two cost centers are seeded for the demo tenant (seed.sql). If
      // none render, the app is talking to a project that wasn't reset
      // (check apps/web/.env + no stale dev server on :5173) or the
      // seeded rows are missing.
      await expect(
        firstOption,
        'No cost center options rendered. seed.sql seeds 2 for the demo tenant; ' +
          'check that apps/web/.env points at the project you just "supabase db reset".'
      ).toBeVisible({ timeout: 10_000 });
      await firstOption.click();

      const materialInput = page.getByPlaceholder('Type or pick from catalog').first();
      await materialInput.fill('E2E smoke test material');
      const qtyInput = page.getByRole('spinbutton').first();
      await qtyInput.fill('1');

      await page.getByRole('button', { name: /submit request/i }).click();

      // Success clears the Description field back to empty.
      await expect(page.getByLabel('Description')).toHaveValue('', { timeout: 15_000 });
      await logout(page);
    });

    await test.step('Cost Control Engineer approves their own submission', async () => {
      // set_request_defaults() puts a new request at the LOWEST
      // sequence_order workflow stage, which is "Cost Control Engineer"
      // itself (seq 1) -- the same role as the submitter, not "Cost
      // Control Manager" (seq 2). approval_assignments only grants
      // cce@test.local rights on that first stage, so the request sits
      // there until they sign off on it themselves; only then does it
      // advance into the Manager's queue.
      await loginAs(page, 'costControlEngineer');
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

    await test.step('Cost Control Manager approves the request', async () => {
      await loginAs(page, 'costControlManager');
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

    await test.step('Procurement logs 2 competing offers', async () => {
      await loginAs(page, 'procurementOfferEntry');
      await page.goto('/offers/entry');

      await expect(page.getByText(marker, { exact: true })).toBeVisible({ timeout: 15_000 });

      for (const [vendor, amount] of [
        ['E2E Vendor A', '4500'],
        ['E2E Vendor B', '4200'],
      ] as const) {
        await page.getByRole('button', { name: /add offer/i }).click();
        await page.getByLabel('Vendor name').fill(vendor);
        await page.getByLabel('Quotation amount').fill(amount);
        await page.getByRole('button', { name: /save offer/i }).click();
        // Wait for the save round-trip to finish (dialog closes) before
        // opening it again -- otherwise the second "Add offer" click can
        // land while the first save is still in flight and clobber it.
        await expect(page.getByRole('dialog')).toBeHidden({ timeout: 10_000 });
      }

      await expect(page.getByText('2 offers logged')).toBeVisible({ timeout: 10_000 });
      await page.getByRole('button', { name: /send to budget controller/i }).click();
      // "Send to Budget Controller" only opens a confirmation dialog --
      // the request stays at offer entry until "Send for approval" runs
      // submit_offers_for_approval() and moves it to Budget Controller.
      const sendDialog = page.getByRole('dialog');
      await sendDialog.getByRole('button', { name: /send for approval/i }).click();
      await expect(sendDialog).toBeHidden({ timeout: 10_000 });
      await expect(page.getByText(marker, { exact: true })).toBeHidden({ timeout: 10_000 });
      await logout(page);
    });

    await test.step('Procurement Chief picks the winning offer and approves', async () => {
      await loginAs(page, 'procurementChief');
      await page.goto('/offers/approval-po');

      // Scope the Approve click to this run's row -- other requests from
      // earlier runs may legitimately share this queue.
      const row = page.getByText(marker, { exact: true });
      await expect(row).toBeVisible({ timeout: 15_000 });
      const tableRow = row.locator('xpath=ancestor::tr[1]');
      await tableRow.getByRole('button', { name: 'Approve' }).click();

      const dialog = page.getByRole('dialog');
      // Cheapest offer (E2E Vendor B, 4200) should be selectable as the winner.
      await dialog.getByText(/E2E Vendor B/i).click();
      await expect(dialog.getByRole('radio', { name: /E2E Vendor B/i })).toBeChecked({ timeout: 5_000 });
      await dialog.getByRole('button', { name: /confirm/i }).click();
      await expect(dialog).toBeHidden({ timeout: 10_000 });
      await logout(page);
    });

    await test.step('Finance sees the resulting purchase order', async () => {
      await loginAs(page, 'finance');
      await page.goto('/finance/purchase-orders');

      await expect(page.getByText(marker, { exact: true })).toBeVisible({ timeout: 15_000 });
    });
  });
});