// Finance (RequireFinanceTeam) plus the finance-keyed warehouse admin screens.
//
// Exposed as a fragment of <Route>s (not a component): <Routes> only accepts
// <Route>/<Fragment> children, so App.tsx drops this in as `{financeRoutes}`.

import { lazy } from 'react';
import { Navigate, Route } from 'react-router-dom';
import RequireFinanceTeam from '../components/RequireFinanceTeam';

const AccountCategoriesAdmin = lazy(() => import('../features/admin/AccountCategoriesAdmin'));
const AccountingPeriodsAdmin = lazy(() => import('../features/admin/AccountingPeriodsAdmin'));
const AccountsAdmin = lazy(() => import('../features/admin/AccountsAdmin'));
const AdvancePayments = lazy(() => import('../features/financial/AdvancePayments'));
const BankReconciliation = lazy(() => import('../features/financial/BankReconciliation'));
const CashBankOperations = lazy(() => import('../features/financial/CashBankOperations'));
const ChartOfAccountsAdmin = lazy(() => import('../features/admin/ChartOfAccountsAdmin'));
const CostCodeList = lazy(() => import('../features/admin/CostCodeList'));
const CostCodeListNew = lazy(() => import('../features/admin/CostCodeListNew'));
const CostTransactionsInquiry = lazy(() => import('../features/financial/CostTransactionsInquiry'));
const CurrentAccountExtract = lazy(() => import('../features/financial/CurrentAccountExtract'));
const Durations = lazy(() => import('../features/financial/Durations'));
const EditInvoice = lazy(() => import('../features/financial/EditInvoice'));
const ExpenditureSlips = lazy(() => import('../features/financial/ExpenditureSlips'));
const FinancialDashboard = lazy(() => import('../features/financial/FinancialDashboard'));
const FinancialReports = lazy(() => import('../features/financial/FinancialReports'));
const GeneralLedger = lazy(() => import('../features/finance/GeneralLedger'));
const MassSlip = lazy(() => import('../features/financial/MassSlip'));
const MaterialReceiptAdmin = lazy(() => import('../features/admin/MaterialReceiptAdmin'));
const PayeNssfRemittance = lazy(() => import('../features/financial/PayeNssfRemittance'));
const PaymentPlanReport = lazy(() => import('../features/financial/PaymentPlanReport'));
const PayrollDisbursement = lazy(() => import('../features/financial/PayrollDisbursement'));
const PettyCashFloats = lazy(() => import('../features/financial/PettyCashFloats'));
const PettyCashRegister = lazy(() => import('../features/financial/PettyCashRegister'));
const PurchaseOrders = lazy(() => import('../features/finance/PurchaseOrders'));
const ReceivableInvoice = lazy(() => import('../features/financial/ReceivableInvoice'));
const SapPaymentApprovals = lazy(() => import('../features/sap/SapPaymentApprovals'));
const StatutoryRatesAdmin = lazy(() => import('../features/admin/StatutoryRatesAdmin'));
const SupplierInvoiceNonPO = lazy(() => import('../features/financial/SupplierInvoiceNonPO'));
const SupplierInvoices = lazy(() => import('../features/financial/SupplierInvoices'));
const TrialBalance = lazy(() => import('../features/financial/TrialBalance'));
const VatReport = lazy(() => import('../features/financial/VatReport'));
const WarehousesAdmin = lazy(() => import('../features/admin/WarehousesAdmin'));
const WhtReport = lazy(() => import('../features/financial/WhtReport'));

export const financeRoutes = (
  <>
    {/* FINANCE - gated by can_access_finance() (added 2026-08-16),
        the OR of is_finance_team_member() and has_po_access().
        These were previously reachable by any authenticated
        tenant user with no access check at all. */}
    <Route element={<RequireFinanceTeam />}>
      {/* purchase-orders moved under /financial-management/ for
          URL taxonomy consistency (roadmap P3); the old /finance/
          path redirects so existing bookmarks keep working. */}
      <Route path="/finance/purchase-orders" element={<Navigate to="/financial-management/purchase-orders" replace />} />
      <Route path="/financial-management/purchase-orders" element={<PurchaseOrders />} />
      <Route path="/financial-management/admin/cost-codes" element={<CostCodeList />} />
      <Route path="/financial-management/admin/cost-codes/new" element={<CostCodeListNew />} />
      <Route path="/sap/payment-approvals" element={<SapPaymentApprovals />} />
      <Route path="/financial-management/invoices/supplier-invoice-po" element={<SupplierInvoices />} />
      <Route path="/financial-management/dashboard" element={<FinancialDashboard />} />
      <Route path="/financial-management/invoices/supplier-invoice-non-po" element={<SupplierInvoiceNonPO />} />
      <Route path="/financial-management/cash-bank-operations" element={<CashBankOperations />} />
      <Route path="/financial-management/bank-reconciliation" element={<BankReconciliation />} />
      <Route path="/financial-management/invoices/receivable-invoice" element={<ReceivableInvoice />} />
      <Route path="/financial-management/expenditure-slips" element={<ExpenditureSlips />} />
      <Route path="/financial-management/invoices/edit-invoice" element={<EditInvoice />} />
      <Route path="/financial-management/reports" element={<FinancialReports />} />
      <Route path="/financial-management/admin/accounts" element={<AccountsAdmin />} />
      <Route path="/financial-management/petty-cash-floats" element={<PettyCashFloats />} />
      <Route path="/financial-management/petty-cash-register" element={<PettyCashRegister />} />
      <Route path="/financial-management/reports/cost-transactions-inquiry" element={<CostTransactionsInquiry />} />
      <Route path="/financial-management/reports/current-account-extract" element={<CurrentAccountExtract />} />
      <Route path="/financial-management/reports/trial-balance" element={<TrialBalance />} />
      <Route path="/financial-management/reports/general-ledger" element={<GeneralLedger />} />
      <Route path="/financial-management/admin/chart-of-accounts" element={<ChartOfAccountsAdmin />} />
      <Route path="/financial-management/admin/accounting-periods" element={<AccountingPeriodsAdmin />} />
      <Route path="/financial-management/admin/statutory-rates" element={<StatutoryRatesAdmin />} />
      <Route path="/financial-management/reports/vat-report" element={<VatReport />} />
      <Route path="/financial-management/reports/wht-report" element={<WhtReport />} />
      <Route path="/financial-management/reports/paye-nssf-remittance" element={<PayeNssfRemittance />} />
      <Route path="/financial-management/reports/durations" element={<Durations />} />
      <Route path="/financial-management/reports/advance-payments" element={<AdvancePayments />} />
      <Route path="/financial-management/reports/payment-plan" element={<PaymentPlanReport />} />
      <Route path="/financial-management/upload/mass-slip" element={<MassSlip />} />
      <Route path="/financial-management/payroll-disbursement" element={<PayrollDisbursement />} />
      {/* Warehouses: writes are keyed to is_finance_team_member()
          in RLS, so the finance gate stays; only the URL moves
          (warehouse namespace, next to goods-issue/stock-balances). */}
      <Route path="/warehouse/admin/warehouses" element={<WarehousesAdmin />} />
      {/* Material Receipt access: the screen assigns/revokes who may
          receive goods through assign_receipt_access() /
          revoke_receipt_access(), which require
          is_finance_team_member('finance') -- NOT has_po_access().
          The route lives with the other finance-authority admin
          screen, so the guard matches the RPC authority. */}
      <Route path="/warehouse/admin/material-receipt" element={<MaterialReceiptAdmin />} />
      <Route path="/financial-management/admin/account-categories" element={<AccountCategoriesAdmin />} />
    </Route>
  </>
);
