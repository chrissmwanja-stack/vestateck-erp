import { render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import PolicyDetail from './PolicyDetail';

vi.mock('./PolicyCashPanel', () => ({ default: () => <div>Policy cash status</div> }));

let canManage = false;
let status = 'active';
vi.mock('../../access', () => ({ useInsuranceAccess: () => ({ canManage, loading: false }) }));
vi.mock('../../db', () => ({
  errorText: (e: Error) => e.message,
  rpc: vi.fn(() => Promise.resolve({ eligible: true, reason: null })),
  write: vi.fn(),
  rows: async (builder: { name: string }) => builder.name === 'ins_policies' ? [{
    id: 'p1', policy_no: 'POL-1', status, inception_date: '2026-10-01', expiry_date: '2027-10-01',
    sum_insured: 10000, gross_premium: 1000, commission_rate_pct: 10, commission_amount: 100,
    net_premium_to_insurer: 900, currency: 'UGX', renewal_of_id: null, bound_at: null, journal_entry_id: null,
  }] : [],
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
beforeEach(() => { canManage = false; status = 'active'; });
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
