import { fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import InsurerStatements from './InsurerStatements';

// Insurer statements: record what an insurer says it owes or paid, reconcile it line by line
// against our premium, commission and claims records, then mark it reconciled or disputed.
// Recording and deciding are manager actions and go through RPCs; anyone can view a
// reconciliation. The statement lines are entered as a JSON array.

const mockFrom = vi.fn();
const mockRpc = vi.fn();
vi.mock('../../../../../lib/supabaseClient', () => ({
  supabase: { from: (...a: unknown[]) => mockFrom(...a), rpc: (...a: unknown[]) => mockRpc(...a) },
}));

let mockCanManage = true;
vi.mock('../../access', () => ({ useInsuranceAccess: () => ({ loading: false, canManage: mockCanManage }) }));

type Row = Record<string, unknown>;
const stmt = (over: Row = {}): Row => ({
  id: 's1', statement_ref: 'STM-001', period_from: '2026-10-01', period_to: '2026-10-31', status: 'received', notes: null, insurer_id: 'i1',
  ins_insurers: { name: 'Jubilee' }, ...over,
});
const insurers = [{ id: 'i1', name: 'Jubilee' }, { id: 'i2', name: 'UAP' }];
const reconLine = (over: Row = {}): Row => ({ line_id: 'l1', policy_id: 'p1', policy_no: 'POL-001', field: 'premium', insurer_amount: 1_000_000, our_amount: 1_000_000, match: true, ...over });

let statements: Row[];
let loadError: { message: string } | null;
let recon: Record<string, Row[]>;

function builder(getRows: () => Row[], getError: () => { message: string } | null = () => null) {
  const chain: Record<string, unknown> = {};
  for (const m of ['select', 'order']) chain[m] = vi.fn(() => chain);
  (chain as { then: unknown }).then = (resolve: (v: unknown) => void) => {
    const error = getError();
    return resolve({ data: error ? null : getRows(), error });
  };
  return chain;
}

beforeEach(() => {
  vi.clearAllMocks();
  mockCanManage = true;
  statements = [stmt()];
  loadError = null;
  recon = { s1: [reconLine()] };
  mockFrom.mockImplementation((name: string) => {
    if (name === 'ins_insurer_statements') return builder(() => statements, () => loadError);
    if (name === 'ins_insurers') return builder(() => insurers);
    throw new Error(`unexpected table ${name}`);
  });
  mockRpc.mockImplementation(async (fn: string, args: Row) => {
    if (fn === 'ins_insurer_statement_reconciliation') return { data: recon[args.p_statement_id as string] ?? [], error: null };
    if (fn === 'ins_decide_insurer_statement') {
      statements = statements.map((s) => (s.id === args.p_statement_id ? { ...s, status: args.p_status } : s));
    }
    return { data: {}, error: null };
  });
});

const renderStatements = () =>
  render(
    <MemoryRouter initialEntries={['/insurance/reports/insurer-statements']}>
      <Routes>
        <Route path="/insurance/reports/insurer-statements" element={<InsurerStatements />} />
        <Route path="/insurance/policies/:id" element={<div>POLICY PAGE</div>} />
      </Routes>
    </MemoryRouter>,
  );
const rowOf = (text: string) => screen.getAllByRole('row').find((r) => r.textContent?.includes(text)) as HTMLElement;
const dialog = () => screen.findByRole('dialog');

describe('InsurerStatements: list', () => {
  it('shows each statement with its insurer, period and status', async () => {
    statements = [stmt(), stmt({ id: 's2', statement_ref: 'STM-002', status: 'reconciled', ins_insurers: null })];
    renderStatements();
    await screen.findByText('STM-001');
    expect(within(rowOf('STM-001')).getByText('Jubilee')).toBeTruthy();
    expect(rowOf('STM-001').textContent).toContain('2026-10-01 → 2026-10-31');
    expect(within(rowOf('STM-001')).getByText('received')).toBeTruthy();
    expect(within(rowOf('STM-002')).getByText('—')).toBeTruthy(); // insurer unknown
    expect(within(rowOf('STM-002')).getByText('reconciled')).toBeTruthy();
  });

  it('shows the empty state', async () => {
    statements = [];
    renderStatements();
    expect(await screen.findByText('No statements recorded yet.')).toBeTruthy();
  });

  it('shows a load failure', async () => {
    loadError = { message: 'permission denied for table ins_insurer_statements' };
    renderStatements();
    expect(await screen.findByText('permission denied for table ins_insurer_statements')).toBeTruthy();
  });

  it('lets a manager record statements and decide on received ones only', async () => {
    statements = [stmt(), stmt({ id: 's2', statement_ref: 'STM-002', status: 'reconciled' }), stmt({ id: 's3', statement_ref: 'STM-003', status: 'disputed' })];
    renderStatements();
    await screen.findByText('STM-001');
    expect(screen.getByRole('button', { name: 'Record statement' })).toBeTruthy();
    expect(within(rowOf('STM-001')).getByRole('button', { name: 'Mark reconciled' })).toBeTruthy();
    expect(within(rowOf('STM-001')).getByRole('button', { name: 'Dispute' })).toBeTruthy();
    for (const ref of ['STM-002', 'STM-003']) {
      expect(within(rowOf(ref)).queryByRole('button', { name: 'Mark reconciled' })).toBeNull();
      expect(within(rowOf(ref)).queryByRole('button', { name: 'Dispute' })).toBeNull();
      expect(within(rowOf(ref)).getByRole('button', { name: 'Reconcile' })).toBeTruthy(); // anyone can still view it
    }
  });

  it('gives a member the list and the reconciliation view, but no way to record or decide', async () => {
    mockCanManage = false;
    renderStatements();
    await screen.findByText('STM-001');
    expect(screen.queryByRole('button', { name: 'Record statement' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Mark reconciled' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Dispute' })).toBeNull();
    expect(screen.getByRole('button', { name: 'Reconcile' })).toBeTruthy();
  });
});

describe('InsurerStatements: reconciliation', () => {
  it('shows each line against our records, flagging a mismatch, and opens the policy', async () => {
    const user = userEvent.setup();
    recon.s1 = [
      reconLine(),
      reconLine({ line_id: 'l2', policy_id: 'p2', policy_no: 'POL-002', field: 'commission', insurer_amount: 150_000, our_amount: 140_000, match: false }),
    ];
    renderStatements();
    await user.click(await screen.findByRole('button', { name: 'Reconcile' }));
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('ins_insurer_statement_reconciliation', { p_statement_id: 's1' }));
    expect(await screen.findByText('Reconciliation')).toBeTruthy();
    expect(within(rowOf('POL-001')).getByText('match')).toBeTruthy();
    const bad = rowOf('POL-002');
    expect(within(bad).getByText('MISMATCH')).toBeTruthy();
    expect(within(bad).getByText('commission')).toBeTruthy();
    expect(within(bad).getByText((150_000).toLocaleString())).toBeTruthy();
    expect(within(bad).getByText((140_000).toLocaleString())).toBeTruthy();
    await user.click(within(bad).getByRole('button', { name: 'POL-002' }));
    expect(await screen.findByText('POLICY PAGE')).toBeTruthy();
  });

  it('says so when a statement has no lines', async () => {
    const user = userEvent.setup();
    recon.s1 = [];
    renderStatements();
    await user.click(await screen.findByRole('button', { name: 'Reconcile' }));
    expect(await screen.findByText('No lines.')).toBeTruthy();
  });

  it('shows the server message when the reconciliation cannot be produced', async () => {
    const user = userEvent.setup();
    mockRpc.mockResolvedValueOnce({ data: null, error: { message: 'INS_NOT_FOUND: Statement not found' } });
    renderStatements();
    await user.click(await screen.findByRole('button', { name: 'Reconcile' }));
    expect(await screen.findByText('Statement not found')).toBeTruthy();
  });

  // If the second statement's reconciliation fails, the card is already titled for the new
  // selection, so it must not still list the FIRST statement's lines under the error.
  it('does not keep showing another statement\'s lines after a reconciliation fails', async () => {
    const user = userEvent.setup();
    statements = [stmt(), stmt({ id: 's2', statement_ref: 'STM-002' })];
    renderStatements();
    await screen.findByText('STM-001');
    await user.click(within(rowOf('STM-001')).getByRole('button', { name: 'Reconcile' }));
    await screen.findByText('POL-001');
    mockRpc.mockResolvedValueOnce({ data: null, error: { message: 'INS_NOT_FOUND: Statement not found' } });
    await user.click(within(rowOf('STM-002')).getByRole('button', { name: 'Reconcile' }));
    await screen.findByText('Statement not found');
    expect(screen.queryByText('POL-001', { selector: 'button' })).toBeNull();
  });
});

describe('InsurerStatements: deciding', () => {
  it.each([
    ['Mark reconciled', 'reconciled'],
    ['Dispute', 'disputed'],
  ])('%s sends %s through the RPC and refreshes the status', async (button, status) => {
    const user = userEvent.setup();
    renderStatements();
    await user.click(await screen.findByRole('button', { name: button }));
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('ins_decide_insurer_statement', { p_statement_id: 's1', p_status: status }));
    expect(await within(rowOf('STM-001')).findByText(status)).toBeTruthy();
    expect(screen.queryByRole('button', { name: button })).toBeNull(); // decided: no longer offered
  });

  it('shows the server message when a decision is refused', async () => {
    const user = userEvent.setup();
    mockRpc.mockResolvedValueOnce({ data: null, error: { message: 'INS_ACCESS_DENIED: Only a manager can decide a statement' } });
    renderStatements();
    await user.click(await screen.findByRole('button', { name: 'Dispute' }));
    expect(await screen.findByText('Only a manager can decide a statement')).toBeTruthy();
    expect(within(rowOf('STM-001')).getByText('received')).toBeTruthy();
  });
});

describe('InsurerStatements: recording', () => {
  const lines = '[{"policy_id":"p1","premium":1000000,"commission":100000,"claims_paid":0}]';
  const fill = async (user: ReturnType<typeof userEvent.setup>, over: { lines?: string } = {}) => {
    const d = await dialog();
    await user.click(within(d).getByLabelText(/^Insurer/));
    await user.click(await screen.findByRole('option', { name: 'UAP' }));
    await user.type(within(d).getByLabelText(/^Statement ref/), 'STM-009');
    fireEvent.change(within(d).getByLabelText('Period from'), { target: { value: '2026-11-01' } });
    fireEvent.change(within(d).getByLabelText('Period to'), { target: { value: '2026-11-30' } });
    fireEvent.change(within(d).getByLabelText(/^Lines/), { target: { value: over.lines ?? lines } });
    return d;
  };
  const saveBtn = (d: HTMLElement) => within(d).getByRole('button', { name: /Save statement|Saving/ }) as HTMLButtonElement;

  it('cannot be saved until every field is filled', async () => {
    const user = userEvent.setup();
    renderStatements();
    await user.click(await screen.findByRole('button', { name: 'Record statement' }));
    const d = await dialog();
    expect(saveBtn(d).disabled).toBe(true);
    await user.click(within(d).getByLabelText(/^Insurer/));
    await user.click(await screen.findByRole('option', { name: 'Jubilee' }));
    await user.type(within(d).getByLabelText(/^Statement ref/), 'STM-009');
    fireEvent.change(within(d).getByLabelText('Period from'), { target: { value: '2026-11-01' } });
    fireEvent.change(within(d).getByLabelText('Period to'), { target: { value: '2026-11-30' } });
    expect(saveBtn(d).disabled).toBe(true); // lines still missing
    fireEvent.change(within(d).getByLabelText(/^Lines/), { target: { value: lines } });
    await waitFor(() => expect(saveBtn(d).disabled).toBe(false));
  });

  it('records the statement through the RPC with the lines parsed, then closes and reloads', async () => {
    const user = userEvent.setup();
    renderStatements();
    await user.click(await screen.findByRole('button', { name: 'Record statement' }));
    const d = await fill(user);
    await user.click(saveBtn(d));
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('ins_record_insurer_statement', {
      p_insurer_id: 'i2', p_statement_ref: 'STM-009', p_period_from: '2026-11-01', p_period_to: '2026-11-30',
      p_lines: [{ policy_id: 'p1', premium: 1_000_000, commission: 100_000, claims_paid: 0 }],
    }));
    await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull());
  });

  it('refuses lines that are not valid JSON, without calling the server, and keeps the dialog', async () => {
    const user = userEvent.setup();
    renderStatements();
    await user.click(await screen.findByRole('button', { name: 'Record statement' }));
    const d = await fill(user, { lines: 'policy p1 premium 1000000' });
    await user.click(saveBtn(d));
    expect((await screen.findAllByText(/The lines are not valid JSON\. Enter an array such as/)).length).toBeGreaterThan(0);
    expect(screen.queryByText(/Unexpected token/)).toBeNull(); // not the browser's raw parse message
    expect(mockRpc).not.toHaveBeenCalled();
    expect(screen.getByRole('dialog')).toBeTruthy();
    expect(saveBtn(screen.getByRole('dialog')).disabled).toBe(false); // can correct and retry
  });

  it('refuses lines that are valid JSON but not an array, without calling the server', async () => {
    const user = userEvent.setup();
    renderStatements();
    await user.click(await screen.findByRole('button', { name: 'Record statement' }));
    const d = await fill(user, { lines: '{"policy_id":"p1","premium":1000000}' });
    await user.click(saveBtn(d));
    expect((await screen.findAllByText('The lines must be a JSON array, with one entry per policy.')).length).toBeGreaterThan(0);
    expect(mockRpc).not.toHaveBeenCalled();
    expect(screen.getByRole('dialog')).toBeTruthy();
  });

  it('keeps the dialog and shows the server message when the statement is refused, for example a repeated reference', async () => {
    const user = userEvent.setup();
    mockRpc.mockResolvedValueOnce({ data: null, error: { message: 'INS_DUPLICATE: A statement with this reference already exists' } });
    renderStatements();
    await user.click(await screen.findByRole('button', { name: 'Record statement' }));
    const d = await fill(user);
    await user.click(saveBtn(d));
    expect(await screen.findByText('A statement with this reference already exists')).toBeTruthy();
    expect(screen.getByRole('dialog')).toBeTruthy();
  });

  it('Cancel closes without calling the server', async () => {
    const user = userEvent.setup();
    renderStatements();
    await user.click(await screen.findByRole('button', { name: 'Record statement' }));
    await user.click(within(await dialog()).getByRole('button', { name: 'Cancel' }));
    await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull());
    expect(mockRpc).not.toHaveBeenCalled();
  });
});
