import { fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi, type Mock } from 'vitest';
import ParametersPanel from './ParametersPanel';
import type { ApprovalAssignment, ParamDefinition, RegulatoryParameter } from '../../../regulatory';

// Regulatory values: a value is proposed as a draft, then approved by an assigned approver who is
// not the proposer. Approved values can only be end-dated or retired; a draft can be edited or
// withdrawn. The panel checks drafts before saving and every approve/end/retire goes through an
// RPC. A refused write keeps its dialog open and reports the server's message.
// RegulatoryRules.test.tsx exercises this panel through its parent; these tests cover the panel
// directly: filters, the missing-rules prompt, editing a draft, history, the approve/retire
// dialogs and the error paths.

const mockFrom = vi.fn();
const mockRpc = vi.fn();
vi.mock('../../../../../../lib/supabaseClient', () => ({
  supabase: { from: (...a: unknown[]) => mockFrom(...a), rpc: (...a: unknown[]) => mockRpc(...a) },
}));

const TODAY = '2026-11-22';
const ME = 'u-me';
const MAKER = 'u-maker';

const defs: ParamDefinition[] = [
  { key: 'remittance.deadline_working_days', category: 'remittance', description: 'Working days to remit premium.', value_type: 'days', class_scoped: false },
  { key: 'levy.training_percent', category: 'levy', description: 'Training levy.', value_type: 'percent', class_scoped: true },
  { key: 'stamp_duty.policy', category: 'stamp_duty', description: 'Stamp duty on a policy.', value_type: 'amount', class_scoped: true },
];
const defByKey = new Map(defs.map((d) => [d.key, d]));
const people = [{ id: ME, name: 'Me', email: 'me@x.test' }, { id: MAKER, name: 'Maker', email: 'maker@x.test' }];

const param = (over: Partial<RegulatoryParameter> = {}): RegulatoryParameter => ({
  id: 'p1', tenant_id: 't1', parameter_key: 'remittance.deadline_working_days', applies_to: null, value_num: 1, value_text: null, currency: null,
  effective_from: '2026-01-01', effective_to: null, source_ref: 'UNVERIFIED: Act s.90', status: 'draft', created_by: MAKER, created_at: '2026-10-01T00:00:00Z',
  approved_by: null, approved_at: null, retired_reason: null, ...over,
});
const assignment = (over: Partial<ApprovalAssignment> = {}): ApprovalAssignment => ({
  id: 'a1', user_id: ME, scope: 'category', scope_value: 'remittance', responsibility: 'Quarterly IRA return', effective_from: '2026-01-01', effective_to: null,
  assigned_by: 'admin', assigned_at: '2026-01-01T00:00:00Z', withdrawn_at: null, withdrawn_by: null, withdrawn_reason: null, ...over,
});

let inserts: unknown[];
let updates: unknown[];
let updateEqs: unknown[][];
let events: Array<{ id: string; parameter_id: string; event: string; actor: string | null; detail: string | null; created_at: string }>;
let eventCalls: Array<[string, unknown[]]>;
let eventsError: { message: string } | null;
let onChanged: Mock<() => Promise<void>>;
let onError: Mock<(message: string | null) => void>;

function writeChain() {
  const c: Record<string, unknown> = {};
  c.eq = vi.fn((...a: unknown[]) => { updateEqs.push(a); return c; });
  (c as { then: unknown }).then = (resolve: (v: unknown) => void) => resolve({ data: null, error: null });
  return c;
}

beforeEach(() => {
  vi.clearAllMocks();
  inserts = [];
  updates = [];
  updateEqs = [];
  events = [];
  eventCalls = [];
  eventsError = null;
  onChanged = vi.fn(async () => {});
  onError = vi.fn();
  mockRpc.mockResolvedValue({ data: {}, error: null });
  mockFrom.mockImplementation((name: string) => {
    if (name === 'regulatory_parameters') {
      return {
        insert: vi.fn((v: unknown) => { inserts.push(v); return writeChain(); }),
        update: vi.fn((v: unknown) => { updates.push(v); return writeChain(); }),
      };
    }
    if (name === 'regulatory_parameter_events') {
      const chain: Record<string, unknown> = {};
      for (const m of ['select', 'eq', 'order']) chain[m] = vi.fn((...a: unknown[]) => { eventCalls.push([m, a]); return chain; });
      (chain as { then: unknown }).then = (resolve: (v: unknown) => void) => resolve({ data: eventsError ? null : events, error: eventsError });
      return chain;
    }
    throw new Error(`unexpected table ${name}`);
  });
});

type Over = Partial<{
  params: RegulatoryParameter[]; assignments: ApprovalAssignment[]; userId: string | null; tenantId: string | null; canDraft: boolean; isCompanyAdmin: boolean;
}>;
function renderPanel(over: Over = {}) {
  return render(
    <ParametersPanel
      defs={defs} defByKey={defByKey} params={over.params ?? []} assignments={over.assignments ?? []} people={people}
      userId={'userId' in over ? over.userId! : ME} tenantId={'tenantId' in over ? over.tenantId! : 't1'}
      canDraft={over.canDraft ?? true} isCompanyAdmin={over.isCompanyAdmin ?? false} today={TODAY} onChanged={onChanged} onError={onError}
    />,
  );
}
const rowOf = (text: string) => screen.getAllByRole('row').find((r) => r.textContent?.includes(text)) as HTMLElement;
const dialog = () => screen.findByRole('dialog');
const pick = async (user: ReturnType<typeof userEvent.setup>, label: string | RegExp, option: string | RegExp) => {
  await user.click(screen.getByLabelText(label));
  await user.click(await screen.findByRole('option', { name: option }));
};

describe('ParametersPanel: list', () => {
  const three = () => [
    param({ id: 'p1', status: 'draft' }),
    param({ id: 'p2', parameter_key: 'levy.training_percent', value_num: 10, status: 'approved', source_ref: 'IRA circular 4/2026', approved_by: ME }),
    param({ id: 'p3', parameter_key: 'stamp_duty.policy', value_num: 35000, currency: 'UGX', status: 'retired', retired_reason: 'Superseded by a new circular' }),
  ];

  it('filters by status and by category, and says when nothing matches', async () => {
    const user = userEvent.setup();
    renderPanel({ params: three() });
    expect(screen.getAllByRole('row')).toHaveLength(4); // header + 3
    await pick(user, 'Status', 'Approved');
    expect(screen.getAllByRole('row')).toHaveLength(2);
    expect(rowOf('levy.training_percent')).toBeTruthy();

    await pick(user, 'Status', 'All');
    await pick(user, 'Category', 'stamp_duty');
    expect(screen.getAllByRole('row')).toHaveLength(2);
    expect(rowOf('stamp_duty.policy')).toBeTruthy(); // the chip above the table also names this rule, so look in the table

    await pick(user, 'Status', 'Approved'); // approved AND stamp_duty: none
    expect(screen.getByText('No values match.')).toBeTruthy();
  });

  it('shows the value as people read it, the period, the status and who proposed and approved it', () => {
    renderPanel({ params: three() });
    expect(within(rowOf('levy.training_percent')).getByText('10%')).toBeTruthy();
    expect(within(rowOf('levy.training_percent')).getByText('Approved')).toBeTruthy();
    expect(rowOf('levy.training_percent').textContent).toContain('2026-01-01 to open');
    expect(rowOf('levy.training_percent').textContent).toContain('Proposed by Maker, approved by Me');
    expect(within(rowOf('remittance.deadline_working_days')).getByText('1 day')).toBeTruthy();
    expect(within(rowOf('remittance.deadline_working_days')).getByText('Draft, awaiting approval')).toBeTruthy();
    expect(within(rowOf('stamp_duty.policy')).getByText('Retired')).toBeTruthy();
    expect(within(rowOf('stamp_duty.policy')).getByText('Superseded by a new circular')).toBeTruthy();
  });

  it('flags an unverified source, and only an unverified one', () => {
    renderPanel({ params: three() });
    expect(within(rowOf('remittance.deadline_working_days')).getByText('Unverified')).toBeTruthy();
    expect(within(rowOf('levy.training_percent')).queryByText('Unverified')).toBeNull();
  });

  it('shows "Unknown user" when the proposer is not in the list of people', () => {
    renderPanel({ params: [param({ created_by: 'someone-gone' })] });
    expect(rowOf('remittance.deadline_working_days').textContent).toContain('Proposed by Unknown user');
  });
});

describe('ParametersPanel: rules with no approved value', () => {
  it('counts them, and drops a rule once an approved value is in force today', () => {
    renderPanel({ params: [param({ id: 'p2', parameter_key: 'levy.training_percent', status: 'approved', value_num: 10 })] });
    expect(screen.getByText(/2 rules have no approved value today/)).toBeTruthy();
    expect(screen.queryByText('levy.training_percent', { selector: '.MuiChip-label' })).toBeNull();
  });

  it('uses the singular for one rule, and a future-dated approval does not count as in force', () => {
    renderPanel({ params: [
      param({ id: 'p2', parameter_key: 'levy.training_percent', status: 'approved' }),
      param({ id: 'p3', parameter_key: 'stamp_duty.policy', status: 'approved', value_num: 1, currency: 'UGX', effective_from: '2027-01-01' }),
    ] });
    expect(screen.getByText(/2 rules have no approved value today/)).toBeTruthy();
    expect(screen.getByText('stamp_duty.policy', { selector: '.MuiChip-label' })).toBeTruthy();
  });

  it('lets a drafter start a proposal for a rule from its chip, with that rule filled in', async () => {
    const user = userEvent.setup();
    renderPanel();
    expect(screen.getByText('Select a rule to propose a value for it.')).toBeTruthy();
    await user.click(screen.getByText('levy.training_percent', { selector: '.MuiChip-label' }));
    const d = await dialog();
    expect(within(d).getByText('Propose a value')).toBeTruthy();
    expect(within(d).getByLabelText(/^Rule/).textContent).toBe('levy.training_percent');
    expect((within(d).getByLabelText(/^Starts/) as HTMLInputElement).value).toBe(TODAY);
  });

  it('shows someone who may not draft the list but no way to propose', async () => {
    const user = userEvent.setup();
    renderPanel({ canDraft: false });
    expect(screen.queryByText('Select a rule to propose a value for it.')).toBeNull();
    expect(screen.queryByRole('button', { name: 'New value' })).toBeNull();
    await user.click(screen.getByText('levy.training_percent', { selector: '.MuiChip-label' }));
    expect(screen.queryByRole('dialog')).toBeNull();
  });
});

describe('ParametersPanel: proposing and editing', () => {
  it('will not save a new value when it cannot tell which company it belongs to', async () => {
    const user = userEvent.setup();
    renderPanel({ tenantId: null });
    await user.click(screen.getByRole('button', { name: 'New value' }));
    await pick(user, /^Rule/, 'remittance.deadline_working_days');
    await user.type(screen.getByLabelText(/^Value/), '3');
    await user.type(screen.getByLabelText(/^Source/), 'UNVERIFIED: Act s.90');
    await user.click(within(await dialog()).getByRole('button', { name: 'Save draft' }));
    await waitFor(() => expect(onError).toHaveBeenCalledWith('Could not tell which company you are working in. Reload the page and try again.'));
    expect(inserts).toEqual([]);
    expect(screen.getByRole('dialog')).toBeTruthy();
  });

  it('offers Edit on a draft to a drafter only', () => {
    const { unmount } = renderPanel({ params: [param()] });
    expect(screen.getByRole('button', { name: 'Edit' })).toBeTruthy();
    unmount();
    renderPanel({ params: [param()], canDraft: false });
    expect(screen.queryByRole('button', { name: 'Edit' })).toBeNull();
  });

  it('does not offer Edit on an approved value', () => {
    renderPanel({ params: [param({ status: 'approved' })] });
    expect(screen.queryByRole('button', { name: 'Edit' })).toBeNull();
  });

  it('edits a draft in place: the rule is locked, and the update leaves the rule key out', async () => {
    const user = userEvent.setup();
    renderPanel({ params: [param()] });
    await user.click(screen.getByRole('button', { name: 'Edit' }));
    const d = await dialog();
    expect(within(d).getByText('Edit draft')).toBeTruthy();
    expect(within(d).getByLabelText(/^Rule/).getAttribute('aria-disabled')).toBe('true');
    const value = within(d).getByLabelText(/^Value/) as HTMLInputElement;
    expect(value.value).toBe('1');
    await user.clear(value);
    await user.type(value, '3');
    await user.click(within(d).getByRole('button', { name: 'Save changes' }));
    await waitFor(() => expect(updates).toHaveLength(1));
    expect(updates[0]).toEqual({
      applies_to: null, value_num: 3, value_text: null, currency: null, effective_from: '2026-01-01', effective_to: null, source_ref: 'UNVERIFIED: Act s.90',
    });
    expect(updateEqs).toEqual([['id', 'p1']]);
    expect(inserts).toEqual([]);
    await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull());
    expect(onChanged).toHaveBeenCalledTimes(1);
  });

  it('checks an edit before saving it', async () => {
    const user = userEvent.setup();
    renderPanel({ params: [param()] });
    await user.click(screen.getByRole('button', { name: 'Edit' }));
    const d = await dialog();
    await user.clear(within(d).getByLabelText(/^Source/));
    await user.click(within(d).getByRole('button', { name: 'Save changes' }));
    expect(within(d).getByText(/Say where the value comes from/)).toBeTruthy();
    expect(updates).toEqual([]);
    expect(screen.getByRole('dialog')).toBeTruthy();
  });
});

describe('ParametersPanel: approving', () => {
  const approvable = () => ({ params: [param()], assignments: [assignment()] });

  it('warns that an unverified source needs confirming, and approves through the RPC', async () => {
    const user = userEvent.setup();
    renderPanel(approvable());
    await user.click(screen.getByRole('button', { name: 'Approve' }));
    const d = await dialog();
    expect(within(d).getByText('Approve this value?')).toBeTruthy();
    expect(within(d).getByText(/The source is marked UNVERIFIED/)).toBeTruthy();
    expect(within(d).getByText(/cannot be edited/)).toBeTruthy();
    await user.click(within(d).getByRole('button', { name: 'Approve' }));
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('reg_approve_parameter', { p_id: 'p1' }));
    await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull());
    expect(onChanged).toHaveBeenCalledTimes(1);
  });

  it('shows no unverified warning for a confirmed source', async () => {
    const user = userEvent.setup();
    renderPanel({ params: [param({ source_ref: 'Insurance Act s.90, confirmed by the accountant 2026-11-01' })], assignments: [assignment()] });
    await user.click(screen.getByRole('button', { name: 'Approve' }));
    expect(within(await dialog()).queryByText(/UNVERIFIED/)).toBeNull();
  });

  it('keeps the dialog open and reports the server\'s message when approval is refused', async () => {
    const user = userEvent.setup();
    mockRpc.mockResolvedValueOnce({ data: null, error: { message: 'REG_NOT_APPROVER: You are not an assigned approver' } });
    renderPanel(approvable());
    await user.click(screen.getByRole('button', { name: 'Approve' }));
    await user.click(within(await dialog()).getByRole('button', { name: 'Approve' }));
    await waitFor(() => expect(onError).toHaveBeenCalledWith('You are not an assigned approver'));
    expect(screen.getByRole('dialog')).toBeTruthy();
    expect(onChanged).not.toHaveBeenCalled();
  });

  it('shows Saving and disables the button while the approval is in flight, so it is sent once', async () => {
    const user = userEvent.setup();
    let release: (v: unknown) => void = () => {};
    mockRpc.mockImplementationOnce(() => new Promise((resolve) => { release = resolve; }));
    renderPanel(approvable());
    await user.click(screen.getByRole('button', { name: 'Approve' }));
    await user.click(within(await dialog()).getByRole('button', { name: 'Approve' }));
    const busy = await within(screen.getByRole('dialog')).findByRole('button', { name: 'Saving…' });
    expect((busy as HTMLButtonElement).disabled).toBe(true);
    release({ data: {}, error: null });
    await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull());
    expect(mockRpc).toHaveBeenCalledTimes(1);
  });
});

describe('ParametersPanel: withdrawing and retiring', () => {
  it('withdraws a draft with a reason of at least five characters, trimmed', async () => {
    const user = userEvent.setup();
    renderPanel({ params: [param({ created_by: ME })], userId: ME });
    await user.click(screen.getByRole('button', { name: 'Withdraw' }));
    const d = await dialog();
    expect(within(d).getByText('Withdraw this draft')).toBeTruthy();
    expect(within(d).queryByText(/cannot be brought back/)).toBeNull(); // that is for approved values
    const confirm = within(d).getByRole('button', { name: 'Withdraw' }) as HTMLButtonElement;
    expect(confirm.disabled).toBe(true);
    await user.type(within(d).getByLabelText(/^Reason/), ' abc ');
    expect(confirm.disabled).toBe(true);
    await user.type(within(d).getByLabelText(/^Reason/), 'defg ');
    await user.click(confirm);
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('reg_retire_parameter', { p_id: 'p1', p_reason: 'abc defg' }));
  });

  it('does not offer Withdraw on someone else\'s draft to a person who is not a company admin', () => {
    renderPanel({ params: [param({ created_by: MAKER })], userId: ME, isCompanyAdmin: false });
    expect(screen.queryByRole('button', { name: 'Withdraw' })).toBeNull();
  });

  it('retires an approved value after warning that it cannot be brought back', async () => {
    const user = userEvent.setup();
    renderPanel({ params: [param({ status: 'approved', source_ref: 'IRA circular 4/2026' })], isCompanyAdmin: true });
    await user.click(screen.getByRole('button', { name: 'Retire' }));
    const d = await dialog();
    expect(within(d).getByText('Retire this value')).toBeTruthy();
    expect(within(d).getByText(/cannot be brought back/)).toBeTruthy();
    await user.type(within(d).getByLabelText(/^Reason/), 'Superseded by new circular');
    await user.click(within(d).getByRole('button', { name: 'Retire' }));
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('reg_retire_parameter', { p_id: 'p1', p_reason: 'Superseded by new circular' }));
    expect(onChanged).toHaveBeenCalledTimes(1);
  });

  it('end-dates an approved value only to a date that shortens it', async () => {
    const user = userEvent.setup();
    renderPanel({ params: [param({ status: 'approved', effective_to: '2027-06-30', source_ref: 'IRA circular 4/2026' })], isCompanyAdmin: true });
    await user.click(screen.getByRole('button', { name: 'End-date' }));
    const d = await dialog();
    const confirm = within(d).getByRole('button', { name: 'End-date' }) as HTMLButtonElement;
    expect(confirm.disabled).toBe(true); // no date yet
    fireEvent.change(within(d).getByLabelText('Ends before'), { target: { value: '2027-09-01' } });
    expect(within(d).getByText(/must be earlier than the current end date \(2027-06-30\)/)).toBeTruthy();
    expect(confirm.disabled).toBe(true);
    fireEvent.change(within(d).getByLabelText('Ends before'), { target: { value: '2026-12-31' } });
    expect(confirm.disabled).toBe(false);
    await user.click(confirm);
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('reg_end_parameter', { p_id: 'p1', p_effective_to: '2026-12-31' }));
  });
});

describe('ParametersPanel: history', () => {
  it('shows who proposed the value and each later event, oldest first', async () => {
    const user = userEvent.setup();
    events = [
      { id: 'e1', parameter_id: 'p1', event: 'approved', actor: ME, detail: 'Confirmed with the accountant', created_at: '2026-10-05T08:00:00Z' },
      { id: 'e2', parameter_id: 'p1', event: 'end-dated', actor: null, detail: null, created_at: '2026-10-09T08:00:00Z' },
    ];
    renderPanel({ params: [param()] });
    await user.click(screen.getByRole('button', { name: 'History' }));
    const d = await dialog();
    expect(within(d).getByText('History: remittance.deadline_working_days')).toBeTruthy();
    expect(within(d).getByText('Proposed by Maker')).toBeTruthy();
    expect(within(d).getByText('UNVERIFIED: Act s.90')).toBeTruthy();
    expect(within(d).getByText('approved by Me')).toBeTruthy();
    expect(within(d).getByText('Confirmed with the accountant')).toBeTruthy();
    expect(within(d).getByText('end-dated by -')).toBeTruthy(); // no actor recorded
    expect(eventCalls).toEqual(expect.arrayContaining([['eq', ['parameter_id', 'p1']], ['order', ['created_at', { ascending: true }]]]));
  });

  it('says so when nothing has happened since the proposal', async () => {
    const user = userEvent.setup();
    renderPanel({ params: [param()] });
    await user.click(screen.getByRole('button', { name: 'History' }));
    expect(await within(await dialog()).findByText('Nothing has happened to this value since it was proposed.')).toBeTruthy();
  });

  it('reports a failure to load the history and does not open an empty dialog', async () => {
    const user = userEvent.setup();
    eventsError = { message: 'permission denied for table regulatory_parameter_events' };
    renderPanel({ params: [param()] });
    await user.click(screen.getByRole('button', { name: 'History' }));
    await waitFor(() => expect(onError).toHaveBeenCalledWith('permission denied for table regulatory_parameter_events'));
    expect(screen.queryByRole('dialog')).toBeNull();
  });
});
