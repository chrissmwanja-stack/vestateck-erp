import { test, expect } from '@playwright/test';
import { loginAs, logout } from './utils/auth';

/**
 * Smoke test for the payroll money-flow path:
 *   HR creates a run, generates items, submits for approval
 *     -> an approver (pm@test.local) approves it
 *     -> Finance records the disbursement
 *
 * NOTE: payroll approval rights are granted per-user via the
 * PayrollApproversAdmin screen (/hr/admin/payroll-approvers), not implied
 * by a job title. This spec assumes pm@test.local is already configured
 * as an approver in the target environment -- if it isn't, the "approve"
 * step will fail with "nothing waiting on you". Grant it there first.
 *
 * Period is derived from the current date so reruns on a new calendar
 * month don't collide with a prior run; reruns within the same month
 * will hit whatever duplicate-period validation the backend has.
 */
test.describe('Payroll disbursement', () => {
  test('a payroll run moves from creation to a recorded disbursement', async ({ page }) => {
    const now = new Date();
    const period = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}`;

    await test.step('HR creates, generates, and submits a payroll run', async () => {
      await loginAs(page, 'hr');
      await page.goto('/hr/payroll');

      await page.getByRole('button', { name: 'New run' }).click();
      const dialog = page.getByRole('dialog');
      await dialog.getByLabel('Period').fill(period);
      await dialog.getByRole('button', { name: 'Create' }).click();
      await expect(dialog).toBeHidden({ timeout: 15_000 });

      await expect(page.getByText(period)).toBeVisible({ timeout: 10_000 });
      await page.getByText(period).click();

      await page.getByRole('button', { name: /generate.*refresh items/i }).click();
      await page.getByRole('button', { name: 'Submit for approval' }).click();
      await expect(page.getByText(/pending approval|submitted/i)).toBeVisible({ timeout: 15_000 });
      await logout(page);
    });

    await test.step('Approver approves the run', async () => {
      await loginAs(page, 'projectManager');
      await page.goto('/hr/payroll/approvals');

      await expect(page.getByText(period)).toBeVisible({ timeout: 15_000 });
      const row = page.getByText(period, { exact: false });
      const card = row.locator('xpath=ancestor::*[.//button[normalize-space()="Approve"]][1]');
      await card.getByRole('button', { name: 'Approve' }).click();
      await expect(card.getByRole('button', { name: 'Approve' })).toBeHidden({ timeout: 15_000 });
      await logout(page);
    });

    await test.step('Finance records the disbursement', async () => {
      await loginAs(page, 'finance');
      await page.goto('/financial-management/payroll-disbursement');

      await expect(page.getByText(period)).toBeVisible({ timeout: 15_000 });
      const row = page.getByText(period, { exact: false });
      const card = row.locator('xpath=ancestor::*[.//button[normalize-space()="Record Disbursement"]][1]');
      await card.getByRole('button', { name: 'Record Disbursement' }).click();

      const dialog = page.getByRole('dialog');
      await dialog.getByLabel('Payment Method').click();
      await page.getByRole('option').first().click();
      await dialog.getByLabel('Bank Account').fill('E2E Test Payroll Account');
      await dialog.getByLabel(/amount/i).fill('1');
      await dialog.getByLabel('Description').fill('E2E smoke disbursement');

      await dialog.getByRole('button', { name: 'Record Disbursement' }).click();
      await expect(dialog).toBeHidden({ timeout: 15_000 });
      await expect(page.getByText('Disbursed')).toBeVisible({ timeout: 10_000 });
    });
  });
});
