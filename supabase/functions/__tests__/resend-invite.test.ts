import { beforeEach, describe, expect, it } from 'vitest';
import { FakeSupabase, json, loadHandler, req } from './harness';

const TENANT = 'tenant-1';
const OTHER_TENANT = 'tenant-2';

type Caller = { tenant_id: string; is_platform_admin: boolean; is_company_admin: boolean };
const COMPANY_ADMIN: Caller = { tenant_id: TENANT, is_platform_admin: false, is_company_admin: true };
const MODULE_ADMIN: Caller = { tenant_id: TENANT, is_platform_admin: false, is_company_admin: false };
const PLATFORM_ADMIN: Caller = { tenant_id: '00000000-0000-0000-0000-000000000099', is_platform_admin: true, is_company_admin: false };

const invite = (over: Record<string, unknown> = {}) => ({
  id: 'inv-1',
  tenant_id: TENANT,
  email: 'stored@example.com',
  role_bundle: 'member',
  status: 'pending',
  ...over,
});

let fake: FakeSupabase;
const run = async (body: unknown = { invitation_id: 'inv-1' }, env: Record<string, string | undefined> = {}, opts?: Parameters<typeof req>[1]) =>
  (await loadHandler('resend-invite', fake, env))(req(body, opts));

function script(caller: Caller | null, inv: Record<string, unknown> | null = invite()) {
  fake.on('invitations.select', { data: inv });
  fake.on('app_users.select', { data: caller });
  fake.on('invitations.update', {});
}

beforeEach(() => {
  fake = new FakeSupabase();
  fake.userResult = { data: { user: { id: 'caller-1', email: 'caller@example.com' } }, error: null };
});

describe('resend-invite: request validation', () => {
  it('401 without an Authorization header', async () => {
    expect((await run({ invitation_id: 'x' }, {}, { auth: null })).status).toBe(401);
    expect(fake.calls).toHaveLength(0);
  });

  it('401 when the session is invalid', async () => {
    fake.userResult = { data: { user: null }, error: { message: 'expired' } };
    expect((await run()).status).toBe(401);
  });

  it('400 when invitation_id is missing', async () => {
    expect((await run({})).status).toBe(400);
    expect(fake.calls).toHaveLength(0);
  });

  it('404 when the invitation does not exist', async () => {
    script(COMPANY_ADMIN, null);
    expect((await run()).status).toBe(404);
    expect(fake.inviteArgs).toHaveLength(0);
  });

  it('500 when the invitation lookup fails', async () => {
    fake.on('invitations.select', { error: { message: 'boom' } });
    expect((await run()).status).toBe(500);
  });

  it.each(['accepted', 'revoked', 'cancelled'])('400 for a %s invitation, and nothing is sent', async (status) => {
    script(COMPANY_ADMIN, invite({ status }));
    const res = await run();
    expect(res.status).toBe(400);
    expect((await json(res)).error).toContain(status);
    expect(fake.inviteArgs).toHaveLength(0);
  });

  it.each(['pending', 'expired'])('accepts a %s invitation', async (status) => {
    script(COMPANY_ADMIN, invite({ status }));
    expect((await run()).status).toBe(200);
  });
});

describe('resend-invite: who may resend', () => {
  it('403 when the caller has no app_users record', async () => {
    script(null);
    expect((await run()).status).toBe(403);
    expect(fake.inviteArgs).toHaveLength(0);
  });

  it('a platform admin can resend a member invite in any tenant, with no impersonation needed', async () => {
    script(PLATFORM_ADMIN, invite({ tenant_id: OTHER_TENANT }));
    expect((await run()).status).toBe(200);
    expect(fake.callsTo('impersonation_sessions.select')).toHaveLength(0);
  });

  it('a platform admin can resend a company-admin invite', async () => {
    script(PLATFORM_ADMIN, invite({ role_bundle: 'company_admin' }));
    expect((await run()).status).toBe(200);
  });

  it('a company admin cannot resend a company-admin invite, even in their own tenant', async () => {
    script(COMPANY_ADMIN, invite({ role_bundle: 'company_admin' }));
    expect((await run()).status).toBe(403);
    expect(fake.inviteArgs).toHaveLength(0);
  });

  it('a company admin can resend a member invite in their own tenant', async () => {
    script(COMPANY_ADMIN);
    expect((await run()).status).toBe(200);
  });

  it("a company admin cannot resend an invite belonging to another tenant", async () => {
    script(COMPANY_ADMIN, invite({ tenant_id: OTHER_TENANT }));
    expect((await run()).status).toBe(403);
    expect(fake.inviteArgs).toHaveLength(0);
  });

  it('a module admin who is not the company admin cannot resend', async () => {
    script(MODULE_ADMIN);
    expect((await run()).status).toBe(403);
    expect(fake.inviteArgs).toHaveLength(0);
  });

  it('the caller identity comes from the session, not the body', async () => {
    script(COMPANY_ADMIN);
    await run({ invitation_id: 'inv-1', callerId: 'someone-else', is_platform_admin: true });
    expect(fake.filtersOf(fake.callsTo('app_users.select')[0], 'eq')).toContainEqual(['id', 'caller-1']);
  });
});

describe('resend-invite: resending', () => {
  it('mails the address stored on the invitation, never one supplied in the request', async () => {
    script(COMPANY_ADMIN);
    await run({ invitation_id: 'inv-1', email: 'attacker@example.com' });
    expect(fake.inviteArgs).toHaveLength(1);
    expect(fake.inviteArgs[0].email).toBe('stored@example.com');
  });

  it('looks the invitation up by the requested id', async () => {
    script(COMPANY_ADMIN);
    await run({ invitation_id: 'inv-42' });
    expect(fake.filtersOf(fake.callsTo('invitations.select')[0], 'eq')).toContainEqual(['id', 'inv-42']);
  });

  it('carries the invitation and tenant ids and the configured redirect', async () => {
    script(COMPANY_ADMIN);
    const res = await run({ invitation_id: 'inv-1' }, { ACCEPT_INVITE_URL: 'https://app.example.com/accept-invite' });
    expect(fake.inviteArgs[0].options).toEqual({
      redirectTo: 'https://app.example.com/accept-invite',
      data: { invitation_id: 'inv-1', tenant_id: TENANT },
    });
    expect(await json(res)).toEqual({ invitation_id: 'inv-1', email: 'stored@example.com' });
  });

  it('omits redirectTo when ACCEPT_INVITE_URL is not set', async () => {
    script(COMPANY_ADMIN);
    await run();
    expect((fake.inviteArgs[0].options as { redirectTo?: string }).redirectTo).toBeUndefined();
  });

  it('flips an expired invitation back to pending, by id, after the mail is sent', async () => {
    script(COMPANY_ADMIN, invite({ status: 'expired' }));
    await run();
    const upd = fake.callsTo('invitations.update')[0];
    expect(upd.payload).toEqual({ status: 'pending' });
    expect(fake.filtersOf(upd, 'eq')).toContainEqual(['id', 'inv-1']);
    expect(upd.client).toBe('service');
  });

  it('leaves a pending invitation untouched', async () => {
    script(COMPANY_ADMIN, invite({ status: 'pending' }));
    await run();
    expect(fake.callsTo('invitations.update')).toHaveLength(0);
  });

  it.each([
    ['code email_exists', { message: 'exists', code: 'email_exists' }],
    ['HTTP status 422', { message: 'exists', status: 422 }],
  ])('409 email_exists on %s, and an expired invitation stays expired', async (_l, err) => {
    script(COMPANY_ADMIN, invite({ status: 'expired' }));
    fake.inviteResult = { data: { user: null }, error: err };
    const res = await run();
    expect(res.status).toBe(409);
    expect((await json(res)).code).toBe('email_exists');
    expect(fake.callsTo('invitations.update')).toHaveLength(0);
  });

  it('500 on another auth error, and an expired invitation stays expired', async () => {
    script(COMPANY_ADMIN, invite({ status: 'expired' }));
    fake.inviteResult = { data: { user: null }, error: { message: 'smtp down', status: 500 } };
    expect((await run()).status).toBe(500);
    expect(fake.callsTo('invitations.update')).toHaveLength(0);
  });
});

describe('resend-invite: known gaps (flip to plain `it` when fixed)', () => {
  // A malformed body currently surfaces as a 500 with the JSON parser's message
  // because req.json() is not guarded. A client error should be a 400.
  it.fails('400 for a malformed JSON body', async () => {
    script(COMPANY_ADMIN);
    expect((await run(undefined, {}, { rawBody: '{not json' })).status).toBe(400);
  });

  // The invitation's existence and status are revealed before the caller is
  // authorised, so any signed-in user can probe an invitation id (404 vs 400 vs
  // 403) in any tenant. Authorise first, then report on status.
  it.fails('does not reveal an invitation\'s status to a caller who may not resend it', async () => {
    script(MODULE_ADMIN, invite({ status: 'accepted' }));
    expect((await run()).status).toBe(403);
  });
});
