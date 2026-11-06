// Client error collector (gap #3).
// Vercel function at /api/client-errors. Logs unhandled client errors and
// promise rejections; wire the log drain to alerting.

interface Req { method?: string; body?: unknown; }
interface Res {
  status(code: number): Res;
  json(body: unknown): void;
  end(): void;
}

export default function handler(req: Req, res: Res) {
  if (req.method !== 'POST') {
    res.status(405).json({ ok: false });
    return;
  }
  const b = (req.body ?? {}) as Record<string, unknown>;
  console.error('[client-error]', JSON.stringify({
    message: b.message,
    stack: b.stack,
    url: b.url,
    at: b.at,
    extra: b.extra,
  }));
  res.status(204).end();
}
