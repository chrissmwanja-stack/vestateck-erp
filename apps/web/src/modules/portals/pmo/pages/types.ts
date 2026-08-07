// PMO Types
export type ProjectStatus = 'not_started' | 'in_progress' | 'on_hold' | 'completed' | 'cancelled';
export type TaskStatus = 'todo' | 'in_progress' | 'review' | 'done';
export type TaskPriority = 'low' | 'medium' | 'high' | 'critical';

export interface ProjectCategory { id: string; tenant_id: string; name: string; description: string | null; is_active: boolean; }
export interface TaskType { id: string; tenant_id: string; name: string; description: string | null; is_active: boolean; }

export interface Project {
  id: string;
  tenant_id: string;
  project_no: string;
  name: string;
  category_id: string | null;
  client_name: string | null;
  status: ProjectStatus;
  budget: number | null;
  currency: string;
  start_date: string | null;
  end_date: string | null;
  manager_id: string | null;
  created_at: string;
  project_categories?: { name: string } | null;
}

export interface Task {
  id: string;
  tenant_id: string;
  project_id: string | null;
  title: string;
  type_id: string | null;
  status: TaskStatus;
  priority: TaskPriority;
  assignee_id: string | null;
  due_date: string | null;
  created_at: string;
  projects?: { name: string } | null;
}

export interface Milestone {
  id: string;
  tenant_id: string;
  project_id: string;
  title: string;
  due_date: string | null;
  completion_percent: number;
  status: string;
  created_at: string;
}
