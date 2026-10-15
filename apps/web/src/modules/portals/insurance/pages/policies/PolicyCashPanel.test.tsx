import { fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import PolicyCashPanel from './PolicyCashPanel';
import type { PolicyCashPosition, PolicyCashRequest } from '../../policyCash';

const { call } = vi.hoisted(() => ({ call: vi.fn() }));
vi.mock('../../db', () => ({ rpc: call, errorText: (e: Error) => e.message }));
let position: PolicyCashPosition;
const request: PolicyCashRequest = {
  id: 'q1', kind: 'receipt', amount: 400, cash_date: '2026-10-15', reference: 'REF-01', notes: 'Partial premium',
  status: 'pending', maker_id: 'maker', checker_id: null, checked_at: null, created_at: '2026-10-15T09:00:00Z',
  decision_reason: null, bank_account_id: 'bank1', bank_name: 'Premium Trust', settlement_id: null, settlement_no: null,
  reconciled: false, reconciled_by: null, reconciled_at: null,
};
beforeEach(() => {
  position = {
    policy_id: 'p1', policy_status: 'active', currency: 'UGX', actor_id: 'maker', can_prepare: true,
    collected: 400, remitted: 0, commission_transferred: 0, commission_amount: 100, commission_status: 'deferred',
    available_allocated_funds: 400, client_outstanding: 600, insurer_outstanding: 900, maximum_remittance: 400, requests: [request],
  };
  call.mockReset().mockImplementation(async (name: string) => {
    if (name === 'ins_policy_cash_position') return position;
    if (name === 'ins_policy_cash_bank_accounts') return [{ id: 'bank1', name: 'Premium Trust', currency: 'UGX' }];
    return {};
  });
});
const mount = (mode: 'view' | 'finance' = 'finance') => render(<MemoryRouter><PolicyCashPanel policyId="p1" mode={mode} /></MemoryRouter>);
async function receiptForm() {
  fireEvent.click(await screen.findByRole('button', { name: 'Prepare premium receipt' }));
  fireEvent.mouseDown(screen.getByRole('combobox', { name: 'Client-money bank account' }));
  fireEvent.click(await screen.findByRole('option', { name: 'Premium Trust (UGX)' }));
  fireEvent.change(screen.getByLabelText('Amount'), { target: { value: '200' } });
}

describe('policy cash workflow panel', () => {
  it('is read-only for Insurance even if its user also has Finance authority', async () => {
    mount('view');
    await screen.findByText('Client money collected');
    expect(screen.queryByRole('button', { name: 'Prepare premium receipt' })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Approve and post' })).not.toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'Open Finance cash workflow' })).toHaveAttribute('href', '/financial-management/insurance-premium-cash?policy=p1');
    expect(call).not.toHaveBeenCalledWith('ins_policy_cash_bank_accounts');
  });
  it('does not offer preparation or checking to non-Finance users', async () => {
    position.can_prepare = false; mount();
    await screen.findByText(/Authorized Finance membership/);
    expect(screen.queryByRole('button', { name: 'Prepare premium receipt' })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Cancel request' })).not.toBeInTheDocument();
  });
  it('lets the maker cancel but never approve their own request', async () => {
    mount(); await screen.findByRole('button', { name: 'Cancel request' });
    expect(screen.queryByRole('button', { name: 'Approve and post' })).not.toBeInTheDocument();
  });
  it('requires a checker confirmation, then calls the transactional approval RPC', async () => {
    position.actor_id = 'checker'; mount();
    fireEvent.click(await screen.findByRole('button', { name: 'Approve and post' }));
    const dialog = screen.getByRole('dialog');
    expect(within(dialog).getByText(/Approval immediately posts/)).toBeInTheDocument();
    expect(call).not.toHaveBeenCalledWith('ins_decide_policy_cash_request', expect.anything());
    fireEvent.click(within(dialog).getByRole('button', { name: 'Approve and post' }));
    await waitFor(() => expect(call).toHaveBeenCalledWith('ins_decide_policy_cash_request', {
      p_request_id: 'q1', p_decision: 'approve', p_reason: null,
    }));
  });
  it('submits a pending receipt and preserves its idempotency key on a failed-response retry', async () => {
    let failed = false;
    const base = call.getMockImplementation()!;
    call.mockImplementation(async (...args: unknown[]) => {
      if (args[0] === 'ins_submit_policy_cash_request' && !failed) { failed = true; throw new Error('Network interrupted'); }
      return base(...args);
    });
    mount(); await receiptForm();
    fireEvent.click(screen.getByRole('button', { name: 'Submit for approval' }));
    await screen.findByText('Network interrupted');
    fireEvent.click(screen.getByRole('button', { name: 'Submit for approval' }));
    await waitFor(() => expect(call.mock.calls.filter(([name]) => name === 'ins_submit_policy_cash_request')).toHaveLength(2));
    const requests = call.mock.calls.filter(([name]) => name === 'ins_submit_policy_cash_request');
    expect(requests[0][1]).toEqual(requests[1][1]);
    expect(requests[0][1]).toMatchObject({ p_policy_id: 'p1', p_kind: 'receipt', p_bank_account_id: 'bank1', p_amount: 200 });
  });
  it('disables remittance preparation until an allocated receipt is posted', async () => {
    position.maximum_remittance = 0; position.available_allocated_funds = 0; position.collected = 0;
    mount(); expect(await screen.findByRole('button', { name: 'Prepare insurer remittance' })).toBeDisabled();
  });
  it('shows server funding failures instead of claiming success', async () => {
    position.actor_id = 'checker';
    const base = call.getMockImplementation()!;
    call.mockImplementation(async (...args: unknown[]) => {
      if (args[0] === 'ins_decide_policy_cash_request') throw new Error('INS_CASH_CAP: funds already consumed');
      return base(...args);
    });
    mount(); fireEvent.click(await screen.findByRole('button', { name: 'Approve and post' }));
    fireEvent.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Approve and post' }));
    expect(await screen.findByText(/funds already consumed/)).toBeInTheDocument();
    expect(screen.getByRole('dialog')).toBeInTheDocument();
  });
  it('shows approval and independent reconciliation evidence for posted requests', async () => {
    position.requests = [{ ...request, status: 'posted', checker_id: 'checker', settlement_no: 'STL-001', reconciled: true, reconciled_by: 'third-user' }];
    mount();
    await screen.findByText('Bank reconciled');
    expect(screen.getByText('Checker / poster: checker')).toBeInTheDocument();
    expect(screen.getByText('Reconciler: third-user')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Approve and post' })).not.toBeInTheDocument();
  });
});
