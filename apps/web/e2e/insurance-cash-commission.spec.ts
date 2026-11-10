import { test, expect, type Locator, type Page } from '@playwright/test';
import { loginAs, logout, type TestAccountKey } from './utils/auth';

/**
 * Insurance money flow, end to end through the UI, on the seeded Pearl Risk
 * Brokers tenant (supabase/seed.sql section 6):
 *
 *   1. bind        draft -> submitted (manager) -> approved (a DIFFERENT admin) -> bound
 *   2. receipt     finance maker prepares the premium receipt; the checker posts it;
 *                  the maker is only offered "Cancel request" on their own request
 *   3. remittance  the checker prepares the insurer remittance, the maker posts it
 *   4. commission  paying the insurer in full earns the commission; an insurance
 *                  manager transfers it from client money to the operating account
 *
 * Fixture: seeded policy 4, "Ruth Namukasa" (individual medical, draft, one
 * insurer, no certificate needed). It is untouched by seed.sql and by the other
 * specs, so this spec owns it. The tests run serially and depend on each other.
 *
 * RERUNS: the policy ends up fully paid and its commission transferred, so a
 * second run against the same database cannot repeat steps 2 to 4. The bind step
 * skips itself when the policy is already past draft, and the cash steps then
 * fail with a message telling you to `supabase db reset`. CI always starts fresh.
 *
 * Amounts are not hard-coded. The prepare dialog states "Current limit: ..."
 * (what the database will accept), and the spec pays exactly that, so it tracks
 * the commission rate and charge lines in the seed instead of duplicating them.
 *
 * Not covered here (see e2e/README.md): independent bank reconciliation by the
 * third finance user, rejecting a request, document generation (needs edge
 * functions), claims and cancellation.
 */

const CLIENT = 'Ruth Namukasa';
const POLICIES_PATH = '/insurance/policies';
const CASH_PATH = '/financial-management/insurance-premium-cash';
const COMMISSION_PATH = '/insurance/commission';

const runId = Date.now();
const receiptRef = `E2E-RCPT-${runId}`;
const remitRef = `E2E-REMIT-${runId}`;

const ERROR_ALERT =
  '[class*="MuiAlert-standardError"], [class*="MuiAlert-filledError"], [class*="MuiAlert-outlinedError"]';

/** Waits for `target` to disappear; if it does not, reports the app's own error banner. */
async function expectGone(page: Page, target: Locator, what: string, timeout = 15_000) {
  try {
    await expect(target).toBeHidden({ timeout });
  } catch (e) {
    const banner = page.locator(ERROR_ALERT).first();
    if (await banner.isVisible()) {
      throw new Error(`${what} was refused: ${(await banner.innerText()).trim()}`);
    }
    throw e;
  }
}

async function switchUser(page: Page, key: TestAccountKey) {
  await logout(page);
  await loginAs(page, key);
}

async function openPolicy(page: Page) {
  await page.goto(POLICIES_PATH);
  await page.getByPlaceholder('Search policy no, client, insurer or product').fill(CLIENT);
  const row = page.getByRole('row', { name: new RegExp(CLIENT) });
  await expect(row).toBeVisible({ timeout: 30_000 });
  await row.click();
  await expect(page).toHaveURL(/\/insurance\/policies\/[0-9a-f-]{36}$/);
}

/** Finance route: find the policy and open its cash workflow. */
async function openCashWorkflow(page: Page) {
  await page.goto(CASH_PATH);
  await expect(page.getByRole('heading', { name: 'Insurance premium cash' })).toBeVisible({ timeout: 30_000 });
  await page.getByLabel('Find policy, client or insurer').fill(CLIENT);
  await page.getByRole('button', { name: 'Search', exact: true }).click();
  const row = page
    .getByRole('table', { name: 'Premium cash policies' })
    .getByRole('row', { name: new RegExp(CLIENT) });
  await expect(row, `${CLIENT} should be a bound policy visible to Finance`).toBeVisible({ timeout: 30_000 });
  await row.getByRole('button', { name: 'View cash workflow' }).click();
  await expect(page.getByText('Premium receipts & insurer remittances')).toBeVisible({ timeout: 15_000 });
  await expect(page.getByText('Loading cash position…')).toBeHidden({ timeout: 15_000 });
}

const requestRow = (page: Page, reference: string) =>
  page.getByRole('table', { name: 'Policy cash requests' }).getByRole('row', { name: new RegExp(reference) });

function parseLimit(text: string): string {
  const m = /Current limit:\s*[^\d-]*([\d,]+(?:\.\d{1,2})?)/.exec(text);
  if (!m) throw new Error(`Could not read the current limit from: "${text}"`);
  return m[1].replace(/,/g, '');
}

/**
 * Prepares a receipt or remittance for the full amount the database allows.
 * Returns the amount typed so callers can report it.
 */
async function prepareRequest(page: Page, kind: 'receipt' | 'remittance', reference: string): Promise<string> {
  const buttonName = kind === 'receipt' ? 'Prepare premium receipt' : 'Prepare insurer remittance';
  const button = page.getByRole('button', { name: buttonName });
  await expect(button).toBeVisible({ timeout: 15_000 });
  await expect(
    button,
    kind === 'receipt'
      ? 'Nothing left to collect on this policy. It was already paid by an earlier run: run `supabase db reset`.'
      : 'No insurer amount is available to remit yet (the receipt may not have funded it).',
  ).toBeEnabled();
  await button.click();

  const dialog = page.getByRole('dialog');
  await expect(dialog.getByText(/Current limit:/)).toBeVisible();

  // With per-insurer shares the limit depends on the chosen insurer, so pick it first.
  if (kind === 'remittance') {
    const share = dialog.getByLabel('Insurer to remit to');
    if (await share.count()) {
      await share.click();
      await page.getByRole('option').first().click();
    }
  }
  await dialog.getByLabel('Client-money bank account').click();
  await expect(page.getByRole('option').first(), 'a client-money bank account should exist').toBeVisible({ timeout: 10_000 });
  await page.getByRole('option').first().click();

  const amount = parseLimit(await dialog.getByText(/Current limit:/).innerText());
  expect(Number(amount), 'the limit to pay must be positive').toBeGreaterThan(0);
  await dialog.getByLabel('Amount', { exact: true }).fill(amount);
  await dialog.getByLabel('Bank reference').fill(reference);
  await dialog.getByRole('button', { name: 'Submit for approval' }).click();
  await expectGone(page, dialog, `Submitting the ${kind}`);
  return amount;
}

async function expectPending(page: Page, reference: string, mine: boolean) {
  const row = requestRow(page, reference);
  await expect(row).toBeVisible({ timeout: 15_000 });
  await expect(row.locator('.MuiChip-label')).toHaveText('pending');
  if (mine) {
    // Maker-checker: the maker may withdraw their own request but never approve it.
    await expect(row.getByRole('button', { name: 'Cancel request' })).toBeVisible();
    await expect(row.getByRole('button', { name: 'Approve and post' })).toHaveCount(0);
  }
}

async function approveAndPost(page: Page, reference: string) {
  const row = requestRow(page, reference);
  await expect(row).toBeVisible({ timeout: 15_000 });
  await row.getByRole('button', { name: 'Approve and post' }).click();
  const dialog = page.getByRole('dialog');
  await dialog.getByRole('button', { name: 'Approve and post' }).click();
  await expectGone(page, dialog, 'Approval');
  await expect(row.locator('.MuiChip-label')).toHaveText('posted', { timeout: 15_000 });
  await expect(row.getByText('Not posted')).toHaveCount(0);
  await expect(row.getByText('Awaiting independent bank reconciliation')).toBeVisible();
}

test.describe('Insurance bind -> premium receipt -> insurer remittance -> commission', () => {
  test.describe.configure({ mode: 'serial' });

  test('bind: submitted by the manager, approved by a different admin, bound', async ({ page }) => {
    test.setTimeout(120_000);
    const submit = page.getByRole('button', { name: 'Submit for approval' });
    const renew = page.getByRole('button', { name: 'Start renewal' });

    await loginAs(page, 'insManager');
    await openPolicy(page);
    await expect(submit.or(renew)).toBeVisible({ timeout: 30_000 });
    if (!(await submit.isVisible())) {
      test.info().annotations.push({ type: 'note', description: 'Policy already bound by an earlier run; bind skipped.' });
      return;
    }

    await test.step('manager submits the draft', async () => {
      await submit.click();
      await expect(submit).toBeHidden({ timeout: 15_000 });
    });

    await test.step('a different insurance admin approves', async () => {
      await switchUser(page, 'insAdmin');
      await openPolicy(page);
      await page.getByRole('button', { name: 'Approve', exact: true }).click();
      const dialog = page.getByRole('dialog');
      await dialog.getByRole('button', { name: 'Approve', exact: true }).click();
      await expectGone(page, dialog, 'Policy approval');
      await expect(page.getByRole('button', { name: 'Bind policy' })).toBeVisible({ timeout: 15_000 });
    });

    await test.step('manager binds the approved policy', async () => {
      await switchUser(page, 'insManager');
      await openPolicy(page);
      await page.getByRole('button', { name: 'Bind policy' }).click();
      const dialog = page.getByRole('dialog');
      await dialog.getByRole('button', { name: 'Bind policy' }).click();
      await expectGone(page, dialog, 'Binding');
      await expect(renew).toBeVisible({ timeout: 15_000 });
    });
  });

  test('premium receipt: the maker prepares, the checker posts', async ({ page }) => {
    test.setTimeout(120_000);
    await loginAs(page, 'finMaker');
    await openCashWorkflow(page);
    await prepareRequest(page, 'receipt', receiptRef);
    await expectPending(page, receiptRef, true);

    await switchUser(page, 'finChecker');
    await openCashWorkflow(page);
    await expectPending(page, receiptRef, false);
    await approveAndPost(page, receiptRef);
  });

  test('insurer remittance: the checker prepares, the maker posts', async ({ page }) => {
    test.setTimeout(120_000);
    await loginAs(page, 'finChecker');
    await openCashWorkflow(page);
    await prepareRequest(page, 'remittance', remitRef);
    await expectPending(page, remitRef, true);

    await switchUser(page, 'finMaker');
    await openCashWorkflow(page);
    await expectPending(page, remitRef, false);
    await approveAndPost(page, remitRef);
  });

  test('commission: earned once the insurer is paid in full, transferred by a manager', async ({ page }) => {
    test.setTimeout(90_000);
    await loginAs(page, 'insManager');
    await page.goto(COMMISSION_PATH);
    await expect(page.getByRole('heading', { name: 'Commission', exact: true })).toBeVisible({ timeout: 30_000 });

    // Recognition happens when the settling payment posts, not at bank reconciliation.
    const available = page.getByText(/\d+ earned entr(y|ies) can be transferred/);
    await expect(
      available,
      'commission should be earned after the insurer remittance posted in the previous test',
    ).toBeVisible({ timeout: 15_000 });
    expect(parseInt((await available.innerText()).trim(), 10)).toBeGreaterThan(0);

    await page.getByRole('checkbox', { name: 'Select all earned entries' }).check();
    await page.getByRole('button', { name: /^Transfer \d+ selected/ }).click();

    const dialog = page.getByRole('dialog');
    await expect(dialog.getByText('Transfer commission to an operating account')).toBeVisible();
    // Native selects: index 0 is the "Choose…" placeholder.
    await dialog.getByLabel('From (client money)').selectOption({ index: 1 });
    await dialog.getByLabel('To (operating)').selectOption({ index: 1 });
    await dialog.getByRole('button', { name: 'Transfer commission' }).click();
    await expectGone(page, dialog, 'Commission transfer');
    await expect(page.getByText(/^Transferred /)).toBeVisible({ timeout: 15_000 });
  });
});
