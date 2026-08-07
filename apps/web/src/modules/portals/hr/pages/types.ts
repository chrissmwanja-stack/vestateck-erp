// HR Module - Core Types
// Multi-tenant pattern

export type EmploymentStatus = 'active' | 'on_leave' | 'terminated' | 'resigned';
export type LeaveStatus = 'pending' | 'approved' | 'rejected' | 'cancelled';
export type AttendanceStatus = 'present' | 'absent' | 'late' | 'on_leave';

export interface HRPosition {
  id: string;
  tenant_id: string;
  title: string;
  department_id?: string | null;
  description?: string | null;
  is_active: boolean;
  created_at: string;
}

export interface HRDepartment {
  id: string;
  tenant_id: string;
  name: string;
  parent_id?: string | null;
  is_active: boolean;
}

export interface HRLeaveType {
  id: string;
  tenant_id: string;
  name: string; // Annual, Sick, Maternity, Paternity, Unpaid
  description?: string | null;
  days_per_year: number;
  is_active: boolean;
  created_at: string;
}

export interface HREmployee {
  id: string;
  tenant_id: string;
  employee_no: string; // HR-EMP-2026-0001
  first_name: string;
  last_name: string;
  email: string;
  phone?: string | null;
  department_id?: string | null;
  position_id?: string | null;
  manager_id?: string | null;
  employment_status: EmploymentStatus;
  hire_date?: string | null;
  is_active: boolean;
  created_at: string;
  updated_at: string;
  hr_departments?: { name: string } | null;
  hr_positions?: { title: string } | null;
}

export interface HRLeaveRequest {
  id: string;
  tenant_id: string;
  employee_id: string;
  leave_type_id: string;
  start_date: string;
  end_date: string;
  days: number;
  reason?: string | null;
  status: LeaveStatus;
  approver_id?: string | null;
  created_at: string;
  hr_leave_types?: { name: string } | null;
  hr_employees?: { first_name: string; last_name: string } | null;
}

export interface HRAttendance {
  id: string;
  tenant_id: string;
  employee_id: string;
  attendance_date: string;
  check_in?: string | null;
  check_out?: string | null;
  status: AttendanceStatus;
  notes?: string | null;
}

export interface HRJobPosting {
  id: string;
  tenant_id: string;
  title: string;
  department_id?: string | null;
  position_id?: string | null;
  description?: string | null;
  status: 'open' | 'closed' | 'on_hold';
  created_at: string;
}
