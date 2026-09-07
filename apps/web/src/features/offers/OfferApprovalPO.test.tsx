import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import OfferApprovalPO from './OfferApprovalPO';

// Fourth/final step of the procurement happy path. Real logic worth
// pinning down: Budget Controller must pick a winning offer as part of
// approving (bundled into the same Approve action, not a separate
// step), and everything downstream of that just carries the choice
// forward read-only. Also covers the offerStageQueue filter (nothing
// still at offer-entry, nothing with zero offers) and the
// offer-submitter self-approval block, same pattern as ApprovalQueue.

function renderScreen() {
  return render(
    <MemoryRouter>
      <OfferApprovalPO />
    </MemoryRouter>
  );
}

const OFFER_A = { id: 'o1', vendor_name: 'Acme Supplies', quotation_amount: 4000000, quantity: 100, submitted_by: 'other-user' };
const OFFER_B = { id: 'o2', vendor_name: 'Bulk Traders', quotation_amount: 3800000, quantity: 100, submitted_by: 'other-user' };

function makeRequest(overrides: Record<string, unknown> = {}) {
  return {
    id: 'req1',
    item_description: 'Cement for foundation',
    requester: { name: 'Amina' },
    current_stage: {
      name: 'Budget Controller',
      requires_offer_entry: false,
      requires_offer_selection: true,
      blocks_offer_submitter_approval: false,
      threshold_amount: 5000000,
    },
    offers: [OFFER_A, OFFER_B],
    selected_offer: null,
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
  },
}));

function setup(opts: { queue?: unknown[]; decisionError?: { message: string } | null; userId?: string | null } = {}) {
  const { queue = [makeRequest()], decisionError = null, userId = 'u1' } = opts;
  const rpcCalls: Array<[string, unknown]> = [];
  mockRpcRef = vi.fn((fnName: string, params?: unknown) => {
    rpcCalls.push([fnName, params]);
    if (fnName === 'get_my_approval_queue') return Promise.resolve({ data: queue, error: null });
    if (fnName === 'record_approval_decision') return Promise.resolve({ data: null, error: decisionError });
    throw new Error(`unhandled rpc: ${fnName}`);
  });
  mockGetUserRef = vi.fn().mockResolvedValue({ data: { user: userId ? { id: userId } : null } });
  return { rpcCalls };
}

beforeEach(() => {
  vi.clearAllMocks();
});

describe('OfferApprovalPO', () => {
  it('excludes rows still at the offer-entry stage or with no offers on file', async () => {
    setup({
      queue: [
        makeRequest({ id: 'stillEntry', current_stage: { name: 'Procurement', requires_offer_entry: true, requires_offer_selection: false, blocks_offer_submitter_approval: false }, offers: [] }),
        makeRequest({ id: 'noOffers', current_stage: { name: 'Finance', requires_offer_entry: false, requires_offer_selection: false, blocks_offer_submitter_approval: false }, offers: [] }),
      ],
    });

    renderScreen();

    await waitFor(() => expect(screen.getByText('Nothing waiting on you right now.')).toBeInTheDocument());
  });

  it('shows a "Pick a winner" chip and the competing offer count at Budget Controller', async () => {
    setup();

    renderScreen();

    await waitFor(() => expect(screen.getByText('Pick a winner')).toBeInTheDocument());
    expect(screen.getByText('2 competing')).toBeInTheDocument();
  });

  it('blocks approving at Budget Controller until a winning offer is selected', async () => {
    const user = userEvent.setup();
    const { rpcCalls } = setup();

    renderScreen();
    await waitFor(() => expect(screen.getByText('Cement for foundation')).toBeInTheDocument());

    await user.click(screen.getByRole('button', { name: 'Approve' }));
    const dialog = await screen.findByRole('dialog');
    await user.click(within(dialog).getByRole('button', { name: /confirm/i }));

    expect(await screen.findByText(/pick a winning offer before approving/i)).toBeInTheDocument();
    expect(rpcCalls.filter(([name]) => name === 'record_approval_decision')).toHaveLength(0);
  });

  it('sends the selected offer id and removes the row on a successful approval', async () => {
    const user = userEvent.setup();
    const { rpcCalls } = setup();

    renderScreen();
    await waitFor(() => expect(screen.getByText('Cement for foundation')).toBeInTheDocument());

    await user.click(screen.getByRole('button', { name: 'Approve' }));
    const dialog = await screen.findByRole('dialog');
    await user.click(within(dialog).getByLabelText(/bulk traders/i));
    await user.click(within(dialog).getByRole('button', { name: /confirm/i }));

    await waitFor(() => expect(screen.queryByText('Cement for foundation')).not.toBeInTheDocument());
    const decisionCall = rpcCalls.find(([name]) => name === 'record_approval_decision');
    expect(decisionCall?.[1]).toMatchObject({ p_request_id: 'req1', p_decision: 'approved', p_selected_offer_id: 'o2' });
  });

  it('does not require selection downstream of Budget Controller, where a winner is already on file', async () => {
    const user = userEvent.setup();
    const { rpcCalls } = setup({
      queue: [
        makeRequest({
          current_stage: { name: 'Finance', requires_offer_entry: false, requires_offer_selection: false, blocks_offer_submitter_approval: false, threshold_amount: null },
          offers: [OFFER_B],
          selected_offer: OFFER_B,
        }),
      ],
    });

    renderScreen();
    await waitFor(() => expect(screen.getByText('Cement for foundation')).toBeInTheDocument());
    expect(screen.queryByText('Pick a winner')).not.toBeInTheDocument();
    expect(screen.getByText(/Bulk Traders \(3,800,000\)/)).toBeInTheDocument();

    await user.click(screen.getByRole('button', { name: 'Approve' }));
    const dialog = await screen.findByRole('dialog');
    await user.click(within(dialog).getByRole('button', { name: /confirm/i }));

    await waitFor(() => expect(rpcCalls.filter(([name]) => name === 'record_approval_decision')).toHaveLength(1));
    const decisionCall = rpcCalls.find(([name]) => name === 'record_approval_decision');
    // no selection UI is shown at this stage, but the dialog still
    // defaults to the request's already-chosen offer rather than null
    expect(decisionCall?.[1]).toMatchObject({ p_selected_offer_id: 'o2' });
  });

  it('requires a comment to reject', async () => {
    const user = userEvent.setup();
    setup();

    renderScreen();
    await waitFor(() => expect(screen.getByText('Cement for foundation')).toBeInTheDocument());

    await user.click(screen.getByRole('button', { name: 'Reject' }));
    const dialog = await screen.findByRole('dialog');
    await user.click(within(dialog).getByRole('button', { name: /confirm/i }));

    expect(await screen.findByText(/a comment is required when rejecting/i)).toBeInTheDocument();
  });

  it('blocks Approve/Reject when the reviewer already submitted one of the competing offers', async () => {
    setup({
      queue: [
        makeRequest({
          current_stage: { name: 'Budget Controller', requires_offer_entry: false, requires_offer_selection: true, blocks_offer_submitter_approval: true, threshold_amount: 5000000 },
          offers: [{ ...OFFER_A, submitted_by: 'u1' }, OFFER_B],
        }),
      ],
      userId: 'u1',
    });

    renderScreen();

    await waitFor(() => expect(screen.getByText('You submitted an offer')).toBeInTheDocument());
    expect(screen.getByRole('button', { name: 'Approve' })).toBeDisabled();
    expect(screen.getByRole('button', { name: 'Reject' })).toBeDisabled();
  });
});
