import { render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import InsuranceDashboard from './InsuranceDashboard';
import { formatMoney } from '../logic';

// The dashboard totals money per currency. A USD policy next to a UGX policy gives two
// lines on a card, never one added-up figure.

const mockFrom = vi.fn();

vi.mock('../../../../lib/supabaseClient', () => ({
  supabase: { from: (...args: unknown[]) => mockFrom(...args), rpc: vi.fn() },
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
