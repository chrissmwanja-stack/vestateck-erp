import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { FakeSupabase, json, loadFn, req } from './harness';
import { DEFAULT_BRANDING } from '../_shared/branding';

const SECRET = 's3cret-value';
const ENV = { OPERATOR_DIGEST_SECRET: SECRET, RESEND_API_KEY: 'resend-key', RESEND_FROM_EMAIL: 'ops@example.com' };

let fake: FakeSupabase;
let fetchMock: ReturnType<typeof vi.fn>;

const post = (secret: string | null = SECRET, method = 'POST') => {
  const headers: Record<string, string> = {};
  if (secret !== null) headers['x-digest-secret'] = secret;
  return new Request('http://localhost/fn', { method, headers });
};
const run = async (r: Request, env: Record<string, string | undefined> = ENV) => (await loadFn('send-operator-digest', fake, env)).handler(r);

const payload = (over: Record<string, unknown> = {}) => ({
  totals: { companies: 5, active: 3, pending: 1, suspended: 1, live: 2, users: 40 },
  new_companies: [],
  new_users: 0,
  stalled: [],
  quiet: [],
  trials_ending: [],
  pending_over_threshold: [],
  open_impersonations: [],
  admins_without_mfa: [],
  attention_count: 0,
  ...over,
});
const row = (id: string, over: Record<string, unknown> = {}) => ({
  id,
  period_start: '2026-11-13T04:00:00Z',
  period_end: '2026-11-14T04:00:00Z',
  generated_at: '2026-11-14T04:00:05Z',
  attention_count: 0,
  payload: payload(),
  recipients: ['ops@example.com'],
  ...over,
});

function scriptRows(rows: unknown[]) {
  fake.on('platform_digests.select', { data: rows });
  fake.on('get_platform_branding.rpc', { data: null });
  fake.on('platform_digest_summary.rpc', { data: 'All quiet.' });
  fake.on('mark_platform_digest_delivered.rpc', {});
}
const marks = () => fake.callsTo('mark_platform_digest_delivered.rpc').map((c) => c.payload);

beforeEach(() => {
  fake = new FakeSupabase();
  fetchMock = vi.fn().mockResolvedValue({ ok: true });
  vi.stubGlobal('fetch', fetchMock);
});
afterEach(() => {
  vi.unstubAllGlobals();
});

describe('send-operator-digest: authentication', () => {
  it('405 for anything but POST', async () => {
    expect((await run(post(SECRET, 'GET'))).status).toBe(405);
    expect(fake.calls).toHaveLength(0);
  });

  it('fails closed (503) when OPERATOR_DIGEST_SECRET is not configured, even for a request with an empty secret', async () => {
    const res = await run(post(''), { ...ENV, OPERATOR_DIGEST_SECRET: undefined });
    expect(res.status).toBe(503);
    expect(fake.calls).toHaveLength(0);
  });

  it.each([
    ['no header', null],
    ['an empty header', ''],
    ['a wrong secret', 'nope'],
    ['a prefix of the secret', SECRET.slice(0, -1)],
    ['the secret with extra characters', SECRET + 'x'],
    ['the secret in a different case', SECRET.toUpperCase()],
  ])('401 with %s, and no database access', async (_l, secret) => {
    const res = await run(post(secret));
    expect(res.status).toBe(401);
    expect(fake.calls).toHaveLength(0);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('does not accept the secret as a bearer token or query parameter', async () => {
    const r = new Request(`http://localhost/fn?x-digest-secret=${SECRET}`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${SECRET}` },
    });
    expect((await run(r)).status).toBe(401);
  });

  it('proceeds with the correct secret', async () => {
    scriptRows([]);
    const res = await run(post());
    expect(res.status).toBe(200);
    expect(await json(res)).toEqual({ processed: 0, results: [] });
  });
});

describe('send-operator-digest: selecting digests', () => {
  it('reads pending digests oldest first, capped at 20, with the service role', async () => {
    scriptRows([]);
    await run(post());
    const q = fake.callsTo('platform_digests.select')[0];
    expect(q.client).toBe('service');
    expect(fake.filtersOf(q, 'eq')).toContainEqual(['delivery_status', 'pending']);
    expect(fake.filtersOf(q, 'order')).toContainEqual(['generated_at', { ascending: true }]);
    expect(fake.filtersOf(q, 'limit')).toContainEqual([20]);
  });

  it('500 when the digests cannot be read, and nothing is sent', async () => {
    scriptRows([]);
    fake.on('platform_digests.select', { error: { message: 'db down' } });
    const res = await run(post());
    expect(res.status).toBe(500);
    expect(fetchMock).not.toHaveBeenCalled();
  });
});

describe('send-operator-digest: skipping', () => {
  it.each([['an empty list', []], ['null', null]])('marks a digest with %s of recipients skipped, and sends nothing', async (_l, recipients) => {
    scriptRows([row('d1', { recipients })]);
    const res = await run(post());
    expect(marks()).toEqual([{ p_id: 'd1', p_status: 'skipped', p_error: 'no recipients' }]);
    expect(fetchMock).not.toHaveBeenCalled();
    expect((await json(res)).results).toEqual([{ id: 'd1', status: 'skipped' }]);
  });

  it.each([
    ['no API key', { RESEND_API_KEY: undefined }],
    ['no from address', { RESEND_FROM_EMAIL: undefined }],
    ['neither', { RESEND_API_KEY: undefined, RESEND_FROM_EMAIL: undefined }],
  ])('marks the digest skipped with an explanation when email has %s', async (_l, over) => {
    scriptRows([row('d1')]);
    const res = await run(post(), { ...ENV, ...over });
    expect(marks()).toEqual([
      { p_id: 'd1', p_status: 'skipped', p_error: 'email not configured (RESEND_API_KEY / RESEND_FROM_EMAIL)' },
    ]);
    expect(fetchMock).not.toHaveBeenCalled();
    expect((await json(res)).results).toEqual([{ id: 'd1', status: 'skipped', error: 'email not configured' }]);
  });
});

describe('send-operator-digest: sending', () => {
  it('emails every recipient from the configured sender and marks the digest sent', async () => {
    scriptRows([row('d1', { recipients: ['a@x.example', 'b@x.example'] })]);
    const res = await run(post());
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe('https://api.resend.com/emails');
    expect((init.headers as Record<string, string>).Authorization).toBe('Bearer resend-key');
    const sent = JSON.parse(init.body as string);
    expect(sent.from).toBe('ops@example.com');
    expect(sent.to).toEqual(['a@x.example', 'b@x.example']);
    expect(sent.subject).toBe(`[${DEFAULT_BRANDING.platformName}] Operator digest: all clear`);
    expect(marks()).toEqual([{ p_id: 'd1', p_status: 'sent', p_error: null }]);
    expect(await json(res)).toEqual({ processed: 1, results: [{ id: 'd1', status: 'sent' }] });
  });

  it("builds the summary in SQL from the row's own payload", async () => {
    const p = payload({ attention_count: 2 });
    scriptRows([row('d1', { payload: p })]);
    await run(post());
    expect(fake.callsTo('platform_digest_summary.rpc')[0].payload).toEqual({ p_payload: p });
    const html = JSON.parse((fetchMock.mock.calls[0][1] as RequestInit).body as string).html as string;
    expect(html).toContain('All quiet.');
  });

  it('marks the digest failed with Resend\'s error and keeps going with the next one', async () => {
    scriptRows([row('d1'), row('d2')]);
    fetchMock
      .mockResolvedValueOnce({ ok: false, status: 500, text: async () => 'upstream broke' })
      .mockResolvedValueOnce({ ok: true });
    const res = await run(post());
    expect(marks()).toEqual([
      { p_id: 'd1', p_status: 'failed', p_error: 'Resend 500: upstream broke' },
      { p_id: 'd2', p_status: 'sent', p_error: null },
    ]);
    const body = await json(res);
    expect(body.processed).toBe(2);
    expect(body.results).toEqual([
      { id: 'd1', status: 'failed', error: 'Resend 500: upstream broke' },
      { id: 'd2', status: 'sent' },
    ]);
  });

  it('a network failure marks the digest failed rather than crashing the run', async () => {
    scriptRows([row('d1')]);
    fetchMock.mockRejectedValue(new Error('network down'));
    const res = await run(post());
    expect(res.status).toBe(200);
    expect(marks()).toEqual([{ p_id: 'd1', p_status: 'failed', p_error: 'network down' }]);
  });

  it('handles a mixed batch: skipped, sent and failed each get their own outcome', async () => {
    scriptRows([row('d1', { recipients: [] }), row('d2'), row('d3')]);
    fetchMock.mockResolvedValueOnce({ ok: true }).mockResolvedValueOnce({ ok: false, status: 429, text: async () => 'slow down' });
    const res = await run(post());
    expect(((await json(res)).results as { id: string; status: string }[]).map((r) => `${r.id}:${r.status}`)).toEqual([
      'd1:skipped',
      'd2:sent',
      'd3:failed',
    ]);
  });
});

describe('renderDigest', () => {
  type Render = (b: typeof DEFAULT_BRANDING, row: ReturnType<typeof row>, summary: string) => { subject: string; html: string };
  const load = async (env: Record<string, string | undefined> = ENV) =>
    (await loadFn('send-operator-digest', fake, env)).mod.renderDigest as Render;

  it('says how many items need attention, or that all is clear', async () => {
    const render = await load();
    expect(render(DEFAULT_BRANDING, row('d', { payload: payload({ attention_count: 3 }) }), 's').subject).toBe(
      '[VestaPortal] Operator digest: 3 item(s) need attention',
    );
    const clear = render(DEFAULT_BRANDING, row('d'), 's');
    expect(clear.subject).toContain('all clear');
    expect(clear.html).toContain('All clear.');
  });

  it('escapes company names, emails and free text, and URL-encodes company ids in links', async () => {
    const render = await load();
    const evil = '<img src=x onerror=alert(1)>';
    const { html } = render(
      DEFAULT_BRANDING,
      row('d', {
        payload: payload({
          attention_count: 5,
          new_companies: [{ id: 'a/b?c', name: evil, plan: evil, status: evil, created_at: '' }],
          trials_ending: [{ id: 't1', name: 'T', trial_ends_at: '', days_left: 0, stage_key: evil, contact_email: evil }],
          stalled: [{ id: 's1', name: 'S', stage_key: 'created', next_step: evil, days_in_stage: 9 }],
          admins_without_mfa: [evil],
          open_impersonations: [{ admin_email: evil, tenant_name: evil, started_at: '', reason: evil }],
        }),
      }),
      evil,
    );
    expect(html).not.toContain('<img src=x');
    expect(html).toContain('&lt;img src=x onerror=alert(1)&gt;');
    expect(html).toContain('/admin/companies/a%2Fb%3Fc');
  });

  it('shows only the sections that have items, with counts', async () => {
    const render = await load();
    const { html } = render(
      DEFAULT_BRANDING,
      row('d', {
        payload: payload({
          attention_count: 2,
          quiet: [{ id: 'q1', name: 'Quiet Co', plan: 'standard', days_quiet: 45 }],
          admins_without_mfa: ['a@x.example', 'b@x.example'],
        }),
      }),
      's',
    );
    expect(html).toContain('Gone quiet (30+ days) (1)');
    expect(html).toContain('Platform admins without MFA (2)');
    expect(html).not.toContain('Stalled in setup');
    expect(html).not.toContain('New companies');
  });

  it('words trial endings and the pending threshold from the data', async () => {
    const render = await load();
    const { html } = render(
      DEFAULT_BRANDING,
      row('d', {
        payload: payload({
          attention_count: 3,
          trials_ending: [
            { id: 't0', name: 'Today Co', trial_ends_at: '', days_left: 0, stage_key: 'live' },
            { id: 't3', name: 'Soon Co', trial_ends_at: '', days_left: 3, stage_key: 'live' },
          ],
          pending_over_threshold: [{ id: 'p1', name: 'Slow Co', stage_key: 'created', days_pending: 4 }],
          settings: { pending_company_threshold_days: 5 },
        }),
      }),
      's',
    );
    expect(html).toContain('ends today');
    expect(html).toContain('3 day(s) left');
    expect(html).toContain('Pending longer than 5 days');
  });

  it('points links at APP_URL, falling back to the first allowed origin, without a trailing slash', async () => {
    const p = payload({ attention_count: 1, quiet: [{ id: 'q1', name: 'Q', plan: 'p', days_quiet: 31 }] });
    const a = (await load({ ...ENV, APP_URL: 'https://app.example.com/' }))(DEFAULT_BRANDING, row('d', { payload: p }), 's');
    expect(a.html).toContain('href="https://app.example.com/admin/companies/q1"');
    expect(a.html).toContain('href="https://app.example.com/admin"');
    const b = (await load({ ...ENV, ALLOWED_ORIGINS: 'https://one.example,https://two.example' }))(DEFAULT_BRANDING, row('d', { payload: p }), 's');
    expect(b.html).toContain('href="https://one.example/admin"');
  });
});
