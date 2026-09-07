import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import SupplierInvoices from './SupplierInvoices';

// Regression coverage for a real bug (see AdvancePayments/ReceivableInvoice/
// SupplierInvoiceNonPO/MassSlip -- all five Financial screens shipped with
// the same mistake): "New Supplier Invoice" sent tenant_id: '' on insert.
// The fix resolves tenant_id client-side via app_users right before
// insert (same pattern MaterialCatalogAdmin.tsx uses), and always sends a
// placeholder prf_oif_number (overwritten by the assign_supplier_invoice_oif
// trigger) since codegen doesn't know about triggers. This file pins down
// the resolved tenant_id reaching the insert payload, plus the numeric
// validation around WHT that guards against an invalid ledger entry.

const PO_A = { id: 'po1', po_number: 'PO-001', vendor_name: 'Acme Supplies', amount: 500000 };
const VENDOR_ACCOUNT_A = { id: 'acc1', account_code: 'V-100', name: 'Acme Supplies Ltd', category_id: 'cat1' };
const ORG_A = { id: 'org1', company_code: 'CO1', site_name: 'Kampala HQ' };
const CATEGORY_A = { id: 'cat1', code: 'VEND', name: 'Vendors' };

function makeThenable(data: unknown, error: unknown = null) {
  const builder: any = {
    select: () => builder,
    eq: () => builder,
    ilike: () => builder,
    gte: () => builder,
    lte: () => builder,
    order: () => builder,
    then: (resolve: (v: { data: unknown; error: unknown }) => void) => resolve({ data, error }),
  };
  return builder;
}

let mockFromRef: ReturnType<typeof setup>['mockFrom'];
let mockGetUserRef: ReturnType<typeof setup>['mockGetUser'];

vi.mock('../../lib/supabaseClient', () => ({
  supabase: {
    from: (...args: [string]) => mockFromRef(...args),
    auth: { getUser: () => mockGetUserRef() },
  },
}));

function setup(opts: {
  invoiceRows?: unknown[];
  invoicedPoIds?: string[];
  appUserTenantId?: string | null;
  appUserError?: { message: string } | null;
  insertError?: { message: string } | null;
} = {}) {
  const {
    invoiceRows = [],
    invoicedPoIds = [],
    appUserTenantId = 't1',
    appUserError = null,
    insertError = null,
  } = opts;

  const insertCalls: unknown[] = [];

  const mockFrom = vi.fn((table: string) => {
    if (table === 'supplier_invoices') {
      return {
        select: (cols: string) => {
          // loadOpenPOs uses a plain select('purchase_order_id') with no
          // .eq('invoice_type', ...) filter -- distinguish by column list.
          if (cols === 'purchase_order_id') {
            return makeThenable(invoicedPoIds.map((id) => ({ purchase_order_id: id })));
          }
          return makeThenable(invoiceRows);
        },
        insert: (payload: unknown) => {
          insertCalls.push(payload);
          return Promise.resolve({ error: insertError });
        },
      };
    }
    if (table === 'purchase_orders') {
      return { select: () => ({ order: () => Promise.resolve({ data: [PO_A], error: null }) }) };
    }
    if (table === 'accounts') {
      return { select: () => ({ eq: () => ({ in: () => ({ order: () => Promise.resolve({ data: [VENDOR_ACCOUNT_A], error: null }) }) }) }) };
    }
    if (table === 'organizations') {
      return { select: () => ({ eq: () => ({ order: () => ({ order: () => Promise.resolve({ data: [ORG_A], error: null }) }) }) }) };
    }
    if (table === 'account_categories') {
      return { select: () => ({ eq: () => ({ order: () => Promise.resolve({ data: [CATEGORY_A], error: null }) }) }) };
    }
    if (table === 'app_users') {
      return {
        select: () => ({
          eq: () => ({
            single: () => Promise.resolve({ data: appUserTenantId ? { tenant_id: appUserTenantId } : null, error: appUserError }),
          }),
        }),
      };
    }
    throw new Error(`setup: no handler for table "${table}"`);
  });

  const mockGetUser = vi.fn().mockResolvedValue({ data: { user: { id: 'u1' } } });

  return { mockFrom, mockGetUser, insertCalls };
}

function activate(setupResult: ReturnType<typeof setup>) {
  mockFromRef = setupResult.mockFrom;
  mockGetUserRef = setupResult.mockGetUser;
}

beforeEach(() => {
  vi.clearAllMocks();
});

// Required MUI TextFields render their label with a literal " *" suffix
// (e.g. "Purchase Order *"), and "Invoice No" collides with the plain
// search filter of the same name -- so every entry-form query below is
// scoped to the form itself and uses a regex to tolerate the asterisk.
function entryForm() {
  const heading = screen.getByRole('heading', { name: 'New Supplier Invoice' });
  return within(heading.parentElement as HTMLElement);
}

async function openAndFillMinimalForm(user: ReturnType<typeof userEvent.setup>) {
  await user.click(screen.getByRole('button', { name: /new supplier invoice/i }));
  await waitFor(() => expect(screen.getByRole('heading', { name: 'New Supplier Invoice' })).toBeInTheDocument());
  const form = entryForm();

  await user.click(form.getByLabelText('Organization'));
  await user.click(await screen.findByText('CO1 — Kampala HQ'));
  await user.click(form.getByLabelText(/purchase order/i));
  await user.click(await screen.findByText('PO-001 — Acme Supplies'));
  await user.click(form.getByLabelText(/vendor account/i));
  await user.click(await screen.findByText('V-100 — Acme Supplies Ltd'));
  await user.type(form.getByLabelText(/invoice no/i), 'INV-100');
  await user.type(form.getByLabelText(/invoice date/i), '2026-09-01');
  await user.type(form.getByLabelText(/amount \(incl\. vat\)/i), '150000');
}

describe('SupplierInvoices', () => {
  it('resolves and sends the real tenant_id on insert, not an empty string', async () => {
    const user = userEvent.setup();
    const result = setup({ appUserTenantId: 't1' });
    activate(result);

    render(<SupplierInvoices />);
    await waitFor(() => expect(screen.getByText('No supplier invoices found.')).toBeInTheDocument());

    await openAndFillMinimalForm(user);
    await user.click(screen.getByRole('button', { name: 'Save' }));

    await waitFor(() => expect(result.insertCalls).toHaveLength(1));
    const payload = result.insertCalls[0] as Record<string, unknown>;
    expect(payload.tenant_id).toBe('t1');
    expect(payload.tenant_id).not.toBe('');
  });

  it('always sends the prf_oif_number placeholder (overwritten by a DB trigger)', async () => {
    const user = userEvent.setup();
    const result = setup();
    activate(result);

    render(<SupplierInvoices />);
    await waitFor(() => expect(screen.getByText('No supplier invoices found.')).toBeInTheDocument());
    await openAndFillMinimalForm(user);
    await user.click(screen.getByRole('button', { name: 'Save' }));

    await waitFor(() => expect(result.insertCalls).toHaveLength(1));
    expect((result.insertCalls[0] as Record<string, unknown>).prf_oif_number).toBe('');
  });

  it('blocks save and shows a clear error when the tenant cannot be resolved, without inserting', async () => {
    const user = userEvent.setup();
    const result = setup({ appUserTenantId: null, appUserError: { message: 'no profile row' } });
    activate(result);

    render(<SupplierInvoices />);
    await waitFor(() => expect(screen.getByText('No supplier invoices found.')).toBeInTheDocument());
    await openAndFillMinimalForm(user);
    await user.click(screen.getByRole('button', { name: 'Save' }));

    expect(await screen.findByText('no profile row')).toBeInTheDocument();
    expect(result.insertCalls).toHaveLength(0);
  });

  it('requires all core fields before attempting a save', async () => {
    const user = userEvent.setup();
    const result = setup();
    activate(result);

    render(<SupplierInvoices />);
    await waitFor(() => expect(screen.getByText('No supplier invoices found.')).toBeInTheDocument());
    await user.click(screen.getByRole('button', { name: /new supplier invoice/i }));
    await waitFor(() => expect(screen.getByRole('heading', { name: 'New Supplier Invoice' })).toBeInTheDocument());

    await user.click(entryForm().getByRole('button', { name: 'Save' }));

    expect(await screen.findByText(/organization, po, vendor account, invoice number, invoice date, and amount are required/i)).toBeInTheDocument();
    expect(result.insertCalls).toHaveLength(0);
  });

  it('rejects a WHT amount greater than the invoice amount', async () => {
    const user = userEvent.setup();
    const result = setup();
    activate(result);

    render(<SupplierInvoices />);
    await waitFor(() => expect(screen.getByText('No supplier invoices found.')).toBeInTheDocument());
    await openAndFillMinimalForm(user);
    await user.type(entryForm().getByLabelText('WHT Amount'), '999999999');
    await user.click(entryForm().getByRole('button', { name: 'Save' }));

    expect(await screen.findByText(/wht amount cannot exceed the invoice amount/i)).toBeInTheDocument();
    expect(result.insertCalls).toHaveLength(0);
  });

  it('rejects an amount of zero or less', async () => {
    const user = userEvent.setup();
    const result = setup();
    activate(result);

    render(<SupplierInvoices />);
    await waitFor(() => expect(screen.getByText('No supplier invoices found.')).toBeInTheDocument());
    await user.click(screen.getByRole('button', { name: /new supplier invoice/i }));
    await waitFor(() => expect(screen.getByRole('heading', { name: 'New Supplier Invoice' })).toBeInTheDocument());
    const form = entryForm();
    await user.click(form.getByLabelText('Organization'));
    await user.click(await screen.findByText('CO1 — Kampala HQ'));
    await user.click(form.getByLabelText(/purchase order/i));
    await user.click(await screen.findByText('PO-001 — Acme Supplies'));
    await user.click(form.getByLabelText(/vendor account/i));
    await user.click(await screen.findByText('V-100 — Acme Supplies Ltd'));
    await user.type(form.getByLabelText(/invoice no/i), 'INV-100');
    await user.type(form.getByLabelText(/invoice date/i), '2026-09-01');
    await user.type(form.getByLabelText(/amount \(incl\. vat\)/i), '0');

    await user.click(form.getByRole('button', { name: 'Save' }));

    expect(await screen.findByText(/amount must be a valid number greater than 0/i)).toBeInTheDocument();
    expect(result.insertCalls).toHaveLength(0);
  });

  it('excludes a PO from the open-PO picker once it already has an invoice on file', async () => {
    const user = userEvent.setup();
    const result = setup({ invoicedPoIds: ['po1'] });
    activate(result);

    render(<SupplierInvoices />);
    await waitFor(() => expect(screen.getByText('No supplier invoices found.')).toBeInTheDocument());
    await user.click(screen.getByRole('button', { name: /new supplier invoice/i }));
    await waitFor(() => expect(screen.getByRole('heading', { name: 'New Supplier Invoice' })).toBeInTheDocument());
    const form = entryForm();

    await user.click(form.getByLabelText(/purchase order/i));
    expect(screen.queryByText('PO-001 — Acme Supplies')).not.toBeInTheDocument();
  });
});