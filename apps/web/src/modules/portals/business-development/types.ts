// Business Development & Proposal - Core Types
// Multi-tenant + RLS pattern (matches IT Support & Material Classification)

export type LeadStatus = 'new' | 'contacted' | 'qualified' | 'unqualified' | 'converted' | 'lost';
export type OpportunityStage = 'identification' | 'qualification' | 'proposal' | 'negotiation' | 'closed_won' | 'closed_lost';
export type ProposalStatus = 'draft' | 'in_review' | 'pending_approval' | 'approved' | 'sent' | 'accepted' | 'rejected' | 'expired';
export type TenderStatus = 'open' | 'submitted' | 'under_evaluation' | 'awarded' | 'lost' | 'cancelled';
export type ActivityType = 'call' | 'meeting' | 'email' | 'note' | 'site_visit';

export interface BDLead {
  id: string;
  tenant_id: string;
  lead_no: string; // BD-L-2026-0001
  company_name: string;
  contact_name: string;
  email?: string;
  phone?: string;
  source_id: string; // FK bd_lead_sources
  status: LeadStatus;
  estimated_value?: number;
  currency?: string;
  assigned_to?: string; // auth.users.id
  notes?: string;
  converted_to_opportunity_id?: string;
  created_by: string;
  created_at: string;
  updated_at: string;
}

export interface BDLeadSource {
  id: string;
  tenant_id: string;
  name: string; // Referral, Website, Cold Call, Tender Portal
  description?: string;
  is_active: boolean;
}

export interface BDOpportunity {
  id: string;
  tenant_id: string;
  opportunity_no: string; // BD-O-2026-0001
  title: string;
  client_id: string; // FK bd_clients
  lead_id?: string;
  stage: OpportunityStage;
  probability: number; // 0-100
  estimated_value: number;
  currency: string;
  expected_close_date?: string;
  assigned_to?: string;
  source_id?: string;
  description?: string;
  created_by: string;
  created_at: string;
  updated_at: string;
}

export interface BDOpportunityStage {
  id: string;
  tenant_id: string;
  stage: OpportunityStage;
  label: string;
  order_index: number;
  probability_default: number;
  color: string;
  is_active: boolean;
}

export interface BDClient {
  id: string;
  tenant_id: string;
  name: string;
  category_id?: string; // FK bd_client_categories
  industry?: string;
  website?: string;
  phone?: string;
  email?: string;
  address?: string;
  tax_no?: string;
  is_active: boolean;
  created_at: string;
}

export interface BDClientCategory {
  id: string;
  tenant_id: string;
  name: string;
  description?: string;
  is_active: boolean;
}

export interface BDContact {
  id: string;
  tenant_id: string;
  client_id: string;
  first_name: string;
  last_name: string;
  email?: string;
  phone?: string;
  position?: string;
  is_primary: boolean;
  created_at: string;
}

export interface BDProposal {
  id: string;
  tenant_id: string;
  proposal_no: string; // BD-P-2026-0001
  title: string;
  opportunity_id?: string;
  client_id: string;
  type_id?: string; // FK bd_proposal_types
  status: ProposalStatus;
  version: number;
  currency: string;
  total_value: number;
  valid_until?: string;
  assigned_to?: string;
  template_id?: string;
  content?: string; // JSON or markdown for proposal body
  created_by: string;
  created_at: string;
  updated_at: string;
}

export interface BDProposalType {
  id: string;
  tenant_id: string;
  name: string;
  description?: string;
  is_active: boolean;
}

export interface BDTender {
  id: string;
  tenant_id: string;
  tender_no: string; // External ref + internal
  title: string;
  client_id?: string;
  type_id?: string;
  status: TenderStatus;
  submission_deadline?: string;
  estimated_value?: number;
  currency?: string;
  portal_url?: string;
  assigned_to?: string;
  description?: string;
  created_by: string;
  created_at: string;
  updated_at: string;
}

export interface BDActivity {
  id: string;
  tenant_id: string;
  type: ActivityType;
  subject: string;
  description?: string;
  client_id?: string;
  lead_id?: string;
  opportunity_id?: string;
  proposal_id?: string;
  activity_date: string;
  created_by: string;
  created_at: string;
}

export interface BDRevenueForecast {
  tenant_id: string;
  month: string; // YYYY-MM
  opportunity_stage: OpportunityStage;
  weighted_value: number;
  raw_value: number;
  count: number;
}
