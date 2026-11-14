import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { FakeSupabase, json, loadHandler, req } from './harness';

const TENANT = 'tenant-1';
const ENV = { RESEND_API_KEY: 'resend-key', RESEND_FROM_EMAIL: 'po@example.com' };

let fake: FakeSupabase;
let fetchMock: ReturnType<typeof vi.fn>;
const run = async (body: unknown = { request_id: 'req-1' }, env: Record<string, string | undefined> = ENV, opts?: Parameters<typeof req>[1]) =>
  (await loadHandler('generate-po', fake, env))(req(body, opts));

const po = (over: { po?: Record<string, unknown>; request?: Record<string, unknown> } = {}) => ({
  id: 'po-1',
  po_number: 'PO-0001',
  vendor_name: 'Simba Supplies',
  amount: 1234.5,
  generated_at: '2026-11-10T08:00:00Z',
  requests: {
    id: 'req-1',
    item_description: 'Cement, 50 bags',
    quantity: 50,
    status: 'approved',
    tenant_id: TENANT,
    requester_id: 'requester-1',
    tenants: { name: 'Acme Ltd' },
    departments: { name: 'Works' },
    cost_centers: { name: 'Site A', project_code: 'PRJ-7' },
    requester: { name: 'Rita Requester', email: 'rita@example.com' },
    ...over.request,
  },
  ...over.po,
});

const history = [
  {
    decision: 'approved',
    comment: 'Within budget',
    acted_at: '2026-11-09T08:00:00Z',
    workflow_stages: { name: 'Budget Controller' },
    approver: { name: 'Alice Approver' },
    behalf: { name: 'Bob Boss' },
  },
];

/** Caller is the requester unless a test says otherwise. */
function script(over: Parameters<typeof po>[0] = {}, caller = 'requester-1') {
  fake.userResult = { data: { user: { id: caller, email: 'c@example.com' } }, error: null };
  fake.on('purchase_orders.select', { data: po(over) });
  // approval_actions is read twice: the authorisation lookup (limit 1) and the history (ordered)
  fake.on('approval_actions.select', (c) => (fake.filtersOf(c, 'limit').length ? { data: null } : { data: history }));
  fake.on('has_po_access.rpc', { data: false });
  fake.on('get_my_tenant_id.rpc', { data: TENANT });
}
const nothingProduced = () => {
  expect(fake.storageCalls).toHaveLength(0);
  expect(fetchMock).not.toHaveBeenCalled();
};

beforeEach(() => {
  fake = new FakeSupabase();
  fetchMock = vi.fn().mockResolvedValue({ ok: true, text: async () => '' });
  vi.stubGlobal('fetch', fetchMock);
});
afterEach(() => {
  vi.unstubAllGlobals();
});

describe('generate-po: request validation', () => {
  it('401 without an Authorization header', async () => {
    expect((await run({ request_id: 'r' }, ENV, { auth: null })).status).toBe(401);
    expect(fake.calls).toHaveLength(0);
  });

  it('401 when the session is invalid', async () => {
    fake.userResult = { data: { user: null }, error: { message: 'expired' } };
    expect((await run()).status).toBe(401);
  });

  it('400 when request_id is missing', async () => {
    expect((await run({})).status).toBe(400);
    expect(fake.calls).toHaveLength(0);
  });

  it('looks the PO up by the requested request id', async () => {
    script();
    await run({ request_id: 'req-99' });
    expect(fake.filtersOf(fake.callsTo('purchase_orders.select')[0], 'eq')).toContainEqual(['request_id', 'req-99']);
  });

  it('404 when no PO exists for the request yet (or the request is missing)', async () => {
    script();
    fake.on('purchase_orders.select', { data: null });
    expect((await run()).status).toBe(404);
    fake.on('purchase_orders.select', { data: { ...po(), requests: null } });
    expect((await run()).status).toBe(404);
    nothingProduced();
  });

  it('500 when the PO lookup fails', async () => {
    script();
    fake.on('purchase_orders.select', { error: { message: 'boom' } });
    expect((await run()).status).toBe(500);
    nothingProduced();
  });
});

describe('generate-po: authorization', () => {
  it('lets the requester generate it, with no further lookups', async () => {
    script();
    expect((await run()).status).toBe(200);
    const lookups = fake.callsTo('approval_actions.select').filter((c) => fake.filtersOf(c, 'limit').length);
    expect(lookups).toHaveLength(0);
    expect(fake.callsTo('has_po_access.rpc')).toHaveLength(0);
  });

  it('lets someone in the approval trail generate it, matched on the session user', async () => {
    script({}, 'approver-1');
    fake.on('approval_actions.select', (c) => (fake.filtersOf(c, 'limit').length ? { data: { id: 'a1' } } : { data: history }));
    expect((await run({ request_id: 'req-1', approver_id: 'someone-else' })).status).toBe(200);
    const lookup = fake.callsTo('approval_actions.select').find((c) => fake.filtersOf(c, 'limit').length)!;
    expect(fake.filtersOf(lookup, 'eq')).toEqual(expect.arrayContaining([['request_id', 'req-1'], ['approver_id', 'approver-1']]));
  });

  it("lets a PO-access holder in the request's tenant generate it, evaluated as the caller", async () => {
    script({}, 'po-admin');
    fake.on('has_po_access.rpc', { data: true });
    expect((await run()).status).toBe(200);
    for (const key of ['has_po_access.rpc', 'get_my_tenant_id.rpc']) {
      const c = fake.callsTo(key)[0];
      expect(c.client).toBe('anon');
      expect(c.authorization).toBe('Bearer test-token');
    }
  });

  it('refuses a PO-access holder from another tenant', async () => {
    script({}, 'po-admin');
    fake.on('has_po_access.rpc', { data: true });
    fake.on('get_my_tenant_id.rpc', { data: 'tenant-2' });
    expect((await run()).status).toBe(403);
    nothingProduced();
  });

  it.each([
    ['false', false],
    ['null', null],
    ["the string 'true'", 'true'],
    ['1', 1],
  ])('refuses when has_po_access returns %s (only boolean true counts)', async (_l, value) => {
    script({}, 'stranger');
    fake.on('has_po_access.rpc', { data: value });
    expect((await run()).status).toBe(403);
    nothingProduced();
  });

  it('refuses a stranger, and produces no file and no email', async () => {
    script({}, 'stranger');
    const res = await run();
    expect(res.status).toBe(403);
    expect(fake.callsTo('approval_actions.select').every((c) => fake.filtersOf(c, 'limit').length > 0)).toBe(true);
    nothingProduced();
  });
});

describe('generate-po: document and storage', () => {
  it('puts the PO details and approval trail on the page', async () => {
    script();
    await run();
    const text = fake.pdfLines.join('\n');
    for (const expected of [
      'Acme Ltd',
      'PURCHASE ORDER',
      'PO Number: PO-0001',
      'Simba Supplies',
      'Cement, 50 bags',
      'Quantity: 50',
      'Amount: 1,234.50',
      'Rita Requester',
      'Department: Works',
      'Cost Center: Site A (PRJ-7)',
      'Budget Controller: APPROVED — Alice Approver (on behalf of Bob Boss)',
      '"Within budget"',
    ]) {
      expect(text).toContain(expected);
    }
  });

  it('falls back to safe labels when related rows are missing', async () => {
    script({ request: { tenants: null, departments: null, cost_centers: null, requester: null } });
    fake.on('approval_actions.select', (c) => (fake.filtersOf(c, 'limit').length ? { data: null } : { data: [] }));
    expect((await run()).status).toBe(200);
    const text = fake.pdfLines.join('\n');
    expect(text).toContain('VestaPortal');
    expect(text).toContain('Unknown');
    expect(text).not.toContain('Department:');
    expect(text).not.toContain('Cost Center:');
  });

  it("stores the PDF in the private bucket under the request's tenant folder, then signs it for 7 days", async () => {
    script();
    const res = await run();
    const [upload, signed] = fake.storageCalls;
    expect(upload.bucket).toBe('po-documents');
    expect(upload.op).toBe('upload');
    expect(upload.args[0]).toBe(`${TENANT}/PO-0001.pdf`);
    expect(upload.args[1]).toBe(fake.pdfBytes);
    expect(upload.args[2]).toEqual({ contentType: 'application/pdf', upsert: true });
    expect(signed.op).toBe('createSignedUrl');
    expect(signed.args).toEqual([`${TENANT}/PO-0001.pdf`, 60 * 60 * 24 * 7]);
    expect(await json(res)).toMatchObject({ po_number: 'PO-0001', pdf_url: 'https://signed.test/doc.pdf' });
  });

  it('500 when the upload fails, and no email is sent', async () => {
    script();
    fake.uploadResult = { error: { message: 'bucket missing' } };
    expect((await run()).status).toBe(500);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('500 when the signed URL cannot be created, and no email is sent', async () => {
    script();
    fake.signedResult = { data: null, error: { message: 'sign failed' } };
    const res = await run();
    expect(res.status).toBe(500);
    expect((await json(res)).error).toBe('sign failed');
    expect(fetchMock).not.toHaveBeenCalled();
  });
});

describe('generate-po: email', () => {
  it('emails the requester the PDF as an attachment and reports emailed: true', async () => {
    script();
    const res = await run();
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe('https://api.resend.com/emails');
    expect((init.headers as Record<string, string>).Authorization).toBe('Bearer resend-key');
    const sent = JSON.parse(init.body as string);
    expect(sent.from).toBe('po@example.com');
    expect(sent.to).toEqual(['rita@example.com']);
    expect(sent.subject).toBe('Purchase Order PO-0001 generated');
    expect(sent.attachments).toHaveLength(1);
    expect(sent.attachments[0].filename).toBe('PO-0001.pdf');
    expect(Buffer.from(sent.attachments[0].content, 'base64').equals(Buffer.from(fake.pdfBytes))).toBe(true);
    expect(sent.html).toContain('https://signed.test/doc.pdf');
    expect((await json(res)).emailed).toBe(true);
  });

  it('mails only the requester, even when someone else triggered the generation', async () => {
    script({}, 'po-admin');
    fake.on('has_po_access.rpc', { data: true });
    await run();
    expect(JSON.parse((fetchMock.mock.calls[0][1] as RequestInit).body as string).to).toEqual(['rita@example.com']);
  });

  it.each([
    ['no API key', { RESEND_API_KEY: undefined }],
    ['no from address', { RESEND_FROM_EMAIL: undefined }],
  ])('sends nothing and reports emailed: false when there is %s', async (_l, over) => {
    script();
    const res = await run({ request_id: 'req-1' }, { ...ENV, ...over });
    expect(res.status).toBe(200);
    expect(fetchMock).not.toHaveBeenCalled();
    expect(await json(res)).toMatchObject({ emailed: false, pdf_url: 'https://signed.test/doc.pdf' });
  });

  it('sends nothing when the requester has no email address', async () => {
    script({ request: { requester: { name: 'Rita', email: null } } });
    const res = await run();
    expect(fetchMock).not.toHaveBeenCalled();
    expect((await json(res)).emailed).toBe(false);
  });

  it('a failed email does not fail the request: 200 with the PDF link and the error', async () => {
    script();
    fetchMock.mockResolvedValue({ ok: false, text: async () => 'domain not verified' });
    const res = await run();
    expect(res.status).toBe(200);
    expect(await json(res)).toEqual({
      po_number: 'PO-0001',
      pdf_url: 'https://signed.test/doc.pdf',
      emailed: false,
      email_error: 'domain not verified',
    });
  });
});

describe('generate-po: known gaps (flip to plain `it` when fixed)', () => {
  // A malformed body currently surfaces as a 500 with the JSON parser's message
  // because req.json() is not guarded. A client error should be a 400.
  it.fails('400 for a malformed JSON body', async () => {
    script();
    expect((await run(undefined, ENV, { rawBody: '{not json' })).status).toBe(400);
  });

  // vendor_name and item_description are free text, but they are put into the
  // email HTML as-is, so markup in them is delivered to the requester as markup.
  // They (and the PO number) should be escaped, as the other emails do via
  // escapeHtml in _shared/branding.ts.
  it.fails('HTML-escapes vendor, item and PO number in the email body', async () => {
    script({ po: { vendor_name: '<a href="https://evil.example">Pay here</a>' }, request: { item_description: '<b>x</b>' } });
    await run();
    const html = JSON.parse((fetchMock.mock.calls[0][1] as RequestInit).body as string).html as string;
    expect(html).not.toContain('<a href="https://evil.example">');
    expect(html).not.toContain('<b>x</b>');
  });
});
