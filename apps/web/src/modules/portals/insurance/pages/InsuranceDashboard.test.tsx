import { render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import InsuranceDashboard from './InsuranceDashboard';

// The financial figures come from one server function and are shown per currency: a USD card next to a UGX
// card, never one added-up figure. The dashboard totals nothing itself.

vi.mock('../renewalNotificationSweep', () => ({ useRenewalNotificationSweep: () => undefined }));
const mockFrom = vi.fn();
const mockRpc = vi.fn();

vi.mock('../../../../lib/supabaseClient', () => ({
  supabase: { from: (...args: unknown[]) => mockFrom(...args), rpc: (...args: unknown[]) => mockRpc(...args) },
}));
vi.mock('../../../../features/navigation/useMyModuleAccess', () => ({
  useMyModuleAccess: () => ({ canAccessFinance: false }),
}));

const future = '2099-01-01';
let policies: unknown[] = [];
let claims: unknown[] = [];
let summary: unknown[] = [];
let summaryError: string | null = null;
let remittance: { data: unknown; error: { message: string } | null } = { data: [], error: null };

function builder(result: () => { data: unknown; error: null }) {
  const chain: Record<string, unknown> = {};
  for (const m of ['select', 'eq', 'in', 'order']) chain[m] = vi.fn(() => chain);
  (chain as { then: unknown }).then = (resolve: (v: unknown) => void) => resolve(result());
  return chain;
}

function setup() {
  mockFrom.mockImplementation((table: string) => {
    switch (table) {
      case 'ins_policies': return builder(() => ({ data: policies, error: null }));
      case 'ins_claims': return builder(() => ({ data: claims, error: null }));
      case 'ins_renewal_pipeline': return builder(() => ({ data: [], error: null }));
      case 'ins_policy_cash_requests': return builder(() => ({ data: [], error: null }));
      case 'ins_commission_position': return builder(() => ({ data: [], error: null }));
      case 'tenant_ledger_settings': return builder(() => ({ data: [{ functional_currency: 'UGX' }], error: null }));
      default: throw new Error(`unexpected table ${table}`);
    }
  });
  render(<MemoryRouter><InsuranceDashboard /></MemoryRouter>);
}

function card(label: string): HTMLElement {
  const el = screen.getByText(label).closest('.MuiCardContent-root');
  if (!el) throw new Error(`no card for ${label}`);
  return el as HTMLElement;
}

const money = (over: Record<string, unknown>) => ({
  currency: 'UGX', policy_count: 2, gross_written: 160000, endorsements: 0, cancellations: -20000, reversals: 0, net_written: 140000,
  commission_earned: 14000, premium_collected: 40000, outstanding_premium: 100000, overdue_premium: 30000, open_claim_count: 1,
  claims_outstanding: 7000, ...over,
});

beforeEach(() => {
  mockFrom.mockReset();
  mockRpc.mockReset();
  policies = [];
  claims = [];
  summary = [];
  summaryError = null;
  remittance = { data: [], error: null };
  mockRpc.mockImplementation((fn: string) => {
    if (fn === 'ins_dashboard_summary') {
      return Promise.resolve(summaryError ? { data: null, error: { message: summaryError } } : { data: summary, error: null });
    }
    return Promise.resolve(remittance);
  });
});

describe('InsuranceDashboard financial position', () => {
  it('asks the server for the figures and shows one card per currency, never added together', async () => {
    summary = [
      money({}),
      money({ currency: 'USD', gross_written: 2000, cancellations: 0, net_written: 2000, commission_earned: 200, premium_collected: 0,
        outstanding_premium: 2000, overdue_premium: 0, claims_outstanding: 0, open_claim_count: 0, policy_count: 1 }),
    ];
    setup();
    await screen.findByText('Financial position');
    expect(mockRpc).toHaveBeenCalledWith('ins_dashboard_summary', { p_from: expect.stringMatching(/^\d{4}-\d{2}-\d{2}$/), p_to: expect.stringMatching(/^\d{4}-\d{2}-\d{2}$/) });
    expect(await screen.findByText('UGX')).toBeInTheDocument();
    expect(screen.getByText('USD')).toBeInTheDocument();
    const text = (document.body.textContent ?? '').replace(/\s+/g, ' ');
    expect(text).toContain('160,000');
    expect(text).toContain('2,000');
    expect(text).not.toContain('162,000');
  });

  it('shows gross premium written with the cancellations and the net figure beside it', async () => {
    summary = [money({})];
    setup();
    await screen.findByText('Gross premium written');
    const gross = screen.getByText('Gross premium written').closest('div')?.parentElement?.textContent ?? '';
    expect(gross).toContain('160,000');
    expect(gross).toContain('2 policies bound');
    expect(screen.getByText('Cancellations and reversals').closest('div')?.parentElement?.textContent).toContain('20,000');
    expect(screen.getByText('Net premium written').closest('div')?.parentElement?.textContent).toContain('140,000');
  });

  it('shows commission earned, premium collected, outstanding premium with its overdue part, and claims outstanding', async () => {
    summary = [money({})];
    setup();
    await screen.findByText('Commission earned');
    const row = (label: string) => screen.getByText(label).closest('div')?.parentElement?.textContent ?? '';
    expect(row('Commission earned')).toContain('14,000');
    expect(row('Premium collected')).toContain('40,000');
    expect(row('Outstanding premium')).toContain('100,000');
    expect(row('Outstanding premium')).toContain('30,000');
    expect(row('Claims outstanding')).toContain('7,000');
    expect(row('Claims outstanding')).toContain('1 open claim');
  });

  it('says commission is not available, rather than zero, when no posting rule is set up', async () => {
    summary = [money({ commission_earned: null })];
    setup();
    await screen.findByText('Not available');
    expect(screen.getByText('No commission income posting rule is set up yet')).toBeInTheDocument();
  });

  it('says so when there is nothing to show for the period', async () => {
    setup();
    expect(await screen.findByText('No premium was written and nothing is outstanding for this period.')).toBeInTheDocument();
  });

  it('keeps the rest of the dashboard when the summary fails', async () => {
    summaryError = 'INS_FORBIDDEN: insurance access is required';
    setup();
    expect(await screen.findByText(/insurance access is required/i)).toBeInTheDocument();
    expect(screen.getByText('Policies in force')).toBeInTheDocument();
  });

  it('shows the operational counts from the rows the user can read', async () => {
    policies = [
      { status: 'active', expiry_date: future },
      { status: 'active', expiry_date: future },
      { status: 'active', expiry_date: future },
    ];
    claims = [{ status: 'notified' }, { status: 'assessing' }, { status: 'closed' }];
    setup();
    await screen.findByText('Policies in force');
    expect(card('Policies in force').textContent).toContain('3');
    expect(card('Open claims').textContent).toContain('2');
    expect(card('Claims to assess').textContent).toContain('2');
  });

  it('no longer totals premium, commission or reserves in the browser', async () => {
    policies = [{ status: 'active', expiry_date: future }];
    setup();
    await screen.findByText('Policies in force');
    expect(screen.queryByText('Gross premium in force')).not.toBeInTheDocument();
    expect(screen.queryByText('Commission in force')).not.toBeInTheDocument();
    expect(screen.queryByText('Open claim reserves')).not.toBeInTheDocument();
  });
});

describe('InsuranceDashboard held premium', () => {
  it('raises an alert and a card when premium is held past the remittance deadline', async () => {
    remittance = {
      data: [
        { policy_id: 'a', policy_no: 'P1', insurer_id: 'i', unremitted_amount: 10, receipt_date: '2026-10-01', deadline_date: '2026-10-02', status: 'overdue' },
        { policy_id: 'b', policy_no: 'P2', insurer_id: 'i', unremitted_amount: 10, receipt_date: '2026-10-01', deadline_date: '2026-10-02', status: 'overdue' },
        { policy_id: 'c', policy_no: 'P3', insurer_id: 'i', unremitted_amount: 10, receipt_date: '2026-10-17', deadline_date: '2026-10-17', status: 'due_today' },
      ],
      error: null,
    };
    setup();
    expect(await screen.findByText('Premium on 2 policies are held past the remittance deadline.')).toBeInTheDocument();
    expect(screen.getByText('Premium on 1 policy must be remitted today.')).toBeInTheDocument();
    expect(card('Premium past remittance deadline').textContent).toContain('2');
    expect(mockRpc).toHaveBeenCalledWith('ins_unremitted_premium_report', { p_as_of: expect.stringMatching(/^\d{4}-\d{2}-\d{2}$/) });
  });

  it('points to the rules screen when premium is held but no deadline is approved', async () => {
    remittance = {
      data: [{ policy_id: 'a', policy_no: 'P1', insurer_id: 'i', unremitted_amount: 10, receipt_date: '2026-10-01', deadline_date: null, status: 'deadline_not_set' }],
      error: null,
    };
    setup();
    expect(await screen.findByText(/no remittance deadline is approved, so deadlines cannot be checked/i)).toBeInTheDocument();
    expect(card('Premium past remittance deadline').textContent).toContain('No remittance deadline is approved yet');
  });

  it('still shows the rest of the dashboard when the held-premium report fails', async () => {
    remittance = { data: null, error: { message: 'INS_FORBIDDEN: insurance access is required' } };
    setup();
    await screen.findByText('Policies in force');
    expect(screen.queryByText('Premium past remittance deadline')).not.toBeInTheDocument();
  });
});
