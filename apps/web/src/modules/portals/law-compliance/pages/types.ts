// Law and Compliance - Core Types
export type ContractStatus = 'draft' | 'pending_approval' | 'active' | 'expired' | 'terminated';
export type CaseStatus = 'open' | 'in_progress' | 'closed' | 'on_hold';
export type ComplianceStatus = 'compliant' | 'non_compliant' | 'pending' | 'overdue';

export interface LawContractType {
  id: string;
  tenant_id: string;
  name: string;
  description: string | null;
  is_active: boolean;
  created_at: string;
}

export interface LawCaseType {
  id: string;
  tenant_id: string;
  name: string;
  description: string | null;
  is_active: boolean;
}

export interface LawContract {
  id: string;
  tenant_id: string;
  contract_no: string;
  title: string;
  type_id: string | null;
  party_name: string;
  status: ContractStatus;
  start_date: string | null;
  end_date: string | null;
  value: number | null;
  currency: string;
  created_at: string;
  updated_at: string;
  law_contract_types?: { name: string } | null;
}

export interface LawCase {
  id: string;
  tenant_id: string;
  case_no: string;
  title: string;
  type_id: string | null;
  status: CaseStatus;
  description: string | null;
  lawyer_name: string | null;
  created_at: string;
  law_case_types?: { name: string } | null;
}

export interface ComplianceItem {
  id: string;
  tenant_id: string;
  title: string;
  regulation: string | null;
  status: ComplianceStatus;
  due_date: string | null;
  owner: string | null;
  created_at: string;
}
