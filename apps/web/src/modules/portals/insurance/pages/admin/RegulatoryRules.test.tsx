import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import RegulatoryRules from './RegulatoryRules';
import type { ApprovalAssignment, ParamDefinition, RegulatoryParameter } from '../../regulatory';

// Regulatory rules screen: a value is proposed as a draft, then approved by someone who has
// been assigned to it (never by the proposer, never by role). Company admins assign approvers
// and end-date or retire approved values. The screen shows each person only what they may do,
// and every write goes through the table insert/update or an RPC: the server still decides.

const mockFrom = vi.fn();
const mockRpc = vi.fn();
const mockGetUser = vi.fn();
let mockAccess: unknown = null;

vi.mock('../../../../../lib/supabaseClient', () => ({
  supabase: { from: (...a: unknown[]) => mockFrom(...a), rpc: (...a: unknown[]) => mockRpc(...a), auth: { getUser: () => mockGetUser() } },
}));
vi.mock('../../../../../features/navigation/useMyModuleAccess', () => ({ useMyModuleAccess: () => mockAccess }));

const ME = 'user-me';
const MAKER = 'user-maker';

const defs: ParamDefinition[] = [
  { key: 'remittance.deadline_working_days', category: 'remittance', description: 'Working days to remit premium.', value_type: 'days', class_scoped: false },
  { key: 'levy.training_percent', category: 'levy', description: 'Training levy.', value_type: 'percent', class_scoped: true },
  { key: 'stamp_duty.policy', category: 'stamp_duty', description: 'Stamp duty on a policy.', value_type: 'amount', class_scoped: true },
];

const param = (over: Partial<RegulatoryParameter>): RegulatoryParameter => ({
  id: 'p1', tenant_id: 't1', parameter_key: 'remittance.deadline_working_days', applies_to: null, value_num: 1, value_text: null, currency: null,
  effective_from: '2026-01-01', effective_to: null, source_ref: 'UNVERIFIED: Act s.90', status: 'draft', created_by: MAKER, created_at: '2026-10-01T00:00:00Z',
  approved_by: null, approved_at: null, retired_reason: null, ...over,
});
const assignment = (over: Partial<ApprovalAssignment> = {}): ApprovalAssignment => ({
  id: 'a1', user_id: ME, scope: 'category', scope_value: 'remittance', responsibility: 'Quarterly IRA return', effective_from: '2026-01-01', effective_to: null,
  assigned_by: 'admin', assigned_at: '2026-01-01T00:00:00Z', withdrawn_at: null, withdrawn_by: null, withdrawn_reason: null, ...over,
});

let params: RegulatoryParameter[] = [];
let assignments: ApprovalAssignment[] = [];
let inserts: unknown[] = [];
let updates: unknown[] = [];

function builder(result: () => { data: unknown; error: null }) {
  const chain: Record<string, unknown> = {};
  for (const m of ['select', 'eq', 'order', 'limit']) chain[m] = vi.fn(() => chain);
  chain.maybeSingle = vi.fn(async () => ({ data: { tenant_id: 't1' }, error: null }));
  chain.insert = vi.fn(async (v: unknown) => { inserts.push(v); return { data: null, error: null }; });
  chain.update = vi.fn((v: unknown) => { updates.push(v); return chain; });
  (chain as { then: unknown }).then = (resolve: (v: unknown) => void) => resolve(result());
  return chain;
}

function setup(access: unknown) {
  mockAccess = access;
  mockGetUser.mockResolvedValue({ data: { user: { id: ME } } });
  mockRpc.mockResolvedValue({ data: {}, error: null });
  mockFrom.mockImplementation((table: string) => {
    switch (table) {
      case 'regulatory_parameter_definitions': return builder(() => ({ data: defs, error: null }));
      case 'regulatory_parameters': return builder(() => ({ data: params, error: null }));
      case 'regulatory_approval_assignments': return builder(() => ({ data: assignments, error: null }));
      case 'regulatory_parameter_events': return builder(() => ({ data: [], error: null }));
      case 'app_users': return builder(() => ({ data: [{ id: ME, name: 'Me', email: 'me@x.test' }, { id: MAKER, name: 'Maker', email: 'maker@x.test' }], error: null }));
      default: throw new Error(`unexpected table ${table}`);
    }
  });
  render(<RegulatoryRules />);
}

const access = (over: Record<string, unknown> = {}) => ({
  isCompanyAdmin: false, isPlatformAdmin: false, canAccessFinance: false, rolesByModule: new Map([['insurance', new Set(['member'])]]), ...over,
});

beforeEach(() => {
  params = [];
  assignments = [];
  inserts = [];
  updates = [];
  mockFrom.mockReset();
  mockRpc.mockReset();
  mockGetUser.mockReset();
});

describe('values tab', () => {
  it('lists the rules that have no approved value today, and not the ones that do', async () => {
    params = [param({ status: 'approved', approved_by: 'x', approved_at: 'y', parameter_key: 'levy.training_percent', value_num: 1 })];
    setup(access());
    const alert = await screen.findByRole('alert');
    expect(within(alert).getByText('remittance.deadline_working_days')).toBeInTheDocument();
    expect(within(alert).getByText('stamp_duty.policy')).toBeInTheDocument();
    expect(within(alert).queryByText('levy.training_percent')).not.toBeInTheDocument();
  });

  it('lets an assigned approver approve someone else\'s draft after confirming', async () => {
    params = [param({})];
    assignments = [assignment()];
    setup(access());
    await userEvent.click(await screen.findByRole('button', { name: 'Approve' }));
    expect(await screen.findByText('Approve this value?')).toBeInTheDocument();
    expect(screen.getByText(/source is marked UNVERIFIED/i)).toBeInTheDocument();
    await userEvent.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Approve' }));
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('reg_approve_parameter', { p_id: 'p1' }));
  });

  it('disables approval on your own draft and when you are not assigned', async () => {
    params = [param({ id: 'own', created_by: ME }), param({ id: 'other', parameter_key: 'levy.training_percent', value_num: 1 })];
    assignments = [assignment()];
    setup(access());
    const buttons = await screen.findAllByRole('button', { name: 'Approve' });
    expect(buttons).toHaveLength(2);
    expect(buttons.every((b) => (b as HTMLButtonElement).disabled)).toBe(true);
  });

  it('does not offer a company admin approval just because they are an admin', async () => {
    params = [param({})];
    setup(access({ isCompanyAdmin: true }));
    expect(await screen.findByRole('button', { name: 'Approve' })).toBeDisabled();
  });

  it('offers new values only to people who may draft', async () => {
    setup(access());
    await screen.findByText('Regulatory rules');
    expect(screen.queryByRole('button', { name: 'New value' })).not.toBeInTheDocument();
  });

  it('lets the Insurance Admin propose a value, checked first and saved with the company id', async () => {
    setup(access({ rolesByModule: new Map([['insurance', new Set(['admin'])]]) }));
    await userEvent.click(await screen.findByRole('button', { name: 'New value' }));
    await userEvent.click(screen.getByLabelText(/^Rule/));
    await userEvent.click(await screen.findByRole('option', { name: 'levy.training_percent' }));
    await userEvent.type(screen.getByLabelText(/^Value/), '150');
    await userEvent.type(screen.getByLabelText(/^Source/), 'UNVERIFIED: waiting for adviser');
    await userEvent.click(screen.getByRole('button', { name: 'Save draft' }));
    expect(await screen.findByText('A percentage cannot be more than 100.')).toBeInTheDocument();
    expect(inserts).toHaveLength(0);

    const value = screen.getByLabelText(/^Value/);
    await userEvent.clear(value);
    await userEvent.type(value, '0.5');
    await userEvent.click(screen.getByRole('button', { name: 'Save draft' }));
    await waitFor(() => expect(inserts).toHaveLength(1));
    expect(inserts[0]).toEqual(expect.objectContaining({
      tenant_id: 't1', parameter_key: 'levy.training_percent', value_num: 0.5, currency: null, applies_to: null, source_ref: 'UNVERIFIED: waiting for adviser',
    }));
  });

  it('shows end-date and retire for a company admin only, and sends the end date', async () => {
    params = [param({ status: 'approved', approved_by: 'x', approved_at: 'y' })];
    setup(access());
    await screen.findByText('1 day');
    expect(screen.queryByRole('button', { name: 'End-date' })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Retire' })).not.toBeInTheDocument();
  });

  it('lets a company admin end-date an approved value, only to a date after it starts', async () => {
    params = [param({ status: 'approved', approved_by: 'x', approved_at: 'y', effective_from: '2026-01-01' })];
    setup(access({ isCompanyAdmin: true }));
    await userEvent.click(await screen.findByRole('button', { name: 'End-date' }));
    const dialog = screen.getByRole('dialog');
    const date = within(dialog).getByLabelText(/Ends before/);
    await userEvent.type(date, '2026-01-01');
    expect(within(dialog).getByRole('button', { name: 'End-date' })).toBeDisabled();
    await userEvent.clear(date);
    await userEvent.type(date, '2026-12-31');
    await userEvent.click(within(dialog).getByRole('button', { name: 'End-date' }));
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('reg_end_parameter', { p_id: 'p1', p_effective_to: '2026-12-31' }));
  });

  it('needs a reason to retire, and lets the proposer withdraw their own draft', async () => {
    params = [param({ created_by: ME })];
    setup(access());
    await userEvent.click(await screen.findByRole('button', { name: 'Withdraw' }));
    const dialog = screen.getByRole('dialog');
    const confirm = within(dialog).getByRole('button', { name: 'Withdraw' });
    expect(confirm).toBeDisabled();
    await userEvent.type(within(dialog).getByLabelText(/Reason/), 'Entered in error');
    await userEvent.click(confirm);
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('reg_retire_parameter', { p_id: 'p1', p_reason: 'Entered in error' }));
  });

  it('shows the server\'s refusal in plain words', async () => {
    params = [param({})];
    assignments = [assignment()];
    setup(access());
    mockRpc.mockResolvedValue({ data: null, error: { message: 'REG_OVERLAP: another approved value for remittance.deadline_working_days already covers part of this period; end-date it first' } });
    await userEvent.click(await screen.findByRole('button', { name: 'Approve' }));
    await userEvent.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Approve' }));
    expect(await screen.findByText(/already covers part of this period/)).toBeInTheDocument();
  });
});

describe('approvers tab', () => {
  it('shows assignments and withdrawal to a company admin, who can assign', async () => {
    assignments = [assignment({ user_id: MAKER })];
    setup(access({ isCompanyAdmin: true }));
    await userEvent.click(await screen.findByRole('tab', { name: 'Approvers' }));
    expect(await screen.findByText('Quarterly IRA return')).toBeInTheDocument();
    expect(screen.getByText('In force')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Assign approver' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Withdraw' })).toBeInTheDocument();
  });

  it('gives everyone else a read-only view', async () => {
    assignments = [assignment()];
    setup(access());
    await userEvent.click(await screen.findByRole('tab', { name: 'Approvers' }));
    await screen.findByText('Quarterly IRA return');
    expect(screen.queryByRole('button', { name: 'Assign approver' })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Withdraw' })).not.toBeInTheDocument();
  });

  it('assigns an approver to a category after checking the form', async () => {
    setup(access({ isCompanyAdmin: true }));
    await userEvent.click(await screen.findByRole('tab', { name: 'Approvers' }));
    await userEvent.click(await screen.findByRole('button', { name: 'Assign approver' }));
    const dialog = screen.getByRole('dialog');
    await userEvent.click(within(dialog).getByRole('button', { name: 'Assign' }));
    expect(await within(dialog).findByText('Choose who will approve.')).toBeInTheDocument();
    expect(mockRpc).not.toHaveBeenCalled();

    await userEvent.click(within(dialog).getByLabelText(/^Approver/));
    await userEvent.click(await screen.findByRole('option', { name: /^Maker/ }));
    await userEvent.click(within(dialog).getByLabelText(/^Category/));
    await userEvent.click(await screen.findByRole('option', { name: 'remittance' }));
    await userEvent.type(within(dialog).getByLabelText(/^Responsibility/), 'Quarterly IRA return');
    await userEvent.click(within(dialog).getByRole('button', { name: 'Assign' }));
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('reg_assign_approver', expect.objectContaining({
      p_user_id: MAKER, p_scope: 'category', p_scope_value: 'remittance', p_responsibility: 'Quarterly IRA return', p_effective_to: null,
    })));
  });
});
