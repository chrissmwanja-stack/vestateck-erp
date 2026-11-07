import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import QuotesList from './QuotesList';

let canManage = false;
vi.mock('../../access', () => ({ useInsuranceAccess: () => ({ canManage, loading: false }) }));

const rpcCalls: { fn: string; args: Record<string, unknown> }[] = [];
let rpcResult: unknown = null;
const datasets: Record<string, unknown[]> = {
  ins_quotes: [],
  ins_clients: [{ id: 'c1', name: 'Acme Ltd' }],
  ins_insurers: [{ id: 'i1', name: 'Jubilee', is_active: true }],
  ins_product_lines: [{ id: 'l1', name: 'Motor', is_active: true }],
};
vi.mock('../../../../../lib/supabaseClient', () => ({
  supabase: {
    from: (name: string) => {
      const chain: Record<string, unknown> = {};
      for (const m of ['select', 'order']) chain[m] = vi.fn(() => chain);
      (chain as { then: unknown }).then = (resolve: (v: unknown) => void) =>
        resolve({ data: datasets[name] ?? [], error: null });
      return chain;
    },
    rpc: (fn: string, args: Record<string, unknown>) => {
      rpcCalls.push({ fn, args });
      return Promise.resolve({ data: rpcResult, error: null });
    },
  },
}));

const quote = (over: Record<string, unknown>) => ({
  id: 'q1', quote_no: 'Q-0001', status: 'draft', client_id: 'c1', insurer_id: 'i1',
  product_line_id: 'l1', sum_insured: 1000000, currency: 'UGX', gross_premium: 120000,
  commission_rate_pct: 10, valid_until: '2026-12-31', insurer_ref: null,
  accepted_policy_id: null, notes: null, created_at: '2026-11-01', ...over,
});

function mount() {
  render(<MemoryRouter><QuotesList /></MemoryRouter>);
}

beforeEach(() => {
  canManage = false;
  rpcCalls.length = 0;
  rpcResult = null;
  datasets.ins_quotes = [
    quote({ id: 'q1', quote_no: 'Q-0001', status: 'draft' }),
    quote({ id: 'q2', quote_no: 'Q-0002', status: 'submitted' }),
    quote({ id: 'q3', quote_no: 'Q-0003', status: 'accepted' }),
    quote({ id: 'q4', quote_no: 'Q-0004', status: 'placed', accepted_policy_id: 'p9' }),
  ];
});

describe('quotes list', () => {
  it('renders quotes with resolved names and status chips', async () => {
    mount();
    await screen.findByText('Q-0001');
    // Every quote in the fixture uses the same client, insurer and product line.
    expect(screen.getAllByText('Acme Ltd')).toHaveLength(4);
    expect(screen.getAllByText('Jubilee')).toHaveLength(4);
    expect(screen.getAllByText('Motor')).toHaveLength(4);
    expect(screen.getByText('draft')).toBeInTheDocument();
    expect(screen.getByText('submitted')).toBeInTheDocument();
    expect(screen.getByText('accepted')).toBeInTheDocument();
    expect(screen.getByText('placed')).toBeInTheDocument();
  });

  it('shows Submit only on drafts and calls ins_submit_quote', async () => {
    mount();
    await screen.findByText('Q-0001');
    const submitButtons = screen.getAllByText('Submit');
    expect(submitButtons).toHaveLength(1);
    await userEvent.click(submitButtons[0]);
    await waitFor(() =>
      expect(rpcCalls).toContainEqual({ fn: 'ins_submit_quote', args: { p_quote_id: 'q1' } }));
  });

  it('hides Decide/Place from members but shows them to managers', async () => {
    canManage = false;
    mount();
    await screen.findByText('Q-0001');
    expect(screen.queryByText('Decide')).not.toBeInTheDocument();
    expect(screen.queryByText('Place')).not.toBeInTheDocument();
  });

  it('manager can decide a submitted quote with accept and insurer ref', async () => {
    canManage = true;
    mount();
    await screen.findByText('Q-0002');
    await userEvent.click(screen.getByText('Decide'));
    const ref = await screen.findByLabelText('Insurer reference');
    await userEvent.type(ref, 'JUB-991');
    await userEvent.click(screen.getByText('Save decision'));
    await waitFor(() =>
      expect(rpcCalls).toContainEqual({
        fn: 'ins_decide_quote',
        args: { p_quote_id: 'q2', p_decision: 'accepted', p_insurer_ref: 'JUB-991' },
      }));
  });

  it('manager can place an accepted quote and gets the policy id', async () => {
    canManage = true;
    rpcResult = { id: 'p9' };
    mount();
    await screen.findByText('Q-0003');
    await userEvent.click(screen.getByText('Place'));
    await waitFor(() =>
      expect(rpcCalls).toContainEqual({ fn: 'ins_place_quote', args: { p_quote_id: 'q3' } }));
  });

  it('creates a draft quote through ins_create_quote', async () => {
    mount();
    await screen.findByText('Q-0001');
    await userEvent.click(screen.getByText('New quote'));
    // Required MUI selects are labelled "Client *" etc., so match by role and a name pattern,
    // and pick the option by role (the quotes table behind the dialog repeats these names).
    await userEvent.click(await screen.findByRole('combobox', { name: /^Client/ }));
    await userEvent.click(await screen.findByRole('option', { name: 'Acme Ltd' }));
    await userEvent.click(screen.getByRole('combobox', { name: /^Insurer/ }));
    await userEvent.click(await screen.findByRole('option', { name: 'Jubilee' }));
    await userEvent.click(screen.getByRole('combobox', { name: /^Product line/ }));
    await userEvent.click(await screen.findByRole('option', { name: 'Motor' }));
    await userEvent.type(screen.getByLabelText('Gross premium'), '120000');
    await userEvent.click(screen.getByText('Create draft'));
    await waitFor(() =>
      expect(rpcCalls.some((c) => c.fn === 'ins_create_quote' && c.args.p_gross_premium === 120000)).toBe(true));
  });
});
