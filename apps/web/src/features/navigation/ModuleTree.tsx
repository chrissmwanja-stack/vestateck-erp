import { useState, MouseEvent, useMemo } from "react";
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
} from "@mui/icons-material";
import { Link as RouterLink, useLocation } from "react-router-dom";
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
}

interface Portal {
  id: string;
  label: string;
  icon: React.ReactNode;
  nodes: TreeNode[];
  disabled?: boolean;
  tooltip?: string;
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
      },
      {
        id: "request-ops",
        label: "Request Operations",
        icon: <Folder fontSize="small" />,
        children: [
          { id: "new-request", label: "New Request", icon: <Description fontSize="small" />, to: "/requests/new" },
          { id: "my-requests", label: "My Requests", icon: <ReceiptLong fontSize="small" />, to: "/requests/my-requests" },
          { id: "req-approval", label: "Request Approval", icon: <AssignmentTurnedIn fontSize="small" />, to: "/approvals" },
          { id: "material-quantity", label: "Material Quantity", icon: <ReceiptLong fontSize="small" />, to: "/requests/material-quantity" },
        ],
      },
      {
        id: "warehouse-ops",
        label: "Warehouse Operations",
        icon: <Inventory2 fontSize="small" />,
        children: [
          { id: "goods-issue", label: "Goods Issue", icon: <ReceiptLong fontSize="small" />, to: "/warehouse/goods-issue" },
          { id: "stock-balances", label: "Stock Balances", icon: <Inventory2 fontSize="small" />, to: "/warehouse/stock-balances" },
        ],
      },
      {
        id: "offer-ops",
        label: "Offer Operations PO",
        icon: <Folder fontSize="small" />,
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
         { id: "procurement-info", label: "Procurement Info", icon: <OpenInNew fontSize="small" />, to: "/procurement/info" },
         { id: "purchase-orders", label: "Purchase Orders", icon: <ReceiptLong fontSize="small" />, to: "/finance/purchase-orders" },
       ],
      },
      {
        id: "reports",
        label: "Reports",
        icon: <Folder fontSize="small" />,
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
          { id: "new-material-approval", label: "Material Request Approval", icon: <AssignmentTurnedIn fontSize="small" />, to: "/approvals/material-requests" },
          { id: "new-material-report", label: "Material Request Report", icon: <BarChart fontSize="small" />, to: "/requests/material-request-report" },
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
              { id: "cost-code-list", label: "Cost Code List", icon: <ReceiptLong fontSize="small" />, to: "/admin/cost-codes" },
              { id: "cost-code-list-new", label: "Cost Code List New", icon: <ReceiptLong fontSize="small" />, to: "/admin/cost-codes/new" },
              { id: "material-receipt-admin", label: "Material Receipt", icon: <ReceiptLong fontSize="small" />, to: "/admin/material-receipt" },
            ],
          },
          { id: "material-lookups-admin", label: "Material Classification", icon: <ReceiptLong fontSize="small" />, to: "/admin/material-lookups" },
          { id: "warehouses-admin", label: "Warehouses", icon: <Inventory2 fontSize="small" />, to: "/admin/warehouses" },
        ],
      },
      {
        id: "sap",
        label: "SAP Operations",
        icon: <AccountBalance fontSize="small" />,
        children: [{ id: "payment-approvals", label: "Payment Approvals", icon: <AssignmentTurnedIn fontSize="small" />, to: "/sap/payment-approvals" }],
      },
    ],
  },
  {
    id: "financial-management",
    label: "Financial Management and Financial Reporting",
    icon: <AttachMoney fontSize="small" />,
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
          { id: "advance-payments", label: "Advance Payments", icon: <BarChart fontSize="small" />, to: "/financial-management/reports/advance-payments" },
          { id: "durations", label: "Durations", icon: <BarChart fontSize="small" />, to: "/financial-management/reports/durations" },
          { id: "payment-plan-report", label: "Payment Plan Report", icon: <BarChart fontSize="small" />, to: "/financial-management/reports/payment-plan" },
          { id: "vat-report", label: "VAT Report", icon: <BarChart fontSize="small" />, to: "/financial-management/reports/vat-report" },
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
  },
  {
    id: "law-compliance",
    label: "Law and Compliance",
    icon: <AdminPanelSettings fontSize="small" />,
    nodes: lawComplianceNodes,
  },
  {
    id: "human-resources",
    label: "Human Resources",
    icon: <AssignmentTurnedIn fontSize="small" />,
    nodes: hrNodes,
  },
  {
    id: "business-development",
    label: "Business Development and Proposal",
    icon: <Description fontSize="small" />,
    nodes: businessDevNodes,
  },
  {
    id: "machine-operation",
    label: "Machine Operation",
    icon: <Build fontSize="small" />,
    nodes: machineOperationNodes,
  },
  {
    id: "pmo",
    label: "Project Management Office",
    icon: <Folder fontSize="small" />,
    nodes: pmoNodes,
  },
  {
    id: "sustainability",
    label: "Sustainability and Business Excellence",
    icon: <Folder fontSize="small" />,
    nodes: sustainabilityNodes,
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

export default function ModuleTree() {
  const location = useLocation();
  const [search, setSearch] = useState("");
  const [activePortalId, setActivePortalId] = useState(() => {
    return localStorage.getItem("activePortalId") || portals[0].id;
  });
  const [anchorEl, setAnchorEl] = useState<null | HTMLElement>(null);
  const activePortal = useMemo(() => portals.find((p) => p.id === activePortalId) ?? portals[0], [activePortalId]);

  const handleOpenSwitcher = (e: MouseEvent<HTMLElement>) => setAnchorEl(e.currentTarget);
  const handleCloseSwitcher = () => setAnchorEl(null);
  const handleSelectPortal = (portal: Portal) => {
    if (portal.disabled) return;
    setActivePortalId(portal.id);
    localStorage.setItem("activePortalId", portal.id);
    handleCloseSwitcher();
  };

  const filteredNodes = useMemo(() => {
    if (!search) return activePortal.nodes;
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
    return filter(activePortal.nodes);
  }, [activePortal.nodes, search]);

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
          </Typography>
          <Typography variant="caption" sx={{ color: "primary.contrastText", opacity: 0.8 }}>
            Vestateck ERP — click to switch portal
          </Typography>
        </Box>
        <ExpandMore sx={{ color: "primary.contrastText", flexShrink: 0 }} />
      </Box>

      <Menu anchorEl={anchorEl} open={Boolean(anchorEl)} onClose={handleCloseSwitcher} PaperProps={{ sx: { width: 320 } }}>
        {portals.map((portal) => (
          <MenuItem
            key={portal.id}
            selected={portal.id === activePortalId}
            disabled={portal.disabled}
            onClick={() => handleSelectPortal(portal)}
          >
            <ListItemIcon sx={{ minWidth: 32 }}>{portal.icon}</ListItemIcon>
            <ListItemText primary={portal.label} secondary={portal.disabled ? "Coming soon" : undefined} />
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