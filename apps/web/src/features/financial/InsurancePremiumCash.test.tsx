import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import InsurancePremiumCash from './InsurancePremiumCash';
const { call } = vi.hoisted(() => ({ call: vi.fn() }));
vi.mock('../../modules/portals/insurance/db', () => ({ rpc: call, errorText: (e: Error) => e.message }));
vi.mock('../../modules/portals/insurance/pages/policies/PolicyCashPanel', () => ({
  default: ({ policyId, mode }: { policyId: string; mode: string }) => <div>Cash panel {policyId} ({mode})</div>,
}));
const mount = (path = '/financial-management/insurance-premium-cash') => render(<MemoryRouter initialEntries={[path]}><InsurancePremiumCash /></MemoryRouter>);
const POLICIES = [{ id: 'p1', policy_no: 'POL-01', status: 'active', currency: 'UGX', client_name: 'Acme', insurer_name: 'Alpha' }];
const WAITING = [{
  item_type: 'premium_cash', item_id: 'r1', policy_id: 'p9', policy_no: 'POL-WAIT', client_name: 'Beta', insurer_name: 'Alpha', currency: 'USD',
  kind: 'receipt', amount: 75, submitted_at: new Date().toISOString(), submitted_by_name: 'Mary', is_mine: false,
}];
// Each RPC gets its own answer, so the policy list and the worklist do not share a mock.
const answer = (name: string) => (name === 'ins_finance_pending_approvals' ? Promise.resolve(WAITING) : Promise.resolve(POLICIES));
beforeEach(() => {
  call.mockReset().mockImplementation(answer);
});
describe('Finance policy cash workbench', () => {
  it('selects a policy without needing the Insurance policy route', async () => {
    mount(); await screen.findByText('POL-01');
    fireEvent.click(screen.getByRole('button', { name: 'View cash workflow' }));
    expect(await screen.findByText('Cash panel p1 (finance)')).toBeInTheDocument();
  });
  it('opens a policy deep link and searches through the narrow Finance RPC', async () => {
    mount('/financial-management/insurance-premium-cash?policy=p2');
    expect(await screen.findByText('Cash panel p2 (finance)')).toBeInTheDocument();
    fireEvent.change(screen.getByLabelText('Find policy, client or insurer'), { target: { value: 'Acme' } });
    fireEvent.click(screen.getByRole('button', { name: 'Search' }));
    await waitFor(() => expect(call).toHaveBeenCalledWith('ins_policy_cash_policies', { p_search: 'Acme', p_offset: 0 }));
  });
  it('shows the server Finance authorization error and no policies on denial', async () => {
    call.mockRejectedValue(new Error('INS_CASH_FORBIDDEN: Finance required')); mount();
    // Both the worklist and the policy list report it.
    expect((await screen.findAllByText('INS_CASH_FORBIDDEN: Finance required')).length).toBeGreaterThan(0);
    expect(screen.queryByText('POL-01')).not.toBeInTheDocument();
  });
  it('lists what is waiting for Finance and opens its policy', async () => {
    mount(); await screen.findByText('POL-WAIT');
    expect(call).toHaveBeenCalledWith('ins_finance_pending_approvals');
    fireEvent.click(screen.getByRole('button', { name: 'Review' }));
    expect(await screen.findByText('Cash panel p9 (finance)')).toBeInTheDocument();
  });
  it('shows each policy\'s currency in the lookup', async () => {
    mount(); await screen.findByText('POL-01');
    expect(screen.getByRole('table', { name: 'Premium cash policies' })).toHaveTextContent('UGX');
  });
});
