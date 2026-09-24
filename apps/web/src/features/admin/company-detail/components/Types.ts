export interface TenantRow {
  id: string;
  name: string;
  status: 'pending' | 'active' | 'suspended';
  created_at: string;
  industry_template: string;
  contact_name: string | null;
  contact_email: string | null;
  contact_phone: string | null;
  tax_id: string | null;
  address: string | null;
  country: string;
  plan: string;
  subscription_status: string;
  seat_limit: number | null;
  trial_ends_at: string | null;
  renews_at: string | null;
  status_changed_at: string | null;
  read_only: boolean;
  read_only_reason: string | null;
  read_only_since: string | null;
  updated_at: string;
}

export interface Profile {
  tenant: TenantRow;
  seats: { limit: number | null; members: number; pending_invites: number };
  activity: {
    modules: number;
    requests_30d: number;
    last_request_at: string | null;
    last_sign_in_at: string | null;
    company_admins: { name: string; email: string }[];
  };
  last_status_event: { action: string; reason: string | null; created_at: string; actor_email: string | null } | null;
  recent_events: {
    id: string;
    action: string;
    reason: string | null;
    created_at: string;
    actor_email: string | null;
    mfa_verified: boolean;
  }[];
  notes_count: number;
}

export interface Note {
  id: string;
  body: string;
  author_email: string | null;
  created_at: string;
}

export interface CountRow {
  count: number;
  [key: string]: string | number;
}

export interface Analytics {
  requests_by_status: CountRow[];
  requests_by_month: CountRow[];
  purchase_orders: { count: number; total_value: number };
  members_by_department: CountRow[];
  top_requesters: CountRow[];
}

export interface WorkflowStage {
  id: string;
  name: string;
  sequence_order: number;
  approver_role: string;
  threshold_amount: number | null;
  applies_to: string;
}

export type ProfileDraft = {
  name: string;
  contact_name: string;
  contact_email: string;
  contact_phone: string;
  tax_id: string;
  address: string;
  country: string;
  plan: string;
  subscription_status: string;
  seat_limit: string;
  trial_ends_at: string;
  renews_at: string;
};