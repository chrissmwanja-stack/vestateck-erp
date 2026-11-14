import { createHash } from 'node:crypto';
import { beforeEach, describe, expect, it } from 'vitest';
import { FakeSupabase, json, loadHandler, req } from './harness';

const TENANT = 'tenant-1';
const KINDS = ['client_debit_note', 'insurer_debit_note', 'risk_note', 'renewal_notice'] as const;

let fake: FakeSupabase;
const run = async (body: unknown = { policy_id: 'pol-1', kind: 'client_debit_note' }, opts?: Parameters<typeof req>[1]) =>
  (await loadHandler('generate-ins-doc', fake))(req(body, opts));

const policy = (over: Record<string, unknown> = {}) => ({
  id: 'pol-1',
  policy_no: 'POL-0001',
  status: 'active',
  transaction_type: 'new_business',
  inception_date: '2026-01-01',
  expiry_date: '2026-12-31',
  sum_insured: 50000000,
  currency: 'UGX',
  gross_premium: 1200000,
  commission_rate_pct: 12.5,
  commission_amount: 150000,
  net_premium_to_insurer: 1050000,
  risk_description: null,
  tenant_id: TENANT,
  ins_clients: { client_id: 'c1', bd_clients: { name: 'Kato Traders', email: 'kato@example.com', phone: '+256700000000' } },
  ins_insurers: { name: 'Jubilee Insurance' },
  ins_product_lines: { name: 'Motor Comprehensive' },
  tenants: { name: 'Acme Brokers' },
  ...over,
});

function script(over: Record<string, unknown> = {}) {
  fake.on('can_access_insurance.rpc', { data: true });
  fake.on('get_my_tenant_id.rpc', { data: TENANT });
  fake.on('ins_policies.select', { data: policy(over) });
  fake.on('ins_policy_risks.select', { data: [] });
  fake.on('documents_register.rpc', { data: { id: 'doc-1' } });
}
const text = () => fake.pdfLines.join('\n');
const nothingProduced = () => {
  expect(fake.storageCalls).toHaveLength(0);
  expect(fake.callsTo('documents_register.rpc')).toHaveLength(0);
};

beforeEach(() => {
  fake = new FakeSupabase();
  fake.userResult = { data: { user: { id: 'caller-1', email: 'c@example.com' } }, error: null };
});

describe('generate-ins-doc: request validation', () => {
  it('401 without an Authorization header', async () => {
    expect((await run(undefined, { auth: null })).status).toBe(401);
    expect(fake.calls).toHaveLength(0);
  });

  it('401 when the session is invalid', async () => {
    fake.userResult = { data: { user: null }, error: { message: 'expired' } };
    expect((await run()).status).toBe(401);
  });

  it('400 when policy_id is missing', async () => {
    expect((await run({ kind: 'risk_note' })).status).toBe(400);
    expect(fake.calls).toHaveLength(0);
  });

  it.each([[undefined], ['invoice'], ['CLIENT_DEBIT_NOTE'], ['']])('400 for kind %j, listing the valid kinds', async (kind) => {
    const res = await run({ policy_id: 'pol-1', kind });
    expect(res.status).toBe(400);
    expect((await json(res)).error).toContain(KINDS.join(', '));
    expect(fake.calls).toHaveLength(0);
  });

  it('404 when the policy does not exist', async () => {
    script();
    fake.on('ins_policies.select', { data: null });
    expect((await run()).status).toBe(404);
    nothingProduced();
  });

  it('500 when the policy lookup fails', async () => {
    script();
    fake.on('ins_policies.select', { error: { message: 'boom' } });
    expect((await run()).status).toBe(500);
    nothingProduced();
  });

  it('loads the policy by the requested id', async () => {
    script();
    await run({ policy_id: 'pol-77', kind: 'client_debit_note' });
    expect(fake.filtersOf(fake.callsTo('ins_policies.select')[0], 'eq')).toContainEqual(['id', 'pol-77']);
  });
});

describe('generate-ins-doc: authorization', () => {
  it('checks insurance access and tenant as the caller, not with the service role', async () => {
    script();
    await run();
    for (const key of ['can_access_insurance.rpc', 'get_my_tenant_id.rpc']) {
      const c = fake.callsTo(key)[0];
      expect(c.client).toBe('anon');
      expect(c.authorization).toBe('Bearer test-token');
    }
  });

  it.each([
    ['false', false],
    ['null', null],
    ["the string 'true'", 'true'],
    ['1', 1],
  ])('403 when can_access_insurance returns %s (only boolean true counts)', async (_l, value) => {
    script();
    fake.on('can_access_insurance.rpc', { data: value });
    expect((await run()).status).toBe(403);
    nothingProduced();
  });

  it("403 for someone with insurance access in a different tenant from the policy's", async () => {
    script();
    fake.on('get_my_tenant_id.rpc', { data: 'tenant-2' });
    expect((await run()).status).toBe(403);
    nothingProduced();
  });

  it('403 when the caller\'s tenant cannot be resolved', async () => {
    script();
    fake.on('get_my_tenant_id.rpc', { data: null });
    expect((await run()).status).toBe(403);
    nothingProduced();
  });
});

describe('generate-ins-doc: document content', () => {
  it('headlines every kind with its own title and the policy, insured and insurer', async () => {
    const titles: Record<string, string> = {
      client_debit_note: 'CLIENT DEBIT NOTE',
      insurer_debit_note: 'INSURER DEBIT NOTE (COMMISSION)',
      risk_note: 'RISK NOTE',
      renewal_notice: 'RENEWAL NOTICE',
    };
    for (const kind of KINDS) {
      fake = new FakeSupabase();
      fake.userResult = { data: { user: { id: 'caller-1', email: 'c@example.com' } }, error: null };
      script();
      await run({ policy_id: 'pol-1', kind });
      const t = text();
      expect(t).toContain(titles[kind]);
      for (const s of ['Acme Brokers', 'Policy: POL-0001', 'Product: Motor Comprehensive', 'Kato Traders', 'Email: kato@example.com', 'Jubilee Insurance']) {
        expect(t).toContain(s);
      }
      expect(t).toContain(`template ins_${kind} v1`);
    }
  });

  it('client debit note: shows the premium breakdown and the amount due from the insured', async () => {
    script();
    await run({ policy_id: 'pol-1', kind: 'client_debit_note' });
    const t = text();
    expect(t).toContain('Gross premium: UGX 1,200,000.00');
    expect(t).toContain('Commission at 12.50%: UGX 150,000.00');
    expect(t).toContain('Net premium to insurers: UGX 1,050,000.00');
    expect(t).toContain('Amount due from the insured: UGX 1,200,000.00');
  });

  it('insurer debit note: shows the commission due', async () => {
    script();
    await run({ policy_id: 'pol-1', kind: 'insurer_debit_note' });
    expect(text()).toContain('Commission due to us from the insurers: UGX 150,000.00');
  });

  it('renewal notice: states the expiry date', async () => {
    script();
    await run({ policy_id: 'pol-1', kind: 'renewal_notice' });
    expect(text()).toContain('This policy expires on 2026-12-31.');
  });

  it('includes the risk description when present, and omits it when absent', async () => {
    script({ risk_description: 'Toyota Hilux UBA 123X' });
    await run();
    expect(text()).toContain('Toyota Hilux UBA 123X');
    fake = new FakeSupabase();
    fake.userResult = { data: { user: { id: 'caller-1', email: 'c@example.com' } }, error: null };
    script();
    await run();
    expect(text()).not.toContain('Risk description');
  });

  it('copes with missing parties and dates', async () => {
    script({ ins_clients: null, ins_insurers: null, ins_product_lines: null, tenants: null, expiry_date: null, commission_rate_pct: 0 });
    expect((await run({ policy_id: 'pol-1', kind: 'renewal_notice' })).status).toBe(200);
    expect(text()).toContain('VestaPortal');
    expect(text()).toContain('This policy expires on -.');
  });
});

describe('generate-ins-doc: risk note', () => {
  const risks = [
    { ins_risks: { description: 'Toyota Hilux', risk_type: 'motor', reg_no: 'UBA 123X', make: 'Toyota', model: 'Hilux', year_made: 2019, sum_insured: 40000000 } },
    { ins_risks: { description: 'Warehouse stock', risk_type: 'fire', reg_no: null, make: null, model: null, year_made: null, sum_insured: 10000000 } },
    { ins_risks: null },
  ];

  it('lists each linked risk with its sum insured and a schedule total', async () => {
    script();
    fake.on('ins_policy_risks.select', { data: risks });
    await run({ policy_id: 'pol-1', kind: 'risk_note' });
    const t = text();
    expect(t).toContain('- Toyota Hilux');
    expect(t).toContain('Toyota Hilux 2019 reg UBA 123X (motor)');
    expect(t).toContain('Sum insured: UGX 40,000,000.00');
    expect(t).toContain('- Warehouse stock');
    expect(t).toContain('Total sum insured on schedule: UGX 50,000,000.00');
    expect(fake.filtersOf(fake.callsTo('ins_policy_risks.select')[0], 'eq')).toContainEqual(['policy_id', 'pol-1']);
  });

  it('says so when no risks are linked', async () => {
    script();
    await run({ policy_id: 'pol-1', kind: 'risk_note' });
    expect(text()).toContain('No risks are linked to this policy.');
    expect(text()).toContain('Total sum insured on schedule: UGX 0.00');
  });

  it('500 when the risks cannot be read, and nothing is stored', async () => {
    script();
    fake.on('ins_policy_risks.select', { error: { message: 'boom' } });
    expect((await run({ policy_id: 'pol-1', kind: 'risk_note' })).status).toBe(500);
    nothingProduced();
  });

  it.each(['client_debit_note', 'insurer_debit_note', 'renewal_notice'])('does not read risks for a %s', async (kind) => {
    script();
    await run({ policy_id: 'pol-1', kind });
    expect(fake.callsTo('ins_policy_risks.select')).toHaveLength(0);
  });
});

describe('generate-ins-doc: storage and registration', () => {
  it("uploads the PDF to the private bucket in the policy's tenant folder", async () => {
    script();
    await run({ policy_id: 'pol-1', kind: 'risk_note' });
    const upload = fake.storageCalls[0];
    expect(upload.bucket).toBe('tenant-documents');
    expect(upload.op).toBe('upload');
    expect(upload.args[0]).toMatch(new RegExp(`^${TENANT}/insurance/insurance_policy/pol-1/POL-0001-risk_note-\\d{14}\\.pdf$`));
    expect(upload.args[1]).toBe(fake.pdfBytes);
    expect(upload.args[2]).toEqual({ contentType: 'application/pdf', upsert: true });
  });

  it("registers the document as the caller, with the file's real hash and size and the template version", async () => {
    script();
    await run({ policy_id: 'pol-1', kind: 'client_debit_note' });
    const path = fake.storageCalls[0].args[0] as string;
    const reg = fake.callsTo('documents_register.rpc')[0];
    expect(reg.client).toBe('anon');
    expect(reg.authorization).toBe('Bearer test-token');
    expect(reg.payload).toEqual({
      p_entity_type: 'insurance_policy',
      p_entity_id: 'pol-1',
      p_bucket: 'tenant-documents',
      p_path: path,
      p_file_name: path.split('/').pop(),
      p_content_hash: createHash('sha256').update(fake.pdfBytes).digest('hex'),
      p_byte_size: fake.pdfBytes.length,
      p_mime_type: 'application/pdf',
      p_doc_kind: 'client_debit_note',
      p_template_code: 'ins_client_debit_note',
      p_template_version: 1,
    });
  });

  it('returns the document id, kind, path and a one-hour signed URL', async () => {
    script();
    const res = await run({ policy_id: 'pol-1', kind: 'renewal_notice' });
    const path = fake.storageCalls[0].args[0] as string;
    expect(await json(res)).toEqual({
      id: 'doc-1',
      kind: 'renewal_notice',
      path,
      signed_url: 'https://signed.test/doc.pdf',
      signed_error: null,
    });
    expect(fake.storageCalls[1].op).toBe('createSignedUrl');
    expect(fake.storageCalls[1].args).toEqual([path, 3600]);
  });

  it('a signing failure still returns the registered document, with the error and no URL', async () => {
    script();
    fake.signedResult = { data: null, error: { message: 'sign failed' } };
    const res = await run();
    expect(res.status).toBe(200);
    expect(await json(res)).toMatchObject({ id: 'doc-1', signed_url: null, signed_error: 'sign failed' });
  });

  it('500 when the upload fails, and nothing is registered', async () => {
    script();
    fake.uploadResult = { error: { message: 'bucket missing' } };
    expect((await run()).status).toBe(500);
    expect(fake.callsTo('documents_register.rpc')).toHaveLength(0);
  });

  it.each([
    ['an error', { error: { message: 'tenant folder mismatch' } }],
    ['no row', { data: null }],
  ])('when the registry refuses the row (%s), the uploaded file is removed so storage and registry cannot drift', async (_l, result) => {
    script();
    fake.on('documents_register.rpc', result);
    const res = await run();
    expect(res.status).toBe(500);
    const path = fake.storageCalls[0].args[0] as string;
    const removal = fake.storageCalls.find((c) => c.op === 'remove')!;
    expect(removal.bucket).toBe('tenant-documents');
    expect(removal.args).toEqual([[path]]);
    expect(fake.storageCalls.some((c) => c.op === 'createSignedUrl')).toBe(false);
  });
});

describe('generate-ins-doc: known gaps (flip to plain `it` when fixed)', () => {
  // A malformed body currently surfaces as a 500 with the JSON parser's message
  // because req.json() is not guarded. A client error should be a 400.
  it.fails('400 for a malformed JSON body', async () => {
    script();
    expect((await run(undefined, { rawBody: '{not json' })).status).toBe(400);
  });

  // The policy lookup runs before authorisation, so a caller with no insurance
  // access can tell which policy ids exist (404 vs 403). Authorise first.
  it.fails('does not reveal whether a policy exists to a caller without insurance access', async () => {
    script();
    fake.on('can_access_insurance.rpc', { data: false });
    fake.on('ins_policies.select', { data: null });
    expect((await run()).status).toBe(403);
  });

  // policy_no is free text (imported numbers often look like UAP/MV/2026/001) and
  // goes straight into the storage path, so a slash adds folders under the policy
  // and the registered file name loses everything before the last slash. The file
  // should always sit directly in the policy folder with a name that keeps the
  // whole policy number.
  it.fails('keeps the document directly in the policy folder when the policy number contains slashes', async () => {
    script({ policy_no: 'UAP/MV/2026/001' });
    await run();
    const path = fake.storageCalls[0].args[0] as string;
    expect(path.split('/')).toHaveLength(5);
    expect(fake.callsTo('documents_register.rpc')[0].payload).toMatchObject({
      p_file_name: expect.stringContaining('UAP'),
    });
  });
});
