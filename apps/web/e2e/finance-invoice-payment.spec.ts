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

      const dialog = page.getByRole('dialog');
      await expect(dialog.getByRole('heading', { name: 'New Supplier Invoice' })).toBeVisible();

      for (const label of ['Organization', /cost center/i, /vendor account/i]) {
        await dialog.getByLabel(label).click();
        const option = page.getByRole('option').first();
        await expect(option).toBeVisible({ timeout: 10_000 });
        await option.click();
      }

      await dialog.getByLabel(/invoice no/i).fill(invoiceNo);
      await dialog.getByLabel(/invoice date/i).fill('2026-09-08');
      await dialog.getByLabel(/amount \(incl\. vat\)/i).fill('80000');

      await dialog.getByRole('button', { name: 'Save' }).click();
      await expect(dialog).toBeHidden({ timeout: 15_000 });
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
