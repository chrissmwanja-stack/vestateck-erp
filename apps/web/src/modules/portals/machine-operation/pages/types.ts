// Machine Operation Types
export type EquipmentStatus = 'available' | 'in_use' | 'maintenance' | 'retired' | 'breakdown';
export type MaintenanceType = 'preventive' | 'corrective' | 'inspection';
export type MaintenanceStatus = 'scheduled' | 'in_progress' | 'completed' | 'cancelled';

export interface MachineType {
  id: string;
  tenant_id: string;
  name: string;
  description: string | null;
  is_active: boolean;
}

export interface Machine {
  id: string;
  tenant_id: string;
  machine_no: string;
  name: string;
  type_id: string | null;
  model: string | null;
  serial_number: string | null;
  status: EquipmentStatus;
  location: string | null;
  purchase_date: string | null;
  created_at: string;
  machine_types?: { name: string } | null;
}

export interface MaintenanceRequest {
  id: string;
  tenant_id: string;
  machine_id: string;
  type: MaintenanceType;
  description: string;
  status: MaintenanceStatus;
  requested_by: string | null;
  scheduled_date: string | null;
  completed_date: string | null;
  created_at: string;
  machines?: { name: string; machine_no: string } | null;
}

export interface OperationLog {
  id: string;
  tenant_id: string;
  machine_id: string;
  log_date: string;
  hours_used: number;
  operator_name: string | null;
  work_description: string | null;
  created_at: string;
}

export interface FuelLog {
  id: string;
  tenant_id: string;
  machine_id: string;
  log_date: string;
  fuel_liters: number;
  cost: number | null;
  created_at: string;
}
