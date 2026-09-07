import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import InvoiceSubmissionForm from './InvoiceSubmissionForm';

// The Multiplexing sibling of RequestSubmissionForm/OfferEntry: a single
// insert into invoice_requests. tenant_id/requester_id are sent as empty
// strings here because they're filled unconditionally by a BEFORE INSERT
// trigger (set_invoice_request_defaults) -- that's a DB-side concern the
// db-shadow-replay job covers, not this file. What's worth pinning down
// client-side: the vendor/amount validation gate before any insert is
// attempted, the amount reset/clear on success, and the stage-name
// fallback when the embedded workflow_stages select comes back empty.

const mockSingle = vi.fn();
const mockSelect = vi.fn(() => ({ single: mockSingle }));
const mockInsert = vi.fn((_payload: Record<string, unknown>) => ({ select: mockSelect }));
const mockFrom = vi.fn((_table: string) => ({ insert: mockInsert }));

vi.mock('../../lib/supabaseClient', () => ({
  supabase: {
    from: (table: string) => mockFrom(table),
  },
}));

beforeEach(() => {
  mockFrom.mockClear();
  mockInsert.mockClear();
  mockSelect.mockClear();
  mockSingle.mockReset();
});

async function fillAndSubmit(
  user: ReturnType<typeof userEvent.setup>,
  { vendor, amount }: { vendor?: string; amount?: string }
) {
  if (vendor !== undefined) {
    await user.type(screen.getByLabelText('Vendor / Supplier'), vendor);
  }
  if (amount !== undefined) {
    await user.type(screen.getByLabelText('Amount (UGX)'), amount);
  }
  await user.click(screen.getByRole('button', { name: /submit for approval/i }));
}

describe('InvoiceSubmissionForm', () => {
  it('rejects submission with no vendor and no amount, without inserting', async () => {
    const user = userEvent.setup();
    render(<InvoiceSubmissionForm />);

    await user.click(screen.getByRole('button', { name: /submit for approval/i }));

    expect(screen.getByText('Vendor and valid amount are required.')).toBeInTheDocument();
    expect(mockFrom).not.toHaveBeenCalled();
  });

  it('rejects a zero amount', async () => {
    const user = userEvent.setup();
    render(<InvoiceSubmissionForm />);

    await fillAndSubmit(user, { vendor: 'Acme Ltd', amount: '0' });

    expect(screen.getByText('Vendor and valid amount are required.')).toBeInTheDocument();
    expect(mockFrom).not.toHaveBeenCalled();
  });

  it('rejects a non-numeric amount', async () => {
    const user = userEvent.setup();
    render(<InvoiceSubmissionForm />);

    await fillAndSubmit(user, { vendor: 'Acme Ltd', amount: 'abc' });

    // The number input itself blocks non-numeric characters, so "abc"
    // never reaches state -- amount stays empty, which is still caught
    // by the "required" half of the same validation branch.
    expect(screen.getByText('Vendor and valid amount are required.')).toBeInTheDocument();
    expect(mockFrom).not.toHaveBeenCalled();
  });

  it('rejects a vendor name that is only whitespace', async () => {
    const user = userEvent.setup();
    render(<InvoiceSubmissionForm />);

    await fillAndSubmit(user, { vendor: '   ', amount: '5000' });

    expect(screen.getByText('Vendor and valid amount are required.')).toBeInTheDocument();
    expect(mockFrom).not.toHaveBeenCalled();
  });

  it('submits, shows the approval stage, and clears the form on success', async () => {
    mockSingle.mockResolvedValue({
      data: {
        vendor_name: 'Acme Ltd',
        amount: 5000,
        current_stage_id: 'stage1',
        workflow_stages: [{ name: 'Finance Review' }],
      },
      error: null,
    });
    const user = userEvent.setup();
    render(<InvoiceSubmissionForm />);

    await fillAndSubmit(user, { vendor: 'Acme Ltd', amount: '5000' });

    await waitFor(() =>
      expect(screen.getByText(/awaiting approval at the finance review stage/i)).toBeInTheDocument()
    );
    expect(mockFrom).toHaveBeenCalledWith('invoice_requests');
    const insertPayload = mockInsert.mock.calls[0][0] as Record<string, unknown>;
    expect(insertPayload.vendor_name).toBe('Acme Ltd');
    expect(insertPayload.amount).toBe(5000);

    // Back to a fresh form for the next invoice.
    await user.click(screen.getByRole('button', { name: /submit another invoice/i }));
    expect(screen.getByLabelText('Vendor / Supplier')).toHaveValue('');
  });

  it('falls back to a generic queue message when workflow_stages comes back empty', async () => {
    mockSingle.mockResolvedValue({
      data: { vendor_name: 'Acme Ltd', amount: 5000, current_stage_id: null, workflow_stages: [] },
      error: null,
    });
    const user = userEvent.setup();
    render(<InvoiceSubmissionForm />);

    await fillAndSubmit(user, { vendor: 'Acme Ltd', amount: '5000' });

    expect(await screen.findByText(/it's now in the approval queue/i)).toBeInTheDocument();
  });

  it('shows the insert error and leaves the form filled in so the user can retry', async () => {
    mockSingle.mockResolvedValue({ data: null, error: { message: 'tenant_id violates not-null constraint' } });
    const user = userEvent.setup();
    render(<InvoiceSubmissionForm />);

    await fillAndSubmit(user, { vendor: 'Acme Ltd', amount: '5000' });

    await waitFor(() =>
      expect(screen.getByText('tenant_id violates not-null constraint')).toBeInTheDocument()
    );
    expect(screen.getByLabelText('Vendor / Supplier')).toHaveValue('Acme Ltd');
    expect(screen.queryByText('Submit another invoice')).not.toBeInTheDocument();
  });
});