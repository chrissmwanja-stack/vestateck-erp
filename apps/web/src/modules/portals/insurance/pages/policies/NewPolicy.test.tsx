import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import NewPolicy from './NewPolicy';

// New policy form: the currency field offers the company's currency first, then only
// currencies that have an approved exchange rate. A policy in another currency can be
// saved as a draft (the server accepts it) but the form says it cannot be bound yet.

const mockFrom = vi.fn();
const mockRpc = vi.fn();

vi.mock('../../../../../lib/supabaseClient', () => ({
  supabase: {
    from: (...args: unknown[]) => mockFrom(...args),
    rpc: (...args: unknown[]) => mockRpc(...args),
  },
}));

let fxRates: { currency: string }[] = [];
let fxError = false;

function builder(result: () => { data: unknown; error: { message: string } | null }) {
  const chain: Record<string, unknown> = {};
  for (const m of ['select', 'eq', 'order']) chain[m] = vi.fn(() => chain);
  (chain as { then: unknown }).then = (resolve: (v: unknown) => void) => resolve(result());
  return chain;
}

function setup() {
  mockFrom.mockImplementation((table: string) => {
    switch (table) {
      case 'ins_clients':
        return builder(() => ({ data: [
          { id: 'c1', client_id: 'bd1', bd_clients: { name: 'Acme Ltd' }, kyc_status: 'verified', risk_rating: 'low' },
          { id: 'c2', client_id: 'bd2', bd_clients: { name: 'Pending Ltd' }, kyc_status: 'pending', risk_rating: 'high' },
        ], error: null }));
      case 'ins_insurers':
        return builder(() => ({ data: [{ id: 'i1', name: 'Jubilee', default_commission_rate_pct: 10 }], error: null }));
      case 'ins_product_lines':
        return builder(() => ({ data: [{ id: 'p1', name: 'Motor' }], error: null }));
      case 'tenant_ledger_settings':
        return builder(() => ({ data: [{ functional_currency: 'UGX' }], error: null }));
      case 'fx_rates':
        return builder(() => (fxError ? { data: null, error: { message: 'permission denied' } } : { data: fxRates, error: null }));
      default:
        throw new Error(`unexpected table ${table}`);
    }
  });
  render(<MemoryRouter><NewPolicy /></MemoryRouter>);
}

async function pick(label: string, option: RegExp | string) {
  await userEvent.click(screen.getByLabelText(new RegExp('^' + label)));
  await userEvent.click(await screen.findByRole('option', { name: option }));
}

beforeEach(() => {
  fxRates = [];
  fxError = false;
  mockFrom.mockReset();
  mockRpc.mockReset();
  mockRpc.mockResolvedValue({ data: { id: 'new-policy' }, error: null });
});

describe('NewPolicy currency', () => {
  it('offers only the company currency when no rate is approved, and says how to add more', async () => {
    setup();
    await screen.findByLabelText('Currency');
    expect(screen.getByText(/other currencies appear here once an exchange rate is approved/i)).toBeInTheDocument();
    await userEvent.click(screen.getByLabelText('Currency'));
    expect(await screen.findAllByRole('option')).toHaveLength(1);
    expect(screen.getByRole('option', { name: /UGX \(company currency\)/ })).toBeInTheDocument();
  });

  it('adds each currency with an approved rate once, after the company currency', async () => {
    fxRates = [{ currency: 'USD' }, { currency: 'USD' }, { currency: 'EUR' }, { currency: 'UGX' }];
    setup();
    await screen.findByLabelText('Currency');
    await userEvent.click(screen.getByLabelText('Currency'));
    const names = (await screen.findAllByRole('option')).map((o) => o.textContent);
    expect(names).toEqual(['UGX (company currency)', 'EUR', 'USD']);
  });

  it('still works in the company currency if exchange rates cannot be read', async () => {
    fxError = true;
    setup();
    await screen.findByLabelText('Currency');
    await userEvent.click(screen.getByLabelText('Currency'));
    expect(await screen.findAllByRole('option')).toHaveLength(1);
  });

  it('warns that a foreign-currency draft cannot be bound yet, and saves it in that currency', async () => {
    fxRates = [{ currency: 'USD' }];
    setup();
    await screen.findByLabelText('Currency');
    expect(screen.queryByText(/is not the company currency/i)).not.toBeInTheDocument();

    await pick('Currency', 'USD');
    expect(screen.getByText(/USD is not the company currency \(UGX\)/)).toBeInTheDocument();

    await pick('Client', 'Acme Ltd');
    await pick('Insurer', 'Jubilee');
    await pick('Product line', 'Motor');
    await userEvent.click(screen.getByRole('button', { name: /save draft/i }));

    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('ins_create_policy', expect.objectContaining({ p_currency: 'USD' })));
  });

  it('saves in the company currency by default', async () => {
    setup();
    await screen.findByLabelText('Currency');
    await pick('Client', 'Acme Ltd');
    await pick('Insurer', 'Jubilee');
    await pick('Product line', 'Motor');
    await userEvent.click(screen.getByRole('button', { name: /save draft/i }));
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('ins_create_policy', expect.objectContaining({ p_currency: 'UGX' })));
  });
});

describe('NewPolicy KYC warning', () => {
  it('warns when the chosen client is pending and high risk, and stays silent for a verified low-risk client', async () => {
    setup();
    await screen.findByLabelText('Currency');
    expect(screen.queryByText(/: KYC is /)).not.toBeInTheDocument();

    await pick('Client', 'Pending Ltd');
    expect(screen.getByText(/Pending Ltd: KYC is pending/)).toBeInTheDocument();
    expect(screen.getByText(/the risk rating is high/)).toBeInTheDocument();

    // A warning, not a block: the save still goes through.
    await pick('Insurer', 'Jubilee');
    await pick('Product line', 'Motor');
    await userEvent.click(screen.getByRole('button', { name: /save draft/i }));
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('ins_create_policy', expect.anything()));

    await pick('Client', 'Acme Ltd');
    expect(screen.queryByText(/: KYC is /)).not.toBeInTheDocument();
  });

  it('mentions an expired KYC without the risk clause when only KYC is a problem', async () => {
    mockFrom.mockImplementation((table: string) => {
      if (table === 'ins_clients') {
        return builder(() => ({ data: [
          { id: 'c3', client_id: 'bd3', bd_clients: { name: 'Lapsed Ltd' }, kyc_status: 'expired', risk_rating: 'medium' },
        ], error: null }));
      }
      return builder(() => ({ data: table === 'tenant_ledger_settings' ? [{ functional_currency: 'UGX' }] : [], error: null }));
    });
    render(<MemoryRouter><NewPolicy /></MemoryRouter>);
    await screen.findByLabelText('Currency');
    await pick('Client', 'Lapsed Ltd');
    expect(screen.getByText(/Lapsed Ltd: KYC is expired/)).toBeInTheDocument();
    expect(screen.queryByText(/risk rating is high/)).not.toBeInTheDocument();
  });
});
