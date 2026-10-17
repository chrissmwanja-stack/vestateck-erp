// Pure rules for the insurance dashboard. Each alert appears only when its count is
// above zero, and links to the page where the work is done.

/** Where premium cash requests are approved. Finance users only. */
export const FINANCE_CASH_PATH = '/financial-management/insurance-premium-cash';

export interface DashboardFacts {
  overdueRenewals: number;
  pendingCashRequests: number;
  claimsToAssess: number;
  approvedClaimsUnsettled: number;
  commissionEarnedNotTransferred: number;
  /** True when the person can open the Finance cash workbench, where requests are approved. */
  canOpenFinanceCash?: boolean;
}

export interface DashboardAlert {
  id: string;
  text: string;
  to: string;
}

const plural = (n: number, one: string, many: string) => (n === 1 ? one : many);

export function dashboardAlerts(f: DashboardFacts): DashboardAlert[] {
  const alerts: DashboardAlert[] = [];
  if (f.overdueRenewals > 0) {
    alerts.push({
      id: 'renewals-overdue',
      text: `${f.overdueRenewals} ${plural(f.overdueRenewals, 'policy is', 'policies are')} past expiry date.`,
      to: '/insurance/renewals',
    });
  }
  if (f.pendingCashRequests > 0) {
    alerts.push({
      id: 'cash-pending',
      text: `${f.pendingCashRequests} premium ${plural(f.pendingCashRequests, 'request is', 'requests are')} waiting for approval.`,
      to: f.canOpenFinanceCash ? FINANCE_CASH_PATH : '/insurance/policies',
    });
  }
  if (f.claimsToAssess > 0) {
    alerts.push({
      id: 'claims-assess',
      text: `${f.claimsToAssess} ${plural(f.claimsToAssess, 'claim is', 'claims are')} waiting to be assessed.`,
      to: '/insurance/claims',
    });
  }
  if (f.approvedClaimsUnsettled > 0) {
    alerts.push({
      id: 'claims-unsettled',
      text: `${f.approvedClaimsUnsettled} approved ${plural(f.approvedClaimsUnsettled, 'claim has', 'claims have')} not been settled.`,
      to: '/insurance/claims',
    });
  }
  if (f.commissionEarnedNotTransferred > 0) {
    alerts.push({
      id: 'commission-untransferred',
      text: 'Commission is earned and held in client money, not yet transferred to the company account.',
      to: '/insurance/commission',
    });
  }
  return alerts;
}
