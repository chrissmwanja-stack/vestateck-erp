// Row shapes for the insurance tables and views, as the UI reads them.
// The generated Database types predate these tables, so they are typed here.

export type PolicyStatus = 'draft' | 'active' | 'renewed';
export type ClaimStatus = 'notified' | 'assessing' | 'approved' | 'settled' | 'repudiated' | 'closed';

export interface ProductLine {
  id: string;
  code: string;
  name: string;
  class: 'general' | 'life' | 'health';
  is_active: boolean;
}

export interface Insurer {
  id: string;
  code: string;
  name: string;
  contact_name: string | null;
  contact_email: string | null;
  contact_phone: string | null;
  default_commission_rate_pct: number;
  is_active: boolean;
}

export interface InsClient {
  id: string;
  client_id: string;
  client_type: 'individual' | 'corporate';
  tax_id: string | null;
  risk_rating: 'low' | 'medium' | 'high';
  kyc_status: 'pending' | 'verified' | 'expired';
  bd_clients: { name: string; email: string | null; phone: string | null } | null;
}

export interface Policy {
  id: string;
  policy_no: string;
  status: PolicyStatus;
  client_id: string;
  insurer_id: string;
  product_line_id: string;
  inception_date: string;
  expiry_date: string;
  sum_insured: number;
  currency: string;
  gross_premium: number;
  commission_rate_pct: number;
  commission_amount: number | null;
  net_premium_to_insurer: number | null;
  bound_at: string | null;
  journal_entry_id: string | null;
  renewal_of_id: string | null;
  risk_description: string | null;
  notes: string | null;
  ins_clients?: { bd_clients: { name: string } | null } | null;
  ins_insurers?: { name: string } | null;
  ins_product_lines?: { name: string } | null;
}

export interface Claim {
  id: string;
  claim_no: string;
  policy_id: string;
  status: ClaimStatus;
  loss_date: string;
  notified_date: string;
  loss_description: string;
  insurer_claim_ref: string | null;
  reserve_amount: number;
  approved_amount: number | null;
  paid_amount: number;
  settled_at: string | null;
  created_at: string;
  ins_policies?: {
    policy_no: string;
    sum_insured: number;
    currency: string;
    ins_clients?: { bd_clients: { name: string } | null } | null;
  } | null;
}

export interface ClaimEvent {
  id: string;
  from_status: ClaimStatus | null;
  to_status: ClaimStatus;
  note: string | null;
  created_at: string;
}

export interface RenewalRow {
  policy_id: string;
  policy_no: string;
  client_name: string;
  insurer_name: string;
  product_name: string;
  inception_date: string;
  expiry_date: string;
  days_to_expiry: number;
  gross_premium: number;
  commission_rate_pct: number;
  currency: string;
  renewal_draft_id: string | null;
}
