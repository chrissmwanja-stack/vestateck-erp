import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import FinancialAuditTrail from './FinancialAuditTrail';
import { mockSupabaseRpc } from '../../test/rpcHarness';

// Finance B: the audit trail screen. It is a thin, read-only view over
// fin_audit_trail() + fin_audit_gaps(), so what is worth pinning down is
// the client-side behaviour that can actually be wrong: that the RPC is
// called with the right entity type and id, that a server refusal is
// surfaced rather than swallowed, and that "not recorded" is shown as such
// instead of being faked into a blank cell.

const INVOICE = {
  id: 'inv-1',
  invoice_number: 'INV-100',
  invoice_date: '2026-10-01',
  amount_incl_vat: 1160,
  currency: 'UGX',
};

const TRAIL = [
  {
    hop: 1,
    stage: 'document',
    happened_at: '2026-10-01T09:00:00Z',
    actor_id: null,
    actor_name: null,
    summary: 'INV-100',
    detail: 'the document itself',
    journal_id: null,
    document_id: null,
    document_name: null,
    amount: 1160,
    currency: 'UGX',
    status: null,
  },
  {
    hop: 2,
    stage: 'journal',
    happened_at: '2026-10-01T09:00:01Z',
    actor_id: 'u-fin',
    actor_name: 'Fin User',
    summary: 'Supplier invoice INV-100',
    detail: null,
    journal_id: 'je-1',
    document_id: null,
    document_name: null,
    amount: null,
    currency: null,
    status: 'posted',
  },
  {
    hop: 3,
    stage: 'posted',
    happened_at: '2026-10-01T09:00:01Z',
    actor_id: 'u-fin',
    actor_name: 'Fin User',
    summary: 'Posted by Fin User',
    detail: null,
    journal_id: 'je-1',
    document_id: null,
    document_name: null,
    amount: null,
    currency: null,
    status: 'posted',
  },
];

const GAPS = [
  {
    journal_entry_id: 'je-9',
    source_type: 'manual',
    entry_date: '2026-09-01',
    description: 'Opening balance',
    gap: 'no initiator recorded for this posting',
  },
];

const mockFrom = vi.fn();
const mockRpc = vi.fn();

vi.mock('../../lib/supabaseClient', () => ({
  supabase: {
    from: (...args: [string]) => mockFrom(...args),
    rpc: (...args: [string, unknown?]) => mockRpc(...args),
  },
}));

let tableData: Record<string, unknown[]> = {};

function builderFor(table: string) {
  const builder: any = {};
  for (const m of ['select', 'eq', 'gte', 'lte', 'in', 'order', 'limit']) builder[m] = () => builder;
  builder.then = (resolve: (v: { data: unknown; error: unknown }) => void) =>
    resolve({ data: tableData[table] ?? [], error: null });
  return builder;
}

function setup(opts: { trail?: unknown[]; gaps?: unknown[]; trailError?: { message: string } | null } = {}) {
  tableData = {
    supplier_invoices: [INVOICE],
    receivable_invoices: [],
    cash_bank_transactions: [],
    fin_settlements: [],
  };
  mockFrom.mockReset();
  mockRpc.mockReset();
  mockFrom.mockImplementation((table: string) => builderFor(table));
  return mockSupabaseRpc(mockRpc, {
    fin_audit_trail: () =>
      opts.trailError ? { data: null, error: opts.trailError } : { data: opts.trail ?? TRAIL, error: null },
    fin_audit_gaps: () => ({ data: opts.gaps ?? GAPS, error: null }),
  });
}

async function pickInvoice() {
  const picker = await screen.findByLabelText('Document');
  // The option label is long; match the start of it.
  fireEvent.mouseDown(picker);
  const option = await screen.findByText(/INV-100/);
  fireEvent.click(option);
}

describe('FinancialAuditTrail', () => {
  beforeEach(() => {
    mockRpc.mockReset();
    mockFrom.mockReset();
  });

  it('lists recent documents of the chosen type', async () => {
    setup();
    render(<FinancialAuditTrail />);

    await waitFor(() => expect(mockFrom).toHaveBeenCalledWith('supplier_invoices'));
    await pickInvoice();
    // The selection is shown in the picker itself.
    await waitFor(() => expect(screen.getAllByText(/INV-100/).length).toBeGreaterThan(0));
  });

  it('calls fin_audit_trail with the entity type and id, then renders the hops in order', async () => {
    const { callsTo } = setup();
    render(<FinancialAuditTrail />);
    await pickInvoice();
    fireEvent.click(screen.getByRole('button', { name: /trace/i }));

    await waitFor(() => expect(callsTo('fin_audit_trail').length).toBe(1));
    expect(callsTo('fin_audit_trail')[0].args).toMatchObject({
      p_entity_type: 'supplier_invoice',
      p_entity_id: 'inv-1',
    });

    await waitFor(() => expect(screen.getByText('Posted by Fin User')).toBeTruthy());
    expect(screen.getByText('the document itself')).toBeTruthy();
    expect(screen.getByText('Supplier invoice INV-100')).toBeTruthy();
  });

  it('shows "not recorded" for roles the books never captured, instead of inventing them', async () => {
    setup();
    render(<FinancialAuditTrail />);
    await pickInvoice();
    fireEvent.click(screen.getByRole('button', { name: /trace/i }));

    await waitFor(() => expect(screen.getByText(/initiated: not recorded/)).toBeTruthy());
    expect(screen.getByText(/posted: Fin User/)).toBeTruthy();
    expect(screen.getByText(/approved: not recorded/)).toBeTruthy();
  });

  it('surfaces a server refusal rather than showing an empty trail', async () => {
    setup({ trailError: { message: 'fin_trace: supplier_invoice inv-1 not found for your company' } });
    render(<FinancialAuditTrail />);
    await pickInvoice();
    fireEvent.click(screen.getByRole('button', { name: /trace/i }));

    await waitFor(() =>
      expect(screen.getByText(/not found for your company/)).toBeTruthy(),
    );
  });

  it('reports postings with incomplete history alongside the trail', async () => {
    setup();
    render(<FinancialAuditTrail />);
    await pickInvoice();
    fireEvent.click(screen.getByRole('button', { name: /trace/i }));

    await waitFor(() =>
      expect(screen.getByText(/Postings with incomplete history \(1\)/)).toBeTruthy(),
    );
    expect(screen.getByText('no initiator recorded for this posting')).toBeTruthy();
  });
});
