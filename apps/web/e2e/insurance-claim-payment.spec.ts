import { test, expect, type Locator, type Page } from '@playwright/test';
import { loginAs, logout, type TestAccountKey } from './utils/auth';

/**
 * Insurance claim, paid through the brokerage, end to end through the UI, on the
 * seeded Pearl Risk Brokers tenant (supabase/seed.sql section 6).
 *
 * What the system actually enforces (supabase/tests/test_ins_claim_payments.sql):
 *   - Segregation on APPROVAL: the person who registered a claim cannot approve it.
 *   - The brokerage never pays the client ahead of the insurer: the client can
 *     only be paid out of money already received from the insurer.
 *   - "Settled" cannot be set by hand; the claim settles when it is paid in full.
 *   - Finance cannot settle claim items from the generic Finance screen.
 * There is NO separate finance maker-checker on claim payments (unlike premium
 * cash, see insurance-cash-commission.spec.ts): insurance admins and managers
 * record them. This spec therefore tests the controls above, not a maker-checker
 * that does not exist on claims.
 *
 *   1. setup      an admin sets insurer SAV to "Brokerage pays the client"
 *   2. approval   the registrant (ins.manager) starts assessment but is not offered
 *                 Approve; a different admin approves; the claim copies the mode
 *   3. receipt    recognise the receivable (needs the insurer's written reference);
 *                 "Pay client" is disabled until money is held; receive part of the
 *                 amount, check the UI refuses to pay out more than is held, pay
 *                 that part to the client
 *   4. settle     receive and pay the remainder; the claim settles; close it
 *
 * Fixture: the seeded claim on policy 1 (registered by ins.manager, reserve
 * UGX 3,500,000, insurer reference SAV-CLM-0001). Its claim NUMBER is generated
 * by the database, so the spec finds it by insurer reference and reads the number. We approve UGX 3,000,000. The tests run serially and
 * depend on each other.
 *
 * RERUNS: the claim ends closed and cannot be replayed, so a second run on the
 * same database fails at step 2 with a message telling you to
 * `supabase db reset`. CI always starts fresh. Setting SAV to brokerage mode
 * persists afterwards; it only affects claims approved from then on.
 *
 * Not covered here (see e2e/README.md): the insurer-pays-direct mode, voiding a
 * payment, repudiation, reserve revisions, and claim documents.
 */

// The seed passes 'SAV-CLM-0001' as the INSURER's claim reference (ins_create_claim's
// p_insurer_claim_ref); the claim number itself is generated, and the list does not show
// the insurer reference, so the row is picked by its loss description instead.
const INSURER_REF = 'SAV-CLM-0001';
const LOSS_DESCRIPTION = /Rear-end collision on Entebbe Road/;
const APPROVED = '3000000';
const FIRST_PART = '1000000';
const OVER_HELD = '1000001';

const runId = Date.now();
const confirmationRef = `E2E-CONF-${runId}`;

const ERROR_ALERT =
  '[class*="MuiAlert-standardError"], [class*="MuiAlert-filledError"], [class*="MuiAlert-outlinedError"]';

/** Shared across the serial tests: set when the claim is first opened. */
let claimUrl = '';
let claimNo = '';

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

async function openClaim(page: Page) {
  await page.goto(claimUrl);
  await expect(page.getByRole('heading', { name: claimNo })).toBeVisible({ timeout: 30_000 });
}

/** The "label … value" row inside the Payment card. */
const line = (page: Page, label: string) => page.getByText(label, { exact: true }).locator('xpath=..');

async function pickFirstBank(page: Page, dialog: Locator) {
  await dialog.getByLabel('Client-money bank account').click();
  await expect(page.getByRole('option').first(), 'a client-money bank account should exist').toBeVisible({ timeout: 10_000 });
  await page.getByRole('option').first().click();
}

/**
 * Records a receipt from the insurer or a payout to the client. With `amount`
 * it types that figure; without it, it keeps the pre-filled maximum and checks
 * it equals `expectPrefilled`.
 */
async function recordMoney(
  page: Page,
  kind: 'receipt' | 'payout',
  reference: string,
  opts: { amount?: string; expectPrefilled?: RegExp } = {},
) {
  const button = page.getByRole('button', { name: kind === 'receipt' ? 'Record receipt from insurer' : 'Pay client' });
  await expect(button).toBeEnabled({ timeout: 15_000 });
  await button.click();
  const dialog = page.getByRole('dialog');
  await expect(
    dialog.getByRole('heading', { name: kind === 'receipt' ? 'Record receipt from insurer' : 'Pay the client' }),
  ).toBeVisible();
  await pickFirstBank(page, dialog);
  const amount = dialog.getByLabel(/^Amount/);
  if (opts.amount) {
    await amount.fill(opts.amount);
  } else if (opts.expectPrefilled) {
    await expect(amount).toHaveValue(opts.expectPrefilled);
  }
  await dialog.getByLabel('Reference (optional)').fill(reference);
  await dialog.getByRole('button', { name: 'Save' }).click();
  await expectGone(page, dialog, kind === 'receipt' ? 'Recording the insurer receipt' : 'Paying the client');
}

test.describe('Insurance claim paid through the brokerage: approve -> recognise -> receive -> pay -> settle', () => {
  test.describe.configure({ mode: 'serial' });

  test('setup: insurer SAV pays claims through the brokerage', async ({ page }) => {
    test.setTimeout(90_000);
    await loginAs(page, 'insAdmin');
    await page.goto('/insurance/insurers');
    const row = page.getByRole('row', { name: /\bSAV\b/ });
    await expect(row).toBeVisible({ timeout: 30_000 });
    await row.getByRole('button', { name: 'Edit' }).click();
    const dialog = page.getByRole('dialog');
    await expect(dialog.getByRole('heading', { name: 'Edit insurer' })).toBeVisible();
    await dialog.getByLabel('How claims are paid').click();
    await page.getByRole('option', { name: 'Brokerage pays the client' }).click();
    await dialog.getByRole('button', { name: 'Save' }).click();
    await expectGone(page, dialog, 'Saving the insurer');
    await expect(row).toContainText('Brokerage');
  });

  test('approval: the registrant cannot approve; a different admin does; the claim copies the mode', async ({ page }) => {
    test.setTimeout(120_000);
    await loginAs(page, 'insManager');
    await page.goto('/insurance/claims');
    await page.getByPlaceholder('Search claim no, policy, client, description or insurer ref').fill(INSURER_REF);
    const claimRow = page.getByRole('row', { name: LOSS_DESCRIPTION });
    await expect(claimRow, `the seeded claim (insurer reference ${INSURER_REF}) should be in the open claims`).toBeVisible({ timeout: 30_000 });
    claimNo = (await claimRow.getByRole('cell').first().innerText()).trim();
    expect(claimNo, 'the first cell of the row is the generated claim number').toMatch(/\S/);
    await claimRow.click();
    await expect(page).toHaveURL(/\/insurance\/claims\/[0-9a-f-]{36}$/);
    claimUrl = page.url();
    await expect(page.getByRole('heading', { name: claimNo })).toBeVisible();
    // The search matched on the insurer's reference, so the detail page must show it.
    await expect(page.getByText(INSURER_REF, { exact: true })).toBeVisible();

    const startAssessment = page.getByRole('button', { name: 'Start assessment' });
    await expect(
      startAssessment,
      `${claimNo} is not in its starting state. It was used by an earlier run: run \`supabase db reset\`.`,
    ).toBeVisible({ timeout: 15_000 });

    await test.step('the registrant starts assessment', async () => {
      await startAssessment.click();
      const dialog = page.getByRole('dialog');
      await dialog.getByRole('button', { name: 'Start assessment' }).click();
      await expectGone(page, dialog, 'Starting assessment');
    });

    await test.step('the registrant is told another manager must approve, and gets no Approve button', async () => {
      await expect(page.getByText('You registered this claim, so another manager must approve it.')).toBeVisible({ timeout: 15_000 });
      await expect(page.getByRole('button', { name: 'Approve', exact: true })).toHaveCount(0);
    });

    await test.step('a different admin approves', async () => {
      await switchUser(page, 'insAdmin');
      await openClaim(page);
      await page.getByRole('button', { name: 'Approve', exact: true }).click();
      const dialog = page.getByRole('dialog');
      await dialog.getByLabel(/^Approved amount/).fill(APPROVED);
      await dialog.getByRole('button', { name: 'Approve', exact: true }).click();
      await expectGone(page, dialog, 'Claim approval');
    });

    await test.step('the claim copied the insurer\'s mode and waits for recognition', async () => {
      await expect(page.locator('.MuiChip-label', { hasText: 'Brokerage pays the client' })).toBeVisible({ timeout: 15_000 });
      await expect(page.getByText(/nothing is recognised until the insurer confirms in writing/)).toBeVisible();
      // Nothing can be received or paid before the receivable is recognised.
      await expect(page.getByRole('button', { name: 'Record receipt from insurer' })).toHaveCount(0);
      await expect(page.getByRole('button', { name: 'Pay client' })).toHaveCount(0);
    });
  });

  test('receipt: recognise, receive part from the insurer, pay that part to the client', async ({ page }) => {
    test.setTimeout(120_000);
    await loginAs(page, 'insManager');
    await openClaim(page);

    await test.step('recognise the receivable with the insurer\'s written reference', async () => {
      const recognise = page.getByRole('button', { name: 'Recognise receivable' });
      await expect(recognise).toBeDisabled(); // the reference is required
      await page.getByLabel("Insurer's written confirmation reference").fill(confirmationRef);
      await recognise.click();
      await expectGone(page, recognise, 'Recognising the receivable');
    });

    await test.step('the client cannot be paid before the insurer\'s money arrives', async () => {
      await expect(page.getByRole('button', { name: 'Record receipt from insurer' })).toBeEnabled({ timeout: 15_000 });
      await expect(page.getByRole('button', { name: 'Pay client' })).toBeDisabled();
      await expect(page.getByText("The client can be paid once the insurer's money has been received.")).toBeVisible();
    });

    await test.step('receive part of the approved amount from the insurer', async () => {
      await recordMoney(page, 'receipt', `E2E-RCPT-1-${runId}`, { amount: FIRST_PART });
      await expect(line(page, 'Received from the insurer')).toContainText(/1,000,000/);
      await expect(line(page, 'Held for the client')).toContainText(/1,000,000/);
    });

    await test.step('the dialog refuses to pay out more than is held', async () => {
      await page.getByRole('button', { name: 'Pay client' }).click();
      const dialog = page.getByRole('dialog');
      // Choose the bank first, so the only thing that can block Save is the amount.
      await pickFirstBank(page, dialog);
      await dialog.getByLabel(/^Amount/).fill(FIRST_PART);
      await expect(dialog.getByRole('button', { name: 'Save' })).toBeEnabled();
      await dialog.getByLabel(/^Amount/).fill(OVER_HELD);
      await expect(dialog.getByRole('alert')).toContainText(/has been received from the insurer and not yet paid out/);
      await expect(dialog.getByRole('button', { name: 'Save' })).toBeDisabled();
      await dialog.getByRole('button', { name: 'Cancel' }).click();
      await expectGone(page, dialog, 'Cancelling the dialog');
    });

    await test.step('pay the held amount to the client', async () => {
      await recordMoney(page, 'payout', `E2E-PAY-1-${runId}`, { expectPrefilled: /^1000000(\.0+)?$/ });
      await expect(line(page, 'Paid to the client')).toContainText(/1,000,000/);
      await expect(line(page, 'Held for the client')).toContainText(/\b0\b/);
      // Not paid in full yet, so the claim must not be settled or closable.
      await expect(page.getByRole('button', { name: 'Close', exact: true })).toHaveCount(0);
    });
  });

  test('settle: receive and pay the remainder; the claim settles and is closed', async ({ page }) => {
    test.setTimeout(120_000);
    await loginAs(page, 'insManager');
    await openClaim(page);

    await test.step('receive the rest from the insurer (the dialog pre-fills what is still due)', async () => {
      await recordMoney(page, 'receipt', `E2E-RCPT-2-${runId}`, { expectPrefilled: /^2000000(\.0+)?$/ });
      await expect(line(page, 'Still due from the insurer')).toContainText(/\b0\b/);
      await expect(line(page, 'Held for the client')).toContainText(/2,000,000/);
    });

    await test.step('pay the rest to the client; paying in full settles the claim', async () => {
      await recordMoney(page, 'payout', `E2E-PAY-2-${runId}`, { expectPrefilled: /^2000000(\.0+)?$/ });
      await expect(line(page, 'Paid to the client')).toContainText(/3,000,000/);
      await expect(line(page, 'Held for the client')).toContainText(/\b0\b/);
      // "Close" only exists once the claim is settled, and settling is automatic.
      await expect(page.getByRole('button', { name: 'Close', exact: true })).toBeVisible({ timeout: 15_000 });
      await expect(page.locator('.MuiChip-label', { hasText: /^Posted$/ })).toHaveCount(4);
    });

    await test.step('close the claim; the payments are then final', async () => {
      await page.getByRole('button', { name: 'Close', exact: true }).click();
      const dialog = page.getByRole('dialog');
      await dialog.getByRole('button', { name: 'Close', exact: true }).click();
      await expectGone(page, dialog, 'Closing the claim');
      await expect(page.getByRole('button', { name: 'Close', exact: true })).toHaveCount(0);
      await expect(page.getByRole('button', { name: 'Void', exact: true })).toHaveCount(0);
    });
  });
});
