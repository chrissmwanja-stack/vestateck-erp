import { render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import InsuranceDashboard from './InsuranceDashboard';
import { formatMoney } from '../logic';

// The dashboard totals money per currency. A USD policy next to a UGX policy gives two
// lines on a card, never one added-up figure.

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

beforeEach(() => {
  mockFrom.mockReset();
  mockRpc.mockReset();
  mockRpc.mockResolvedValue({ data: [], error: null });
  policies = [];
  claims = [];
});

describe('InsuranceDashboard money per currency', () => {
  it('shows one line per currency for premium, commission and reserves', async () => {
    policies = [
      { status: 'active', gross_premium: 1_000_000, commission_amount: 100_000, currency: 'UGX', expiry_date: future },
      { status: 'active', gross_premium: 2_000, commission_amount: 200, currency: 'USD', expiry_date: future },
      { status: 'active', gross_premium: 500_000, commission_amount: 50_000, currency: 'UGX', expiry_date: future },
    ];
    claims = [
      { status: 'notified', reserve_amount: 300_000, ins_policies: { currency: 'UGX' } },
      { status: 'assessing', reserve_amount: 1_500, ins_policies: { currency: 'USD' } },
      { status: 'closed', reserve_amount: 9_999_999, ins_policies: { currency: 'UGX' } },
    ];
    setup();
    await screen.findByText('Policies in force');

    const premium = card('Gross premium in force').textContent ?? '';
    expect(premium).toContain('1,500,000');
    expect(premium).toContain('2,000');
    expect(premium).not.toContain('1,502,000');

    const reserves = card('Open claim reserves').textContent ?? '';
    expect(reserves).toContain('300,000');
    expect(reserves).toContain('1,500');
    expect(reserves).not.toContain('9,999,999');
    expect(reserves).not.toContain('301,500');

    expect(card('Commission in force').textContent).toContain('150,000');
    expect(card('Policies in force').textContent).toContain('3');
  });

  it('shows a single zero in the company currency when there is nothing yet', async () => {
    setup();
    await screen.findByText('Policies in force');
    expect(card('Gross premium in force').textContent).toContain(formatMoney(0, 'UGX'));
  });
});

describe('InsuranceDashboard held premium', () => {
  it('raises an alert and a card when premium is held past the remittance deadline', async () => {
    mockRpc.mockResolvedValue({
      data: [
        { policy_id: 'a', policy_no: 'P1', insurer_id: 'i', unremitted_amount: 10, receipt_date: '2026-10-01', deadline_date: '2026-10-02', status: 'overdue' },
        { policy_id: 'b', policy_no: 'P2', insurer_id: 'i', unremitted_amount: 10, receipt_date: '2026-10-01', deadline_date: '2026-10-02', status: 'overdue' },
        { policy_id: 'c', policy_no: 'P3', insurer_id: 'i', unremitted_amount: 10, receipt_date: '2026-10-17', deadline_date: '2026-10-17', status: 'due_today' },
      ],
      error: null,
    });
    setup();
    expect(await screen.findByText('Premium on 2 policies are held past the remittance deadline.')).toBeInTheDocument();
    expect(screen.getByText('Premium on 1 policy must be remitted today.')).toBeInTheDocument();
    expect(card('Premium past remittance deadline').textContent).toContain('2');
    expect(mockRpc).toHaveBeenCalledWith('ins_unremitted_premium_report', { p_as_of: expect.stringMatching(/^\d{4}-\d{2}-\d{2}$/) });
  });

  it('points to the rules screen when premium is held but no deadline is approved', async () => {
    mockRpc.mockResolvedValue({
      data: [{ policy_id: 'a', policy_no: 'P1', insurer_id: 'i', unremitted_amount: 10, receipt_date: '2026-10-01', deadline_date: null, status: 'deadline_not_set' }],
      error: null,
    });
    setup();
    expect(await screen.findByText(/no remittance deadline is approved, so deadlines cannot be checked/i)).toBeInTheDocument();
    expect(card('Premium past remittance deadline').textContent).toContain('No remittance deadline is approved yet');
  });

  it('still shows the rest of the dashboard when the held-premium report fails', async () => {
    mockRpc.mockResolvedValue({ data: null, error: { message: 'INS_FORBIDDEN: insurance access is required' } });
    setup();
    await screen.findByText('Policies in force');
    expect(screen.queryByText('Premium past remittance deadline')).not.toBeInTheDocument();
  });
});
