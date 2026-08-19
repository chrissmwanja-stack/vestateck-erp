// accept-invite
//
// Step 2 of the onboarding invite chain (see session notes, section 5).
// Runs after the invited person has set a password via /accept-invite
// and has an authenticated session (auth.uid() resolves). Turns their
// pending `invitations` row into real app_users / staff_roles rows.
//
// This is the ONLY place app_users/staff_roles get created for an
// invited user -- invite-user deliberately stops short of this.
//
// Idempotency: if called twice for an already-accepted invitation, this
// returns success without re-inserting (checks invitation.status first).

import { serve } from 'https://deno.land/std@0.224.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0';
import { buildCorsHeaders } from '../_shared/cors.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const ALL_MODULES = ['hr', 'legal', 'bd', 'it', 'pmo', 'machine_operation', 'sustainability', 'procurement'] as const;

interface ModuleRole {
  module: (typeof ALL_MODULES)[number];
  role: 'admin' | 'manager' | 'member';
}

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
    // Caller must already be authenticated (they set their password via
    // Supabase Auth's recovery/invite flow before hitting this endpoint).
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

    const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    // --- Find the pending invitation for this email ---
    // Matched by email rather than a client-supplied invitation_id, so a
    // malicious caller can't pass someone else's invitation_id and land
    // in a tenant they were never invited to -- the auth.uid() session's
    // own email is the only thing we trust here.
    const { data: invitation, error: inviteError } = await admin
      .from('invitations')
      .select('id, tenant_id, role_bundle, modules_and_roles, finance_role, status')
      .eq('email', userEmail.toLowerCase().trim())
      .eq('status', 'pending')
      .order('created_at', { ascending: false })
      .limit(1)
      .maybeSingle();

    if (inviteError) return jsonResponse(corsHeaders, { error: inviteError.message }, 500);

    // --- Idempotency: already accepted (e.g. double-submit) ---
    if (!invitation) {
      const { data: alreadyAccepted } = await admin
        .from('app_users')
        .select('id, tenant_id')
        .eq('id', userId)
        .maybeSingle();

      if (alreadyAccepted) {
        return jsonResponse(corsHeaders,
          { message: 'Invitation already accepted', tenant_id: alreadyAccepted.tenant_id },
          200
        );
      }
      return jsonResponse(corsHeaders, { error: 'No pending invitation found for this email' }, 404 );
    }

    // --- Create app_users row ---
    const { error: appUserError } = await admin.from('app_users').insert({
      id: userId,
      tenant_id: invitation.tenant_id,
      email: userEmail,
      name: userEmail.split('@')[0], // placeholder -- user can update in profile settings
      // Durable marker for "the tenant's overall company admin", distinct
      // from the per-module staff_roles admin rows inserted below (see
      // 20260817125405_add_is_company_admin_flag). invite-user's
      // member-invite authorization gates on this specifically -- without
      // it, nobody who accepts a company_admin invite would ever be able
      // to invite anyone else.
      is_company_admin: invitation.role_bundle === 'company_admin',
    });

    if (appUserError) {
      // 23505 = unique violation -> app_users row already exists (race
      // condition or a retried call). Treat as already-done rather than
      // a hard failure.
      if (appUserError.code !== '23505') {
        return jsonResponse(corsHeaders, { error: appUserError.message }, 500);
      }
    }

    // --- Create staff_roles rows ---
    const roleRows =
      invitation.role_bundle === 'company_admin'
        ? ALL_MODULES.map((module) => ({
            tenant_id: invitation.tenant_id,
            user_id: userId,
            module,
            role: 'admin',
          }))
        : ((invitation.modules_and_roles as ModuleRole[] | null) ?? []).map((mr) => ({
            tenant_id: invitation.tenant_id,
            user_id: userId,
            module: mr.module,
            role: mr.role,
          }));

    if (roleRows.length > 0) {
      const { error: rolesError } = await admin.from('staff_roles').insert(roleRows);
      // Ignore unique-violation on roles too, for the same retry reason.
      if (rolesError && rolesError.code !== '23505') {
        return jsonResponse(corsHeaders, { error: rolesError.message }, 500);
      }
    }

    // --- Create finance_team_members row, if applicable ---
    // company_admin gets full 'finance' access implicitly, same treatment
    // as staff_roles above. Member invites only get a row if the inviter
    // explicitly granted finance access via invite-user's finance_role.
    const financeRole =
      invitation.role_bundle === 'company_admin' ? 'finance' : invitation.finance_role;

    if (financeRole) {
      const { error: financeError } = await admin.from('finance_team_members').insert({
        tenant_id: invitation.tenant_id,
        user_id: userId,
        role: financeRole,
      });
      // Ignore unique-violation for the same retry reason as staff_roles.
      if (financeError && financeError.code !== '23505') {
        return jsonResponse(corsHeaders, { error: financeError.message }, 500);
      }
    }

    // --- Mark the invitation accepted ---
    const { error: acceptError } = await admin
      .from('invitations')
      .update({ status: 'accepted', accepted_at: new Date().toISOString() })
      .eq('id', invitation.id);

    if (acceptError) return jsonResponse(corsHeaders, { error: acceptError.message }, 500);

    // --- If this is the tenant's first accepted invite, activate it ---
    const { count: acceptedCount, error: countError } = await admin
      .from('invitations')
      .select('id', { count: 'exact', head: true })
      .eq('tenant_id', invitation.tenant_id)
      .eq('status', 'accepted');

    if (!countError && acceptedCount === 1) {
      await admin
        .from('tenants')
        .update({ status: 'active' })
        .eq('id', invitation.tenant_id)
        .eq('status', 'pending');
    }

    return jsonResponse(corsHeaders,
      {
        tenant_id: invitation.tenant_id,
        role_bundle: invitation.role_bundle,
        modules_granted: roleRows.map((r) => r.module),
        finance_role_granted: financeRole,
      },
      200
    );
  } catch (err) {
    return jsonResponse(corsHeaders,
      { error: err instanceof Error ? err.message : 'Unexpected error' },
      500
    );
  }
});