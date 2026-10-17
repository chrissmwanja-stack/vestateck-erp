import { describe, expect, it } from 'vitest';
import { dashboardAlerts, FINANCE_CASH_PATH, type DashboardFacts } from './dashboardAlerts';

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
});
