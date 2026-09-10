import { render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import MyApprovals from './MyApprovals';

// Covers the gap list_my_approval_surfaces() (20260909080000_my_approval_surfaces.sql)
// closes: a designated approver outside a module's own staff (payroll
// approvers without HR staff role, today) previously had no nav path to
// their approval screen at all. This page is a pure link-out -- it never
// duplicates a domain's data or actions, so the test surface is just:
// loading, error, empty state, and that each returned surface renders as
// a link to its real route with the right count badge behavior.

const mockRpc = vi.fn();
vi.mock('../../lib/supabaseClient', () => ({
  supabase: {
    rpc: (...args: unknown[]) => mockRpc(...args),
  },
}));

function renderPage() {
  return render(
    <MemoryRouter>
      <MyApprovals />
    </MemoryRouter>
  );
}

beforeEach(() => {
  mockRpc.mockReset();
});

describe('MyApprovals', () => {
  it('shows a spinner while loading', () => {
    mockRpc.mockReturnValue(new Promise(() => {})); // never resolves
    renderPage();

    expect(screen.getByRole('progressbar')).toBeInTheDocument();
  });

  it('calls list_my_approval_surfaces and shows an empty state when nothing is returned', async () => {
    mockRpc.mockResolvedValue({ data: [], error: null });
    renderPage();

    await waitFor(() => expect(screen.getByText(/nothing waiting on you/i)).toBeInTheDocument());
    expect(mockRpc).toHaveBeenCalledWith('list_my_approval_surfaces');
  });

  it('shows an error state when the rpc errors', async () => {
    mockRpc.mockResolvedValue({ data: null, error: { message: 'boom' } });
    renderPage();

    await waitFor(() => expect(screen.getByText('boom')).toBeInTheDocument());
  });

  it('renders a link with a pending-count badge for a surface with items waiting', async () => {
    mockRpc.mockResolvedValue({
      data: [
        {
          surface_key: 'payroll_approvals',
          label: 'Payroll Approvals',
          route: '/hr/payroll/approvals',
          pending_count: 3,
        },
      ],
      error: null,
    });
    renderPage();

    await waitFor(() => expect(screen.getByText('Payroll Approvals')).toBeInTheDocument());
    const link = screen.getByRole('link', { name: /Payroll Approvals/i });
    expect(link).toHaveAttribute('href', '/hr/payroll/approvals');
    expect(screen.getByText('3')).toBeInTheDocument();
  });

  it('renders a surface with no badge when pending_count is null (e.g. SAP payment recording)', async () => {
    mockRpc.mockResolvedValue({
      data: [
        {
          surface_key: 'sap_payment_recording',
          label: 'SAP Payment Recording',
          route: '/sap/payment-approvals',
          pending_count: null,
        },
      ],
      error: null,
    });
    renderPage();

    await waitFor(() => expect(screen.getByText('SAP Payment Recording')).toBeInTheDocument());
    // No numeric badge should render for a null count.
    expect(screen.queryByText('0')).not.toBeInTheDocument();
  });

  it('renders a surface with a zero count and no badge (nothing pending right now, but still an active approver)', async () => {
    mockRpc.mockResolvedValue({
      data: [
        {
          surface_key: 'leave_approvals',
          label: 'Leave Approvals',
          route: '/hr/leaves/approvals',
          pending_count: 0,
        },
      ],
      error: null,
    });
    renderPage();

    await waitFor(() => expect(screen.getByText('Leave Approvals')).toBeInTheDocument());
    expect(screen.queryByText('0')).not.toBeInTheDocument();
  });

  it('renders multiple surfaces, each linking to its own route', async () => {
    mockRpc.mockResolvedValue({
      data: [
        { surface_key: 'payroll_approvals', label: 'Payroll Approvals', route: '/hr/payroll/approvals', pending_count: 2 },
        { surface_key: 'leave_approvals', label: 'Leave Approvals', route: '/hr/leaves/approvals', pending_count: 1 },
      ],
      error: null,
    });
    renderPage();

    await waitFor(() => expect(screen.getByText('Payroll Approvals')).toBeInTheDocument());
    expect(screen.getByText('Leave Approvals')).toBeInTheDocument();
    expect(screen.getByRole('link', { name: /Payroll Approvals/i })).toHaveAttribute(
      'href',
      '/hr/payroll/approvals'
    );
    expect(screen.getByRole('link', { name: /Leave Approvals/i })).toHaveAttribute(
      'href',
      '/hr/leaves/approvals'
    );
  });
});
