import { beforeEach, describe, expect, it } from 'vitest';
import { FakeSupabase, json, loadHandler, req } from './harness';

const TENANT = 'tenant-1';
const OTHER_TENANT = 'tenant-2';
const MODULES = [{ key: 'hr' }, { key: 'procurement' }, { key: 'pmo' }];
const MEMBER_BODY = {
  email: '  New.Person@Example.com ',
  tenant_id: TENANT,
  role_bundle: 'member',
  modules_and_roles: [{ module: 'hr', role: 'member' }],
};

let fake: FakeSupabase;
const run = async (body: unknown, env: Record<string, string | undefined> = {}, opts?: Parameters<typeof req>[1]) =>
  (await loadHandler('invite-user', fake, env))(req(body, opts));

type Caller = { tenant_id: string; is_platform_admin: boolean; is_company_admin: boolean };
const COMPANY_ADMIN: Caller = { tenant_id: TENANT, is_platform_admin: false, is_company_admin: true };
const MODULE_ADMIN: Caller = { tenant_id: TENANT, is_platform_admin: false, is_company_admin: false };
const PLATFORM_ADMIN: Caller = { tenant_id: '00000000-0000-0000-0000-000000000099', is_platform_admin: true, is_company_admin: false };

function script(caller: Caller | null, over: { tenant?: unknown; impersonating?: string | null } = {}) {
  fake.on('platform_modules.select', { data: MODULES });
  fake.on('app_users.select', { data: caller });
  fake.on('impersonation_sessions.select', { data: over.impersonating ? { tenant_id: over.impersonating } : null });
  fake.on('tenants.select', { data: 'tenant' in over ? over.tenant : { id: TENANT, status: 'active' } });
  fake.on('invitations.insert', { data: { id: 'inv-1' } });
  fake.on('invitations.delete', {});
}

beforeEach(() => {
  fake = new FakeSupabase();
  fake.userResult = { data: { user: { id: 'caller-1', email: 'caller@example.com' } }, error: null };
});

describe('invite-user: request validation', () => {
  it('401 without an Authorization header', async () => {
    expect((await run(MEMBER_BODY, {}, { auth: null })).status).toBe(401);
    expect(fake.calls).toHaveLength(0);
  });

  it('401 when the session is invalid', async () => {
    fake.userResult = { data: { user: null }, error: { message: 'expired' } };
    expect((await run(MEMBER_BODY)).status).toBe(401);
  });

  it.each([
    ['email', { ...MEMBER_BODY, email: '' }],
    ['tenant_id', { ...MEMBER_BODY, tenant_id: undefined }],
    ['role_bundle', { ...MEMBER_BODY, role_bundle: undefined }],
  ])('400 when %s is missing', async (_f, body) => {
    expect((await run(body)).status).toBe(400);
  });

  it('400 for an unknown role_bundle', async () => {
    expect((await run({ ...MEMBER_BODY, role_bundle: 'owner' })).status).toBe(400);
  });

  it('400 for an unknown finance_role', async () => {
    script(COMPANY_ADMIN);
    expect((await run({ ...MEMBER_BODY, finance_role: 'cfo' })).status).toBe(400);
    expect(fake.callsTo('invitations.insert')).toHaveLength(0);
  });

  it('400 for a member invite with neither modules nor a finance role', async () => {
    script(COMPANY_ADMIN);
    expect((await run({ ...MEMBER_BODY, modules_and_roles: [] })).status).toBe(400);
    expect((await run({ ...MEMBER_BODY, modules_and_roles: undefined })).status).toBe(400);
  });

  it.each([
    ['a module that is not in the registry', [{ module: 'finance-admin', role: 'member' }]],
    ['a role outside admin/manager/member', [{ module: 'hr', role: 'owner' }]],
    ['one bad pair among good ones', [{ module: 'hr', role: 'member' }, { module: 'nope', role: 'member' }]],
    ['a non-array', 'hr'],
  ])('400 for %s', async (_l, modules_and_roles) => {
    script(COMPANY_ADMIN);
    const res = await run({ ...MEMBER_BODY, modules_and_roles });
    expect(res.status).toBe(400);
    expect(fake.callsTo('invitations.insert')).toHaveLength(0);
  });

  it('500 when the module registry cannot be read', async () => {
    script(COMPANY_ADMIN);
    fake.on('platform_modules.select', { error: { message: 'boom' } });
    expect((await run(MEMBER_BODY)).status).toBe(500);
  });

  it('reads only active, tenant-entitled modules from the registry', async () => {
    script(COMPANY_ADMIN);
    await run(MEMBER_BODY);
    const eqs = fake.filtersOf(fake.callsTo('platform_modules.select')[0], 'eq');
    expect(eqs).toEqual(expect.arrayContaining([['is_active', true], ['tenant_entitled', true]]));
  });
});

describe('invite-user: who may invite whom', () => {
  it('403 when the caller has no app_users record', async () => {
    script(null);
    expect((await run(MEMBER_BODY)).status).toBe(403);
    expect(fake.callsTo('invitations.insert')).toHaveLength(0);
  });

  it('only a platform admin may invite a company admin', async () => {
    script(COMPANY_ADMIN);
    const res = await run({ email: 'a@b.co', tenant_id: TENANT, role_bundle: 'company_admin' });
    expect(res.status).toBe(403);
    expect(fake.callsTo('invitations.insert')).toHaveLength(0);
  });

  it('a platform admin can invite a company admin into any tenant; no modules or finance role are stored', async () => {
    script(PLATFORM_ADMIN, { tenant: { id: OTHER_TENANT, status: 'pending' } });
    const res = await run({
      email: 'a@b.co',
      tenant_id: OTHER_TENANT,
      role_bundle: 'company_admin',
      modules_and_roles: [{ module: 'hr', role: 'member' }],
      finance_role: 'finance',
    });
    expect(res.status).toBe(200);
    expect(fake.callsTo('invitations.insert')[0].payload).toMatchObject({
      tenant_id: OTHER_TENANT,
      role_bundle: 'company_admin',
      modules_and_roles: null,
      finance_role: null,
    });
  });

  it("a company admin can invite members into their own tenant", async () => {
    script(COMPANY_ADMIN);
    expect((await run(MEMBER_BODY)).status).toBe(200);
  });

  it('a module admin who is not the company admin cannot invite members', async () => {
    script(MODULE_ADMIN);
    const res = await run(MEMBER_BODY);
    expect(res.status).toBe(403);
    expect(fake.callsTo('invitations.insert')).toHaveLength(0);
  });

  it("a company admin cannot invite into another company's tenant", async () => {
    script(COMPANY_ADMIN, { tenant: { id: OTHER_TENANT, status: 'active' } });
    const res = await run({ ...MEMBER_BODY, tenant_id: OTHER_TENANT });
    expect(res.status).toBe(403);
    expect(fake.callsTo('invitations.insert')).toHaveLength(0);
  });

  it('a platform admin must be viewing the tenant they invite into (no impersonation = refused)', async () => {
    script(PLATFORM_ADMIN);
    const res = await run(MEMBER_BODY);
    expect(res.status).toBe(403);
    expect(fake.callsTo('invitations.insert')).toHaveLength(0);
  });

  it('a platform admin impersonating the tenant may invite members into it', async () => {
    script(PLATFORM_ADMIN, { impersonating: TENANT });
    expect((await run(MEMBER_BODY)).status).toBe(200);
  });

  it('impersonation of a different tenant does not authorise inviting into this one', async () => {
    script(PLATFORM_ADMIN, { impersonating: OTHER_TENANT });
    expect((await run(MEMBER_BODY)).status).toBe(403);
  });

  it('only counts the caller\'s own, still-open, recent (2h) impersonation session', async () => {
    script(PLATFORM_ADMIN, { impersonating: TENANT });
    const before = Date.now();
    await run(MEMBER_BODY);
    const call = fake.callsTo('impersonation_sessions.select')[0];
    expect(fake.filtersOf(call, 'eq')).toContainEqual(['platform_admin_id', 'caller-1']);
    expect(fake.filtersOf(call, 'is')).toContainEqual(['ended_at', null]);
    const [col, cutoff] = fake.filtersOf(call, 'gt')[0] as [string, string];
    expect(col).toBe('started_at');
    const ageMs = before - new Date(cutoff).getTime();
    expect(ageMs).toBeGreaterThanOrEqual(2 * 60 * 60 * 1000 - 5000);
    expect(ageMs).toBeLessThanOrEqual(2 * 60 * 60 * 1000 + 5000);
  });

  it('does not look up impersonation for a non-platform-admin', async () => {
    script(COMPANY_ADMIN);
    await run(MEMBER_BODY);
    expect(fake.callsTo('impersonation_sessions.select')).toHaveLength(0);
  });

  it('the caller identity comes from the session, not the body', async () => {
    script(COMPANY_ADMIN);
    await run({ ...MEMBER_BODY, invited_by: 'someone-else', callerId: 'someone-else' });
    expect(fake.filtersOf(fake.callsTo('app_users.select')[0], 'eq')).toContainEqual(['id', 'caller-1']);
    expect((fake.callsTo('invitations.insert')[0].payload as { invited_by: string }).invited_by).toBe('caller-1');
  });
});

describe('invite-user: target tenant', () => {
  it('404 when the tenant does not exist', async () => {
    script(COMPANY_ADMIN, { tenant: null });
    expect((await run(MEMBER_BODY)).status).toBe(404);
    expect(fake.callsTo('invitations.insert')).toHaveLength(0);
  });

  it('400 when the tenant is suspended', async () => {
    script(COMPANY_ADMIN, { tenant: { id: TENANT, status: 'suspended' } });
    expect((await run(MEMBER_BODY)).status).toBe(400);
    expect(fake.callsTo('invitations.insert')).toHaveLength(0);
  });

  it('allows a pending tenant (first admin is invited before it is active)', async () => {
    script(PLATFORM_ADMIN, { tenant: { id: OTHER_TENANT, status: 'pending' } });
    const res = await run({ email: 'a@b.co', tenant_id: OTHER_TENANT, role_bundle: 'company_admin' });
    expect(res.status).toBe(200);
  });
});

describe('invite-user: creating the invitation', () => {
  it('stores a lower-cased, trimmed email, the validated module roles and status pending', async () => {
    script(COMPANY_ADMIN);
    await run(MEMBER_BODY);
    expect(fake.callsTo('invitations.insert')[0].payload).toEqual({
      tenant_id: TENANT,
      email: 'new.person@example.com',
      invited_by: 'caller-1',
      role_bundle: 'member',
      modules_and_roles: [{ module: 'hr', role: 'member' }],
      finance_role: null,
      status: 'pending',
    });
    expect(fake.callsTo('invitations.insert')[0].client).toBe('service');
  });

  it('accepts a finance-only member invite and stores an empty module list', async () => {
    script(COMPANY_ADMIN);
    const res = await run({ ...MEMBER_BODY, modules_and_roles: undefined, finance_role: 'cost_control' });
    expect(res.status).toBe(200);
    expect(fake.callsTo('invitations.insert')[0].payload).toMatchObject({
      modules_and_roles: [],
      finance_role: 'cost_control',
    });
  });

  it('409 for a duplicate pending invitation, without sending an auth invite', async () => {
    script(COMPANY_ADMIN);
    fake.on('invitations.insert', { error: { message: 'dup', code: '23505' } });
    expect((await run(MEMBER_BODY)).status).toBe(409);
    expect(fake.inviteArgs).toHaveLength(0);
  });

  it('500 on any other insert error, without sending an auth invite', async () => {
    script(COMPANY_ADMIN);
    fake.on('invitations.insert', { error: { message: 'boom' } });
    expect((await run(MEMBER_BODY)).status).toBe(500);
    expect(fake.inviteArgs).toHaveLength(0);
  });
});

describe('invite-user: sending the auth invite', () => {
  it('invites the address, carrying the invitation and tenant ids and the configured redirect', async () => {
    script(COMPANY_ADMIN);
    const res = await run(MEMBER_BODY, { ACCEPT_INVITE_URL: 'https://app.example.com/accept-invite' });
    expect(res.status).toBe(200);
    expect(fake.inviteArgs[0].options).toEqual({
      redirectTo: 'https://app.example.com/accept-invite',
      data: { invitation_id: 'inv-1', tenant_id: TENANT },
    });
    expect(await json(res)).toMatchObject({
      invitation_id: 'inv-1',
      auth_user_id: 'auth-user-1',
      tenant_id: TENANT,
      role_bundle: 'member',
    });
  });

  it('omits redirectTo when ACCEPT_INVITE_URL is not set', async () => {
    script(COMPANY_ADMIN);
    await run(MEMBER_BODY);
    expect((fake.inviteArgs[0].options as { redirectTo?: string }).redirectTo).toBeUndefined();
  });

  it.each([
    ['code email_exists', { message: 'exists', code: 'email_exists' }],
    ['HTTP status 422', { message: 'exists', status: 422 }],
  ])('409 email_exists on %s, and the invitation row is rolled back', async (_l, err) => {
    script(COMPANY_ADMIN);
    fake.inviteResult = { data: { user: null }, error: err };
    const res = await run(MEMBER_BODY);
    expect(res.status).toBe(409);
    expect((await json(res)).code).toBe('email_exists');
    const del = fake.callsTo('invitations.delete')[0];
    expect(fake.filtersOf(del, 'eq')).toContainEqual(['id', 'inv-1']);
  });

  it('500 on another auth error, and still rolls back the invitation so a retry is possible', async () => {
    script(COMPANY_ADMIN);
    fake.inviteResult = { data: { user: null }, error: { message: 'smtp down', status: 500 } };
    const res = await run(MEMBER_BODY);
    expect(res.status).toBe(500);
    expect(fake.callsTo('invitations.delete')).toHaveLength(1);
  });
});

describe('invite-user: known gaps (flip to plain `it` when fixed)', () => {
  // A malformed body currently surfaces as a 500 with the JSON parser's message
  // because req.json() is not guarded. A client error should be a 400.
  it.fails('400 for a malformed JSON body', async () => {
    script(COMPANY_ADMIN);
    expect((await run(undefined, {}, { rawBody: '{not json' })).status).toBe(400);
  });

  // Auth invite uses the raw email while the invitation row and accept-invite
  // use the trimmed, lower-cased one. Both sides should see the same address.
  it.fails('sends the auth invite to the same normalised address it stored', async () => {
    script(COMPANY_ADMIN);
    await run(MEMBER_BODY);
    expect(fake.inviteArgs[0].email).toBe('new.person@example.com');
  });
});
