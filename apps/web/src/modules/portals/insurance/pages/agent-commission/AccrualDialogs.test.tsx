import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import AccrualDialogs from './AccrualDialogs';

// The dialogs must never decide anything. Every figure they show comes from a
// server reply, and every refusal comes from the server in words. These tests
// pin that: the mocked RPCs are the only source of truth, and a case where the
// browser "helpfully" works something out for itself would show up here as a
// rendered number with no RPC behind it.

const mockRpc = vi.fn();
vi.mock('../../../../../lib/supabaseClient', () => ({
  supabase: { from: vi.fn(), rpc: (...a: unknown[]) => mockRpc(...a) },
}));

/**
 * What the component actually sees.
 *
 * db.rpc() unwraps `{ data, error }` and throws on `error`, so a mock that
 * resolves the payload directly hands the component `undefined`. Every stub in
 * this file goes through here instead, which also means the tests exercise the
 * unwrapping rather than a shape that only exists in tests.
 */
const reply = (payload: unknown) => Promise.resolve({ data: payload, error: null });

let canManage = true;
vi.mock('../../access', () => ({ useInsuranceAccess: () => ({ loading: false, canManage }) }));

const POLICY_OPTIONS = [
  { id: 'p1', policy_no: 'POL-001' },
  { id: 'p2', policy_no: 'POL-002' },
];

const check = (over: Record<string, unknown> = {}) => ({
  code: null, reason: null, intermediary_id: 'i1', name: 'Acme Agents',
  basis: 'pct_of_broker_commission', gross_amount: 300000, currency: 'UGX',
  recognition_mode: 'on_insurer_settlement', ...over,
});

const preview = (over: Record<string, unknown> = {}) => ({
  from: '2026-11-01', to: '2026-11-30',
  eligible: [
    { policy_id: 'p1', policy_no: 'POL-001', inception_date: '2026-11-02', currency: 'UGX', name: 'Acme Agents', basis: 'pct_of_broker_commission', gross_amount: 300000 },
  ],
  eligible_count: 1,
  blocked: [],
  blocked_count: 0,
  by_currency: [{ currency: 'UGX', count: 1, gross_amount: 300000 }],
  ...over,
});

const runResult = (over: Record<string, unknown> = {}) => ({
  from: '2026-11-01', to: '2026-11-30',
  accrued: 1, skipped: 0, failed: 0, failures: [], results: [],
  blocked_before_run: 0,
  by_currency: [{ currency: 'UGX', count: 1, gross_amount: 300000 }],
  ...over,
});

const renderDialogs = () => render(<AccrualDialogs onDone={vi.fn()} policyOptions={POLICY_OPTIONS} />);

/**
 * Pick a policy.
 *
 * `userEvent` drives a full pointer sequence, and the MUI Select's menu is
 * portalled to document.body OUTSIDE the dialog. Its click therefore bubbles
 * through the backdrop, which closes the dialog and takes the answer with it.
 * fireEvent against the option itself is what the component actually listens
 * for, so that is what these tests do.
 */
const choosePolicy = async (policyNo: string) => {
  fireEvent.mouseDown(screen.getByLabelText('Policy'));
  fireEvent.click(await screen.findByRole('option', { name: policyNo }));
};

beforeEach(() => {
  canManage = true;
  mockRpc.mockReset();
});

describe('AccrualDialogs', () => {
  it('offers both actions to a manager', () => {
    renderDialogs();
    expect(screen.getByRole('button', { name: 'Accrue Commission' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Run Accruals' })).toBeTruthy();
  });

  it('shows nothing at all to someone who is not a manager', () => {
    canManage = false;
    renderDialogs();
    expect(screen.queryByRole('button', { name: 'Accrue Commission' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Run Accruals' })).toBeNull();
  });

  it('asks the server about a policy and shows the share it would accrue', async () => {
    mockRpc.mockImplementation(() => reply(check()));
    renderDialogs();

    fireEvent.click(screen.getByRole('button', { name: 'Accrue Commission' }));
    await choosePolicy('POL-001');

    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith(
      'ins_agent_commission_blocked_reason', { p_policy_id: 'p1' },
    ));
    expect(await screen.findByText(/Will accrue Acme Agents/i)).toBeTruthy();
    // en-UG renders UGX as USh, so assert the figure and the agent rather than
    // guessing the symbol.
    expect(screen.getByText(/300,000/)).toBeTruthy();
  });

  it('refuses in the server\'s words and disables the button when the commission is not yet earned', async () => {
    mockRpc.mockImplementation(() => reply(check({
      code: 'INS_AGENT_NOT_RECOGNISED',
      reason: 'the brokerage\'s own commission on POL-001 has not been recognised yet',
      gross_amount: undefined, basis: undefined,
    })));
    renderDialogs();

    fireEvent.click(screen.getByRole('button', { name: 'Accrue Commission' }));
    await choosePolicy('POL-001');

    expect(await screen.findByText(/Commission not yet earned/i)).toBeTruthy();
    expect(screen.getByText(/has not been recognised yet/i)).toBeTruthy();
    const accrue = screen.getByRole('button', { name: 'Accrue' }) as HTMLButtonElement;
    expect(accrue.disabled).toBe(true);
  });

  it('will not accrue a policy the server says is already on the books', async () => {
    mockRpc.mockImplementation(() => reply(check({ code: 'INS_AGENT_ALREADY_ACCRUED', reason: 'a share for Acme Agents is already on the books (accrued, 300000)' })));
    renderDialogs();

    fireEvent.click(screen.getByRole('button', { name: 'Accrue Commission' }));
    await choosePolicy('POL-001');

    expect(await screen.findByText(/Already on the books/i)).toBeTruthy();
    expect((screen.getByRole('button', { name: 'Accrue' }) as HTMLButtonElement).disabled).toBe(true);
  });

  it('never offers a way to type an amount', async () => {
    mockRpc.mockImplementation(() => reply(check()));
    renderDialogs();

    fireEvent.click(screen.getByRole('button', { name: 'Accrue Commission' }));
    await choosePolicy('POL-001');
    await screen.findByText(/Will accrue/i);

    // The only fields are the policy and the reason. There is no amount field on
    // the server, so there must not be one here either.
    const inputs = Array.from(document.querySelectorAll('input, textarea'))
      .map((el) => (el as HTMLInputElement).getAttribute('aria-label') ?? el.getAttribute('name') ?? '');
    expect(inputs.some((n) => /amount/i.test(n))).toBe(false);
    expect(screen.getByLabelText('Why (optional)')).toBeTruthy();
  });

  it('accrues one policy and tells the parent to reload', async () => {
    const onDone = vi.fn();
    mockRpc.mockImplementation((fn: string) => {
      if (fn === 'ins_agent_commission_blocked_reason') return reply(check());
      return reply({ accrued: true, gross_amount: 300000 });
    });
    render(<AccrualDialogs onDone={onDone} policyOptions={POLICY_OPTIONS} />);

    fireEvent.click(screen.getByRole('button', { name: 'Accrue Commission' }));
    await choosePolicy('POL-001');
    await screen.findByText(/Will accrue/i);
    await userEvent.type(screen.getByLabelText('Why (optional)'), 'backfilling the book');
    await userEvent.click(screen.getByRole('button', { name: 'Accrue' }));

    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith(
      'ins_agent_commission_accrue_manual',
      { p_policy_id: 'p1', p_reason: 'backfilling the book' },
    ));
    expect(await screen.findByText(/^Accrued (USh|UGX)/)).toBeTruthy();
    expect(onDone).toHaveBeenCalled();
  });

  it('reports a refusal that arrives at the moment of accruing', async () => {
    mockRpc.mockImplementation((fn: string) => {
      if (fn === 'ins_agent_commission_blocked_reason') return reply(check());
      return reply({ accrued: false, reason: 'the policy was reversed while this dialog was open' });
    });
    renderDialogs();

    fireEvent.click(screen.getByRole('button', { name: 'Accrue Commission' }));
    await choosePolicy('POL-001');
    await screen.findByText(/Will accrue/i);
    await userEvent.click(screen.getByRole('button', { name: 'Accrue' }));

    expect(await screen.findByText(/the policy was reversed while this dialog was open/i)).toBeTruthy();
  });

  it('previews a period before running it, and cannot run until it has', async () => {
    mockRpc.mockImplementation(() => reply(preview()));
    renderDialogs();

    await userEvent.click(screen.getByRole('button', { name: 'Run Accruals' }));
    const runButton = screen.getByRole('button', { name: /Accrue 0/ }) as HTMLButtonElement;
    expect(runButton.disabled).toBe(true);

    await userEvent.click(screen.getByRole('button', { name: /Check what would be accrued/i }));

    expect(await screen.findByText(/1 policy is ready/i)).toBeTruthy();
    expect(screen.getByText(/POL-001/)).toBeTruthy();
    await waitFor(() => expect(
      (screen.getByRole('button', { name: /Accrue 1/ }) as HTMLButtonElement).disabled,
    ).toBe(false));
  });

  it('lists what cannot be accrued with the reason, rather than hiding it', async () => {
    mockRpc.mockImplementation(() => reply(preview({
      eligible: [], eligible_count: 0,
      blocked: [{ policy_id: 'p2', policy_no: 'POL-002', inception_date: '2026-11-05', currency: 'UGX', code: 'INS_AGENT_NOT_RECOGNISED', reason: 'the brokerage\'s own commission on POL-002 has not been recognised yet' }],
      blocked_count: 1,
      by_currency: [],
    })));
    renderDialogs();

    await userEvent.click(screen.getByRole('button', { name: 'Run Accruals' }));
    await userEvent.click(screen.getByRole('button', { name: /Check what would be accrued/i }));

    expect(await screen.findByText(/Nothing is ready to accrue/i)).toBeTruthy();
    expect(screen.getByText(/^Cannot be accrued$/)).toBeTruthy();
    expect(screen.getAllByText(/POL-002/).length).toBeGreaterThan(0);
    expect(screen.getByText(/has not been recognised yet/i)).toBeTruthy();
    // Nothing eligible means nothing to run, so the action stays out of reach.
    expect((screen.getByRole('button', { name: /Accrue 0/ }) as HTMLButtonElement).disabled).toBe(true);
  });

  it('says how a run went, including what failed', async () => {
    mockRpc.mockImplementation((fn: string) => {
      if (fn === 'ins_agent_commission_accrual_preview') return reply(preview());
      return reply(runResult({
        accrued: 2, skipped: 1, failed: 1,
        failures: [{ policy_no: 'POL-009', error: 'INS_POSTING_RULE_MISSING' }],
      }));
    });
    renderDialogs();

    await userEvent.click(screen.getByRole('button', { name: 'Run Accruals' }));
    await userEvent.click(screen.getByRole('button', { name: /Check what would be accrued/i }));
    await screen.findByText(/1 policy is ready/i);
    await userEvent.click(screen.getByRole('button', { name: /Accrue 1/ }));

    expect(await screen.findByText(/Accrued 2, skipped 1, and 1 could not be accrued/i)).toBeTruthy();
    expect(screen.getByText(/POL-009: INS_POSTING_RULE_MISSING/)).toBeTruthy();
  });

  it('will not run a period that ends before it starts', async () => {
    renderDialogs();

    await userEvent.click(screen.getByRole('button', { name: 'Run Accruals' }));
    const from = screen.getByLabelText('From');
    const to = screen.getByLabelText('To');
    await userEvent.clear(from);
    await userEvent.type(from, '2026-11-30');
    await userEvent.clear(to);
    await userEvent.type(to, '2026-11-01');
    await userEvent.click(screen.getByRole('button', { name: /Check what would be accrued/i }));

    expect(await screen.findByText(/cannot be before its start/i)).toBeTruthy();
    expect(mockRpc).not.toHaveBeenCalledWith('ins_agent_commission_accrual_preview', expect.anything());
  });
});
