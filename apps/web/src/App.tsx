import { lazy, Suspense } from 'react';
import { Link as RouterLink, Route, Routes, Navigate } from 'react-router-dom';
import { AppBar, Box, Button, Container, IconButton, Toolbar, Typography, Tooltip } from '@mui/material';
import { DarkModeOutlined, LightModeOutlined } from '@mui/icons-material';

const RequestSubmissionForm = lazy(() => import('./features/requests/RequestSubmissionForm'));
const ApprovalQueue = lazy(() => import('./features/approvals/ApprovalQueue'));
const PurchaseOrders = lazy(() => import('./features/finance/PurchaseOrders'));
const ProcurementTrack = lazy(() => import('./features/procurement/ProcurementTrack'));
const PurchasingDashboard = lazy(() => import('./features/procurement/PurchasingDashboard'));
const RequestTracking = lazy(() => import('./features/procurement/RequestTracking'));
const ProcurementInfo = lazy(() => import('./features/procurement/ProcurementInfo'));
import LoginPage from './features/auth/LoginPage';
import RequireAuth from './features/auth/RequireAuth';
import RequireModule from './components/RequireModule';
import { useAuth } from './lib/authContext';
import { useThemeMode } from './lib/themeModeContext';
import ModuleTree from './features/navigation/ModuleTree';
import NotificationBell from './features/notifications/NotificationBell';
import ImpersonationBanner from './features/admin/ImpersonationBanner';
const AcceptInvitePage = lazy(() => import('./features/auth/AcceptInvitePage')); const BootstrapAdminPage = lazy(() => import('./features/auth/BootstrapAdminPage'));
const CompaniesConsole = lazy(() => import('./features/admin/CompaniesConsole'));
const CompanyDetail = lazy(() => import('./features/admin/CompanyDetail'));
const InviteMember = lazy(() => import('./features/team/InviteMember'));
const CompanySetupChecklist = lazy(() => import('./features/team/CompanySetupChecklist'));
const DelegationManager = lazy(() => import('./features/delegations/DelegationManager'));
const InvoiceApprovalQueue = lazy(() => import('./features/multiplexing/InvoiceApprovalQueue'));
const InvoiceSubmissionForm = lazy(() => import('./features/multiplexing/InvoiceSubmissionForm'));
const CostCodeList = lazy(() => import('./features/admin/CostCodeList'));
const CostCodeListNew = lazy(() => import('./features/admin/CostCodeListNew'));
const SapPaymentApprovals = lazy(() => import('./features/sap/SapPaymentApprovals'));
const SupplierInvoices = lazy(() => import('./features/financial/SupplierInvoices'));
const FinancialDashboard = lazy(() => import('./features/financial/FinancialDashboard'));
const SupplierInvoiceNonPO = lazy(() => import('./features/financial/SupplierInvoiceNonPO'));
const CashBankOperations = lazy(() => import('./features/financial/CashBankOperations'));
const EditInvoice = lazy(() => import('./features/financial/EditInvoice'));
const ExpenditureSlips = lazy(() => import('./features/financial/ExpenditureSlips'));
const FinancialReports = lazy(() => import('./features/financial/FinancialReports'));
const AccountsAdmin = lazy(() => import('./features/admin/AccountsAdmin'));
const ReceivableInvoice = lazy(() => import('./features/financial/ReceivableInvoice'));
const PettyCashFloats = lazy(() => import('./features/financial/PettyCashFloats'));
const PettyCashRegister = lazy(() => import('./features/financial/PettyCashRegister'));
const CostTransactionsInquiry = lazy(() => import('./features/financial/CostTransactionsInquiry'));
const CurrentAccountExtract = lazy(() => import('./features/financial/CurrentAccountExtract'));
const TrialBalance = lazy(() => import('./features/financial/TrialBalance'));
const VatReport = lazy(() => import('./features/financial/VatReport'));
const Durations = lazy(() => import('./features/financial/Durations'));
const AdvancePayments = lazy(() => import('./features/financial/AdvancePayments'));
const PayrollDisbursement = lazy(() => import('./features/financial/PayrollDisbursement'));
const PaymentPlanReport = lazy(() => import('./features/financial/PaymentPlanReport'));
const MassSlip = lazy(() => import('./features/financial/MassSlip'));
const MaterialQuantity = lazy(() => import('./features/requests/MaterialQuantity'));
const MaterialReceiptAdmin = lazy(() => import('./features/admin/MaterialReceiptAdmin'));
const GoodsIssue = lazy(() => import('./features/requests/GoodsIssue'));
const StockBalances = lazy(() => import('./features/reports/StockBalances'));
const WarehousesAdmin = lazy(() => import('./features/admin/WarehousesAdmin'));
const MyRequests = lazy(() => import('./features/requests/MyRequests'));
const VendorEvaluationReport = lazy(() => import('./features/procurement/VendorEvaluationReport'));
const OrganizationsAdmin = lazy(() => import('./features/admin/OrganizationsAdmin'));
const DepartmentsAdmin = lazy(() => import('./features/admin/DepartmentsAdmin'));
const AccountCategoriesAdmin = lazy(() => import('./features/admin/AccountCategoriesAdmin'));
const NewMaterialRequest = lazy(() => import('./features/requests/NewMaterialRequest'));
const MaterialRequestApproval = lazy(() => import('./features/approvals/MaterialRequestApproval'));
const MaterialRequestReport = lazy(() => import('./features/requests/MaterialRequestReport'));
const MaterialLookupsAdmin = lazy(() => import('./features/admin/MaterialLookupsAdmin'));
const OfferEntry = lazy(() => import('./features/offers/OfferEntry'));
const OfferApprovalPO = lazy(() => import('./features/offers/OfferApprovalPO'));
const NewTicket = lazy(() => import('./features/it-support/NewTicket'));
const ItSupportDashboard = lazy(() => import('./features/it-support/ItSupportDashboard'));
const MyTickets = lazy(() => import('./features/it-support/MyTickets'));
const AllTickets = lazy(() => import('./features/it-support/AllTickets'));
const TicketApprovals = lazy(() => import('./features/it-support/TicketApprovals'));
const ProblemManagement = lazy(() => import('./features/it-support/ProblemManagement'));
const HardwareInventory = lazy(() => import('./features/it-support/assets/HardwareInventory'));
const SoftwareInventory = lazy(() => import('./features/it-support/assets/SoftwareInventory'));
const LicenseTracking = lazy(() => import('./features/it-support/assets/LicenseTracking'));
const AssetAssignments = lazy(() => import('./features/it-support/assets/AssetAssignments'));
const AssetRequest = lazy(() => import('./features/it-support/assets/AssetRequest'));
const AccountManagement = lazy(() => import('./features/it-support/access/AccountManagement'));
const GroupManagement = lazy(() => import('./features/it-support/access/GroupManagement'));
const TicketCategoriesAdmin = lazy(() => import('./features/it-support/admin/TicketCategoriesAdmin'));
const SlaPoliciesAdmin = lazy(() => import('./features/it-support/admin/SlaPoliciesAdmin'));
const PriorityLevelsAdmin = lazy(() => import('./features/it-support/admin/PriorityLevelsAdmin'));
const SupportTeamsAdmin = lazy(() => import('./features/it-support/admin/SupportTeamsAdmin'));
const TicketTrackingReport = lazy(() => import('./features/it-support/reports/TicketTrackingReport'));
const SlaPerformanceReport = lazy(() => import('./features/it-support/reports/SlaPerformanceReport'));
const AssetReport = lazy(() => import('./features/it-support/reports/AssetReport'));
const KnowledgeBase = lazy(() => import('./features/it-support/KnowledgeBase'));
const Faq = lazy(() => import('./features/it-support/Faq'));
const AccessRequests = lazy(() => import('./features/it-support/access/AccessRequests'));

// BUSINESS DEVELOPMENT - NEW SHELL
const BDDashboard = lazy(() => import('./modules/portals/business-development/pages/BDDashboard'));
const LeadSourcesAdmin = lazy(() => import('./modules/portals/business-development/pages/admin/LeadSourcesAdmin'));
const OpportunityStagesAdmin = lazy(() => import('./modules/portals/business-development/pages/admin/OpportunityStagesAdmin'));
const ClientCategoriesAdmin = lazy(() => import('./modules/portals/business-development/pages/admin/ClientCategoriesAdmin'));
const ProposalTypesAdmin = lazy(() => import('./modules/portals/business-development/pages/admin/ProposalTypesAdmin'));
const ProposalStatusesAdmin = lazy(() => import('./modules/portals/business-development/pages/admin/ProposalStatusesAdmin'));
const TenderTypesAdmin = lazy(() => import('./modules/portals/business-development/pages/admin/TenderTypesAdmin'));
const LeadStatusesAdmin = lazy(() => import('./modules/portals/business-development/pages/admin/LeadStatusesAdmin'));
const NewLead = lazy(() => import('./modules/portals/business-development/pages/leads/NewLead'));
const LeadsList = lazy(() => import('./modules/portals/business-development/pages/leads/LeadsList'));
const QualifiedLeads = lazy(() => import('./modules/portals/business-development/pages/leads/QualifiedLeads'));
const ImportLeads = lazy(() => import('./modules/portals/business-development/pages/leads/ImportLeads'));
const NewOpportunity = lazy(() => import('./modules/portals/business-development/pages/opportunities/NewOpportunity'));
const ClientsList = lazy(() => import('./modules/portals/business-development/pages/clients/ClientsList'));
const ContactsList = lazy(() => import('./modules/portals/business-development/pages/clients/ContactsList'));
const ActivitiesList = lazy(() => import('./modules/portals/business-development/pages/clients/ActivitiesList'));
const OpportunitiesList = lazy(() => import('./modules/portals/business-development/pages/opportunities/OpportunitiesList'));
const PipelineBoard = lazy(() => import('./modules/portals/business-development/pages/opportunities/PipelineBoard'));
const ProposalsList = lazy(() => import('./modules/portals/business-development/pages/proposals/ProposalsList'));
const NewProposal = lazy(() => import('./modules/portals/business-development/pages/proposals/NewProposal'));
const ProposalApprovals = lazy(() => import('./modules/portals/business-development/pages/proposals/ProposalApprovals'));
const ProposalTemplates = lazy(() => import('./modules/portals/business-development/pages/proposals/ProposalTemplates'));
const ProposalTracking = lazy(() => import('./modules/portals/business-development/pages/proposals/ProposalTracking'));
const TendersList = lazy(() => import('./modules/portals/business-development/pages/tenders/TendersList'));
const NewTender = lazy(() => import('./modules/portals/business-development/pages/tenders/NewTender'));
const SubmissionsList = lazy(() => import('./modules/portals/business-development/pages/tenders/SubmissionsList'));
const TenderTracking = lazy(() => import('./modules/portals/business-development/pages/tenders/TenderTracking'));
const PipelineReport = lazy(() => import('./modules/portals/business-development/pages/reports/PipelineReport'));
const RevenueForecast = lazy(() => import('./modules/portals/business-development/pages/reports/RevenueForecast'));
const WinLossReport = lazy(() => import('./modules/portals/business-development/pages/reports/WinLossReport'));
const ProposalStatusReport = lazy(() => import('./modules/portals/business-development/pages/reports/ProposalStatusReport'));
const LeadSourceReport = lazy(() => import('./modules/portals/business-development/pages/reports/LeadSourceReport'));

// HR - NEW REAL
const PositionsAdmin = lazy(() => import('./modules/portals/hr/pages/admin/PositionsAdmin'));
const LeaveTypesAdmin = lazy(() => import('./modules/portals/hr/pages/admin/LeaveTypesAdmin'));
const EmployeesList = lazy(() => import('./modules/portals/hr/pages/employees/EmployeesList'));
const LeaveRequestsList = lazy(() => import('./modules/portals/hr/pages/leaves/LeaveRequestsList'));
const AttendanceList = lazy(() => import('./modules/portals/hr/pages/attendance/AttendanceList'));
const JobPostingsList = lazy(() => import('./modules/portals/hr/pages/recruitment/JobPostingsList'));
const ApplicationsList = lazy(() => import('./modules/portals/hr/pages/recruitment/ApplicationsList'));
const PayrollList = lazy(() => import('./modules/portals/hr/pages/payroll/PayrollList'));
const CompensationHistory = lazy(() => import('./modules/portals/hr/pages/payroll/CompensationHistory'));
const PayrollApprovals = lazy(() => import('./modules/portals/hr/pages/payroll/PayrollApprovals'));
const AppraisalsList = lazy(() => import('./modules/portals/hr/pages/performance/AppraisalsList'));
const TrainingList = lazy(() => import('./modules/portals/hr/pages/performance/TrainingList'));
const HRDashboard = lazy(() => import('./modules/portals/hr/pages/HRDashboard'));
const OrgChart = lazy(() => import('./modules/portals/hr/pages/org/OrgChart'));
const HeadcountReport = lazy(() => import('./modules/portals/hr/pages/reports/HeadcountReport'));
const AttendanceReport = lazy(() => import('./modules/portals/hr/pages/reports/AttendanceReport'));

// LAW AND COMPLIANCE - NEW REAL
const ContractTypesAdmin = lazy(() => import('./modules/portals/law-compliance/pages/admin/ContractTypesAdmin'));
const CaseTypesAdmin = lazy(() => import('./modules/portals/law-compliance/pages/admin/CaseTypesAdmin'));
const ContractsList = lazy(() => import('./modules/portals/law-compliance/pages/contracts/ContractsList'));
const NewContract = lazy(() => import('./modules/portals/law-compliance/pages/contracts/NewContract'));
const ContractApprovals = lazy(() => import('./modules/portals/law-compliance/pages/contracts/ContractApprovals'));
const CasesList = lazy(() => import('./modules/portals/law-compliance/pages/cases/CasesList'));
const HearingsList = lazy(() => import('./modules/portals/law-compliance/pages/cases/HearingsList'));
const ComplianceRegister = lazy(() => import('./modules/portals/law-compliance/pages/compliance/ComplianceRegister'));
const FilingsList = lazy(() => import('./modules/portals/law-compliance/pages/compliance/FilingsList'));
const LawDashboard = lazy(() => import('./modules/portals/law-compliance/pages/LawDashboard'));
const ExpiryReport = lazy(() => import('./modules/portals/law-compliance/pages/reports/ExpiryReport'));
const CaseStatusReport = lazy(() => import('./modules/portals/law-compliance/pages/reports/CaseStatusReport'));

// MACHINE OPERATION - 100% REAL
const MachineTypesAdmin = lazy(() => import('./modules/portals/machine-operation/pages/admin/MachineTypesAdmin'));
const MaintenanceTypesAdmin = lazy(() => import('./modules/portals/machine-operation/pages/admin/MaintenanceTypesAdmin'));
const MachineDashboard = lazy(() => import('./modules/portals/machine-operation/pages/MachineDashboard'));
const EquipmentList = lazy(() => import('./modules/portals/machine-operation/pages/equipment/EquipmentList'));
const EquipmentAssignments = lazy(() => import('./modules/portals/machine-operation/pages/equipment/EquipmentAssignments'));
const MaintenanceSchedule = lazy(() => import('./modules/portals/machine-operation/pages/maintenance/MaintenanceSchedule'));
const MaintenanceRequests = lazy(() => import('./modules/portals/machine-operation/pages/maintenance/MaintenanceRequests'));
const MaintenanceHistory = lazy(() => import('./modules/portals/machine-operation/pages/maintenance/MaintenanceHistory'));
const DailyLogs = lazy(() => import('./modules/portals/machine-operation/pages/logs/DailyLogs'));
const FuelLogs = lazy(() => import('./modules/portals/machine-operation/pages/logs/FuelLogs'));
const UtilizationReport = lazy(() => import('./modules/portals/machine-operation/pages/reports/UtilizationReport'));
const DowntimeReport = lazy(() => import('./modules/portals/machine-operation/pages/reports/DowntimeReport'));

// PMO - 100% REAL
const ProjectCategoriesAdmin = lazy(() => import('./modules/portals/pmo/pages/admin/ProjectCategoriesAdmin'));
const TaskTypesAdmin = lazy(() => import('./modules/portals/pmo/pages/admin/TaskTypesAdmin'));
const PMODashboard = lazy(() => import('./modules/portals/pmo/pages/PMODashboard'));
const ProjectsList = lazy(() => import('./modules/portals/pmo/pages/projects/ProjectsList'));
const NewProject = lazy(() => import('./modules/portals/pmo/pages/projects/NewProject'));
const ProjectDetail = lazy(() => import('./modules/portals/pmo/pages/projects/ProjectDetail'));
const TasksList = lazy(() => import('./modules/portals/pmo/pages/tasks/TasksList'));
const MilestonesList = lazy(() => import('./modules/portals/pmo/pages/tasks/MilestonesList'));
const GanttChart = lazy(() => import('./modules/portals/pmo/pages/tasks/GanttChart'));
const ResourceAllocation = lazy(() => import('./modules/portals/pmo/pages/resources/ResourceAllocation'));
const ResourceUtilization = lazy(() => import('./modules/portals/pmo/pages/resources/ResourceUtilization'));
const ProjectStatusReport = lazy(() => import('./modules/portals/pmo/pages/reports/ProjectStatusReport'));
const BudgetVsActualReport = lazy(() => import('./modules/portals/pmo/pages/reports/BudgetVsActualReport'));

// SUSTAINABILITY - 100% REAL
const MetricTypesAdmin = lazy(() => import('./modules/portals/sustainability/pages/admin/MetricTypesAdmin'));
const InitiativeCategoriesAdmin = lazy(() => import('./modules/portals/sustainability/pages/admin/InitiativeCategoriesAdmin'));
const SustainabilityDashboard = lazy(() => import('./modules/portals/sustainability/pages/SustainabilityDashboard'));
const CarbonMetrics = lazy(() => import('./modules/portals/sustainability/pages/metrics/CarbonMetrics'));
const EnergyMetrics = lazy(() => import('./modules/portals/sustainability/pages/metrics/EnergyMetrics'));
const WasteMetrics = lazy(() => import('./modules/portals/sustainability/pages/metrics/WasteMetrics'));
const InitiativesList = lazy(() => import('./modules/portals/sustainability/pages/initiatives/InitiativesList'));
const NewInitiative = lazy(() => import('./modules/portals/sustainability/pages/initiatives/NewInitiative'));
const AuditsList = lazy(() => import('./modules/portals/sustainability/pages/audits/AuditsList'));
const CertificationsList = lazy(() => import('./modules/portals/sustainability/pages/audits/CertificationsList'));
const SustainabilityReport = lazy(() => import('./modules/portals/sustainability/pages/reports/SustainabilityReport'));
const ExcellenceReport = lazy(() => import('./modules/portals/sustainability/pages/reports/ExcellenceReport'));

function TopNav() {
  const { session, signOut } = useAuth();
  const { resolvedMode, toggle } = useThemeMode();

  return (
     <>
    <AppBar position="static">
      <Toolbar sx={{ gap: 2 }}>
        <Typography variant="h6" sx={{ flexGrow: 1 }}>
          VestaPortal
        </Typography>
        <Tooltip title={resolvedMode === 'dark' ? 'Switch to light mode' : 'Switch to dark mode'}>
          <IconButton color="inherit" onClick={toggle} aria-label="Toggle dark mode">
            {resolvedMode === 'dark' ? <LightModeOutlined /> : <DarkModeOutlined />}
          </IconButton>
        </Tooltip>
        {session && (
          <>
            <Button color="inherit" component={RouterLink} to="/delegations">
              Delegations
            </Button>
            <NotificationBell userId={session.user.id} />
            <Typography variant="body2" sx={{ opacity: 0.8 }}>
              {session.user.email}
            </Typography>
            <Button color="inherit" onClick={() => signOut()}>
              Sign out
            </Button>
          </>
        )}
      </Toolbar>
    </AppBar>
      {session && <ImpersonationBanner />}
    </>
  );
}

function RouteFallback() {
  return (
    <Box sx={{ display: 'flex', justifyContent: 'center', mt: 6 }}>
      <Typography variant="body2" sx={{ opacity: 0.6 }}>
        Loading…
      </Typography>
    </Box>
  );
}

export default function App() {
  const { session } = useAuth();
  return (
    <Box sx={{ display: 'flex', flexDirection: 'column', minHeight: '100vh' }}>
      <TopNav />
      <Box sx={{ display: 'flex', flex: 1 }}>
        {session && <ModuleTree />}
        <Container component="main" sx={{ mt: 3, mb: 6, flexGrow: 1, maxWidth: '100%', px: 4 }}>
          <Suspense fallback={<RouteFallback />}>
          <Routes>
            <Route path="/login" element={<LoginPage />} />
            <Route path="/accept-invite" element={<AcceptInvitePage />} />
            <Route path="/bootstrap-admin" element={<BootstrapAdminPage />} />
            <Route element={<RequireAuth />}>
              <Route path="/" element={<Navigate to="/requests/new" replace />} />
              <Route path="/requests/new" element={<RequestSubmissionForm />} />
              <Route path="/approvals" element={<ApprovalQueue />} />
              <Route path="/finance/purchase-orders" element={<PurchaseOrders />} />
              <Route
                path="/delegations"
                element={session ? <DelegationManager userId={session.user.id} /> : null}
              />
              <Route path="/multiplexing/approvals" element={<InvoiceApprovalQueue />} />
              <Route path="/multiplexing/invoice-new" element={<InvoiceSubmissionForm />} />
              <Route path="/admin/cost-codes" element={<CostCodeList />} />
              <Route path="/admin/cost-codes/new" element={<CostCodeListNew />} />
              <Route path="/sap/payment-approvals" element={<SapPaymentApprovals />} />
              <Route path="/financial-management/invoices/supplier-invoice-po" element={<SupplierInvoices />} />
              <Route path="/financial-management/dashboard" element={<FinancialDashboard />} />
              <Route path="/financial-management/invoices/supplier-invoice-non-po" element={<SupplierInvoiceNonPO />} />
              <Route path="/financial-management/cash-bank-operations" element={<CashBankOperations />} />
              <Route path="/financial-management/invoices/receivable-invoice" element={<ReceivableInvoice />} /> 
              <Route path="/financial-management/expenditure-slips" element={<ExpenditureSlips />} />
              <Route path="/financial-management/invoices/edit-invoice" element={<EditInvoice />} />
              <Route path="/financial-management/reports" element={<FinancialReports />} />
              <Route path="/admin/accounts" element={<AccountsAdmin />} />
              <Route path="/financial-management/petty-cash-floats" element={<PettyCashFloats />} />  
              <Route path="/financial-management/petty-cash-register" element={<PettyCashRegister />} />
              <Route path="/financial-management/reports/cost-transactions-inquiry" element={<CostTransactionsInquiry />} />
              <Route path="/financial-management/reports/current-account-extract" element={<CurrentAccountExtract />} />
              <Route path="/financial-management/reports/trial-balance" element={<TrialBalance />} />
              <Route path="/financial-management/reports/vat-report" element={<VatReport />} />
              <Route path="/financial-management/reports/durations" element={<Durations />} />
              <Route path="/financial-management/reports/advance-payments" element={<AdvancePayments />} />
              <Route path="/financial-management/reports/payment-plan" element={<PaymentPlanReport />} />
              <Route path="/financial-management/upload/mass-slip" element={<MassSlip />} />
              <Route path="/financial-management/payroll-disbursement" element={<PayrollDisbursement />} />
              <Route path="/admin/material-receipt" element={<MaterialReceiptAdmin />} />
              <Route path="/admin/warehouses" element={<WarehousesAdmin />} />
              <Route path="/admin/material-lookups" element={<MaterialLookupsAdmin />} />
              <Route path="/requests/my-requests" element={<MyRequests />} />
              <Route path="/admin/organizations" element={<OrganizationsAdmin />} />
              <Route path="/admin/departments" element={<DepartmentsAdmin />} />
              <Route path="/admin/account-categories" element={<AccountCategoriesAdmin />} />
              <Route path="/admin/companies" element={<CompaniesConsole />} />
              <Route path="/admin/companies/:tenantId" element={<CompanyDetail />} />
              <Route path="/team/invite" element={<InviteMember />} />
              <Route path="/setup" element={<CompanySetupChecklist />} />
              <Route path="/requests/new-material" element={<NewMaterialRequest />} />

              {/* PROCUREMENT - gated by staff_roles module="procurement" (added
                  2026-08-15). These were previously reachable by any
                  authenticated tenant user with no module check at all. */}
              <Route element={<RequireModule module="procurement" />}>
                <Route path="/procurement/track" element={<ProcurementTrack />} />
                <Route path="/procurement/request-tracking" element={<RequestTracking />} />
                <Route path="/procurement/info" element={<ProcurementInfo />} />
                <Route path="/procurement/vendor-evaluation" element={<VendorEvaluationReport />} />
                <Route path="/purchasing/dashboard" element={<PurchasingDashboard />} />
                <Route path="/offers/entry" element={<OfferEntry />} />
                <Route path="/offers/approval-po" element={<OfferApprovalPO />} />
                <Route path="/approvals/material-requests" element={<MaterialRequestApproval />} />
                <Route path="/requests/material-quantity" element={<MaterialQuantity />} />
                <Route path="/requests/material-request-report" element={<MaterialRequestReport />} />
                <Route path="/warehouse/goods-issue" element={<GoodsIssue />} />
                <Route path="/warehouse/stock-balances" element={<StockBalances />} />
              </Route>
              
              {/* IT SUPPORT - your existing work */}
              <Route element={<RequireModule module="it" />}>
                <Route path="/it-support/new-ticket" element={<NewTicket />} />
                <Route path="/it-support/my-tickets" element={<MyTickets />} />
                <Route path="/it-support/all-tickets" element={<AllTickets />} />
                <Route path="/it-support/approvals" element={<TicketApprovals />} />
                <Route path="/it-support/problems" element={<ProblemManagement />} />
                <Route path="/it-support/dashboard" element={<ItSupportDashboard />} />
                <Route path="/it-support/assets/hardware" element={<HardwareInventory />} />
                <Route path="/it-support/assets/software" element={<SoftwareInventory />} />
                <Route path="/it-support/assets/licenses" element={<LicenseTracking />} />
                <Route path="/it-support/assets/assignments" element={<AssetAssignments />} />
                <Route path="/it-support/assets/request" element={<AssetRequest />} />
                <Route path="/it-support/access/accounts" element={<AccountManagement />} />
                <Route path="/it-support/access/groups" element={<GroupManagement />} />
                <Route path="/it-support/admin/categories" element={<TicketCategoriesAdmin />} />
                <Route path="/it-support/admin/slas" element={<SlaPoliciesAdmin />} />
                <Route path="/it-support/admin/priorities" element={<PriorityLevelsAdmin />} />
                <Route path="/it-support/admin/teams" element={<SupportTeamsAdmin />} />
                <Route path="/it-support/reports/ticket-tracking" element={<TicketTrackingReport />} />
                <Route path="/it-support/reports/sla" element={<SlaPerformanceReport />} />
                <Route path="/it-support/reports/assets" element={<AssetReport />} />
                <Route path="/it-support/kb" element={<KnowledgeBase />} />
                <Route path="/it-support/faq" element={<Faq />} />
                <Route path="/it-support/access/requests" element={<AccessRequests />} />
              </Route>


              {/* BUSINESS DEVELOPMENT - NOW CONNECTED - Full 32-route shell */}
              <Route element={<RequireModule module="bd" />}>
                <Route path="/business-development/dashboard" element={<BDDashboard />} />

                {/* Lead Management */}
                <Route path="/business-development/leads" element={<LeadsList />} />
                <Route path="/business-development/leads/new" element={<NewLead />} />
                <Route path="/business-development/leads/qualified" element={<QualifiedLeads />} />
                <Route path="/business-development/leads/import" element={<ImportLeads />} />

                {/* Opportunity Management */}
                <Route path="/business-development/opportunities" element={<OpportunitiesList />} />
                <Route path="/business-development/opportunities/pipeline" element={<PipelineBoard />} />
                <Route path="/business-development/opportunities/new" element={<NewOpportunity />} />

                {/* Proposals */}
                <Route path="/business-development/proposals" element={<ProposalsList />} />
                <Route path="/business-development/proposals/new" element={<NewProposal />} />
                <Route path="/business-development/proposals/approvals" element={<ProposalApprovals />} />
                <Route path="/business-development/proposals/templates" element={<ProposalTemplates />} />
                <Route path="/business-development/proposals/tracking" element={<ProposalTracking />} />

                {/* Client Management */}
                <Route path="/business-development/clients" element={<ClientsList />} />
                <Route path="/business-development/clients/contacts" element={<ContactsList />} />
                <Route path="/business-development/clients/activities" element={<ActivitiesList />} />

                {/* Tender Management */}
                <Route path="/business-development/tenders" element={<TendersList />} />
                <Route path="/business-development/tenders/new" element={<NewTender />} />
                <Route path="/business-development/tenders/submissions" element={<SubmissionsList />} />
                <Route path="/business-development/tenders/tracking" element={<TenderTracking />} />

                {/* Reports */}
                <Route path="/business-development/reports/pipeline" element={<PipelineReport />} />
                <Route path="/business-development/reports/win-loss" element={<WinLossReport />} />
                <Route path="/business-development/reports/proposal-status" element={<ProposalStatusReport />} />
                <Route path="/business-development/reports/lead-source" element={<LeadSourceReport />} />
                <Route path="/business-development/reports/forecast" element={<RevenueForecast />} />

                {/* Admin - lookups backing dropdowns */}
                <Route path="/business-development/admin/lead-sources" element={<LeadSourcesAdmin />} />
                <Route path="/business-development/admin/lead-statuses" element={<LeadStatusesAdmin />} />
                <Route path="/business-development/admin/opportunity-stages" element={<OpportunityStagesAdmin />} />
                <Route path="/business-development/admin/proposal-types" element={<ProposalTypesAdmin />} />
                <Route path="/business-development/admin/proposal-statuses" element={<ProposalStatusesAdmin />} />
                <Route path="/business-development/admin/client-categories" element={<ClientCategoriesAdmin />} />
                <Route path="/business-development/admin/tender-types" element={<TenderTypesAdmin />} />
              </Route>



              {/* LAW AND COMPLIANCE - SHELL WIRED */}
              <Route element={<RequireModule module="legal" />}>
                <Route path="/law-compliance/dashboard" element={<LawDashboard />} />
                <Route path="/law-compliance/contracts" element={<ContractsList />} />
                <Route path="/law-compliance/contracts/new" element={<NewContract />} />
                <Route path="/law-compliance/contracts/approvals" element={<ContractApprovals />} />
                <Route path="/law-compliance/cases" element={<CasesList />} />
                <Route path="/law-compliance/cases/hearings" element={<HearingsList />} />
                <Route path="/law-compliance/compliance/register" element={<ComplianceRegister />} />
                <Route path="/law-compliance/compliance/filings" element={<FilingsList />} />
                <Route path="/law-compliance/reports/expiry" element={<ExpiryReport />} />
                <Route path="/law-compliance/reports/cases" element={<CaseStatusReport />} />
                <Route path="/law-compliance/admin/contract-types" element={<ContractTypesAdmin />} />
                <Route path="/law-compliance/admin/case-types" element={<CaseTypesAdmin />} />
              </Route>


              {/* HUMAN RESOURCES - SHELL WIRED */}
              <Route element={<RequireModule module="hr" />}>
                <Route path="/hr/dashboard" element={<HRDashboard />} />
                <Route path="/hr/employees" element={<EmployeesList />} />
                <Route path="/hr/employees/new" element={<EmployeesList />} />
                <Route path="/hr/org-chart" element={<OrgChart />} />
                <Route path="/hr/attendance" element={<AttendanceList />} />
                <Route path="/hr/leaves" element={<LeaveRequestsList />} />
                <Route path="/hr/leaves/approvals" element={<LeaveRequestsList />} />
                <Route path="/hr/recruitment/jobs" element={<JobPostingsList />} />
                <Route path="/hr/recruitment/applications" element={<ApplicationsList />} />
                <Route path="/hr/payroll" element={<PayrollList />} />
                <Route path="/hr/payroll/compensation-history" element={<CompensationHistory />} />
                <Route path="/hr/payroll/approvals" element={<PayrollApprovals />} />
                <Route path="/hr/performance/appraisals" element={<AppraisalsList />} />
                <Route path="/hr/training" element={<TrainingList />} />
                <Route path="/hr/reports/headcount" element={<HeadcountReport />} />
                <Route path="/hr/reports/attendance" element={<AttendanceReport />} />
                <Route path="/hr/admin/departments" element={<DepartmentsAdmin />} />
                <Route path="/hr/admin/positions" element={<PositionsAdmin />} />
                <Route path="/hr/admin/leave-types" element={<LeaveTypesAdmin />} />
              </Route>

              {/* MACHINE OPERATION - 100% REAL NOW */}
              <Route element={<RequireModule module="machine_operation" />}>
                <Route path="/machine-operation/dashboard" element={<MachineDashboard />} />
                <Route path="/machine-operation/equipment" element={<EquipmentList />} />
                <Route path="/machine-operation/equipment/assignments" element={<EquipmentAssignments />} />
                <Route path="/machine-operation/maintenance/schedule" element={<MaintenanceSchedule />} />
                <Route path="/machine-operation/maintenance/requests" element={<MaintenanceRequests />} />
                <Route path="/machine-operation/maintenance/history" element={<MaintenanceHistory />} />
                <Route path="/machine-operation/logs/daily" element={<DailyLogs />} />
                <Route path="/machine-operation/logs/fuel" element={<FuelLogs />} />
                <Route path="/machine-operation/reports/utilization" element={<UtilizationReport />} />
                <Route path="/machine-operation/reports/downtime" element={<DowntimeReport />} />
                <Route path="/machine-operation/admin/types" element={<MachineTypesAdmin />} />
                <Route path="/machine-operation/admin/maintenance-types" element={<MaintenanceTypesAdmin />} />
              </Route>

              {/* PMO - 100% REAL NOW */}
              <Route element={<RequireModule module="pmo" />}>
                <Route path="/pmo/dashboard" element={<PMODashboard />} />
                <Route path="/pmo/projects" element={<ProjectsList />} />
                <Route path="/pmo/projects/new" element={<NewProject />} />
                <Route path="/pmo/projects/:id" element={<ProjectDetail />} />
                <Route path="/pmo/tasks" element={<TasksList />} />
                <Route path="/pmo/milestones" element={<MilestonesList />} />
                <Route path="/pmo/gantt" element={<GanttChart />} />
                <Route path="/pmo/resources/allocation" element={<ResourceAllocation />} />
                <Route path="/pmo/resources/utilization" element={<ResourceUtilization />} />
                <Route path="/pmo/reports/status" element={<ProjectStatusReport />} />
                <Route path="/pmo/reports/budget" element={<BudgetVsActualReport />} />
                <Route path="/pmo/admin/categories" element={<ProjectCategoriesAdmin />} />
                <Route path="/pmo/admin/task-types" element={<TaskTypesAdmin />} />
              </Route>

              {/* SUSTAINABILITY - 100% REAL NOW */}
              <Route element={<RequireModule module="sustainability" />}>
                <Route path="/sustainability/dashboard" element={<SustainabilityDashboard />} />
                <Route path="/sustainability/metrics/carbon" element={<CarbonMetrics />} />
                <Route path="/sustainability/metrics/energy" element={<EnergyMetrics />} />
                <Route path="/sustainability/metrics/waste" element={<WasteMetrics />} />
                <Route path="/sustainability/initiatives" element={<InitiativesList />} />
                <Route path="/sustainability/initiatives/new" element={<NewInitiative />} />
                <Route path="/sustainability/audits" element={<AuditsList />} />
                <Route path="/sustainability/certifications" element={<CertificationsList />} />
                <Route path="/sustainability/reports/sustainability" element={<SustainabilityReport />} />
                <Route path="/sustainability/reports/excellence" element={<ExcellenceReport />} />
                <Route path="/sustainability/admin/metric-types" element={<MetricTypesAdmin />} />
                <Route path="/sustainability/admin/categories" element={<InitiativeCategoriesAdmin />} />
              </Route>


            </Route>
            <Route path="*" element={<Navigate to="/" replace />} />
          </Routes>
          </Suspense>
        </Container>
      </Box>
    </Box>
  );
}