import { render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import PolicyDetail from './PolicyDetail';

vi.mock('./PolicyCashPanel', () => ({ default: () => <div>Policy cash status</div> }));

// Delivers a fully reviewed financial configuration, so the Bind button in these tests is
// gated only by what this file exercises (the foreign-currency block).
vi.mock('./PolicyFinancialConfiguration', async () => {
  const { useEffect } = await import('react');
  return {
    default: ({ onDetails }: { onDetails: (d: unknown) => void }) => {
      useEffect(() => {
        onDetails({
          policy_id: 'p1', policy_no: 'POL-1', status: 'draft', currency, gross_premium: 1000,
          shares: [{ insurer_id: 'i1', is_lead: true, share_pct: 100, commission_rate_pct: 10, insurer_policy_no: null, reviewed: true }],
          charges: [], snapshot: null, can_configure: true, client_name: 'Acme Ltd',
        });
      }, []);
      return null;
    },
  };
});

let canManage = false;
let status = 'active';
let currency = 'UGX';
vi.mock('../../access', () => ({ useInsuranceAccess: () => ({ canManage, loading: false }) }));
vi.mock('../../db', () => ({
  errorText: (e: Error) => e.message,
  rpc: vi.fn(() => Promise.resolve({ eligible: true, reason: null })),
  write: vi.fn(),
  rows: async (builder: { name: string }) => {
    if (builder.name === 'ins_policies') return [{
      id: 'p1', policy_no: 'POL-1', status, inception_date: '2026-10-01', expiry_date: '2027-10-01',
      sum_insured: 10000, gross_premium: 1000, commission_rate_pct: 10, commission_amount: 100,
      net_premium_to_insurer: 900, currency, renewal_of_id: null, bound_at: null, journal_entry_id: null,
    }];
    if (builder.name === 'tenant_ledger_settings') return [{ functional_currency: 'UGX' }];
    return [];
  },
  table: (name: string) => {
    interface Builder { name: string; select: () => Builder; eq: () => Builder; order: () => Builder }
    const builder: Builder = { name, select: () => builder, eq: () => builder, order: () => builder };
    return builder;
  },
}));
function mount() {
  render(<MemoryRouter initialEntries={['/insurance/policies/p1']}><Routes>
    <Route path="/insurance/policies/:id" element={<PolicyDetail />} />
  </Routes></MemoryRouter>);
}
beforeEach(() => { canManage = false; status = 'active'; currency = 'UGX'; });
describe('policy detail reversal access', () => {
  it('does not show reversal to a member', async () => {
    mount();
    await screen.findByText('POL-1');
    expect(screen.queryByRole('button', { name: 'Reverse policy' })).not.toBeInTheDocument();
  });
  it('shows an eligible active policy action to a manager', async () => {
    canManage = true; mount();
    await waitFor(() => expect(screen.getByRole('button', { name: 'Reverse policy' })).toBeEnabled());
  });
  it('does not offer claims, renewals or another reversal on a reversed policy', async () => {
    canManage = true; status = 'reversed'; mount();
    await screen.findByText('Reversed');
    expect(screen.queryByRole('button', { name: 'Reverse policy' })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Report claim' })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Start renewal' })).not.toBeInTheDocument();
  });
});

describe('foreign-currency draft bind', () => {
  it('binds a draft in another currency like any other, and says it binds at the approved inception-date rate', async () => {
    canManage = true; status = 'draft'; currency = 'USD'; mount();
    await screen.findByText(/This draft is in USD, not the company currency \(UGX\)/);
    expect(screen.getByText(/at the approved rate for the inception date/)).toBeInTheDocument();
    await waitFor(() => expect(screen.getByRole('button', { name: 'Bind policy' })).toBeEnabled());
    // The bind is no longer blocked by the currency; the server prices it at the rate.
    expect(screen.getByRole('button', { name: 'Bind policy' }).getAttribute('title') ?? '').not.toContain('not the company currency');
  });

  it('enables bind for a draft in the company currency once the configuration is reviewed', async () => {
    canManage = true; status = 'draft'; currency = 'UGX'; mount();
    await waitFor(() => expect(screen.getByRole('button', { name: 'Bind policy' })).toBeEnabled());
    expect(screen.queryByText(/not the company currency/)).not.toBeInTheDocument();
  });
});
