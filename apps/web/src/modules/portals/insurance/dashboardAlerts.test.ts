import { describe, expect, it } from 'vitest';
import { dashboardAlerts, FINANCE_CASH_PATH, REGULATORY_RULES_PATH, REMITTANCE_REPORT_PATH, type DashboardFacts } from './dashboardAlerts';

const none: DashboardFacts = {
  overdueRenewals: 0,
  pendingCashRequests: 0,
  claimsToAssess: 0,
  approvedClaimsUnsettled: 0,
  commissionEarnedNotTransferred: 0,
};

describe('dashboardAlerts', () => {
  it('shows nothing when there is nothing to do', () => {
    expect(dashboardAlerts(none)).toEqual([]);
  });

  it('sends a Finance user to the cash workbench for pending premium requests', () => {
    const [alert] = dashboardAlerts({ ...none, pendingCashRequests: 2, canOpenFinanceCash: true });
    expect(alert.id).toBe('cash-pending');
    expect(alert.to).toBe(FINANCE_CASH_PATH);
    expect(alert.text).toContain('2 premium requests are waiting');
  });

  it('keeps an insurance-only user on the policies list, which they can open', () => {
    const [alert] = dashboardAlerts({ ...none, pendingCashRequests: 1 });
    expect(alert.to).toBe('/insurance/policies');
    expect(alert.text).toContain('1 premium request is waiting');
  });

  it('raises the held-premium alerts first and sends each to the right page', () => {
    const alerts = dashboardAlerts({ ...none, overdueRenewals: 1, remittanceOverdue: 2, remittanceDueToday: 1, remittanceDeadlineNotSet: 3 });
    expect(alerts.map((a) => a.id)).toEqual(['remittance-overdue', 'remittance-due-today', 'remittance-no-deadline', 'renewals-overdue']);
    expect(alerts[0].text).toBe('Premium on 2 policies are held past the remittance deadline.');
    expect(alerts[0].to).toBe(REMITTANCE_REPORT_PATH);
    expect(alerts[1].text).toBe('Premium on 1 policy must be remitted today.');
    expect(alerts[2].to).toBe(REGULATORY_RULES_PATH);
  });

  it('uses the singular for one overdue policy and stays quiet when the counts are zero or missing', () => {
    expect(dashboardAlerts({ ...none, remittanceOverdue: 1 })[0].text).toBe('Premium on 1 policy is held past the remittance deadline.');
    expect(dashboardAlerts({ ...none, remittanceOverdue: 0, remittanceDueToday: 0, remittanceDeadlineNotSet: 0 })).toEqual([]);
  });
});
