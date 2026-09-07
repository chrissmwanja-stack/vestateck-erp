import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import SupplierInvoiceNonPO from './SupplierInvoiceNonPO';

// Same tenant_id regression as SupplierInvoices.tsx (see that file's
// header comment), plus one thing unique to this screen: purchase_order_id
// must never appear in the insert payload -- its absence (NULL) is what
// makes a row a non-PO invoice rather than a schema afterthought.

const COST_CENTER_A = { id: 'cc1', tenant_id: 't1', name: 'Head Office', project_code: 'PRJ-900', budget_amount: 200000, created_at: '2026-01-01' };
const VENDOR_ACCOUNT_A = { id: 'acc1', account_code: 'V-100', name: 'Utility Co', category_id: 'cat1' };
const ORG_A = { id: 'org1', company_code: 'CO1', site_name: 'Kampala HQ' };

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
  appUserTenantId?: string | null;
  appUserError?: { message: string } | null;
  insertError?: { message: string } | null;
} = {}) {
  const { appUserTenantId = 't1', appUserError = null, insertError = null } = opts;
  const insertCalls: unknown[] = [];

  const mockFrom = vi.fn((table: string) => {
    if (table === 'supplier_invoices') {
      return {
        select: () => makeThenable([]),
        insert: (payload: unknown) => {
          insertCalls.push(payload);
          return Promise.resolve({ error: insertError });
        },
      };
    }
    if (table === 'cost_centers') {
      return { select: () => ({ order: () => Promise.resolve({ data: [COST_CENTER_A], error: null }) }) };
    }
    if (table === 'accounts') {
      return { select: () => ({ eq: () => ({ in: () => ({ order: () => Promise.resolve({ data: [VENDOR_ACCOUNT_A], error: null }) }) }) }) };
    }
    if (table === 'organizations') {
      return { select: () => ({ eq: () => ({ order: () => ({ order: () => Promise.resolve({ data: [ORG_A], error: null }) }) }) }) };
    }
    if (table === 'account_categories') {
      return { select: () => ({ eq: () => ({ order: () => Promise.resolve({ data: [], error: null }) }) }) };
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
  await user.click(form.getByLabelText(/cost center/i));
  await user.click(await screen.findByText('PRJ-900 — Head Office'));
  await user.click(form.getByLabelText(/vendor account/i));
  await user.click(await screen.findByText('V-100 — Utility Co'));
  await user.type(form.getByLabelText(/invoice no/i), 'INV-200');
  await user.type(form.getByLabelText(/invoice date/i), '2026-09-01');
  await user.type(form.getByLabelText(/amount \(incl\. vat\)/i), '80000');
}

describe('SupplierInvoiceNonPO', () => {
  it('resolves and sends the real tenant_id on insert, not an empty string', async () => {
    const user = userEvent.setup();
    const result = setup({ appUserTenantId: 't1' });
    activate(result);

    render(<SupplierInvoiceNonPO />);
    await waitFor(() => expect(screen.getByText('No supplier invoices found.')).toBeInTheDocument());
    await openAndFillMinimalForm(user);
    await user.click(entryForm().getByRole('button', { name: 'Save' }));

    await waitFor(() => expect(result.insertCalls).toHaveLength(1));
    const payload = result.insertCalls[0] as Record<string, unknown>;
    expect(payload.tenant_id).toBe('t1');
    expect(payload.tenant_id).not.toBe('');
  });

  it('never sends a purchase_order_id -- its absence is what makes this a non-PO row', async () => {
    const user = userEvent.setup();
    const result = setup();
    activate(result);

    render(<SupplierInvoiceNonPO />);
    await waitFor(() => expect(screen.getByText('No supplier invoices found.')).toBeInTheDocument());
    await openAndFillMinimalForm(user);
    await user.click(entryForm().getByRole('button', { name: 'Save' }));

    await waitFor(() => expect(result.insertCalls).toHaveLength(1));
    expect(result.insertCalls[0] as Record<string, unknown>).not.toHaveProperty('purchase_order_id');
  });

  it('blocks save and shows a clear error when the tenant cannot be resolved, without inserting', async () => {
    const user = userEvent.setup();
    const result = setup({ appUserTenantId: null, appUserError: { message: 'no profile row' } });
    activate(result);

    render(<SupplierInvoiceNonPO />);
    await waitFor(() => expect(screen.getByText('No supplier invoices found.')).toBeInTheDocument());
    await openAndFillMinimalForm(user);
    await user.click(entryForm().getByRole('button', { name: 'Save' }));

    expect(await screen.findByText('no profile row')).toBeInTheDocument();
    expect(result.insertCalls).toHaveLength(0);
  });

  it('requires organization, cost center, vendor account, invoice number, date, and amount', async () => {
    const user = userEvent.setup();
    const result = setup();
    activate(result);

    render(<SupplierInvoiceNonPO />);
    await user.click(screen.getByRole('button', { name: /new supplier invoice/i }));
    await waitFor(() => expect(screen.getByRole('heading', { name: 'New Supplier Invoice' })).toBeInTheDocument());

    await user.click(entryForm().getByRole('button', { name: 'Save' }));

    expect(await screen.findByText(/organization, cost center, vendor account, invoice number, invoice date, and amount are required/i)).toBeInTheDocument();
    expect(result.insertCalls).toHaveLength(0);
  });

  it('rejects a WHT amount greater than the invoice amount', async () => {
    const user = userEvent.setup();
    const result = setup();
    activate(result);

    render(<SupplierInvoiceNonPO />);
    await waitFor(() => expect(screen.getByText('No supplier invoices found.')).toBeInTheDocument());
    await openAndFillMinimalForm(user);
    await user.type(entryForm().getByLabelText('WHT Amount'), '999999999');
    await user.click(entryForm().getByRole('button', { name: 'Save' }));

    expect(await screen.findByText(/wht amount cannot exceed the invoice amount/i)).toBeInTheDocument();
    expect(result.insertCalls).toHaveLength(0);
  });
});