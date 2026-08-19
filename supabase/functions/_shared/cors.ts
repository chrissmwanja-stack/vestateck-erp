// Origin allowlist for browser-facing edge functions.
//
// All six functions that serve browser requests (accept-invite,
// bootstrap-admin, create-tenant, generate-po, invite-user,
// resend-invite) were shipping `Access-Control-Allow-Origin: '*'`,
// which lets any website's script read these functions' responses --
// including ones that return invite tokens, tenant analytics, or
// mutate data. These functions already gate on the Authorization
// header server-side, so wildcard CORS isn't an auth bypass, but it
// still lets a malicious page piggyback on a signed-in user's browser
// session and read the response, or probe these endpoints from
// arbitrary origins. Locking this to known frontend origins removes
// that surface at zero functional cost -- only the deployed app is
// ever meant to call these.
//
// ALLOWED_ORIGINS is a comma-separated edge-function secret, set with:
//   supabase secrets set ALLOWED_ORIGINS=https://app.example.com,https://staging.example.com
// Not deployed anywhere yet as of 2026-08-19 (dev-only, per Chris),
// so this defaults to the Vite dev server origin. Set the secret --
// don't hardcode a new default here -- the moment a real frontend URL
// exists.

const DEFAULT_DEV_ORIGINS = ['http://localhost:5173'];

function getAllowedOrigins(): string[] {
  const raw = Deno.env.get('ALLOWED_ORIGINS');
  if (!raw) return DEFAULT_DEV_ORIGINS;
  return raw
    .split(',')
    .map((o) => o.trim())
    .filter(Boolean);
}

const ALLOWED_ORIGINS = getAllowedOrigins();

// Returns CORS headers scoped to this specific request: echoes the
// request's Origin back only if it's on the allowlist, otherwise
// omits Access-Control-Allow-Origin entirely (the browser then blocks
// script access to the response -- same effective result as a hard
// reject, but without needing a special-cased error response). This
// per-request echo is required rather than a static header because
// Access-Control-Allow-Origin can only ever hold a single origin --
// there's no way to comma-separate multiple allowed origins in the
// header value itself.
export function buildCorsHeaders(req: Request): HeadersInit {
  const origin = req.headers.get('Origin') ?? '';
  const headers: Record<string, string> = {
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    // Tells shared/CDN caches the response varies by Origin, so a
    // cached response for one origin is never served to another.
    Vary: 'Origin',
  };
  if (ALLOWED_ORIGINS.includes(origin)) {
    headers['Access-Control-Allow-Origin'] = origin;
  }
  return headers;
}
