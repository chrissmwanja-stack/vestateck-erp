import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import PolicyReversalAction from './PolicyReversalAction';

const mockRpc = vi.fn();
vi.mock('../../db', () => ({ rpc: (...args: unknown[]) => mockRpc(...args), errorText: (e: Error) => e.message }));
const result = { id: 'r1', original_policy_id: 'p1', replacement_policy_id: null };
beforeEach(() => {
  vi.clearAllMocks();
  mockRpc.mockImplementation((name: string) => Promise.resolve(name === 'ins_policy_reversal_eligibility'
    ? { eligible: true, reason: null } : result));
});

async function open(onReversed = vi.fn()) {
  const user = userEvent.setup();
  render(<PolicyReversalAction policyId="p1" policyNo="POL-1" onReversed={onReversed} />);
  await waitFor(() => expect(screen.getByRole('button', { name: 'Reverse policy' })).toBeEnabled());
  await user.click(screen.getByRole('button', { name: 'Reverse policy' }));
  return { user, onReversed };
}

describe('restricted policy reversal', () => {
  it('defaults reissue off, requires a reason, and sends a request key', async () => {
    const { user, onReversed } = await open();
    expect(screen.getByRole('checkbox')).not.toBeChecked();
    expect(screen.getByRole('button', { name: 'Confirm reversal' })).toBeDisabled();
    await user.type(screen.getByLabelText('Reversal reason'), 'Correct premium');
    await user.click(screen.getByRole('button', { name: 'Confirm reversal' }));
    expect(mockRpc).toHaveBeenCalledWith('ins_reverse_policy', {
      p_policy_id: 'p1', p_reason: 'Correct premium', p_reissue: false, p_request_key: expect.any(String),
    });
    await waitFor(() => expect(onReversed).toHaveBeenCalledWith(result));
  });

  it('explicitly requests a linked draft, not automatic binding', async () => {
    const { user } = await open();
    await user.click(screen.getByRole('checkbox'));
    expect(screen.getByText(/review and bind it separately/)).toBeInTheDocument();
    await user.type(screen.getByLabelText('Reversal reason'), 'Replace policy');
    await user.click(screen.getByRole('button', { name: 'Confirm reversal' }));
    expect(mockRpc).toHaveBeenCalledWith('ins_reverse_policy', expect.objectContaining({ p_reissue: true }));
    expect(mockRpc.mock.calls.every(([name]) => name !== 'ins_bind_policy')).toBe(true);
  });

  it('shows blockers and disables an ineligible policy', async () => {
    mockRpc.mockResolvedValue({ eligible: false, reason: 'This policy has a claim.' });
    render(<PolicyReversalAction policyId="p1" policyNo="POL-1" onReversed={vi.fn()} />);
    expect(await screen.findByText('This policy has a claim.')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Reverse policy' })).toBeDisabled();
  });

  it('retains the same request key and dialog after an uncertain error', async () => {
    let attempts = 0;
    mockRpc.mockImplementation((name: string) => {
      if (name === 'ins_policy_reversal_eligibility') return Promise.resolve({ eligible: true, reason: null });
      return ++attempts === 1 ? Promise.reject(new Error('Network response lost')) : Promise.resolve(result);
    });
    const { user } = await open();
    await user.type(screen.getByLabelText('Reversal reason'), 'Correct premium');
    await user.click(screen.getByRole('button', { name: 'Confirm reversal' }));
    expect(await screen.findByText('Network response lost')).toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: 'Confirm reversal' }));
    const calls = mockRpc.mock.calls.filter(([name]) => name === 'ins_reverse_policy');
    expect(calls).toHaveLength(2);
    expect(calls[0][1].p_request_key).toBe(calls[1][1].p_request_key);
  });

  it('cancelling does not reverse or create a draft', async () => {
    const { user } = await open();
    await user.click(screen.getByRole('button', { name: 'Cancel' }));
    expect(mockRpc.mock.calls.filter(([name]) => name === 'ins_reverse_policy')).toHaveLength(0);
  });
});
