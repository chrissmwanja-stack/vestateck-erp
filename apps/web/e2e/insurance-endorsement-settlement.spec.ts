import { test, expect, type Locator, type Page } from '@playwright/test';
import { loginAs, type TestAccountKey } from './utils/auth';

/**
 * P2: the endorsement settlement workflow and the cancellation ordering, end to end
 * through the UI, on the seeded Pearl Risk Brokers tenant (supabase/seed.sql section 6).
 *
 * P2-A — newest-first ordering (policy 3, "Mukasa Family Clinic"):
 *   post Endorsement 1, post Endorsement 2, attempt cancel 1 (refused — a later
 *   endorsement is live), cancel 2 (permitted), attempt cancel 1 (permitted now).
 *
 * P2-B — cancellation refusal after settlement (policy 2, "Lake Victoria Hotels"):
 *   Scenario 1: post an endorsement that generates financial items, settle the
 *     insurer payable item through the app, then attempt cancel → E4 refuses with
 *     the settlement named and instructions to void it first.
 *   Scenario 2: void the settlement through the app, retry cancel → permitted; the
 *     reversal is posted and the policy returns to its bound position.
 *
 * Fixture: both are seeded in-force policies that no other spec touches. The
 * spec runs serially and depends on each other's outcomes. It consumes its
 * endorsements (they end cancelled), so a rerun against the same database needs
 * `supabase db reset`.
 *
 * Both policies are already bound and active, so nothing here needs binding or
 * approving a fresh policy — those paths are covered by
 * insurance-cash-commission.spec.ts. This spec covers only what P2 gates: the
 * endorsements and their settlement.
 *
 * Naming: the "reason" column carries the spec marker so the exact endorsement
 * can be found back by name. Amounts are typed by hand.
 *
 * Accounts: the proposal is made by a plain insurance manager (insManager);
 * prepare/approve/settle/cancel run as the hybrid accounts (insFinMaker /
 * insFinChecker), because the endorsements page is insurance-gated and the
 * money actions additionally require Finance membership -- a plain finance
 * user cannot reach the screen at all.
 */

const ERROR_ALERT =
  '[class*="MuiAlert-standardError"], [class*="MuiAlert-filledError"], [class*="MuiAlert-outlinedError"]';

const POLICIES_PATH = '/insurance/policies';
const P2_A_CLIENT = 'Mukasa Family Clinic';
const P2_B_CLIENT = 'Lake Victoria Hotels';

const runId = Date.now();
const MARKER = (s: string) => `E2E-END-${runId}-${s}`;

async function expectGone(page: Page, target: Locator, what: string, timeout = 20_000) {
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

/**
 * Signs in as `actor` and opens a policy. The browser session is wiped first rather
 * than signed out through the UI: this spec switches person up to a dozen times, and
 * a UI sign-out followed by an immediate /login reload races the app's auth-state
 * redirect (the login form re-mounts under the test's cursor). Clearing storage on a
 * fresh page load is deterministic and quicker.
 */
async function goToPolicy(page: Page, actor: TestAccountKey, client: string) {
  await page.context().clearCookies();
  await page.goto('/login');
  await page.evaluate(() => {
    try {
      window.localStorage.clear();
      window.sessionStorage.clear();
    } catch {
      /* storage unavailable: loginAs below will surface it */
    }
  });
  await loginAs(page, actor);
  await openPolicy(page, client);
}

async function openPolicy(page: Page, client: string) {
  await page.goto(POLICIES_PATH);
  await page.getByPlaceholder('Search policy no, client, insurer or product').fill(client);
  const row = page.getByRole('row', { name: new RegExp(client) });
  await expect(row).toBeVisible({ timeout: 30_000 });
  await row.click();
  await expect(page).toHaveURL(/\/insurance\/policies\/[0-9a-f-]{36}$/);
  await expect(page.getByText('Endorsements', { exact: true })).toBeVisible({ timeout: 30_000 });
}

/** The one posted row whose reason contains the marker (the marker is unique per run). */
async function postedRowWithMarker(page: Page, marker: string) {
  // Reason column collapses at 60 chars, but the marker is always under 60 chars.
  return page.getByRole('row', { name: new RegExp(marker) }).first();
}

async function prepare(page: Page, marker: string) {
  // Prepare the row the marker identifies (the one just proposed).
  const row = await postedRowWithMarker(page, marker);
  const button = row.getByRole('button', { name: 'Prepare', exact: true });
  await expect(button).toBeVisible({ timeout: 20_000 });
  await button.click();
  const dialog = page.getByRole('dialog');
  await expect(dialog.getByText('Prepare for posting')).toBeVisible({ timeout: 15_000 });
  await dialog.getByLabel('Endorsement clearing account').click();
  // The seeded plain clearing account (seed.sql 2b). The first option is a bank or
  // control account, which posts fine but is refused as the credit-note offset when
  // the endorsement is cancelled (CREDIT_NOTE_OFFSET).
  await page.getByRole('option', { name: /^2090\b/ }).click();
  await dialog.getByRole('button', { name: 'Prepare', exact: true }).click();
  await expectGone(page, dialog, 'Preparing the endorsement');
  await expect(page.getByText(/^Prepared/)).toBeVisible({ timeout: 15_000 });
}

async function approve(page: Page, marker: string) {
  const row = await postedRowWithMarker(page, marker);
  const button = row.getByRole('button', { name: 'Review', exact: true });
  await expect(button).toBeVisible({ timeout: 20_000 });
  await button.click();
  const dialog = page.getByRole('dialog');
  await dialog.getByLabel('Review note (at least 5 characters)').fill('Finance review of the endorsed calculation');
  await dialog.getByRole('button', { name: 'Approve and post' }).click();
  await expectGone(page, dialog, 'Approving the endorsement');
  await expect(page.getByText(/^Posted as /)).toBeVisible({ timeout: 15_000 });
}

/** propose → prepare → approve as three different people (maker/checker discipline). */
async function postEndorsement(page: Page, client: string, delta: string, marker: string) {
  // Propose as the insurance manager holding the endorsement slot.
  await goToPolicy(page, 'insManager', client);
  await page.getByRole('button', { name: 'Endorse', exact: true }).click();
  const proposeDialog = page.getByRole('dialog');
  await expect(proposeDialog.getByText('Propose an endorsement')).toBeVisible({ timeout: 15_000 });
  await proposeDialog.getByLabel('Agreed premium delta', { exact: false }).first().fill(delta);
  await proposeDialog.getByLabel('Reason (at least 5 characters)').fill(`SUM INCREASE — ${marker}`);
  await proposeDialog.getByRole('button', { name: 'Propose' }).click();
  await expectGone(page, proposeDialog, 'Proposing the endorsement');
  await expect(page.getByText(/Endorsement proposed/)).toBeVisible({ timeout: 15_000 });

  // Prepare as the hybrid insurance-finance maker; approve as the hybrid checker
  // (the endorsements page is insurance-gated, so a plain finance user cannot reach
  // it -- the hybrid accounts exist exactly for this).
  await goToPolicy(page, 'insFinMaker', client);
  await prepare(page, marker);

  await goToPolicy(page, 'insFinChecker', client);
  await approve(page, marker);
  const row = await postedRowWithMarker(page, marker);
  await expect(row.locator('.MuiChip-label')).toHaveText('posted', { timeout: 15_000 });
}

async function openCancelDialog(page: Page, marker: string) {
  const row = await postedRowWithMarker(page, marker);
  await row.getByRole('button', { name: 'Cancel', exact: true }).click();
  await expect(page.getByText('Cancel endorsement', { exact: false })).toBeVisible({ timeout: 15_000 });
}

async function cancelPrepare(page: Page, client: string, marker: string, actor: TestAccountKey, reason: string) {
  await goToPolicy(page, actor, client);
  await openCancelDialog(page, marker);
  const dialog = page.getByRole('dialog');
  await expect(dialog.getByText('This reverses the endorsement in full')).toBeVisible({ timeout: 20_000 });
  await dialog.getByLabel('Why is it being cancelled?', { exact: false }).fill(reason);
  await dialog.getByRole('button', { name: 'Prepare cancellation' }).click();
  await expectGone(page, dialog, 'Preparing the cancellation');
}

async function cancelApprove(page: Page, client: string, marker: string, actor: TestAccountKey, reason: string) {
  await goToPolicy(page, actor, client);
  await openCancelDialog(page, marker);
  const dialog = page.getByRole('dialog');
  await expect(dialog.getByText('This reverses the endorsement in full')).toBeVisible({ timeout: 20_000 });
  await dialog.getByLabel('Why is it being cancelled?', { exact: false }).fill(reason);
  await dialog.getByRole('button', { name: 'Approve (independent checker)' }).click();
  await expectGone(page, dialog, 'Approving the cancellation');
  await expect(page.getByText(/^Endorsement cancelled/)).toBeVisible({ timeout: 20_000 });
}

test.describe('P2: endorsement settlement and cancellation ordering', () => {
  test.describe.configure({ mode: 'serial' });

  test('P2-A: cancel newest-first, then the oldest, on policy 3', async ({ page }) => {
    test.setTimeout(480_000);

    const markerA = MARKER('A');
    const markerB = MARKER('B');

    await postEndorsement(page, P2_A_CLIENT, '500000', markerA);
    await postEndorsement(page, P2_A_CLIENT, '400000', markerB);

    // Cancel 1 while 2 is live → refused, naming the need to cancel the newest first.
    await goToPolicy(page, 'insFinMaker', P2_A_CLIENT);
    await openCancelDialog(page, markerA);
    const refusal = page.getByRole('dialog');
    await expect(refusal.getByText('This endorsement cannot be cancelled yet')).toBeVisible({ timeout: 20_000 });
    await expect(refusal.getByText(/cancel the newest one first/i)).toBeVisible();
    await refusal.getByRole('button', { name: 'Close' }).click();

    // Cancel 2 (permitted).
    await cancelPrepare(page, P2_A_CLIENT, markerB, 'insFinMaker', 'Cancelling endorsement 2 — P2-A');
    await cancelApprove(page, P2_A_CLIENT, markerB, 'insFinChecker', 'Cancelling endorsement 2 — P2-A');

    // Cancel 1 again → permitted now that 2 is cancelled.
    await cancelPrepare(page, P2_A_CLIENT, markerA, 'insFinMaker', 'Cancelling endorsement 1 — P2-A');
    await cancelApprove(page, P2_A_CLIENT, markerA, 'insFinChecker', 'Cancelling endorsement 1 — P2-A');

    await expect(page.getByText(/0 posted/)).toBeVisible({ timeout: 15_000 });
  });

  test('P2-B scenario 1: cancellation refused after settlement', async ({ page }) => {
    test.setTimeout(480_000);

    const marker = MARKER('B');
    await postEndorsement(page, P2_B_CLIENT, '2000000', marker);

    // Settle the payable item through the app.
    await goToPolicy(page, 'insFinMaker', P2_B_CLIENT);
    const row = await postedRowWithMarker(page, marker);
    await row.getByRole('button', { name: 'Settle', exact: true }).click();
    const settleDialog = page.getByRole('dialog', { name: /Settle endorsement/ });
    await expect(settleDialog).toBeVisible({ timeout: 15_000 });
    await expect(settleDialog.getByText(/outstanding/).first()).toBeVisible({ timeout: 20_000 });

    // The insurer payable item is the one with a Remit button.
    const remit = settleDialog.getByRole('button', { name: 'Remit', exact: true }).first();
    await expect(remit).toBeVisible({ timeout: 15_000 });
    await remit.click();

    const form = settleDialog;
    await expect(form.getByLabel('Client-money bank account')).toBeVisible({ timeout: 15_000 });
    await form.getByLabel('Client-money bank account').click();
    await page.getByRole('option').first().click();
    await form.getByRole('button', { name: 'Post settlement' }).click();
    await expect(page.getByText(/^Settlement posted/)).toBeVisible({ timeout: 20_000 });
    await settleDialog.getByRole('button', { name: 'Close' }).click();

    // Attempt cancellation → E4 refuses, naming the settlement.
    await openCancelDialog(page, marker);
    const refusal = page.getByRole('dialog');
    await expect(refusal.getByText('This endorsement cannot be cancelled yet')).toBeVisible({ timeout: 20_000 });
    await expect(refusal.getByText(/settled by STL-/i)).toBeVisible();
    await refusal.getByRole('button', { name: 'Close' }).click();
  });

  test('P2-B scenario 2: voiding the settlement unblocks cancellation', async ({ page }) => {
    test.setTimeout(480_000);

    const marker = MARKER('B');
    await goToPolicy(page, 'insFinMaker', P2_B_CLIENT);
    const row = await postedRowWithMarker(page, marker);
    await row.getByRole('button', { name: 'Settle', exact: true }).click();
    await expect(page.getByText('Settle endorsement')).toBeVisible({ timeout: 15_000 });
    const settleDialog = page.getByRole('dialog', { name: /Settle endorsement/ });
    await expect(settleDialog.getByText('Posted settlements')).toBeVisible({ timeout: 20_000 });
    await settleDialog.getByRole('button', { name: 'Void settlement', exact: true }).first().click();
    const voidDialog = page.getByRole('dialog', { name: /Void settlement/ });
    // The title only: the confirm button carries the same words, so a text match is ambiguous.
    await expect(voidDialog.getByRole('heading', { name: /Void settlement/ })).toBeVisible({ timeout: 10_000 });
    await voidDialog.getByLabel('Reason for voiding', { exact: false }).fill('Reversing a test settlement for the P2-B scenario 2 flow');
    await voidDialog.getByRole('button', { name: 'Void settlement', exact: true }).click();
    await expect(page.getByText(/^Settlement voided/)).toBeVisible({ timeout: 20_000 });
    await page.getByRole('dialog', { name: /Settle endorsement/ }).getByRole('button', { name: 'Close' }).click();

    // Retry the cancellation → permitted.
    await cancelPrepare(page, P2_B_CLIENT, marker, 'insFinMaker', 'Cancelling the endorsement after reversing its settlement');
    await cancelApprove(page, P2_B_CLIENT, marker, 'insFinChecker', 'Cancelling the endorsement after reversing its settlement');

    await expect(page.getByText(/0 posted/)).toBeVisible({ timeout: 15_000 });
    const cancelledRow = await postedRowWithMarker(page, marker);
    await expect(cancelledRow.locator('.MuiChip-label')).toHaveText('cancelled', { timeout: 15_000 });
  });
});
