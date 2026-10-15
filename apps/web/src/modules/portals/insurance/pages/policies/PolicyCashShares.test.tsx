import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { describe, expect, it, vi } from 'vitest';
import PolicyCashPanel from './PolicyCashPanel';
const { call } = vi.hoisted(() => ({ call: vi.fn() }));
vi.mock('../../db', () => ({ rpc: call, errorText: (e: Error) => e.message }));
describe('co-insurer remittance selection', () => {
  it('shows independent caps and submits against the specifically selected insurer share', async () => {
    call.mockImplementation(async (name: string) =>
      name === 'ins_policy_cash_position'
        ? {
            policy_id: 'p1',
            policy_status: 'active',
            currency: 'UGX',
            actor_id: 'maker',
            can_prepare: true,
            collected: 604.5,
            remitted: 0,
            commission_transferred: 0,
            commission_amount: 140,
            commission_status: 'per insurer share',
            available_allocated_funds: 575,
            client_outstanding: 604.5,
            insurer_outstanding: 1010,
            maximum_remittance: 575,
            requests: [],
            shares: [
              {
                share_id: 'a',
                insurer_id: 'ins-a',
                insurer_name: 'Alpha',
                is_lead: true,
                share_pct: 60,
                funded: 330,
                remitted: 0,
                outstanding: 600,
                maximum_remittance: 330,
              },
              {
                share_id: 'b',
                insurer_id: 'ins-b',
                insurer_name: 'Beta',
                is_lead: false,
                share_pct: 40,
                funded: 245,
                remitted: 0,
                outstanding: 410,
                maximum_remittance: 245,
              },
            ],
          }
        : name === 'ins_policy_cash_bank_accounts'
          ? [{ id: 'trust', name: 'Trust bank', currency: 'UGX' }]
          : {},
    );
    render(
      <MemoryRouter>
        <PolicyCashPanel policyId="p1" mode="finance" />
      </MemoryRouter>,
    );
    fireEvent.click(
      await screen.findByRole('button', { name: 'Prepare insurer remittance' }),
    );
    fireEvent.mouseDown(
      screen.getByRole('combobox', { name: 'Insurer to remit to' }),
    );
    fireEvent.click(
      await screen.findByRole('option', { name: /Beta — available/ }),
    );
    fireEvent.mouseDown(
      screen.getByRole('combobox', { name: 'Client-money bank account' }),
    );
    fireEvent.click(
      await screen.findByRole('option', { name: 'Trust bank (UGX)' }),
    );
    fireEvent.change(screen.getByLabelText('Amount'), {
      target: { value: '246' },
    });
    fireEvent.click(
      screen.getByRole('button', { name: 'Submit for approval' }),
    );
    await screen.findByText(/Amount exceeds the current available limit/);
    expect(call).not.toHaveBeenCalledWith(
      'ins_submit_policy_share_cash_request',
      expect.anything(),
    );
    fireEvent.change(screen.getByLabelText('Amount'), {
      target: { value: '200' },
    });
    fireEvent.click(
      screen.getByRole('button', { name: 'Submit for approval' }),
    );
    await waitFor(() =>
      expect(call).toHaveBeenCalledWith(
        'ins_submit_policy_share_cash_request',
        expect.objectContaining({
          p_policy_id: 'p1',
          p_insurer_share_id: 'b',
          p_amount: 200,
        }),
      ),
    );
    expect(call).not.toHaveBeenCalledWith(
      'ins_submit_policy_cash_request',
      expect.anything(),
    );
  });
});
