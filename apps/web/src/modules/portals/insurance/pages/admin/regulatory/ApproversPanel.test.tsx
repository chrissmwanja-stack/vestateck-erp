import { fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi, type Mock } from 'vitest';
import ApproversPanel from './ApproversPanel';
import type { ApprovalAssignment, ParamDefinition } from '../../../regulatory';

// Approver assignments: who may approve which regulatory rule. A company admin assigns and
// withdraws; everyone else gets a read-only view. The form is checked before the RPC, a blank
// end date means open-ended, and a refused write keeps the dialog open with the server's message.
// RegulatoryRules.test.tsx exercises this panel through its parent; these tests cover the panel
// directly, including the states and error paths that screen test does not reach.

const mockRpc = vi.fn();
vi.mock('../../../../../../lib/supabaseClient', () => ({ supabase: { rpc: (...a: unknown[]) => mockRpc(...a) } }));

const TODAY = '2026-11-22';
const defs: ParamDefinition[] = [
  { key: 'remittance.deadline_working_days', category: 'remittance', description: 'Working days to remit premium.', value_type: 'days', class_scoped: false },
  { key: 'levy.training_percent', category: 'levy', description: 'Training levy.', value_type: 'percent', class_scoped: true },
  { key: 'levy.ira_percent', category: 'levy', description: 'IRA levy.', value_type: 'percent', class_scoped: true },
  { key: 'stamp_duty.policy', category: 'stamp_duty', description: 'Stamp duty on a policy.', value_type: 'amount', class_scoped: true },
];
const people = [
  { id: 'u1', name: 'Amina', email: 'amina@x.test' },
  { id: 'u2', name: '', email: 'ben@x.test' },
];
const assignment = (over: Partial<ApprovalAssignment> = {}): ApprovalAssignment => ({
  id: 'a1', user_id: 'u1', scope: 'category', scope_value: 'remittance', responsibility: 'Quarterly IRA return', effective_from: '2026-01-01', effective_to: null,
  assigned_by: 'admin', assigned_at: '2026-01-01T00:00:00Z', withdrawn_at: null, withdrawn_by: null, withdrawn_reason: null, ...over,
});

let onChanged: Mock<() => Promise<void>>;
let onError: Mock<(message: string | null) => void>;

beforeEach(() => {
  vi.clearAllMocks();
  onChanged = vi.fn(async () => {});
  onError = vi.fn();
  mockRpc.mockResolvedValue({ data: {}, error: null });
});

function renderPanel(assignments: ApprovalAssignment[] = [], isCompanyAdmin = true) {
  return render(<ApproversPanel defs={defs} assignments={assignments} people={people} isCompanyAdmin={isCompanyAdmin} today={TODAY} onChanged={onChanged} onError={onError} />);
}
const rowOf = (text: string) => screen.getAllByRole('row').find((r) => r.textContent?.includes(text)) as HTMLElement;
const dialog = () => screen.findByRole('dialog');
const pick = async (user: ReturnType<typeof userEvent.setup>, label: string | RegExp, option: string | RegExp) => {
  await user.click(screen.getByLabelText(label));
  await user.click(await screen.findByRole('option', { name: option }));
};

describe('ApproversPanel: display', () => {
  it('gives a non-admin a read-only view with an explanation', () => {
    renderPanel([assignment()], false);
    expect(screen.getByText(/Only a company admin can assign or withdraw approvers/)).toBeTruthy();
    expect(screen.queryByRole('button', { name: /Assign approver/ })).toBeNull();
    expect(screen.queryByRole('columnheader', { name: 'Action' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Withdraw' })).toBeNull();
  });

  it('gives a company admin the assign and withdraw controls', () => {
    renderPanel([assignment()], true);
    expect(screen.queryByText(/Only a company admin can assign/)).toBeNull();
    expect(screen.getByRole('button', { name: /Assign approver/ })).toBeTruthy();
    expect(screen.getByRole('columnheader', { name: 'Action' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Withdraw' })).toBeTruthy();
  });

  it('says that nobody can approve until someone is assigned', () => {
    renderPanel([]);
    expect(screen.getByText('No approvers assigned yet. Until someone is assigned, no value can be approved.')).toBeTruthy();
  });

  it('shows who, what they cover, the responsibility and the period, with name, email and unknown-user fallbacks', () => {
    renderPanel([
      assignment({ id: 'a1', user_id: 'u1' }),
      assignment({ id: 'a2', user_id: 'u2', scope: 'key', scope_value: 'levy.ira_percent', responsibility: 'Levy return', effective_to: '2027-03-31' }),
      assignment({ id: 'a3', user_id: 'gone', scope_value: 'levy', responsibility: 'Old duty' }),
    ]);
    expect(within(rowOf('Quarterly IRA return')).getByText('Amina')).toBeTruthy();
    expect(within(rowOf('Quarterly IRA return')).getByText('Whole category')).toBeTruthy();
    expect(rowOf('Quarterly IRA return').textContent).toContain('2026-01-01 to open');
    expect(within(rowOf('Levy return')).getByText('ben@x.test')).toBeTruthy(); // no name: email
    expect(within(rowOf('Levy return')).getByText('One rule')).toBeTruthy();
    expect(within(rowOf('Levy return')).getByText('levy.ira_percent')).toBeTruthy();
    expect(rowOf('Levy return').textContent).toContain('2026-01-01 to 2027-03-31');
    expect(within(rowOf('Old duty')).getByText('Unknown user')).toBeTruthy();
  });

  it('shows each assignment\'s state against today, and the reason for a withdrawal', () => {
    renderPanel([
      assignment({ id: 'a1', responsibility: 'In force one' }),
      assignment({ id: 'a2', responsibility: 'Future one', effective_from: '2027-01-01' }),
      assignment({ id: 'a3', responsibility: 'Past one', effective_to: '2026-06-30' }),
      assignment({ id: 'a4', responsibility: 'Withdrawn one', withdrawn_at: '2026-09-01T00:00:00Z', withdrawn_reason: 'Left the company' }),
    ]);
    expect(within(rowOf('In force one')).getByText('In force')).toBeTruthy();
    expect(within(rowOf('Future one')).getByText('Starts later')).toBeTruthy();
    expect(within(rowOf('Past one')).getByText('Ended')).toBeTruthy();
    expect(within(rowOf('Withdrawn one')).getByText('Withdrawn')).toBeTruthy();
    expect(within(rowOf('Withdrawn one')).getByText('Left the company')).toBeTruthy();
    // Only a live assignment can be withdrawn again.
    expect(within(rowOf('Withdrawn one')).queryByRole('button', { name: 'Withdraw' })).toBeNull();
    expect(within(rowOf('In force one')).getByRole('button', { name: 'Withdraw' })).toBeTruthy();
  });
});

describe('ApproversPanel: assigning', () => {
  it('starts today, covers a whole category, and offers each category once, in order', async () => {
    const user = userEvent.setup();
    renderPanel();
    await user.click(screen.getByRole('button', { name: /Assign approver/ }));
    const d = await dialog();
    expect((within(d).getByLabelText('From') as HTMLInputElement).value).toBe(TODAY);
    expect(within(d).getByLabelText('Covers').textContent).toBe('A whole category');
    await user.click(within(d).getByLabelText(/^Category/));
    const options = (await screen.findAllByRole('option')).map((o) => o.textContent);
    expect(options).toEqual(['levy', 'remittance', 'stamp_duty']);
  });

  it('switching to One rule lists the rules and clears a category already chosen', async () => {
    const user = userEvent.setup();
    renderPanel();
    await user.click(screen.getByRole('button', { name: /Assign approver/ }));
    await pick(user, /^Category/, 'levy');
    await pick(user, 'Covers', 'One rule');
    expect(screen.getByLabelText(/^Rule/).textContent).not.toContain('levy'); // value cleared
    await user.click(screen.getByLabelText(/^Rule/));
    const options = (await screen.findAllByRole('option')).map((o) => o.textContent);
    expect(options).toEqual(defs.map((d) => d.key));
  });

  it('shows every problem at once and writes nothing when the form is incomplete', async () => {
    const user = userEvent.setup();
    renderPanel();
    await user.click(screen.getByRole('button', { name: /Assign approver/ }));
    const d = await dialog();
    await user.click(within(d).getByRole('button', { name: 'Assign' }));
    expect(within(d).getByText('Choose who will approve.')).toBeTruthy();
    expect(within(d).getByText('Choose the category.')).toBeTruthy();
    expect(within(d).getByText(/State the responsibility this approval covers/)).toBeTruthy();
    expect(mockRpc).not.toHaveBeenCalled();
  });

  it('rejects an end date before the start date', async () => {
    const user = userEvent.setup();
    renderPanel();
    await user.click(screen.getByRole('button', { name: /Assign approver/ }));
    const d = await dialog();
    fireEvent.change(within(d).getByLabelText('To (optional)'), { target: { value: '2026-01-01' } });
    await user.click(within(d).getByRole('button', { name: 'Assign' }));
    expect(within(d).getByText('The end date cannot be before the start date.')).toBeTruthy();
    expect(mockRpc).not.toHaveBeenCalled();
  });

  it('assigns through the RPC with a trimmed responsibility and an open end, then closes and reloads', async () => {
    const user = userEvent.setup();
    renderPanel();
    await user.click(screen.getByRole('button', { name: /Assign approver/ }));
    await pick(user, /^Approver/, /Amina \(amina@x\.test\)/);
    await pick(user, /^Category/, 'remittance');
    await user.type(screen.getByLabelText(/Responsibility/), '  Quarterly IRA return  ');
    await user.click(within(await dialog()).getByRole('button', { name: 'Assign' }));
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('reg_assign_approver', {
      p_user_id: 'u1', p_scope: 'category', p_scope_value: 'remittance', p_responsibility: 'Quarterly IRA return', p_effective_from: TODAY, p_effective_to: null,
    }));
    await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull());
    expect(onChanged).toHaveBeenCalledTimes(1);
    expect(onError).toHaveBeenCalledWith(null);
  });

  it('assigns one rule with an end date', async () => {
    const user = userEvent.setup();
    renderPanel();
    await user.click(screen.getByRole('button', { name: /Assign approver/ }));
    await pick(user, /^Approver/, /ben@x\.test/);
    await pick(user, 'Covers', 'One rule');
    await pick(user, /^Rule/, 'stamp_duty.policy');
    await user.type(screen.getByLabelText(/Responsibility/), 'Stamp duty return');
    fireEvent.change(screen.getByLabelText('To (optional)'), { target: { value: '2027-06-30' } });
    await user.click(within(await dialog()).getByRole('button', { name: 'Assign' }));
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('reg_assign_approver', {
      p_user_id: 'u2', p_scope: 'key', p_scope_value: 'stamp_duty.policy', p_responsibility: 'Stamp duty return', p_effective_from: TODAY, p_effective_to: '2027-06-30',
    }));
  });

  it('keeps the dialog open and reports the server\'s message when the assignment is refused', async () => {
    const user = userEvent.setup();
    mockRpc.mockResolvedValueOnce({ data: null, error: { message: 'INS_ACCESS_DENIED: Only a company admin can assign approvers' } });
    renderPanel();
    await user.click(screen.getByRole('button', { name: /Assign approver/ }));
    await pick(user, /^Approver/, /Amina/);
    await pick(user, /^Category/, 'levy');
    await user.type(screen.getByLabelText(/Responsibility/), 'Levy return');
    await user.click(within(await dialog()).getByRole('button', { name: 'Assign' }));
    await waitFor(() => expect(onError).toHaveBeenCalledWith('Only a company admin can assign approvers'));
    expect(screen.getByRole('dialog')).toBeTruthy();
    expect(onChanged).not.toHaveBeenCalled();
    await waitFor(() => expect((within(screen.getByRole('dialog')).getByRole('button', { name: 'Assign' }) as HTMLButtonElement).disabled).toBe(false));
  });
});

describe('ApproversPanel: withdrawing', () => {
  const open = async (user: ReturnType<typeof userEvent.setup>) => {
    renderPanel([assignment()]);
    await user.click(screen.getByRole('button', { name: 'Withdraw' }));
    return dialog();
  };

  it('names the person and what they lose, and needs a real reason', async () => {
    const user = userEvent.setup();
    const d = await open(user);
    expect(within(d).getByText(/Amina will no longer be able to approve remittance\./)).toBeTruthy();
    expect(within(d).getByText(/The assignment stays on record\./)).toBeTruthy();
    const confirm = within(d).getByRole('button', { name: 'Withdraw' }) as HTMLButtonElement;
    expect(confirm.disabled).toBe(true);
    await user.type(within(d).getByLabelText(/Reason/), '  abc  ');
    expect(confirm.disabled).toBe(true); // fewer than five characters once trimmed
    await user.type(within(d).getByLabelText(/Reason/), 'de');
    expect(confirm.disabled).toBe(false);
  });

  it('withdraws through the RPC with a trimmed reason, then reloads', async () => {
    const user = userEvent.setup();
    const d = await open(user);
    await user.type(within(d).getByLabelText(/Reason/), '  Left the company  ');
    await user.click(within(d).getByRole('button', { name: 'Withdraw' }));
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('reg_withdraw_approver', { p_assignment_id: 'a1', p_reason: 'Left the company' }));
    await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull());
    expect(onChanged).toHaveBeenCalledTimes(1);
  });

  it('Cancel closes without writing', async () => {
    const user = userEvent.setup();
    const d = await open(user);
    await user.click(within(d).getByRole('button', { name: 'Cancel' }));
    await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull());
    expect(mockRpc).not.toHaveBeenCalled();
  });

  it('keeps the dialog open and reports the message when the withdrawal is refused', async () => {
    const user = userEvent.setup();
    mockRpc.mockResolvedValueOnce({ data: null, error: { message: 'REG_ASSIGNMENT_NOT_FOUND: Assignment not found' } });
    const d = await open(user);
    await user.type(within(d).getByLabelText(/Reason/), 'Left the company');
    await user.click(within(d).getByRole('button', { name: 'Withdraw' }));
    await waitFor(() => expect(onError).toHaveBeenCalledWith('Assignment not found'));
    expect(screen.getByRole('dialog')).toBeTruthy();
    expect(onChanged).not.toHaveBeenCalled();
  });
});
