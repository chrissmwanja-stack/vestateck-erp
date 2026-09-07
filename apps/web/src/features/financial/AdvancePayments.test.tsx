import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import AdvancePayments from './AdvancePayments';

// Same client-side tenant_id gap that shipped across all five Financial
// screens (see SupplierInvoices.test.tsx) -- advance_payments has no
// DB-level default/trigger for tenant_id, so it's resolved via app_users
// right before insert. This file pins that down for AdvancePayments,
// plus the one piece of real branching logic unique to this screen: the
// Apply-to-invoice dialog looks at a different table (and sends a
// different reference_type) depending on whether the advance is a
// payment-to-vendor or a receipt-from-client.

const ACCOUNT_VENDOR = { id: 'acc-v1', account_code: 'V-100', name: 'Acme Supplies Ltd', account_type: 'vendor' };
const ACCOUNT_CLIENT = { id: 'acc-c1', account_code: 'C-200', name: 'Beta Client Ltd', account_type: 'client' };

const ADVANCE_PAYMENT_ROW = {
  id: 'adv1',
  account_id: 'acc-v1',
  account_code: 'V-100',
  account_name: 'Acme Supplies Ltd',
  direction: 'payment',
  amount: 500000,
  currency: 'UGX',
  payment_date: '2026-08-01',
  payment_method: 'bank',
  description: null,
  total_applied: 0,
  remaining_amount: 500000,
};

const ADVANCE_RECEIPT_ROW = {
  id: 'adv2',
  account_id: 'acc-c1',
  account_code: 'C-200',
  account_name: 'Beta Client Ltd',
  direction: 'receipt',
  amount: 300000,
  currency: 'UGX',
  payment_date: '2026-08-02',
  payment_method: 'cash',
  description: null,
  total_applied: 0,
  remaining_amount: 300000,
};

const SUPPLIER_INVOICE_OPEN = { id: 'sinv1', invoice_number: 'SINV-100', amount_incl_vat: 500000 };
const RECEIVABLE_INVOICE_OPEN = { id: 'rinv1', invoice_number: 'RINV-200', amount_incl_vat: 300000 };

function makeThenable(data: unknown, error: unknown = null) {
  const builder: any = {
    select: () => builder,
    eq: () => builder,
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
  accounts?: unknown[];
  advanceRows?: unknown[];
  appUserTenantId?: string | null;
  appUserError?: { message: string } | null;
  insertError?: { message: string } | null;
  supplierInvoices?: unknown[];
  receivableInvoices?: unknown[];
} = {}) {
  const {
    accounts = [ACCOUNT_VENDOR, ACCOUNT_CLIENT],
    advanceRows = [],
    appUserTenantId = 't1',
    appUserError = null,
    insertError = null,
    supplierInvoices = [SUPPLIER_INVOICE_OPEN],
    receivableInvoices = [RECEIVABLE_INVOICE_OPEN],
  } = opts;

  const insertCalls: Array<{ table: string; payload: unknown }> = [];

  const mockFrom = vi.fn((table: string) => {
    if (table === 'accounts') {
      return { select: () => ({ eq: () => ({ order: () => Promise.resolve({ data: accounts, error: null }) }) }) };
    }
    if (table === 'v_advance_payments') {
      return { select: () => ({ eq: () => ({ order: () => Promise.resolve({ data: advanceRows, error: null }) }) }) };
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
    if (table === 'advance_payments') {
      return {
        insert: (payload: unknown) => {
          insertCalls.push({ table, payload });
          return Promise.resolve({ error: insertError });
        },
      };
    }
    if (table === 'supplier_invoices') {
      return { select: () => makeThenable(supplierInvoices) };
    }
    if (table === 'receivable_invoices') {
      return { select: () => makeThenable(receivableInvoices) };
    }
    if (table === 'advance_payment_applications') {
      return {
        insert: (payload: unknown) => {
          insertCalls.push({ table, payload });
          return Promise.resolve({ error: null });
        },
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

function renderScreen() {
  return render(
    <MemoryRouter>
      <AdvancePayments />
    </MemoryRouter>
  );
}

beforeEach(() => {
  vi.clearAllMocks();
});

async function pickSelect(labelText: string, optionName: RegExp | string, user: ReturnType<typeof userEvent.setup>) {
  await user.click(screen.getByLabelText(labelText));
  await user.click(await screen.findByRole('option', { name: optionName }));
}

async function fillMinimalForm(user: ReturnType<typeof userEvent.setup>) {
  await pickSelect('Account', /V-100 — Acme Supplies Ltd/, user);
  await user.type(screen.getByLabelText('Amount'), '150000');
}

describe('AdvancePayments', () => {
  it('resolves and sends the real tenant_id on insert, not an empty string', async () => {
    const result = setup({ appUserTenantId: 't1' });
    activate(result);
    const user = userEvent.setup();

    renderScreen();
    await waitFor(() => expect(screen.getByText(/No advance payments recorded/)).toBeInTheDocument());

    await fillMinimalForm(user);
    await user.click(screen.getByRole('button', { name: 'Record' }));

    await waitFor(() => expect(result.insertCalls).toHaveLength(1));
    const { table, payload } = result.insertCalls[0] as { table: string; payload: Record<string, unknown> };
    expect(table).toBe('advance_payments');
    expect(payload.tenant_id).toBe('t1');
    expect(payload.tenant_id).not.toBe('');
  });

  it('blocks save and shows a clear error when the tenant cannot be resolved, without inserting', async () => {
    const result = setup({ appUserTenantId: null, appUserError: { message: 'no profile row' } });
    activate(result);
    const user = userEvent.setup();

    renderScreen();
    await waitFor(() => expect(screen.getByText(/No advance payments recorded/)).toBeInTheDocument());

    await fillMinimalForm(user);
    await user.click(screen.getByRole('button', { name: 'Record' }));

    expect(await screen.findByText('no profile row')).toBeInTheDocument();
    expect(result.insertCalls).toHaveLength(0);
  });

  it('requires account, amount, and payment date before attempting to save', async () => {
    const result = setup();
    activate(result);
    const user = userEvent.setup();

    renderScreen();
    await waitFor(() => expect(screen.getByText(/No advance payments recorded/)).toBeInTheDocument());

    // Payment Date already defaults to today, so leaving Account and
    // Amount blank is enough to trip this.
    await user.click(screen.getByRole('button', { name: 'Record' }));

    expect(await screen.findByText('Account, amount, and payment date are required.')).toBeInTheDocument();
    expect(result.insertCalls).toHaveLength(0);
  });

  it('never sends a bank account once the method is switched to cash, even if one was typed while it was bank', async () => {
    const result = setup();
    activate(result);
    const user = userEvent.setup();

    renderScreen();
    await waitFor(() => expect(screen.getByText(/No advance payments recorded/)).toBeInTheDocument());

    // Method defaults to "Bank", so the Bank Account field is visible
    // from the start.
    await user.type(screen.getByLabelText('Bank Account'), '9988');
    await fillMinimalForm(user);
    await pickSelect('Method', 'Cash', user);

    await user.click(screen.getByRole('button', { name: 'Record' }));

    await waitFor(() => expect(result.insertCalls).toHaveLength(1));
    const payload = result.insertCalls[0].payload as Record<string, unknown>;
    expect(payload.payment_method).toBe('cash');
    expect(payload.bank_account).toBeNull();
  });

  it('opens the apply dialog against supplier_invoices for a payment-direction row and applies with reference_type supplier_invoice', async () => {
    const result = setup({ advanceRows: [ADVANCE_PAYMENT_ROW, ADVANCE_RECEIPT_ROW] });
    activate(result);
    const user = userEvent.setup();

    renderScreen();
    await waitFor(() => expect(screen.getByText(/Acme Supplies Ltd/)).toBeInTheDocument());

    const vendorRow = screen.getByText(/V-100 — Acme Supplies Ltd/).closest('tr') as HTMLElement;
    await user.click(within(vendorRow).getByRole('button', { name: 'Apply' }));

    const dialog = await screen.findByRole('dialog');
    expect(within(dialog).getByText(/500,000/)).toBeInTheDocument();
    await pickSelect('Invoice', /SINV-100/, user);
    expect(screen.queryByText(/RINV-200/)).not.toBeInTheDocument();

    await user.type(within(dialog).getByLabelText('Amount to apply'), '200000');
    await user.click(within(dialog).getByRole('button', { name: 'Apply' }));

    await waitFor(() => expect(result.insertCalls).toHaveLength(1));
    const { table, payload } = result.insertCalls[0] as { table: string; payload: Record<string, unknown> };
    expect(table).toBe('advance_payment_applications');
    expect(payload.reference_type).toBe('supplier_invoice');
    expect(payload.reference_id).toBe('sinv1');
    expect(payload.advance_payment_id).toBe('adv1');
  });

  it('opens the apply dialog against receivable_invoices for a receipt-direction row and applies with reference_type receivable_invoice', async () => {
    const result = setup({ advanceRows: [ADVANCE_PAYMENT_ROW, ADVANCE_RECEIPT_ROW] });
    activate(result);
    const user = userEvent.setup();

    renderScreen();
    await waitFor(() => expect(screen.getByText(/Beta Client Ltd/)).toBeInTheDocument());

    const clientRow = screen.getByText(/C-200 — Beta Client Ltd/).closest('tr') as HTMLElement;
    await user.click(within(clientRow).getByRole('button', { name: 'Apply' }));

    const dialog = await screen.findByRole('dialog');
    expect(within(dialog).getByText(/300,000/)).toBeInTheDocument();
    await pickSelect('Invoice', /RINV-200/, user);
    expect(screen.queryByText(/SINV-100/)).not.toBeInTheDocument();

    await user.type(within(dialog).getByLabelText('Amount to apply'), '150000');
    await user.click(within(dialog).getByRole('button', { name: 'Apply' }));

    await waitFor(() => expect(result.insertCalls).toHaveLength(1));
    const { table, payload } = result.insertCalls[0] as { table: string; payload: Record<string, unknown> };
    expect(table).toBe('advance_payment_applications');
    expect(payload.reference_type).toBe('receivable_invoice');
    expect(payload.reference_id).toBe('rinv1');
    expect(payload.advance_payment_id).toBe('adv2');
  });
});