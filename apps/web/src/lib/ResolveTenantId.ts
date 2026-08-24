import type { Session } from '@supabase/supabase-js';
import { supabase } from './supabaseClient';

export type ResolveTenantIdResult = { tenantId: string; error?: undefined } | { tenantId?: undefined; error: string };

// Every "New X" create screen whose target table has tenant_id as
// `uuid NOT NULL` with no column-level DEFAULT needs to resolve and send
// the real tenant_id itself on insert. Several screens across the app
// (MaterialLookupsAdmin, DepartmentsAdmin, OrganizationsAdmin,
// WarehousesAdmin, SapPaymentApprovals, CashBankOperations,
// NewMaterialRequest) previously sent a placeholder `tenant_id: ''`
// instead, on the assumption that a BEFORE INSERT trigger would fill it
// in server-side. That assumption is false regardless of whether the
// trigger exists: Postgres coerces literal/bound values to their column
// type (uuid_in('')) during statement parsing, before any row-level
// trigger or RLS check ever runs -- so every one of those creates failed
// outright with "invalid input syntax for type uuid", not silently.
//
// This mirrors the fix already applied to MaterialCatalogAdmin.tsx and
// AccountsAdmin.tsx (see 20260822120000_material_catalog_insert_policy.sql
// for that incident's writeup), consolidated into one place instead of a
// dozen near-identical inline copies -- the same reasoning that
// migration gives for not reintroducing a second, independent
// tenant_id-setting mechanism applies just as much to duplicating this
// client-side logic: a copy that quietly drifts from the others is
// exactly how this bug shipped seven times in the first place.
export async function resolveTenantId(session: Session | null): Promise<ResolveTenantIdResult> {
  const userId = session?.user?.id;
  if (!userId) {
    return { error: 'Could not determine your session. Please refresh and try again.' };
  }
  const { data: appUser, error } = await supabase.from('app_users').select('tenant_id').eq('id', userId).single();
  if (error || !appUser?.tenant_id) {
    return { error: 'Could not determine your organization. Please refresh and try again.' };
  }
  return { tenantId: appUser.tenant_id };
}