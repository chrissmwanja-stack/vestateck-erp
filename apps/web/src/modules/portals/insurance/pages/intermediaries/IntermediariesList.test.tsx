import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import IntermediariesList from './IntermediariesList';

const mockFrom = vi.fn();
const mockRpc = vi.fn();
vi.mock('../../../../../lib/supabaseClient', () => ({
  supabase: {
    from: (...a: unknown[]) => mockFrom(...a),
    rpc: (...a: unknown[]) => mockRpc(...a),
    auth: { getUser: () => Promise.resolve({ data: { user: { id: 'me' } } }) },
  },
}));
vi.mock('../../access', () => ({ useInsuranceAccess: () => ({ canManage: true, loading: false }) }));

const agent = (over: Record<string, unknown> = {}) => ({
  id: 'a1', code: 'AG-1', kind: 'business', name: 'Alpha Agency', category: 'independent_broker',
  contact_email: 'alpha@example.co.ug', contact_phone: '+256700000000', parent_id: null,
  licence_ref: 'LIC-1', licence_authority: 'IRA', licence_valid_from: null, licence_valid_to: '2099-12-31',
  appointment_ref: null, authorisation_basis: null, authorisation_reference: null,
  status: 'active', last_changed_by: 'someone', verified_by: 'checker', verified_at: '2026-10-01', ...over,
});

let data: unknown[] = [];
function builder() {
  const chain: Record<string, unknown> = {};
  for (const m of ['select', 'order']) chain[m] = vi.fn(() => chain);
  (chain as { then: unknown }).then = (resolve: (v: unknown) => void) => resolve({ data, error: null });
  return chain;
}

beforeEach(() => {
  mockFrom.mockReset();
  mockRpc.mockReset();
  mockFrom.mockImplementation(() => builder());
  mockRpc.mockResolvedValue({ data: {}, error: null });
  data = [agent()];
});

describe('IntermediariesList contact details', () => {
  it('shows the stored contact in the list', async () => {
    render(<IntermediariesList />);
    expect(await screen.findByText('alpha@example.co.ug · +256700000000')).toBeInTheDocument();
  });

  it('keeps the stored contact when an edit is saved (it used to be wiped to null)', async () => {
    render(<IntermediariesList />);
    await userEvent.click(await screen.findByRole('button', { name: 'Edit Alpha Agency' }));
    expect(screen.getByLabelText('Contact email')).toHaveValue('alpha@example.co.ug');
    expect(screen.getByLabelText('Contact phone')).toHaveValue('+256700000000');

    await userEvent.clear(screen.getByLabelText('Name'));
    await userEvent.type(screen.getByLabelText('Name'), 'Alpha Agency Ltd');
    await userEvent.click(screen.getByRole('button', { name: 'Save' }));

    expect(mockRpc).toHaveBeenCalledWith('ins_save_intermediary', expect.objectContaining({
      p_id: 'a1',
      p_name: 'Alpha Agency Ltd',
      p_contact_email: 'alpha@example.co.ug',
      p_contact_phone: '+256700000000',
    }));
  });

  it('sends a changed contact, and null when the user clears it', async () => {
    render(<IntermediariesList />);
    await userEvent.click(await screen.findByRole('button', { name: 'Edit Alpha Agency' }));
    await userEvent.clear(screen.getByLabelText('Contact email'));
    await userEvent.clear(screen.getByLabelText('Contact phone'));
    await userEvent.type(screen.getByLabelText('Contact phone'), '0712 345 678');
    await userEvent.click(screen.getByRole('button', { name: 'Save' }));

    expect(mockRpc).toHaveBeenCalledWith('ins_save_intermediary', expect.objectContaining({
      p_contact_email: null,
      p_contact_phone: '0712 345 678',
    }));
  });

  it('blocks saving a malformed email and says why', async () => {
    render(<IntermediariesList />);
    await userEvent.click(await screen.findByRole('button', { name: 'Edit Alpha Agency' }));
    await userEvent.clear(screen.getByLabelText('Contact email'));
    await userEvent.type(screen.getByLabelText('Contact email'), 'nope');
    expect(screen.getByText('Enter a valid contact email address, or leave it blank.')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Save' })).toBeDisabled();
  });

  it('sends the contact when creating a new intermediary', async () => {
    render(<IntermediariesList />);
    await userEvent.click(await screen.findByRole('button', { name: 'New intermediary' }));
    await userEvent.type(screen.getByLabelText('Reference code'), 'ag-2');
    await userEvent.type(screen.getByLabelText('Name'), 'Beta Agency');
    await userEvent.type(screen.getByLabelText('Licence reference'), 'LIC-2');
    await userEvent.type(screen.getByLabelText('Issuing authority'), 'IRA');
    await userEvent.type(screen.getByLabelText('Valid to'), '2099-12-31');
    await userEvent.type(screen.getByLabelText('Contact email'), 'beta@example.co.ug');
    await userEvent.click(screen.getByRole('button', { name: 'Save' }));

    expect(mockRpc).toHaveBeenCalledWith('ins_save_intermediary', expect.objectContaining({
      p_id: null, p_code: 'AG-2', p_contact_email: 'beta@example.co.ug', p_contact_phone: null,
    }));
  });
});