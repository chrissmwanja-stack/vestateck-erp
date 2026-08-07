// Sustainability Types
export type MetricType = 'carbon' | 'energy' | 'water' | 'waste';
export type InitiativeStatus = 'planned' | 'in_progress' | 'completed' | 'on_hold';
export type AuditStatus = 'scheduled' | 'in_progress' | 'completed';

export interface MetricTypeDef { id: string; tenant_id: string; name: string; unit: string; type: MetricType; is_active: boolean; }
export interface InitiativeCategory { id: string; tenant_id: string; name: string; description: string | null; is_active: boolean; }

export interface SustainabilityMetric {
  id: string;
  tenant_id: string;
  metric_type_id: string | null;
  type: MetricType;
  value: number;
  unit: string | null;
  recorded_date: string;
  notes: string | null;
  created_at: string;
  metric_types?: { name: string; unit: string } | null;
}

export interface Initiative {
  id: string;
  tenant_id: string;
  title: string;
  category_id: string | null;
  status: InitiativeStatus;
  target_value: number | null;
  current_value: number | null;
  owner: string | null;
  start_date: string | null;
  end_date: string | null;
  created_at: string;
  initiative_categories?: { name: string } | null;
}

export interface Audit {
  id: string;
  tenant_id: string;
  title: string;
  type: string | null;
  status: AuditStatus;
  audit_date: string | null;
  findings: string | null;
  created_at: string;
}

export interface Certification {
  id: string;
  tenant_id: string;
  name: string;
  standard: string | null;
  issue_date: string | null;
  expiry_date: string | null;
  status: string;
  created_at: string;
}
