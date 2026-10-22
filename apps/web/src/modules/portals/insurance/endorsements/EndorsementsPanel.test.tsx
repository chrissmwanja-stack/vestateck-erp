// The endorsements panel: proposes through the RPC wrappers, lists the
// policy's endorsements, withdraws live ones, and gates the Finance
// maker/checker controls behind the finance-team membership check.
import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import EndorsementsPanel from './EndorsementsPanel';

const mockFrom = vi.fn();
const mockRpc = vi.fn();

vi.mock('../../../../lib/supabaseClient', () => ({
  supabase: {
    from: (...args: unknown[]) => mockFrom(...args),
    rpc: (...args: unknown[]) => mockRpc(...args),
  },
}));

vi.mock('jspdf', () => ({ jsPDF: vi.fn() }));

function builder(result: () => { data: unknown; error: { message: string } | null }) {
  const chain: Record<string, unknown> = {};
  for (const m of ['select', 'eq', 'order', 'limit']) chain[m] = vi.fn(() => chain);
  (chain as { then: unknown }).then = (resolve: (v: unknown) => void) => resolve(result());
  return chain;
}

let endorsements: Record<string, unknown>[] = [];
let glAccounts: Record<string, unknown>[] = [];

beforeEach(() => {
  endorsements = [];
  glAccounts = [{ id: 'gl-1', account_code: '2010', name: 'Premium clearing' }];
  mockFrom.mockReset();
  mockFrom.mockImplementation((t: string) => {
    if (t === 'ins_policy_endorsements') return builder(() => ({ data: endorsements, error: null }));
    if (t === 'gl_accounts') return builder(() => ({ data: glAccounts, error: null }));
    return builder(() => ({ data: [], error: null }));
  });
  mockRpc.mockReset();
  mockRpc.mockImplementation((fn: string) => {
    if (fn === 'ins_endorsement_review_position') {
      return Promise.resolve({ data: {
        policy_id: 'pol-1',
        policy_no: 'POL-1',
        currency: 'UGX',
        bound_gross_premium: 1200000,
        bound_commission_amount: 120000,
        current_gross_premium: 1200000,
        current_commission_amount: 120000,
        current_sum_insured: 100000000,
        posted_endorsements: 0,
        live_endorsements: [],
        cancellation_in_flight: false,
      }, error: null });
    }
    if (fn === 'is_finance_team_member') return Promise.resolve({ data: true, error: null });
    throw new Error(`unexpected rpc ${fn}`);
  });
  vi.stubGlobal('crypto', { randomUUID: () => 'req-key-1' });
});

function renderPanel(props: Partial<{ canManage: boolean; policyActive: boolean }> = {}) {
  return render(<EndorsementsPanel policyId="pol-1" canManage={props.canManage ?? true} policyActive={props.policyActive ?? true} />);
}

describe('EndorsementsPanel', () => {
  it('shows the empty state and the position line', async () => {
    renderPanel();
    expect(await screen.findByText(/no endorsements on this policy/i)).toBeTruthy();
    expect(screen.getByText(/current premium UGX 1,200,000.00/i)).toBeTruthy();
  });

  it('hides the Endorse button when the policy is not active/renewed', async () => {
    renderPanel({ policyActive: false });
    await screen.findByText(/no endorsements on this policy/i);
    expect(screen.queryByRole('button', { name: 'Endorse' })).toBeNull();
  });

  it('proposes an endorsement with a request key and reloads the list', async () => {
    mockRpc.mockImplementation((fn: string) => {
      if (fn === 'ins_endorsement_review_position') {
        return Promise.resolve({ data: {
          policy_id: 'pol-1', policy_no: 'POL-1', currency: 'UGX', bound_gross_premium: 1200000,
          bound_commission_amount: 120000, current_gross_premium: 1200000, current_commission_amount: 120000,
          current_sum_insured: 100000000, posted_endorsements: 0, live_endorsements: [], cancellation_in_flight: false,
        }, error: null });
      }
      if (fn === 'is_finance_team_member') return Promise.resolve({ data: false, error: null });
      if (fn === 'ins_propose_policy_endorsement') {
        return Promise.resolve({ data: { id: 'e-1', endorsement_no: 'END-0001-0001', status: 'proposed' }, error: null });
      }
      throw new Error(`unexpected rpc ${fn}`);
    });
    renderPanel();
    fireEvent.click(await screen.findByRole('button', { name: 'Endorse' }));
    const reason = await screen.findByLabelText(/reason \(at least 5 characters\)/i);
    fireEvent.change(reason, { target: { value: 'Client asked for a sum insured increase' } });
    fireEvent.click(screen.getByRole('button', { name: 'Propose' }));
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('ins_propose_policy_endorsement', expect.objectContaining({
      p_policy_id: 'pol-1', p_request_key: 'req-key-1',
    })));
    expect(await screen.findByText(/finance will prepare and decide/i)).toBeTruthy();
  });

  it('renders listed endorsements with status chips and deltas', async () => {
    endorsements = [{
      id: 'e-1', endorsement_no: 'END-0001-0001', status: 'posted', effective_date: '2026-10-01',
      reason: 'Sum insured increase', proposed_by: 'u1', proposed_at: '2026-10-01T09:00:00Z', prepared_by: null,
      calculation: { premium_delta: 240000, commission_delta: 24000, currency: 'UGX' }, review_note: null,
      credit_note_ids: [],
    }];
    renderPanel({ canManage: false });
    expect(await screen.findByText('END-0001-0001')).toBeTruthy();
    expect(screen.getByText('posted')).toBeTruthy();
    expect(screen.getByText(/240,000\.00/)).toBeTruthy();
    // read-only viewer: no withdraw / finance controls
    expect(screen.queryByRole('button', { name: 'Withdraw' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Prepare' })).toBeNull();
  });

  it('offers withdraw on a live endorsement and calls the RPC with a reason', async () => {
    endorsements = [{
      id: 'e-2', endorsement_no: null, status: 'proposed', effective_date: '2026-10-21', reason: 'Mistake in the delta',
      proposed_by: 'u1', proposed_at: '2026-10-21T09:00:00Z', prepared_by: null, calculation: null, review_note: null,
      credit_note_ids: [],
    }];
    mockRpc.mockImplementation((fn: string) => {
      if (fn === 'ins_endorsement_review_position') return Promise.resolve({ data: null, error: null });
      if (fn === 'is_finance_team_member') return Promise.resolve({ data: false, error: null });
      if (fn === 'ins_withdraw_policy_endorsement') return Promise.resolve({ data: null, error: null });
      throw new Error(`unexpected rpc ${fn}`);
    });
    renderPanel();
    fireEvent.click(await screen.findByRole('button', { name: 'Withdraw' }));
    const reason = await screen.findByLabelText(/reason \(at least 5 characters\)/i);
    fireEvent.change(reason, { target: { value: 'Wrong delta entered' } });
    fireEvent.click(screen.getByRole('button', { name: 'Withdraw' }));
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('ins_withdraw_policy_endorsement', {
      p_endorsement_id: 'e-2', p_reason: 'Wrong delta entered',
    }));
    expect(await screen.findByText(/withdrawn/i)).toBeTruthy();
  });

  it('shows Finance prepare and review controls only for finance members', async () => {
    endorsements = [{
      id: 'e-3', endorsement_no: null, status: 'proposed', effective_date: '2026-10-21', reason: 'Increase cover',
      proposed_by: 'u1', proposed_at: '2026-10-21T09:00:00Z', prepared_by: null, calculation: null, review_note: null,
      credit_note_ids: [],
    }];
    const first = renderPanel(); // is_finance_team_member -> true from beforeEach
    await screen.findByRole('button', { name: 'Prepare' });
    expect(screen.getByRole('button', { name: 'Review' })).toBeTruthy();
    first.unmount();

    // non-finance manager: no finance controls
    mockRpc.mockImplementation((fn: string) => {
      if (fn === 'ins_endorsement_review_position') return Promise.resolve({ data: null, error: null });
      if (fn === 'is_finance_team_member') return Promise.resolve({ data: false, error: null });
      throw new Error(`unexpected rpc ${fn}`);
    });
    renderPanel();
    await screen.findByText('Increase cover');
    await waitFor(() => expect(screen.queryByRole('button', { name: 'Prepare' })).toBeNull());
  });

  it('surfaces server refusals in the error banner', async () => {
    mockRpc.mockImplementation((fn: string) => {
      if (fn === 'ins_endorsement_review_position') return Promise.resolve({ data: null, error: null });
      if (fn === 'is_finance_team_member') return Promise.resolve({ data: false, error: null });
      if (fn === 'ins_propose_policy_endorsement') return Promise.resolve({ data: null, error: { message: 'INS_ENDORSEMENT_CURRENCY refused' } });
      throw new Error(`unexpected rpc ${fn}`);
    });
    renderPanel();
    fireEvent.click(await screen.findByRole('button', { name: 'Endorse' }));
    const reason = await screen.findByLabelText(/reason \(at least 5 characters\)/i);
    fireEvent.change(reason, { target: { value: 'Foreign currency attempt' } });
    fireEvent.click(screen.getByRole('button', { name: 'Propose' }));
    expect(await screen.findByText(/INS_ENDORSEMENT_CURRENCY/)).toBeTruthy();
  });
});
