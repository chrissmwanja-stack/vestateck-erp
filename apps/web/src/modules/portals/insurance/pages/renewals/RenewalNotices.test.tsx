import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import RenewalNotices from './RenewalNotices';

// Renewal notices: generate draft notices for policies in the renewal window, then mark each sent
// on a chosen channel. Only a manager can mark a notice sent. The server RPCs are the enforcement
// point; this screen only reads the table and calls them. Policies are loaded in one query for
// all notices on the page (none when there are no notices).

const mockFrom = vi.fn();
const mockRpc = vi.fn();
vi.mock('../../../../../lib/supabaseClient', () => ({
  supabase: { from: (...a: unknown[]) => mockFrom(...a), rpc: (...a: unknown[]) => mockRpc(...a) },
}));

let mockCanManage = true;
vi.mock('../../access', () => ({ useInsuranceAccess: () => ({ loading: false, canManage: mockCanManage }) }));

type Row = Record<string, unknown>;
let notices: Row[];
let policies: Row[];
let noticesError: { message: string } | null;
let calls: Array<[string, string, unknown[]]>;

const notice = (over: Row = {}): Row => ({
  id: 'n1', notice_no: 'RN-2026-0001', status: 'draft', channel: 'email', sent_at: null, policy_id: 'p1', created_at: '2026-11-01T08:00:00Z', ...over,
});
const policy = (over: Row = {}): Row => ({
  id: 'p1', policy_no: 'POL-001', expiry_date: '2027-01-15', currency: 'UGX', gross_premium: 1_000_000, ins_clients: { bd_clients: { name: 'Acme Traders' } }, ...over,
});

function builder(name: string, getRows: () => Row[], getError: () => { message: string } | null = () => null) {
  const chain: Record<string, unknown> = {};
  for (const m of ['select', 'order', 'in']) chain[m] = vi.fn((...a: unknown[]) => { calls.push([name, m, a]); return chain; });
  (chain as { then: unknown }).then = (resolve: (v: unknown) => void) => {
    const error = getError();
    return resolve({ data: error ? null : getRows(), error });
  };
  return chain;
}

beforeEach(() => {
  vi.clearAllMocks();
  mockCanManage = true;
  notices = [notice()];
  policies = [policy()];
  noticesError = null;
  calls = [];
  mockFrom.mockImplementation((name: string) => {
    if (name === 'ins_renewal_notices') return builder(name, () => notices, () => noticesError);
    if (name === 'ins_policies') return builder(name, () => policies);
    throw new Error(`unexpected table ${name}`);
  });
  mockRpc.mockResolvedValue({ data: {}, error: null });
});

const renderNotices = () =>
  render(
    <MemoryRouter initialEntries={['/insurance/renewals/notices']}>
      <Routes>
        <Route path="/insurance/renewals/notices" element={<RenewalNotices />} />
        <Route path="/insurance/policies/:id" element={<div>POLICY PAGE</div>} />
      </Routes>
    </MemoryRouter>,
  );
const rowOf = (text: string) => screen.getAllByRole('row').find((r) => r.textContent?.includes(text)) as HTMLElement;
const noticeReads = () => mockFrom.mock.calls.filter((c) => c[0] === 'ins_renewal_notices').length;

describe('RenewalNotices: display', () => {
  it('reads the notices newest first, then the policies they refer to, once', async () => {
    notices = [notice({ id: 'n1', policy_id: 'p1' }), notice({ id: 'n2', notice_no: 'RN-2026-0002', policy_id: 'p1' }), notice({ id: 'n3', notice_no: 'RN-2026-0003', policy_id: 'p2' })];
    policies = [policy({ id: 'p1' }), policy({ id: 'p2', policy_no: 'POL-002' })];
    renderNotices();
    await screen.findByText('RN-2026-0001');
    expect(calls).toEqual(expect.arrayContaining([['ins_renewal_notices', 'order', ['created_at', { ascending: false }]]]));
    const inCalls = calls.filter((c) => c[0] === 'ins_policies' && c[1] === 'in');
    expect(inCalls).toHaveLength(1);
    expect(inCalls[0][2]).toEqual(['id', ['p1', 'p2']]); // each policy once
  });

  it('shows the notice with its policy, client, expiry, status, channel and sent date', async () => {
    notices = [notice({ status: 'sent', channel: 'portal', sent_at: '2026-11-05T09:00:00Z' })];
    renderNotices();
    await screen.findByText('RN-2026-0001');
    const row = rowOf('RN-2026-0001');
    expect(within(row).getByText('POL-001')).toBeTruthy();
    expect(within(row).getByText('Acme Traders')).toBeTruthy();
    expect(within(row).getByText('2027-01-15')).toBeTruthy();
    expect(within(row).getByText('sent')).toBeTruthy();
    expect(within(row).getByText('portal')).toBeTruthy();
    expect(within(row).getByText('2026-11-05')).toBeTruthy();
  });

  // DR-46: the business day is Africa/Kampala (UTC+3), so a notice marked sent at 22:30 UTC on the
  // 5th was sent on the 6th, and must show as the 6th.
  it('shows the sent date on the Kampala business day', async () => {
    notices = [notice({ status: 'sent', sent_at: '2026-11-05T22:30:00Z' })];
    renderNotices();
    await screen.findByText('RN-2026-0001');
    expect(within(rowOf('RN-2026-0001')).getByText('2026-11-06')).toBeTruthy();
  });

  it('shows dashes when the policy cannot be read, and for a draft with no sent date', async () => {
    policies = [];
    renderNotices();
    await screen.findByText('RN-2026-0001');
    const row = rowOf('RN-2026-0001');
    expect(within(row).getAllByText('—')).toHaveLength(4); // policy, client, expiry, sent at
    expect(within(row).queryByRole('button', { name: /POL-/ })).toBeNull();
  });

  it('opens the policy from its number', async () => {
    const user = userEvent.setup();
    renderNotices();
    await user.click(await screen.findByRole('button', { name: 'POL-001' }));
    expect(await screen.findByText('POLICY PAGE')).toBeTruthy();
  });

  it('shows the empty state and does not ask for policies when there are no notices', async () => {
    notices = [];
    renderNotices();
    expect(await screen.findByText('No notices yet — generate them for the renewal window.')).toBeTruthy();
    expect(mockFrom.mock.calls.some((c) => c[0] === 'ins_policies')).toBe(false);
  });

  it('shows a load failure', async () => {
    noticesError = { message: 'permission denied for table ins_renewal_notices' };
    renderNotices();
    expect(await screen.findByText('permission denied for table ins_renewal_notices')).toBeTruthy();
  });
});

describe('RenewalNotices: generating', () => {
  it('generates through the RPC and reloads the list', async () => {
    const user = userEvent.setup();
    notices = [];
    renderNotices();
    await screen.findByText(/No notices yet/);
    notices = [notice()];
    await user.click(screen.getByRole('button', { name: 'Generate notices' }));
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('ins_generate_renewal_notices', {}));
    expect(await screen.findByText('RN-2026-0001')).toBeTruthy();
  });

  it('shows Generating and disables the button while it runs, so it runs once', async () => {
    const user = userEvent.setup();
    let release: (v: unknown) => void = () => {};
    mockRpc.mockImplementationOnce(() => new Promise((resolve) => { release = resolve; }));
    renderNotices();
    await user.click(await screen.findByRole('button', { name: 'Generate notices' }));
    const busy = await screen.findByRole('button', { name: 'Generating…' });
    expect((busy as HTMLButtonElement).disabled).toBe(true);
    release({ data: {}, error: null });
    await screen.findByRole('button', { name: 'Generate notices' });
    expect(mockRpc).toHaveBeenCalledTimes(1);
  });

  it('shows the server message when generation is refused, and can be retried', async () => {
    const user = userEvent.setup();
    mockRpc.mockResolvedValueOnce({ data: null, error: { message: 'INS_ACCESS_DENIED: Only a manager can generate renewal notices' } });
    renderNotices();
    await user.click(await screen.findByRole('button', { name: 'Generate notices' }));
    expect(await screen.findByText('Only a manager can generate renewal notices')).toBeTruthy();
    expect((screen.getByRole('button', { name: 'Generate notices' }) as HTMLButtonElement).disabled).toBe(false);
  });
});

describe('RenewalNotices: marking sent', () => {
  it('offers Mark sent on a draft to a manager, and nothing on a sent notice', async () => {
    notices = [notice(), notice({ id: 'n2', notice_no: 'RN-2026-0002', status: 'sent', sent_at: '2026-11-05T09:00:00Z' })];
    renderNotices();
    await screen.findByText('RN-2026-0001');
    expect(within(rowOf('RN-2026-0001')).getByRole('button', { name: 'Mark sent' })).toBeTruthy();
    expect(within(rowOf('RN-2026-0002')).queryByRole('button', { name: 'Mark sent' })).toBeNull();
  });

  it('gives a member the list without any way to mark a notice sent', async () => {
    mockCanManage = false;
    renderNotices();
    await screen.findByText('RN-2026-0001');
    expect(screen.queryByRole('button', { name: 'Mark sent' })).toBeNull();
    expect(screen.queryByLabelText('Channel')).toBeNull();
  });

  it('sends by email unless another channel is chosen, and reloads', async () => {
    const user = userEvent.setup();
    renderNotices();
    await user.click(await screen.findByRole('button', { name: 'Mark sent' }));
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('ins_mark_renewal_notice_sent', { p_notice_id: 'n1', p_channel: 'email' }));
    await waitFor(() => expect(noticeReads()).toBe(2));
  });

  it('sends on the chosen channel', async () => {
    const user = userEvent.setup();
    renderNotices();
    await user.click(await screen.findByLabelText('Channel'));
    await user.click(await screen.findByRole('option', { name: 'Print' }));
    await user.click(screen.getByRole('button', { name: 'Mark sent' }));
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('ins_mark_renewal_notice_sent', { p_notice_id: 'n1', p_channel: 'print' }));
  });

  it('disables only the notice being sent while it is in flight', async () => {
    const user = userEvent.setup();
    notices = [notice(), notice({ id: 'n2', notice_no: 'RN-2026-0002', policy_id: 'p1' })];
    let release: (v: unknown) => void = () => {};
    mockRpc.mockImplementationOnce(() => new Promise((resolve) => { release = resolve; }));
    renderNotices();
    await screen.findByText('RN-2026-0001');
    await user.click(within(rowOf('RN-2026-0001')).getByRole('button', { name: 'Mark sent' }));
    await waitFor(() => expect((within(rowOf('RN-2026-0001')).getByRole('button', { name: 'Mark sent' }) as HTMLButtonElement).disabled).toBe(true));
    expect((within(rowOf('RN-2026-0002')).getByRole('button', { name: 'Mark sent' }) as HTMLButtonElement).disabled).toBe(false);
    release({ data: {}, error: null });
    await waitFor(() => expect((within(rowOf('RN-2026-0001')).getByRole('button', { name: 'Mark sent' }) as HTMLButtonElement).disabled).toBe(false));
    expect(mockRpc).toHaveBeenCalledTimes(1);
  });

  it('shows the server message when marking is refused', async () => {
    const user = userEvent.setup();
    mockRpc.mockResolvedValueOnce({ data: null, error: { message: 'INS_NOTICE_STATE: The notice has already been sent' } });
    renderNotices();
    await user.click(await screen.findByRole('button', { name: 'Mark sent' }));
    expect(await screen.findByText('The notice has already been sent')).toBeTruthy();
  });
});
