import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import ClientDetail from './ClientDetail';

let canManage = false;
vi.mock('../../access', () => ({ useInsuranceAccess: () => ({ canManage, loading: false }) }));

const updates: unknown[] = [];
const updatedTables: string[] = [];
let kyc = 'pending';
let policies: unknown[] = [];
vi.mock('../../../../../lib/supabaseClient', () => ({
  supabase: {
    from: (name: string) => {
      const chain: Record<string, unknown> = {};
      for (const m of ['select', 'eq', 'order']) chain[m] = vi.fn(() => chain);
      chain.update = vi.fn((patch: unknown) => { updates.push(patch); updatedTables.push(name); return chain; });
      (chain as { then: unknown }).then = (resolve: (v: unknown) => void) =>
        resolve({
          data: name === 'ins_clients'
            ? [{ id: 'c1', client_id: 'b1', client_type: 'corporate', tax_id: '1000012345', risk_rating: 'medium', kyc_status: kyc, bd_clients: { name: 'Acme Ltd', email: 'info@acme.test', phone: null } }]
            : policies,
          error: null,
        });
      return chain;
    },
    rpc: vi.fn(),
  },
}));

function mount() {
  render(
    <MemoryRouter initialEntries={['/insurance/clients/c1']}>
      <Routes><Route path="/insurance/clients/:id" element={<ClientDetail />} /></Routes>
    </MemoryRouter>,
  );
}

beforeEach(() => {
  canManage = false; kyc = 'pending'; updates.length = 0; updatedTables.length = 0;
  policies = [{ id: 'p1', policy_no: 'POL-1', status: 'active', inception_date: '2026-10-01', expiry_date: '2027-10-01', gross_premium: 1000, currency: 'UGX', ins_insurers: { name: 'Jubilee' }, ins_product_lines: { name: 'Motor' } }];
});

describe('client detail', () => {
  it('shows the profile and the client\'s policies', async () => {
    mount();
    await screen.findByText('Acme Ltd');
    expect(screen.getByText('1000012345')).toBeInTheDocument();
    expect(screen.getByText('POL-1')).toBeInTheDocument();
    expect(screen.getByText('Jubilee')).toBeInTheDocument();
  });

  it('does not offer KYC decisions to a member', async () => {
    mount();
    await screen.findByText('Acme Ltd');
    expect(screen.queryByRole('button', { name: 'Mark verified' })).not.toBeInTheDocument();
    expect(screen.getByText(/Only insurance managers can change KYC/)).toBeInTheDocument();
  });

  it('lets a manager verify KYC only after confirming', async () => {
    canManage = true; mount();
    await userEvent.click(await screen.findByRole('button', { name: 'Mark verified' }));
    expect(updates).toEqual([]);
    await userEvent.click(screen.getByRole('button', { name: 'Confirm' }));
    await waitFor(() => expect(updates).toEqual([{ kyc_status: 'verified' }]));
  });

  it('offers expire and reset, not verify, once a client is verified', async () => {
    canManage = true; kyc = 'verified'; mount();
    await screen.findByRole('button', { name: 'Mark expired' });
    expect(screen.getByRole('button', { name: 'Reset to pending' })).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Mark verified' })).not.toBeInTheDocument();
  });

  it('saves profile edits without touching KYC', async () => {
    mount();
    await userEvent.click(await screen.findByRole('button', { name: 'Edit profile' }));
    const tin = screen.getByLabelText('Tax ID (TIN)');
    await userEvent.clear(tin);
    await userEvent.type(tin, '1000099999');
    await userEvent.click(screen.getByRole('button', { name: 'Save' }));
    await waitFor(() => expect(updates).toEqual([{ tax_id: '1000099999', risk_rating: 'medium', client_type: 'corporate' }]));
  });

  it('lets a manager change the name, email and phone on the client master', async () => {
    canManage = true; mount();
    await userEvent.click(await screen.findByRole('button', { name: 'Edit profile' }));
    const name = screen.getByLabelText(/^Name/);
    await userEvent.clear(name);
    await userEvent.type(name, 'Acme Limited');
    await userEvent.type(screen.getByLabelText('Phone'), '0700123456');
    await userEvent.click(screen.getByRole('button', { name: 'Save' }));
    await waitFor(() => expect(updatedTables).toEqual(['ins_clients', 'bd_clients']));
    expect(updates[1]).toEqual({ name: 'Acme Limited', phone: '0700123456' });
  });

  it('lets a member change email and phone but not the name', async () => {
    mount();
    await userEvent.click(await screen.findByRole('button', { name: 'Edit profile' }));
    expect(screen.getByLabelText(/^Name/)).toBeDisabled();
    const email = screen.getByLabelText('Email');
    await userEvent.clear(email);
    await userEvent.type(email, 'claims@acme.test');
    await userEvent.click(screen.getByRole('button', { name: 'Save' }));
    await waitFor(() => expect(updatedTables).toEqual(['ins_clients', 'bd_clients']));
    expect(updates[1]).toEqual({ email: 'claims@acme.test' });
  });

  it('blocks saving while the email is invalid', async () => {
    mount();
    await userEvent.click(await screen.findByRole('button', { name: 'Edit profile' }));
    const email = screen.getByLabelText('Email');
    await userEvent.clear(email);
    await userEvent.type(email, 'not-an-email');
    expect(screen.getByText(/valid email address/i)).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Save' })).toBeDisabled();
  });
});
