import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import CertificateStock from './CertificateStock';

const mockRpc = vi.fn();
vi.mock('../../db', () => ({
  rpc: (...args: unknown[]) => mockRpc(...args),
  rows: async () => [],
  allRows: async () => [
    { id: 'c1', serial_no: 'MC-0001', status: 'in_stock', issued_to: null, risk_id: null, policy_id: null, issued_at: null, close_reason: null, ins_risks: null },
    { id: 'c2', serial_no: 'MC-0002', status: 'in_stock', issued_to: null, risk_id: null, policy_id: null, issued_at: null, close_reason: null, ins_risks: null },
    { id: 'c3', serial_no: 'MC-0003', status: 'used', issued_to: null, risk_id: 'r1', policy_id: 'p1', issued_at: null, close_reason: null, ins_risks: null },
  ],
  table: () => {
    const chain: Record<string, unknown> = {};
    for (const m of ['select', 'eq', 'order']) chain[m] = () => chain;
    return chain;
  },
  errorText: (e: Error) => e.message,
}));
vi.mock('../../access', () => ({ useInsuranceAccess: () => ({ canManage: true }) }));

beforeEach(() => {
  vi.clearAllMocks();
  mockRpc.mockResolvedValue(5);
});

describe('motor certificate stock', () => {
  it('shows counts by status', async () => {
    render(<CertificateStock />);
    expect(await screen.findByText('In stock: 2')).toBeInTheDocument();
    expect(screen.getByText('Used at bind: 1')).toBeInTheDocument();
    expect(screen.getByText('Spoiled: 0')).toBeInTheDocument();
  });

  it('keeps Load range disabled until the range is valid, then sends it', async () => {
    const user = userEvent.setup();
    render(<CertificateStock />);
    await screen.findByText('In stock: 2');
    const load = screen.getByRole('button', { name: 'Load range' });
    expect(load).toBeDisabled();

    await user.type(screen.getByLabelText('Prefix'), 'MC-');
    await user.type(screen.getByLabelText('First number'), '9');
    await user.type(screen.getByLabelText('Last number'), '5');
    expect(load).toBeDisabled();
    expect(screen.getByText('The last serial must be at or after the first.')).toBeInTheDocument();

    const last = screen.getByLabelText('Last number');
    await user.clear(last);
    await user.type(last, '13');
    expect(load).toBeEnabled();
    await user.click(load);
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('ins_load_certificate_range', {
      p_prefix: 'MC-', p_from: 9, p_to: 13, p_width: 8,
    }));
    expect(await screen.findByText('Loaded 5 certificates, from MC-00000009.')).toBeInTheDocument();
  });
});
