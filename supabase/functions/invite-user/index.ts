// invite-user
//
// Step 1 of the onboarding invite chain (see session notes, section 5).
// Creates a pending `invitations` row and an auth.users row (via
// inviteUserByEmail), but deliberately does NOT create app_users /
// staff_roles yet — that happens in accept-invite, once the invited
// person has an authenticated session of their own.
//
// Authorization:
//   - role_bundle = 'company_admin' -> caller must be a platform admin
//     (app_users.is_platform_admin). Any tenant.
//   - role_bundle = 'member'        -> caller must be a module admin
//     (staff_roles.role = 'admin') WITHIN the tenant they're inviting into.
//     tenant_id in the request body must equal the caller's own tenant_id.
//
// This mirrors the invitations table's RLS policies (see the
// onboarding_invitations migration) — the RLS would block a mismatched
// insert anyway, but we check explicitly here so we can return a clear
// 403 instead of a generic Postgres RLS error.
//
// NOTE: this function assumes `tenant_id` already exists in `tenants`.
// Tenant creation (Companies console "create tenant" action) is a
// separate concern — there is currently no RLS INSERT policy on
// `tenants` for authenticated users, so that console screen will need
// either its own edge function or a platform-admin-scoped RLS policy
// before it can create tenants client-side. Not handled here.

import { serve } from 'https://deno.land/std@0.224.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
// Where the invite email's link lands. Point this at the Accept Invite
// screen once it exists, e.g. https://app.vestaportal.com/accept-invite
const ACCEPT_INVITE_URL = Deno.env.get('ACCEPT_INVITE_URL') ?? '';

const ALL_MODULES = ['hr', 'legal', 'bd', 'it', 'pmo', 'machine_operation', 'sustainability', 'procurement'] as const;
const VALID_ROLES = ['admin', 'manager', 'member'] as const;
// Not part of ALL_MODULES/staff_roles -- finance access is a separate
// mechanism (finance_team_members / is_finance_team_member()), see
// 20260816_add_finance_role_to_invitations.
const VALID_FINANCE_ROLES = ['finance', 'cost_control'] as const;

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

interface ModuleRole {
  module: (typeof ALL_MODULES)[number];
  role: (typeof VALID_ROLES)[number];
}

interface InviteUserBody {
  email: string;
  tenant_id: string;
  role_bundle: 'company_admin' | 'member';
  modules_and_roles?: ModuleRole[];
  finance_role?: (typeof VALID_FINANCE_ROLES)[number] | null;
}

function jsonResponse(body: unknown, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

function isValidModuleRoleArray(value: unknown): value is ModuleRole[] {
  if (!Array.isArray(value) || value.length === 0) return false;
  return value.every(
    (v) =>
      v &&
      typeof v === 'object' &&
      ALL_MODULES.includes((v as ModuleRole).module) &&
      VALID_ROLES.includes((v as ModuleRole).role)
  );
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

    const body = (await req.json()) as InviteUserBody;
    const { email, tenant_id, role_bundle } = body;

    if (!email || !tenant_id || !role_bundle) {
      return jsonResponse({ error: 'email, tenant_id, and role_bundle are required' }, 400);
    }
    if (!['company_admin', 'member'].includes(role_bundle)) {
      return jsonResponse({ error: "role_bundle must be 'company_admin' or 'member'" }, 400);
    }

    // finance_role only applies to member invites -- company_admin gets
    // full 'finance' access implicitly (same treatment as modules_and_roles).
    // Computed before the modules_and_roles check below, since a
    // finance-only invite (no modules at all) is valid.
    let financeRole: (typeof VALID_FINANCE_ROLES)[number] | null = null;
    if (role_bundle === 'member' && body.finance_role != null) {
      if (!VALID_FINANCE_ROLES.includes(body.finance_role)) {
        return jsonResponse(
          { error: "finance_role must be 'finance', 'cost_control', or omitted" },
          400
        );
      }
      financeRole = body.finance_role;
    }

    let modulesAndRoles: ModuleRole[] | null = null;
    if (role_bundle === 'member') {
      const hasModules = Array.isArray(body.modules_and_roles) && body.modules_and_roles.length > 0;
      if (!hasModules && !financeRole) {
        return jsonResponse(
          {
            error:
              'member invites need at least one module (module/role pairs) or a finance_role grant',
          },
          400
        );
      }
      if (hasModules && !isValidModuleRoleArray(body.modules_and_roles)) {
        return jsonResponse(
          {
            error:
              'modules_and_roles must be a non-empty array of { module, role }, module in hr/legal/bd/it/pmo/machine_operation/sustainability/procurement, role in admin/manager/member',
          },
          400
        );
      }
      modulesAndRoles = hasModules ? body.modules_and_roles! : [];
    }

    const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    // --- Load caller's own app_users row (platform admin flag + tenant) ---
    const { data: callerRow, error: callerError } = await admin
      .from('app_users')
      .select('tenant_id, is_platform_admin')
      .eq('id', callerId)
      .maybeSingle();

    if (callerError) return jsonResponse({ error: callerError.message }, 500);
    if (!callerRow) {
      return jsonResponse({ error: 'Caller has no app_users record' }, 403);
    }

    // --- Resolve caller's effective tenant ---
    // Mirrors get_my_tenant_id(): a platform admin impersonating a company
    // is acting on that company's tenant, not their own home tenant. Without
    // this, callerRow.tenant_id is always the platform tenant during
    // impersonation and every member invite gets rejected.
    let effectiveTenantId = callerRow.tenant_id;
    if (callerRow.is_platform_admin) {
      const { data: impersonation } = await admin
        .from('impersonation_sessions')
        .select('tenant_id')
        .eq('platform_admin_id', callerId)
        .is('ended_at', null)
        .gt('started_at', new Date(Date.now() - 2 * 60 * 60 * 1000).toISOString())
        .limit(1)
        .maybeSingle();
      if (impersonation?.tenant_id) {
        effectiveTenantId = impersonation.tenant_id;
      }
    }

    // --- Authorization ---
    if (role_bundle === 'company_admin') {
      if (!callerRow.is_platform_admin) {
        return jsonResponse(
          { error: 'Only platform admins can invite a company admin' },
          403
        );
      }
    } else if (callerRow.is_platform_admin) {
      // Platform admins get full access to every module while impersonating
      // a tenant -- they don't need a staff_roles admin row in that company
      // to manage it. Still scoped to the tenant they're actually acting on.
      if (tenant_id !== effectiveTenantId) {
        return jsonResponse(
          { error: 'You can only invite members into the tenant you are currently viewing' },
          403
        );
      }
    } else {
      // member invite: caller must be a module admin, and only within
      // their own tenant.
      if (tenant_id !== effectiveTenantId) {
        return jsonResponse(
          { error: 'You can only invite members into your own tenant' },
          403
        );
      }
      const { data: adminRole, error: adminRoleError } = await admin
        .from('staff_roles')
        .select('id')
        .eq('user_id', callerId)
        .eq('tenant_id', tenant_id)
        .eq('role', 'admin')
        .limit(1)
        .maybeSingle();

      if (adminRoleError) return jsonResponse({ error: adminRoleError.message }, 500);
      if (!adminRole) {
        return jsonResponse(
          { error: 'Only a module admin can invite team members' },
          403
        );
      }
    }

    // --- Confirm the tenant exists ---
    const { data: tenant, error: tenantError } = await admin
      .from('tenants')
      .select('id, status')
      .eq('id', tenant_id)
      .maybeSingle();

    if (tenantError) return jsonResponse({ error: tenantError.message }, 500);
    if (!tenant) {
      return jsonResponse({ error: 'tenant_id does not exist' }, 404);
    }
    if (tenant.status === 'suspended') {
      return jsonResponse({ error: 'Cannot invite into a suspended tenant' }, 400);
    }

    // --- Insert the pending invitation row ---
    const { data: invitation, error: insertError } = await admin
      .from('invitations')
      .insert({
        tenant_id,
        email: email.toLowerCase().trim(),
        invited_by: callerId,
        role_bundle,
        modules_and_roles: modulesAndRoles,
        finance_role: financeRole,
        status: 'pending',
      })
      .select('id')
      .single();

    if (insertError) {
      // Unique constraint is (tenant_id, email, status) — a duplicate
      // here means there's already a pending invite for this person.
      if (insertError.code === '23505') {
        return jsonResponse(
          { error: 'A pending invitation already exists for this email in this tenant' },
          409
        );
      }
      return jsonResponse({ error: insertError.message }, 500);
    }

    // --- Create the auth.users row and send the invite email ---
    const { data: authInvite, error: authError } = await admin.auth.admin.inviteUserByEmail(
      email,
      {
        redirectTo: ACCEPT_INVITE_URL || undefined,
        data: { invitation_id: invitation.id, tenant_id },
      }
    );

    if (authError) {
      // Roll back the invitations row so a retry doesn't hit the unique
      // constraint on a dead invite.
      await admin.from('invitations').delete().eq('id', invitation.id);
      return jsonResponse({ error: authError.message }, 500);
    }

    return jsonResponse(
      {
        invitation_id: invitation.id,
        auth_user_id: authInvite.user?.id ?? null,
        email,
        tenant_id,
        role_bundle,
      },
      200
    );
  } catch (err) {
    return jsonResponse(
      { error: err instanceof Error ? err.message : 'Unexpected error' },
      500
    );
  }
});