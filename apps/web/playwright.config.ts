/// <reference types="node" />

import { defineConfig, devices } from '@playwright/test';

/**
 * Smoke-test config for the 3 money-flow paths (Procurement, Finance
 * invoice/payment, Payroll disbursement). See e2e/README.md before running.
 *
 * These tests run against a real Supabase project (either your own local
 * `supabase start` stack or a live test tenant) using seeded @test.local
 * accounts — there is no mocking. They are not part of `npm run test`
 * (vitest) and are not wired into CI yet; run them explicitly with
 * `npm run test:e2e`.
 */
export default defineConfig({
  testDir: './e2e',
  timeout: 60_000,
  expect: { timeout: 10_000 },
  fullyParallel: false, // specs share seeded workflow state (one request moving through stages)
  retries: 0,
  workers: 1,
  reporter: [['list'], ['html', { open: 'never' }]],

  use: {
    baseURL: process.env.E2E_BASE_URL ?? 'http://localhost:5173',
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
  },

  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
  ],

  // Only boot a local dev server if E2E_BASE_URL wasn't overridden to point
  // at an already-running instance (e.g. a deployed preview).
  webServer: process.env.E2E_BASE_URL
    ? undefined
    : {
        command: 'npm run dev',
        url: 'http://localhost:5173',
        reuseExistingServer: !process.env.CI,
        timeout: 30_000,
      },
});
