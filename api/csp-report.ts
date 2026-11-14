// CSP violation report collector (gap #2).
// Vercel function at /api/csp-report. Logs every accepted report; wire the
// Vercel log drain to your alerting (e.g. Better Stack / Datadog) to get signal.
//
// Public by design (browsers POST here). Two limits, both bounded in memory:
//   1. per client IP, so one source cannot flood the logs, and
//   2. per distinct violation, so a real bug does not log thousands of copies.
// The violation key is attacker-controlled, so it is truncated and the limiter
// caps how many distinct keys it will track.

import { bodyTooLarge, clean, clientIp, createLimiter, type GuardReq } from './_lib/guard';

interface Res {
  status(code: number): Res;
  json(body: unknown): void;
  end(): void;
}

const perIp = createLimiter({ windowMs: 60_000, max: 100 });
const perViolation = createLimiter({ windowMs: 60_000, max: 50 });

export default function handler(req: GuardReq, res: Res) {
  if (req.method !== 'POST') {
    res.status(405).json({ ok: false });
    return;
  }
  if (bodyTooLarge(req)) {
    res.status(413).json({ ok: false });
    return;
  }
  const body = req.body as Record<string, unknown> | undefined;
  const raw = (body?.['csp-report'] ?? body) as Record<string, unknown> | undefined;
  const report = {
    'document-uri': clean(raw?.['document-uri'], 300),
    'violated-directive': clean(raw?.['violated-directive'], 100),
    'effective-directive': clean(raw?.['effective-directive'], 100),
    'blocked-uri': clean(raw?.['blocked-uri'], 300),
    'source-file': clean(raw?.['source-file'], 300),
    'line-number': clean(raw?.['line-number'], 10),
  };
  const key = `${report['document-uri'] ?? ''}|${report['violated-directive'] ?? ''}|${report['blocked-uri'] ?? ''}`;
  if (perIp.allow(clientIp(req)) && perViolation.allow(key)) {
    console.warn('[csp-report]', JSON.stringify(report));
  }
  // Always 204: reporters must not learn anything from the response.
  res.status(204).end();
}
