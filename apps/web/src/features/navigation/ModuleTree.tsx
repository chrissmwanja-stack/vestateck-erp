import { useState, useEffect, MouseEvent, useMemo } from "react";
import {
  Box,
  Collapse,
  List,
  ListItemButton,
  ListItemIcon,
  ListItemText,
  Typography,
  Divider,
  Menu,
  MenuItem,
  TextField,
  InputAdornment,
  Chip,
} from "@mui/material";
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
  ChevronRight,
  OpenInNew,
  AttachMoney,
  ExpandMore,
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
  Search,
  LiveHelp,
  Security,
  Groups,
  Category,
  Timer,
  PriorityHigh,
  Business,
  PersonAdd,
  PlaylistAddCheck,
} from "@mui/icons-material";
import { Link as RouterLink, useLocation } from "react-router-dom";
import { supabase } from "../../lib/supabaseClient";
import type { ModuleKey } from "../../components/RequireModule";
import {
  lawComplianceNodes,
  hrNodes,
  businessDevNodes,
  machineOperationNodes,
  pmoNodes,
  sustainabilityNodes,
} from "../../modules/portals/ShellConfigs";

interface TreeNode {
  id: string;
  label: string;
  icon?: React.ReactNode;
  to?: string;
  children?: TreeNode[];
  disabled?: boolean;
  tooltip?: string;
  // Module gate for individual nodes -- used inside portals that mix
  // gated and ungated screens (e.g. "purchasing-logistics", which has
  // procurement-only nodes alongside open request/finance screens).
  // Nodes with no requiredModule are always shown once their portal is
  // shown. This mirrors, but does not replace, the real enforcement in
  // RequireModule at the route level -- this is nav visibility only.
  requiredModule?: ModuleKey;
  // Gate for access checks that aren't staff_roles/tenant_modules-based
  // (currently just finance: can_access_finance() is the OR of
  // is_finance_team_member() and has_po_access(), enforced at the route
  // level by RequireFinanceTeam). Nav visibility only -- mirrors
  // requiredModule but checked against access.canAccessFinance instead
  // of access.modules. See useMyModuleAccess below.
  requiredAccess?: "finance";
  // Role gate on top of requiredModule -- for a node inside a single-module
  // portal (e.g. bd), the module checked is that portal's requiredModule;
  // for a node that also sets its own requiredModule (mixed portals like
  // purchasing-logistics), it's checked against that instead. Mirrors the
  // `roles` prop on RequireModule/has_module_role -- same exact-match
  // semantics, no admin/manager/member hierarchy. Nav visibility only; the
  // route guard is still the real enforcement.
  requiredRoles?: readonly string[];
}

interface Portal {
  id: string;
  label: string;
  icon: React.ReactNode;
  nodes: TreeNode[];
  disabled?: boolean;
  tooltip?: string;
  // Cosmetic-only: marks preview-maturity modules with a "Preview" badge
  // in the switcher and header. Does NOT restrict access -- gating is
  // still purely requiredModule + useMyModuleAccess, same as before.
  isPreview?: boolean;
  // Module gate for the whole portal -- used for portals that are 100%
  // one module (hr, legal, bd, it, pmo, machine_operation,
  // sustainability). Portals with no requiredModule are always shown;
  // "purchasing-logistics" mixes gated/ungated nodes so it's tagged at
  // the node level instead (see requiredModule on TreeNode).
  requiredModule?: ModuleKey;
  // Whole-portal finance gate -- see requiredAccess on TreeNode. Used for
  // "financial-management", which (unlike purchasing-logistics) is 100%
  // finance-gated routes, so it's simpler to tag at the portal level.
  requiredAccess?: "finance";
}

// Fetches the current user's own staff_roles modules, intersected with
// the tenant's actual tenant_modules entitlements, plus the
// platform-admin flag -- purely for nav visibility (RequireModule/
// has_module_role is the real enforcement, and already applies this
// same intersection server-side -- see 20260815075105_tenant_module_
// entitlements.sql). Mirrors the query pattern already used in
// InviteMember's useTenantAdminAccess / CompaniesConsole's
// usePlatformAdminAccess: get the caller's id from the session first,
// since RLS on these tables scopes by tenant, not by caller.
//
// Without the tenant_modules intersection, a company_admin (who holds
// a staff_roles admin row for all 8 modules by design, so newly-opened
// modules reach them automatically) would see nav entries for modules
// their company hasn't actually been opened for, only to hit "Not
// available to you" on click. tenant_modules is directly readable here
// (not just via the platform-admin-gated get_tenant_modules RPC) --
// its own SELECT policy already allows tenant_id = get_my_tenant_id().
function useMyModuleAccess() {
  const [state, setState] = useState<{
    isPlatformAdmin: boolean;
    modules: Set<string>;
    // Module -> the roles the caller actually holds in staff_roles for it
    // (almost always one row per module, but staff_roles doesn't enforce
    // that). Used for nodes with requiredRoles (e.g. BD's admin lookups /
    // proposal approvals) -- separate from `modules`, which only answers
    // "does this module show up in nav at all".
    rolesByModule: Map<string, Set<string>>;
    isImpersonating: boolean;
    // can_access_finance() is a separate, non-staff_roles-based check
    // (is_finance_team_member() OR has_po_access() -- see
    // RequireFinanceTeam.tsx, which enforces this same check at the
    // route level). Fetched here purely so nav visibility matches what
    // the route guard will actually allow.
    canAccessFinance: boolean;
  } | null>(null);
  useEffect(() => {
    let cancelled = false;

    const fetchAccess = async (userId: string | undefined) => {
      if (!userId) {
        if (!cancelled)
          setState({ isPlatformAdmin: false, modules: new Set(), rolesByModule: new Map(), isImpersonating: false, canAccessFinance: false });
        return;
      }
      const { data: appUser } = await supabase
        .from("app_users")
        .select("tenant_id, is_platform_admin")
        .eq("id", userId)
        .maybeSingle();
      if (cancelled) return;
      if (!appUser) {
        setState({ isPlatformAdmin: false, modules: new Set(), rolesByModule: new Map(), isImpersonating: false, canAccessFinance: false });
        return;
      }
      if (appUser.is_platform_admin) {
        // Check for an active impersonation session -- when impersonating,
        // get_my_tenant_id() resolves to the target tenant, but
        // has_module_role() still bypasses. For nav we need to know:
        // are we in platform-only mode (setup + analytics only) or in
        // "View as" mode (show that company's own portals)?
        const { data: imp } = await supabase
          .from("impersonation_sessions")
          .select("id")
          .eq("platform_admin_id", userId)
          .is("ended_at", null)
          .gt("started_at", new Date(Date.now() - 2 * 60 * 60 * 1000).toISOString())
          .limit(1)
          .maybeSingle();
        if (cancelled) return;
        // has_module_role() (and can_access_finance()) both treat platform
        // admins as an automatic pass -- mirror that here so nav doesn't
        // hide things the route guard would let them through to anyway.
        setState({ isPlatformAdmin: true, modules: new Set(), rolesByModule: new Map(), isImpersonating: !!imp, canAccessFinance: true });
        return;
      }
      const [{ data: roles }, { data: entitlements }, { data: financeAccess }] = await Promise.all([
        supabase.from("staff_roles").select("module, role").eq("user_id", userId).eq("tenant_id", appUser.tenant_id),
        supabase.from("tenant_modules").select("module").eq("tenant_id", appUser.tenant_id),
        supabase.rpc("can_access_finance"),
      ]);
      if (cancelled) return;
      const roleRows = roles ?? [];
      const roleModules = new Set(roleRows.map((r) => r.module as string));
      const entitledModules = new Set((entitlements ?? []).map((e) => e.module as string));
      const effectiveModules = new Set([...roleModules].filter((m) => entitledModules.has(m)));
      const rolesByModule = new Map<string, Set<string>>();
      for (const r of roleRows) {
        const m = r.module as string;
        if (!rolesByModule.has(m)) rolesByModule.set(m, new Set());
        rolesByModule.get(m)!.add(r.role as string);
      }
      setState({
        isPlatformAdmin: false,
        modules: effectiveModules,
        rolesByModule,
        isImpersonating: false,
        canAccessFinance: Boolean(financeAccess),
      });
    };

    // Fetch once on mount for the fast path, but also re-fetch on any auth
    // state change. A session can swap within the same tab without a full
    // page reload -- e.g. accepting an invite link while this layout is
    // already mounted -- and a mount-only effect would keep showing the
    // previous session's access (e.g. "Platform Administration") after the
    // underlying user has changed.
    supabase.auth.getSession().then(({ data: sessionData }) => {
      if (!cancelled) fetchAccess(sessionData.session?.user.id);
    });

    const { data: subscription } = supabase.auth.onAuthStateChange((_event, session) => {
      if (cancelled) return;
      setState(null);
      fetchAccess(session?.user.id);
    });

    return () => {
      cancelled = true;
      subscription.subscription.unsubscribe();
    };
  }, []);
  return state;
}

// IT Support - YOU ALREADY WORKED ON IT (keeping your simpler paths)
const itSupportNodes: TreeNode[] = [
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

const portals: Portal[] = [
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
         { id: "purchase-orders", label: "Purchase Orders", icon: <ReceiptLong fontSize="small" />, to: "/finance/purchase-orders", requiredAccess: "finance" },
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
        id: "admin",
        label: "Admin",
        icon: <AdminPanelSettings fontSize="small" />,
        children: [
          {
            id: "cost-code-transaction",
            label: "Cost Code Transaction",
            icon: <Build fontSize="small" />,
            children: [
              { id: "cost-code-list", label: "Cost Code List", icon: <ReceiptLong fontSize="small" />, to: "/admin/cost-codes", requiredAccess: "finance" },
              { id: "cost-code-list-new", label: "Cost Code List New", icon: <ReceiptLong fontSize="small" />, to: "/admin/cost-codes/new", requiredAccess: "finance" },
              { id: "material-receipt-admin", label: "Material Receipt", icon: <ReceiptLong fontSize="small" />, to: "/admin/material-receipt", requiredAccess: "finance" },
            ],
          },
          { id: "material-lookups-admin", label: "Material Classification", icon: <ReceiptLong fontSize="small" />, to: "/admin/material-lookups", requiredAccess: "finance" },
          { id: "material-catalog-admin", label: "Material Catalog", icon: <ReceiptLong fontSize="small" />, to: "/admin/material-catalog", requiredAccess: "finance" },
          { id: "warehouses-admin", label: "Warehouses", icon: <Inventory2 fontSize="small" />, to: "/admin/warehouses", requiredAccess: "finance" },
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
    // Every route under here is wrapped in RequireFinanceTeam
    // (can_access_finance()) in App.tsx -- gate the whole portal so it
    // doesn't show in nav to users who'll just hit "Not available to you".
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
        children: [{ id: "cash-and-bank-payments", label: "Cash and Bank Payments", icon: <AccountBalance fontSize="small" />, to: "/financial-management/cash-bank-operations" }],
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
        ],
      },
      {
        id: "upload",
        label: "Upload",
        icon: <Folder fontSize="small" />,
        children: [
          { id: "mass-slip", label: "Mass Slip", icon: <Description fontSize="small" />, to: "/financial-management/upload/mass-slip" },
        ],
      },
      {
        id: "financial-admin",
        label: "Admin",
        icon: <AdminPanelSettings fontSize="small" />,
        children: [
          { id: "accounts-admin", label: "Accounts", icon: <ReceiptLong fontSize="small" />, to: "/admin/accounts" },
          { id: "chart-of-accounts-admin", label: "Chart of Accounts", icon: <ReceiptLong fontSize="small" />, to: "/admin/chart-of-accounts" },
          { id: "accounting-periods-admin", label: "Accounting Periods", icon: <ReceiptLong fontSize="small" />, to: "/admin/accounting-periods" },
          { id: "organizations-admin", label: "Organizations", icon: <ReceiptLong fontSize="small" />, to: "/admin/organizations" },
          { id: "departments-admin", label: "Departments", icon: <ReceiptLong fontSize="small" />, to: "/admin/departments" },
          { id: "account-categories-admin", label: "Account Categories", icon: <ReceiptLong fontSize="small" />, to: "/admin/account-categories" },
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
    // Not gated here -- like every other portal in this file, visibility
    // is left to the destination screen (usePlatformAdminAccess /
    // useTenantAdminAccess in CompaniesConsole / CompanySetupChecklist /
    // InviteMember). A non-admin who clicks in just sees that screen's
    // "not available to you" message.
    id: "platform-admin",
    label: "Platform Administration",
    icon: <AdminPanelSettings fontSize="small" />,
    nodes: [
      { id: "platform-overview", label: "Overview", icon: <Dashboard fontSize="small" />, to: "/admin" },
      { id: "companies-console", label: "Companies", icon: <Business fontSize="small" />, to: "/admin/companies" },
      { id: "company-setup", label: "Company Setup", icon: <PlaylistAddCheck fontSize="small" />, to: "/setup" },
      { id: "invite-team", label: "Invite Team", icon: <PersonAdd fontSize="small" />, to: "/team/invite" },
      { id: "team-members", label: "Manage Team", icon: <Groups fontSize="small" />, to: "/team/members" },
      { id: "approval-workflow", label: "Approval Workflow", icon: <ReceiptLong fontSize="small" />, to: "/admin/approval-workflow" },
    ],
  },
];

function TreeItem({ node, depth = 0, pathname }: { node: TreeNode; depth?: number; pathname: string }) {
  const [open, setOpen] = useState(depth === 0);
  const hasChildren = !!node.children && node.children.length > 0;

  const isActive = node.to ? pathname === node.to.split("?")[0] : false;
  const isParentActive = hasChildren && node.children!.some((c) => c.to && pathname.startsWith(c.to.split("?")[0]));

  if (hasChildren) {
    return (
      <Box>
        <ListItemButton
          sx={{
            pl: 2 + depth * 2,
            py: 0.6,
            borderRadius: 1,
            bgcolor: isParentActive ? "action.selected" : "transparent",
            mb: 0.2,
          }}
          onClick={() => setOpen((o) => !o)}
          disabled={node.disabled}
        >
          <ListItemIcon sx={{ minWidth: 32, color: isParentActive ? "primary.main" : "text.secondary" }}>
            {node.icon || <Folder fontSize="small" />}
          </ListItemIcon>
          <ListItemText
            primary={
              <Typography variant="body2" fontWeight={isParentActive ? 600 : 500}>
                {node.label}
              </Typography>
            }
            secondary={node.disabled ? "Coming soon" : undefined}
          />
          {open ? <ExpandMore fontSize="small" /> : <ChevronRight fontSize="small" />}
        </ListItemButton>
        <Collapse in={open} timeout="auto" unmountOnExit>
          <List dense disablePadding sx={{ pl: 0.5 }}>
            {node.children!.map((child) => (
              <TreeItem key={child.id} node={child} depth={depth + 1} pathname={pathname} />
            ))}
          </List>
        </Collapse>
      </Box>
    );
  }

  return (
    <ListItemButton
      sx={{
        pl: 2 + depth * 2,
        py: 0.5,
        ml: 1,
        borderRadius: 1,
        borderLeft: isActive ? 2 : 0,
        borderColor: "primary.main",
        bgcolor: isActive ? "primary.main" : "transparent",
        color: isActive ? "primary.contrastText" : "inherit",
        "&:hover": { bgcolor: isActive ? "primary.dark" : "action.hover" },
        opacity: node.disabled ? 0.6 : 1,
      }}
      disabled={node.disabled}
      component={node.to && !node.disabled ? RouterLink : "div"}
      to={node.to}
    >
      <ListItemIcon sx={{ minWidth: 28, color: isActive ? "inherit" : "text.secondary" }}>
        {node.icon || <ChevronRight fontSize="small" />}
      </ListItemIcon>
      <ListItemText
        primary={<Typography variant="body2" fontWeight={isActive ? 600 : 400} noWrap>{node.label}</Typography>}
        secondary={node.disabled ? "Coming soon" : undefined}
        secondaryTypographyProps={{ variant: "caption" }}
      />
    </ListItemButton>
  );
}

// Strips nodes the current user has no module/role access to. "Access" here
// is access.modules, which is already the staff_roles ∩ tenant_modules
// intersection (see useMyModuleAccess) -- so a node also disappears if
// the tenant simply doesn't have that module opened, not just if the
// user lacks a role in it. Nodes without a requiredModule are always
// kept (for the module check); a parent with children is kept if it has
// any surviving child, or if it's directly accessible itself. This is nav
// visibility only -- RequireModule/has_module_role is what actually
// enforces access if someone still hits the URL directly.
//
// portalModule is the enclosing single-module portal's requiredModule
// (e.g. "bd"), used as the module context for a node's requiredRoles when
// the node itself doesn't set its own requiredModule -- which is the
// normal case for single-module portals like BD, where only the portal
// carries requiredModule and individual nodes just add requiredRoles on
// top of it.
function filterNodesByAccess(
  nodes: TreeNode[],
  access: {
    isPlatformAdmin: boolean;
    modules: Set<string>;
    rolesByModule: Map<string, Set<string>>;
    isImpersonating: boolean;
    canAccessFinance: boolean;
  },
  portalModule?: ModuleKey,
): TreeNode[] {
  const canSee = (n: TreeNode) => {
    const m = n.requiredModule ?? portalModule;
    if (m && !access.isPlatformAdmin && !access.modules.has(m)) return false;
    if (n.requiredAccess === "finance" && !access.isPlatformAdmin && !access.canAccessFinance) return false;
    if (n.requiredRoles && !access.isPlatformAdmin) {
      const myRoles = (m && access.rolesByModule.get(m)) || new Set<string>();
      if (!n.requiredRoles.some((r) => myRoles.has(r))) return false;
    }
    return true;
  };
  const walk = (list: TreeNode[]): TreeNode[] =>
    list
      .map((n) => {
        if (!canSee(n)) return null;
        if (n.children) {
          const children = walk(n.children);
          if (children.length === 0 && !n.to) return null;
          return { ...n, children };
        }
        return n;
      })
      .filter(Boolean) as TreeNode[];
  return walk(nodes);
}

export default function ModuleTree() {
  const location = useLocation();
  const [search, setSearch] = useState("");
  const access = useMyModuleAccess();
  const [activePortalId, setActivePortalId] = useState(() => {
    return localStorage.getItem("activePortalId") || portals[0].id;
  });
  const [anchorEl, setAnchorEl] = useState<null | HTMLElement>(null);

  // Portals gated at the whole-portal level (hr/legal/bd/it/pmo/
  // machine_operation/sustainability) disappear entirely from the
  // switcher if the user has no access. Mixed portals (purchasing-
  // logistics) and ungated ones (financial-management, platform-admin)
  // always show, with node-level filtering applied below.
  const visiblePortals = useMemo(() => {
    if (!access) return portals;
    // Platform-admin isolation: when NOT impersonating a company, only the
    // Platform Administration portal is visible -- setup + analytics only.
    // No company procurement/finance/HR reachable from nav unless the
    // admin explicitly "View as"-es into a company (see PlatformDashboard).
    if (access.isPlatformAdmin && !access.isImpersonating) {
      return portals.filter((p) => p.id === "platform-admin");
    }
    return portals.filter((p) => {
      if (access.isPlatformAdmin) return true;
      if (p.requiredModule && !access.modules.has(p.requiredModule)) return false;
      if (p.requiredAccess === "finance" && !access.canAccessFinance) return false;
      return true;
    });
  }, [access]);

  const activePortal = useMemo(
    () => visiblePortals.find((p) => p.id === activePortalId) ?? visiblePortals[0] ?? portals[0],
    [activePortalId, visiblePortals]
  );

  const handleOpenSwitcher = (e: MouseEvent<HTMLElement>) => setAnchorEl(e.currentTarget);
  const handleCloseSwitcher = () => setAnchorEl(null);
  const handleSelectPortal = (portal: Portal) => {
    if (portal.disabled) return;
    setActivePortalId(portal.id);
    localStorage.setItem("activePortalId", portal.id);
    handleCloseSwitcher();
  };

  const accessFilteredNodes = useMemo(() => {
    if (!access) return activePortal.nodes;
    return filterNodesByAccess(activePortal.nodes, access, activePortal.requiredModule);
  }, [activePortal.nodes, activePortal.requiredModule, access]);

  const filteredNodes = useMemo(() => {
    if (!search) return accessFilteredNodes;
    const lower = search.toLowerCase();
    const filter = (nodes: TreeNode[]): TreeNode[] => {
      return nodes
        .map((n) => {
          if (n.children) {
            const filteredChildren = filter(n.children);
            if (filteredChildren.length > 0 || n.label.toLowerCase().includes(lower)) {
              return { ...n, children: filteredChildren.length ? filteredChildren : n.children };
            }
            return null;
          }
          return n.label.toLowerCase().includes(lower) ? n : null;
        })
        .filter(Boolean) as TreeNode[];
    };
    return filter(accessFilteredNodes);
  }, [accessFilteredNodes, search]);

  return (
    <Box
      sx={{
        width: 300,
        minWidth: 300,
        bgcolor: "background.paper",
        borderRight: 1,
        borderColor: "divider",
        height: "100vh",
        overflow: "auto",
        display: "flex",
        flexDirection: "column",
      }}
    >
      <Box
        onClick={handleOpenSwitcher}
        sx={{
          p: 2,
          borderBottom: 1,
          borderColor: "divider",
          bgcolor: "primary.main",
          cursor: "pointer",
          display: "flex",
          alignItems: "center",
          justifyContent: "space-between",
          position: "sticky",
          top: 0,
          zIndex: 1,
        }}
      >
        <Box sx={{ overflow: "hidden" }}>
          <Typography variant="subtitle2" sx={{ color: "primary.contrastText", fontWeight: 700, display: "flex", alignItems: "center", gap: 1, whiteSpace: "nowrap" }}>
            {activePortal.icon}
            {activePortal.label}
            {activePortal.isPreview && (
              <Chip
                label="Preview"
                size="small"
                sx={{
                  height: 18,
                  fontSize: "0.65rem",
                  bgcolor: "rgba(255,255,255,0.2)",
                  color: "primary.contrastText",
                }}
              />
            )}
          </Typography>
          <Typography variant="caption" sx={{ color: "primary.contrastText", opacity: 0.8 }}>
            VestaPortal — click to switch portal
          </Typography>
        </Box>
        <ExpandMore sx={{ color: "primary.contrastText", flexShrink: 0 }} />
      </Box>

      <Menu anchorEl={anchorEl} open={Boolean(anchorEl)} onClose={handleCloseSwitcher} PaperProps={{ sx: { width: 320 } }}>
        {visiblePortals.map((portal) => (
          <MenuItem
            key={portal.id}
            selected={portal.id === activePortalId}
            disabled={portal.disabled}
            onClick={() => handleSelectPortal(portal)}
          >
            <ListItemIcon sx={{ minWidth: 32 }}>{portal.icon}</ListItemIcon>
            <ListItemText
              primary={
                <Box sx={{ display: "flex", alignItems: "center", gap: 0.75 }}>
                  {portal.label}
                  {portal.isPreview && (
                    <Chip label="Preview" size="small" sx={{ height: 18, fontSize: "0.65rem" }} />
                  )}
                </Box>
              }
              secondary={portal.disabled ? "Coming soon" : undefined}
            />
          </MenuItem>
        ))}
      </Menu>

      <Box sx={{ p: 1, borderBottom: 1, borderColor: "divider" }}>
        <TextField
          size="small"
          fullWidth
          placeholder={`Search ${activePortal.label}...`}
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          InputProps={{
            startAdornment: (
              <InputAdornment position="start">
                <Search fontSize="small" />
              </InputAdornment>
            ),
          }}
        />
      </Box>

      <Box sx={{ p: 1, flex: 1 }}>
        <List dense disablePadding>
          {filteredNodes.length > 0 ? (
            filteredNodes.map((node) => <TreeItem key={node.id} node={node} pathname={location.pathname} />)
          ) : (
            <Box sx={{ p: 2, textAlign: "center" }}>
              <Typography variant="body2" color="text.secondary">No results for "{search}"</Typography>
            </Box>
          )}
        </List>
      </Box>

      <Divider />
      <Box sx={{ p: 1.5 }}>
        <Typography variant="caption" color="text.secondary" sx={{ display: "flex", alignItems: "center", gap: 0.5 }}>
          <Box component="span" sx={{ width: 6, height: 6, borderRadius: "50%", bgcolor: "success.main", display: "inline-block" }} />
          Multi-tenant • {activePortal.nodes.length} modules • RLS-enabled
        </Typography>
      </Box>
    </Box>
  );
}

export { portals, itSupportNodes };
export type { Portal, TreeNode };
export { filterNodesByAccess };