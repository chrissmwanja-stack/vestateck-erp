import type { APIResponse, Page } from '@playwright/test';

/**
 * Direct PostgREST calls made with the signed-in user's own session token.
 *
 * Why this exists: the Company Admin screens hide their controls from
 * non-admins, but that is nav-level defence only. The real enforcement is
 * RLS (is_tenant_admin() etc.), and a spec that only checks "the button is
 * gone" cannot catch a regression where the policy is loosened. These
 * helpers let a spec try the write a hostile client would try, using the
 * same JWT the browser holds, and assert the database refuses it.
 *
 * The Supabase URL and anon key are read from the app's own traffic rather
 * than from env vars, so the spec cannot drift from what the dev server is
 * actually talking to (see global-setup.ts for the usual failure mode).
 */

export interface RestSession {
  restUrl: string; // e.g. http://127.0.0.1:54321/rest/v1
  apikey: string;
  accessToken: string;
  userId: string;
}

/**
 * Call right after loginAs(). Reads the session from localStorage and the
 * project URL / anon key from the first PostgREST request the app makes.
 */
export async function captureRestSession(page: Page): Promise<RestSession> {
  // Make sure at least one PostgREST call has happened on this page.
  const seen = page.waitForRequest((r) => r.url().includes('/rest/v1/'), { timeout: 15_000 });
  await page.goto('/');
  const request = await seen;

  const url = new URL(request.url());
  const apikey = request.headers()['apikey'];
  if (!apikey) throw new Error('Could not read the anon key from an app request.');

  const session = await page.evaluate(() => {
    for (let i = 0; i < localStorage.length; i++) {
      const key = localStorage.key(i);
      if (key && /^sb-.+-auth-token$/.test(key)) {
        const parsed = JSON.parse(localStorage.getItem(key) ?? 'null');
        return parsed ? { accessToken: parsed.access_token, userId: parsed.user?.id } : null;
      }
    }
    return null;
  });
  if (!session?.accessToken || !session.userId) {
    throw new Error('No Supabase session found in localStorage -- is the user signed in?');
  }

  return { restUrl: `${url.origin}/rest/v1`, apikey, ...session };
}

function headers(s: RestSession, extra: Record<string, string> = {}) {
  return {
    apikey: s.apikey,
    Authorization: `Bearer ${s.accessToken}`,
    'Content-Type': 'application/json',
    Prefer: 'return=representation',
    ...extra,
  };
}

export async function restSelect(page: Page, s: RestSession, pathAndQuery: string): Promise<unknown[]> {
  const res = await page.request.get(`${s.restUrl}/${pathAndQuery}`, { headers: headers(s) });
  if (!res.ok()) throw new Error(`GET ${pathAndQuery} failed: ${res.status()} ${await res.text()}`);
  return (await res.json()) as unknown[];
}

export const restInsert = (page: Page, s: RestSession, table: string, row: Record<string, unknown>) =>
  page.request.post(`${s.restUrl}/${table}`, { headers: headers(s), data: row });

export const restUpdate = (page: Page, s: RestSession, table: string, filter: string, patch: Record<string, unknown>) =>
  page.request.patch(`${s.restUrl}/${table}?${filter}`, { headers: headers(s), data: patch });

export const restDelete = (page: Page, s: RestSession, table: string, filter: string) =>
  page.request.delete(`${s.restUrl}/${table}?${filter}`, { headers: headers(s) });

/** The caller's own tenant, from app_users (readable by tenant members). */
export async function myTenantId(page: Page, s: RestSession): Promise<string> {
  const rows = (await restSelect(page, s, `app_users?id=eq.${s.userId}&select=tenant_id`)) as { tenant_id: string }[];
  if (!rows[0]?.tenant_id) throw new Error('Could not resolve the signed-in user\'s tenant.');
  return rows[0].tenant_id;
}

/**
 * True when PostgREST refused the write outright (RLS violation on INSERT
 * is a 4xx), or accepted the request but touched no rows (RLS on UPDATE /
 * DELETE filters rows out and returns an empty representation).
 */
export async function wasRefusedOrNoOp(res: APIResponse): Promise<boolean> {
  if (!res.ok()) return true;
  const text = (await res.text()).trim();
  if (!text) return true;
  try {
    const parsed = JSON.parse(text);
    return Array.isArray(parsed) && parsed.length === 0;
  } catch {
    return false;
  }
}
