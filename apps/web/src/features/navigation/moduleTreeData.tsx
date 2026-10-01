import {
  Folder,
  Description,
  AssignmentTurnedIn,
  ShoppingCart,
  BarChart,
  AdminPanelSettings,
  ReceiptLong,
  Build,
  AccountBalance,
  OpenInNew,
  AttachMoney,
  Payments,
  SupportAgent,
  Computer,
  Storage,
  VpnKey,
  MenuBook,
  People,
  Inventory2,
  ConfirmationNumber,
  Dashboard,
  LiveHelp,
  Security,
  Groups,
  Category,
  Timer,
  PriorityHigh,
  Business,
  Settings,
  Campaign,
  Flag,
  HealthAndSafety,
  Apartment,
  Checklist,
  PersonAdd,
  Rule,
} from "@mui/icons-material";
import {
  lawComplianceNodes,
  hrNodes,
  businessDevNodes,
  machineOperationNodes,
  pmoNodes,
  sustainabilityNodes,
} from "../../modules/portals/ShellConfigs";
import type { Portal, TreeNode } from "./types";

// IT Support - YOU ALREADY WORKED ON IT (keeping your simpler paths)
export const itSupportNodes: TreeNode[] = [
  {
    id: "it-dashboard",
    label: "Dashboard",
    icon: <Dashboard fontSize="small" />,
    to: "/it-support/dashboard",
  },
  {
    id: "service-operations",
    label: "Service Operations",
    icon: <SupportAgent fontSize="small" />,
    children: [
      { id: "new-ticket", label: "New Ticket", icon: <ConfirmationNumber fontSize="small" />, to: "/it-support/new-ticket" },
      { id: "my-tickets", label: "My Tickets", icon: <ReceiptLong fontSize="small" />, to: "/it-support/my-tickets" },
      { id: "all-tickets", label: "All Tickets", icon: <AssignmentTurnedIn fontSize="small" />, to: "/it-support/all-tickets" },
      { id: "ticket-approvals", label: "Ticket Approvals", icon: <AssignmentTurnedIn fontSize="small" />, to: "/it-support/approvals" },
      { id: "problem-management", label: "Problem Management", icon: <Build fontSize="small" />, to: "/it-support/problems" },
    ],
  },
  {
    id: "knowledge-management",
    label: "Knowledge Management",
    icon: <MenuBook fontSize="small" />,
    children: [
      { id: "kb-articles", label: "Knowledge Base", icon: <Description fontSize="small" />, to: "/it-support/kb" },
      { id: "faq", label: "FAQ", icon: <LiveHelp fontSize="small" />, to: "/it-support/faq" },
    ],
  },
  {
    id: "asset-management",
    label: "Asset Management",
    icon: <Computer fontSize="small" />,
    children: [
      { id: "hardware-inv", label: "Hardware Inventory", icon: <Computer fontSize="small" />, to: "/it-support/assets/hardware" },
      { id: "software-inv", label: "Software Inventory", icon: <Storage fontSize="small" />, to: "/it-support/assets/software" },
      { id: "license-tracking", label: "License Tracking", icon: <ReceiptLong fontSize="small" />, to: "/it-support/assets/licenses" },
      { id: "asset-assignments", label: "Asset Assignments", icon: <Inventory2 fontSize="small" />, to: "/it-support/assets/assignments" },
      { id: "asset-request", label: "Asset Request", icon: <ShoppingCart fontSize="small" />, to: "/it-support/assets/request" },
    ],
  },
  {
    id: "user-access",
    label: "User & Access",
    icon: <VpnKey fontSize="small" />,
    children: [
      { id: "access-requests", label: "Access Requests", icon: <Security fontSize="small" />, to: "/it-support/access/requests" },
      { id: "account-mgmt", label: "Account Management", icon: <People fontSize="small" />, to: "/it-support/access/accounts" },
      { id: "group-mgmt", label: "Group Management", icon: <Groups fontSize="small" />, to: "/it-support/access/groups" },
    ],
  },
  {
    id: "it-reports",
    label: "Reports",
    icon: <BarChart fontSize="small" />,
    children: [
      { id: "ticket-tracking", label: "Ticket Tracking", icon: <BarChart fontSize="small" />, to: "/it-support/reports/ticket-tracking" },
      { id: "sla-performance", label: "SLA Performance", icon: <Timer fontSize="small" />, to: "/it-support/reports/sla" },
      { id: "asset-report", label: "Asset Report", icon: <BarChart fontSize="small" />, to: "/it-support/reports/assets" },
    ],
  },
  {
    id: "it-admin",
    label: "Admin",
    icon: <AdminPanelSettings fontSize="small" />,
    children: [
      { id: "ticket-categories", label: "Ticket Categories", icon: <Category fontSize="small" />, to: "/it-support/admin/categories" },
      { id: "sla-policies", label: "SLA Policies", icon: <Timer fontSize="small" />, to: "/it-support/admin/slas" },
      { id: "priority-levels", label: "Priority Levels", icon: <PriorityHigh fontSize="small" />, to: "/it-support/admin/priorities" },
      { id: "support-teams", label: "Support Teams", icon: <Groups fontSize="small" />, to: "/it-support/admin/teams" },
    ],
  },
];

export const portals: Portal[] = [
  {
    id: "purchasing-logistics",
    label: "Purchasing and Logistics Operations",
    icon: <ShoppingCart fontSize="small" />,
    nodes: [
      {
        id: "purchasing-dashboard",
        label: "Dashboard",
        icon: <Dashboard fontSize="small" />,
        to: "/purchasing/dashboard",
        requiredModule: "procurement",
      },
      {
        id: "request-ops",
        label: "Request Operations",
        icon: <Folder fontSize="small" />,
        children: [
          { id: "new-request", label: "New Request", icon: <Description fontSize="small" />, to: "/requests/new" },
          { id: "my-requests", label: "My Requests", icon: <ReceiptLong fontSize="small" />, to: "/requests/my-requests" },
          { id: "req-approval", label: "Request Approval", icon: <AssignmentTurnedIn fontSize="small" />, to: "/approvals" },
          { id: "material-quantity", label: "Material Quantity", icon: <ReceiptLong fontSize="small" />, to: "/requests/material-quantity", requiredModule: "procurement" },
        ],
      },
      {
        id: "warehouse-ops",
        label: "Warehouse Operations",
        icon: <Inventory2 fontSize="small" />,
        requiredModule: "procurement",
        children: [
          { id: "goods-issue", label: "Goods Issue", icon: <ReceiptLong fontSize="small" />, to: "/warehouse/goods-issue" },
          { id: "stock-balances", label: "Stock Balances", icon: <Inventory2 fontSize="small" />, to: "/warehouse/stock-balances" },
        ],
      },
      {
        id: "offer-ops",
        label: "Offer Operations PO",
        icon: <Folder fontSize="small" />,
        requiredModule: "procurement",
        children: [
          { id: "offer-entry", label: "Offer Entry", icon: <ShoppingCart fontSize="small" />, to: "/offers/entry" },
          { id: "offer-approval-po", label: "Offer Approval PO", icon: <AssignmentTurnedIn fontSize="small" />, to: "/offers/approval-po" },
        ],
      },
      {
        id: "purchasing-ops",
        label: "Purchasing Operations",
        icon: <Folder fontSize="small" />,
        children: [
          { id: "procurement-info", label: "Procurement Info", icon: <OpenInNew fontSize="small" />, to: "/procurement/info", requiredModule: "procurement" },
          { id: "purchase-orders", label: "Purchase Orders", icon: <ReceiptLong fontSize="small" />, to: "/financial-management/purchase-orders", requiredAccess: "finance" },
        ],
      },
      {
        id: "reports",
        label: "Reports",
        icon: <Folder fontSize="small" />,
        requiredModule: "procurement",
        children: [
          { id: "req-tracking", label: "Request Tracking", icon: <BarChart fontSize="small" />, to: "/procurement/request-tracking" },
          { id: "vendor-eval", label: "Vendor Evaluation Report", icon: <BarChart fontSize="small" />, to: "/procurement/vendor-evaluation" },
        ],
      },
      {
        id: "new-material",
        label: "New Material Card",
        icon: <Folder fontSize="small" />,
        children: [
          { id: "new-material-req", label: "New Material Request", icon: <ReceiptLong fontSize="small" />, to: "/requests/new-material" },
          { id: "new-material-approval", label: "Material Request Approval", icon: <AssignmentTurnedIn fontSize="small" />, to: "/approvals/material-requests", requiredModule: "procurement" },
          { id: "new-material-report", label: "Material Request Report", icon: <BarChart fontSize="small" />, to: "/requests/material-request-report", requiredModule: "procurement" },
        ],
      },
      {
        id: "multiplexing",
        label: "Multiplexing Transaction",
        icon: <Folder fontSize="small" />,
        children: [
          { id: "send-invoice-approval", label: "Send Invoice for Approval", icon: <AssignmentTurnedIn fontSize="small" />, to: "/multiplexing/invoice-new" },
          { id: "pending-invoice", label: "Pending Invoice Approvals", icon: <AssignmentTurnedIn fontSize="small" />, to: "/multiplexing/approvals" },
        ],
      },
      {
        // Purchasing & Logistics → Administration. Ownership per the
        // admin-architecture rework (§11): material classification /
        // catalog / receipt are procurement configuration -- their RLS
        // writes are keyed to has_po_access(), so nav mirrors that tier
        // (requiredAccess "po"); warehouses writes are finance-team-keyed,
        // so that entry keeps the finance gate. Cost codes moved to the
        // Financial Management portal's Admin group.
        id: "admin",
        label: "Admin",
        icon: <AdminPanelSettings fontSize="small" />,
        children: [
          { id: "material-lookups-admin", label: "Material Classification", icon: <ReceiptLong fontSize="small" />, to: "/procurement/admin/material-lookups", requiredAccess: "po" },
          { id: "material-catalog-admin", label: "Material Catalog", icon: <ReceiptLong fontSize="small" />, to: "/procurement/admin/material-catalog", requiredAccess: "po" },
          { id: "material-receipt-admin", label: "Material Receipt", icon: <ReceiptLong fontSize="small" />, to: "/procurement/admin/material-receipt", requiredAccess: "po" },
          { id: "warehouses-admin", label: "Warehouses", icon: <Inventory2 fontSize="small" />, to: "/warehouse/admin/warehouses", requiredAccess: "finance" },
        ],
      },
      {
        id: "sap",
        label: "SAP Operations",
        icon: <AccountBalance fontSize="small" />,
        children: [{ id: "payment-approvals", label: "Payment Approvals", icon: <AssignmentTurnedIn fontSize="small" />, to: "/sap/payment-approvals", requiredAccess: "finance" }],
      },
    ],
  },
  {
    id: "financial-management",
    label: "Financial Management and Financial Reporting",
    icon: <AttachMoney fontSize="small" />,
    requiredAccess: "finance",
    nodes: [
      {
        id: "financial-dashboard",
        label: "Dashboard",
        icon: <Dashboard fontSize="small" />,
        to: "/financial-management/dashboard",
      },
      {
        id: "invoices-data-entry",
        label: "Invoices Data Entry",
        icon: <Folder fontSize="small" />,
        children: [
          { id: "supplier-invoice-po", label: "Supplier Invoice (PO Related)", icon: <ReceiptLong fontSize="small" />, to: "/financial-management/invoices/supplier-invoice-po" },
          { id: "supplier-invoice", label: "Supplier Invoice", icon: <ReceiptLong fontSize="small" />, to: "/financial-management/invoices/supplier-invoice-non-po" },
          { id: "receivable-invoice", label: "Receivable Invoice", icon: <ReceiptLong fontSize="small" />, to: "/financial-management/invoices/receivable-invoice" },
          { id: "edit-invoice", label: "Edit Invoice", icon: <ReceiptLong fontSize="small" />, to: "/financial-management/invoices/edit-invoice" },
        ],
      },
      { id: "expenditure-slips", label: "Expenditure Slips", icon: <ReceiptLong fontSize="small" />, to: "/financial-management/expenditure-slips" },
      {
        id: "cash-and-bank-operations",
        label: "Cash and Bank Operations",
        icon: <Folder fontSize="small" />,
        children: [
          { id: "cash-and-bank-payments", label: "Cash and Bank Payments", icon: <AccountBalance fontSize="small" />, to: "/financial-management/cash-bank-operations" },
          { id: "bank-reconciliation", label: "Bank Reconciliation", icon: <AccountBalance fontSize="small" />, to: "/financial-management/bank-reconciliation" },
        ],
      },
      { id: "petty-cash-floats", label: "Petty Cash Floats", icon: <Payments fontSize="small" />, to: "/financial-management/petty-cash-floats" },
      { id: "petty-cash-register", label: "Petty Cash Register", icon: <Payments fontSize="small" />, to: "/financial-management/petty-cash-register" },
      { id: "payroll-disbursement", label: "Payroll Disbursement", icon: <Payments fontSize="small" />, to: "/financial-management/payroll-disbursement" },
      {
        id: "financial-reports",
        label: "Reports",
        icon: <Folder fontSize="small" />,
        children: [
          { id: "financial-reports-summary", label: "Reports Summary", icon: <BarChart fontSize="small" />, to: "/financial-management/reports" },
          { id: "cost-transactions-inquiry", label: "Cost Transactions Inquiry", icon: <BarChart fontSize="small" />, to: "/financial-management/reports/cost-transactions-inquiry" },
          { id: "current-account-extract", label: "Current Account Extract", icon: <BarChart fontSize="small" />, to: "/financial-management/reports/current-account-extract" },
          { id: "trial-balance", label: "Trial Balance", icon: <BarChart fontSize="small" />, to: "/financial-management/reports/trial-balance" },
          { id: "general-ledger", label: "General Ledger", icon: <BarChart fontSize="small" />, to: "/financial-management/reports/general-ledger" },
          { id: "advance-payments", label: "Advance Payments", icon: <BarChart fontSize="small" />, to: "/financial-management/reports/advance-payments" },
          { id: "durations", label: "Durations", icon: <BarChart fontSize="small" />, to: "/financial-management/reports/durations" },
          { id: "payment-plan-report", label: "Payment Plan Report", icon: <BarChart fontSize="small" />, to: "/financial-management/reports/payment-plan" },
          { id: "vat-report", label: "VAT Report", icon: <BarChart fontSize="small" />, to: "/financial-management/reports/vat-report" },
          { id: "wht-report", label: "WHT Report", icon: <BarChart fontSize="small" />, to: "/financial-management/reports/wht-report" },
          { id: "paye-nssf-remittance", label: "PAYE/NSSF Remittance", icon: <BarChart fontSize="small" />, to: "/financial-management/reports/paye-nssf-remittance" },
        ],
      },
      {
        id: "upload",
        label: "Upload",
        icon: <Folder fontSize="small" />,
        children: [{ id: "mass-slip", label: "Mass Slip", icon: <Description fontSize="small" />, to: "/financial-management/upload/mass-slip" }],
      },
      {
        id: "financial-admin",
        label: "Admin",
        icon: <AdminPanelSettings fontSize="small" />,
        children: [
          { id: "accounts-admin", label: "Accounts", icon: <ReceiptLong fontSize="small" />, to: "/financial-management/admin/accounts" },
          { id: "chart-of-accounts-admin", label: "Chart of Accounts", icon: <ReceiptLong fontSize="small" />, to: "/financial-management/admin/chart-of-accounts" },
          { id: "accounting-periods-admin", label: "Accounting Periods", icon: <ReceiptLong fontSize="small" />, to: "/financial-management/admin/accounting-periods" },
          { id: "statutory-rates-admin", label: "Statutory Rates (PAYE/NSSF)", icon: <ReceiptLong fontSize="small" />, to: "/financial-management/admin/statutory-rates" },
          { id: "account-categories-admin", label: "Account Categories", icon: <ReceiptLong fontSize="small" />, to: "/financial-management/admin/account-categories" },
          { id: "cost-code-list", label: "Cost Code List", icon: <ReceiptLong fontSize="small" />, to: "/financial-management/admin/cost-codes" },
          { id: "cost-code-list-new", label: "Cost Code List New", icon: <ReceiptLong fontSize="small" />, to: "/financial-management/admin/cost-codes/new" },
        ],
      },
    ],
  },
  {
    id: "it-support",
    label: "IT Support",
    icon: <SupportAgent fontSize="small" />,
    nodes: itSupportNodes,
    requiredModule: "it",
  },
  {
    id: "law-compliance",
    label: "Law and Compliance",
    icon: <AdminPanelSettings fontSize="small" />,
    nodes: lawComplianceNodes,
    requiredModule: "legal",
  },
  {
    id: "human-resources",
    label: "Human Resources",
    icon: <AssignmentTurnedIn fontSize="small" />,
    nodes: hrNodes,
    requiredModule: "hr",
  },
  {
    id: "business-development",
    label: "Business Development and Proposal",
    icon: <Description fontSize="small" />,
    nodes: businessDevNodes,
    requiredModule: "bd",
  },
  {
    id: "machine-operation",
    label: "Machine Operation",
    icon: <Build fontSize="small" />,
    nodes: machineOperationNodes,
    requiredModule: "machine_operation",
  },
  {
    id: "pmo",
    label: "Project Management Office",
    icon: <Folder fontSize="small" />,
    nodes: pmoNodes,
    requiredModule: "pmo",
  },
  {
    id: "sustainability",
    label: "Sustainability and Business Excellence",
    icon: <Folder fontSize="small" />,
    nodes: sustainabilityNodes,
    requiredModule: "sustainability",
  },
  {
    id: "my-approvals",
    label: "My Approvals",
    icon: <AssignmentTurnedIn fontSize="small" />,
    nodes: [{ id: "my-approvals-home", label: "My Approvals", icon: <AssignmentTurnedIn fontSize="small" />, to: "/my-approvals" }],
  },
  {
    // Company Administration -- layer 2 of the admin model: the tenant's
    // own governance (organization, users & access, workflows). Whole
    // portal gated to the company admin (or a platform admin via View-as);
    // RequireTenantAdmin is the route-level enforcement. The shell with
    // the same items lives in features/company-admin/CompanyAdminLayout.
    id: "company-admin",
    label: "Company Administration",
    icon: <AssignmentTurnedIn fontSize="small" />,
    requiredAccess: "company-admin",
    nodes: [
      { id: "ca-dashboard", label: "Dashboard", icon: <Dashboard fontSize="small" />, to: "/company-admin" },
      {
        id: "ca-organization",
        label: "Organization",
        icon: <Apartment fontSize="small" />,
        children: [
          { id: "ca-departments", label: "Departments", icon: <Apartment fontSize="small" />, to: "/company-admin/organization/departments" },
          { id: "ca-organizations", label: "Organizations", icon: <Groups fontSize="small" />, to: "/company-admin/organization/organizations" },
        ],
      },
      {
        id: "ca-users",
        label: "Users & Access",
        icon: <People fontSize="small" />,
        children: [
          { id: "ca-members", label: "Team Members", icon: <People fontSize="small" />, to: "/company-admin/users/members" },
          { id: "ca-invite", label: "Invite Member", icon: <PersonAdd fontSize="small" />, to: "/company-admin/users/invite" },
        ],
      },
      {
        id: "ca-workflows",
        label: "Workflows",
        icon: <Rule fontSize="small" />,
        children: [
          { id: "ca-approvals", label: "Approval Workflow", icon: <AssignmentTurnedIn fontSize="small" />, to: "/company-admin/workflows/approvals" },
        ],
      },
      { id: "ca-setup", label: "Setup Checklist", icon: <Checklist fontSize="small" />, to: "/company-admin/setup" },
    ],
  },
  {
    // Kept in lock-step with AdminLayout's CONSOLE_GROUPS: this portal is
    // the platform admin's nav OUTSIDE console routes (the rail takes over
    // inside them). Every console screen must be linked from one or the
    // other, so new screens get added to both. requiredAccess "platform"
    // hides it from every non-platform user in the switcher (the routes
    // themselves are RequirePlatformAdmin-guarded; this removes the dead
    // entry that used to bounce to a "not allowed" screen).
    id: "platform-admin",
    label: "Platform Administration",
    icon: <AdminPanelSettings fontSize="small" />,
    requiredAccess: "platform",
    nodes: [
      { id: "platform-overview", label: "Overview", icon: <Dashboard fontSize="small" />, to: "/admin" },
      { id: "companies-console", label: "Companies", icon: <Business fontSize="small" />, to: "/admin/companies" },
      { id: "platform-users", label: "Users", icon: <People fontSize="small" />, to: "/admin/users" },
      { id: "platform-team", label: "Platform Team", icon: <Groups fontSize="small" />, to: "/admin/team" },
      { id: "platform-templates", label: "Industry Templates", icon: <Category fontSize="small" />, to: "/admin/templates" },
      { id: "platform-announcements", label: "Announcements", icon: <Campaign fontSize="small" />, to: "/admin/announcements" },
      { id: "platform-flags", label: "Feature Flags", icon: <Flag fontSize="small" />, to: "/admin/flags" },
      { id: "platform-audit", label: "Audit Log", icon: <ReceiptLong fontSize="small" />, to: "/admin/audit" },
      { id: "platform-health", label: "Platform Health", icon: <HealthAndSafety fontSize="small" />, to: "/admin/health" },
      { id: "platform-settings", label: "Settings", icon: <Settings fontSize="small" />, to: "/admin/settings" },
    ],
  },
];
