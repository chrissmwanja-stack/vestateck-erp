// Shared domain types mirroring supabase/migrations/0001_init_core_schema.sql
// and 0002_approval_queue_rpc.sql.
//
// Note: the interface for the `requests` table is named `ERPRequest`, not
// `Request` — `Request` collides with the built-in DOM/fetch type, which
// causes confusing errors anywhere `fetch` is used alongside these types.

export type RequestStatus = "open" | "rejected" | "closed";
export type DelegationStatus = "active" | "expired" | "revoked";
export type ApprovalDecision = "approved" | "rejected";
export type ApprovalScopeType = "department" | "cost_center" | "global";

export interface Tenant {
  id: string;
  name: string;
  industry_template: string;
  created_at: string;
}

export interface Department {
  id: string;
  tenant_id: string;
  parent_department_id: string | null;
  name: string;
  is_active: boolean;
  created_at: string;
}

export interface AppUser {
  id: string; // matches auth.users.id
  tenant_id: string;
  department_id: string | null; // nullable per migration (on delete set null)
  name: string;
  email: string;
  role_title: string | null;
  created_at: string;
}

export interface CostCenter {
  id: string;
  tenant_id: string;
  name: string;
  project_code: string | null;
  budget_amount: number | null;
  created_at: string;
}

export interface WorkflowStage {
  id: string;
  tenant_id: string;
  name: string;
  sequence_order: number;
  approver_role: string;
  threshold_amount: number | null;
  next_stage_low_id: string | null;
  next_stage_high_id: string | null;
  requires_offer_entry: boolean;
  // Multi-offer model: true at the stage where a winner still needs to be
  // picked from competing offers (Budget Controller) -- see OfferApprovalPO.tsx.
  requires_offer_selection: boolean;
  created_at: string;
  blocks_offer_submitter_approval: boolean;
}

export interface ERPRequest {
  id: string;
  tenant_id: string;
  requester_id: string;
  department_id: string;
  cost_center_id: string | null;
  current_stage_id: string | null;
  item_description: string;
  quantity: number;
  status: RequestStatus;
  replaces_request_id: string | null;
  created_at: string;
  updated_at: string;
}

export interface RequestOffer {
  id: string;
  request_id: string;
  vendor_name: string;
  quotation_amount: number;
  quantity: number;
  submitted_by: string;
  submitted_at: string;
}

export interface ApprovalAssignment {
  id: string;
  tenant_id: string;
  user_id: string;
  workflow_stage_id: string;
  scope_type: ApprovalScopeType;
  scope_id: string | null;
  threshold_max: number | null;
  created_at: string;
}

export interface ApprovalAction {
  id: string;
  request_id: string;
  workflow_stage_id: string;
  approver_id: string;
  acted_on_behalf_of: string | null;
  decision: ApprovalDecision;
  comment: string | null;
  acted_at: string;
}

export interface ApprovalDelegation {
  id: string;
  tenant_id: string;
  delegator_user_id: string;
  delegate_user_id: string;
  workflow_stage_id: string | null; // null = all stages the delegator owns
  starts_at: string;
  ends_at: string;
  status: DelegationStatus;
  created_at: string;
}

export interface PurchaseOrder {
  id: string;
  request_id: string;
  po_number: string;
  vendor_name: string;
  amount: number;
  generated_by: string;
  generated_at: string;
}

// Convenience shape returned by get_my_approval_queue() (joined RPC result) —
// see supabase/migrations/0002_approval_queue_rpc.sql
export interface QueuedRequest extends ERPRequest {
  cost_center: Pick<CostCenter, "id" | "name" | "project_code">;
  department: Pick<Department, "id" | "name">;
  requester: Pick<AppUser, "id" | "name">;
  current_stage: Pick<
    WorkflowStage,
    | "id"
    | "name"
    | "approver_role"
    | "threshold_amount"
    | "requires_offer_entry"
    | "requires_offer_selection"
    | "blocks_offer_submitter_approval"
  >;
  acting_on_behalf_of: Pick<AppUser, "id" | "name"> | null;
  // Multi-offer model: all competing quotes on file for this request, used
  // while it's at the offer-entry / offer-selection stages -- see
  // OfferEntry.tsx and OfferApprovalPO.tsx.
  offers?: RequestOffer[];
  // The offer chosen as the winner once Budget Controller has decided --
  // present on every stage after selection (Finance / PM / GM).
  selected_offer?: Pick<RequestOffer, "id" | "vendor_name" | "quotation_amount"> | null;
  // TODO: superseded by `offers`/`selected_offer` under the multi-offer
  // model -- confirm nothing else still reads this before removing it.
  latest_offer: Pick<RequestOffer, "vendor_name" | "quotation_amount" | "submitted_by"> | null;
}

export interface PoEditChange {
  old: unknown;
  new: unknown;
}

export interface PoEdit {
  id: string;
  edited_at: string;
  reason: string;
  changes: Record<string, PoEditChange>;
  editor: Pick<AppUser, "id" | "name">;
}

// Convenience shape returned by get_my_purchase_orders() — see the
// finance_po_access_and_edit_audit migration.
export interface FinancePurchaseOrder {
  id: string;
  request_id: string;
  po_number: string;
  vendor_name: string;
  amount: number;
  generated_by: Pick<AppUser, "id" | "name">;
  generated_at: string;
  request: Pick<ERPRequest, "id" | "item_description" | "quantity" | "status">;
  requester: Pick<AppUser, "id" | "name">;
  department: Pick<Department, "id" | "name">;
  cost_center: Pick<CostCenter, "id" | "name" | "project_code">;
  project_sap_no: string | null;
  payment_conditions: string | null;
  terms_of_delivery: string | null;
  edit_count: number;
  last_edited_at: string | null;
  last_edited_by: Pick<AppUser, "id" | "name"> | null;
}