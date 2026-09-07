import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import ApprovalQueue from './ApprovalQueue';

function renderQueue() {
  return render(
    <MemoryRouter>
      <ApprovalQueue />
    </MemoryRouter>
  );
}

// Third step of the procurement happy path. Two things worth pinning
// down beyond what the SQL side (record_approval_decision) already
// covers: the client-side dedup that keeps this queue from double-
// showing rows already owned by OfferEntry.tsx/OfferApprovalPO.tsx, and
// the offer-submitter self-approval block (a reviewer can't approve
// their own vendor quote at a stage configured to require someone
// else).

function makeRequest(overrides: Record<string, unknown> = {}) {
  return {
    id: 'req1',
    item_description: 'Cement for foundation',
    quantity: 100,
    requester: { name: 'Amina' },
    department: { name: 'Procurement' },
    cost_center: { project_code: 'PRJ-001' },
    current_stage: { name: 'Cost Control Manager', requires_offer_entry: false, blocks_offer_submitter_approval: false },
    latest_offer: null,
    acting_on_behalf_of: null,
    ...overrides,
  };
}

let mockRpcRef = vi.fn();
let mockGetUserRef = vi.fn();

vi.mock('../../lib/supabaseClient', () => ({
  supabase: {
    rpc: (...args: [string, unknown?]) => mockRpcRef(...args),
    auth: { getUser: () => mockGetUserRef() },
    channel: () => ({
      on: function on() { return this; },
      subscribe: () => ({}),
    }),
    removeChannel: () => {},
  },
}));

function setup(opts: {
  queue?: unknown[];
  decisionError?: { message: string } | null;
  cancelError?: { message: string } | null;
  userId?: string | null;
} = {}) {
  const { queue = [makeRequest()], decisionError = null, cancelError = null, userId = 'u1' } = opts;

  const rpcCalls: Array<[string, unknown]> = [];
  mockRpcRef = vi.fn((fnName: string, params?: unknown) => {
    rpcCalls.push([fnName, params]);
    if (fnName === 'get_my_approval_queue') return Promise.resolve({ data: queue, error: null });
    if (fnName === 'record_approval_decision') return Promise.resolve({ data: null, error: decisionError });
    if (fnName === 'cancel_request') return Promise.resolve({ data: null, error: cancelError });
    throw new Error(`unhandled rpc: ${fnName}`);
  });
  mockGetUserRef = vi.fn().mockResolvedValue({ data: { user: userId ? { id: userId } : null } });

  return { rpcCalls };
}

beforeEach(() => {
  vi.clearAllMocks();
});

describe('ApprovalQueue', () => {
  it('excludes a row that is at an offer-entry stage with no offer yet (owned by OfferEntry.tsx)', async () => {
    setup({ queue: [makeRequest({ current_stage: { name: 'Procurement', requires_offer_entry: true, blocks_offer_submitter_approval: false }, latest_offer: null })] });

    renderQueue();

    await waitFor(() => expect(screen.getByText('Nothing waiting on you right now.')).toBeInTheDocument());
  });

  it('excludes a row that already has an offer but is not at an offer-entry stage (owned by OfferApprovalPO.tsx)', async () => {
    setup({
      queue: [
        makeRequest({
          current_stage: { name: 'Budget Controller', requires_offer_entry: false, blocks_offer_submitter_approval: false },
          latest_offer: { submitted_by: 'someone-else' },
        }),
      ],
    });

    renderQueue();

    await waitFor(() => expect(screen.getByText('Nothing waiting on you right now.')).toBeInTheDocument());
  });

  it('shows a plain (non-offer) request in this queue', async () => {
    setup();

    renderQueue();

    await waitFor(() => expect(screen.getByText('Cement for foundation')).toBeInTheDocument());
  });

  it('blocks Approve/Reject and shows a chip when the reviewer is also the offer submitter', async () => {
    // requires_offer_entry:true + an offer already present is the
    // documented transient edge case (insert trigger normally advances
    // the stage in the same transaction) that still must show here
    // rather than vanish -- see the offerHandledElsewhere comment.
    setup({
      queue: [
        makeRequest({
          current_stage: { name: 'Budget Controller', requires_offer_entry: true, blocks_offer_submitter_approval: true },
          latest_offer: { submitted_by: 'u1' },
        }),
      ],
      userId: 'u1',
    });

    renderQueue();

    await waitFor(() => expect(screen.getByText('You submitted this offer')).toBeInTheDocument());
    expect(screen.getByRole('button', { name: 'Approve' })).toBeDisabled();
    expect(screen.getByRole('button', { name: 'Reject' })).toBeDisabled();
  });

  it('requires a comment to reject, and removes the row from the queue on success', async () => {
    const user = userEvent.setup();
    const { rpcCalls } = setup();

    renderQueue();
    await waitFor(() => expect(screen.getByText('Cement for foundation')).toBeInTheDocument());

    await user.click(screen.getByRole('button', { name: 'Reject' }));
    const dialog = await screen.findByRole('dialog');
    await user.click(within(dialog).getByRole('button', { name: /confirm/i }));
    expect(await screen.findByText(/a comment is required when rejecting/i)).toBeInTheDocument();

    await user.type(within(dialog).getByLabelText(/reason \(required\)/i), 'Budget exceeded');
    await user.click(within(dialog).getByRole('button', { name: /confirm/i }));

    await waitFor(() => expect(screen.queryByText('Cement for foundation')).not.toBeInTheDocument());
    const decisionCall = rpcCalls.find(([name]) => name === 'record_approval_decision');
    expect(decisionCall?.[1]).toMatchObject({ p_request_id: 'req1', p_decision: 'rejected', p_comment: 'Budget exceeded' });
  });

  it('approves without requiring a comment, and shows a server error without removing the row', async () => {
    const user = userEvent.setup();
    setup({ decisionError: { message: 'stage mismatch' } });

    renderQueue();
    await waitFor(() => expect(screen.getByText('Cement for foundation')).toBeInTheDocument());

    await user.click(screen.getByRole('button', { name: 'Approve' }));
    const dialog = await screen.findByRole('dialog');
    await user.click(within(dialog).getByRole('button', { name: /confirm/i }));

    expect(await screen.findByText('stage mismatch')).toBeInTheDocument();
    expect(screen.getByText('Cement for foundation')).toBeInTheDocument();
  });

  it('requires a reason to cancel, and removes the row from the queue on success', async () => {
    const user = userEvent.setup();
    setup();

    renderQueue();
    await waitFor(() => expect(screen.getByText('Cement for foundation')).toBeInTheDocument());

    await user.click(screen.getByRole('button', { name: /cancel request/i }));
    const dialog = await screen.findByRole('dialog');
    await user.click(within(dialog).getByRole('button', { name: /confirm cancellation/i }));
    expect(await screen.findByText(/a reason is required to cancel/i)).toBeInTheDocument();

    await user.type(within(dialog).getByLabelText(/reason \(required\)/i), 'Duplicate request');
    await user.click(within(dialog).getByRole('button', { name: /confirm cancellation/i }));

    await waitFor(() => expect(screen.queryByText('Cement for foundation')).not.toBeInTheDocument());
  });

  it('shows a "PO exists" chip when the request already has a purchase order', async () => {
    setup({ queue: [makeRequest({ purchase_order: { id: 'po1' } })] });

    renderQueue();

    await waitFor(() => expect(screen.getByText('PO exists')).toBeInTheDocument());
  });
});
