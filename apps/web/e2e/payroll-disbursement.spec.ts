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
 * by a job title. A FRESH `supabase db reset` now seeds pm@test.local
 * as an active approver (seed.sql), so no manual grant is needed on a
 * fresh stack. Environments that predate that seed addition still need
 * a one-time grant: log in as hr@test.local, open
 * /hr/admin/payroll-approvers, and add pm@test.local.
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

      // "New run" only renders for HR team members (is_hr_team_member()).
      // Fresh seeds give hr@test.local an hr_team_members row; if the
      // button never appears, either that row is missing on the target
      // project or the app is pointed at a project that wasn't reset.
      await expect(
        page.getByRole('button', { name: 'New run' }),
        '"New run" never appeared -- hr@test.local is not an HR team member here. ' +
          'A fresh seed adds hr_team_members; check apps/web/.env points at the ' +
          'project you just "supabase db reset".'
      ).toBeVisible({ timeout: 30_000 });
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
      // Leave Amount as-is: openDisburse() pre-fills it with the run's
      // actual remaining balance. Overwriting it with an arbitrary small
      // number (e.g. '1') leaves amount_disbursed short of total_net, so
      // check_payroll_disbursement() never flips status to 'disbursed'
      // and the run just sits at "Approved · awaiting disbursement".
      await dialog.getByLabel('Description').fill('E2E smoke disbursement');

      await dialog.getByRole('button', { name: 'Record Disbursement' }).click();
      await expect(dialog).toBeHidden({ timeout: 15_000 });
      await expect(page.getByText('Disbursed')).toBeVisible({ timeout: 10_000 });
    });
  });
});
