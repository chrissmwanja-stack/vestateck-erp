import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import ExchangeRates from './ExchangeRates';
import type { FxRate } from '../../fx';

// Exchange-rate screen: approval is offered to finance users for someone else's draft,
// never for their own; members can look rates up but not enter them; a draft is saved
// with the company's tenant id and only after the client-side checks pass. Every write
// goes through the table insert or an RPC, and the server still decides.

const mockFrom = vi.fn();
const mockRpc = vi.fn();
const mockGetUser = vi.fn();
let mockAccess: unknown = null;

vi.mock('../../../../../lib/supabaseClient', () => ({
  supabase: {
    from: (...args: unknown[]) => mockFrom(...args),
    rpc: (...args: unknown[]) => mockRpc(...args),
    auth: { getUser: () => mockGetUser() },
  },
}));
vi.mock('../../../../../features/navigation/useMyModuleAccess', () => ({
  useMyModuleAccess: () => mockAccess,
}));

const ME = 'user-me';
const OTHER = 'user-other';

let rates: FxRate[] = [];
let inserts: unknown[] = [];

const draft = (over: Partial<FxRate>): FxRate => ({
  id: 'r1', tenant_id: 't1', currency: 'USD', rate_date: '2026-10-15', rate: 3700.5, source: 'Bulletin',
  status: 'draft', entered_by: OTHER, approved_by: null, approved_at: null, withdrawn_reason: null,
  created_at: '2026-10-15T08:00:00Z', ...over,
});

// Minimal query builder: every filter returns the same chain; awaiting it yields the rows.
function builder(result: () => { data: unknown; error: null }) {
  const chain: Record<string, unknown> = {};
  for (const m of ['select', 'eq', 'order', 'limit']) chain[m] = vi.fn(() => chain);
  chain.maybeSingle = vi.fn(async () => result());
  chain.insert = vi.fn(async (value: unknown) => {
    inserts.push(value);
    return { data: null, error: null };
  });
  (chain as { then: unknown }).then = (resolve: (v: unknown) => void) => resolve(result());
  return chain;
}

function setup(access: unknown) {
  mockAccess = access;
  mockGetUser.mockResolvedValue({ data: { user: { id: ME } } });
  mockFrom.mockImplementation((table: string) => {
    if (table === 'tenant_ledger_settings') return builder(() => ({ data: [{ functional_currency: 'UGX' }], error: null }));
    if (table === 'fx_rates') return builder(() => ({ data: rates, error: null }));
    if (table === 'app_users') return builder(() => ({ data: { tenant_id: 't1' }, error: null }));
    throw new Error(`unexpected table ${table}`);
  });
}

beforeEach(() => {
  rates = [];
  inserts = [];
  mockRpc.mockReset();
  mockFrom.mockReset();
  mockGetUser.mockReset();
});

describe('ExchangeRates', () => {
  it('offers approval on someone else’s draft but not on the user’s own', async () => {
    rates = [draft({ id: 'theirs', entered_by: OTHER }), draft({ id: 'mine', currency: 'EUR', entered_by: ME })];
    setup({ isPlatformAdmin: false, isCompanyAdmin: false, canAccessFinance: true });
    render(<ExchangeRates />);

    await screen.findByText('USD');
    const rows = screen.getAllByRole('row');
    const theirs = rows.find((r) => within(r).queryByText('USD'))!;
    const mine = rows.find((r) => within(r).queryByText('EUR'))!;
    expect(within(theirs).queryByRole('button', { name: 'Approve' })).not.toBeNull();
    expect(within(mine).queryByRole('button', { name: 'Approve' })).toBeNull();
    expect(within(mine).queryByRole('button', { name: 'Withdraw' })).not.toBeNull();
    expect(within(theirs).queryByRole('button', { name: 'Withdraw' })).toBeNull();
  });

  it('approves through the RPC', async () => {
    rates = [draft({ id: 'theirs', entered_by: OTHER })];
    mockRpc.mockResolvedValue({});
    setup({ isPlatformAdmin: false, isCompanyAdmin: false, canAccessFinance: true });
    render(<ExchangeRates />);

    await userEvent.click(await screen.findByRole('button', { name: 'Approve' }));
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('fx_rate_approve', { p_id: 'theirs' }));
  });

  it('shows members a read-only view with no entry form', async () => {
    setup({ isPlatformAdmin: false, isCompanyAdmin: false, canAccessFinance: false });
    render(<ExchangeRates />);

    expect(await screen.findByText(/Only company admins and finance users can enter or approve rates/)).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Save draft' })).toBeNull();
  });

  it('refuses the company’s own currency without writing anything', async () => {
    setup({ isPlatformAdmin: false, isCompanyAdmin: true, canAccessFinance: false });
    render(<ExchangeRates />);

    await userEvent.type(await screen.findByLabelText('Currency'), 'UGX');
    await userEvent.type(screen.getByLabelText(/Rate \(UGX per 1 unit\)/), '1');
    await userEvent.type(screen.getByLabelText('Source'), 'Own currency');
    await userEvent.click(screen.getByRole('button', { name: 'Save draft' }));

    expect(await screen.findByText(/always 1, so there is nothing to enter/)).toBeTruthy();
    expect(inserts).toHaveLength(0);
  });

  it('saves a valid draft with the company id and asks for approval by someone else', async () => {
    setup({ isPlatformAdmin: false, isCompanyAdmin: true, canAccessFinance: false });
    render(<ExchangeRates />);

    await userEvent.type(await screen.findByLabelText('Currency'), 'usd');
    await userEvent.type(screen.getByLabelText(/Rate \(UGX per 1 unit\)/), '3700.5');
    await userEvent.type(screen.getByLabelText('Source'), 'Central bank bulletin');
    await userEvent.click(screen.getByRole('button', { name: 'Save draft' }));

    await waitFor(() => expect(inserts).toHaveLength(1));
    expect(inserts[0]).toMatchObject({ tenant_id: 't1', currency: 'USD', rate: 3700.5, source: 'Central bank bulletin' });
    expect(await screen.findByText(/A different person must approve it before it is used/)).toBeTruthy();
  });
});
