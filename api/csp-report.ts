// CSP violation report collector (gap #2).
// Vercel function at /api/csp-report. Logs every report; wire the Vercel
// log drain to your alerting (e.g. Better Stack / Datadog) to get signal.
// Rate-limited in-memory per instance to avoid log flooding.

interface Req { method?: string; body?: unknown; }
interface Res {
  status(code: number): Res;
  json(body: unknown): void;
  end(): void;
}

const recent = new Map<string, number>();
const WINDOW_MS = 60_000;
const MAX_PER_WINDOW = 50;

function allow(key: string): boolean {
  const now = Date.now();
  const n = (recent.get(key) ?? 0) + 1;
  recent.set(key, n);
  const windowStart = recent.get(key + ':w') ?? now;
  if (now - windowStart > WINDOW_MS) {
    recent.set(key + ':w', now);
    recent.set(key, 1);
    return true;
  }
  recent.set(key + ':w', windowStart);
  return n <= MAX_PER_WINDOW;
}

export default function handler(req: Req, res: Res) {
  if (req.method !== 'POST') {
    res.status(405).json({ ok: false });
    return;
  }
  const body = req.body as Record<string, unknown> | undefined;
  const report = (body?.['csp-report'] ?? body) as Record<string, unknown> | undefined;
  const key = `${String(report?.['document-uri'] ?? '')}|${String(report?.['violated-directive'] ?? '')}|${String(report?.['blocked-uri'] ?? '')}`;
  if (allow(key)) {
    console.warn('[csp-report]', JSON.stringify(report));
  }
  // Always 204: reporters must not learn anything from the response.
  res.status(204).end();
}
