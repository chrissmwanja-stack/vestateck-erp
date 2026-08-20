import * as React from "react";
import {
  Folder,
  Description,
  AssignmentTurnedIn,
  BarChart,
  AdminPanelSettings,
  ReceiptLong,
  Build,
  People,
  Gavel,
  Balance,
  Security,
  Badge,
  WorkHistory,
  Payments,
  School,
  TrendingUp,
  Handshake,
  RequestQuote,
  PrecisionManufacturing,
  Engineering,
  LocalGasStation,
  Assignment,
  Flag,
  Groups,
  Nature,
  Verified,
  FactCheck,
  Lightbulb,
  ContactPage,
  CalendarMonth,
} from "@mui/icons-material";
import { BD_ADMIN_ROLES } from "./business-development/access";

interface TreeNode {
  id: string;
  label: string;
  icon?: React.ReactNode;
  to?: string;
  children?: TreeNode[];
  disabled?: boolean;
  tooltip?: string;
  // See the matching field on ModuleTree.tsx's own TreeNode -- this local
  // copy just needs the field to exist so node literals here can set it and
  // stay structurally assignable to ModuleTree's TreeNode[].
  requiredRoles?: readonly string[];
}

// Law and Compliance - modeled on MAKS Legal module
export const lawComplianceNodes: TreeNode[] = [
  {
    id: "law-dashboard",
    label: "Dashboard",
    icon: <BarChart fontSize="small" />,
    to: "/law-compliance/dashboard",
  },
  {
    id: "contracts",
    label: "Contract Management",
    icon: <Description fontSize="small" />,
    children: [
      { id: "contract-list", label: "Contracts", icon: <ReceiptLong fontSize="small" />, to: "/law-compliance/contracts" },
      { id: "contract-new", label: "New Contract", icon: <Description fontSize="small" />, to: "/law-compliance/contracts/new" },
      { id: "contract-approvals", label: "Contract Approvals", icon: <AssignmentTurnedIn fontSize="small" />, to: "/law-compliance/contracts/approvals" },
    ],
  },
  {
    id: "legal-cases",
    label: "Legal Cases",
    icon: <Gavel fontSize="small" />,
    children: [
      { id: "case-list", label: "Cases", icon: <Balance fontSize="small" />, to: "/law-compliance/cases" },
      { id: "case-hearings", label: "Hearings & Sessions", icon: <CalendarMonth fontSize="small" />, to: "/law-compliance/cases/hearings" },
    ],
  },
  {
    id: "compliance-tracking",
    label: "Compliance",
    icon: <Security fontSize="small" />,
    children: [
      { id: "compliance-register", label: "Compliance Register", icon: <FactCheck fontSize="small" />, to: "/law-compliance/compliance/register" },
      { id: "regulatory-filings", label: "Regulatory Filings", icon: <ReceiptLong fontSize="small" />, to: "/law-compliance/compliance/filings" },
    ],
  },
  {
    id: "law-reports",
    label: "Reports",
    icon: <BarChart fontSize="small" />,
    children: [
      { id: "contract-expiry-report", label: "Contract Expiry Report", icon: <BarChart fontSize="small" />, to: "/law-compliance/reports/expiry" },
      { id: "case-status-report", label: "Case Status Report", icon: <BarChart fontSize="small" />, to: "/law-compliance/reports/cases" },
    ],
  },
  {
    id: "law-admin",
    label: "Admin",
    icon: <AdminPanelSettings fontSize="small" />,
    children: [
      { id: "contract-types", label: "Contract Types", icon: <ReceiptLong fontSize="small" />, to: "/law-compliance/admin/contract-types" },
      { id: "case-types", label: "Case Types", icon: <ReceiptLong fontSize="small" />, to: "/law-compliance/admin/case-types" },
    ],
  },
];

// Human Resources
export const hrNodes: TreeNode[] = [
  {
    id: "hr-dashboard",
    label: "Dashboard",
    icon: <BarChart fontSize="small" />,
    to: "/hr/dashboard",
  },
  {
    id: "employee-mgmt",
    label: "Employee Management",
    icon: <Badge fontSize="small" />,
    children: [
      { id: "employee-list", label: "Employees", icon: <People fontSize="small" />, to: "/hr/employees" },
      { id: "employee-new", label: "New Employee", icon: <ContactPage fontSize="small" />, to: "/hr/employees/new" },
      { id: "org-chart", label: "Organization Chart", icon: <Groups fontSize="small" />, to: "/hr/org-chart" },
    ],
  },
  {
    id: "attendance-leave",
    label: "Attendance & Leave",
    icon: <CalendarMonth fontSize="small" />,
    children: [
      { id: "attendance", label: "Attendance", icon: <FactCheck fontSize="small" />, to: "/hr/attendance" },
      { id: "leave-requests", label: "Leave Requests", icon: <AssignmentTurnedIn fontSize="small" />, to: "/hr/leaves" },
      { id: "leave-approvals", label: "Leave Approvals", icon: <AssignmentTurnedIn fontSize="small" />, to: "/hr/leaves/approvals" },
    ],
  },
  {
    id: "recruitment",
    label: "Recruitment",
    icon: <WorkHistory fontSize="small" />,
    children: [
      { id: "job-postings", label: "Job Postings", icon: <Description fontSize="small" />, to: "/hr/recruitment/jobs" },
      { id: "applications", label: "Applications", icon: <Assignment fontSize="small" />, to: "/hr/recruitment/applications" },
    ],
  },
  {
    id: "payroll",
    label: "Payroll",
    icon: <Payments fontSize="small" />,
    children: [
      { id: "payroll-runs", label: "Payroll Runs", icon: <Payments fontSize="small" />, to: "/hr/payroll" },
      { id: "compensation-history", label: "Compensation History", icon: <ReceiptLong fontSize="small" />, to: "/hr/payroll/compensation-history" },
      { id: "payroll-approvals", label: "Payroll Approvals", icon: <AssignmentTurnedIn fontSize="small" />, to: "/hr/payroll/approvals" },
    ],
  },
  {
    id: "performance",
    label: "Performance",
    icon: <TrendingUp fontSize="small" />,
    children: [
      { id: "appraisals", label: "Appraisals", icon: <Assignment fontSize="small" />, to: "/hr/performance/appraisals" },
      { id: "training", label: "Training & Development", icon: <School fontSize="small" />, to: "/hr/training" },
    ],
  },
  {
    id: "hr-reports",
    label: "Reports",
    icon: <BarChart fontSize="small" />,
    children: [
      { id: "headcount-report", label: "Headcount Report", icon: <BarChart fontSize="small" />, to: "/hr/reports/headcount" },
      { id: "attendance-report", label: "Attendance Report", icon: <BarChart fontSize="small" />, to: "/hr/reports/attendance" },
    ],
  },
  {
    id: "hr-admin",
    label: "Admin",
    icon: <AdminPanelSettings fontSize="small" />,
    children: [
      { id: "departments", label: "Departments", icon: <ReceiptLong fontSize="small" />, to: "/hr/admin/departments" },
      { id: "positions", label: "Positions", icon: <ReceiptLong fontSize="small" />, to: "/hr/admin/positions" },
      { id: "leave-types", label: "Leave Types", icon: <ReceiptLong fontSize="small" />, to: "/hr/admin/leave-types" },
    ],
  },
];

// Business Development and Proposal - FULL SHELL (expanded)
export const businessDevNodes: TreeNode[] = [
  {
    id: "bd-dashboard",
    label: "Dashboard",
    icon: <BarChart fontSize="small" />,
    to: "/business-development/dashboard",
  },
  {
    id: "lead-mgmt",
    label: "Lead Management",
    icon: <ContactPage fontSize="small" />,
    children: [
      { id: "leads", label: "Leads", icon: <ReceiptLong fontSize="small" />, to: "/business-development/leads" },
      { id: "leads-new", label: "New Lead", icon: <Description fontSize="small" />, to: "/business-development/leads/new" },
      { id: "leads-qualified", label: "Qualified Leads", icon: <Verified fontSize="small" />, to: "/business-development/leads/qualified" },
      { id: "leads-import", label: "Import Leads", icon: <Folder fontSize="small" />, to: "/business-development/leads/import" },
    ],
  },
  {
    id: "opportunity-mgmt",
    label: "Opportunity Management",
    icon: <TrendingUp fontSize="small" />,
    children: [
      { id: "opportunities", label: "Opportunities", icon: <Lightbulb fontSize="small" />, to: "/business-development/opportunities" },
      { id: "opportunity-pipeline", label: "Pipeline Board", icon: <BarChart fontSize="small" />, to: "/business-development/opportunities/pipeline" },
      { id: "opportunity-new", label: "New Opportunity", icon: <Description fontSize="small" />, to: "/business-development/opportunities/new" },
    ],
  },
  {
    id: "proposals",
    label: "Proposals",
    icon: <RequestQuote fontSize="small" />,
    children: [
      { id: "proposal-list", label: "Proposals", icon: <Description fontSize="small" />, to: "/business-development/proposals" },
      { id: "proposal-new", label: "New Proposal", icon: <Description fontSize="small" />, to: "/business-development/proposals/new" },
      { id: "proposal-approvals", label: "Proposal Approvals", icon: <AssignmentTurnedIn fontSize="small" />, to: "/business-development/proposals/approvals", requiredRoles: BD_ADMIN_ROLES },
      { id: "proposal-templates", label: "Templates", icon: <Folder fontSize="small" />, to: "/business-development/proposals/templates" },
      { id: "proposal-tracking", label: "Tracking", icon: <FactCheck fontSize="small" />, to: "/business-development/proposals/tracking" },
    ],
  },
  {
    id: "client-mgmt",
    label: "Client Management",
    icon: <Handshake fontSize="small" />,
    children: [
      { id: "clients", label: "Clients", icon: <Groups fontSize="small" />, to: "/business-development/clients" },
      { id: "client-contacts", label: "Contacts", icon: <ContactPage fontSize="small" />, to: "/business-development/clients/contacts" },
      { id: "client-activities", label: "Activities & Meetings", icon: <CalendarMonth fontSize="small" />, to: "/business-development/clients/activities" },
    ],
  },
  {
    id: "tender-mgmt",
    label: "Tender Management",
    icon: <Gavel fontSize="small" />,
    children: [
      { id: "tenders", label: "Tenders", icon: <ReceiptLong fontSize="small" />, to: "/business-development/tenders" },
      { id: "tender-new", label: "New Tender", icon: <Description fontSize="small" />, to: "/business-development/tenders/new" },
      { id: "tender-submissions", label: "Submissions", icon: <AssignmentTurnedIn fontSize="small" />, to: "/business-development/tenders/submissions" },
      { id: "tender-tracking", label: "Tracking", icon: <BarChart fontSize="small" />, to: "/business-development/tenders/tracking" },
    ],
  },
  {
    id: "bd-reports",
    label: "Reports",
    icon: <BarChart fontSize="small" />,
    children: [
      { id: "pipeline-report", label: "Pipeline Report", icon: <BarChart fontSize="small" />, to: "/business-development/reports/pipeline" },
      { id: "win-loss-report", label: "Win/Loss Report", icon: <BarChart fontSize="small" />, to: "/business-development/reports/win-loss" },
      { id: "proposal-status-report", label: "Proposal Status", icon: <BarChart fontSize="small" />, to: "/business-development/reports/proposal-status" },
      { id: "lead-source-report", label: "Lead Source Report", icon: <BarChart fontSize="small" />, to: "/business-development/reports/lead-source" },
      { id: "revenue-forecast", label: "Revenue Forecast", icon: <TrendingUp fontSize="small" />, to: "/business-development/reports/forecast" },
    ],
  },
  {
    id: "bd-admin",
    label: "Admin",
    icon: <AdminPanelSettings fontSize="small" />,
    // Gating the parent is enough -- filterNodesByAccess drops a node (and
    // never walks its children) as soon as the node itself fails the role
    // check, so the seven lookup-table screens below inherit this.
    requiredRoles: BD_ADMIN_ROLES,
    children: [
      { id: "lead-sources", label: "Lead Sources", icon: <ReceiptLong fontSize="small" />, to: "/business-development/admin/lead-sources" },
      { id: "lead-statuses", label: "Lead Statuses", icon: <ReceiptLong fontSize="small" />, to: "/business-development/admin/lead-statuses" },
      { id: "opportunity-stages", label: "Opportunity Stages", icon: <Flag fontSize="small" />, to: "/business-development/admin/opportunity-stages" },
      { id: "proposal-types", label: "Proposal Types", icon: <ReceiptLong fontSize="small" />, to: "/business-development/admin/proposal-types" },
      { id: "proposal-statuses", label: "Proposal Statuses", icon: <ReceiptLong fontSize="small" />, to: "/business-development/admin/proposal-statuses" },
      { id: "client-categories", label: "Client Categories", icon: <ReceiptLong fontSize="small" />, to: "/business-development/admin/client-categories" },
      { id: "tender-types", label: "Tender Types", icon: <ReceiptLong fontSize="small" />, to: "/business-development/admin/tender-types" },
    ],
  },
];

// Machine Operation
export const machineOperationNodes: TreeNode[] = [
  {
    id: "machine-dashboard",
    label: "Dashboard",
    icon: <BarChart fontSize="small" />,
    to: "/machine-operation/dashboard",
  },
  {
    id: "equipment",
    label: "Equipment Management",
    icon: <PrecisionManufacturing fontSize="small" />,
    children: [
      { id: "equipment-list", label: "Equipment List", icon: <ReceiptLong fontSize="small" />, to: "/machine-operation/equipment" },
      { id: "equipment-assignment", label: "Assignments", icon: <Assignment fontSize="small" />, to: "/machine-operation/equipment/assignments" },
    ],
  },
  {
    id: "maintenance",
    label: "Maintenance",
    icon: <Engineering fontSize="small" />,
    children: [
      { id: "maintenance-schedule", label: "Schedule", icon: <CalendarMonth fontSize="small" />, to: "/machine-operation/maintenance/schedule" },
      { id: "maintenance-requests", label: "Maintenance Requests", icon: <Build fontSize="small" />, to: "/machine-operation/maintenance/requests" },
      { id: "maintenance-history", label: "History", icon: <WorkHistory fontSize="small" />, to: "/machine-operation/maintenance/history" },
    ],
  },
  {
    id: "operation-logs",
    label: "Operation Logs",
    icon: <FactCheck fontSize="small" />,
    children: [
      { id: "daily-logs", label: "Daily Logs", icon: <Description fontSize="small" />, to: "/machine-operation/logs/daily" },
      { id: "fuel-consumption", label: "Fuel & Consumption", icon: <LocalGasStation fontSize="small" />, to: "/machine-operation/logs/fuel" },
    ],
  },
  {
    id: "machine-reports",
    label: "Reports",
    icon: <BarChart fontSize="small" />,
    children: [
      { id: "utilization-report", label: "Utilization Report", icon: <BarChart fontSize="small" />, to: "/machine-operation/reports/utilization" },
      { id: "downtime-report", label: "Downtime Report", icon: <BarChart fontSize="small" />, to: "/machine-operation/reports/downtime" },
    ],
  },
  {
    id: "machine-admin",
    label: "Admin",
    icon: <AdminPanelSettings fontSize="small" />,
    children: [
      { id: "machine-types", label: "Machine Types", icon: <ReceiptLong fontSize="small" />, to: "/machine-operation/admin/types" },
      { id: "maintenance-types", label: "Maintenance Types", icon: <ReceiptLong fontSize="small" />, to: "/machine-operation/admin/maintenance-types" },
    ],
  },
];

// PMO
export const pmoNodes: TreeNode[] = [
  {
    id: "pmo-dashboard",
    label: "Dashboard",
    icon: <BarChart fontSize="small" />,
    to: "/pmo/dashboard",
  },
  {
    id: "projects",
    label: "Projects",
    icon: <Folder fontSize="small" />,
    children: [
      { id: "project-list", label: "Projects", icon: <ReceiptLong fontSize="small" />, to: "/pmo/projects" },
      { id: "project-new", label: "New Project", icon: <Description fontSize="small" />, to: "/pmo/projects/new" },
    ],
  },
  {
    id: "project-planning",
    label: "Planning",
    icon: <Assignment fontSize="small" />,
    children: [
      { id: "tasks", label: "Tasks", icon: <Assignment fontSize="small" />, to: "/pmo/tasks" },
      { id: "milestones", label: "Milestones", icon: <Flag fontSize="small" />, to: "/pmo/milestones" },
      { id: "gantt", label: "Gantt Chart", icon: <CalendarMonth fontSize="small" />, to: "/pmo/gantt" },
    ],
  },
  {
    id: "resource-mgmt",
    label: "Resources",
    icon: <Groups fontSize="small" />,
    children: [
      { id: "resource-allocation", label: "Allocation", icon: <People fontSize="small" />, to: "/pmo/resources/allocation" },
      { id: "resource-utilization", label: "Utilization", icon: <BarChart fontSize="small" />, to: "/pmo/resources/utilization" },
    ],
  },
  {
    id: "pmo-reports",
    label: "Reports",
    icon: <BarChart fontSize="small" />,
    children: [
      { id: "project-status", label: "Project Status", icon: <BarChart fontSize="small" />, to: "/pmo/reports/status" },
      { id: "budget-vs-actual", label: "Budget vs Actual", icon: <BarChart fontSize="small" />, to: "/pmo/reports/budget" },
    ],
  },
  {
    id: "pmo-admin",
    label: "Admin",
    icon: <AdminPanelSettings fontSize="small" />,
    children: [
      { id: "project-categories", label: "Project Categories", icon: <ReceiptLong fontSize="small" />, to: "/pmo/admin/categories" },
      { id: "task-types", label: "Task Types", icon: <ReceiptLong fontSize="small" />, to: "/pmo/admin/task-types" },
    ],
  },
];

// Sustainability and Business Excellence
export const sustainabilityNodes: TreeNode[] = [
  {
    id: "sustain-dashboard",
    label: "Dashboard",
    icon: <BarChart fontSize="small" />,
    to: "/sustainability/dashboard",
  },
  {
    id: "sustain-metrics",
    label: "Sustainability Metrics",
    icon: <Nature fontSize="small" />,
    children: [
      { id: "carbon-footprint", label: "Carbon Footprint", icon: <Nature fontSize="small" />, to: "/sustainability/metrics/carbon" },
      { id: "energy-consumption", label: "Energy Consumption", icon: <Lightbulb fontSize="small" />, to: "/sustainability/metrics/energy" },
      { id: "waste-management", label: "Waste Management", icon: <ReceiptLong fontSize="small" />, to: "/sustainability/metrics/waste" },
    ],
  },
  {
    id: "initiatives",
    label: "Initiatives",
    icon: <Lightbulb fontSize="small" />,
    children: [
      { id: "initiative-list", label: "Initiatives", icon: <Flag fontSize="small" />, to: "/sustainability/initiatives" },
      { id: "initiative-new", label: "New Initiative", icon: <Description fontSize="small" />, to: "/sustainability/initiatives/new" },
    ],
  },
  {
    id: "audits-cert",
    label: "Audits & Certifications",
    icon: <Verified fontSize="small" />,
    children: [
      { id: "audits", label: "Audits", icon: <FactCheck fontSize="small" />, to: "/sustainability/audits" },
      { id: "certifications", label: "Certifications", icon: <Verified fontSize="small" />, to: "/sustainability/certifications" },
    ],
  },
  {
    id: "sustain-reports",
    label: "Reports",
    icon: <BarChart fontSize="small" />,
    children: [
      { id: "sustain-report", label: "Sustainability Report", icon: <BarChart fontSize="small" />, to: "/sustainability/reports/sustainability" },
      { id: "excellence-report", label: "Excellence Scorecard", icon: <BarChart fontSize="small" />, to: "/sustainability/reports/excellence" },
    ],
  },
  {
    id: "sustain-admin",
    label: "Admin",
    icon: <AdminPanelSettings fontSize="small" />,
    children: [
      { id: "metric-types", label: "Metric Types", icon: <ReceiptLong fontSize="small" />, to: "/sustainability/admin/metric-types" },
      { id: "initiative-categories", label: "Initiative Categories", icon: <ReceiptLong fontSize="small" />, to: "/sustainability/admin/categories" },
    ],
  },
];
