import { useMyModuleAccess } from '../../../features/navigation/useMyModuleAccess';

// Role tiers for the Insurance Brokerage module.
//
// staff_roles.role has no hierarchy; has_module_role() matches roles exactly, so
// the manager tier lists both values. These mirror the server tiers in
// 20261010100000_insurance_brokerage_core.sql:
//   can_access_insurance() = admin | manager | member   (see, draft, register, assess)
//   can_manage_insurance() = admin | manager            (bind, decide claims, masters, delete drafts)
// The server is the enforcement point. The UI uses these only to show or hide buttons.
export const INS_ADMIN_ROLES = ['admin', 'manager'] as const;

export interface InsuranceAccess {
  loading: boolean;
  canManage: boolean;
}

export function useInsuranceAccess(): InsuranceAccess {
  const access = useMyModuleAccess();
  if (!access) return { loading: true, canManage: false };
  const roles = access.rolesByModule.get('insurance') ?? new Set<string>();
  const canManage = access.isPlatformAdmin || INS_ADMIN_ROLES.some((r) => roles.has(r));
  return { loading: false, canManage };
}
