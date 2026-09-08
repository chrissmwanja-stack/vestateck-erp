import { test, expect } from '@playwright/test';
import { loginAs } from './utils/auth';

/**
 * Smoke test for the finance money-flow path: raising a supplier invoice
 * and settling it via Cash & Bank Operations.
 *
 * Uses the non-PO invoice screen deliberately -- it has no dependency on
 * a procurement-generated PO, so this spec can run standalone. It still
 * exercises the same `cash_bank_transactions` settlement path (polymorphic
 * reference_type/reference_id) that PO-linked invoices, expenditure slips,
 * and payroll runs all share.
 */
test.describe('Finance invoice + payment', () => {
  test('a non-PO supplier invoice can be raised and settled', async ({ page }) => {
    const invoiceNo = `E2E-${Date.now()}`;

    await loginAs(page, 'finance');

    await test.step('Raise a non-PO supplier invoice', async () => {
      await page.goto('/financial-management/invoices/supplier-invoice-non-po');
      await page.getByRole('button', { name: /new supplier invoice/i }).click();

      // The entry form is an inline Card toggled by state, not a MUI
      // Dialog -- there's no role="dialog" wrapper to scope into here.
      const formHeading = page.getByRole('heading', { name: 'New Supplier Invoice' });
      await expect(formHeading).toBeVisible();

      for (const label of ['Organization', /cost center/i, /vendor account/i]) {
        await test.step(`pick ${String(label)}`, async () => {
          await page.getByLabel(label).click();
          const option = page.getByRole('option').first();
          // The three lookup tables are RLS-gated to finance team
          // members; if this times out, finance@test.local is probably
          // missing its finance_team_members row (seed.sql adds it) or
          // the app isn't pointed at the DB that was just reset.
          await expect(
            option,
            `No '${String(label)}' options rendered. Seeded lookup rows exist for the demo tenant; ` +
              `check that (1) apps/web/.env points at the project you 'supabase db reset', and ` +
              `(2) finance@test.local has a finance_team_members row (fresh seed adds it).`
          ).toBeVisible({ timeout: 10_000 });
          await option.click();
        });
      }

      await page.getByLabel(/invoice no/i).fill(invoiceNo);
      await page.getByLabel(/invoice date/i).fill('2026-09-08');
      await page.getByLabel(/amount \(incl\. vat\)/i).fill('80000');

      await page.getByRole('button', { name: 'Save' }).click();
      await expect(formHeading).toBeHidden({ timeout: 15_000 });
      await expect(page.getByText(invoiceNo)).toBeVisible({ timeout: 10_000 });
    });

    await test.step('Settle it via Cash & Bank Operations', async () => {
      await page.goto('/financial-management/cash-bank-operations');
      await page.getByRole('button', { name: 'New Transaction' }).click();

      await page.getByLabel('Transaction Type').click();
      await page.getByRole('option', { name: /payment \(money out\)/i }).click();

      await page.getByLabel('Payment Method').click();
      await page.getByRole('option', { name: 'Bank' }).click();

      await page.getByLabel('Settles Against').click();
      await page.getByRole('option', { name: 'Supplier Invoice' }).click();

      const refField = page.getByLabel(/Supplier Invoice No\./i);
      await refField.click();
      await refField.fill(invoiceNo);
      const refOption = page.getByRole('option', { name: new RegExp(invoiceNo) });
      await expect(refOption).toBeVisible({ timeout: 10_000 });
      await refOption.click();

      await page.getByLabel('Amount').fill('80000');
      await page.getByLabel('Bank Account').fill('E2E Test Account');
      await page.getByLabel('Description').fill('E2E smoke settlement');

      await page.getByRole('button', { name: 'Save' }).click();
      await expect(page.getByText('E2E smoke settlement')).toBeVisible({ timeout: 15_000 });
    });
  });
});
