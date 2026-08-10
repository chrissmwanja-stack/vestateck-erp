// resend-invite
//
// Re-sends the invite email for a pending or expired invitation.
//
// Relies on Supabase Auth's invite endpoint being idempotent for
// unconfirmed users: calling inviteUserByEmail again for an email that
// already has an unconfirmed auth.users row (created by the original
// invite-user call) resends the invite rather than erroring. If a
// person already confirmed an account with that email some other way,
// this will fail with Supabase's "already registered" error, which gets
// surfaced as-is -- that's a real conflict the admin needs to know about,
// not something to paper over.
//
// Authorization mirrors invite-user / revoke_invitation: platform admins
// can resend anything; tenant module admins can resend 'member' invites
// in their own tenant only.

import { serve } from 'https://deno.land/std@0.224.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const ACCEPT_INVITE_URL = Deno.env.get('ACCEPT_INVITE_URL') ?? '';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

interface ResendInviteBody {
  invitation_id: string;
}

function jsonResponse(body: unknown, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      return jsonResponse({ error: 'Missing Authorization header' }, 401);
    }

    const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: userData, error: userError } = await userClient.auth.getUser();
    if (userError || !userData.user) {
      return jsonResponse({ error: 'Invalid or expired session' }, 401);
    }
    const callerId = userData.user.id;

    const body = (await req.json()) as ResendInviteBody;
    if (!body.invitation_id) {
      return jsonResponse({ error: 'invitation_id is required' }, 400);
    }

    const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    const { data: invitation, error: inviteError } = await admin
      .from('invitations')
      .select('id, tenant_id, email, role_bundle, status')
      .eq('id', body.invitation_id)
      .maybeSingle();

    if (inviteError) return jsonResponse({ error: inviteError.message }, 500);
    if (!invitation) return jsonResponse({ error: 'Invitation not found' }, 404);

    if (!['pending', 'expired'].includes(invitation.status)) {
      return jsonResponse(
        { error: `Only pending or expired invitations can be resent (this one is ${invitation.status})` },
        400
      );
    }

    // --- Authorization (same shape as invite-user) ---
    const { data: callerRow, error: callerError } = await admin
      .from('app_users')
      .select('tenant_id, is_platform_admin')
      .eq('id', callerId)
      .maybeSingle();

    if (callerError) return jsonResponse({ error: callerError.message }, 500);
    if (!callerRow) return jsonResponse({ error: 'Caller has no app_users record' }, 403);

    if (invitation.role_bundle === 'company_admin') {
      if (!callerRow.is_platform_admin) {
        return jsonResponse({ error: 'Only platform admins can resend a company admin invite' }, 403);
      }
    } else {
      if (invitation.tenant_id !== callerRow.tenant_id) {
        return jsonResponse({ error: 'You can only resend invites within your own tenant' }, 403);
      }
      const { data: adminRole, error: adminRoleError } = await admin
        .from('staff_roles')
        .select('id')
        .eq('user_id', callerId)
        .eq('tenant_id', invitation.tenant_id)
        .eq('role', 'admin')
        .limit(1)
        .maybeSingle();

      if (adminRoleError) return jsonResponse({ error: adminRoleError.message }, 500);
      if (!adminRole) {
        return jsonResponse({ error: 'Only a module admin can resend team member invites' }, 403);
      }
    }

    // --- Resend ---
    const { error: authError } = await admin.auth.admin.inviteUserByEmail(invitation.email, {
      redirectTo: ACCEPT_INVITE_URL || undefined,
      data: { invitation_id: invitation.id, tenant_id: invitation.tenant_id },
    });

    if (authError) {
      return jsonResponse({ error: authError.message }, 500);
    }

    // If it had been marked expired, resending makes it pending again.
    if (invitation.status !== 'pending') {
      await admin.from('invitations').update({ status: 'pending' }).eq('id', invitation.id);
    }

    return jsonResponse({ invitation_id: invitation.id, email: invitation.email }, 200);
  } catch (err) {
    return jsonResponse(
      { error: err instanceof Error ? err.message : 'Unexpected error' },
      500
    );
  }
});