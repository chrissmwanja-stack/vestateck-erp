import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import NewPolicy from './NewPolicy';

// Editing a draft reuses the New policy form. Only drafts are editable, and a draft with saved
// insurer shares keeps its insurer and commission rate in the Financial configuration panel.

vi.mock('../../../../../lib/supabaseClient', () => ({
  supabase: { from: (name: string) => mockFrom(name), rpc: vi.fn() },
}));
const mockFrom = vi.fn();

const updates: unknown[] = [];
let status = 'draft';
let shares: { id: string }[] = [];
let updateResult: { data: unknown; error: null | { message: string } } = { data: [{ id: 'pol1' }], error: null };

const policy = () => ({
  id: 'pol1', policy_no: 'POL-7', status, client_id: 'c1', insurer_id: 'i1', product_line_id: 'p1',
  inception_date: '2026-10-01', expiry_date: '2027-09-30', sum_insured: 5000000, currency: 'UGX', gross_premium: 250000,
  commission_rate_pct: 12.5, risk_description: 'Fleet of 3', notes: null,
});

function builder(name: string) {
  const data: Record<string, unknown> = {
    ins_clients: [{ id: 'c1', client_id: 'b1', bd_clients: { name: 'Acme Ltd' } }],
    ins_insurers: [{ id: 'i1', name: 'Jubilee', default_commission_rate_pct: 10 }],
    ins_product_lines: [{ id: 'p1', name: 'Motor' }],
    tenant_ledger_settings: [{ functional_currency: 'UGX' }],
    fx_rates: [],
    ins_policies: [policy()],
    ins_policy_insurer_shares: shares,
  };
  let isUpdate = false;
  const chain: Record<string, unknown> = {};
  for (const m of ['select', 'eq', 'order']) chain[m] = vi.fn(() => chain);
  chain.update = vi.fn((patch: unknown) => { isUpdate = true; updates.push(patch); return chain; });
  (chain as { then: unknown }).then = (resolve: (v: unknown) => void) => resolve(isUpdate ? updateResult : { data: data[name], error: null });
  return chain;
}

function mount() {
  render(
    <MemoryRouter initialEntries={['/insurance/policies/pol1/edit']}>
      <Routes>
        <Route path="/insurance/policies/:id/edit" element={<NewPolicy />} />
        <Route path="/insurance/policies/:id" element={<div>Policy page</div>} />
      </Routes>
    </MemoryRouter>,
  );
}

beforeEach(() => {
  mockFrom.mockReset();
  mockFrom.mockImplementation((name: string) => builder(name));
  updates.length = 0; status = 'draft'; shares = [];
  updateResult = { data: [{ id: 'pol1' }], error: null };
});

describe('editing a draft policy', () => {
  it('loads the draft into the form', async () => {
    mount();
    await screen.findByText('Edit draft POL-7');
    expect(screen.getByLabelText(/^Gross premium/)).toHaveValue(250000);
    expect(screen.getByLabelText(/^Commission/)).toHaveValue(12.5);
    expect(screen.getByDisplayValue('Fleet of 3')).toBeInTheDocument();
  });

  it('saves changes to the draft and returns to the policy', async () => {
    mount();
    await screen.findByText('Edit draft POL-7');
    const premium = screen.getByLabelText(/^Gross premium/);
    await userEvent.clear(premium);
    await userEvent.type(premium, '300000');
    await userEvent.click(screen.getByRole('button', { name: 'Save changes' }));
    await screen.findByText('Policy page');
    expect(updates).toHaveLength(1);
    expect(updates[0]).toMatchObject({ gross_premium: 300000, insurer_id: 'i1', commission_rate_pct: 12.5, client_id: 'c1' });
  });

  it('leaves the insurer and commission to the saved shares', async () => {
    shares = [{ id: 's1' }];
    mount();
    await screen.findByText(/This draft has saved insurer shares/);
    expect(screen.getByLabelText(/^Commission/)).toBeDisabled();
    await userEvent.click(screen.getByRole('button', { name: 'Save changes' }));
    await screen.findByText('Policy page');
    expect(updates[0]).not.toHaveProperty('insurer_id');
    expect(updates[0]).not.toHaveProperty('commission_rate_pct');
  });

  it('will not save a policy that has been bound', async () => {
    status = 'active';
    mount();
    await screen.findByText(/has been bound/);
    expect(screen.getByRole('button', { name: 'Save changes' })).toBeDisabled();
  });

  it('reports a policy that was bound while the form was open', async () => {
    updateResult = { data: [], error: null };
    mount();
    await screen.findByText('Edit draft POL-7');
    await userEvent.click(screen.getByRole('button', { name: 'Save changes' }));
    await waitFor(() => expect(screen.getByText(/no longer a draft/)).toBeInTheDocument());
  });
});
