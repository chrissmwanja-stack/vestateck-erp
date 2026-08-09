// create-tenant
//
// Closes the gap flagged during invite-user: there's no RLS INSERT
// policy on `tenants` for authenticated users (only `tenants_select_own`
// exists), so tenant creation has to go through a service-role edge
// function rather than a direct client insert.
//
// This is the first half of the Companies console's "create tenant +
// invite first admin" action. It only creates the tenant; the caller is
// expected to follow up with a call to invite-user (role_bundle:
// 'company_admin') using the returned tenant_id.
//
// Authorization: caller must be a platform admin (app_users.is_platform_admin).

import { serve } from 'https://deno.land/std@0.224.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

interface CreateTenantBody {
  name: string;
  industry_template?: string;
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

    const body = (await req.json()) as CreateTenantBody;
    const name = body.name?.trim();
    if (!name) {
      return jsonResponse({ error: 'name is required' }, 400);
    }

    const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    // --- Authorization: platform admin only ---
    const { data: callerRow, error: callerError } = await admin
      .from('app_users')
      .select('is_platform_admin')
      .eq('id', callerId)
      .maybeSingle();

    if (callerError) return jsonResponse({ error: callerError.message }, 500);
    if (!callerRow?.is_platform_admin) {
      return jsonResponse({ error: 'Only platform admins can create tenants' }, 403);
    }

    // --- Prevent obvious accidental duplicates ---
    const { data: existing, error: existingError } = await admin
      .from('tenants')
      .select('id')
      .ilike('name', name)
      .limit(1)
      .maybeSingle();

    if (existingError) return jsonResponse({ error: existingError.message }, 500);
    if (existing) {
      return jsonResponse(
        { error: 'A tenant with this name already exists', tenant_id: existing.id },
        409
      );
    }

    // --- Create the tenant ---
    const { data: tenant, error: insertError } = await admin
      .from('tenants')
      .insert({
        name,
        industry_template: body.industry_template ?? 'general',
        created_by: callerId,
        status: 'pending',
      })
      .select('id, name, status')
      .single();

    if (insertError) return jsonResponse({ error: insertError.message }, 500);

    return jsonResponse({ tenant }, 200);
  } catch (err) {
    return jsonResponse(
      { error: err instanceof Error ? err.message : 'Unexpected error' },
      500
    );
  }
});