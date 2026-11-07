import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { createQueryLog } from '../../test/queryChain';
import EditInvoice from './EditInvoice';

// EditInvoice is a unified search + edit screen over two tables
// (supplier_invoices and receivable_invoices). What is worth pinning down
// client-side, because the database only ever sees the final update:
//
//  - the two result sets are merged into one list, newest invoice first,
//    each tagged with its source;
//  - search filters apply to the right table and column (the account
//    filter is vendor_account_id on one table and client_account_id on the
//    other), and "Source" skips the table that is not wanted;
//  - the update payload per source: organization_id is NEVER sent (it is
//    locked after creation), `status` is only sent for receivables, numbers
//    are parsed, blank VAT becomes 0 and a blank description becomes null;
//  - validation blocks the write; a failed update keeps the form open.

const SUPPLIER = {
  id: 's1',
  invoice_number: 'SINV-9',
  invoice_date: '2026-09-02',
  amount_incl_vat: 118000,
  vat_amount: 18000,
  currency: 'UGX',
  description: 'Cement',
  invoice_type: 'po_related',
  cost_center_id: 'cc1',
  organization_id: 'org1',
  prf_oif_number: 'UGN-UG-000001',
  vendor_account_id: 'v1',
  vendor_account: { name: 'Acme Supplies', account_code: 'V-1' },
  organization: { company_code: 'CO1', site_name: 'Kampala HQ' },
  created_at: '2026-09-02T08:00:00Z',
};

const RECEIVABLE = {
  id: 'r1',
  invoice_number: 'RINV-5',
  invoice_date: '2026-09-05',
  amount_incl_vat: 236000,
  vat_amount: 36000,
  currency: 'USD',
  description: 'Consulting',
  status: 'open',
  cost_center_id: null,
  organization_id: 'org1',
  prf_oif_number: 'UGN-UG-000002',
  client_account_id: 'c1',
  client_account: [{ name: 'Retail Co', account_code: 'C-1' }],
  organization: [{ company_code: 'CO1', site_name: 'Kampala HQ' }],
  created_at: '2026-09-05T08:00:00Z',
};

const mockFrom = vi.fn();
vi.mock('../../lib/supabaseClient', () => ({
  supabase: { from: (...args: unknown[]) => mockFrom(...args) },
}));

const q = createQueryLog();
let updates: { table: string; payload: Record<string, unknown>; column: unknown; value: unknown }[];

function setup(
  opts: { supplier?: unknown[]; receivable?: unknown[]; updateError?: { message: string } | null } = {},
) {
  const { supplier = [SUPPLIER], receivable = [RECEIVABLE], updateError = null } = opts;
  q.reset();
  updates = [];

  mockFrom.mockImplementation((table: string) => {
    switch (table) {
      case 'supplier_invoices':
      case 'receivable_invoices': {
        const t = q.chain(table, table === 'supplier_invoices' ? supplier : receivable);
        t.update = (payload: Record<string, unknown>) => ({
          eq: (column: unknown, value: unknown) => {
            updates.push({ table, payload, column, value });
            return Promise.resolve({ error: updateError });
          },
        });
        return t;
      }
      case 'cost_centers':
        return q.chain(table, [{ id: 'cc1', tenant_id: 't1', name: 'Site A', project_code: 'PRJ-1', budget_amount: 0, created_at: '' }]);
      case 'organizations':
        return q.chain(table, [{ id: 'org1', company_code: 'CO1', site_name: 'Kampala HQ' }]);
      case 'account_categories':
        return q.chain(table, [{ id: 'cat1', code: 'VEND', name: 'Vendors' }]);
      case 'accounts':
        return q.chain(table, [
          { id: 'v1', account_code: 'V-1', name: 'Acme Supplies', category_id: 'cat1' },
          { id: 'c1', account_code: 'C-1', name: 'Retail Co', category_id: null },
        ]);
      default:
        throw new Error(`setup: no handler for table "${table}"`);
    }
  });
}

beforeEach(() => {
  vi.clearAllMocks();
});

const rowFor = (invoiceNo: string) => screen.getByText(invoiceNo).closest('tr') as HTMLElement;

async function startEdit(user: ReturnType<typeof userEvent.setup>, invoiceNo: string, heading: string) {
  await user.click(within(rowFor(invoiceNo)).getByRole('button', { name: /edit/i }));
  const h = await screen.findByRole('heading', { name: heading });
  return within(h.parentElement as HTMLElement);
}

describe('EditInvoice', () => {
  describe('search results', () => {
    it('merges supplier and receivable invoices into one list, newest first, with source tags', async () => {
      setup();
      render(<EditInvoice />);

      await screen.findByText('SINV-9');
      const bodyRows = screen.getAllByRole('row').slice(1);
      expect(bodyRows).toHaveLength(2);
      expect(within(bodyRows[0]).getByText('RINV-5')).toBeInTheDocument();
      expect(within(bodyRows[0]).getByText('Receivable')).toBeInTheDocument();
      expect(within(bodyRows[0]).getByText('open')).toBeInTheDocument();
      expect(within(bodyRows[1]).getByText('SINV-9')).toBeInTheDocument();
      expect(within(bodyRows[1]).getByText('Supplier')).toBeInTheDocument();
      expect(within(bodyRows[1]).getByText('PO Related')).toBeInTheDocument();
    });

    it('resolves account and organization labels from either an embedded object or a one-element array', async () => {
      setup();
      render(<EditInvoice />);

      await screen.findByText('SINV-9');
      expect(within(rowFor('SINV-9')).getByText('V-1 — Acme Supplies')).toBeInTheDocument();
      expect(within(rowFor('RINV-5')).getByText('C-1 — Retail Co')).toBeInTheDocument();
      expect(within(rowFor('RINV-5')).getByText('CO1 — Kampala HQ')).toBeInTheDocument();
    });

    it('queries only the supplier table when Source is "Supplier Invoice"', async () => {
      const user = userEvent.setup();
      setup();
      render(<EditInvoice />);
      await screen.findByText('SINV-9');

      await user.click(screen.getByLabelText('Source'));
      await user.click(await screen.findByRole('option', { name: 'Supplier Invoice' }));
      q.reset();
      await user.click(screen.getByRole('button', { name: 'Search' }));

      await waitFor(() => expect(q.callsTo('supplier_invoices', 'select')).toHaveLength(1));
      expect(q.callsTo('receivable_invoices')).toHaveLength(0);
    });

    it('applies invoice number and date filters to both tables', async () => {
      const user = userEvent.setup();
      setup();
      render(<EditInvoice />);
      await screen.findByText('SINV-9');

      await user.type(screen.getByLabelText('Invoice No'), ' 9 ');
      await user.type(screen.getByLabelText('Date From'), '2026-09-01');
      await user.type(screen.getByLabelText('Date To'), '2026-09-30');
      q.reset();
      await user.click(screen.getByRole('button', { name: 'Search' }));

      await waitFor(() => expect(q.callsTo('receivable_invoices', 'ilike')).toHaveLength(1));
      for (const table of ['supplier_invoices', 'receivable_invoices']) {
        expect(q.callsTo(table, 'ilike')[0].args).toEqual(['invoice_number', '%9%']);
        expect(q.callsTo(table, 'gte')[0].args).toEqual(['invoice_date', '2026-09-01']);
        expect(q.callsTo(table, 'lte')[0].args).toEqual(['invoice_date', '2026-09-30']);
      }
    });

    it('shows a load error instead of an empty list when a query fails', async () => {
      setup();
      mockFrom.mockImplementation((table: string) =>
        table === 'supplier_invoices' ? q.chain(table, [], new Error('JWT expired')) : q.chain(table, []),
      );
      render(<EditInvoice />);

      expect(await screen.findByText('JWT expired')).toBeInTheDocument();
    });
  });

  describe('editing a supplier invoice', () => {
    it('sends a clean update payload that never includes organization_id or status', async () => {
      const user = userEvent.setup();
      setup();
      render(<EditInvoice />);
      await screen.findByText('SINV-9');
      const form = await startEdit(user, 'SINV-9', 'Edit Supplier Invoice — SINV-9');

      const invoiceNo = form.getByLabelText(/^invoice no/i);
      await user.clear(invoiceNo);
      await user.type(invoiceNo, '  SINV-9B ');
      const amount = form.getByLabelText(/^amount/i);
      await user.clear(amount);
      await user.type(amount, '120000');
      await user.clear(form.getByLabelText(/^vat amount/i));
      await user.clear(form.getByLabelText(/^description/i));
      await user.click(form.getByRole('button', { name: 'Save' }));

      await waitFor(() => expect(updates).toHaveLength(1));
      expect(updates[0]).toEqual({
        table: 'supplier_invoices',
        payload: {
          invoice_number: 'SINV-9B',
          invoice_date: '2026-09-02',
          vendor_account_id: 'v1',
          amount_incl_vat: 120000,
          vat_amount: 0,
          currency: 'UGX',
          description: null,
          cost_center_id: 'cc1',
        },
        column: 'id',
        value: 's1',
      });
      expect(updates[0].payload).not.toHaveProperty('organization_id');
      expect(updates[0].payload).not.toHaveProperty('status');
      await waitFor(() =>
        expect(screen.queryByRole('heading', { name: /^Edit Supplier Invoice/ })).not.toBeInTheDocument(),
      );
    });

    it('keeps the organization read-only', async () => {
      const user = userEvent.setup();
      setup();
      render(<EditInvoice />);
      await screen.findByText('SINV-9');
      const form = await startEdit(user, 'SINV-9', 'Edit Supplier Invoice — SINV-9');

      expect(form.getByLabelText(/^organization/i)).toBeDisabled();
      expect(form.getByLabelText(/^prf \/ oif no/i)).toBeDisabled();
    });
  });

  describe('editing a receivable invoice', () => {
    it('sends client_account_id and status, and still never organization_id', async () => {
      const user = userEvent.setup();
      setup();
      render(<EditInvoice />);
      await screen.findByText('RINV-5');
      const form = await startEdit(user, 'RINV-5', 'Edit Receivable Invoice — RINV-5');

      await user.click(form.getByLabelText(/^status/i));
      await user.click(await screen.findByRole('option', { name: 'Paid' }));
      await user.click(form.getByRole('button', { name: 'Save' }));

      await waitFor(() => expect(updates).toHaveLength(1));
      expect(updates[0].table).toBe('receivable_invoices');
      expect(updates[0].payload).toEqual({
        invoice_number: 'RINV-5',
        invoice_date: '2026-09-05',
        client_account_id: 'c1',
        amount_incl_vat: 236000,
        vat_amount: 36000,
        currency: 'USD',
        description: 'Consulting',
        status: 'paid',
        cost_center_id: null,
      });
      expect(updates[0]).toMatchObject({ column: 'id', value: 'r1' });
    });

    it('only offers a Status field for receivables', async () => {
      const user = userEvent.setup();
      setup();
      render(<EditInvoice />);
      await screen.findByText('SINV-9');
      const form = await startEdit(user, 'SINV-9', 'Edit Supplier Invoice — SINV-9');

      expect(form.queryByLabelText(/^status/i)).not.toBeInTheDocument();
    });
  });

  describe('validation and failures', () => {
    it('requires an invoice number before writing anything', async () => {
      const user = userEvent.setup();
      setup();
      render(<EditInvoice />);
      await screen.findByText('SINV-9');
      const form = await startEdit(user, 'SINV-9', 'Edit Supplier Invoice — SINV-9');

      await user.clear(form.getByLabelText(/^invoice no/i));
      await user.click(form.getByRole('button', { name: 'Save' }));

      expect(await form.findByText('Account, invoice number, date, and amount are required.')).toBeInTheDocument();
      expect(updates).toHaveLength(0);
    });

    it('rejects an amount of zero', async () => {
      const user = userEvent.setup();
      setup();
      render(<EditInvoice />);
      await screen.findByText('SINV-9');
      const form = await startEdit(user, 'SINV-9', 'Edit Supplier Invoice — SINV-9');

      const amount = form.getByLabelText(/^amount/i);
      await user.clear(amount);
      await user.type(amount, '0');
      await user.click(form.getByRole('button', { name: 'Save' }));

      expect(await form.findByText('Amount must be a valid number greater than 0.')).toBeInTheDocument();
      expect(updates).toHaveLength(0);
    });

    it('keeps the form open and shows the database error when the update fails', async () => {
      const user = userEvent.setup();
      setup({ updateError: { message: 'Organization cannot be changed after creation' } });
      render(<EditInvoice />);
      await screen.findByText('SINV-9');
      const form = await startEdit(user, 'SINV-9', 'Edit Supplier Invoice — SINV-9');

      await user.click(form.getByRole('button', { name: 'Save' }));

      expect(await form.findByText('Organization cannot be changed after creation')).toBeInTheDocument();
      expect(screen.getByRole('heading', { name: 'Edit Supplier Invoice — SINV-9' })).toBeInTheDocument();
    });

    it('shows a failed account lookup in the form instead of leaving the dropdown silently empty', async () => {
      const user = userEvent.setup();
      setup();
      const base = mockFrom.getMockImplementation() as (table: string) => unknown;
      mockFrom.mockImplementation((table: string) =>
        table === 'accounts' ? q.chain(table, [], new Error('permission denied for table accounts')) : base(table),
      );
      render(<EditInvoice />);
      await screen.findByText('SINV-9');
      const form = await startEdit(user, 'SINV-9', 'Edit Supplier Invoice — SINV-9');

      expect(await form.findByText('permission denied for table accounts')).toBeInTheDocument();
      expect(updates).toHaveLength(0);
    });

    it('closes the form on Cancel without writing', async () => {
      const user = userEvent.setup();
      setup();
      render(<EditInvoice />);
      await screen.findByText('SINV-9');
      const form = await startEdit(user, 'SINV-9', 'Edit Supplier Invoice — SINV-9');

      await user.click(form.getByRole('button', { name: 'Cancel' }));

      await waitFor(() =>
        expect(screen.queryByRole('heading', { name: /^Edit Supplier Invoice/ })).not.toBeInTheDocument(),
      );
      expect(updates).toHaveLength(0);
    });
  });
});