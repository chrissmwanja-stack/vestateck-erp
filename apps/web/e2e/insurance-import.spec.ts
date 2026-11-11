import { test, expect, type Locator, type Page } from '@playwright/test';

/**
 * In-force portfolio import (docs/insurance-brokerage/IN_FORCE_IMPORT.md,
 * build order step 5): upload a canonical-template workbook, stage, validate,
 * commit, post the opening position and reconcile.
 *
 * The canonical workbook is ONE file with a sheet per source: policies,
 * receipts, remittances, shares and control_totals. The opening position is
 * computed from all of them - receipts against the premium, remittances out
 * of the client-money float, and the reviewer's control totals deciding
 * whether the batch may be committed at all - so a spec that uploads a
 * single-sheet CSV only ever exercises the policies path. This spec builds a
 * real multi-sheet .xlsx for each scenario.
 *
 * Uses the seeded insurance accounts (seed.sql section: ins.manager@test.local
 * and ins.admin@test.local, password Tester123). Staging/commit/opening are
 * manager-tier RPCs; approving a control-total difference must be done by
 * SOMEONE OTHER THAN THE UPLOADER (INS_IMPORT_CONTROL_OVERRIDE_SELF), which is
 * why the second scenario signs in twice.
 *
 * Batch labels are unique per run so reruns don't collide.
 */

const MANAGER = 'ins.manager@test.local';
const ADMIN = 'ins.admin@test.local';
const PASSWORD = 'Tester123';

async function loginAs(page: Page, email: string) {
  await page.goto('/login');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password', { exact: true }).fill(PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page.getByRole('button', { name: 'Sign out' })).toBeVisible({ timeout: 15_000 });
}

// After a wizard action either the next control appears or the page shows an
// error banner (the RPC was refused). Fail with the banner text instead of a
// bare "element not found" timeout.
async function expectNext(page: Page, next: Locator, timeout = 15_000) {
  const errorBanner = page.locator(
    '[class*="MuiAlert-standardError"], [class*="MuiAlert-filledError"], [class*="MuiAlert-outlinedError"]',
  ).first();
  const outcome = await Promise.race([
    next.waitFor({ state: 'visible', timeout }).then(() => 'next' as const),
    errorBanner.waitFor({ state: 'visible', timeout }).then(() => 'error' as const),
  ]).catch(() => 'timeout' as const);
  if (outcome === 'error') {
    throw new Error(`Wizard refused the step: ${(await errorBanner.innerText()).trim()}`);
  }
  await expect(next).toBeVisible({ timeout: 1_000 });
}

/** Builds an .xlsx from {sheetName: rows[]} with the headers taken from the
 *  first row's keys - the same shape the customer's template has. */
async function buildWorkbook(sheets: Record<string, Record<string, string | number>[]>): Promise<Buffer> {
  const mod = await import('xlsx');
  const X = ((mod as unknown as { default?: typeof mod }).default ?? mod);
  const wb = X.utils.book_new();
  for (const [name, sheetRows] of Object.entries(sheets)) {
    X.utils.book_append_sheet(wb, X.utils.json_to_sheet(sheetRows), name);
  }
  return X.write(wb, { type: 'buffer', bookType: 'xlsx' }) as Buffer;
}

const GROSS = 1_000_000;
const COMMISSION = 100_000; // 10%
const RECEIPT = 400_000;
const REMITTANCE = 200_000;

/** One policy, one receipt, one remittance, and the control totals that
 *  describe them. `controlOverrides` lets a scenario record totals that
 *  disagree with the book. */
async function bookWorkbook(policyNo: string, controlOverrides: Record<string, string | number> = {}) {
  const today = new Date().toISOString().slice(0, 10);
  return buildWorkbook({
    policies: [{
      legacy_policy_no: policyNo,
      client_name: 'Kampala Transport Ltd',
      insurer: 'SAV',
      product_line: 'MOTOR',
      inception_date: '2026-01-01',
      expiry_date: '2026-12-31',
      currency: 'UGX',
      gross_premium: GROSS,
      commission_rate_pct: 10,
    }],
    receipts: [{ legacy_policy_no: policyNo, receipt_date: today, amount: RECEIPT }],
    remittances: [{ legacy_policy_no: policyNo, remit_date: today, amount: REMITTANCE }],
    control_totals: [{
      currency: 'UGX',
      policy_count: 1,
      gross_premium: GROSS,
      commission: COMMISSION,
      receipts: RECEIPT,
      remittances: REMITTANCE,
      client_money: RECEIPT - REMITTANCE,
      // Reported after posting, never part of the commit gate: receivable is
      // billed less received, payable is net premium less remitted, and the
      // commission is deferred because the insurer net is not fully remitted.
      receivables: GROSS - RECEIPT,
      payables: GROSS - COMMISSION - REMITTANCE,
      unearned_commission: COMMISSION,
      ...controlOverrides,
    }],
  });
}

async function stageWorkbook(page: Page, label: string, workbook: Buffer) {
  await page.goto('/insurance/admin/import');
  await expect(page.getByText('In-force portfolio import')).toBeVisible({ timeout: 30_000 });
  await page.getByLabel('Batch label').fill(label);
  await page.getByLabel('Cut-over date').fill(new Date().toISOString().slice(0, 10));
  // The MUI button is a <label> wrapping a hidden <input type=file>; target the input.
  await page.locator('input[type="file"]').setInputFiles({
    name: 'book.xlsx',
    mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    buffer: workbook,
  });
  await page.getByRole('button', { name: 'Stage rows' }).click();
  await expectNext(page, page.getByRole('button', { name: 'Run validation' }));
}

test.describe('Insurance in-force import wizard', () => {
  test('a multi-sheet workbook posts its history and reconciles against the control totals', async ({ page }) => {
    const label = `E2E import ${Date.now()}`;
    const policyNo = `E2E-${Date.now()}`;

    await loginAs(page, MANAGER);
    await stageWorkbook(page, label, await bookWorkbook(policyNo));

    await test.step('validate the whole workbook, not just the policies sheet', async () => {
      await page.getByRole('button', { name: 'Run validation' }).click();
      await expectNext(page, page.getByRole('button', { name: 'Commit policies' }));
    });

    await test.step('the book agrees with the recorded control totals', async () => {
      await page.getByRole('button', { name: 'Compare with control totals' }).click();
      await expectNext(page, page.getByText(/Control totals agree/));
      // Every measure the workbook recorded must read "match". A false
      // difference here is the regression the old COALESCE(control, 0)
      // comparison produced on a perfect batch.
      const rows = page.locator('tbody tr').filter({ hasText: 'UGX' });
      await expect(rows).toHaveCount(6); // policy count + 4 money measures + client money
      await expect(page.getByText('DIFF')).toHaveCount(0);
      await expect(page.getByText('not recorded')).toHaveCount(0);
    });

    await test.step('commit policies', async () => {
      await page.getByRole('button', { name: 'Commit policies' }).click();
      await expectNext(page, page.getByRole('button', { name: 'Post opening position' }));
    });

    await test.step('post opening position', async () => {
      await page.getByRole('button', { name: 'Post opening position' }).click();
      await expectNext(page, page.getByRole('button', { name: 'Run reconciliation' }));
    });

    await test.step('reconcile shows the ledger agreeing too', async () => {
      await page.getByRole('button', { name: 'Run reconciliation' }).click();
      await expectNext(page, page.getByRole('cell', { name: 'gross_premium', exact: true }).first());
      // client_money is the leg-4 measure: receipts less remittances per
      // currency, checked against the balance the reviewer recorded.
      await expect(page.getByRole('cell', { name: 'client_money', exact: true })).toBeVisible();
      // The post-posting report: journal, open items and legacy totals agree
      // on the three measures the commit gate cannot see.
      await expect(page.getByRole('cell', { name: 'receivables', exact: true })).toBeVisible();
      await expect(page.getByRole('cell', { name: 'payables', exact: true })).toBeVisible();
      await expect(page.getByRole('cell', { name: 'unearned_commission', exact: true })).toBeVisible();
      await expect(page.getByText(/agree on receivables, payables and unearned commission/)).toBeVisible();
      await expect(page.getByText('DIFF')).toHaveCount(0);
    });
  });

  test('a difference stops the commit until a second person explains it', async ({ page }) => {
    const label = `E2E import diff ${Date.now()}`;
    const policyNo = `E2E-DIFF-${Date.now()}`;

    await loginAs(page, MANAGER);
    // The reviewer's sheet says the legacy ledger held 1,250,000 of premium
    // for this book; the staged policies only add up to 1,000,000.
    await stageWorkbook(page, label, await bookWorkbook(policyNo, { gross_premium: 1_250_000 }));
    await page.getByRole('button', { name: 'Run validation' }).click();
    await expectNext(page, page.getByRole('button', { name: 'Commit policies' }));

    await test.step('the difference is shown, and the commit is refused', async () => {
      await page.getByRole('button', { name: 'Compare with control totals' }).click();
      await expect(page.getByText('DIFF').first()).toBeVisible({ timeout: 15_000 });
      await expect(page.getByText(/disagree with the staged book/)).toBeVisible();

      await page.getByRole('button', { name: 'Commit policies' }).click();
      const banner = page.locator('[class*="MuiAlert-standardError"], [class*="MuiAlert-filledError"]').first();
      await expect(banner).toBeVisible({ timeout: 15_000 });
      await expect(page.getByRole('button', { name: 'Post opening position' })).toHaveCount(0);
    });

    // The approval link is the batch URL: the uploader sends it to the admin,
    // who opens it on their own session (the wizard restores the step from the
    // batch's status).
    const reviewUrl = page.url();
    expect(reviewUrl).toContain('batch=');

    await test.step('a second person approves the difference with a reason', async () => {
      await page.getByRole('button', { name: 'Sign out' }).click();
      await loginAs(page, ADMIN);
      await page.goto(reviewUrl);
      await expect(page.getByText(/Opened batch/)).toBeVisible({ timeout: 15_000 });
      await page.getByRole('button', { name: 'Compare with control totals' }).click();
      await expect(page.getByText('DIFF').first()).toBeVisible({ timeout: 15_000 });

      const approve = page.getByRole('button', { name: 'Approve difference' });
      await expect(approve).toBeDisabled();
      await page.getByLabel('Why do the totals differ?').fill('Two merged policies in the legacy ledger.');
      await expect(approve).toBeEnabled();
      await approve.click();
      await expect(page.getByText(/Approved 1 difference/)).toBeVisible({ timeout: 15_000 });
    });

    await test.step('now the commit goes through', async () => {
      await page.getByRole('button', { name: 'Commit policies' }).click();
      await expectNext(page, page.getByRole('button', { name: 'Post opening position' }));
    });
  });
});
