import { Page, expect } from '@playwright/test';

/**
 * Seeded @test.local accounts from supabase/seed.sql. All share the
 * password Tester123 unless overridden per-account via env vars below
 * (useful if a target environment reseeds with different passwords).
 *
 * None of these are MFA-enrolled in the seed data, so the login helper
 * assumes the plain password → app flow and does not handle the TOTP
 * challenge screen. If a target account has MFA turned on, log in with a
 * non-MFA account instead of extending this helper to punch through 2FA.
 */
export const TEST_ACCOUNTS = {
  costControlEngineer: { email: 'cce@test.local', role: 'Cost Control Engineer' },
  costControlManager: { email: 'cost.control@test.local', role: 'Cost Control Manager' },
  procurementOfferEntry: { email: 'procurement.offer@test.local', role: 'Procurement/Logistics Expert' },
  procurementChief: { email: 'procurement@test.local', role: 'Procurement & Logistics Chief' },
  finance: { email: 'finance@test.local', role: 'Finance Officer' },
  hr: { email: 'hr@test.local', role: 'HR Manager' },
  projectManager: { email: 'pm@test.local', role: 'Project Manager' },
} as const;

export type TestAccountKey = keyof typeof TEST_ACCOUNTS;

function passwordFor(key: TestAccountKey): string {
  const envOverride = process.env[`E2E_PASSWORD_${key.toUpperCase()}`];
  return envOverride ?? process.env.E2E_DEFAULT_PASSWORD ?? 'Tester123';
}

/** Logs in as a seeded test account and waits for the app shell to load. */
export async function loginAs(page: Page, key: TestAccountKey) {
  const account = TEST_ACCOUNTS[key];
  await page.goto('/login');
  await page.getByLabel('Email').fill(account.email);
  await page.getByLabel('Password', { exact: true }).fill(passwordFor(key));
  await page.getByRole('button', { name: 'Sign in' }).click();

  // Post-login redirect target varies by role's default route, so just
  // wait for the login form to disappear and the top-bar sign-out control
  // (present on every authenticated route) to appear.
  await expect(page.getByRole('button', { name: 'Sign out' })).toBeVisible({ timeout: 15_000 });
}

/** Signs out and waits for the login form to come back. */
export async function logout(page: Page) {
  await page.getByRole('button', { name: 'Sign out' }).click();
  await expect(page.getByLabel('Email')).toBeVisible({ timeout: 10_000 });
}
