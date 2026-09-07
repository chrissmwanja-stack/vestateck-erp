import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import ReceivableInvoice from './ReceivableInvoice';

// Same client-side tenant_id gap that shipped across all five Financial
// screens (see SupplierInvoices.test.tsx): receivable_invoices has no
// DB-level default/trigger for tenant_id, so it's resolved via app_users
// right before insert, and prf_oif_number is always sent as a placeholder
// (overwritten unconditionally by assign_receivable_invoice_oif). This
// file pins both down, plus the one piece of real branching logic unique
// to this screen: "Account Type" is a UI-only category filter (not
// persisted on the invoice) that narrows the Client Account list, and
// switching it clears any client account already chosen so a stale
// selection from the previous category can't slip through.

const ORG_A = { id: 'org1', company_code: 'CO1', site_name: 'Kampala HQ' };
const CATEGORY_RETAIL = { id: 'cat-retail', code: 'RETL', name: 'Retail Clients' };
const CATEGORY_CORP = { id: 'cat-corp', code: 'CORP', name: 'Corporate Clients' };
const CLIENT_RETAIL = { id: 'acc-retail1', account_code: 'C-100', name: 'Retail Co', category_id: 'cat-retail' };
const CLIENT_CORP = { id: 'acc-corp1', account_code: 'C-200', name: 'Corp Co', category_id: 'cat-corp' };

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
  clientAccounts?: unknown[];
  appUserTenantId?: string | null;
  appUserError?: { message: string } | null;
  insertError?: { message: string } | null;
} = {}) {
  const {
    invoiceRows = [],
    clientAccounts = [CLIENT_RETAIL, CLIENT_CORP],
    appUserTenantId = 't1',
    appUserError = null,
    insertError = null,
  } = opts;

  const insertCalls: unknown[] = [];

  const mockFrom = vi.fn((table: string) => {
    if (table === 'receivable_invoices') {
      return {
        select: () => makeThenable(invoiceRows),
        insert: (payload: unknown) => {
          insertCalls.push(payload);
          return Promise.resolve({ error: insertError });
        },
      };
    }
    if (table === 'cost_centers') {
      return { select: () => ({ order: () => Promise.resolve({ data: [], error: null }) }) };
    }
    if (table === 'accounts') {
      return { select: () => ({ eq: () => ({ in: () => ({ order: () => Promise.resolve({ data: clientAccounts, error: null }) }) }) }) };
    }
    if (table === 'organizations') {
      return { select: () => ({ eq: () => ({ order: () => ({ order: () => Promise.resolve({ data: [ORG_A], error: null }) }) }) }) };
    }
    if (table === 'account_categories') {
      return { select: () => ({ eq: () => ({ order: () => Promise.resolve({ data: [CATEGORY_RETAIL, CATEGORY_CORP], error: null }) }) }) };
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

// "Invoice No" appears both as a plain search filter and as a required
// field inside the entry form -- same collision SupplierInvoices.test.tsx
// documents -- so every entry-form query below is scoped to the form.
function entryForm() {
  const heading = screen.getByRole('heading', { name: 'New Receivable Invoice' });
  return within(heading.parentElement as HTMLElement);
}

async function openAndFillMinimalForm(user: ReturnType<typeof userEvent.setup>) {
  await user.click(screen.getByRole('button', { name: /new receivable invoice/i }));
  await waitFor(() => expect(screen.getByRole('heading', { name: 'New Receivable Invoice' })).toBeInTheDocument());
  const form = entryForm();

  await user.click(form.getByLabelText('Organization'));
  await user.click(await screen.findByText('CO1 — Kampala HQ'));
  await user.click(form.getByLabelText(/client account/i));
  await user.click(await screen.findByText('C-100 — Retail Co'));
  await user.type(form.getByLabelText(/invoice no/i), 'RINV-100');
  await user.type(form.getByLabelText(/invoice date/i), '2026-09-01');
  await user.type(form.getByLabelText(/amount \(incl\. vat\)/i), '150000');
}

describe('ReceivableInvoice', () => {
  it('resolves and sends the real tenant_id on insert, not an empty string', async () => {
    const user = userEvent.setup();
    const result = setup({ appUserTenantId: 't1' });
    activate(result);

    render(<ReceivableInvoice />);
    await waitFor(() => expect(screen.getByText('No receivable invoices found.')).toBeInTheDocument());

    await openAndFillMinimalForm(user);
    await user.click(entryForm().getByRole('button', { name: 'Save' }));

    await waitFor(() => expect(result.insertCalls).toHaveLength(1));
    const payload = result.insertCalls[0] as Record<string, unknown>;
    expect(payload.tenant_id).toBe('t1');
    expect(payload.tenant_id).not.toBe('');
  });

  it('always sends the prf_oif_number placeholder (overwritten by a DB trigger)', async () => {
    const user = userEvent.setup();
    const result = setup();
    activate(result);

    render(<ReceivableInvoice />);
    await waitFor(() => expect(screen.getByText('No receivable invoices found.')).toBeInTheDocument());

    await openAndFillMinimalForm(user);
    await user.click(entryForm().getByRole('button', { name: 'Save' }));

    await waitFor(() => expect(result.insertCalls).toHaveLength(1));
    expect((result.insertCalls[0] as Record<string, unknown>).prf_oif_number).toBe('');
  });

  it('blocks save and shows a clear error when the tenant cannot be resolved, without inserting', async () => {
    const user = userEvent.setup();
    const result = setup({ appUserTenantId: null, appUserError: { message: 'no profile row' } });
    activate(result);

    render(<ReceivableInvoice />);
    await waitFor(() => expect(screen.getByText('No receivable invoices found.')).toBeInTheDocument());

    await openAndFillMinimalForm(user);
    await user.click(entryForm().getByRole('button', { name: 'Save' }));

    expect(await screen.findByText('no profile row')).toBeInTheDocument();
    expect(result.insertCalls).toHaveLength(0);
  });

  it('requires all core fields before attempting a save', async () => {
    const user = userEvent.setup();
    const result = setup();
    activate(result);

    render(<ReceivableInvoice />);
    await waitFor(() => expect(screen.getByText('No receivable invoices found.')).toBeInTheDocument());
    await user.click(screen.getByRole('button', { name: /new receivable invoice/i }));
    await waitFor(() => expect(screen.getByRole('heading', { name: 'New Receivable Invoice' })).toBeInTheDocument());

    await user.click(entryForm().getByRole('button', { name: 'Save' }));

    expect(
      await screen.findByText(/organization, client account, invoice number, invoice date, and amount are required/i)
    ).toBeInTheDocument();
    expect(result.insertCalls).toHaveLength(0);
  });

  it('rejects an amount of zero or less', async () => {
    const user = userEvent.setup();
    const result = setup();
    activate(result);

    render(<ReceivableInvoice />);
    await waitFor(() => expect(screen.getByText('No receivable invoices found.')).toBeInTheDocument());
    await user.click(screen.getByRole('button', { name: /new receivable invoice/i }));
    await waitFor(() => expect(screen.getByRole('heading', { name: 'New Receivable Invoice' })).toBeInTheDocument());
    const form = entryForm();

    await user.click(form.getByLabelText('Organization'));
    await user.click(await screen.findByText('CO1 — Kampala HQ'));
    await user.click(form.getByLabelText(/client account/i));
    await user.click(await screen.findByText('C-100 — Retail Co'));
    await user.type(form.getByLabelText(/invoice no/i), 'RINV-100');
    await user.type(form.getByLabelText(/invoice date/i), '2026-09-01');
    await user.type(form.getByLabelText(/amount \(incl\. vat\)/i), '0');

    await user.click(form.getByRole('button', { name: 'Save' }));

    expect(await screen.findByText(/amount must be a valid number greater than 0/i)).toBeInTheDocument();
    expect(result.insertCalls).toHaveLength(0);
  });

  it('narrows Client Account to the chosen Account Type', async () => {
    const user = userEvent.setup();
    const result = setup();
    activate(result);

    render(<ReceivableInvoice />);
    await waitFor(() => expect(screen.getByText('No receivable invoices found.')).toBeInTheDocument());
    await user.click(screen.getByRole('button', { name: /new receivable invoice/i }));
    await waitFor(() => expect(screen.getByRole('heading', { name: 'New Receivable Invoice' })).toBeInTheDocument());
    const form = entryForm();

    await user.click(form.getByLabelText('Account Type'));
    await user.click(await screen.findByRole('option', { name: 'Corporate Clients' }));
    await user.click(form.getByLabelText(/client account/i));

    expect(screen.queryByText('C-100 — Retail Co')).not.toBeInTheDocument();
    expect(await screen.findByText('C-200 — Corp Co')).toBeInTheDocument();
  });

  it('switching Account Type after picking a client clears the stale id, not just its on-screen display', async () => {
    const user = userEvent.setup();
    const result = setup();
    activate(result);

    render(<ReceivableInvoice />);
    await waitFor(() => expect(screen.getByText('No receivable invoices found.')).toBeInTheDocument());
    await user.click(screen.getByRole('button', { name: /new receivable invoice/i }));
    await waitFor(() => expect(screen.getByRole('heading', { name: 'New Receivable Invoice' })).toBeInTheDocument());
    const form = entryForm();

    // Pick the corporate account under the Corporate Clients filter.
    await user.click(form.getByLabelText('Account Type'));
    await user.click(await screen.findByRole('option', { name: 'Corporate Clients' }));
    await user.click(form.getByLabelText(/client account/i));
    await user.click(await screen.findByText('C-200 — Corp Co'));

    // Switch the filter to Retail without re-picking a client account.
    // The Autocomplete's display goes blank either way, because C-200 no
    // longer matches the filtered option list -- that's not proof the
    // underlying client_account_id was actually cleared. Fill the rest
    // of the form and submit to check what's really still held in state.
    await user.click(form.getByLabelText('Account Type'));
    await user.click(await screen.findByRole('option', { name: 'Retail Clients' }));
    expect((form.getByLabelText(/client account/i) as HTMLInputElement).value).toBe('');

    await user.click(form.getByLabelText('Organization'));
    await user.click(await screen.findByText('CO1 — Kampala HQ'));
    await user.type(form.getByLabelText(/invoice no/i), 'RINV-100');
    await user.type(form.getByLabelText(/invoice date/i), '2026-09-01');
    await user.type(form.getByLabelText(/amount \(incl\. vat\)/i), '150000');
    await user.click(form.getByRole('button', { name: 'Save' }));

    // client_account_id must have actually been cleared -- if it silently
    // still held 'acc-corp1', this would insert against the wrong client
    // instead of failing validation.
    expect(
      await screen.findByText(/organization, client account, invoice number, invoice date, and amount are required/i)
    ).toBeInTheDocument();
    expect(result.insertCalls).toHaveLength(0);
  });
});