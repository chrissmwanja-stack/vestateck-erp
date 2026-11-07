import { test, expect, type Page } from '@playwright/test';

/**
 * In-force portfolio import (docs/insurance-brokerage/IN_FORCE_IMPORT.md,
 * build order step 5): upload a canonical-template workbook, stage, validate,
 * commit, post the opening position and reconcile.
 *
 * Uses the seeded insurance manager (seed.sql section: ins.manager@test.local,
 * password Tester123) because staging/commit/opening are manager RPCs.
 * The batch label is unique per run so reruns don't collide.
 */

async function loginAsInsuranceManager(page: Page) {
  await page.goto('/login');
  await page.getByLabel('Email').fill('ins.manager@test.local');
  await page.getByLabel('Password', { exact: true }).fill('Tester123');
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page.getByRole('button', { name: 'Sign out' })).toBeVisible({ timeout: 15_000 });
}

test.describe('Insurance in-force import wizard', () => {
  test('stage -> validate -> commit -> opening position -> reconcile', async ({ page }) => {
    const label = `E2E import ${Date.now()}`;
    const cutOver = new Date().toISOString().slice(0, 10);

    await loginAsInsuranceManager(page);
    await page.goto('/insurance/admin/import');
    await expect(page.getByText('In-force portfolio import')).toBeVisible({ timeout: 30_000 });

    await test.step('stage a workbook', async () => {
      await page.getByLabel('Batch label').fill(label);
      await page.getByLabel('Cut-over date').fill(cutOver);
      // A minimal CSV standing in for the canonical template's policies sheet.
      const csv = [
        'legacy_policy_no,client_name,insurer,product_line,inception_date,expiry_date,currency,gross_premium,commission_rate_pct',
        `E2E-${Date.now()},Kampala Transport Ltd,ICEA,MOTOR,2026-01-01,2026-12-31,UGX,1000000,10`,
      ].join('\n');
      const buffer = Buffer.from(csv);
      await page.getByRole('button', { name: /Choose workbook/ }).setInputFiles({
        name: 'import.csv', mimeType: 'text/csv', buffer,
      });
      await page.getByRole('button', { name: 'Stage rows' }).click();
      await expect(page.getByText('Validate')).toBeVisible({ timeout: 15_000 });
    });

    await test.step('validate', async () => {
      await page.getByRole('button', { name: 'Run validation' }).click();
      await expect(page.getByText('Commit policies')).toBeVisible({ timeout: 15_000 });
    });

    await test.step('commit policies', async () => {
      await page.getByRole('button', { name: 'Commit policies' }).click();
      await expect(page.getByText('Opening position')).toBeVisible({ timeout: 15_000 });
    });

    await test.step('post opening position', async () => {
      await page.getByRole('button', { name: 'Post opening position' }).click();
      await expect(page.getByRole('button', { name: 'Run reconciliation' })).toBeVisible({ timeout: 15_000 });
    });

    await test.step('reconcile shows the control comparison', async () => {
      await page.getByRole('button', { name: 'Run reconciliation' }).click();
      await expect(page.getByText('gross_premium')).toBeVisible({ timeout: 15_000 });
    });
  });
});
