import { test, expect } from '@playwright/test';
import { loginAs, logout } from './utils/auth';
import { uniquePayrollPeriod } from './utils/period';

/**
 * Payroll approval -- the REJECT branch, which payroll-disbursement.spec.ts
 * deliberately avoids (it walks the approve -> disburse path).
 *
 *   HR creates a run, generates items, submits for approval
 *     -> the approver (pm@test.local, seeded as a payroll approver)
 *        rejects it with a reason
 *     -> HR sees the run back on /hr/payroll with a "rejected" chip
 *        and the reason attached
 *
 * The period is random per run (see utils/period.ts) so reruns against the
 * same database don't hit the UNIQUE (tenant_id, period) constraint.
 */
test.describe('Payroll approval -- reject path', () => {
  test('a rejected payroll run surfaces its reason back to HR', async ({ page }) => {
    const period = uniquePayrollPeriod();
    const reason = `E2E reject reason ${Date.now()}: NSSF figures need a second look`;

    await test.step('HR creates, generates, and submits a payroll run', async () => {
      await loginAs(page, 'hr');
      await page.goto('/hr/payroll');

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

    await test.step('Approver rejects the run with a reason', async () => {
      await loginAs(page, 'projectManager');
      await page.goto('/hr/payroll/approvals');

      const row = page.getByText(period, { exact: false });
      await expect(
        row,
        'Run never appeared in the approver queue -- pm@test.local is not an active ' +
          'payroll approver on this project. A fresh seed grants it (seed.sql section 3).'
      ).toBeVisible({ timeout: 15_000 });

      // Scope to this run's card via its Reject button; other runs from
      // prior executions may legitimately share the queue.
      const card = row.locator('xpath=ancestor::*[.//button[normalize-space()="Reject"]][1]');

      // A blank reason must be refused by the form first (--bmp rails: the
      // RPC is p_reason NOT NULL-ish in spirit; the screen blocks empty).
      await card.getByRole('button', { name: 'Reject' }).click();
      const dialog = page.getByRole('dialog');
      await dialog.getByRole('button', { name: 'Reject', exact: true }).click();
      await expect(
        dialog.getByText(/reason is required/i),
        'Reject dialog accepted an empty reason.'
      ).toBeVisible({ timeout: 5_000 });

      await dialog.getByLabel('Reason').fill(reason);
      await dialog.getByRole('button', { name: 'Reject', exact: true }).click();
      await expect(dialog).toBeHidden({ timeout: 15_000 });
      // Rejected runs leave the pending approvals queue entirely.
      await expect(row).toBeHidden({ timeout: 15_000 });
      await logout(page);
    });

    await test.step('HR sees the run rejected, with the approver\`s reason', async () => {
      await loginAs(page, 'hr');
      await page.goto('/hr/payroll');

      const row = page.getByText(period, { exact: false });
      await expect(row).toBeVisible({ timeout: 15_000 });

      // The status chip sits on the run's header, like the period.
      const header = row.locator('xpath=ancestor::*[.//*[normalize-space()="rejected"] or .//*[normalize-space()="draft"]][1]');
      await expect(
        header.getByText(/^rejected$/i),
        'Run does not show a "rejected" chip for HR after the approver rejected it.'
      ).toBeVisible({ timeout: 10_000 });

      // The approver's reason only renders on the EXPANDED run row
      // ('Sent back by an approver: "..."' -- PayrollList.tsx).
      await row.click();
      await expect(
        page.getByText(/NSSF figures need a second look/i),
        'The rejection reason is not visible back on the expanded payroll run.'
      ).toBeVisible({ timeout: 10_000 });
    });
  });
});
