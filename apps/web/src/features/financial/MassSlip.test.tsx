import { render, screen, waitFor, fireEvent } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import MassSlip from './MassSlip';

// This sandbox's jsdom doesn't implement Blob.prototype.text (the real
// Chromium/Node one MassSlip relies on via `await file.text()`).
// Polyfill it with FileReader, which jsdom does implement fully.
if (typeof Blob !== 'undefined' && !Blob.prototype.text) {
  Blob.prototype.text = function (this: Blob) {
    return new Promise<string>((resolve, reject) => {
      const reader = new FileReader();
      reader.onerror = () => reject(reader.error);
      reader.onload = () => resolve(String(reader.result));
      reader.readAsText(this);
    });
  };
}

// Same client-side tenant_id gap as the other four Financial screens
// (see SupplierInvoices.test.tsx): supplier_invoices/receivable_invoices
// have no DB trigger for tenant_id, so handleCommit resolves it via
// app_users right before each row's insert -- but unlike every other
// screen in this family, a failed lookup here fails *silently*: phase
// just reverts to 'preview' with no alert shown. This file pins that
// real (if surprising) behavior down, plus the pieces of validation
// logic unique to a bulk importer: the "PO Number or Cost Center Code,
// one of the two" cross-field rule, case/whitespace-insensitive code
// matching against the loaded lookups, and duplicate-number detection
// that warns but doesn't block a commit.

const ORG_A = { id: 'org1', company_code: 'CO1' };
const COST_CENTER_A = { id: 'cc1', project_code: 'PRJ-001' };
const VENDOR_ACCOUNT_A = { id: 'v1', account_code: 'V-100' };
const OPEN_PO_A = { id: 'po1', po_number: 'PO-001' };

function csv(headers: string[], rows: string[][]) {
  return [headers.join(','), ...rows.map((r) => r.join(','))].join('\n');
}

async function uploadFile(baseElement: HTMLElement, content: string, filename = 'import.csv') {
  const input = baseElement.querySelector('input[type="file"]') as HTMLInputElement;
  const file = new File([content], filename, { type: 'text/csv' });
  fireEvent.change(input, { target: { files: [file] } });
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
  organizations?: unknown[];
  costCenters?: unknown[];
  vendorAccounts?: unknown[];
  openPOs?: unknown[];
  invoicedPoIds?: string[];
  existingInvoiceNumbers?: string[];
  appUserTenantId?: string | null;
  appUserError?: { message: string } | null;
  insertError?: { message: string } | null;
} = {}) {
  const {
    organizations = [ORG_A],
    costCenters = [COST_CENTER_A],
    vendorAccounts = [VENDOR_ACCOUNT_A],
    openPOs = [OPEN_PO_A],
    invoicedPoIds = [],
    existingInvoiceNumbers = [],
    appUserTenantId = 't1',
    appUserError = null,
    insertError = null,
  } = opts;

  const insertCalls: Array<{ table: string; payload: unknown }> = [];

  const mockFrom = vi.fn((table: string) => {
    if (table === 'organizations') {
      return { select: () => ({ eq: () => Promise.resolve({ data: organizations, error: null }) }) };
    }
    if (table === 'cost_centers') {
      return { select: () => Promise.resolve({ data: costCenters, error: null }) };
    }
    if (table === 'accounts') {
      return { select: () => ({ eq: () => ({ in: () => Promise.resolve({ data: vendorAccounts, error: null }) }) }) };
    }
    if (table === 'purchase_orders') {
      return { select: () => Promise.resolve({ data: openPOs, error: null }) };
    }
    if (table === 'petty_cash_floats') {
      return { select: () => ({ eq: () => Promise.resolve({ data: [], error: null }) }) };
    }
    if (table === 'supplier_invoices') {
      return {
        select: (cols: string) => {
          if (cols === 'purchase_order_id') {
            return Promise.resolve({ data: invoicedPoIds.map((id) => ({ purchase_order_id: id })), error: null });
          }
          return Promise.resolve({ data: existingInvoiceNumbers.map((n) => ({ invoice_number: n })), error: null });
        },
        insert: (payload: unknown) => {
          insertCalls.push({ table, payload });
          return Promise.resolve({ error: insertError });
        },
      };
    }
    if (table === 'app_users') {
      return {
        select: () => ({
          eq: () => ({
            single: () =>
              Promise.resolve({
                data: appUserTenantId ? { tenant_id: appUserTenantId } : null,
                error: appUserError,
              }),
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

async function selectSupplierInvoiceImport(user: ReturnType<typeof userEvent.setup>) {
  await user.click(screen.getByLabelText('What are you importing?'));
  await user.click(await screen.findByRole('option', { name: 'Supplier Invoices' }));
}

const SUPPLIER_INVOICE_HEADERS = [
  'organization_code',
  'vendor_account_code',
  'po_number',
  'cost_center_code',
  'invoice_number',
  'invoice_date',
  'due_date',
  'amount_incl_vat',
  'vat_amount',
  'currency',
  'description',
];

describe('MassSlip', () => {
  it('resolves and sends the real tenant_id on each row insert, not an empty string', async () => {
    const result = setup({ appUserTenantId: 't1' });
    activate(result);
    const user = userEvent.setup();

    const { baseElement } = render(<MassSlip />);
    await selectSupplierInvoiceImport(user);

    const body = csv(SUPPLIER_INVOICE_HEADERS, [
      ['CO1', 'V-100', 'PO-001', '', 'INV-500', '2026-09-01', '', '100000', '', '', ''],
    ]);
    await uploadFile(baseElement, body);

    await waitFor(() => expect(screen.getByText('1 ready')).toBeInTheDocument());
    await user.click(screen.getByRole('button', { name: /import 1 valid row/i }));

    await waitFor(() => expect(result.insertCalls).toHaveLength(1));
    const { table, payload } = result.insertCalls[0] as { table: string; payload: Record<string, unknown> };
    expect(table).toBe('supplier_invoices');
    expect(payload.tenant_id).toBe('t1');
    expect(payload.tenant_id).not.toBe('');
  });

  it('leaves the row uncommitted and stays on the preview screen when the tenant cannot be resolved', async () => {
    const result = setup({ appUserTenantId: null, appUserError: { message: 'no profile row' } });
    activate(result);
    const user = userEvent.setup();

    const { baseElement } = render(<MassSlip />);
    await selectSupplierInvoiceImport(user);

    const body = csv(SUPPLIER_INVOICE_HEADERS, [
      ['CO1', 'V-100', 'PO-001', '', 'INV-500', '2026-09-01', '', '100000', '', '', ''],
    ]);
    await uploadFile(baseElement, body);

    await waitFor(() => expect(screen.getByText('1 ready')).toBeInTheDocument());
    await user.click(screen.getByRole('button', { name: /import 1 valid row/i }));

    // No alert is shown for this failure mode -- it just silently drops
    // back to the preview screen without importing anything. Pinning
    // that down here so a future change to this behavior is a deliberate
    // decision, not an accident.
    await waitFor(() => expect(screen.getByRole('button', { name: /import 1 valid row/i })).toBeInTheDocument());
    expect(screen.queryByText('Import Results')).not.toBeInTheDocument();
    expect(result.insertCalls).toHaveLength(0);
  });

  it('requires either PO Number or Cost Center Code for a supplier invoice row', async () => {
    const result = setup();
    activate(result);
    const user = userEvent.setup();

    const { baseElement } = render(<MassSlip />);
    await selectSupplierInvoiceImport(user);

    // Both po_number and cost_center_code left blank.
    const body = csv(SUPPLIER_INVOICE_HEADERS, [
      ['CO1', 'V-100', '', '', 'INV-500', '2026-09-01', '', '100000', '', '', ''],
    ]);
    await uploadFile(baseElement, body);

    await waitFor(() => expect(screen.getByText('1 with errors')).toBeInTheDocument());
    expect(screen.getByText(/either po number or cost center code is required/i)).toBeInTheDocument();
  });

  it('matches account codes case-insensitively and tolerates surrounding whitespace', async () => {
    const result = setup();
    activate(result);
    const user = userEvent.setup();

    const { baseElement } = render(<MassSlip />);
    await selectSupplierInvoiceImport(user);

    const body = csv(SUPPLIER_INVOICE_HEADERS, [
      ['co1', ' v-100 ', 'po-001', '', 'INV-500', '2026-09-01', '', '100000', '', '', ''],
    ]);
    await uploadFile(baseElement, body);

    await waitFor(() => expect(screen.getByText('1 ready')).toBeInTheDocument());
    expect(screen.queryByText(/not found/i)).not.toBeInTheDocument();
  });

  it('flags a duplicate invoice number as a warning rather than an error, and still commits it', async () => {
    const result = setup({ existingInvoiceNumbers: ['INV-100'] });
    activate(result);
    const user = userEvent.setup();

    const { baseElement } = render(<MassSlip />);
    await selectSupplierInvoiceImport(user);

    const body = csv(SUPPLIER_INVOICE_HEADERS, [
      ['CO1', 'V-100', '', 'PRJ-001', 'INV-100', '2026-09-01', '', '100000', '', '', ''],
    ]);
    await uploadFile(baseElement, body);

    await waitFor(() => expect(screen.getByText('1 ready')).toBeInTheDocument());
    expect(screen.queryByText('1 with errors')).not.toBeInTheDocument();
    expect(screen.getByText(/invoice number "INV-100" already exists/i)).toBeInTheDocument();

    await user.click(screen.getByRole('button', { name: /import 1 valid row/i }));

    await waitFor(() => expect(result.insertCalls).toHaveLength(1));
    expect(await screen.findByText('Import Results')).toBeInTheDocument();
    expect(screen.getByText('Imported')).toBeInTheDocument();
  });
});