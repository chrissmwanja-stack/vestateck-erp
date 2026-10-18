import { render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import ClientsList from './ClientsList';

const mockFrom = vi.fn();
vi.mock('../../../../../lib/supabaseClient', () => ({ supabase: { from: (...a: unknown[]) => mockFrom(...a), rpc: vi.fn() } }));

const client = (over: Record<string, unknown>) => ({
  id: 'c', client_id: 'b', client_type: 'corporate', tax_id: '1000012345', risk_rating: 'medium', kyc_status: 'pending',
  bd_clients: { name: 'Acme Ltd', email: 'info@acme.test', phone: '+256700000001' }, ...over,
});
let data: unknown[] = [];
function builder() {
  const chain: Record<string, unknown> = {};
  for (const m of ['select', 'order']) chain[m] = vi.fn(() => chain);
  (chain as { then: unknown }).then = (resolve: (v: unknown) => void) => resolve({ data, error: null });
  return chain;
}
const names = () => screen.queryAllByRole('row').slice(1).map((r) => within(r).queryAllByRole('cell')[0]?.textContent).filter(Boolean);

beforeEach(() => {
  mockFrom.mockReset();
  mockFrom.mockImplementation(() => builder());
  data = [
    client({ id: '1' }),
    client({ id: '2', client_type: 'individual', tax_id: null, risk_rating: 'high', kyc_status: 'verified', bd_clients: { name: 'Jane Doe', email: null, phone: '0772123456' } }),
    client({ id: '3', kyc_status: 'expired', bd_clients: { name: 'Old Co', email: null, phone: null } }),
  ];
});

describe('ClientsList search and filters', () => {
  it('finds a client by name, tax ID or phone', async () => {
    render(<ClientsList />);
    await screen.findByText('Acme Ltd');
    await userEvent.type(screen.getByLabelText('Search'), 'jane');
    expect(names()).toEqual(['Jane Doe']);
    await userEvent.clear(screen.getByLabelText('Search'));
    await userEvent.type(screen.getByLabelText('Search'), '1000012345');
    expect(names()).toEqual(['Acme Ltd', 'Old Co']);
    await userEvent.clear(screen.getByLabelText('Search'));
    await userEvent.type(screen.getByLabelText('Search'), '772123');
    expect(names()).toEqual(['Jane Doe']);
  });

  it('filters by KYC status, so expired and pending clients can be chased', async () => {
    render(<ClientsList />);
    await screen.findByText('Acme Ltd');
    await userEvent.click(screen.getByLabelText('KYC'));
    await userEvent.click(await screen.findByRole('option', { name: 'Expired' }));
    expect(names()).toEqual(['Old Co']);
    expect(screen.getByRole('status')).toHaveTextContent('Showing 1 of 3 clients');
  });

  it('combines risk and type, and clear filters restores the list', async () => {
    render(<ClientsList />);
    await screen.findByText('Acme Ltd');
    await userEvent.click(screen.getByLabelText('Risk'));
    await userEvent.click(await screen.findByRole('option', { name: 'High' }));
    await userEvent.click(screen.getByLabelText('Type'));
    await userEvent.click(await screen.findByRole('option', { name: 'Corporate' }));
    expect(await screen.findByText('No clients match these filters.')).toBeInTheDocument();
    await userEvent.click(screen.getByRole('button', { name: 'Clear filters' }));
    expect(names()).toHaveLength(3);
  });
});
