import { render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import InsurersList from './InsurersList';

const mockFrom = vi.fn();
vi.mock('../../../../../lib/supabaseClient', () => ({ supabase: { from: (...a: unknown[]) => mockFrom(...a), rpc: vi.fn() } }));
vi.mock('../../access', () => ({ useInsuranceAccess: () => ({ canManage: false, loading: false }) }));

const insurer = (over: Record<string, unknown>) => ({
  id: 'i', code: 'JUB', name: 'Jubilee', contact_name: 'Sam', contact_email: null, contact_phone: null, default_commission_rate_pct: 10, claim_payment_mode: 'insurer_direct', is_active: true, ...over,
});
let data: unknown[] = [];
function builder() {
  const chain: Record<string, unknown> = {};
  for (const m of ['select', 'order']) chain[m] = vi.fn(() => chain);
  (chain as { then: unknown }).then = (resolve: (v: unknown) => void) => resolve({ data, error: null });
  return chain;
}
const names = () => screen.queryAllByRole('row').slice(1).map((r) => within(r).queryAllByRole('cell')[1]?.textContent).filter(Boolean);

beforeEach(() => {
  mockFrom.mockReset();
  mockFrom.mockImplementation(() => builder());
  data = [insurer({ id: '1' }), insurer({ id: '2', code: 'BRT', name: 'Britam', contact_name: null, contact_email: 'claims@britam.test', is_active: false })];
});

describe('InsurersList search and filters', () => {
  it('searches code, name and contact', async () => {
    render(<InsurersList />);
    await screen.findByText('Jubilee');
    await userEvent.type(screen.getByLabelText('Search'), 'britam.test');
    expect(names()).toEqual(['Britam']);
    await userEvent.clear(screen.getByLabelText('Search'));
    await userEvent.type(screen.getByLabelText('Search'), 'sam');
    expect(names()).toEqual(['Jubilee']);
  });

  it('filters active and inactive insurers', async () => {
    render(<InsurersList />);
    await screen.findByText('Jubilee');
    await userEvent.click(screen.getByLabelText('Status'));
    await userEvent.click(await screen.findByRole('option', { name: 'Inactive' }));
    expect(names()).toEqual(['Britam']);
    await userEvent.click(screen.getByRole('button', { name: 'Clear filters' }));
    expect(names()).toEqual(['Jubilee', 'Britam']);
  });
});
