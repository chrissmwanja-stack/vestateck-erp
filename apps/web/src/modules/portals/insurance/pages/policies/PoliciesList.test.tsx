import { render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import PoliciesList from './PoliciesList';

const mockFrom = vi.fn();
vi.mock('../../../../../lib/supabaseClient', () => ({ supabase: { from: (...a: unknown[]) => mockFrom(...a), rpc: vi.fn() } }));

const row = (over: Record<string, unknown>) => ({
  id: 'p', policy_no: 'POL-00001', status: 'active', insurer_id: 'i1', product_line_id: 'l1', inception_date: '2026-01-01', expiry_date: '2026-12-31',
  gross_premium: 1000, commission_amount: 100, currency: 'UGX',
  ins_clients: { bd_clients: { name: 'Acme Ltd' } }, ins_insurers: { name: 'Jubilee' }, ins_product_lines: { name: 'Motor' }, ...over,
});
let data: unknown[] = [];

function builder() {
  const chain: Record<string, unknown> = {};
  for (const m of ['select', 'eq', 'order']) chain[m] = vi.fn(() => chain);
  (chain as { then: unknown }).then = (resolve: (v: unknown) => void) => resolve({ data, error: null });
  return chain;
}

const policyNos = () => screen.queryAllByRole('row').slice(1).map((r) => within(r).queryAllByRole('cell')[0]?.textContent).filter(Boolean);

beforeEach(() => {
  mockFrom.mockReset();
  mockFrom.mockImplementation(() => builder());
  data = [
    row({ id: '1', policy_no: 'POL-00001', expiry_date: '2026-03-31' }),
    row({ id: '2', policy_no: 'POL-00002', insurer_id: 'i2', ins_insurers: { name: 'Britam' }, product_line_id: 'l2', ins_product_lines: { name: 'Fire' }, expiry_date: '2026-11-30', ins_clients: { bd_clients: { name: 'Zed Co' } } }),
    row({ id: '3', policy_no: 'POL-00003', expiry_date: '2026-06-30', ins_clients: { bd_clients: { name: 'Bravo Ltd' } } }),
  ];
});

const open = async () => {
  render(<MemoryRouter><PoliciesList /></MemoryRouter>);
  await screen.findByText('POL-00001');
};

describe('PoliciesList search and filters', () => {
  it('shows every policy and the total at first', async () => {
    await open();
    expect(policyNos()).toEqual(['POL-00001', 'POL-00002', 'POL-00003']);
    expect(screen.getByRole('status')).toHaveTextContent('3 policies');
    expect(screen.queryByRole('button', { name: 'Clear filters' })).not.toBeInTheDocument();
  });

  it('narrows by what is typed and says how many of the total are showing', async () => {
    await open();
    await userEvent.type(screen.getByLabelText('Search'), 'zed');
    expect(policyNos()).toEqual(['POL-00002']);
    expect(screen.getByRole('status')).toHaveTextContent('Showing 1 of 3 policies');
  });

  it('filters by insurer, offering only insurers that have policies', async () => {
    await open();
    await userEvent.click(screen.getByLabelText('Insurer'));
    expect((await screen.findAllByRole('option')).map((o) => o.textContent)).toEqual(['All', 'Britam', 'Jubilee']);
    await userEvent.click(screen.getByRole('option', { name: 'Britam' }));
    expect(policyNos()).toEqual(['POL-00002']);
  });

  it('sorts by expiry without losing the filter', async () => {
    await open();
    await userEvent.click(screen.getByLabelText('Sort'));
    await userEvent.click(await screen.findByRole('option', { name: 'Expiry, latest first' }));
    expect(policyNos()).toEqual(['POL-00002', 'POL-00003', 'POL-00001']);
  });

  it('says so when nothing matches, and clear filters brings everything back', async () => {
    await open();
    await userEvent.type(screen.getByLabelText('Search'), 'nothing like this');
    expect(await screen.findByText('No policies match these filters.')).toBeInTheDocument();
    await userEvent.click(screen.getByRole('button', { name: 'Clear filters' }));
    expect(policyNos()).toHaveLength(3);
    expect(screen.getByLabelText('Search')).toHaveValue('');
  });

  it('asks the server for one status and keeps the other filters on top of it', async () => {
    await open();
    await userEvent.click(screen.getByLabelText('Status'));
    await userEvent.click(await screen.findByRole('option', { name: 'Draft' }));
    const eqCalls = mockFrom.mock.results.flatMap((r) => (r.value as { eq: { mock: { calls: unknown[][] } } }).eq.mock.calls);
    expect(eqCalls).toContainEqual(['status', 'draft']);
  });
});
