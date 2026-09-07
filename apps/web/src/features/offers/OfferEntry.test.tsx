import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import OfferEntry from './OfferEntry';

// Second step of the procurement happy path. The real logic worth
// pinning down client-side (the DB also enforces the >= 2 offers rule
// server-side, but this screen mirrors it so the button disables with
// a clear reason instead of failing on submit): the MIN_OFFERS_REQUIRED
// gate on "Send to Budget Controller", the case-insensitive
// duplicate-vendor guard before insert, and numeric validation on the
// offer form.

const REQUEST_NO_OFFERS = {
  id: 'req1',
  item_description: 'Cement for foundation',
  quantity: 100,
  requester: { name: 'Amina' },
  department: { name: 'Procurement' },
  cost_center: { project_code: 'PRJ-001' },
  current_stage: { requires_offer_entry: true },
  offers: [],
};

const REQUEST_ONE_OFFER = {
  ...REQUEST_NO_OFFERS,
  id: 'req2',
  offers: [
    { id: 'o1', vendor_name: 'Acme Supplies', quotation_amount: 5000, quantity: 100, submitted_at: '2026-08-01T00:00:00Z' },
  ],
};

const REQUEST_TWO_OFFERS = {
  ...REQUEST_NO_OFFERS,
  id: 'req3',
  offers: [
    { id: 'o1', vendor_name: 'Acme Supplies', quotation_amount: 5000, quantity: 100, submitted_at: '2026-08-01T00:00:00Z' },
    { id: 'o2', vendor_name: 'Bulk Traders', quotation_amount: 4800, quantity: 100, submitted_at: '2026-08-02T00:00:00Z' },
  ],
};

const REQUEST_NOT_AWAITING = {
  ...REQUEST_NO_OFFERS,
  id: 'req4',
  current_stage: { requires_offer_entry: false },
};

let mockRpcRef = vi.fn();
let mockFromRef = vi.fn();
let mockGetUserRef = vi.fn();

vi.mock('../../lib/supabaseClient', () => ({
  supabase: {
    rpc: (...args: [string, unknown?]) => mockRpcRef(...args),
    from: (...args: [string]) => mockFromRef(...args),
    auth: { getUser: () => mockGetUserRef() },
  },
}));

function setup(opts: {
  queue?: unknown[];
  insertError?: { message: string } | null;
  submitApprovalError?: { message: string } | null;
  userId?: string | null;
} = {}) {
  const { queue = [REQUEST_TWO_OFFERS], insertError = null, submitApprovalError = null, userId = 'u1' } = opts;

  const insertCalls: unknown[] = [];
  const rpcCalls: Array<[string, unknown]> = [];

  mockRpcRef = vi.fn((fnName: string, params?: unknown) => {
    rpcCalls.push([fnName, params]);
    if (fnName === 'get_my_approval_queue') return Promise.resolve({ data: queue, error: null });
    if (fnName === 'submit_offers_for_approval') return Promise.resolve({ data: null, error: submitApprovalError });
    throw new Error(`unhandled rpc: ${fnName}`);
  });

  mockFromRef = vi.fn((table: string) => {
    if (table === 'request_offers') {
      return {
        insert: (payload: unknown) => {
          insertCalls.push(payload);
          return Promise.resolve({ error: insertError });
        },
      };
    }
    throw new Error(`unhandled table: ${table}`);
  });

  mockGetUserRef = vi.fn().mockResolvedValue({ data: { user: userId ? { id: userId } : null } });

  return { insertCalls, rpcCalls };
}

beforeEach(() => {
  vi.clearAllMocks();
});

describe('OfferEntry', () => {
  it('only lists requests currently at the offer-entry stage', async () => {
    setup({ queue: [REQUEST_NO_OFFERS, REQUEST_NOT_AWAITING] });

    render(<OfferEntry />);

    await waitFor(() => expect(screen.getByText('Cement for foundation')).toBeInTheDocument());
    // Only one card should render, not two (both share the same description).
    expect(screen.getAllByText('Cement for foundation')).toHaveLength(1);
  });

  it('disables "Send to Budget Controller" until at least 2 offers are logged', async () => {
    setup({ queue: [REQUEST_ONE_OFFER] });

    render(<OfferEntry />);

    await waitFor(() => expect(screen.getByText('1 offer logged')).toBeInTheDocument());
    expect(screen.getByRole('button', { name: /send to budget controller/i })).toBeDisabled();
    expect(screen.getByText(/1 more offer needed/i)).toBeInTheDocument();
  });

  it('enables "Send to Budget Controller" once 2 offers are logged', async () => {
    setup({ queue: [REQUEST_TWO_OFFERS] });

    render(<OfferEntry />);

    await waitFor(() => expect(screen.getByText('2 offers logged')).toBeInTheDocument());
    expect(screen.getByRole('button', { name: /send to budget controller/i })).toBeEnabled();
  });

  it('rejects a duplicate vendor name (case-insensitive) before inserting', async () => {
    const user = userEvent.setup();
    const { insertCalls } = setup({ queue: [REQUEST_ONE_OFFER] });

    render(<OfferEntry />);
    await waitFor(() => expect(screen.getByText('1 offer logged')).toBeInTheDocument());

    await user.click(screen.getByRole('button', { name: /add offer/i }));
    await user.type(screen.getByLabelText('Vendor name'), 'acme supplies');
    await user.type(screen.getByLabelText('Quotation amount'), '4500');
    await user.click(screen.getByRole('button', { name: /save offer/i }));

    expect(await screen.findByText(/already has a quote on this request/i)).toBeInTheDocument();
    expect(insertCalls).toHaveLength(0);
  });

  it('validates the quotation amount must be a positive number', async () => {
    const user = userEvent.setup();
    const { insertCalls } = setup({ queue: [REQUEST_NO_OFFERS] });

    render(<OfferEntry />);
    await waitFor(() => expect(screen.getByText('0 offers logged')).toBeInTheDocument());

    await user.click(screen.getByRole('button', { name: /add offer/i }));
    await user.type(screen.getByLabelText('Vendor name'), 'New Vendor');
    await user.type(screen.getByLabelText('Quotation amount'), '0');
    await user.click(screen.getByRole('button', { name: /save offer/i }));

    expect(await screen.findByText(/quotation amount must be a number greater than zero/i)).toBeInTheDocument();
    expect(insertCalls).toHaveLength(0);
  });

  it('inserts a valid offer with the resolved submitted_by and reloads the queue', async () => {
    const user = userEvent.setup();
    const { insertCalls, rpcCalls } = setup({ queue: [REQUEST_NO_OFFERS], userId: 'u42' });

    render(<OfferEntry />);
    await waitFor(() => expect(screen.getByText('0 offers logged')).toBeInTheDocument());

    await user.click(screen.getByRole('button', { name: /add offer/i }));
    await user.type(screen.getByLabelText('Vendor name'), 'New Vendor');
    await user.type(screen.getByLabelText('Quotation amount'), '3200');
    await user.click(screen.getByRole('button', { name: /save offer/i }));

    await waitFor(() => expect(insertCalls).toHaveLength(1));
    expect(insertCalls[0]).toMatchObject({
      request_id: 'req1',
      vendor_name: 'New Vendor',
      quotation_amount: 3200,
      submitted_by: 'u42',
    });
    // reload after success
    await waitFor(() => expect(rpcCalls.filter(([name]) => name === 'get_my_approval_queue')).toHaveLength(2));
  });

  it('blocks add-offer with a clear message when the session cannot be determined', async () => {
    const user = userEvent.setup();
    const { insertCalls } = setup({ queue: [REQUEST_NO_OFFERS], userId: null });

    render(<OfferEntry />);
    await waitFor(() => expect(screen.getByText('0 offers logged')).toBeInTheDocument());

    await user.click(screen.getByRole('button', { name: /add offer/i }));
    await user.type(screen.getByLabelText('Vendor name'), 'New Vendor');
    await user.type(screen.getByLabelText('Quotation amount'), '3200');
    await user.click(screen.getByRole('button', { name: /save offer/i }));

    expect(await screen.findByText(/could not determine your session/i)).toBeInTheDocument();
    expect(insertCalls).toHaveLength(0);
  });

  it('sends the request for approval and shows a server error without closing the dialog state incorrectly', async () => {
    const user = userEvent.setup();
    setup({ queue: [REQUEST_TWO_OFFERS], submitApprovalError: { message: 'insufficient offers' } });

    render(<OfferEntry />);
    await waitFor(() => expect(screen.getByText('2 offers logged')).toBeInTheDocument());

    await user.click(screen.getByRole('button', { name: /send to budget controller/i }));
    const dialog = await screen.findByRole('dialog');
    await user.click(within(dialog).getByRole('button', { name: /send for approval/i }));

    expect(await screen.findByText('insufficient offers')).toBeInTheDocument();
  });
});
