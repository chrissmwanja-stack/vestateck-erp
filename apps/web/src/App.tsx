import { useEffect, useState } from 'react';
import { Link as RouterLink, Route, Routes, Navigate } from 'react-router-dom';
import { AppBar, Box, Button, Container, Toolbar, Typography } from '@mui/material';

import RequestSubmissionForm from './features/requests/RequestSubmissionForm';
import ApprovalQueue from './features/approvals/ApprovalQueue';
import PurchaseOrders from './features/finance/PurchaseOrders';
import ProcurementTrack from './features/procurement/ProcurementTrack';
import PurchasingDashboard from './features/procurement/PurchasingDashboard';
import RequestTracking from './features/procurement/RequestTracking';
import ProcurementInfo from './features/procurement/ProcurementInfo';
import LoginPage from './features/auth/LoginPage';
import RequireAuth from './features/auth/RequireAuth';
import { useAuth } from './lib/authContext';
import { supabase } from './lib/supabaseClient';
import ModuleTree from './features/navigation/ModuleTree';
import NotificationBell from './features/notifications/NotificationBell';
import DelegationManager from './features/delegations/DelegationManager';
import InvoiceApprovalQueue from './features/multiplexing/InvoiceApprovalQueue';
import InvoiceSubmissionForm from './features/multiplexing/InvoiceSubmissionForm';
import CostCodeList from './features/admin/CostCodeList';
import CostCodeListNew from './features/admin/CostCodeListNew';
import SapPaymentApprovals from './features/sap/SapPaymentApprovals';
import SupplierInvoices from './features/financial/SupplierInvoices';
import FinancialDashboard from './features/financial/FinancialDashboard';
import SupplierInvoiceNonPO from './features/financial/SupplierInvoiceNonPO';
import CashBankOperations from './features/financial/CashBankOperations';
import EditInvoice from './features/financial/EditInvoice';
import ExpenditureSlips from './features/financial/ExpenditureSlips';          
import FinancialReports from './features/financial/FinancialReports';
import AccountsAdmin from './features/admin/AccountsAdmin';
import ReceivableInvoice from './features/financial/ReceivableInvoice'; 
import PettyCashFloats from './features/financial/PettyCashFloats';
import PettyCashRegister from './features/financial/PettyCashRegister';
import CostTransactionsInquiry from './features/financial/CostTransactionsInquiry';
import CurrentAccountExtract from './features/financial/CurrentAccountExtract';
import TrialBalance from './features/financial/TrialBalance';
import VatReport from './features/financial/VatReport';
import Durations from './features/financial/Durations';
import AdvancePayments from './features/financial/AdvancePayments';
import PaymentPlanReport from './features/financial/PaymentPlanReport';
import MassSlip from './features/financial/MassSlip';
import MaterialQuantity from './features/requests/MaterialQuantity';
import MaterialReceiptAdmin from './features/admin/MaterialReceiptAdmin';
import MyRequests from './features/requests/MyRequests';
import VendorEvaluationReport from './features/procurement/VendorEvaluationReport';
import OrganizationsAdmin from './features/admin/OrganizationsAdmin';
import DepartmentsAdmin from './features/admin/DepartmentsAdmin';
import AccountCategoriesAdmin from './features/admin/AccountCategoriesAdmin';
import NewMaterialRequest from './features/requests/NewMaterialRequest';
import MaterialRequestApproval from './features/approvals/MaterialRequestApproval';
import MaterialRequestReport from './features/requests/MaterialRequestReport';
import MaterialLookupsAdmin from './features/admin/MaterialLookupsAdmin';
import OfferEntry from './features/offers/OfferEntry';
import OfferApprovalPO from './features/offers/OfferApprovalPO';
import NewTicket from './features/it-support/NewTicket';
import ItSupportDashboard from './features/it-support/ItSupportDashboard';
import MyTickets from './features/it-support/MyTickets';
import AllTickets from './features/it-support/AllTickets';
import TicketApprovals from './features/it-support/TicketApprovals';
import ProblemManagement from './features/it-support/ProblemManagement';
import HardwareInventory from './features/it-support/assets/HardwareInventory';
import SoftwareInventory from './features/it-support/assets/SoftwareInventory';
import LicenseTracking from './features/it-support/assets/LicenseTracking';
import AssetAssignments from './features/it-support/assets/AssetAssignments';
import AssetRequest from './features/it-support/assets/AssetRequest';
import AccountManagement from './features/it-support/access/AccountManagement';
import GroupManagement from './features/it-support/access/GroupManagement';
import TicketCategoriesAdmin from './features/it-support/admin/TicketCategoriesAdmin';
import SlaPoliciesAdmin from './features/it-support/admin/SlaPoliciesAdmin';
import PriorityLevelsAdmin from './features/it-support/admin/PriorityLevelsAdmin';
import SupportTeamsAdmin from './features/it-support/admin/SupportTeamsAdmin';
import TicketTrackingReport from './features/it-support/reports/TicketTrackingReport';
import SlaPerformanceReport from './features/it-support/reports/SlaPerformanceReport';
import AssetReport from './features/it-support/reports/AssetReport';   
import KnowledgeBase from './features/it-support/KnowledgeBase';
import Faq from './features/it-support/Faq';
import AccessRequests from './features/it-support/access/AccessRequests';

// BUSINESS DEVELOPMENT - NEW SHELL
import BDPlaceholder from './modules/portals/business-development/pages/Placeholder';
import LeadSourcesAdmin from './modules/portals/business-development/pages/admin/LeadSourcesAdmin';
import OpportunityStagesAdmin from './modules/portals/business-development/pages/admin/OpportunityStagesAdmin';
import ClientCategoriesAdmin from './modules/portals/business-development/pages/admin/ClientCategoriesAdmin';
import ProposalTypesAdmin from './modules/portals/business-development/pages/admin/ProposalTypesAdmin';
import ProposalStatusesAdmin from './modules/portals/business-development/pages/admin/ProposalStatusesAdmin';
import TenderTypesAdmin from './modules/portals/business-development/pages/admin/TenderTypesAdmin';
import LeadStatusesAdmin from './modules/portals/business-development/pages/admin/LeadStatusesAdmin';
import NewLead from './modules/portals/business-development/pages/leads/NewLead';
import LeadsList from './modules/portals/business-development/pages/leads/LeadsList';
import QualifiedLeads from './modules/portals/business-development/pages/leads/QualifiedLeads';
import ImportLeads from './modules/portals/business-development/pages/leads/ImportLeads';
import NewOpportunity from './modules/portals/business-development/pages/opportunities/NewOpportunity';
import ClientsList from './modules/portals/business-development/pages/clients/ClientsList';
import ContactsList from './modules/portals/business-development/pages/clients/ContactsList';
import ActivitiesList from './modules/portals/business-development/pages/clients/ActivitiesList';
import OpportunitiesList from './modules/portals/business-development/pages/opportunities/OpportunitiesList';
import PipelineBoard from './modules/portals/business-development/pages/opportunities/PipelineBoard';
import ProposalsList from './modules/portals/business-development/pages/proposals/ProposalsList';
import NewProposal from './modules/portals/business-development/pages/proposals/NewProposal';
import ProposalApprovals from './modules/portals/business-development/pages/proposals/ProposalApprovals';
import ProposalTemplates from './modules/portals/business-development/pages/proposals/ProposalTemplates';
import ProposalTracking from './modules/portals/business-development/pages/proposals/ProposalTracking';
import TendersList from './modules/portals/business-development/pages/tenders/TendersList';
import NewTender from './modules/portals/business-development/pages/tenders/NewTender';
import SubmissionsList from './modules/portals/business-development/pages/tenders/SubmissionsList';
import TenderTracking from './modules/portals/business-development/pages/tenders/TenderTracking';
import PipelineReport from './modules/portals/business-development/pages/reports/PipelineReport';
import RevenueForecast from './modules/portals/business-development/pages/reports/RevenueForecast';
import WinLossReport from './modules/portals/business-development/pages/reports/WinLossReport';
import ProposalStatusReport from './modules/portals/business-development/pages/reports/ProposalStatusReport';
import LeadSourceReport from './modules/portals/business-development/pages/reports/LeadSourceReport';

// HR - NEW REAL
import PositionsAdmin from './modules/portals/hr/pages/admin/PositionsAdmin';
import LeaveTypesAdmin from './modules/portals/hr/pages/admin/LeaveTypesAdmin';
import EmployeesList from './modules/portals/hr/pages/employees/EmployeesList';
import LeaveRequestsList from './modules/portals/hr/pages/leaves/LeaveRequestsList';
import AttendanceList from './modules/portals/hr/pages/attendance/AttendanceList';
import JobPostingsList from './modules/portals/hr/pages/recruitment/JobPostingsList';
import ApplicationsList from './modules/portals/hr/pages/recruitment/ApplicationsList';
import PayrollList from './modules/portals/hr/pages/payroll/PayrollList';
import AppraisalsList from './modules/portals/hr/pages/performance/AppraisalsList';
import TrainingList from './modules/portals/hr/pages/performance/TrainingList';
import HRDashboard from './modules/portals/hr/pages/HRDashboard';
import OrgChart from './modules/portals/hr/pages/org/OrgChart';
import HeadcountReport from './modules/portals/hr/pages/reports/HeadcountReport';
import AttendanceReport from './modules/portals/hr/pages/reports/AttendanceReport';

// LAW AND COMPLIANCE - NEW REAL
import ContractTypesAdmin from './modules/portals/law-compliance/pages/admin/ContractTypesAdmin';
import CaseTypesAdmin from './modules/portals/law-compliance/pages/admin/CaseTypesAdmin';
import ContractsList from './modules/portals/law-compliance/pages/contracts/ContractsList';
import NewContract from './modules/portals/law-compliance/pages/contracts/NewContract';
import ContractApprovals from './modules/portals/law-compliance/pages/contracts/ContractApprovals';
import CasesList from './modules/portals/law-compliance/pages/cases/CasesList';
import HearingsList from './modules/portals/law-compliance/pages/cases/HearingsList';
import ComplianceRegister from './modules/portals/law-compliance/pages/compliance/ComplianceRegister';
import FilingsList from './modules/portals/law-compliance/pages/compliance/FilingsList';
import LawDashboard from './modules/portals/law-compliance/pages/LawDashboard';
import ExpiryReport from './modules/portals/law-compliance/pages/reports/ExpiryReport';
import CaseStatusReport from './modules/portals/law-compliance/pages/reports/CaseStatusReport';

// MACHINE OPERATION - 100% REAL
import MachineTypesAdmin from './modules/portals/machine-operation/pages/admin/MachineTypesAdmin';
import MaintenanceTypesAdmin from './modules/portals/machine-operation/pages/admin/MaintenanceTypesAdmin';
import MachineDashboard from './modules/portals/machine-operation/pages/MachineDashboard';
import EquipmentList from './modules/portals/machine-operation/pages/equipment/EquipmentList';
import EquipmentAssignments from './modules/portals/machine-operation/pages/equipment/EquipmentAssignments';
import MaintenanceSchedule from './modules/portals/machine-operation/pages/maintenance/MaintenanceSchedule';
import MaintenanceRequests from './modules/portals/machine-operation/pages/maintenance/MaintenanceRequests';
import MaintenanceHistory from './modules/portals/machine-operation/pages/maintenance/MaintenanceHistory';
import DailyLogs from './modules/portals/machine-operation/pages/logs/DailyLogs';
import FuelLogs from './modules/portals/machine-operation/pages/logs/FuelLogs';
import UtilizationReport from './modules/portals/machine-operation/pages/reports/UtilizationReport';
import DowntimeReport from './modules/portals/machine-operation/pages/reports/DowntimeReport';

// PMO - 100% REAL
import ProjectCategoriesAdmin from './modules/portals/pmo/pages/admin/ProjectCategoriesAdmin';
import TaskTypesAdmin from './modules/portals/pmo/pages/admin/TaskTypesAdmin';
import PMODashboard from './modules/portals/pmo/pages/PMODashboard';
import ProjectsList from './modules/portals/pmo/pages/projects/ProjectsList';
import NewProject from './modules/portals/pmo/pages/projects/NewProject';
import TasksList from './modules/portals/pmo/pages/tasks/TasksList';
import MilestonesList from './modules/portals/pmo/pages/tasks/MilestonesList';
import GanttChart from './modules/portals/pmo/pages/tasks/GanttChart';
import ResourceAllocation from './modules/portals/pmo/pages/resources/ResourceAllocation';
import ResourceUtilization from './modules/portals/pmo/pages/resources/ResourceUtilization';
import ProjectStatusReport from './modules/portals/pmo/pages/reports/ProjectStatusReport';
import BudgetVsActualReport from './modules/portals/pmo/pages/reports/BudgetVsActualReport';

// SUSTAINABILITY - 100% REAL
import MetricTypesAdmin from './modules/portals/sustainability/pages/admin/MetricTypesAdmin';
import InitiativeCategoriesAdmin from './modules/portals/sustainability/pages/admin/InitiativeCategoriesAdmin';
import SustainabilityDashboard from './modules/portals/sustainability/pages/SustainabilityDashboard';
import CarbonMetrics from './modules/portals/sustainability/pages/metrics/CarbonMetrics';
import EnergyMetrics from './modules/portals/sustainability/pages/metrics/EnergyMetrics';
import WasteMetrics from './modules/portals/sustainability/pages/metrics/WasteMetrics';
import InitiativesList from './modules/portals/sustainability/pages/initiatives/InitiativesList';
import NewInitiative from './modules/portals/sustainability/pages/initiatives/NewInitiative';
import AuditsList from './modules/portals/sustainability/pages/audits/AuditsList';
import CertificationsList from './modules/portals/sustainability/pages/audits/CertificationsList';
import SustainabilityReport from './modules/portals/sustainability/pages/reports/SustainabilityReport';
import ExcellenceReport from './modules/portals/sustainability/pages/reports/ExcellenceReport';












function useFinanceAccess(sessionUserId: string | undefined) {
  const [isFinance, setIsFinance] = useState<boolean | null>(null);

  useEffect(() => {
    if (!sessionUserId) {
      setIsFinance(null);
      return;
    }
    let cancelled = false;
    supabase.rpc('am_i_finance').then(({ data, error }) => {
      if (cancelled) return;
      setIsFinance(error ? false : Boolean(data));
    });
    return () => {
      cancelled = true;
    };
  }, [sessionUserId]);

  return isFinance;
}

function TopNav() {
  const { session, signOut } = useAuth();
  const isFinance = useFinanceAccess(session?.user?.id);

  return (
    <AppBar position="static">
      <Toolbar sx={{ gap: 2 }}>
        <Typography variant="h6" sx={{ flexGrow: 1 }}>
          ERP Platform
        </Typography>
        {session && (
          <>
            <Button color="inherit" component={RouterLink} to="/requests/my-requests">
              My requests
            </Button>
            <Button color="inherit" component={RouterLink} to="/requests/new">
              New request
            </Button>
            <Button color="inherit" component={RouterLink} to="/approvals">
              Approval queue
            </Button>
            <Button color="inherit" component={RouterLink} to="/procurement/track">
              Procurement
            </Button>
            {isFinance && (
              <Button color="inherit" component={RouterLink} to="/finance/purchase-orders">
                Purchase orders
              </Button>
            )}
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
          <Routes>
            <Route path="/login" element={<LoginPage />} />
            <Route element={<RequireAuth />}>
              <Route path="/" element={<Navigate to="/requests/new" replace />} />
              <Route path="/requests/new" element={<RequestSubmissionForm />} />
              <Route path="/approvals" element={<ApprovalQueue />} />
              <Route path="/finance/purchase-orders" element={<PurchaseOrders />} />
              <Route path="/procurement/track" element={<ProcurementTrack />} />
              <Route path="/procurement/request-tracking" element={<RequestTracking />} />
              <Route path="/procurement/info" element={<ProcurementInfo />} />
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
              <Route path="/requests/material-quantity" element={<MaterialQuantity />} />
              <Route path="/admin/material-receipt" element={<MaterialReceiptAdmin />} />
              <Route path="/admin/material-lookups" element={<MaterialLookupsAdmin />} />
              <Route path="/requests/my-requests" element={<MyRequests />} />
              <Route path="/procurement/vendor-evaluation" element={<VendorEvaluationReport />} />
              <Route path="/admin/organizations" element={<OrganizationsAdmin />} />
              <Route path="/admin/departments" element={<DepartmentsAdmin />} />
              <Route path="/admin/account-categories" element={<AccountCategoriesAdmin />} /> 
              <Route path="/requests/new-material" element={<NewMaterialRequest />} />
              <Route path="/purchasing/dashboard" element={<PurchasingDashboard />} />
              <Route path="/approvals/material-requests" element={<MaterialRequestApproval />} />
              <Route path="/requests/material-request-report" element={<MaterialRequestReport />} />
              <Route path="/offers/entry" element={<OfferEntry />} />
              <Route path="/offers/approval-po" element={<OfferApprovalPO />} />
              
              {/* IT SUPPORT - your existing work */}
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


              {/* BUSINESS DEVELOPMENT - NOW CONNECTED - Full 32-route shell */}
              <Route path="/business-development/dashboard" element={<BDPlaceholder title="BD Dashboard" description="KPIs: Pipeline value, win rate, leads by source, proposals pending, revenue forecast. Funnel chart lead->opportunity->proposal->won." />} />
              
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



              {/* LAW AND COMPLIANCE - SHELL WIRED */}
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


              {/* HUMAN RESOURCES - SHELL WIRED */}
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
              <Route path="/hr/performance/appraisals" element={<AppraisalsList />} />
              <Route path="/hr/training" element={<TrainingList />} />
              <Route path="/hr/reports/headcount" element={<HeadcountReport />} />
              <Route path="/hr/reports/attendance" element={<AttendanceReport />} />
              <Route path="/hr/admin/departments" element={<DepartmentsAdmin />} />
              <Route path="/hr/admin/positions" element={<PositionsAdmin />} />
              <Route path="/hr/admin/leave-types" element={<LeaveTypesAdmin />} />

              {/* MACHINE OPERATION - 100% REAL NOW */}
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

              {/* PMO - 100% REAL NOW */}
              <Route path="/pmo/dashboard" element={<PMODashboard />} />
              <Route path="/pmo/projects" element={<ProjectsList />} />
              <Route path="/pmo/projects/new" element={<NewProject />} />
              <Route path="/pmo/tasks" element={<TasksList />} />
              <Route path="/pmo/milestones" element={<MilestonesList />} />
              <Route path="/pmo/gantt" element={<GanttChart />} />
              <Route path="/pmo/resources/allocation" element={<ResourceAllocation />} />
              <Route path="/pmo/resources/utilization" element={<ResourceUtilization />} />
              <Route path="/pmo/reports/status" element={<ProjectStatusReport />} />
              <Route path="/pmo/reports/budget" element={<BudgetVsActualReport />} />
              <Route path="/pmo/admin/categories" element={<ProjectCategoriesAdmin />} />
              <Route path="/pmo/admin/task-types" element={<TaskTypesAdmin />} />

              {/* SUSTAINABILITY - 100% REAL NOW */}
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
            <Route path="*" element={<Navigate to="/" replace />} />
          </Routes>
        </Container>
      </Box>
    </Box>
  );
}