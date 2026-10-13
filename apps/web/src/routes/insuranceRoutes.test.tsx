import { Suspense } from 'react';
import { render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter, Routes } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { insuranceRoutes } from './insuranceRoutes';
import { insuranceNodes } from '../modules/portals/ShellConfigs';

const mockUseAuth = vi.fn();
vi.mock('../lib/authContext', () => ({ useAuth: () => mockUseAuth() }));

const mockRpc = vi.fn();
vi.mock('../lib/supabaseClient', () => ({
  supabase: { rpc: (...args: unknown[]) => mockRpc(...args) },
}));

// Only the page under test is stubbed; other lazy pages never load unless routed to.
vi.mock('../modules/portals/insurance/pages/commission/CommissionPage', () => ({
  default: () => <div>Commission page</div>,
}));
vi.mock('../modules/portals/insurance/pages/commission/CommissionStatements', () => ({
  default: () => <div>Commission statement page</div>,
}));

function renderAt(path: string) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <Suspense fallback={<div>Loading</div>}>
        <Routes>{insuranceRoutes}</Routes>
      </Suspense>
    </MemoryRouter>
  );
}

beforeEach(() => {
  mockUseAuth.mockReset();
  mockRpc.mockReset();
  mockUseAuth.mockReturnValue({ session: { user: { id: 'u1' } }, loading: false });
});

describe('insurance commission route', () => {
  it('opens /insurance/commission for a user with an insurance role', async () => {
    mockRpc.mockResolvedValue({ data: true, error: null });
    renderAt('/insurance/commission');
    await waitFor(() => expect(screen.getByText('Commission page')).toBeInTheDocument());
    expect(mockRpc).toHaveBeenCalledWith('has_module_role', {
      p_module: 'insurance',
      p_roles: ['admin', 'manager', 'member'],
    });
  });

  it('opens /insurance/commission/statements for a user with an insurance role, and denies others', async () => {
    mockRpc.mockResolvedValue({ data: true, error: null });
    const first = renderAt('/insurance/commission/statements');
    await waitFor(() => expect(screen.getByText('Commission statement page')).toBeInTheDocument());
    first.unmount();
    mockRpc.mockResolvedValue({ data: false, error: null });
    renderAt('/insurance/commission/statements');
    await waitFor(() => expect(screen.getByText('Not available to you')).toBeInTheDocument());
    expect(screen.queryByText('Commission statement page')).not.toBeInTheDocument();
  });

  it('denies a direct URL visit when the user has no insurance role', async () => {
    mockRpc.mockResolvedValue({ data: false, error: null });
    renderAt('/insurance/commission');
    await waitFor(() => expect(screen.getByText('Not available to you')).toBeInTheDocument());
    expect(screen.queryByText('Commission page')).not.toBeInTheDocument();
  });

  it('denies when there is no session, without calling the server', () => {
    mockUseAuth.mockReturnValue({ session: null, loading: false });
    renderAt('/insurance/commission');
    expect(screen.getByText('Not available to you')).toBeInTheDocument();
    expect(mockRpc).not.toHaveBeenCalled();
  });
});

describe('insurance nav', () => {
  it('has a Commission entry pointing at the routed path', () => {
    const node = insuranceNodes.find((n) => n.id === 'ins-commission');
    expect(node?.to).toBe('/insurance/commission');
    expect(node?.requiredRoles).toBeUndefined();
  });

  it('has a Commission Statement entry pointing at the routed path', () => {
    const node = insuranceNodes.find((n) => n.id === 'ins-commission-statements');
    expect(node?.to).toBe('/insurance/commission/statements');
    expect(node?.requiredRoles).toBeUndefined();
  });
});
