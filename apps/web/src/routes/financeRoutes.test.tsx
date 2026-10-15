import { Suspense } from 'react';
import { render, screen } from '@testing-library/react';
import { MemoryRouter, Routes } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { financeRoutes } from './financeRoutes';

const { auth, call } = vi.hoisted(() => ({ auth: vi.fn(), call: vi.fn() }));
vi.mock('../lib/authContext', () => ({ useAuth: auth }));
vi.mock('../lib/supabaseClient', () => ({ supabase: { rpc: call } }));
vi.mock('../features/financial/InsurancePremiumCash', () => ({ default: () => <div>Finance premium cash workbench</div> }));
const mount = () => render(<MemoryRouter initialEntries={['/financial-management/insurance-premium-cash?policy=p1']}>
  <Suspense fallback={<div>Loading</div>}><Routes>{financeRoutes}</Routes></Suspense>
</MemoryRouter>);
beforeEach(() => {
  auth.mockReturnValue({ loading: false, session: { user: { id: 'finance' } } });
  call.mockReset();
});
describe('Finance premium cash route', () => {
  it('allows a Finance user without requiring an Insurance role', async () => {
    call.mockResolvedValue({ data: true, error: null }); mount();
    await screen.findByText('Finance premium cash workbench');
    expect(call).toHaveBeenCalledWith('can_access_finance');
    expect(call).not.toHaveBeenCalledWith('has_module_role', expect.anything());
  });
  it('denies a user without Finance access', async () => {
    call.mockResolvedValue({ data: false, error: null }); mount();
    await screen.findByText('Not available to you');
    expect(screen.queryByText('Finance premium cash workbench')).not.toBeInTheDocument();
  });
  it('fails closed if the access check errors', async () => {
    call.mockResolvedValue({ data: null, error: { message: 'Not authorized' } }); mount();
    await screen.findByText('Not available to you');
  });
});
