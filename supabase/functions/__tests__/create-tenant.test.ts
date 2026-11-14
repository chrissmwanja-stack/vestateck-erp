import { beforeEach, describe, expect, it } from 'vitest';
import { FakeSupabase, json, loadHandler, req } from './harness';

let fake: FakeSupabase;
const run = async (body: unknown = { name: 'Acme Ltd' }, opts?: Parameters<typeof req>[1]) =>
  (await loadHandler('create-tenant', fake))(req(body, opts));

/** Caller is a platform admin; template 'general' exists and is the default; no duplicate; insert + seed succeed. */
function scriptHappyPath() {
  fake.on('app_users.select', { data: { is_platform_admin: true } });
  fake.on('industry_templates.select', { data: { key: 'general' } });
  fake.on('tenants.select', { data: null });
  fake.on('tenants.insert', { data: { id: 't-new', name: 'Acme Ltd', status: 'pending' } });
  fake.on('seed_tenant_defaults.rpc', {});
}

beforeEach(() => {
  fake = new FakeSupabase();
  fake.userResult = { data: { user: { id: 'admin-1', email: 'admin@example.com' } }, error: null };
});

describe('create-tenant: access', () => {
  it('401 without an Authorization header', async () => {
    expect((await run({ name: 'x' }, { auth: null })).status).toBe(401);
    expect(fake.calls).toHaveLength(0);
  });

  it('401 when the session is invalid', async () => {
    fake.userResult = { data: { user: null }, error: { message: 'expired' } };
    expect((await run()).status).toBe(401);
  });

  it.each([[{}], [{ name: '' }], [{ name: '   ' }]])('400 when name is missing or blank (%j)', async (body) => {
    expect((await run(body)).status).toBe(400);
    expect(fake.callsTo('tenants.insert')).toHaveLength(0);
  });

  it.each([
    ['a regular user', { data: { is_platform_admin: false } }],
    ['a caller with no app_users row', { data: null }],
  ])('403 for %s, with no tenant created and nothing seeded', async (_l, row) => {
    fake.on('app_users.select', row);
    fake.on('industry_templates.select', { data: { key: 'general' } });
    const res = await run();
    expect(res.status).toBe(403);
    expect(fake.callsTo('tenants.insert')).toHaveLength(0);
    expect(fake.callsTo('seed_tenant_defaults.rpc')).toHaveLength(0);
  });

  it('checks platform-admin status for the authenticated caller, not anyone named in the body', async () => {
    scriptHappyPath();
    await run({ name: 'Acme Ltd', created_by: 'someone-else', user_id: 'someone-else' });
    const lookup = fake.callsTo('app_users.select')[0];
    expect(fake.filtersOf(lookup, 'eq')).toContainEqual(['id', 'admin-1']);
    expect((fake.callsTo('tenants.insert')[0].payload as { created_by: string }).created_by).toBe('admin-1');
  });

  it('500 when the caller lookup fails (does not fall through to creating)', async () => {
    fake.on('app_users.select', { error: { message: 'boom' } });
    fake.on('industry_templates.select', { data: { key: 'general' } });
    expect((await run()).status).toBe(500);
    expect(fake.callsTo('tenants.insert')).toHaveLength(0);
  });
});

describe('create-tenant: template', () => {
  it('uses the registry default when none is given', async () => {
    scriptHappyPath();
    fake.on('industry_templates.select', (c) => {
      const eqs = fake.filtersOf(c, 'eq');
      if (eqs.some((f) => f[0] === 'is_default')) return { data: { key: 'construction' } };
      // the later "template exists and is active" check echoes the key it was asked about
      return { data: { key: eqs.find((f) => f[0] === 'key')?.[1] } };
    });
    await run({ name: 'Acme Ltd' });
    expect((fake.callsTo('tenants.insert')[0].payload as { industry_template: string }).industry_template).toBe('construction');
  });

  it("falls back to 'general' when no default is registered", async () => {
    scriptHappyPath();
    fake.on('industry_templates.select', (c) =>
      fake.filtersOf(c, 'eq').some((f) => f[0] === 'is_default') ? { data: null } : { data: { key: 'general' } },
    );
    await run({ name: 'Acme Ltd' });
    expect((fake.callsTo('tenants.insert')[0].payload as { industry_template: string }).industry_template).toBe('general');
  });

  it('400 for an unknown or inactive template and lists the valid keys', async () => {
    scriptHappyPath();
    fake.on('industry_templates.select', (c) =>
      fake.filtersOf(c, 'eq').some((f) => f[0] === 'key') ? { data: null } : { data: [{ key: 'general' }, { key: 'insurance' }] },
    );
    const res = await run({ name: 'Acme Ltd', industry_template: 'nope' });
    expect(res.status).toBe(400);
    expect((await json(res)).error).toContain('general, insurance');
    expect(fake.callsTo('tenants.insert')).toHaveLength(0);
  });
});

describe('create-tenant: creation', () => {
  it('409 with the existing id on a case-insensitive duplicate name', async () => {
    scriptHappyPath();
    fake.on('tenants.select', { data: { id: 't-existing' } });
    const res = await run({ name: 'ACME LTD' });
    expect(res.status).toBe(409);
    expect((await json(res)).tenant_id).toBe('t-existing');
    expect(fake.filtersOf(fake.callsTo('tenants.select')[0], 'ilike')).toContainEqual(['name', 'ACME LTD']);
    expect(fake.callsTo('tenants.insert')).toHaveLength(0);
  });

  it('creates a pending, standard-plan, active-subscription tenant with a trimmed name', async () => {
    scriptHappyPath();
    const res = await run({ name: '  Acme Ltd  ', industry_template: 'general' });
    expect(res.status).toBe(200);
    expect(fake.callsTo('tenants.insert')[0].payload).toEqual({
      name: 'Acme Ltd',
      industry_template: 'general',
      created_by: 'admin-1',
      status: 'pending',
      plan: 'standard',
      subscription_status: 'active',
    });
    expect(fake.callsTo('tenants.insert')[0].client).toBe('service');
    expect((await json(res)).tenant).toEqual({ id: 't-new', name: 'Acme Ltd', status: 'pending' });
  });

  it("seeds defaults through the caller's own JWT (the RPC re-checks auth.uid())", async () => {
    scriptHappyPath();
    await run({ name: 'Acme Ltd', industry_template: 'general' });
    const seed = fake.callsTo('seed_tenant_defaults.rpc')[0];
    expect(seed.client).toBe('anon');
    expect(seed.authorization).toBe('Bearer test-token');
    expect(seed.payload).toEqual({ p_tenant_id: 't-new', p_industry_template: 'general' });
  });

  it('keeps the tenant and returns a seed_warning when seeding fails', async () => {
    scriptHappyPath();
    fake.on('seed_tenant_defaults.rpc', { error: { message: 'seed boom' } });
    const res = await run({ name: 'Acme Ltd', industry_template: 'general' });
    expect(res.status).toBe(200);
    const body = await json(res);
    expect(body.tenant).toBeTruthy();
    expect(body.seed_warning).toContain('seed boom');
  });

  it('500 when the insert fails, and does not seed', async () => {
    scriptHappyPath();
    fake.on('tenants.insert', { error: { message: 'boom' } });
    expect((await run({ name: 'Acme Ltd', industry_template: 'general' })).status).toBe(500);
    expect(fake.callsTo('seed_tenant_defaults.rpc')).toHaveLength(0);
  });
});

describe('create-tenant: known gaps (flip to plain `it` when fixed)', () => {
  // A malformed body currently surfaces as a 500 with the JSON parser's message
  // because req.json() is not guarded. A client error should be a 400.
  it.fails('400 for a malformed JSON body', async () => {
    scriptHappyPath();
    expect((await run(undefined, { rawBody: '{not json' })).status).toBe(400);
  });

  // ilike treats % and _ in the name as wildcards, so "Acme_Ltd" matches
  // "Acme Ltd" as a duplicate. The name should be escaped before matching.
  it.fails('escapes LIKE wildcards in the duplicate-name check', async () => {
    scriptHappyPath();
    await run({ name: '100%_Co', industry_template: 'general' });
    expect(fake.filtersOf(fake.callsTo('tenants.select')[0], 'ilike')).toContainEqual(['name', '100\\%\\_Co']);
  });
});
