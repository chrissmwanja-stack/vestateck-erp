import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import AgentCommissionTerms from './AgentCommissionTerms';

// Terms panel: every write goes through an RPC (never a table write), the person who entered a
// draft never sees Approve on it, members get a read-only list, and a refusal from the server is
// shown without its error code.

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

const term = (over: Record<string, unknown>) => ({
  id: 't1', intermediary_id: 'i1', basis: 'pct_of_broker_commission', rate_pct: 30, fixed_amount: null,
  tier_from_amount: null, tier_to_amount: null, product_line_id: null, currency: 'UGX',
  effective_from: '2026-01-01', effective_to: null, source_ref: null, status: 'draft',
  entered_by: 'u-other', approved_by: null, approved_at: null, withdrawn_reason: null,
  created_at: '2026-11-01T00:00:00Z', ...over,
});

let data: Record<string, unknown[]>;
const builder = (out: unknown[]) => {
  const b: Record<string, unknown> = {};
  b.select = () => b; b.order = () => b;
  b.then = (res: (v: unknown) => unknown) => Promise.resolve({ data: out, error: null }).then(res);
  return b;
};

beforeEach(() => {
  mockFrom.mockReset(); mockRpc.mockReset(); mockGetUser.mockReset(); mockAccess.mockReset();
  mockAccess.mockReturnValue({ loading: false, canManage: true });
  mockGetUser.mockResolvedValue({ data: { user: { id: 'u-me' } } });
  mockRpc.mockResolvedValue({ data: {}, error: null });
  data = {
    ins_intermediary_terms: [term({})],
    ins_intermediaries: [
      { id: 'i1', name: 'Sample Agent', category: 'sub_agent' },
      { id: 'i2', name: 'Co Broker Ltd', category: 'independent_broker' },
    ],
    ins_product_lines: [{ id: 'pl1', name: 'Motor' }],
    app_users: [{ id: 'u-other', name: 'Other Manager', email: 'o@x.com' }, { id: 'u-me', name: 'Me', email: 'me@x.com' }],
  };
  mockFrom.mockImplementation((t: string) => builder(data[t] ?? []));
});

describe('AgentCommissionTerms', () => {
  it('lists the term with agent, arrangement, who entered it and its status', async () => {
    render(<AgentCommissionTerms />);
    expect(await screen.findByText('Sample Agent')).toBeInTheDocument();
    expect(screen.getByText('30% of brokerage commission')).toBeInTheDocument();
    expect(screen.getByText('Other Manager')).toBeInTheDocument();
    expect(screen.getByText('Draft')).toBeInTheDocument();
    expect(screen.getByText('All product lines')).toBeInTheDocument();
  });

  it("offers Approve on another person's draft and calls the approve RPC", async () => {
    render(<AgentCommissionTerms />);
    await userEvent.click(await screen.findByRole('button', { name: 'Approve' }));
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('ins_approve_intermediary_term', { p_id: 't1' }));
    expect(await screen.findByText('Term approved.')).toBeInTheDocument();
  });

  it('hides Approve on a draft the signed-in user entered', async () => {
    data.ins_intermediary_terms = [term({ entered_by: 'u-me' })];
    render(<AgentCommissionTerms />);
    await screen.findByText('Sample Agent');
    expect(screen.queryByRole('button', { name: 'Approve' })).not.toBeInTheDocument();
  });

  it('gives members a read-only list', async () => {
    mockAccess.mockReturnValue({ loading: false, canManage: false });
    render(<AgentCommissionTerms />);
    await screen.findByText('Sample Agent');
    expect(screen.queryByRole('button', { name: 'Approve' })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'New term' })).not.toBeInTheDocument();
  });

  it('shows End term on an approved open-ended term and sends the chosen date', async () => {
    data.ins_intermediary_terms = [term({ status: 'approved', approved_by: 'u-other', approved_at: '2026-02-01T00:00:00Z' })];
    render(<AgentCommissionTerms />);
    await userEvent.click(await screen.findByRole('button', { name: 'End term' }));
    const dialog = await screen.findByRole('dialog');
    await userEvent.click(within(dialog).getByRole('button', { name: 'End term' }));
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('ins_end_intermediary_term', expect.objectContaining({ p_id: 't1' })));
  });

  it('does not offer a co-broker when entering a term, and saves a draft through the RPC', async () => {
    render(<AgentCommissionTerms />);
    await userEvent.click(await screen.findByRole('button', { name: 'New term' }));
    await userEvent.click(screen.getByLabelText('Intermediary'));
    expect(screen.queryByRole('option', { name: 'Co Broker Ltd' })).not.toBeInTheDocument();
    await userEvent.click(await screen.findByRole('option', { name: 'Sample Agent' }));
    await userEvent.click(screen.getByLabelText('Arrangement'));
    await userEvent.click(await screen.findByRole('option', { name: '% of brokerage commission' }));
    await userEvent.type(screen.getByLabelText('Percentage'), '25');
    await userEvent.click(screen.getByRole('button', { name: 'Save as draft' }));
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('ins_set_intermediary_term', expect.objectContaining({
      p_intermediary_id: 'i1', p_basis: 'pct_of_broker_commission', p_rate_pct: 25, p_fixed_amount: null, p_product_line_id: null,
    })));
  });

  it('blocks a save with no percentage and does not call the RPC', async () => {
    render(<AgentCommissionTerms />);
    await userEvent.click(await screen.findByRole('button', { name: 'New term' }));
    await userEvent.click(screen.getByLabelText('Intermediary'));
    await userEvent.click(await screen.findByRole('option', { name: 'Sample Agent' }));
    await userEvent.click(screen.getByLabelText('Arrangement'));
    await userEvent.click(await screen.findByRole('option', { name: '% of brokerage commission' }));
    await userEvent.click(screen.getByRole('button', { name: 'Save as draft' }));
    expect(await screen.findByText(/percentage between 0 and 100/i)).toBeInTheDocument();
    expect(mockRpc).not.toHaveBeenCalled();
  });

  it('shows a server refusal without its error code', async () => {
    mockRpc.mockResolvedValue({ data: null, error: { message: 'INS_AGENT_TERM_SELF_APPROVAL: the person who entered a term cannot approve it' } });
    render(<AgentCommissionTerms />);
    await userEvent.click(await screen.findByRole('button', { name: 'Approve' }));
    expect(await screen.findByText(/cannot approve it/i)).toBeInTheDocument();
    expect(screen.queryByText(/INS_AGENT_TERM_SELF_APPROVAL/)).not.toBeInTheDocument();
  });
});
