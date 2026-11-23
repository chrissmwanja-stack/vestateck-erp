import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi, type Mock } from 'vitest';
import StatutoryChargesPanel from './StatutoryChargesPanel';
import { formatMoney } from '../../logic';
import type { FinancialDetails, PolicyCharge, StatutoryChargeFields } from '../../financialConfiguration';

// Statutory charges on one policy: levies and taxes collected for a third party.
// The panel reads ins_policy_financial_details once, lists only catalogue-priced lines, and offers
// two actions on a draft: price the charges and acknowledge them. Both go through RPCs, then the
// panel reloads and tells the policy page to reload. In "required" mode a policy cannot bind
// until the charges are priced AND acknowledged, and a re-price after acknowledging voids the
// acknowledgement, so the panel says exactly that. Where the database alone can know whether
// anything is owed (priced_count 0), the panel stays silent rather than show a usually-wrong warning.

const mockRpc = vi.fn();
vi.mock('../../../../../lib/supabaseClient', () => ({ supabase: { rpc: (...a: unknown[]) => mockRpc(...a) } }));

type Line = PolicyCharge & StatutoryChargeFields;
const line = (over: Partial<Line>): Line => ({
  id: 'c1', kind: 'insurer_pass_through', description: 'Training levy', amount: 5_000, recipient_mode: 'all_insurers', recipient_insurer_id: null,
  vat_mode: 'not_calculated', vat_rate_pct: null, income_gl_account_id: null, reviewed: true,
  catalogue_id: 'cat-1', charge_class: 'training_levy', catalogue_version: 3, recipient_name: 'IRA', ...over,
});
const TRAINING = line({});
const STAMP = line({ id: 'c2', description: 'Stamp duty', amount: 30_000, charge_class: 'stamp_duty', catalogue_id: 'cat-2', catalogue_version: 1, recipient_name: 'URA' });
const MANUAL_FEE = line({ id: 'c3', kind: 'broker_fee', description: 'Brokerage fee', amount: 90_000, catalogue_id: null, charge_class: null, recipient_name: null, catalogue_version: null });

type Statutory = NonNullable<FinancialDetails['statutory']>;
const statutory = (over: Partial<Statutory> = {}): Statutory => ({
  ack: null, acknowledged: false, acknowledged_total: null, priced_total: 35_000, priced_count: 2, enforcement: 'required', ...over,
});
const details = (over: Partial<FinancialDetails> = {}): FinancialDetails => ({
  policy_id: 'p1', policy_no: 'POL-1', status: 'draft', currency: 'UGX', gross_premium: 1_000_000, shares: [], charges: [TRAINING, STAMP, MANUAL_FEE],
  snapshot: null, can_configure: true, client_name: 'Acme', statutory: statutory(), enforcement: null, ...over,
});

let current: FinancialDetails | null;
let loadError: { message: string } | null;
let applyResult: unknown;
let onChanged: Mock<() => Promise<void>>;

beforeEach(() => {
  vi.clearAllMocks();
  current = details();
  loadError = null;
  applyResult = { total: 35_000, lines: [{}, {}] };
  onChanged = vi.fn(async () => {});
  mockRpc.mockImplementation(async (fn: string) => {
    if (fn === 'ins_policy_financial_details') return loadError ? { data: null, error: loadError } : { data: current, error: null };
    if (fn === 'ins_apply_statutory_charges') return { data: applyResult, error: null };
    if (fn === 'ins_acknowledge_statutory_charges') {
      if (current?.statutory) current = { ...current, statutory: { ...current.statutory, acknowledged: true, acknowledged_total: current.statutory.priced_total } };
      return { data: {}, error: null };
    }
    throw new Error(`unexpected rpc ${fn}`);
  });
});

const renderPanel = (props: { dirty?: boolean } = {}) => render(<StatutoryChargesPanel policyId="p1" onChanged={onChanged} {...props} />);
const detailCalls = () => mockRpc.mock.calls.filter((c) => c[0] === 'ins_policy_financial_details').length;
const priceBtn = () => screen.getByRole('button', { name: 'Price statutory charges' }) as HTMLButtonElement;
const ackBtn = () => screen.getByRole('button', { name: 'Acknowledge' }) as HTMLButtonElement;
const rowOf = (text: string) => screen.getAllByRole('row').find((r) => r.textContent?.includes(text)) as HTMLElement;

describe('StatutoryChargesPanel: loading and visibility', () => {
  it('reads the policy financial details for this policy, once', async () => {
    renderPanel();
    await screen.findByText('Statutory charges');
    expect(mockRpc).toHaveBeenCalledWith('ins_policy_financial_details', { p_policy_id: 'p1' });
    expect(detailCalls()).toBe(1);
  });

  it('shows the error when the details cannot be loaded, and offers no actions', async () => {
    loadError = { message: 'INS_ACCESS_DENIED: Not allowed' };
    renderPanel();
    expect(await screen.findByText('Not allowed')).toBeTruthy();
    expect(screen.queryByRole('button')).toBeNull();
  });

  it('renders nothing when the response is empty', async () => {
    current = null;
    const { container } = renderPanel();
    await waitFor(() => expect(detailCalls()).toBe(1));
    expect(container.textContent).toBe('');
  });

  it('hides itself for a bound, advisory policy with nothing priced', async () => {
    current = details({ status: 'active', charges: [MANUAL_FEE], statutory: statutory({ priced_total: 0, priced_count: 0, enforcement: 'advisory' }) });
    const { container } = renderPanel();
    await waitFor(() => expect(detailCalls()).toBe(1));
    expect(container.textContent).toBe('');
  });

  it('still shows on a draft with nothing priced, so charges can be priced', async () => {
    current = details({ charges: [], statutory: statutory({ priced_total: 0, priced_count: 0, enforcement: 'advisory' }) });
    renderPanel();
    expect(await screen.findByText('No statutory charges priced for this policy.')).toBeTruthy();
    expect(screen.getByText('Not priced')).toBeTruthy();
    expect(priceBtn().disabled).toBe(false);
    expect(ackBtn().disabled).toBe(true); // nothing to acknowledge
  });

  it('shows on a bound policy when enforcement is required, without action buttons', async () => {
    current = details({ status: 'active', charges: [], statutory: statutory({ priced_total: 0, priced_count: 0, acknowledged: false }) });
    renderPanel();
    expect(await screen.findByText('Statutory charges')).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Price statutory charges' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Acknowledge' })).toBeNull();
  });
});

describe('StatutoryChargesPanel: what it shows', () => {
  it('lists only the catalogue-priced lines, with class, recipient, version and the amount in the policy currency', async () => {
    current = details({ currency: 'USD' });
    renderPanel();
    await screen.findByText('Training levy');
    expect(screen.queryByText('Brokerage fee')).toBeNull(); // a manual fee is not a statutory charge
    expect(rowOf('Training levy').textContent).toContain('training levy');
    expect(rowOf('Training levy').textContent).toContain('IRA');
    expect(rowOf('Training levy').textContent).toContain('3');
    expect(rowOf('Training levy').textContent).toContain(formatMoney(5_000, 'USD'));
    expect(rowOf('Stamp duty').textContent).toContain('stamp duty');
    expect(rowOf('Stamp duty').textContent).toContain('URA');
    expect(rowOf('Stamp duty').textContent).toContain(formatMoney(30_000, 'USD'));
  });

  it('shows a dash for a missing recipient or version', async () => {
    current = details({ charges: [line({ recipient_name: null, catalogue_version: null })] });
    renderPanel();
    await screen.findByText('Training levy');
    expect(rowOf('Training levy').textContent?.match(/—/g)).toHaveLength(2);
  });

  it('explains enforcement: on means a bind needs the charges, advisory means it does not', async () => {
    renderPanel();
    expect(await screen.findByText('Enforcement on')).toBeTruthy();
    expect(screen.getByText(/requires them to be priced and acknowledged before a policy can bind/)).toBeTruthy();
  });

  it('says advisory when the company does not enforce, and notes there is no refusal', async () => {
    current = details({ statutory: statutory({ enforcement: 'advisory' }) });
    renderPanel();
    expect(await screen.findByText('Advisory')).toBeTruthy();
    expect(screen.getByText(/does not refuse a bind for want of them/)).toBeTruthy();
  });

  it('falls back to the top-level enforcement from a response that has no statutory block', async () => {
    current = details({ statutory: null, enforcement: 'required' });
    renderPanel();
    expect(await screen.findByText('Enforcement on')).toBeTruthy();
    expect(screen.getByText('Not priced')).toBeTruthy();
  });

  it.each([
    ['acknowledged', statutory({ acknowledged: true, acknowledged_total: 35_000 }), 'Acknowledged'],
    ['priced but not acknowledged', statutory(), 'Not acknowledged'],
    ['nothing priced', statutory({ priced_total: 0, priced_count: 0 }), 'Not priced'],
  ])('status chip: %s', async (_n, s, label) => {
    current = details({ statutory: s });
    renderPanel();
    expect(await screen.findByText(label)).toBeTruthy();
  });

  it('shows the billed total, and the acknowledged total only when it differs', async () => {
    current = details({ statutory: statutory({ acknowledged: true, acknowledged_total: 30_000 }) });
    const { unmount } = renderPanel();
    await screen.findByText(/Total billed:/);
    const norm = (t: string | null) => (t ?? '').replace(/\s+/g, ' ');
    expect(screen.getByText((_, el) => el?.tagName === 'P' && norm(el.textContent).includes(`· acknowledged ${norm(formatMoney(30_000, 'UGX'))}`))).toBeTruthy();
    unmount();

    current = details({ statutory: statutory({ acknowledged: true, acknowledged_total: 35_000 }) });
    renderPanel();
    await screen.findByText(/Total billed:/);
    expect(screen.queryByText(/· acknowledged/)).toBeNull();
  });
});

describe('StatutoryChargesPanel: what blocks a bind', () => {
  it('warns that priced charges are not acknowledged when enforcement is on', async () => {
    renderPanel();
    expect(await screen.findByText('Statutory charges are priced but not acknowledged. Acknowledge them before binding.')).toBeTruthy();
  });

  it('warns when the charges changed after they were acknowledged', async () => {
    current = details({ statutory: statutory({ acknowledged: true, acknowledged_total: 30_000 }) });
    renderPanel();
    expect(await screen.findByText('The statutory charges changed after they were acknowledged. Acknowledge them again before binding.')).toBeTruthy();
  });

  it('stays silent when nothing is priced, because only the database knows whether anything is owed', async () => {
    current = details({ charges: [], statutory: statutory({ priced_total: 0, priced_count: 0 }) });
    renderPanel();
    await screen.findByText('Not priced');
    expect(screen.queryByText(/before binding/)).toBeNull();
  });

  it('has no warning when enforcement is advisory', async () => {
    current = details({ statutory: statutory({ enforcement: 'advisory' }) });
    renderPanel();
    await screen.findByText('Advisory');
    expect(screen.queryByText(/before binding/)).toBeNull();
  });

  it('has no warning once everything is acknowledged at the current prices', async () => {
    current = details({ statutory: statutory({ acknowledged: true, acknowledged_total: 35_000 }) });
    renderPanel();
    await screen.findByText('Acknowledged');
    expect(screen.queryByText(/before binding/)).toBeNull();
  });
});

describe('StatutoryChargesPanel: actions', () => {
  it('offers the actions only on a draft', async () => {
    current = details({ status: 'approved' });
    renderPanel();
    await screen.findByText('Training levy');
    expect(screen.queryByRole('button', { name: 'Price statutory charges' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Acknowledge' })).toBeNull();
  });

  it('while the configuration has unsaved edits, says to save first and disables both actions', async () => {
    renderPanel({ dirty: true });
    expect(await screen.findByText(/Save the financial configuration first/)).toBeTruthy();
    expect(priceBtn().disabled).toBe(true);
    expect(ackBtn().disabled).toBe(true);
  });

  it('prices the charges, reports the result, reloads and tells the policy page', async () => {
    const user = userEvent.setup();
    renderPanel();
    await user.click(await screen.findByRole('button', { name: 'Price statutory charges' }));
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('ins_apply_statutory_charges', { p_policy_id: 'p1' }));
    expect(await screen.findByText('Priced 2 charge(s) totalling 35000')).toBeTruthy();
    expect(detailCalls()).toBe(2);
    expect(onChanged).toHaveBeenCalledTimes(1);
  });

  it('says just "Priced." when the RPC returns nothing', async () => {
    const user = userEvent.setup();
    applyResult = null;
    renderPanel();
    await user.click(await screen.findByRole('button', { name: 'Price statutory charges' }));
    expect(await screen.findByText('Priced.')).toBeTruthy();
  });

  it('acknowledges through the RPC and then shows the charges as acknowledged', async () => {
    const user = userEvent.setup();
    renderPanel();
    await screen.findByText('Not acknowledged');
    await user.click(ackBtn());
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('ins_acknowledge_statutory_charges', { p_policy_id: 'p1' }));
    expect(await screen.findByText('Acknowledged.')).toBeTruthy(); // the confirmation message
    await waitFor(() => expect(screen.queryByText('Not acknowledged')).toBeNull());
    expect(screen.queryByText(/before binding/)).toBeNull();
    expect(onChanged).toHaveBeenCalledTimes(1);
  });

  it('shows the server message, keeps the figures and does not tell the policy page when an action is refused', async () => {
    const user = userEvent.setup();
    mockRpc.mockImplementation(async (fn: string) => {
      if (fn === 'ins_policy_financial_details') return { data: current, error: null };
      return { data: null, error: { message: 'INS_ACCESS_DENIED: Only a manager can price statutory charges' } };
    });
    renderPanel();
    await user.click(await screen.findByRole('button', { name: 'Price statutory charges' }));
    expect(await screen.findByText('Only a manager can price statutory charges')).toBeTruthy();
    expect(screen.queryByText(/^Priced/)).toBeNull();
    expect(onChanged).not.toHaveBeenCalled();
    expect(screen.getByText('Training levy')).toBeTruthy();
    await waitFor(() => expect(priceBtn().disabled).toBe(false)); // can retry
  });

  it('disables both actions while one is running, so it runs once', async () => {
    const user = userEvent.setup();
    let release: (v: unknown) => void = () => {};
    mockRpc.mockImplementation((fn: string) => {
      if (fn === 'ins_policy_financial_details') return Promise.resolve({ data: current, error: null });
      return new Promise((resolve) => { release = resolve; });
    });
    renderPanel();
    await user.click(await screen.findByRole('button', { name: 'Price statutory charges' }));
    await waitFor(() => expect(priceBtn().disabled).toBe(true));
    expect(ackBtn().disabled).toBe(true);
    release({ data: applyResult, error: null });
    await waitFor(() => expect(priceBtn().disabled).toBe(false));
    expect(mockRpc.mock.calls.filter((c) => c[0] === 'ins_apply_statutory_charges')).toHaveLength(1);
  });
});
