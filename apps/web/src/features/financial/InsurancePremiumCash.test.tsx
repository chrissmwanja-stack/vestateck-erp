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
beforeEach(() => {
  call.mockReset().mockResolvedValue([{ id: 'p1', policy_no: 'POL-01', status: 'active', currency: 'UGX', client_name: 'Acme', insurer_name: 'Alpha' }]);
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
    await screen.findByText('INS_CASH_FORBIDDEN: Finance required');
    expect(screen.queryByText('POL-01')).not.toBeInTheDocument();
  });
});
