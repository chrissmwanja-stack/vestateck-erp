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
 *
 * Counter-account names come from the seeded chart of accounts, not from
 * anything this spec creates: 5000 General Expense (the charge) and 4100
 * Brokerage Fees & Other Income (the interest). There is no "Bank Charges" or
 * "Interest Received" account in the seed -- using those names is what the
 * first CI run of this file did, and it waited a minute for an option that
 * could never appear.
 */

const BANK = 'PEARL-OPERATING';

/**
 * A RegExp that matches `text` literally. Reasons are free text built in the
 * tests (e.g. "... (corrected)"); passed raw to new RegExp(), the parentheses
 * become a capture group and the pattern no longer matches the visible text.
 */
function literal(text: string): RegExp {
  return new RegExp(text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'));
}

/**
 * Several steps switch users on the same page. If the previous session is still
 * live, /login redirects straight back into the app while the form is being
 * filled ("element was detached from the DOM"). Sign out first, and wait for the
 * sign-out to actually finish (back on /login) before the next login starts.
 * isVisible() does not wait, so this is a no-op on a fresh page.
 */
async function signOutIfSignedIn(page: Page) {
  const signOut = page.getByRole('button', { name: 'Sign out' });
  if (!(await signOut.isVisible())) return;
  await signOut.click();
  await page.waitForURL(/\/login/, { timeout: 15_000 });
  await expect(page.getByRole('button', { name: 'Sign in' })).toBeVisible();
}

async function openReconciliationAs(page: Page, account: 'finMaker' | 'finChecker') {
  await signOutIfSignedIn(page);
  await loginAs(page, account);
  await page.goto('/financial-management/bank-reconciliation');
  const bank = page.getByRole('combobox', { name: 'Bank Account' });
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

/**
 * Picks the counter-account in the adjustments panel.
 *
 * The option must be asserted before clicking: `click()` alone waits out the
 * whole test budget on a name that does not exist, and reports it as a click
 * timeout rather than "this account is not in the chart". The names below are
 * seeded by the chart-of-accounts template (GL 5000 General Expense, 4100
 * Brokerage Fees & Other Income) -- if one is renamed there, this is the line
 * to change, not the picker.
 */
async function pickCounterAccount(page: Page, label: string) {
  // getByRole, not getByLabel: once the popup opens, MUI's listbox <ul> is also
  // aria-labelledby this label, so getByLabel matches two elements and trips
  // Playwright's strict mode on fill().
  const picker = page.getByRole('combobox', { name: 'Other side of the entry' });
  await picker.click();
  await picker.fill(label);
  const option = page.getByRole('option', { name: new RegExp(label) }).first();
  await expect(
    option,
    `Counter account "${label}" is not in the seeded chart of accounts (or is disabled as a ` +
      `header/control account). Check gl_accounts in supabase/seed.sql.`
  ).toBeVisible({ timeout: 10_000 });
  await option.click();
}

test.describe('Bank adjustments (D4e)', () => {
  test.describe.configure({ mode: 'serial' });

  test('a charge is proposed by one finance user and approved by another, then visible to the accountant', async ({ page }) => {
    const uniqueReason = `e2e bank charge ${Date.now()}`;

    await test.step('maker proposes against the unmatched charge line', async () => {
      await openReconciliationAs(page, 'finMaker');
      await selectStatementLine(page, 'D4E-CHARGE-1');

      await pickCounterAccount(page, 'General Expense');
      await page.getByLabel('Reason').fill(uniqueReason);
      await page.getByRole('button', { name: 'Propose adjustment' }).click();

      // The maker must NOT be able to approve their own proposal: the button is
      // present but disabled (unless the company enabled the one-person
      // exception, which the seeded tenant has not).
      const ownRow = page.getByRole('row', { name: literal(uniqueReason) });
      await expect(ownRow).toBeVisible({ timeout: 15_000 });
      await expect(ownRow.getByRole('button', { name: 'Approve' })).toBeDisabled();
      await expect(ownRow.getByRole('button', { name: 'Withdraw' })).toBeEnabled();
    });

    await test.step('a different finance user sees it and approves it', async () => {
      await openReconciliationAs(page, 'finChecker');
      const row = page.getByRole('row', { name: literal(uniqueReason) });
      await expect(row).toBeVisible({ timeout: 15_000 });

      await row.getByRole('button', { name: 'Approve' }).click();
      const dialog = page.getByRole('dialog');
      await expect(dialog.getByText(uniqueReason)).toBeVisible();
      await dialog.getByRole('button', { name: 'Approve and post' }).click();

      await expect(page.getByText(/approved and posted/i)).toBeVisible({ timeout: 15_000 });
      await expect(page.getByRole('row', { name: literal(uniqueReason) }))
        .toContainText('posted');
    });

    await test.step('the accountant register shows it, approved by the checker', async () => {
      await page.goto('/financial-management/reports/bank-adjustments');
      const row = page.getByRole('row', { name: literal(uniqueReason) });
      await expect(row).toBeVisible({ timeout: 15_000 });
      await expect(row).toContainText('posted');
      await expect(row).toContainText('Pearl Finance Checker');
      // Posted by two different people, so it must not be flagged as the
      // one-person exception.
      await expect(row.getByText('self-approved')).toHaveCount(0);
    });

    await test.step('the statement line is matched, so it is no longer offered for adjustment', async () => {
      await openReconciliationAs(page, 'finMaker');
      // The statement table lists UNMATCHED lines only (v_bank_statement_unmatched),
      // so a matched line is absent from it rather than shown with a "matched"
      // badge. Wait for the other seeded line first so the table has loaded and
      // "absent" cannot pass vacuously. "Ref: " is the statement table's own
      // prefix; the adjustment history lists the same line without it.
      await expect(page.getByRole('row', { name: /Ref: D4E-INTEREST-1/ })).toBeVisible({ timeout: 15_000 });
      await expect(page.getByRole('row', { name: /Ref: D4E-CHARGE-1/ })).toHaveCount(0);
    });
  });

  test('a rejected proposal can be reworked as a linked adjustment', async ({ page }) => {
    const rejected = `e2e interest ${Date.now()}`;
    const reworked = `${rejected} (corrected)`;

    await test.step('maker proposes, checker rejects with a reason', async () => {
      await openReconciliationAs(page, 'finMaker');
      await selectStatementLine(page, 'D4E-INTEREST-1');
      await pickCounterAccount(page, '4100');
      await page.getByLabel('Reason').fill(rejected);
      await page.getByRole('button', { name: 'Propose adjustment' }).click();
      await expect(page.getByRole('row', { name: literal(rejected) })).toBeVisible({ timeout: 15_000 });

      await openReconciliationAs(page, 'finChecker');
      const row = page.getByRole('row', { name: literal(rejected) });
      await row.getByRole('button', { name: 'Reject' }).click();
      const dialog = page.getByRole('dialog');
      await dialog.getByLabel(/Why is it being rejected/).fill('please use the interest income account');
      await dialog.getByRole('button', { name: 'Reject' }).click();
      await expect(page.getByText(/rejected\. Nothing was posted/i)).toBeVisible({ timeout: 15_000 });
    });

    await test.step('the maker reworks it, linked to the rejected row', async () => {
      await openReconciliationAs(page, 'finMaker');
      const rejectedRow = page.getByRole('row', { name: literal(rejected) });
      await expect(rejectedRow).toContainText('rejected');
      await rejectedRow.getByRole('button', { name: 'Rework' }).click();

      await expect(page.getByTestId('rework-banner')).toBeVisible();
      await page.getByLabel('Reason').fill(reworked);
      await page.getByRole('button', { name: 'Propose rework' }).click();

      const reworkedRow = page.getByRole('row', { name: literal(reworked) });
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
      await dialog.getByRole('combobox', { name: 'Add an account' }).click();
      await dialog.getByRole('combobox', { name: 'Add an account' }).fill('General Expense');
      const usual = page.getByRole('option', { name: /General Expense/ }).first();
      await expect(usual, 'General Expense (GL 5000) is not in the seeded chart of accounts').toBeVisible({ timeout: 10_000 });
      await usual.click();
      await dialog.getByRole('button', { name: 'Add' }).click();
      await dialog.getByRole('button', { name: 'Close' }).click();

      await expect(page.getByTestId('usual-empty-alert')).toHaveCount(0);
    });

    await test.step('the control account is offered but cannot be chosen', async () => {
      await page.getByRole('button', { name: /Usual accounts/ }).click();
      const dialog = page.getByRole('dialog');
      await dialog.getByRole('combobox', { name: 'Add an account' }).click();
      await dialog.getByRole('combobox', { name: 'Add an account' }).fill('Accounts Receivable Control');
      // It IS in the chart of accounts, so it appears -- and must be refused,
      // because a control account can never be the other side of an adjustment.
      const control = page.getByRole('option', { name: /Accounts Receivable Control/ }).first();
      await expect(
        control,
        'Accounts Receivable Control (GL 1100) should be listed as a control account in seed.sql'
      ).toBeVisible({ timeout: 10_000 });
      await expect(control).toHaveAttribute('aria-disabled', 'true');
    });
  });
});
