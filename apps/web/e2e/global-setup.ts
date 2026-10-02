import { readFileSync, existsSync } from 'node:fs';
import type { FullConfig } from '@playwright/test';
import { dirname, resolve } from 'node:path';

/**
 * Prints which Supabase backend the web app under test will talk to
 * (the URL baked into apps/web/.env, which Vite reads at dev-server
 * start). The three e2e specs depend on seeded @test.local data, so the
 * #1 cause of confusing failures is the app pointing at a DIFFERENT
 * project than the one that was just `supabase db reset`:
 *
 *   - apps/web/.env left pointing at the hosted project while `supabase
 *     db reset` only touched the local Docker stack, or
 *   - a stale `npm run dev` already running against another env, which
 *     Playwright happily reuses (reuseExistingServer).
 *
 * Fail loudly (well, banner loudly) here instead of 20 minutes into a
 * spec run wondering why the dropdowns are empty.
 */
function parseEnvFile(filePath: string): Map<string, string> {
  const vars = new Map<string, string>();
  if (!existsSync(filePath)) return vars;
  for (const line of readFileSync(filePath, 'utf8').split('\n')) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const eq = trimmed.indexOf('=');
    if (eq === -1) continue;
    const key = trimmed.slice(0, eq).trim();
    const value = trimmed.slice(eq + 1).trim().replace(/^["']|["']$/g, '');
    vars.set(key, value);
  }
  return vars;
}

export default function globalSetup(config: FullConfig): void {
  if (process.env.E2E_BASE_URL) {
    console.log(
      `\n[e2e] E2E_BASE_URL=${process.env.E2E_BASE_URL}: using an already-running app, ` +
        `so which Supabase backend it talks to is not checked here.\n`
    );
    return;
  }

  // Same precedence the dev server Playwright boots sees (playwright.config.ts
  // passes { ...process.env, ...e2eEnv } and Vite lets real env vars beat
  // .env files): .env.e2e > process.env > .env. Reading only .env would report
  // the wrong backend whenever .env.e2e is what points the app at the local stack.
  // FullConfig has no `configDir` (that is Playwright-internal, so it was
  // undefined at runtime). Derive the directory from the public `configFile`
  // (apps/web/playwright.config.ts); fall back to cwd, which is apps/web when
  // run via `npm run test:e2e --workspace=apps/web`.
  const configDir = config.configFile ? dirname(config.configFile) : process.cwd();
  const dotEnv = parseEnvFile(resolve(configDir, '.env'));
  const e2eEnv = parseEnvFile(resolve(configDir, '.env.e2e'));
  const pick = (key: string): string | undefined =>
    e2eEnv.get(key) ?? process.env[key] ?? dotEnv.get(key);

  const url = pick('VITE_SUPABASE_URL');
  if (!url) {
    console.warn(
      `\n[e2e] No VITE_SUPABASE_URL found in apps/web/.env.e2e, the environment, or apps/web/.env --` +
        `\n      the dev server will have no Supabase URL.` +
        `\n      Copy apps/web/.env.e2e.example to .env.e2e and fill it from 'supabase status'` +
        `\n      (local: http://127.0.0.1:54321).\n`
    );
    return;
  }

  const anon = pick('VITE_SUPABASE_ANON_KEY') ?? '';
  const looksLocal = /localhost|127\.0\.0\.1|0\.0\.0\.0/.test(url);

  console.log(`\n[e2e] Web app will talk to Supabase at ${url} (${looksLocal ? 'LOCAL' : 'REMOTE'})`);
  console.log(`[e2e] anon key configured: ${anon.length > 20 ? 'yes' : 'NO -- check apps/web/.env.e2e or apps/web/.env'}\n`);

  if (!looksLocal) {
    console.warn(
      `[e2e] WARNING: that URL is NOT the local Supabase stack. 'supabase db reset' only` +
        `\n      resets the LOCAL database and will not affect ${url}. Point .env.e2e at` +
        `\n      http://127.0.0.1:54321 (or run this against the project you actually reset),` +
        `\n      and make sure no stale 'npm run dev' on :5173 is being reused -- stop it and` +
        `\n      let Playwright boot its own server.\n`
    );
  }
}