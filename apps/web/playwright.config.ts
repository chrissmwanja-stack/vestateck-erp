/// <reference types="node" />

import { defineConfig, devices } from '@playwright/test';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

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

// Minimal .env parser (no dotenv dependency) so `npm run test:e2e` can point
// the dev server it boots at your LOCAL `supabase start` stack, without
// touching apps/web/.env (which may point at a live/linked project for
// normal `npm run dev` work). Copy .env.e2e.example to .env.e2e and fill in
// the values `supabase status` prints. See e2e/README.md.
function loadEnvFile(filename: string): Record<string, string> {
  const filePath = path.resolve(__dirname, filename);
  if (!fs.existsSync(filePath)) return {};
  const result: Record<string, string> = {};
  for (const rawLine of fs.readFileSync(filePath, 'utf-8').split('\n')) {
    const line = rawLine.trim();
    if (!line || line.startsWith('#')) continue;
    const eq = line.indexOf('=');
    if (eq === -1) continue;
    const key = line.slice(0, eq).trim();
    let value = line.slice(eq + 1).trim();
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    result[key] = value;
  }
  return result;
}

const e2eEnv = loadEnvFile('.env.e2e');
// process.env values can be `string | undefined`; Playwright's webServer.env
// wants `Record<string, string>`, so drop the undefined ones.
const processEnvClean: Record<string, string> = Object.fromEntries(
  Object.entries(process.env).filter((entry): entry is [string, string] => entry[1] !== undefined)
);

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
  //
  // IMPORTANT: reuseExistingServer means Playwright will happily attach to
  // a `npm run dev` you already have running on :5173 from earlier — and
  // that instance was started with whatever apps/web/.env said at the time,
  // NOT with .env.e2e. Stop any existing dev server before running
  // `npm run test:e2e` or this override silently does nothing.
  webServer: process.env.E2E_BASE_URL
    ? undefined
    : {
        command: 'npm run dev',
        url: 'http://localhost:5173',
        reuseExistingServer: !process.env.CI,
        timeout: 30_000,
        env: { ...processEnvClean, ...e2eEnv }, 
      },
});
