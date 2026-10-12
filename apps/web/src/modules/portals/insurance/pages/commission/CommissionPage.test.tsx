import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import CommissionPage from './CommissionPage';

// Commission screen: transfers go through ins_transfer_earned_commission (never a
// direct table write), only earned entries can be picked, members get a read-only
// view, a server refusal is shown without its error code, and voiding a transfer
// needs a reason before the RPC is attempted.

const mockFrom = vi.fn();
const mockRpc = vi.fn();
vi.mock('../../../../../lib/supabaseClient', () => ({
  supabase: {
    from: (...args: unknown[]) => mockFrom(...args),
    rpc: (...args: unknown[]) => mockRpc(...args),
  },
}));

const mockAccess = vi.fn();
vi.mock('../../access', () => ({
  useInsuranceAccess: () => mockAccess(),
}));

const entry = (over: Record<string, unknown>) => ({
  id: 'e', policy_id: 'p', policy_no: 'POL-1', insurer_id: 'i1', client_id: 'c1', amount: 100000,
  status: 'earned', earned_on: '2026-10-09', transfer_id: null, transfer_no: null, transfer_date: null,
  created_at: '2026-10-09T00:00:00Z', ...over,
});

const LEDGER = [
  entry({ id: 'e-earned-1', policy_no: 'POL-0001', amount: 100000 }),
  entry({ id: 'e-earned-2', policy_no: 'POL-0002', amount: 12500.13, earned_on: '2026-10-10' }),
  entry({ id: 'e-deferred', policy_no: 'POL-0003', status: 'deferred', earned_on: null, amount: 50000 }),
  entry({ id: 'e-moved', policy_no: 'POL-0004', status: 'transferred', transfer_id: 't1', transfer_no: 'CTR-2026-0001', amount: 70000 }),
];
const POSITION = [{ tenant_id: 't', unearned_amount: 50000, earned_in_client_money: 112500.13, transferred_amount: 70000 }];
const TRANSFERS = [
  { id: 't1', transfer_no: 'CTR-2026-0001', from_bank_account_id: 'b-trust', to_bank_account_id: 'b-oper', transfer_date: '2026-10-10',
    amount: 70000, currency: 'UGX', status: 'posted', notes: 'first batch', void_reason: null, created_at: '2026-10-10T00:00:00Z' },
];
const INSURERS = [{ id: 'i1', name: 'Alpha Assurance' }];
const BANKS = [
  { id: 'b-trust', name: 'TRUST-UGX', kind: 'client_money', currency: 'UGX', bank_name: 'Stanbic' },
  { id: 'b-oper', name: 'OPER-UGX', kind: 'operating', currency: 'UGX', bank_name: 'Stanbic' },
];

function selectChain(rows: unknown[]) {
  const chain: Record<string, unknown> = {};
  for (const m of ['select', 'eq', 'order', 'in']) chain[m] = vi.fn(() => chain);
  (chain as { then: unknown }).then = (resolve: (v: unknown) => void) => resolve({ data: rows, error: null });
  return chain;
}

beforeEach(() => {
  vi.clearAllMocks();
  mockAccess.mockReturnValue({ loading: false, canManage: true });
  mockFrom.mockImplementation((name: string) => {
    if (name === 'ins_commission_ledger') return selectChain(LEDGER);
    if (name === 'ins_commission_position') return selectChain(POSITION);
    if (name === 'ins_commission_transfers') return selectChain(TRANSFERS);
    if (name === 'ins_insurers') return selectChain(INSURERS);
    throw new Error(`unexpected table ${name}`);
  });
  mockRpc.mockImplementation(async (fn: string) => {
    if (fn === 'ins_commission_bank_accounts') return { data: BANKS, error: null };
    if (fn === 'ins_transfer_earned_commission') return { data: { transfer_no: 'CTR-2026-0002' }, error: null };
    return { data: null, error: null };
  });
});

describe('CommissionPage', () => {
  it('shows the three amounts and the entries with their insurer', async () => {
    render(<CommissionPage />);
    expect(await screen.findByText('POL-0001')).toBeTruthy();
    // Each label appears on a card and on the status chips below.
    for (const label of ['Unearned', 'Earned, in client money', 'Transferred']) {
      expect(screen.getAllByText(label).length).toBeGreaterThan(0);
    }
    expect(screen.getByText(/112,500\.13/)).toBeTruthy();
    expect(screen.getAllByText('Alpha Assurance').length).toBe(4);
    expect(screen.getByText('CTR-2026-0001')).toBeTruthy();
  });

  it('lets only earned entries be selected and totals the selection', async () => {
    const user = userEvent.setup();
    render(<CommissionPage />);
    await screen.findByText('POL-0001');
    expect((screen.getByLabelText('Select POL-0003') as HTMLInputElement).disabled).toBe(true);
    expect((screen.getByLabelText('Select POL-0004') as HTMLInputElement).disabled).toBe(true);
    const btn = screen.getByRole('button', { name: 'Transfer selected' }) as HTMLButtonElement;
    expect(btn.disabled).toBe(true);

    await user.click(screen.getByLabelText('Select POL-0001'));
    await user.click(screen.getByLabelText('Select POL-0002'));
    const sel = await screen.findByRole('button', { name: /Transfer 2 selected/ });
    expect(sel.textContent).toMatch(/112,500\.13/);
  });

  it('sends the transfer through the RPC with the chosen entries, banks and date', async () => {
    const user = userEvent.setup();
    render(<CommissionPage />);
    await screen.findByText('POL-0001');
    await user.click(screen.getByLabelText('Select all earned entries'));
    await user.click(await screen.findByRole('button', { name: /Transfer 2 selected/ }));

    const dialog = await screen.findByRole('dialog');
    // One account of each kind: both are pre-selected.
    const submit = within(dialog).getByRole('button', { name: 'Transfer commission' }) as HTMLButtonElement;
    await waitFor(() => expect(submit.disabled).toBe(false));
    await user.type(within(dialog).getByLabelText('Notes (optional)'), 'October batch');
    await user.click(submit);

    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('ins_transfer_earned_commission', expect.objectContaining({
      p_from_bank_account_id: 'b-trust',
      p_to_bank_account_id: 'b-oper',
      p_entry_ids: ['e-earned-1', 'e-earned-2'],
      p_notes: 'October batch',
    })));
    expect(await screen.findByText(/as CTR-2026-0002/)).toBeTruthy();
    expect(mockFrom).not.toHaveBeenCalledWith('ins_commission_entries');
  });

  it('shows a server refusal without its error code and keeps the dialog open', async () => {
    mockRpc.mockImplementation(async (fn: string) => {
      if (fn === 'ins_commission_bank_accounts') return { data: BANKS, error: null };
      return { data: null, error: { message: 'INS_TRANSFER_TRUST_SHORT: client-money account TRUST-UGX holds 0 in the ledger' } };
    });
    const user = userEvent.setup();
    render(<CommissionPage />);
    await screen.findByText('POL-0001');
    await user.click(screen.getByLabelText('Select POL-0001'));
    await user.click(await screen.findByRole('button', { name: /Transfer 1 selected/ }));
    const dialog = await screen.findByRole('dialog');
    const submit = within(dialog).getByRole('button', { name: 'Transfer commission' }) as HTMLButtonElement;
    await waitFor(() => expect(submit.disabled).toBe(false));
    await user.click(submit);
    expect(await within(dialog).findByText(/client-money account TRUST-UGX holds 0/)).toBeTruthy();
    expect(screen.queryByText(/INS_TRANSFER_TRUST_SHORT/)).toBeNull();
  });

  it('is read-only for a member: no checkboxes, no transfer button, no bank lookup', async () => {
    mockAccess.mockReturnValue({ loading: false, canManage: false });
    render(<CommissionPage />);
    await screen.findByText('POL-0001');
    expect(screen.queryByLabelText('Select POL-0001')).toBeNull();
    expect(screen.queryByRole('button', { name: /Transfer/ })).toBeNull();
    expect(mockRpc).not.toHaveBeenCalledWith('ins_commission_bank_accounts');
    expect(screen.getByText(/Only insurance managers and admins can transfer commission/)).toBeTruthy();
  });

  it('needs a void reason before calling the RPC', async () => {
    const user = userEvent.setup();
    render(<CommissionPage />);
    await screen.findByText('POL-0001');
    await user.click(screen.getByRole('tab', { name: /Transfers/ }));
    await user.click(await screen.findByRole('button', { name: 'Void' }));

    const dialog = await screen.findByRole('dialog');
    const confirm = within(dialog).getByRole('button', { name: 'Void transfer' }) as HTMLButtonElement;
    expect(confirm.disabled).toBe(true);
    await user.type(within(dialog).getByLabelText(/Reason/), 'no');
    expect(confirm.disabled).toBe(true);
    await user.type(within(dialog).getByLabelText(/Reason/), ' - entered in error');
    expect(confirm.disabled).toBe(false);
    await user.click(confirm);

    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('ins_void_commission_transfer', {
      p_transfer_id: 't1',
      p_reason: 'no - entered in error',
    }));
  });
});