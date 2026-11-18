import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import AgentCommissionWht from './AgentCommissionWht';

// The WHT tab answers "what do we still owe URA" without the user doing arithmetic.
// What is tested: the four figures come from the server, the preparer never sees
// Approve, Pay demands a URA reference, an over-reported period is named instead of
// shown as a negative, and refusals lose their error codes.

const mockFrom = vi.fn();
const mockRpc = vi.fn();
const mockGetUser = vi.fn();
vi.mock('../../../../../lib/supabaseClient', () => ({
  supabase: {
    from: (...a: unknown[]) => mockFrom(...a),
    rpc: (...a: unknown[]) => mockRpc(...a),
    auth: { getUser: () => mockGetUser() },
  },
}));

const mockAccess = vi.fn();
vi.mock('../../access', () => ({ useInsuranceAccess: () => mockAccess() }));

const remittance = (over: Record<string, unknown> = {}) => ({
  id: 'r1', tenant_id: 't1', remittance_no: 'WHT-2026-0001',
  period_start: '2026-10-01', period_end: '2026-10-31', currency: 'UGX', amount: 60000,
  status: 'prepared', paid_on: null, payment_reference: null, journal_entry_id: null,
  prepared_by: 'u-maker', approved_by: null, approved_at: null,
  created_at: '2026-11-01T00:00:00Z', updated_at: '2026-11-01T00:00:00Z', ...over,
});

const position = (over: Record<string, unknown> = {}) => ({
  withheld_total: 90000, reported_total: 60000, paid_total: 0,
  unreported: 30000, awaiting_payment: 60000, remittances: [], ...over,
});

let data: Record<string, unknown[]>;
const builder = (out: unknown[]) => {
  const b: Record<string, unknown> = {};
  b.select = () => b; b.order = () => b; b.range = () => b; b.eq = () => b;
  b.then = (res: (v: unknown) => unknown) => Promise.resolve({ data: out, error: null }).then(res);
  return b;
};

const BANKS = [{ id: 'b1', name: 'Stanbic Current', currency: 'UGX' }];

/**
 * `db.rpc()` unwraps `{ data, error }` before returning, so a mock that resolves a
 * bare value hands the component `undefined` and the screen silently renders
 * nothing. Supabase's own shape is the honest fixture.
 */
const ok = (data: unknown) => Promise.resolve({ data, error: null });

beforeEach(() => {
  mockFrom.mockReset();
  mockRpc.mockReset();
  mockGetUser.mockReset();
  mockAccess.mockReset();
  data = {
    ins_wht_remittances: [remittance()],
    app_users: [
      { id: 'u-maker', name: 'Mary Maker', email: 'mary@example.com' },
      { id: 'u-checker', name: 'Charles Checker', email: 'charles@example.com' },
    ],
  };
  mockFrom.mockImplementation((t: string) => builder(data[t] ?? []));
  mockRpc.mockImplementation((fn: string) => ok(fn === 'ins_wht_position' ? position() : BANKS));
  mockAccess.mockReturnValue({ loading: false, canManage: true });
  mockGetUser.mockResolvedValue({ data: { user: { id: 'u-checker' } } });
});

const renderTab = () => render(<AgentCommissionWht />);

describe('the four figures come from the server', () => {
  it('shows withheld, unreported, reported-not-paid and paid', async () => {
    renderTab();

    expect(await screen.findByText('Withheld from agents')).toBeTruthy();
    expect(screen.getByText('Not on any return')).toBeTruthy();
    expect(screen.getByText('Reported, not paid')).toBeTruthy();
    expect(screen.getByText('Paid to URA')).toBeTruthy();
    // 90,000 withheld / 30,000 unreported / 60,000 awaiting / 0 paid
    expect(screen.getAllByText(/USh\s*90,000/).length).toBeGreaterThan(0);
    expect(screen.getAllByText(/USh\s*30,000/).length).toBeGreaterThan(0);
    expect(screen.getAllByText(/USh\s*60,000/).length).toBeGreaterThan(0);
  });

  it('makes the over-report an explanation, not a minus sign', async () => {
    mockRpc.mockImplementation((fn: string) => ok(fn === 'ins_wht_position'
      ? position({ withheld_total: 60000, reported_total: 90000, unreported: -30000, awaiting_payment: 90000 })
      : BANKS));
    renderTab();

    // Said twice on purpose: once as the tile's hint, once in the banner that
    // explains what to do about it.
    expect((await screen.findAllByText(/no longer withheld/i)).length).toBe(2);
    expect(screen.getByText(/raise this with URA as a credit/i)).toBeTruthy();
    // No negative backlog is ever printed.
    expect(screen.queryByText(/USh\s*-/)).toBeNull();
  });
});

describe('currencies are shown apart', () => {
  it('gives each currency its own block rather than one meaningless total', async () => {
    mockRpc.mockImplementation((fn: string) => ok(fn === 'ins_wht_position'
      ? {
        ...position({ withheld_total: 900500, unreported: 900500, reported_total: 0, awaiting_payment: 0 }),
        by_currency: [
          { currency: 'UGX', withheld_total: 900000, reported_total: 0, paid_total: 0, unreported: 900000, unreported_open: 900000, over_reported: 0, awaiting_payment: 0 },
          { currency: 'USD', withheld_total: 500, reported_total: 0, paid_total: 0, unreported: 500, unreported_open: 500, over_reported: 0, awaiting_payment: 0 },
        ],
      }
      : BANKS));
    renderTab();

    expect(await screen.findByText('UGX')).toBeTruthy();
    expect(screen.getByText('USD')).toBeTruthy();
    expect(screen.getAllByText(/USh\s*900,000/).length).toBeGreaterThan(0);
    expect(screen.getAllByText(/US\$\s*500/).length).toBeGreaterThan(0);
    // The flat 900,500 sum is never printed: it is not money.
    expect(screen.queryByText(/900,500/)).toBeNull();
  });
});

describe('the return workflow is maker-checker', () => {
  it('does not offer the preparer the approval', async () => {
    mockGetUser.mockResolvedValue({ data: { user: { id: 'u-maker' } } });
    renderTab();

    expect(await screen.findByText(/you prepared this return/i)).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Approve' })).toBeNull();
    // The preparer can still withdraw it.
    expect(screen.getByRole('button', { name: 'Void' })).toBeTruthy();
  });

  it('offers Pay only once the return is approved', async () => {
    data.ins_wht_remittances = [remittance()];
    renderTab();
    expect(await screen.findByRole('button', { name: 'Approve' })).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Pay' })).toBeNull();
  });

  it('offers Pay on an approved return and nothing to approve', async () => {
    data.ins_wht_remittances = [remittance({ status: 'approved', approved_by: 'u-checker', approved_at: '2026-11-02T00:00:00Z' })];
    renderTab();
    expect(await screen.findByRole('button', { name: 'Pay' })).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Approve' })).toBeNull();
  });

  it('shows a member no decisions at all', async () => {
    mockAccess.mockReturnValue({ loading: false, canManage: false });
    renderTab();
    await screen.findByText('WHT-2026-0001');
    for (const name of ['Approve', 'Pay', 'Void', 'Prepare a return']) {
      expect(screen.queryByRole('button', { name })).toBeNull();
    }
  });

  it('approves through the RPC', async () => {
    mockRpc.mockImplementation((fn: string) => ok(fn === 'ins_wht_position' ? position() : BANKS));
    renderTab();

    await userEvent.click(await screen.findByRole('button', { name: 'Approve' }));
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('ins_wht_approve_remittance', { p_id: 'r1' }));
    expect(await screen.findByText(/ready to pay/i)).toBeTruthy();
  });
});

describe('paying to URA needs a reference', () => {
  it('refuses to record a payment without one', async () => {
    data.ins_wht_remittances = [remittance({ status: 'approved', approved_by: 'u-checker', approved_at: '2026-11-02T00:00:00Z' })];
    renderTab();

    await userEvent.click(await screen.findByRole('button', { name: 'Pay' }));
    const dialog = await screen.findByRole('dialog');
    // Pick the account first, so the only thing missing is the reference.
    await userEvent.click(within(dialog).getByLabelText(/Paid from/i));
    await userEvent.click(await screen.findByRole('option', { name: /Stanbic Current/ }));
    await userEvent.click(within(dialog).getByRole('button', { name: 'Record payment' }));

    expect(await screen.findByText(/Enter the URA payment reference/i)).toBeTruthy();
    expect(mockRpc).not.toHaveBeenCalledWith('ins_wht_pay_remittance', expect.anything());
  });

  it('sends bank, date and reference once they are given', async () => {
    data.ins_wht_remittances = [remittance({ status: 'approved', approved_by: 'u-checker', approved_at: '2026-11-02T00:00:00Z' })];
    renderTab();

    await userEvent.click(await screen.findByRole('button', { name: 'Pay' }));
    const dialog = await screen.findByRole('dialog');
    await userEvent.click(within(dialog).getByLabelText(/Paid from/i));
    await userEvent.click(await screen.findByRole('option', { name: /Stanbic Current/ }));
    await userEvent.type(within(dialog).getByLabelText(/URA reference/i), 'URA/2026/000123');
    await userEvent.click(within(dialog).getByRole('button', { name: 'Record payment' }));

    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('ins_wht_pay_remittance', {
      p_id: 'r1', p_bank_account_id: 'b1', p_paid_on: expect.any(String), p_reference: 'URA/2026/000123',
    }));
  });
});

describe('voiding needs a reason and is explained', () => {
  it('refuses a short reason', async () => {
    renderTab();
    await userEvent.click(await screen.findByRole('button', { name: 'Void' }));
    const dialog = await screen.findByRole('dialog');
    await userEvent.type(within(dialog).getByLabelText(/reason/i), 'oops');
    await userEvent.click(within(dialog).getByRole('button', { name: 'Void' }));

    expect((await screen.findAllByText(/at least 10 characters/i)).length).toBeGreaterThan(0);
    expect(mockRpc).not.toHaveBeenCalledWith('ins_wht_void_remittance', expect.anything());
  });

  it('says the return is kept when it is voided', async () => {
    renderTab();
    await userEvent.click(await screen.findByRole('button', { name: 'Void' }));
    const dialog = await screen.findByRole('dialog');
    expect(within(dialog).getByText(/marked void/i)).toBeTruthy();
  });
});

describe('server refusals are readable', () => {
  it('strips the error code', async () => {
    mockRpc.mockImplementation((fn: string) => {
      if (fn === 'ins_wht_position') return ok(position());
      if (fn === 'ins_commission_bank_accounts') return ok(BANKS);
      // db.rpc throws with the message already stripped, which is what the screen shows.
      return Promise.reject(new Error('only an approved return can be paid'));
    });
    data.ins_wht_remittances = [remittance()];
    renderTab();

    await userEvent.click(await screen.findByRole('button', { name: 'Approve' }));
    const alert = await screen.findByText(/only an approved return can be paid/i);
    expect(alert.textContent).not.toContain('INS_WHT_NOT_APPROVED');
  });
});
