// Test harness for the Supabase edge functions.
//
// The functions are written for Deno: they import from deno.land / esm.sh,
// read Deno.env at module load and call serve() at the top level. Rather than
// add a second test runner, vitest (project "edge", see vitest.config.ts)
// aliases those two URL imports to ./stubs, and this file supplies:
//   - FakeSupabase: a scriptable stand-in for the supabase-js client that
//     records every query so tests can assert on what was (and was not) done.
//   - loadHandler(): re-imports a function with a given env and returns the
//     request handler it registered.
//
// Unscripted queries do not throw (the functions catch and turn that into a
// 500, which hides the cause); they return an error whose message starts with
// UNSCRIPTED and are listed in fake.unscripted.
import { vi } from 'vitest';

export const ENV = {
  SUPABASE_URL: 'http://supabase.test',
  SUPABASE_ANON_KEY: 'anon-key',
  SUPABASE_SERVICE_ROLE_KEY: 'service-key',
};

export interface DbError {
  message: string;
  code?: string;
  status?: number;
}
export interface Result {
  data?: unknown;
  error?: DbError | null;
  count?: number | null;
}
export interface Call {
  client: 'anon' | 'service';
  authorization?: string;
  table: string;
  op: 'select' | 'insert' | 'update' | 'delete' | 'rpc';
  payload?: unknown;
  filters: Array<[string, ...unknown[]]>;
}
export type Responder = Result | ((call: Call) => Result);

export class FakeSupabase {
  calls: Call[] = [];
  unscripted: string[] = [];
  userResult: { data: { user: unknown }; error: DbError | null } = {
    data: { user: { id: 'user-1', email: 'user@example.com' } },
    error: null,
  };
  inviteResult: { data: { user?: { id: string } | null }; error: (DbError & { code?: string }) | null } = {
    data: { user: { id: 'auth-user-1' } },
    error: null,
  };
  inviteArgs: Array<{ email: string; options: unknown }> = [];
  private scripts = new Map<string, Responder[]>();

  /** Script the answer for a query, e.g. on('app_users.select', {data: {...}}). Pass several to queue. */
  on(key: string, ...responders: Responder[]): this {
    this.scripts.set(key, responders);
    return this;
  }

  callsTo(key: string): Call[] {
    return this.calls.filter((c) => `${c.table}.${c.op}` === key);
  }

  filtersOf(call: Call, method: string): unknown[][] {
    return call.filters.filter((f) => f[0] === method).map((f) => f.slice(1));
  }

  private resolve(call: Call): Required<Result> {
    const key = `${call.table}.${call.op}`;
    this.calls.push(call);
    const queue = this.scripts.get(key);
    if (!queue || queue.length === 0) {
      this.unscripted.push(key);
      return { data: null, error: { message: `UNSCRIPTED ${key}` }, count: null };
    }
    // The last responder repeats so a single scripted answer serves every call.
    const next = queue.length > 1 ? queue.shift()! : queue[0];
    const r = typeof next === 'function' ? next(call) : next;
    return { data: r.data ?? null, error: r.error ?? null, count: r.count ?? null };
  }

  makeClient(_url: string, key: string, opts?: unknown) {
    const kind: 'anon' | 'service' = key === ENV.SUPABASE_ANON_KEY ? 'anon' : 'service';
    const authorization = (opts as { global?: { headers?: Record<string, string> } } | undefined)?.global
      ?.headers?.Authorization;
    const self = this;

    const from = (table: string) => {
      const call: Call = { client: kind, authorization, table, op: 'select', filters: [] };
      let opSet = false;
      const settle = () => self.resolve(call);
      const b: Record<string, unknown> = {
        select: (...args: unknown[]) => {
          if (!opSet) call.op = 'select';
          call.filters.push(['select', ...args]);
          return b;
        },
        insert: (payload: unknown) => {
          call.op = 'insert';
          opSet = true;
          call.payload = payload;
          return b;
        },
        update: (payload: unknown) => {
          call.op = 'update';
          opSet = true;
          call.payload = payload;
          return b;
        },
        delete: () => {
          call.op = 'delete';
          opSet = true;
          return b;
        },
        maybeSingle: () => Promise.resolve(settle()),
        single: () => Promise.resolve(settle()),
        then: (onFulfilled: (v: unknown) => unknown, onRejected?: (e: unknown) => unknown) =>
          Promise.resolve(settle()).then(onFulfilled, onRejected),
      };
      for (const m of ['eq', 'neq', 'is', 'gt', 'gte', 'lt', 'ilike', 'in', 'order', 'limit']) {
        b[m] = (...args: unknown[]) => {
          call.filters.push([m, ...args]);
          return b;
        };
      }
      return b;
    };

    return {
      auth: {
        getUser: () => Promise.resolve(self.userResult),
        admin: {
          inviteUserByEmail: (email: string, options: unknown) => {
            self.inviteArgs.push({ email, options });
            return Promise.resolve(self.inviteResult);
          },
        },
      },
      from,
      rpc: (name: string, args: unknown) =>
        Promise.resolve(
          self.resolve({ client: kind, authorization, table: name, op: 'rpc', payload: args, filters: [] }),
        ),
    };
  }
}

// Static import map: vite must see each path to transform it.
const loaders: Record<string, () => Promise<unknown>> = {
  'accept-invite': () => import('../accept-invite/index'),
  'bootstrap-admin': () => import('../bootstrap-admin/index'),
  'create-tenant': () => import('../create-tenant/index'),
  'invite-user': () => import('../invite-user/index'),
  cors: () => import('../_shared/cors'),
};

type Handler = (req: Request) => Response | Promise<Response>;

/** Fresh-import a function with the given env; returns the handler it registered with serve(). */
export async function loadHandler(
  name: 'accept-invite' | 'bootstrap-admin' | 'create-tenant' | 'invite-user',
  fake: FakeSupabase,
  env: Record<string, string | undefined> = {},
): Promise<Handler> {
  const merged = { ...ENV, ...env };
  const g = globalThis as Record<string, unknown>;
  g.Deno = { env: { get: (k: string) => merged[k] } };
  g.__edge = { fake, handler: undefined };
  vi.resetModules();
  await loaders[name]();
  const handler = (g.__edge as { handler?: Handler }).handler;
  if (!handler) throw new Error(`${name} did not register a handler with serve()`);
  return handler;
}

/** Import the shared CORS helper with a given ALLOWED_ORIGINS (it reads env at module load). */
export async function loadCors(allowedOrigins?: string) {
  const g = globalThis as Record<string, unknown>;
  g.Deno = { env: { get: (k: string) => (k === 'ALLOWED_ORIGINS' ? allowedOrigins : undefined) } };
  vi.resetModules();
  return (await loaders.cors()) as { buildCorsHeaders: (req: Request) => Record<string, string> };
}

export function req(
  body?: unknown,
  opts: { method?: string; auth?: string | null; origin?: string; rawBody?: string } = {},
): Request {
  const headers: Record<string, string> = { 'Content-Type': 'application/json' };
  if (opts.auth !== null) headers.Authorization = opts.auth ?? 'Bearer test-token';
  if (opts.origin) headers.Origin = opts.origin;
  const method = opts.method ?? 'POST';
  const init: RequestInit = { method, headers };
  if (method !== 'GET' && method !== 'OPTIONS') {
    init.body = opts.rawBody ?? JSON.stringify(body ?? {});
  }
  return new Request('http://localhost/fn', init);
}

export async function json(res: Response): Promise<Record<string, unknown>> {
  return (await res.json()) as Record<string, unknown>;
}
