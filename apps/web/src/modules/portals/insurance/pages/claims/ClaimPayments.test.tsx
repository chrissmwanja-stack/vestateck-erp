import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import ClaimPayments from './ClaimPayments';
import type { Claim } from '../../types';

// Claim payment panel: insurer-direct claims record the insurer's payment (reference
// required, no bank account, no bank lookup); brokerage-managed claims record a receipt
// and a payout against a client-money account, and the payout button waits for money to
// be held. Everything goes through the RPCs, never a direct table write. Members see the
// figures but no actions. A void needs a reason first.

const mockFrom = vi.fn();
const mockRpc = vi.fn();
vi.mock('../../../../../lib/supabaseClient', () => ({
  supabase: {
    from: (...args: unknown[]) => mockFrom(...args),
    rpc: (...args: unknown[]) => mockRpc(...args),
  },
}));

const claim = (over: Partial<Claim>): Claim => ({
  id: 'cl1', claim_no: 'CLM-2026-00001', policy_id: 'p1', status: 'approved', loss_date: '2026-10-01',
  notified_date: '2026-10-01', approved_amount: 1000000, paid_amount: 0, payment_mode: 'insurer_direct', recognised_at: '2026-10-02T09:00:00Z',
  settled_at: null, ...over,
} as unknown as Claim);

const BANKS = [
  { id: 'b-trust', name: 'TRUST-UGX', kind: 'client_money', currency: 'UGX', bank_name: 'Stanbic' },
  { id: 'b-oper', name: 'OPER-UGX', kind: 'operating', currency: 'UGX', bank_name: 'Stanbic' },
];

let payments: unknown[] = [];
let position: unknown[] = [];

function selectChain(rowsFn: () => unknown[]) {
  const chain: Record<string, unknown> = {};
  for (const m of ['select', 'eq', 'order']) chain[m] = vi.fn(() => chain);
  (chain as { then: unknown }).then = (resolve: (v: unknown) => void) => resolve({ data: rowsFn(), error: null });
  return chain;
}

const cashPosition = (over: Record<string, unknown>) => ({
  claim_id: 'cl1', claim_no: 'CLM-2026-00001', payment_mode: 'via_broker', approved_amount: 1000000, paid_amount: 0,
  received_from_insurer: 0, paid_to_client: 0, paid_by_insurer_direct: 0, held_for_client: 0, due_from_insurer: 1000000, ...over,
});

const renderPanel = (c: Claim, canManage = true) =>
  render(<ClaimPayments claim={c} currency="UGX" canManage={canManage} onChanged={vi.fn()} />);

beforeEach(() => {
  vi.clearAllMocks();
  payments = [];
  position = [];
  mockFrom.mockImplementation((name: string) => {
    if (name === 'ins_claim_payments') return selectChain(() => payments);
    if (name === 'ins_claim_cash_position') return selectChain(() => position);
    throw new Error(`unexpected table ${name}`);
  });
  mockRpc.mockImplementation(async (fn: string) => {
    if (fn === 'ins_commission_bank_accounts') return { data: BANKS, error: null };
    return { data: { id: 'x' }, error: null };
  });
});

describe('ClaimPayments', () => {
  it('shows nothing until the claim has been approved', () => {
    const { container } = renderPanel(claim({ status: 'assessing', approved_amount: null, payment_mode: null }));
    expect(container.textContent).toBe('');
  });

  it('insurer-direct: explains the flow, needs no bank, and requires the insurer reference', async () => {
    const user = userEvent.setup();
    renderPanel(claim({}));
    expect(await screen.findByText('Insurer pays the client')).toBeTruthy();
    expect(screen.getByText(/Nothing is posted to the ledger/)).toBeTruthy();
    expect(screen.queryByRole('button', { name: /Pay client/ })).toBeNull();
    expect(mockRpc).not.toHaveBeenCalledWith('ins_commission_bank_accounts', expect.anything());

    await user.click(screen.getByRole('button', { name: 'Record insurer payment' }));
    const dialog = await screen.findByRole('dialog');
    const save = within(dialog).getByRole('button', { name: 'Save' }) as HTMLButtonElement;
    expect(save.disabled).toBe(true); // reference missing
    expect(within(dialog).queryByLabelText(/Client-money bank account/)).toBeNull();

    await user.type(within(dialog).getByLabelText(/Insurer's payment reference/), 'ALPHA-ADV-001');
    await waitFor(() => expect(save.disabled).toBe(false));
    await user.click(save);
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('ins_record_claim_payment', expect.objectContaining({
      p_claim_id: 'cl1', p_amount: 1000000, p_reference: 'ALPHA-ADV-001',
    })));
    expect(mockFrom).not.toHaveBeenCalledWith('ins_claims');
  });

  it('insurer-direct: blocks an amount above what is still unpaid', async () => {
    const user = userEvent.setup();
    renderPanel(claim({ paid_amount: 400000 }));
    await user.click(await screen.findByRole('button', { name: 'Record insurer payment' }));
    const dialog = await screen.findByRole('dialog');
    const amount = within(dialog).getByLabelText(/Amount/) as HTMLInputElement;
    expect(amount.value).toBe('600000'); // defaults to the balance
    await user.clear(amount);
    await user.type(amount, '700000');
    expect(await within(dialog).findByText(/Only .*600,000.* is still unpaid/)).toBeTruthy();
    expect((within(dialog).getByRole('button', { name: 'Save' }) as HTMLButtonElement).disabled).toBe(true);
  });

  it('brokerage-managed: an approved claim is pending settlement until the receivable is recognised', async () => {
    const user = userEvent.setup();
    renderPanel(claim({ payment_mode: 'via_broker', recognised_at: null }));
    expect(await screen.findByText(/Approved, pending settlement/)).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Record receipt from insurer' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Pay client' })).toBeNull();
    const recognise = screen.getByRole('button', { name: 'Recognise receivable' }) as HTMLButtonElement;
    expect(recognise.disabled).toBe(true); // the insurer's confirmation reference is required
    await user.type(screen.getByLabelText(/Insurer's written confirmation reference/), 'ALPHA-CONF-77');
    expect(recognise.disabled).toBe(false);
    await user.click(recognise);
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('ins_recognise_claim_receivable', {
      p_claim_id: 'cl1', p_insurer_confirmation: 'ALPHA-CONF-77',
    }));
  });

  it('brokerage-managed: payout stays disabled until the insurer money is received', async () => {
    position = [cashPosition({})];
    renderPanel(claim({ payment_mode: 'via_broker' }));
    expect(await screen.findByText('Brokerage pays the client')).toBeTruthy();
    expect(await screen.findByText(/The client can be paid once the insurer's money has been received/)).toBeTruthy();
    expect((screen.getByRole('button', { name: 'Pay client' }) as HTMLButtonElement).disabled).toBe(true);
    expect((screen.getByRole('button', { name: 'Record receipt from insurer' }) as HTMLButtonElement).disabled).toBe(false);
  });

  it('brokerage-managed: records a receipt against the client-money account only', async () => {
    position = [cashPosition({})];
    const user = userEvent.setup();
    renderPanel(claim({ payment_mode: 'via_broker' }));
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('ins_commission_bank_accounts', {}));
    await user.click(await screen.findByRole('button', { name: 'Record receipt from insurer' }));
    const dialog = await screen.findByRole('dialog');
    const save = within(dialog).getByRole('button', { name: 'Save' }) as HTMLButtonElement;
    await waitFor(() => expect(save.disabled).toBe(false)); // the one client-money account is pre-selected
    await user.click(save);
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('ins_record_claim_receipt', expect.objectContaining({
      p_claim_id: 'cl1', p_bank_account_id: 'b-trust', p_amount: 1000000,
    })));
  });

  it('brokerage-managed: pays out only what is held, through the payout RPC', async () => {
    position = [cashPosition({ received_from_insurer: 600000, held_for_client: 600000, due_from_insurer: 400000 })];
    const user = userEvent.setup();
    renderPanel(claim({ payment_mode: 'via_broker' }));
    const pay = (await screen.findByRole('button', { name: 'Pay client' })) as HTMLButtonElement;
    await waitFor(() => expect(pay.disabled).toBe(false));
    await user.click(pay);
    const dialog = await screen.findByRole('dialog');
    expect((within(dialog).getByLabelText(/Amount/) as HTMLInputElement).value).toBe('600000');
    await user.click(within(dialog).getByRole('button', { name: 'Save' }));
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('ins_record_claim_payout', expect.objectContaining({
      p_claim_id: 'cl1', p_bank_account_id: 'b-trust', p_amount: 600000,
    })));
  });

  it('shows a server refusal without its error code and keeps the dialog open', async () => {
    mockRpc.mockImplementation(async (fn: string) => {
      if (fn === 'ins_commission_bank_accounts') return { data: BANKS, error: null };
      return { data: null, error: { message: 'INS_CLAIM_FUNDS_NOT_RECEIVED: only 0 has been received from the insurer' } };
    });
    position = [cashPosition({ received_from_insurer: 600000, held_for_client: 600000, due_from_insurer: 400000 })];
    const user = userEvent.setup();
    renderPanel(claim({ payment_mode: 'via_broker' }));
    const pay = (await screen.findByRole('button', { name: 'Pay client' })) as HTMLButtonElement;
    await waitFor(() => expect(pay.disabled).toBe(false));
    await user.click(pay);
    const dialog = await screen.findByRole('dialog');
    await user.click(within(dialog).getByRole('button', { name: 'Save' }));
    expect(await within(dialog).findByText(/only 0 has been received from the insurer/)).toBeTruthy();
    expect(screen.queryByText(/INS_CLAIM_FUNDS_NOT_RECEIVED/)).toBeNull();
  });

  it('is read-only for a member: figures but no actions and no bank lookup', async () => {
    position = [cashPosition({})];
    renderPanel(claim({ payment_mode: 'via_broker' }), false);
    expect(await screen.findByText('Brokerage pays the client')).toBeTruthy();
    expect(screen.queryByRole('button', { name: /Record receipt|Pay client|Record insurer payment/ })).toBeNull();
    expect(mockRpc).not.toHaveBeenCalledWith('ins_commission_bank_accounts', expect.anything());
  });

  it('needs a void reason before calling the RPC', async () => {
    payments = [{
      id: 'pay1', claim_id: 'cl1', kind: 'insurer_direct', amount: 400000, payment_date: '2026-10-10', reference: 'ALPHA-ADV-001',
      notes: null, settlement_id: null, status: 'posted', void_reason: null, created_at: '2026-10-10T00:00:00Z',
    }];
    const user = userEvent.setup();
    renderPanel(claim({ paid_amount: 400000 }));
    expect(await screen.findByText('ALPHA-ADV-001')).toBeTruthy();
    await user.click(screen.getByRole('button', { name: 'Void' }));
    const dialog = await screen.findByRole('dialog');
    const confirm = within(dialog).getByRole('button', { name: 'Void payment' }) as HTMLButtonElement;
    expect(confirm.disabled).toBe(true);
    await user.type(within(dialog).getByLabelText(/Reason/), 'no');
    expect(confirm.disabled).toBe(true);
    await user.type(within(dialog).getByLabelText(/Reason/), ' - insurer reversed it');
    expect(confirm.disabled).toBe(false);
    await user.click(confirm);
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('ins_void_claim_payment', {
      p_payment_id: 'pay1', p_reason: 'no - insurer reversed it',
    }));
  });
});
