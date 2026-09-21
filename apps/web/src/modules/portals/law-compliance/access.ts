// Role tiers for the Law & Compliance module.
//
// staff_roles.role has no built-in hierarchy -- has_module_role() does an
// exact `role = any(p_roles)` match (see the BD note in
// business-development/access.ts), so the approver tier lists both
// 'admin' and 'manager' explicitly.
//
// LEGAL_APPROVER_ROLES gates /law-compliance/contracts/approvals in
// App.tsx and mirrors the server-side tier in decide_contract() /
// transition_filing() (20260921100000_law_contract_approval_flow.sql and
// 20260921103000_law_filing_transitions.sql): legal members may draft,
// submit and view, only admin/manager may sign off a contract, reject
// one, or move a regulatory filing through its state machine.
// Everything else under /law-compliance/* stays on RequireModule's
// default admin/manager/member tier.
export const LEGAL_APPROVER_ROLES = ['admin', 'manager'] as const;
