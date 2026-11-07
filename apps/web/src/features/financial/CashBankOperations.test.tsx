import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import CashBankOperations from './CashBankOperations';

// CashBankOperations records the cash/bank leg of every settlement. The
// client-side branching worth pinning down, because nothing else catches
// it (the DB only sees the final insert/update):
//
//  - the payload that reaches cash_bank_transactions: the real tenant_id
//    (not ''), a numeric amount, trimmed text, and bank_account only for
//    bank transactions;
//  - validation before any write (required fields, amount > 0, tenant
//    resolution failure);
//  - a RECEIPT against a RECEIVABLE INVOICE is the only combination that
//    marks the invoice paid -- nothing in the DB does it -- and if that
//    second write fails the transaction must still stand, with a warning;
//  - the reference picker: receivable invoices are limited to open ones,
//    the other types are not, and switching "Settles Against" clears any
//    reference already chosen so a stale id cannot be saved against the
//    wrong table;
//  - the results list resolves a label per reference type and falls back
//    to a dash when the referenced row is not visible.

type Call = { table: string; method: string; args: unknown[] };

const SUPPLIER_INV = { id: 'si1', invoice_number: 'SINV-001' };
const RECEIVABLE_INV = { id: 'ri1', invoice_number: 'RINV-001' };
const SLIP = { id: 'sl1', slip_number: 'SLP-001' };

const mockFrom = vi.fn();
const mockResolveTenantId = vi.fn();

vi.mock('../../lib/supabaseClient', () => ({
  supabase: { from: (...args: unknown[]) => mockFrom(...args) },
}));
vi.mock('../../lib/authContext', () => ({ useAuth: () => ({ session: { user: { id: 'u1' } } }) }));
vi.mock('../../lib/ResolveTenantId', () => ({
  resolveTenantId: (...args: unknown[]) => mockResolveTenantId(...args),
}));

let calls: Call[];
let inserts: Record<string, unknown>[];
let updates: { payload: Record<string, unknown>; column: unknown; value: unknown }[];

// A chainable, awaitable stand-in for a Supabase query builder. Every
// builder method records itself so tests can assert which filters ran.
function chain(table: string, data: unknown[], error: { message: string } | null = null) {
  const builder: Record<string, unknown> = {};
  for (const method of ['select', 'eq', 'in', 'order', 'gte', 'lte']) {
    builder[method] = (...args: unknown[]) => {
      calls.push({ table, method, args });
      return builder;
    };
  }
  builder.then = (resolve: (v: unknown) => unknown, reject?: (e: unknown) => unknown) =>
    Promise.resolve({ data, error }).then(resolve, reject);
  return builder;
}

function setup(
  opts: {
    transactions?: unknown[];
    supplierInvoices?: unknown[];
    receivableInvoices?: unknown[];
    slips?: unknown[];
    insertError?: { message: string } | null;
    statusUpdateError?: { message: string } | null;
    tenant?: { ok: true; tenantId: string } | { ok: false; error: string };
  } = {},
) {
  const {
    transactions = [],
    supplierInvoices = [SUPPLIER_INV],
    receivableInvoices = [RECEIVABLE_INV],
    slips = [SLIP],
    insertError = null,
    statusUpdateError = null,
    tenant = { ok: true as const, tenantId: 'tenant-42' },
  } = opts;

  calls = [];
  inserts = [];
  updates = [];
  mockResolveTenantId.mockResolvedValue(tenant);

  mockFrom.mockImplementation((table: string) => {
    switch (table) {
      case 'cash_bank_transactions': {
        const t = chain(table, transactions);
        t.insert = (payload: Record<string, unknown>) => {
          inserts.push(payload);
          return Promise.resolve({ error: insertError });
        };
        return t;
      }
      case 'supplier_invoices':
        return chain(table, supplierInvoices);
      case 'expenditure_slips':
        return chain(table, slips);
      case 'receivable_invoices': {
        const t = chain(table, receivableInvoices);
        t.update = (payload: Record<string, unknown>) => ({
          eq: (column: unknown, value: unknown) => {
            updates.push({ payload, column, value });
            return Promise.resolve({ error: statusUpdateError });
          },
        });
        return t;
      }
      case 'hr_payroll_runs':
        return chain(table, []);
      default:
        throw new Error(`setup: no handler for table "${table}"`);
    }
  });
}

beforeEach(() => {
  vi.clearAllMocks();
});

const callsTo = (table: string, method?: string) =>
  calls.filter((c) => c.table === table && (!method || c.method === method));

function entryForm() {
  const heading = screen.getByRole('heading', { name: 'New Cash / Bank Transaction' });
  return within(heading.parentElement as HTMLElement);
}

async function openForm(user: ReturnType<typeof userEvent.setup>) {
  await user.click(screen.getByRole('button', { name: /new transaction/i }));
  await waitFor(() =>
    expect(screen.getByRole('heading', { name: 'New Cash / Bank Transaction' })).toBeInTheDocument(),
  );
  return entryForm();
}

async function choose(
  user: ReturnType<typeof userEvent.setup>,
  form: ReturnType<typeof entryForm>,
  label: RegExp,
  optionName: string,
) {
  await user.click(form.getByLabelText(label));
  await user.click(await screen.findByRole('option', { name: optionName }));
}

async function pickReference(
  user: ReturnType<typeof userEvent.setup>,
  form: ReturnType<typeof entryForm>,
  label: RegExp,
  optionName: string,
) {
  await user.click(form.getByLabelText(label));
  await user.click(await screen.findByRole('option', { name: optionName }));
}

async function fillAmountAndDate(
  user: ReturnType<typeof userEvent.setup>,
  form: ReturnType<typeof entryForm>,
  amount = '2500',
  date = '2026-09-01',
) {
  await user.type(form.getByLabelText(/^amount/i), amount);
  await user.type(form.getByLabelText(/^transaction date/i), date);
}

describe('CashBankOperations', () => {
  describe('saving a transaction', () => {
    it('sends the real tenant_id and a clean payload, not an empty string', async () => {
      const user = userEvent.setup();
      setup();
      render(<CashBankOperations />);
      const form = await openForm(user);

      await pickReference(user, form, /supplier invoice no/i, 'SINV-001');
      await fillAmountAndDate(user, form);
      await user.type(form.getByLabelText(/bank account/i), '  Stanbic-001 ');
      await user.click(form.getByRole('button', { name: 'Save' }));

      await waitFor(() => expect(inserts).toHaveLength(1));
      expect(inserts[0]).toEqual({
        tenant_id: 'tenant-42',
        transaction_type: 'payment',
        payment_method: 'bank',
        reference_type: 'supplier_invoice',
        reference_id: 'si1',
        amount: 2500,
        currency: 'UGX',
        transaction_date: '2026-09-01',
        bank_account: 'Stanbic-001',
        description: null,
      });
    });

    it('sends bank_account as null for a cash transaction even if one was typed first', async () => {
      const user = userEvent.setup();
      setup();
      render(<CashBankOperations />);
      const form = await openForm(user);

      await pickReference(user, form, /supplier invoice no/i, 'SINV-001');
      await fillAmountAndDate(user, form);
      await user.type(form.getByLabelText(/bank account/i), 'Stanbic-001');
      await choose(user, form, /^payment method/i, 'Cash');
      expect(form.queryByLabelText(/bank account/i)).not.toBeInTheDocument();
      await user.click(form.getByRole('button', { name: 'Save' }));

      await waitFor(() => expect(inserts).toHaveLength(1));
      expect(inserts[0]).toMatchObject({ payment_method: 'cash', bank_account: null });
    });

    it('blocks the save, shows the error and does not insert when the tenant cannot be resolved', async () => {
      const user = userEvent.setup();
      setup({ tenant: { ok: false, error: 'Could not determine your organization. Please refresh and try again.' } });
      render(<CashBankOperations />);
      const form = await openForm(user);

      await pickReference(user, form, /supplier invoice no/i, 'SINV-001');
      await fillAmountAndDate(user, form);
      await user.click(form.getByRole('button', { name: 'Save' }));

      expect(await form.findByText(/could not determine your organization/i)).toBeInTheDocument();
      expect(inserts).toHaveLength(0);
    });

    it('requires a reference, an amount and a date before doing anything', async () => {
      const user = userEvent.setup();
      setup();
      render(<CashBankOperations />);
      const form = await openForm(user);

      await user.click(form.getByRole('button', { name: 'Save' }));

      expect(
        await form.findByText('Reference item, amount, and transaction date are required.'),
      ).toBeInTheDocument();
      expect(mockResolveTenantId).not.toHaveBeenCalled();
      expect(inserts).toHaveLength(0);
    });

    it.each([['0'], ['-5']])('rejects an amount of %s', async (amount) => {
      const user = userEvent.setup();
      setup();
      render(<CashBankOperations />);
      const form = await openForm(user);

      await pickReference(user, form, /supplier invoice no/i, 'SINV-001');
      await fillAmountAndDate(user, form, amount);
      await user.click(form.getByRole('button', { name: 'Save' }));

      expect(await form.findByText('Amount must be a valid number greater than 0.')).toBeInTheDocument();
      expect(inserts).toHaveLength(0);
    });

    it('keeps the form open and shows the database error when the insert fails', async () => {
      const user = userEvent.setup();
      setup({ insertError: { message: 'new row violates row-level security policy' } });
      render(<CashBankOperations />);
      const form = await openForm(user);

      await pickReference(user, form, /supplier invoice no/i, 'SINV-001');
      await fillAmountAndDate(user, form);
      await user.click(form.getByRole('button', { name: 'Save' }));

      expect(await form.findByText('new row violates row-level security policy')).toBeInTheDocument();
      expect(screen.getByRole('heading', { name: 'New Cash / Bank Transaction' })).toBeInTheDocument();
      expect(updates).toHaveLength(0);
    });
  });

  describe('settling a receivable invoice', () => {
    async function saveReceivable(
      user: ReturnType<typeof userEvent.setup>,
      transactionType: 'Payment (money out)' | 'Receipt (money in)',
    ) {
      const form = await openForm(user);
      await choose(user, form, /^transaction type/i, transactionType);
      await choose(user, form, /settles against/i, 'Receivable Invoice');
      await pickReference(user, form, /receivable invoice no/i, 'RINV-001');
      await fillAmountAndDate(user, form);
      return form;
    }

    it('marks the invoice paid when a receipt is recorded against it', async () => {
      const user = userEvent.setup();
      setup();
      render(<CashBankOperations />);
      const form = await saveReceivable(user, 'Receipt (money in)');

      expect(form.getByText('Saving this will mark the selected invoice as paid.')).toBeInTheDocument();
      await user.click(form.getByRole('button', { name: 'Save' }));

      await waitFor(() => expect(updates).toHaveLength(1));
      expect(inserts[0]).toMatchObject({ transaction_type: 'receipt', reference_type: 'receivable_invoice' });
      expect(updates[0]).toEqual({ payload: { status: 'paid' }, column: 'id', value: 'ri1' });
      await waitFor(() =>
        expect(screen.queryByRole('heading', { name: 'New Cash / Bank Transaction' })).not.toBeInTheDocument(),
      );
    });

    it('does not mark the invoice paid for a payment against it', async () => {
      const user = userEvent.setup();
      setup();
      render(<CashBankOperations />);
      const form = await saveReceivable(user, 'Payment (money out)');

      expect(form.queryByText(/mark the selected invoice as paid/i)).not.toBeInTheDocument();
      await user.click(form.getByRole('button', { name: 'Save' }));

      await waitFor(() => expect(inserts).toHaveLength(1));
      expect(updates).toHaveLength(0);
    });

    it('does not touch receivable invoices for a receipt against another reference type', async () => {
      const user = userEvent.setup();
      setup();
      render(<CashBankOperations />);
      const form = await openForm(user);

      await choose(user, form, /^transaction type/i, 'Receipt (money in)');
      await pickReference(user, form, /supplier invoice no/i, 'SINV-001');
      await fillAmountAndDate(user, form);
      await user.click(form.getByRole('button', { name: 'Save' }));

      await waitFor(() => expect(inserts).toHaveLength(1));
      expect(updates).toHaveLength(0);
    });

    it('keeps the saved transaction and warns when marking the invoice paid fails', async () => {
      const user = userEvent.setup();
      setup({ statusUpdateError: { message: 'permission denied' } });
      render(<CashBankOperations />);
      const form = await saveReceivable(user, 'Receipt (money in)');

      await user.click(form.getByRole('button', { name: 'Save' }));

      expect(
        await screen.findByText(
          'Transaction saved, but the invoice could not be marked paid (permission denied). Update its status manually.',
        ),
      ).toBeInTheDocument();
      expect(inserts).toHaveLength(1);
      expect(screen.queryByRole('heading', { name: 'New Cash / Bank Transaction' })).not.toBeInTheDocument();
    });
  });

  describe('reference picker', () => {
    it('limits receivable invoices to open ones and leaves the other types unfiltered', async () => {
      const user = userEvent.setup();
      setup();
      render(<CashBankOperations />);
      const form = await openForm(user);

      calls = [];
      await choose(user, form, /settles against/i, 'Receivable Invoice');
      await waitFor(() => expect(callsTo('receivable_invoices', 'eq')).toHaveLength(1));
      expect(callsTo('receivable_invoices', 'eq')[0].args).toEqual(['status', 'open']);
      expect(form.getByText('Showing open (unpaid) invoices only')).toBeInTheDocument();

      calls = [];
      await choose(user, form, /settles against/i, 'Expenditure Slip');
      await waitFor(() => expect(callsTo('expenditure_slips', 'order')).toHaveLength(1));
      expect(callsTo('expenditure_slips', 'eq')).toHaveLength(0);
      expect(callsTo('expenditure_slips', 'order')[0].args).toEqual(['slip_number']);
    });

    it('clears an already chosen reference when "Settles Against" changes', async () => {
      const user = userEvent.setup();
      setup();
      render(<CashBankOperations />);
      const form = await openForm(user);

      await pickReference(user, form, /supplier invoice no/i, 'SINV-001');
      await choose(user, form, /settles against/i, 'Expenditure Slip');
      expect(form.getByLabelText(/expenditure slip no/i)).toHaveValue('');

      await fillAmountAndDate(user, form);
      await user.click(form.getByRole('button', { name: 'Save' }));

      expect(
        await form.findByText('Reference item, amount, and transaction date are required.'),
      ).toBeInTheDocument();
      expect(inserts).toHaveLength(0);
    });
  });

  describe('transaction list', () => {
    const transactions = [
      {
        id: 't1',
        transaction_type: 'payment',
        payment_method: 'bank',
        reference_type: 'supplier_invoice',
        reference_id: 'si1',
        amount: 1500,
        currency: 'UGX',
        transaction_date: '2026-08-30',
        bank_account: 'Stanbic-001',
        description: 'Cement',
        created_at: '2026-08-30T10:00:00Z',
        recorded_by_user: [{ name: 'Amina' }],
      },
      {
        id: 't2',
        transaction_type: 'receipt',
        payment_method: 'cash',
        reference_type: 'receivable_invoice',
        reference_id: 'missing-invoice',
        amount: 900,
        currency: 'USD',
        transaction_date: '2026-08-31',
        bank_account: null,
        description: null,
        created_at: '2026-08-31T10:00:00Z',
        recorded_by_user: { name: 'Brian' },
      },
    ];

    it('resolves a reference label per type and shows a dash for a row it cannot see', async () => {
      setup({ transactions });
      render(<CashBankOperations />);

      expect(await screen.findByText('Supplier Invoice: SINV-001')).toBeInTheDocument();
      expect(screen.getByText('Receivable Invoice: —')).toBeInTheDocument();
      // One batched label query per reference type, not one per row.
      expect(callsTo('supplier_invoices', 'in')).toHaveLength(1);
      expect(callsTo('receivable_invoices', 'in')).toHaveLength(1);
      expect(callsTo('supplier_invoices', 'in')[0].args).toEqual(['id', ['si1']]);
    });

    it('reads the recorder name from either an embedded object or a one-element array', async () => {
      setup({ transactions });
      render(<CashBankOperations />);

      expect(await screen.findByText('Amina')).toBeInTheDocument();
      expect(screen.getByText('Brian')).toBeInTheDocument();
    });

    it('shows the empty state when there are no transactions', async () => {
      setup({ transactions: [] });
      render(<CashBankOperations />);

      expect(await screen.findByText('No transactions found.')).toBeInTheDocument();
    });

    it('applies the search filters to the query and removes them again on Clear', async () => {
      const user = userEvent.setup();
      setup({ transactions });
      render(<CashBankOperations />);
      await screen.findByText('Supplier Invoice: SINV-001');

      await user.click(screen.getByLabelText('Type'));
      await user.click(await screen.findByRole('option', { name: 'Receipt' }));
      await user.type(screen.getByLabelText('Date From'), '2026-08-01');
      await user.type(screen.getByLabelText('Date To'), '2026-08-31');

      calls = [];
      await user.click(screen.getByRole('button', { name: 'Search' }));
      await waitFor(() => expect(callsTo('cash_bank_transactions', 'eq')).toHaveLength(1));
      expect(callsTo('cash_bank_transactions', 'eq')[0].args).toEqual(['transaction_type', 'receipt']);
      expect(callsTo('cash_bank_transactions', 'gte')[0].args).toEqual(['transaction_date', '2026-08-01']);
      expect(callsTo('cash_bank_transactions', 'lte')[0].args).toEqual(['transaction_date', '2026-08-31']);

      calls = [];
      await user.click(screen.getByRole('button', { name: 'Clear' }));
      await waitFor(() => expect(callsTo('cash_bank_transactions', 'select')).toHaveLength(1));
      expect(callsTo('cash_bank_transactions', 'eq')).toHaveLength(0);
      expect(callsTo('cash_bank_transactions', 'gte')).toHaveLength(0);
      expect(callsTo('cash_bank_transactions', 'lte')).toHaveLength(0);
    });

    it('shows a load error instead of an empty list when the query fails', async () => {
      setup();
      mockFrom.mockImplementation((table: string) => {
        if (table === 'cash_bank_transactions') return chain(table, [], new Error('JWT expired'));
        return chain(table, []);
      });
      render(<CashBankOperations />);

      expect(await screen.findByText('JWT expired')).toBeInTheDocument();
    });
  });
});
