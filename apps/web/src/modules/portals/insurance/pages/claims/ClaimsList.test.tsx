import { render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import ClaimsList from './ClaimsList';

const mockFrom = vi.fn();
vi.mock('../../../../../lib/supabaseClient', () => ({ supabase: { from: (...a: unknown[]) => mockFrom(...a), rpc: vi.fn() } }));

const claim = (over: Record<string, unknown>) => ({
  id: 'c', claim_no: 'CLM-00001', status: 'notified', loss_date: '2026-05-10', notified_date: '2026-05-11', loss_description: 'Rear-end collision on Jinja Road',
  insurer_claim_ref: null, reserve_amount: 5000, approved_amount: null, paid_amount: 0, policy_id: 'p', created_at: '2026-05-11',
  ins_policies: { policy_no: 'POL-00001', sum_insured: 1000, currency: 'UGX', insurer_id: 'i1', ins_insurers: { name: 'Jubilee' }, ins_clients: { bd_clients: { name: 'Acme Ltd' } } }, ...over,
});
let data: unknown[] = [];
function builder() {
  const chain: Record<string, unknown> = {};
  for (const m of ['select', 'eq', 'order']) chain[m] = vi.fn(() => chain);
  (chain as { then: unknown }).then = (resolve: (v: unknown) => void) => resolve({ data, error: null });
  return chain;
}
const claimNos = () => screen.queryAllByRole('row').slice(1).map((r) => within(r).queryAllByRole('cell')[0]?.textContent).filter(Boolean);

beforeEach(() => {
  mockFrom.mockReset();
  mockFrom.mockImplementation(() => builder());
  data = [
    claim({ id: '1' }),
    claim({ id: '2', claim_no: 'CLM-00002', status: 'assessing', loss_date: '2026-08-01', loss_description: 'Warehouse fire', insurer_claim_ref: 'BRT/778',
      ins_policies: { policy_no: 'POL-00009', sum_insured: 1, currency: 'UGX', insurer_id: 'i2', ins_insurers: { name: 'Britam' }, ins_clients: { bd_clients: { name: 'Zed Co' } } } }),
    claim({ id: '3', claim_no: 'CLM-00003', status: 'closed' }),
  ];
});

describe('ClaimsList search and filters', () => {
  it('starts on open claims, so the closed one is not listed', async () => {
    render(<MemoryRouter><ClaimsList /></MemoryRouter>);
    await screen.findByText('CLM-00001');
    expect(claimNos()).toEqual(['CLM-00001', 'CLM-00002']);
    expect(screen.getByRole('status')).toHaveTextContent('2 claims');
  });

  it('finds a claim by the insurer reference, the client or the description', async () => {
    render(<MemoryRouter><ClaimsList /></MemoryRouter>);
    await screen.findByText('CLM-00001');
    await userEvent.type(screen.getByLabelText('Search'), 'brt/778');
    expect(claimNos()).toEqual(['CLM-00002']);
    await userEvent.clear(screen.getByLabelText('Search'));
    await userEvent.type(screen.getByLabelText('Search'), 'jinja');
    expect(claimNos()).toEqual(['CLM-00001']);
  });

  it('filters by insurer and by loss date', async () => {
    render(<MemoryRouter><ClaimsList /></MemoryRouter>);
    await screen.findByText('CLM-00001');
    await userEvent.click(screen.getByLabelText('Insurer'));
    await userEvent.click(await screen.findByRole('option', { name: 'Britam' }));
    expect(claimNos()).toEqual(['CLM-00002']);
    await userEvent.click(screen.getByRole('button', { name: 'Clear filters' }));
    await userEvent.type(screen.getByLabelText('Loss to'), '2026-06-01');
    expect(claimNos()).toEqual(['CLM-00001']);
  });

  it('offers a way back to the default view after showing everything', async () => {
    render(<MemoryRouter><ClaimsList /></MemoryRouter>);
    await screen.findByText('CLM-00001');
    await userEvent.click(screen.getByLabelText('Show'));
    await userEvent.click(await screen.findByRole('option', { name: 'All' }));
    expect(claimNos()).toEqual(['CLM-00001', 'CLM-00002', 'CLM-00003']);
    await userEvent.click(screen.getByRole('button', { name: 'Clear filters' }));
    expect(claimNos()).toEqual(['CLM-00001', 'CLM-00002']);
  });
});
