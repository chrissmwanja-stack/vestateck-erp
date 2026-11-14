// Shared hardening for the public, unauthenticated log-collector endpoints
// (/api/client-errors, /api/csp-report). Anyone on the internet can POST to
// these, so they must bound what they accept and what they write to logs.
//
// The api/_lib folder is prefixed with an underscore so Vercel does not
// deploy it as a function of its own.

export interface GuardReq {
  method?: string;
  body?: unknown;
  headers?: Record<string, string | string[] | undefined>;
}

/** Max bytes of request body we are willing to log (Content-Length check). */
export const MAX_BODY_BYTES = 16 * 1024;

const CONTROL_CHARS = /[\u0000-\u001f\u007f\u2028\u2029]/g;

/** Strips control characters (incl. newlines, so a caller cannot forge extra
 *  log lines) and truncates. Non-strings are stringified first. */
export function clean(value: unknown, max = 500): string | undefined {
  if (value === undefined || value === null) return undefined;
  const s = typeof value === 'string' ? value : safeStringify(value);
  return s.replace(CONTROL_CHARS, ' ').slice(0, max);
}

function safeStringify(v: unknown): string {
  try {
    return JSON.stringify(v) ?? String(v);
  } catch {
    return String(v);
  }
}

function header(req: GuardReq, name: string): string | undefined {
  const v = req.headers?.[name];
  return Array.isArray(v) ? v[0] : v;
}

/** Best-effort client IP. On Vercel the platform sets x-forwarded-for. */
export function clientIp(req: GuardReq): string {
  const xff = header(req, 'x-forwarded-for');
  const ip = xff ? xff.split(',')[0].trim() : header(req, 'x-real-ip');
  return (ip || 'unknown').slice(0, 64);
}

export function bodyTooLarge(req: GuardReq): boolean {
  const len = Number(header(req, 'content-length'));
  return Number.isFinite(len) && len > MAX_BODY_BYTES;
}

/**
 * Fixed-window per-key limiter with a hard cap on tracked keys, so an attacker
 * who rotates keys cannot grow memory without bound. State is per serverless
 * instance (best effort, not a global limit).
 */
export function createLimiter(opts: { windowMs: number; max: number; maxKeys?: number; now?: () => number }) {
  const { windowMs, max, maxKeys = 5000, now = Date.now } = opts;
  const hits = new Map<string, { start: number; n: number }>();

  function evictExpired(t: number) {
    for (const [k, v] of hits) if (t - v.start > windowMs) hits.delete(k);
  }

  return {
    allow(key: string): boolean {
      const t = now();
      const cur = hits.get(key);
      if (cur && t - cur.start <= windowMs) {
        cur.n += 1;
        return cur.n <= max;
      }
      if (hits.size >= maxKeys) {
        evictExpired(t);
        // Still full of live keys: refuse new keys rather than grow.
        if (hits.size >= maxKeys) return false;
      }
      hits.set(key, { start: t, n: 1 });
      return true;
    },
    size: () => hits.size,
  };
}
