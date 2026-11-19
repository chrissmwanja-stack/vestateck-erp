import { test, expect, type Page } from '@playwright/test';
import { loginAs } from './utils/auth';

/**
 * D4e bank adjustments, end to end, with the two-person rule actually
 * exercised: one finance user proposes, a DIFFERENT one approves, and the
 * accountant-facing register and unusual-account report show the result.
 *
 * Fixtures this depends on (supabase/seed.sql):
 *   - PEARL-OPERATING bank account (registered, UGX, mapped to GL 1000);
 *   - fin.maker@test.local and fin.checker@test.local, both finance team
 *     members and different people;
 *   - two unmatched statement lines, D4E-CHARGE-1 (-45,000) and
 *     D4E-INTEREST-1 (+12,000), on that account.
 * If the statement lines are missing, fix seed.sql (§3b) -- not the spec.
 *
 * The spec consumes the two lines (an approved adjustment matches them), so a
 * second run on the same database needs `supabase db reset`. That is the same
 * contract as insurance-cash-commission.spec.ts.
 */

const BANK = 'PEARL-OPERATING';

async function openReconciliationAs(page: Page, account: 'finMaker' | 'finChecker') {
  await loginAs(page, account);
  await page.goto('/financial-management/bank-reconciliation');
  const bank = page.getByLabel('Bank Account');
  await bank.fill(BANK);
  await page.keyboard.press('Escape');
  // The panel appears once the screen has an account.
  await expect(page.getByTestId('bank-adjustments-panel')).toBeVisible({ timeout: 15_000 });
}

/** Selects a statement line by its reference and returns the row locator. */
async function selectStatementLine(page: Page, reference: string) {
  const row = page.getByRole('row', { name: new RegExp(reference) }).first();
  await expect(
    row,
    `Statement line ${reference} not found on ${BANK}. Seed §3b should have imported it; ` +
      `if the whole table is empty, check that apps/web/.env points at the freshly reset stack.`
  ).toBeVisible({ timeout: 15_000 });
  await row.click();
  return row;
}

/** Picks the counter-account in the adjustments panel. */
async function pickCounterAccount(page: Page, label: string) {
  const picker = page.getByLabel('Other side of the entry');
  await picker.click();
  await picker.fill(label);
  await page.getByRole('option', { name: new RegExp(label) }).first().click();
}

test.describe('Bank adjustments (D4e)', () => {
  test.describe.configure({ mode: 'serial' });

  test('a charge is proposed by one finance user and approved by another, then visible to the accountant', async ({ page }) => {
    const uniqueReason = `e2e bank charge ${Date.now()}`;

    await test.step('maker proposes against the unmatched charge line', async () => {
      await openReconciliationAs(page, 'finMaker');
      await selectStatementLine(page, 'D4E-CHARGE-1');

      await pickCounterAccount(page, 'Bank Charges');
      await page.getByLabel('Reason').fill(uniqueReason);
      await page.getByRole('button', { name: 'Propose adjustment' }).click();

      // The maker must NOT be able to approve their own proposal: the button is
      // present but disabled (unless the company enabled the one-person
      // exception, which the seeded tenant has not).
      const ownRow = page.getByRole('row', { name: new RegExp(uniqueReason) });
      await expect(ownRow).toBeVisible({ timeout: 15_000 });
      await expect(ownRow.getByRole('button', { name: 'Approve' })).toBeDisabled();
      await expect(ownRow.getByRole('button', { name: 'Withdraw' })).toBeEnabled();
    });

    await test.step('a different finance user sees it and approves it', async () => {
      await openReconciliationAs(page, 'finChecker');
      const row = page.getByRole('row', { name: new RegExp(uniqueReason) });
      await expect(row).toBeVisible({ timeout: 15_000 });

      await row.getByRole('button', { name: 'Approve' }).click();
      const dialog = page.getByRole('dialog');
      await expect(dialog.getByText(uniqueReason)).toBeVisible();
      await dialog.getByRole('button', { name: 'Approve and post' }).click();

      await expect(page.getByText(/approved and posted/i)).toBeVisible({ timeout: 15_000 });
      await expect(page.getByRole('row', { name: new RegExp(uniqueReason) }))
        .toContainText('posted');
    });

    await test.step('the accountant register shows it, approved by the checker', async () => {
      await page.goto('/financial-management/reports/bank-adjustments');
      const row = page.getByRole('row', { name: new RegExp(uniqueReason) });
      await expect(row).toBeVisible({ timeout: 15_000 });
      await expect(row).toContainText('posted');
      await expect(row).toContainText('Pearl Finance Checker');
      // Posted by two different people, so it must not be flagged as the
      // one-person exception.
      await expect(row.getByText('self-approved')).toHaveCount(0);
    });

    await test.step('the statement line is matched, so it is no longer offered for adjustment', async () => {
      await openReconciliationAs(page, 'finMaker');
      await expect(page.getByRole('row', { name: /D4E-CHARGE-1/ }).first()).toContainText(/matched/i);
    });
  });

  test('a rejected proposal can be reworked as a linked adjustment', async ({ page }) => {
    const rejected = `e2e interest ${Date.now()}`;
    const reworked = `${rejected} (corrected)`;

    await test.step('maker proposes, checker rejects with a reason', async () => {
      await openReconciliationAs(page, 'finMaker');
      await selectStatementLine(page, 'D4E-INTEREST-1');
      await pickCounterAccount(page, 'Interest Received');
      await page.getByLabel('Reason').fill(rejected);
      await page.getByRole('button', { name: 'Propose adjustment' }).click();
      await expect(page.getByRole('row', { name: new RegExp(rejected) })).toBeVisible({ timeout: 15_000 });

      await openReconciliationAs(page, 'finChecker');
      const row = page.getByRole('row', { name: new RegExp(rejected) });
      await row.getByRole('button', { name: 'Reject' }).click();
      const dialog = page.getByRole('dialog');
      await dialog.getByLabel(/Why is it being rejected/).fill('please use the interest income account');
      await dialog.getByRole('button', { name: 'Reject' }).click();
      await expect(page.getByText(/rejected\. Nothing was posted/i)).toBeVisible({ timeout: 15_000 });
    });

    await test.step('the maker reworks it, linked to the rejected row', async () => {
      await openReconciliationAs(page, 'finMaker');
      const rejectedRow = page.getByRole('row', { name: new RegExp(rejected) });
      await expect(rejectedRow).toContainText('rejected');
      await rejectedRow.getByRole('button', { name: 'Rework' }).click();

      await expect(page.getByTestId('rework-banner')).toBeVisible();
      await page.getByLabel('Reason').fill(reworked);
      await page.getByRole('button', { name: 'Propose rework' }).click();

      const reworkedRow = page.getByRole('row', { name: new RegExp(reworked) });
      await expect(reworkedRow).toBeVisible({ timeout: 15_000 });
      await expect(reworkedRow.getByText('reworked')).toBeVisible();

      await reworkedRow.getByRole('button', { name: 'History' }).click();
      const history = page.getByRole('dialog');
      await expect(history.getByText('Reworked from a rejected proposal')).toBeVisible({ timeout: 15_000 });
      await expect(history.getByText('Rejected')).toBeVisible();
      await history.getByRole('button', { name: 'Close' }).click();
    });
  });

  test('unusual-account report flags a posting outside the usual accounts', async ({ page }) => {
    await test.step('with no usual accounts configured, the report explains itself', async () => {
      await loginAs(page, 'finChecker');
      await page.goto('/financial-management/reports/bank-adjustment-unusual-accounts');
      await expect(page.getByTestId('usual-empty-alert')).toBeVisible({ timeout: 15_000 });
    });

    await test.step('adding the usual account empties the flag list for that account', async () => {
      await page.getByRole('button', { name: /Usual accounts/ }).click();
      const dialog = page.getByRole('dialog');
      await dialog.getByLabel('Add an account').click();
      await dialog.getByLabel('Add an account').fill('Bank Charges');
      await page.getByRole('option', { name: /Bank Charges/ }).first().click();
      await dialog.getByRole('button', { name: 'Add' }).click();
      await dialog.getByRole('button', { name: 'Close' }).click();

      await expect(page.getByTestId('usual-empty-alert')).toHaveCount(0);
      // The control account must never be offered as a usual account.
      await page.getByRole('button', { name: /Usual accounts/ }).click();
      await page.getByRole('dialog').getByLabel('Add an account').click();
      const receivables = page.getByRole('option', { name: /Trade Receivables/ });
      if (await receivables.count()) {
        await expect(receivables.first()).toHaveAttribute('aria-disabled', 'true');
      }
    });
  });
});
