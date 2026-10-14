// supabase-js reports every non-2xx Edge Function response as a generic
// FunctionsHttpError ("Edge Function returned a non-2xx status code"). The
// real reason -- the `{ error }` JSON our functions return -- sits on the
// error's `context`, which is the raw Response. This pulls it out so the UI
// can show what actually went wrong.

interface HasContext {
  context?: unknown;
  message?: string;
}

export async function functionErrorMessage(err: unknown): Promise<string> {
  const e = (err ?? {}) as HasContext;
  const fallback = e.message || 'Request failed';

  const ctx = e.context as { json?: () => Promise<unknown>; clone?: () => unknown } | undefined;
  if (!ctx || typeof ctx.json !== 'function') return fallback;

  try {
    // clone() so the body stays readable for anyone else holding the Response.
    const res = (typeof ctx.clone === 'function' ? ctx.clone() : ctx) as { json: () => Promise<unknown> };
    const body = (await res.json()) as { error?: unknown } | null;
    if (body && typeof body.error === 'string' && body.error.trim()) return body.error;
  } catch {
    // Body wasn't JSON (gateway error, timeout) -- use the generic message.
  }
  return fallback;
}
