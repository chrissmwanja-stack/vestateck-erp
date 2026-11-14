// Client error collector (gap #3).
// Vercel function at /api/client-errors. Logs unhandled client errors and
// promise rejections; wire the log drain to alerting.
//
// Public and unauthenticated by necessity (errors can happen before login), so
// it is hardened: body-size cap, per-IP rate limit, and every field is
// control-char-stripped and truncated before it reaches the logs.

import { bodyTooLarge, clean, clientIp, createLimiter, type GuardReq } from './_lib/guard';

interface Res {
  status(code: number): Res;
  json(body: unknown): void;
  end(): void;
}

const limiter = createLimiter({ windowMs: 60_000, max: 20 });

export default function handler(req: GuardReq, res: Res) {
  if (req.method !== 'POST') {
    res.status(405).json({ ok: false });
    return;
  }
  if (bodyTooLarge(req)) {
    res.status(413).json({ ok: false });
    return;
  }
  // Over the limit: drop silently with the same 204 so reporters learn nothing.
  if (!limiter.allow(clientIp(req))) {
    res.status(204).end();
    return;
  }
  const b = (req.body && typeof req.body === 'object' ? req.body : {}) as Record<string, unknown>;
  console.error('[client-error]', JSON.stringify({
    message: clean(b.message, 500),
    stack: clean(b.stack, 4000),
    url: clean(b.url, 500),
    at: clean(b.at, 40),
    extra: clean(b.extra, 1000),
  }));
  res.status(204).end();
}
