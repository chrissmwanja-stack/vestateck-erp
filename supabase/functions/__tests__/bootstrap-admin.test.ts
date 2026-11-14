import { beforeEach, describe, expect, it } from 'vitest';
import { FakeSupabase, json, loadHandler, req } from './harness';

const CODE = 'correct-horse';
const PLATFORM_TENANT_ID = '00000000-0000-0000-0000-000000000099';
const OK_BODY = { name: ' Chris ', code: CODE };

let fake: FakeSupabase;
const load = (env: Record<string, string | undefined> = { BOOTSTRAP_ADMIN_CODE: CODE }) =>
  loadHandler('bootstrap-admin', fake, env);

beforeEach(() => {
  fake = new FakeSupabase();
});

describe('bootstrap-admin: gates', () => {
  it('answers CORS preflight without authenticating', async () => {
    const res = await (await load())(req(undefined, { method: 'OPTIONS', auth: null }));
    expect(res.status).toBe(200);
    expect(fake.calls).toHaveLength(0);
  });

  it('fails closed (503) when BOOTSTRAP_ADMIN_CODE is not configured, before touching auth or data', async () => {
    const res = await (await load({}))(req(OK_BODY));
    expect(res.status).toBe(503);
    expect(fake.calls).toHaveLength(0);
  });

  it('401 without an Authorization header', async () => {
    const res = await (await load())(req(OK_BODY, { auth: null }));
    expect(res.status).toBe(401);
  });

  it('401 when the session is invalid', async () => {
    fake.userResult = { data: { user: null }, error: { message: 'jwt expired' } };
    const res = await (await load())(req(OK_BODY));
    expect(res.status).toBe(401);
  });

  it('400 when the authenticated user has no email', async () => {
    fake.userResult = { data: { user: { id: 'u1', email: null } }, error: null };
    const res = await (await load())(req(OK_BODY));
    expect(res.status).toBe(400);
  });

  it.each([
    ['wrong code', { name: 'Chris', code: 'nope' }],
    ['missing code', { name: 'Chris' }],
    ['non-string code', { name: 'Chris', code: 12345 }],
  ])('403 on %s, without querying the database (cannot be used to probe whether an admin exists)', async (_l, body) => {
    const res = await (await load())(req(body));
    expect(res.status).toBe(403);
    expect(fake.calls).toHaveLength(0);
  });

  it('403 on an unparseable body rather than a crash', async () => {
    const res = await (await load())(req(undefined, { rawBody: '{not json' }));
    expect(res.status).toBe(403);
  });

  it.each([[''], ['   '], [undefined], [42]])('400 when name is %j', async (name) => {
    const res = await (await load())(req({ name, code: CODE }));
    expect(res.status).toBe(400);
    expect(fake.calls).toHaveLength(0);
  });
});

describe('bootstrap-admin: claim', () => {
  it('409 and no writes once a platform admin already exists', async () => {
    fake.on('app_users.select', { count: 1 });
    const res = await (await load())(req(OK_BODY));
    expect(res.status).toBe(409);
    expect(fake.callsTo('app_users.insert')).toHaveLength(0);
    expect(fake.callsTo('app_users.update')).toHaveLength(0);
  });

  it('500 when the admin count cannot be read (does not fall through to a claim)', async () => {
    fake.on('app_users.select', { error: { message: 'db down' } });
    const res = await (await load())(req(OK_BODY));
    expect(res.status).toBe(500);
    expect(fake.callsTo('app_users.insert')).toHaveLength(0);
  });

  it('creates the first admin in the reserved platform tenant with a trimmed name', async () => {
    fake.on('app_users.select', { count: 0 }, { data: null });
    fake.on('app_users.insert', {});
    fake.userResult = { data: { user: { id: 'u-first', email: 'first@example.com' } }, error: null };
    const res = await (await load())(req(OK_BODY));
    expect(res.status).toBe(200);
    expect(fake.callsTo('app_users.insert')[0].payload).toEqual({
      id: 'u-first',
      tenant_id: PLATFORM_TENANT_ID,
      email: 'first@example.com',
      name: 'Chris',
      is_platform_admin: true,
    });
    // Writes use the service role, never the caller's own client.
    expect(fake.callsTo('app_users.insert')[0].client).toBe('service');
  });

  it('promotes an existing app_users row instead of inserting a duplicate (retried call)', async () => {
    fake.on('app_users.select', { count: 0 }, { data: { id: 'user-1' } });
    fake.on('app_users.update', {});
    const res = await (await load())(req(OK_BODY));
    expect(res.status).toBe(200);
    expect(fake.callsTo('app_users.insert')).toHaveLength(0);
    const upd = fake.callsTo('app_users.update')[0];
    expect(upd.payload).toEqual({ is_platform_admin: true });
    expect(fake.filtersOf(upd, 'eq')).toContainEqual(['id', 'user-1']);
  });

  it('409 when the single-platform-admin index rejects the promotion (lost the race)', async () => {
    fake.on('app_users.select', { count: 0 }, { data: { id: 'user-1' } });
    fake.on('app_users.update', { error: { message: 'dup', code: '23505' } });
    expect((await (await load())(req(OK_BODY))).status).toBe(409);
  });

  it('500 on any other promotion error', async () => {
    fake.on('app_users.select', { count: 0 }, { data: { id: 'user-1' } });
    fake.on('app_users.update', { error: { message: 'boom' } });
    expect((await (await load())(req(OK_BODY))).status).toBe(500);
  });

  it('409 when the insert loses the race on the single-admin index', async () => {
    fake.on('app_users.select', { count: 0 }, { data: null });
    fake.on('app_users.insert', {
      error: { message: 'duplicate key value violates unique constraint "app_users_single_platform_admin"', code: '23505' },
    });
    expect((await (await load())(req(OK_BODY))).status).toBe(409);
  });

  it('treats a primary-key collision on insert as an already-completed claim', async () => {
    fake.on('app_users.select', { count: 0 }, { data: null });
    fake.on('app_users.insert', {
      error: { message: 'duplicate key value violates unique constraint "app_users_pkey"', code: '23505' },
    });
    const res = await (await load())(req(OK_BODY));
    expect(res.status).toBe(200);
    expect((await json(res)).message).toBe('Platform admin claimed');
  });

  it('500 on a non-unique insert error', async () => {
    fake.on('app_users.select', { count: 0 }, { data: null });
    fake.on('app_users.insert', { error: { message: 'boom' } });
    expect((await (await load())(req(OK_BODY))).status).toBe(500);
  });
});
