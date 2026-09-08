import { readFileSync, existsSync } from 'node:fs';
import { resolve } from 'node:path';

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
export default function globalSetup(config: { configDir: string }): void {
  const envPath = resolve(config.configDir, '.env');

  if (!existsSync(envPath)) {
    console.warn(
      `\n[e2e] No apps/web/.env found -- the dev server will have no VITE_SUPABASE_URL.` +
        `\n      Copy apps/web/.env.example and point it at the Supabase stack you seeded` +
        `\n      (local: http://127.0.0.1:54321 -- get the anon key from 'supabase status').\n`
    );
    return;
  }

  const vars = new Map<string, string>();
  for (const line of readFileSync(envPath, 'utf8').split('\n')) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const eq = trimmed.indexOf('=');
    if (eq === -1) continue;
    const key = trimmed.slice(0, eq).trim();
    const value = trimmed.slice(eq + 1).trim().replace(/^["']|["']$/g, '');
    vars.set(key, value);
  }

  const url = vars.get('VITE_SUPABASE_URL') ?? '(missing)';
  const anon = vars.get('VITE_SUPABASE_ANON_KEY') ?? '';
  const looksLocal = /localhost|127\.0\.0\.1|0\.0\.0\.0/.test(url);

  console.log(`\n[e2e] Web app will talk to Supabase at ${url} (${looksLocal ? 'LOCAL' : 'REMOTE'})`);
  console.log(`[e2e] anon key configured: ${anon.length > 20 ? 'yes' : 'NO -- check apps/web/.env'}\n`);

  if (!looksLocal) {
    console.warn(
      `[e2e] WARNING: that URL is NOT the local Supabase stack. 'supabase db reset' only` +
        `\n      resets the LOCAL database and will not affect ${url}. Either point` +
        `\n      apps/web/.env at http://127.0.0.1:54321 (or run this against the project` +
        `\n      you actually reset), and make sure no stale 'npm run dev' on :5173 is being` +
        `\n      reused -- stop it and let Playwright boot its own server.\n`
    );
  }
}
