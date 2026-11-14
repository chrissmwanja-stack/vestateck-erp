import { beforeEach, describe, expect, it } from 'vitest';
import { FakeSupabase, json, loadHandler, req } from './harness';

const TENANT = 'tenant-1';

let fake: FakeSupabase;
const run = async (body: unknown = {}, opts?: Parameters<typeof req>[1]) =>
  (await loadHandler('accept-invite', fake))(req(body, opts));

const pendingInvite = (over: Record<string, unknown> = {}) => ({
  id: 'inv-1',
  tenant_id: TENANT,
  role_bundle: 'member',
  modules_and_roles: [{ module: 'hr', role: 'manager' }],
  finance_role: null,
  status: 'pending',
  ...over,
});

/** Script the happy-path writes; tests override what they care about. */
function scriptAccept(invite: Record<string, unknown>, opts: { accepted?: number } = {}) {
  fake.on('invitations.select', (c) =>
    // the pending-invitation lookup vs. the accepted-count query
    fake.filtersOf(c, 'select').some((f) => (f[1] as { head?: boolean } | undefined)?.head)
      ? { count: opts.accepted ?? 2 }
      : { data: invite },
  );
  fake.on('app_users.insert', {});
  fake.on('staff_roles.insert', {});
  fake.on('finance_team_members.insert', {});
  fake.on('invitations.update', {});
  fake.on('tenants.update', {});
}

beforeEach(() => {
  fake = new FakeSupabase();
  fake.userResult = { data: { user: { id: 'u-new', email: '  New.User@Example.com ' } }, error: null };
});

describe('accept-invite: authentication', () => {
  it('401 without an Authorization header', async () => {
    expect((await run({}, { auth: null })).status).toBe(401);
    expect(fake.calls).toHaveLength(0);
  });

  it('401 when the session is invalid or expired', async () => {
    fake.userResult = { data: { user: null }, error: { message: 'expired' } };
    expect((await run()).status).toBe(401);
    expect(fake.calls).toHaveLength(0);
  });

  it('400 when the authenticated user has no email', async () => {
    fake.userResult = { data: { user: { id: 'u1', email: null } }, error: null };
    expect((await run()).status).toBe(400);
  });

  it('answers CORS preflight without authenticating', async () => {
    const res = await (await loadHandler('accept-invite', fake))(req(undefined, { method: 'OPTIONS', auth: null }));
    expect(res.status).toBe(200);
    expect(fake.calls).toHaveLength(0);
  });
});

describe('accept-invite: finding the invitation', () => {
  it('matches on the session email (trimmed, lower-cased) and pending status, never on a client-supplied id', async () => {
    scriptAccept(pendingInvite());
    await run({ invitation_id: 'someone-elses-invite', tenant_id: 'other-tenant' });
    const lookup = fake.callsTo('invitations.select')[0];
    const eqs = fake.filtersOf(lookup, 'eq');
    expect(eqs).toContainEqual(['email', 'new.user@example.com']);
    expect(eqs).toContainEqual(['status', 'pending']);
    expect(eqs.map((e) => e[0])).not.toContain('id');
    expect(lookup.client).toBe('service');
  });

  it('lands the user in the invitation tenant, not one named in the body', async () => {
    scriptAccept(pendingInvite());
    await run({ tenant_id: 'attacker-tenant' });
    expect((fake.callsTo('app_users.insert')[0].payload as { tenant_id: string }).tenant_id).toBe(TENANT);
  });

  it('is idempotent: no pending invite but an existing app_users row returns 200 and writes nothing', async () => {
    fake.on('invitations.select', { data: null });
    fake.on('app_users.select', { data: { id: 'u-new', tenant_id: TENANT } });
    const res = await run();
    expect(res.status).toBe(200);
    expect((await json(res)).message).toBe('Invitation already accepted');
    for (const k of ['app_users.insert', 'staff_roles.insert', 'invitations.update']) {
      expect(fake.callsTo(k)).toHaveLength(0);
    }
  });

  it('404 when there is neither a pending invite nor an existing user', async () => {
    fake.on('invitations.select', { data: null });
    fake.on('app_users.select', { data: null });
    expect((await run()).status).toBe(404);
  });

  it('500 when the invitation lookup fails', async () => {
    fake.on('invitations.select', { error: { message: 'db down' } });
    expect((await run()).status).toBe(500);
    expect(fake.callsTo('app_users.insert')).toHaveLength(0);
  });
});

describe('accept-invite: member invitation', () => {
  it('creates the user as a non-company-admin with exactly the invited module roles', async () => {
    scriptAccept(pendingInvite({ modules_and_roles: [{ module: 'hr', role: 'manager' }, { module: 'pmo', role: 'member' }] }));
    const res = await run();
    expect(res.status).toBe(200);
    expect(fake.callsTo('app_users.insert')[0].payload).toMatchObject({
      id: 'u-new',
      tenant_id: TENANT,
      email: '  New.User@Example.com ',
      is_company_admin: false,
    });
    expect(fake.callsTo('staff_roles.insert')[0].payload).toEqual([
      { tenant_id: TENANT, user_id: 'u-new', module: 'hr', role: 'manager' },
      { tenant_id: TENANT, user_id: 'u-new', module: 'pmo', role: 'member' },
    ]);
    expect(fake.callsTo('tenant_modules.select')).toHaveLength(0);
    expect((await json(res)).modules_granted).toEqual(['hr', 'pmo']);
  });

  it('adds a finance team row only when the inviter granted a finance role', async () => {
    scriptAccept(pendingInvite({ finance_role: 'cost_control' }));
    const res = await run();
    expect(fake.callsTo('finance_team_members.insert')[0].payload).toEqual({
      tenant_id: TENANT,
      user_id: 'u-new',
      role: 'cost_control',
    });
    expect((await json(res)).finance_role_granted).toBe('cost_control');
  });

  it('adds no finance row when none was granted', async () => {
    scriptAccept(pendingInvite({ finance_role: null }));
    await run();
    expect(fake.callsTo('finance_team_members.insert')).toHaveLength(0);
  });

  it('skips the staff_roles insert for a finance-only invite (no modules)', async () => {
    scriptAccept(pendingInvite({ modules_and_roles: [], finance_role: 'finance' }));
    expect((await run()).status).toBe(200);
    expect(fake.callsTo('staff_roles.insert')).toHaveLength(0);
    expect(fake.callsTo('finance_team_members.insert')).toHaveLength(1);
  });
});

describe('accept-invite: company admin invitation', () => {
  it('flags the user as company admin, grants admin on every entitled module, and full finance', async () => {
    scriptAccept(pendingInvite({ role_bundle: 'company_admin', modules_and_roles: null }));
    fake.on('tenant_modules.select', { data: [{ module: 'hr' }, { module: 'procurement' }, { module: 'insurance' }] });
    const res = await run();
    expect(res.status).toBe(200);
    expect(fake.callsTo('app_users.insert')[0].payload).toMatchObject({ is_company_admin: true });
    expect(fake.callsTo('staff_roles.insert')[0].payload).toEqual(
      ['hr', 'procurement', 'insurance'].map((module) => ({ tenant_id: TENANT, user_id: 'u-new', module, role: 'admin' })),
    );
    expect(fake.filtersOf(fake.callsTo('tenant_modules.select')[0], 'eq')).toContainEqual(['tenant_id', TENANT]);
    expect(fake.callsTo('finance_team_members.insert')[0].payload).toMatchObject({ role: 'finance' });
  });

  it('ignores a stored modules_and_roles on a company_admin invite (entitlements decide)', async () => {
    scriptAccept(pendingInvite({ role_bundle: 'company_admin', modules_and_roles: [{ module: 'law', role: 'member' }] }));
    fake.on('tenant_modules.select', { data: [{ module: 'hr' }] });
    await run();
    expect(fake.callsTo('staff_roles.insert')[0].payload).toEqual([
      { tenant_id: TENANT, user_id: 'u-new', module: 'hr', role: 'admin' },
    ]);
  });

  it('500 when entitlements cannot be read, before granting anything', async () => {
    scriptAccept(pendingInvite({ role_bundle: 'company_admin' }));
    fake.on('tenant_modules.select', { error: { message: 'boom' } });
    expect((await run()).status).toBe(500);
    expect(fake.callsTo('staff_roles.insert')).toHaveLength(0);
    expect(fake.callsTo('invitations.update')).toHaveLength(0);
  });
});

describe('accept-invite: retries and failures', () => {
  it('tolerates unique violations on app_users, staff_roles and finance rows (retried call)', async () => {
    scriptAccept(pendingInvite({ finance_role: 'finance' }));
    const dup = { error: { message: 'dup', code: '23505' } };
    fake.on('app_users.insert', dup);
    fake.on('staff_roles.insert', dup);
    fake.on('finance_team_members.insert', dup);
    expect((await run()).status).toBe(200);
    expect(fake.callsTo('invitations.update')).toHaveLength(1);
  });

  it('500 on any other app_users error and stops there', async () => {
    scriptAccept(pendingInvite());
    fake.on('app_users.insert', { error: { message: 'boom' } });
    expect((await run()).status).toBe(500);
    expect(fake.callsTo('staff_roles.insert')).toHaveLength(0);
    expect(fake.callsTo('invitations.update')).toHaveLength(0);
  });

  it('500 on a staff_roles error and leaves the invitation pending so the user can retry', async () => {
    scriptAccept(pendingInvite());
    fake.on('staff_roles.insert', { error: { message: 'boom' } });
    expect((await run()).status).toBe(500);
    expect(fake.callsTo('invitations.update')).toHaveLength(0);
  });

  it('500 on a finance error and leaves the invitation pending', async () => {
    scriptAccept(pendingInvite({ finance_role: 'finance' }));
    fake.on('finance_team_members.insert', { error: { message: 'boom' } });
    expect((await run()).status).toBe(500);
    expect(fake.callsTo('invitations.update')).toHaveLength(0);
  });

  it('marks the invitation accepted by its own id', async () => {
    scriptAccept(pendingInvite());
    await run();
    const upd = fake.callsTo('invitations.update')[0];
    expect(upd.payload).toMatchObject({ status: 'accepted' });
    expect((upd.payload as { accepted_at: string }).accepted_at).toMatch(/^\d{4}-\d{2}-\d{2}T/);
    expect(fake.filtersOf(upd, 'eq')).toContainEqual(['id', 'inv-1']);
  });

  it('500 when the invitation cannot be marked accepted', async () => {
    scriptAccept(pendingInvite());
    fake.on('invitations.update', { error: { message: 'boom' } });
    expect((await run()).status).toBe(500);
  });
});

describe('accept-invite: tenant activation', () => {
  it('activates a pending tenant on its first accepted invitation, only if still pending', async () => {
    scriptAccept(pendingInvite(), { accepted: 1 });
    await run();
    const upd = fake.callsTo('tenants.update')[0];
    expect(upd.payload).toEqual({ status: 'active' });
    expect(fake.filtersOf(upd, 'eq')).toEqual(expect.arrayContaining([['id', TENANT], ['status', 'pending']]));
  });

  it('does not touch the tenant when it already had accepted invitations', async () => {
    scriptAccept(pendingInvite(), { accepted: 2 });
    await run();
    expect(fake.callsTo('tenants.update')).toHaveLength(0);
  });
});
