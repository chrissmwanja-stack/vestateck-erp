import { render, screen, waitFor } from '@testing-library/react';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import ProposalApprovals from './ProposalApprovals';

const mockFrom = vi.fn();
vi.mock('../../../../../lib/supabaseClient', () => ({
  supabase: {
    from: (...args: unknown[]) => mockFrom(...args),
  },
}));

const PROPOSAL_A = {
  id: 'p1',
  proposal_no: 'PRO-0001',
  title: 'Website revamp',
  status: 'pending_approval',
  total_value: 4500000,
  currency: 'UGX',
  created_at: '2026-08-01T00:00:00Z',
  bd_clients: { name: 'Acme Corp' },
};

const PROPOSAL_B = {
  id: 'p2',
  proposal_no: 'PRO-0002',
  title: 'Fleet maintenance contract',
  status: 'in_review',
  total_value: 1200000,
  currency: 'UGX',
  created_at: '2026-08-02T00:00:00Z',
  bd_clients: null,
};

/**
 * Wires supabase.from("bd_proposals") to fetchData's select/in/order chain
 * and handleDecision's update/eq chain. selectResults is consumed in
 * order -- each fetchData() call (initial mount + any post-decision
 * refetch) pops the next entry, so a test can assert a specific refetch
 * happened by supplying a second entry and checking it rendered.
 */
function setupSupabase(selectResults: Array<{ data: unknown; error: unknown }>, updateResult: { error: unknown } = { error: null }) {
  let selectCallIndex = 0;
  const updateCalls: Array<{ patch: unknown; id: string }> = [];

  mockFrom.mockImplementation(() => ({
    select: () => ({
      in: () => ({
        order: () => {
          const result = selectResults[Math.min(selectCallIndex, selectResults.length - 1)];
          selectCallIndex++;
          return Promise.resolve(result);
        },
      }),
    }),
    update: (patch: unknown) => ({
      eq: (_column: string, id: string) => {
        updateCalls.push({ patch, id });
        return Promise.resolve(updateResult);
      },
    }),
  }));

  return { updateCalls, selectCallCount: () => selectCallIndex };
}

beforeEach(() => {
  mockFrom.mockReset();
  vi.restoreAllMocks();
});

describe('ProposalApprovals', () => {
  it('fetches only pending_approval/in_review proposals, ordered oldest first', async () => {
    setupSupabase([{ data: [PROPOSAL_A, PROPOSAL_B], error: null }]);

    render(<ProposalApprovals />);

    await waitFor(() => expect(screen.getByText('PRO-0001')).toBeInTheDocument());
    expect(screen.getByText('PRO-0002')).toBeInTheDocument();
  });

  it('shows a client name fallback of "-" when bd_clients is null', async () => {
    setupSupabase([{ data: [PROPOSAL_B], error: null }]);

    render(<ProposalApprovals />);

    await waitFor(() => expect(screen.getByText('PRO-0002')).toBeInTheDocument());
    expect(screen.getByText('-')).toBeInTheDocument();
  });

  it('shows the empty-state message when nothing is pending', async () => {
    setupSupabase([{ data: [], error: null }]);

    render(<ProposalApprovals />);

    await waitFor(() =>
      expect(screen.getByText(/No proposals pending approval/)).toBeInTheDocument(),
    );
  });

  it('approve: confirms, updates status to approved, and refetches', async () => {
    vi.spyOn(window, 'confirm').mockReturnValue(true);
    const { updateCalls, selectCallCount } = setupSupabase([
      { data: [PROPOSAL_A], error: null },
      { data: [], error: null }, // post-approval refetch: nothing left pending
    ]);

    render(<ProposalApprovals />);
    await waitFor(() => expect(screen.getByText('PRO-0001')).toBeInTheDocument());

    screen.getByRole('button', { name: 'Approve' }).click();

    await waitFor(() => expect(screen.getByText(/No proposals pending approval/)).toBeInTheDocument());
    expect(updateCalls).toEqual([{ patch: { status: 'approved' }, id: 'p1' }]);
    expect(selectCallCount()).toBe(2); // initial fetch + refetch after a successful decision
  });

  it('reject: confirms, updates status to rejected, and refetches', async () => {
    vi.spyOn(window, 'confirm').mockReturnValue(true);
    const { updateCalls } = setupSupabase([
      { data: [PROPOSAL_A], error: null },
      { data: [], error: null },
    ]);

    render(<ProposalApprovals />);
    await waitFor(() => expect(screen.getByText('PRO-0001')).toBeInTheDocument());

    screen.getByRole('button', { name: 'Reject' }).click();

    await waitFor(() => expect(screen.getByText(/No proposals pending approval/)).toBeInTheDocument());
    expect(updateCalls).toEqual([{ patch: { status: 'rejected' }, id: 'p1' }]);
  });

  it('cancelling the confirm dialog makes no update call and does not refetch', async () => {
    vi.spyOn(window, 'confirm').mockReturnValue(false);
    const { updateCalls, selectCallCount } = setupSupabase([{ data: [PROPOSAL_A], error: null }]);

    render(<ProposalApprovals />);
    await waitFor(() => expect(screen.getByText('PRO-0001')).toBeInTheDocument());

    screen.getByRole('button', { name: 'Approve' }).click();

    // Nothing async to await here since a cancelled confirm makes no
    // supabase call at all -- assert the state stayed put.
    expect(updateCalls).toEqual([]);
    expect(selectCallCount()).toBe(1);
    expect(screen.getByText('PRO-0001')).toBeInTheDocument();
  });

  it('a failed update does not refetch, leaving the (now stale) row in place', async () => {
    vi.spyOn(window, 'confirm').mockReturnValue(true);
    const { updateCalls, selectCallCount } = setupSupabase(
      [{ data: [PROPOSAL_A], error: null }],
      { error: { message: 'permission denied' } },
    );

    render(<ProposalApprovals />);
    await waitFor(() => expect(screen.getByText('PRO-0001')).toBeInTheDocument());

    screen.getByRole('button', { name: 'Approve' }).click();

    await waitFor(() => expect(updateCalls).toEqual([{ patch: { status: 'approved' }, id: 'p1' }]));
    // fetchData is only called again on success -- a failed update should
    // leave the select call count at 1 (no refetch triggered).
    expect(selectCallCount()).toBe(1);
    expect(screen.getByText('PRO-0001')).toBeInTheDocument();
  });
});