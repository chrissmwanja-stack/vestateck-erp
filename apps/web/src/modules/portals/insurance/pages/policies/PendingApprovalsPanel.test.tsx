import { render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import PendingApprovalsPanel from './PendingApprovalsPanel';

const { call } = vi.hoisted(() => ({ call: vi.fn() }));
vi.mock('../../db', () => ({ rpc: call, errorText: (e: Error) => e.message }));

const row = (over: Record<string, unknown>) => ({
  item_type: 'premium_cash', item_id: 'i1', policy_id: 'p1', policy_no: 'POL-1', client_name: 'Acme Ltd', insurer_name: 'Alpha',
  currency: 'UGX', kind: 'receipt', amount: 400, submitted_at: new Date().toISOString(), submitted_by_name: 'Mary', is_mine: false, ...over,
});

beforeEach(() => { call.mockReset(); });

describe('PendingApprovalsPanel', () => {
  it('lists what is waiting, putting the items the reviewer can decide first', async () => {
    call.mockResolvedValue([
      row({ item_id: 'a', policy_no: 'POL-MINE', is_mine: true }),
      row({ item_id: 'b', policy_no: 'POL-OTHER', item_type: 'cancellation_cash', kind: 'refund', amount: '250.00' }),
      row({ item_id: 'c', policy_no: 'POL-CANC', item_type: 'cancellation', kind: 'proposed', amount: null }),
    ]);
    render(<PendingApprovalsPanel onOpen={vi.fn()} />);
    await screen.findByText('POL-OTHER');
    expect(call).toHaveBeenCalledWith('ins_finance_pending_approvals');
    const order = screen.getAllByRole('row').slice(1).map((r) => within(r).getAllByRole('cell')[1].textContent);
    expect(order).toEqual(['POL-OTHER', 'POL-CANC', 'POL-MINE']);
    expect(screen.getByText('2 for you to decide')).toBeInTheDocument();
    expect(screen.getByText('1 you submitted')).toBeInTheDocument();
    expect(screen.getByText('Client refund')).toBeInTheDocument();
    expect(screen.getByText('Awaiting preparation')).toBeInTheDocument();
    // An item without an amount shows a dash, and money carries its own currency.
    const canc = screen.getByText('POL-CANC').closest('tr') as HTMLElement;
    expect(within(canc).getByText('-')).toBeInTheDocument();
    expect(within(screen.getByText('POL-OTHER').closest('tr') as HTMLElement).getByText(/250/)).toBeInTheDocument();
  });

  it('opens the policy for an item, and marks the ones the reviewer submitted', async () => {
    call.mockResolvedValue([row({ item_id: 'a', policy_id: 'pa', policy_no: 'POL-A' }), row({ item_id: 'b', policy_id: 'pb', policy_no: 'POL-B', is_mine: true })]);
    const onOpen = vi.fn();
    render(<PendingApprovalsPanel onOpen={onOpen} />);
    await screen.findByText('POL-A');
    expect(screen.getByText('You submitted it')).toBeInTheDocument();
    await userEvent.click(within(screen.getByText('POL-A').closest('tr') as HTMLElement).getByRole('button', { name: 'Review' }));
    expect(onOpen).toHaveBeenCalledWith('pa');
    await userEvent.click(within(screen.getByText('POL-B').closest('tr') as HTMLElement).getByRole('button', { name: 'Open' }));
    expect(onOpen).toHaveBeenCalledWith('pb');
  });

  it('says so when nothing is waiting', async () => {
    call.mockResolvedValue([]);
    render(<PendingApprovalsPanel onOpen={vi.fn()} />);
    expect(await screen.findByText('Nothing is waiting for Finance.')).toBeInTheDocument();
  });

  it('shows the server error and no list when Finance access is refused', async () => {
    call.mockRejectedValue(new Error('INS_CASH_FORBIDDEN: Finance required'));
    render(<PendingApprovalsPanel onOpen={vi.fn()} />);
    expect(await screen.findByText('INS_CASH_FORBIDDEN: Finance required')).toBeInTheDocument();
    expect(screen.queryByRole('table')).not.toBeInTheDocument();
  });

  it('warns when the list is at its limit, because more are waiting', async () => {
    call.mockResolvedValue(Array.from({ length: 200 }, (_, n) => row({ item_id: `i${n}`, policy_no: `POL-${n}` })));
    render(<PendingApprovalsPanel onOpen={vi.fn()} />);
    expect(await screen.findByText(/Showing the 200 that have waited longest/)).toBeInTheDocument();
  });

  it('refreshes on request', async () => {
    call.mockResolvedValue([]);
    render(<PendingApprovalsPanel onOpen={vi.fn()} />);
    await screen.findByText('Nothing is waiting for Finance.');
    await userEvent.click(screen.getByRole('button', { name: 'Refresh' }));
    expect(call).toHaveBeenCalledTimes(2);
  });
});
