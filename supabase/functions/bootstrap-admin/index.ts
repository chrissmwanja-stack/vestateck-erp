// bootstrap-admin
//
// One-time claim flow for the very first platform admin, replacing the
// manual `UPDATE app_users SET is_platform_admin = true WHERE email = ...`
// workflow (see onboarding session notes, section 6, "known gaps").
//
// Unlike invite-user/accept-invite, there's no inviter for the first
// admin -- nobody has a platform-admin session yet to send the invite.
// So this endpoint is reachable by any authenticated caller, gated by
// two independent checks instead:
//   1. No platform admin may already exist (one-shot; closes itself).
//   2. Caller must supply BOOTSTRAP_ADMIN_CODE, a secret only Chris has
//      (set via `supabase secrets set BOOTSTRAP_ADMIN_CODE=... --project-ref
//      <your-project-ref>`), so a stranger who signs up during the
//      window before the code is known can't race for admin.
//
// Deliberately does NOT create a real business tenant -- platform admins
// live in the reserved '00000000-0000-0000-0000-000000000099' tenant
// (see the bootstrap_platform_admin migration), not a customer tenant.

import { serve } from 'https://deno.land/std@0.224.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0';
import { buildCorsHeaders } from '../_shared/cors.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const BOOTSTRAP_ADMIN_CODE = Deno.env.get('BOOTSTRAP_ADMIN_CODE');

const PLATFORM_TENANT_ID = '00000000-0000-0000-0000-000000000099';

function jsonResponse(corsHeaders: HeadersInit, body: unknown, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

serve(async (req) => {
  const corsHeaders = buildCorsHeaders(req);

  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    // The code must be configured before this endpoint does anything.
    // Fails closed rather than silently allowing an uncoded claim.
    if (!BOOTSTRAP_ADMIN_CODE) {
      return jsonResponse(corsHeaders,
        { error: 'Bootstrap is not configured. Set BOOTSTRAP_ADMIN_CODE and redeploy.' },
        503
      );
    }

    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      return jsonResponse(corsHeaders, { error: 'Missing Authorization header' }, 401);
    }

    const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: userData, error: userError } = await userClient.auth.getUser();
    if (userError || !userData.user) {
      return jsonResponse(corsHeaders, { error: 'Invalid or expired session' }, 401);
    }
    const userId = userData.user.id;
    const userEmail = userData.user.email;
    if (!userEmail) {
      return jsonResponse(corsHeaders, { error: 'Authenticated user has no email' }, 400);
    }

    const { name, code } = await req.json().catch(() => ({}));

    if (typeof code !== 'string' || code !== BOOTSTRAP_ADMIN_CODE) {
      return jsonResponse(corsHeaders, { error: 'Invalid bootstrap code' }, 403);
    }
    if (typeof name !== 'string' || name.trim().length === 0) {
      return jsonResponse(corsHeaders, { error: 'Name is required' }, 400);
    }

    const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    // --- One-shot: refuse once any platform admin exists ---
    const { count: adminCount, error: countError } = await admin
      .from('app_users')
      .select('id', { count: 'exact', head: true })
      .eq('is_platform_admin', true);

    if (countError) return jsonResponse(corsHeaders, { error: countError.message }, 500);

    if ((adminCount ?? 0) > 0) {
      return jsonResponse(corsHeaders,
        { error: 'A platform admin already exists. Ask them to invite you instead.' },
        409
      );
    }

    // --- Idempotency: if this caller already has an app_users row
    // (e.g. retried call), promote it rather than re-inserting ---
    const { data: existing } = await admin
      .from('app_users')
      .select('id')
      .eq('id', userId)
      .maybeSingle();

    if (existing) {
      const { error: updateError } = await admin
        .from('app_users')
        .update({ is_platform_admin: true })
        .eq('id', userId);
      // 23505 here means the app_users_single_platform_admin partial
      // unique index rejected us -- a different caller committed their
      // claim between our count-check above and this update.
      if (updateError) {
        if (updateError.code === '23505') {
          return jsonResponse(corsHeaders,
            { error: 'A platform admin already exists. Ask them to invite you instead.' },
            409
          );
        }
        return jsonResponse(corsHeaders, { error: updateError.message }, 500);
      }
    } else {
      const { error: insertError } = await admin.from('app_users').insert({
        id: userId,
        tenant_id: PLATFORM_TENANT_ID,
        email: userEmail,
        name: name.trim(),
        is_platform_admin: true,
      });
      if (insertError) {
        if (insertError.code === '23505') {
          // Two distinct unique constraints can fire here:
          //  - app_users_single_platform_admin: someone else won the race
          //    between our count-check and this insert. Genuine loss.
          //  - app_users_pkey (id): this exact caller retried after a
          //    prior successful claim already committed. Treat as done.
          if (insertError.message.includes('app_users_single_platform_admin')) {
            return jsonResponse(corsHeaders,
              { error: 'A platform admin already exists. Ask them to invite you instead.' },
              409
            );
          }
        } else {
          return jsonResponse(corsHeaders, { error: insertError.message }, 500);
        }
      }
    }

    return jsonResponse(corsHeaders, { message: 'Platform admin claimed' }, 200);
  } catch (err) {
    return jsonResponse(corsHeaders,
      { error: err instanceof Error ? err.message : 'Unexpected error' },
      500
    );
  }
});