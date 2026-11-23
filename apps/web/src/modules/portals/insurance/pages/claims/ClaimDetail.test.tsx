import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import ClaimDetail from './ClaimDetail';
import { formatMoney } from '../../logic';

// Claim detail page: the claim state machine and its money decisions.
//
// - Which step buttons are offered depends on status, role and history: members can only start
//   an assessment; managers decide. The registrant cannot approve their own claim. Un-approve is
//   offered only before the receivable is recognised and before any payment. A claim is never
//   settled by hand (no Settle button): it settles itself when payments cover the approved amount.
// - Approve needs an amount above zero and at most the sum insured; a re-approval, a repudiation
//   and an un-approval each need a reason. Every transition goes through ins_transition_claim.
// - Revising the reserve goes through ins_revise_claim_reserve and mirrors its client-side checks.
// - The page shows the reserve, approval and status histories, and reloads after any change.
//
// ClaimDocuments, ClaimCorrespondence and ClaimPayments have their own tests; they are stubbed here.

const mockFrom = vi.fn();
const mockRpc = vi.fn();
const mockGetUser = vi.fn();
vi.mock('../../../../../lib/supabaseClient', () => ({
  supabase: {
    from: (...a: unknown[]) => mockFrom(...a),
    rpc: (...a: unknown[]) => mockRpc(...a),
    auth: { getUser: (...a: unknown[]) => mockGetUser(...a) },
  },
}));

let mockCanManage = true;
vi.mock('../../access', () => ({
  useInsuranceAccess: () => ({ loading: false, canManage: mockCanManage }),
}));
vi.mock('./ClaimDocuments', () => ({ default: ({ claimId }: { claimId: string }) => <div>DOCS:{claimId}</div> }));
vi.mock('./ClaimCorrespondence', () => ({ default: ({ claimId }: { claimId: string }) => <div>CORRESPONDENCE:{claimId}</div> }));
vi.mock('./ClaimPayments', () => ({
  default: ({ claim, canManage, onChanged }: { claim: { id: string }; canManage: boolean; onChanged: () => void }) => (
    <div>
      <span>PAYMENTS:{claim.id}:{String(canManage)}</span>
      <button onClick={onChanged}>stub-payment-changed</button>
    </div>
  ),
}));

type Row = Record<string, unknown>;
const baseClaim = (over: Row = {}): Row => ({
  id: 'c1', claim_no: 'CLM-2026-00007', policy_id: 'p1', status: 'assessing', created_by: 'u-other',
  loss_date: '2026-06-10', notified_date: '2026-06-11', loss_description: 'Warehouse fire', insurer_claim_ref: 'INS-77',
  reserve_amount: 5_000_000, approved_amount: null, paid_amount: 0, payment_mode: null, recognised_at: null, settled_at: null,
  created_at: '2026-06-11',
  ins_policies: { policy_no: 'POL-001', sum_insured: 20_000_000, currency: 'UGX', expiry_date: '2026-12-31', ins_clients: { bd_clients: { name: 'Acme Traders' } } },
  ...over,
});

let claim: Row | null;
let events: Row[];
let reserves: Row[];
let approvals: Row[];
let claimError: { message: string } | null;
let currentUser: string | null;

function builder(getRows: () => Row[], getError: () => { message: string } | null = () => null) {
  const chain: Record<string, unknown> = {};
  for (const m of ['select', 'eq', 'order']) chain[m] = vi.fn(() => chain);
  (chain as { then: unknown }).then = (resolve: (v: unknown) => void) => {
    const error = getError();
    return resolve({ data: error ? null : getRows(), error });
  };
  return chain;
}

const claimsReads = () => mockFrom.mock.calls.filter((c) => c[0] === 'ins_claims').length;

beforeEach(() => {
  vi.clearAllMocks();
  mockCanManage = true;
  claim = baseClaim();
  events = [];
  reserves = [];
  approvals = [];
  claimError = null;
  currentUser = 'u-me';
  mockGetUser.mockImplementation(async () => ({ data: { user: currentUser ? { id: currentUser } : null } }));
  mockFrom.mockImplementation((name: string) => {
    if (name === 'ins_claims') return builder(() => (claim ? [claim] : []), () => claimError);
    if (name === 'ins_claim_events') return builder(() => events);
    if (name === 'ins_claim_reserve_history') return builder(() => reserves);
    if (name === 'ins_claim_approval_history') return builder(() => approvals);
    throw new Error(`unexpected table ${name}`);
  });
  mockRpc.mockImplementation(async (fn: string, args: Row) => {
    if (fn === 'ins_transition_claim' && claim) {
      claim = { ...claim, status: args.p_to, ...(args.p_amount != null ? { approved_amount: args.p_amount } : {}) };
    }
    if (fn === 'ins_revise_claim_reserve' && claim) claim = { ...claim, reserve_amount: args.p_new_amount };
    return { data: { id: 'c1' }, error: null };
  });
});

const renderDetail = () =>
  render(
    <MemoryRouter initialEntries={['/insurance/claims/c1']}>
      <Routes><Route path="/insurance/claims/:id" element={<ClaimDetail />} /></Routes>
    </MemoryRouter>,
  );

const STEP_LABELS = ['Start assessment', 'Approve', 'Repudiate', 'Un-approve', 'Close'];
const stepButtons = () => STEP_LABELS.filter((l) => screen.queryByRole('button', { name: l }));
const rowValue = (label: string) => screen.getAllByText(label).find((el) => el.nextElementSibling)?.nextElementSibling?.textContent;
const tableRow = (text: string) => screen.getAllByRole('row').find((r) => r.textContent?.includes(text)) as HTMLElement;
const dialog = () => screen.findByRole('dialog');
const saveBtn = (d: HTMLElement, name: string) => within(d).getByRole('button', { name }) as HTMLButtonElement;

describe('ClaimDetail: display', () => {
  it('shows the claim, its policy and the amounts, and wires the documents and payments panels', async () => {
    claim = baseClaim({ status: 'approved', approved_amount: 4_000_000, paid_amount: 1_000_000, settled_at: null });
    renderDetail();
    expect(await screen.findByText('CLM-2026-00007')).toBeTruthy();
    expect(screen.getByText('Acme Traders · policy POL-001')).toBeTruthy();
    expect(screen.getByText('Amounts (UGX)')).toBeTruthy();
    expect(rowValue('Loss date')).toBe('2026-06-10');
    expect(rowValue('Insurer reference')).toBe('INS-77');
    expect(rowValue('Description')).toBe('Warehouse fire');
    expect(rowValue('Reserve')).toBe(formatMoney(5_000_000, 'UGX'));
    expect(rowValue('Approved')).toBe(formatMoney(4_000_000, 'UGX'));
    expect(rowValue('Paid to the client')).toBe(formatMoney(1_000_000, 'UGX'));
    expect(screen.getByText('DOCS:c1')).toBeTruthy();
    expect(screen.getByText('CORRESPONDENCE:c1')).toBeTruthy(); // the correspondence log is reachable from the claim
    expect(screen.getByText('PAYMENTS:c1:true')).toBeTruthy();
  });

  it('uses the policy currency, shows a dash for an unapproved claim, and falls back to UGX', async () => {
    claim = baseClaim({ ins_policies: { policy_no: 'POL-9', sum_insured: 0, currency: 'USD', expiry_date: '2026-12-31', ins_clients: null } });
    renderDetail();
    expect(await screen.findByText('Amounts (USD)')).toBeTruthy();
    expect(screen.getByText('Client · policy POL-9')).toBeTruthy();
    expect(rowValue('Approved')).toBe('-');
    expect(rowValue('Insurer reference')).toBe('INS-77');
  });

  it('says so when the claim does not exist or is not visible', async () => {
    claim = null;
    renderDetail();
    expect(await screen.findByText('Claim not found, or you do not have access to it.')).toBeTruthy();
    expect(stepButtons()).toEqual([]);
  });

  it('shows the real error, not "not found", when the claim cannot be loaded, and offers no actions', async () => {
    claimError = { message: 'permission denied for table ins_claims' };
    renderDetail();
    expect(await screen.findByText('permission denied for table ins_claims')).toBeTruthy();
    expect(screen.queryByText('Claim not found, or you do not have access to it.')).toBeNull();
    expect(stepButtons()).toEqual([]);
    expect(screen.queryByText(/^DOCS:/)).toBeNull();
    expect(mockRpc).not.toHaveBeenCalled();
  });

  it('lists the reserve history with signed changes, the approval history, and the status events', async () => {
    reserves = [
      { id: 'r1', kind: 'initial', previous_amount: null, new_amount: 5_000_000, reason: 'Opening estimate', revised_at: '2026-06-11T08:00:00Z' },
      { id: 'r2', kind: 'revision', previous_amount: 5_000_000, new_amount: 8_000_000, reason: 'Loss developing', revised_at: '2026-06-20T08:00:00Z' },
      { id: 'r3', kind: 'revision', previous_amount: 8_000_000, new_amount: 6_000_000, reason: 'Salvage recovered', revised_at: '2026-06-25T08:00:00Z' },
    ];
    approvals = [
      { id: 'a1', kind: 'initial', previous_amount: null, new_amount: 6_000_000, reason: 'Assessor report', note: null, effective_at: '2026-06-26T08:00:00Z' },
      { id: 'a2', kind: 'revision', previous_amount: 6_000_000, new_amount: 5_500_000, reason: 'Excess applied', note: null, effective_at: '2026-06-27T08:00:00Z' },
      { id: 'a3', kind: 'cleared', previous_amount: 5_500_000, new_amount: null, reason: 'Wrong policy', note: null, effective_at: '2026-06-28T08:00:00Z' },
    ];
    events = [
      { id: 'e1', from_status: null, to_status: 'notified', note: null, created_at: '2026-06-11T08:00:00Z' },
      { id: 'e2', from_status: 'notified', to_status: 'assessing', note: 'Assessor assigned', created_at: '2026-06-12T08:00:00Z' },
    ];
    renderDetail();
    await screen.findByText('CLM-2026-00007');

    expect(tableRow('Opening estimate').textContent).toContain(formatMoney(5_000_000, 'UGX'));
    expect(tableRow('Opening estimate').textContent).not.toContain('→');
    expect(tableRow('Loss developing').textContent).toContain(`${formatMoney(5_000_000, 'UGX')} → ${formatMoney(8_000_000, 'UGX')}`);
    expect(tableRow('Loss developing').textContent).toContain(`+${formatMoney(3_000_000, 'UGX')}`);
    expect(tableRow('Salvage recovered').textContent).toContain(formatMoney(-2_000_000, 'UGX'));
    expect(tableRow('Salvage recovered').textContent).not.toContain('+');

    expect(within(tableRow('Assessor report')).getByText('Approval')).toBeTruthy();
    expect(within(tableRow('Excess applied')).getByText('Revision')).toBeTruthy();
    expect(within(tableRow('Wrong policy')).getByText('Withdrawn')).toBeTruthy();
    expect(tableRow('Wrong policy').textContent).toContain(`${formatMoney(5_500_000, 'UGX')} → withdrawn`);

    expect(screen.getAllByText('Notified')).toHaveLength(2); // the Loss card's date label and the first event
    expect(screen.getByText('Notified → Assessing')).toBeTruthy();
    expect(screen.getByText('Assessor assigned')).toBeTruthy();
  });

  it('shows empty-state messages when there is no history', async () => {
    renderDetail();
    expect(await screen.findByText('No reserve history yet.')).toBeTruthy();
    expect(screen.getByText('No approval history yet.')).toBeTruthy();
    expect(screen.getByText('No history yet.')).toBeTruthy();
  });

  it('reloads the claim when the payments panel reports a change', async () => {
    const user = userEvent.setup();
    renderDetail();
    await screen.findByText('PAYMENTS:c1:true');
    const before = claimsReads();
    await user.click(screen.getByRole('button', { name: 'stub-payment-changed' }));
    await waitFor(() => expect(claimsReads()).toBe(before + 1));
  });
});

describe('ClaimDetail: which steps are offered', () => {
  const cases: Array<[string, Row, boolean, string[]]> = [
    ['notified, manager', { status: 'notified' }, true, ['Start assessment', 'Repudiate']],
    ['notified, member', { status: 'notified' }, false, ['Start assessment']],
    ['assessing, manager', { status: 'assessing' }, true, ['Approve', 'Repudiate']],
    ['assessing, member', { status: 'assessing' }, false, []],
    ['approved, nothing recognised or paid, manager', { status: 'approved', approved_amount: 1 }, true, ['Un-approve']],
    ['approved, nothing recognised or paid, member', { status: 'approved', approved_amount: 1 }, false, []],
    ['approved, receivable recognised', { status: 'approved', approved_amount: 1, recognised_at: '2026-07-01T00:00:00Z' }, true, []],
    ['approved, part-paid', { status: 'approved', approved_amount: 5, paid_amount: 1 }, true, []],
    ['settled, manager', { status: 'settled' }, true, ['Close']],
    ['settled, member', { status: 'settled' }, false, []],
    ['repudiated, manager', { status: 'repudiated' }, true, ['Close']],
    ['closed', { status: 'closed' }, true, []],
  ];

  it.each(cases)('%s', async (_name, over, canManage, expected) => {
    mockCanManage = canManage;
    claim = baseClaim(over);
    renderDetail();
    await screen.findByText('CLM-2026-00007');
    expect(stepButtons()).toEqual(expected);
    expect(screen.queryByRole('button', { name: /settle/i })).toBeNull(); // settlement is automatic, never a button
  });

  it('keeps the registrant from approving their own claim and explains why', async () => {
    claim = baseClaim({ created_by: 'u-me' });
    renderDetail();
    expect(await screen.findByText('You registered this claim, so another manager must approve it.')).toBeTruthy();
    expect(stepButtons()).toEqual(['Repudiate']);
  });

  it('offers Approve to a different manager, with no notice', async () => {
    renderDetail();
    await screen.findByText('CLM-2026-00007');
    await waitFor(() => expect(mockGetUser).toHaveBeenCalled());
    expect(stepButtons()).toEqual(['Approve', 'Repudiate']);
    expect(screen.queryByText(/another manager must approve/)).toBeNull();
  });

  it('shows the registrant notice only while the claim is being assessed', async () => {
    claim = baseClaim({ status: 'notified', created_by: 'u-me' });
    renderDetail();
    await screen.findByText('CLM-2026-00007');
    expect(screen.queryByText(/another manager must approve/)).toBeNull();
    expect(stepButtons()).toEqual(['Start assessment', 'Repudiate']);
  });
});

describe('ClaimDetail: transitions', () => {
  it('approves with an amount: blocks zero and anything above the sum insured, then sends the figure', async () => {
    const user = userEvent.setup();
    renderDetail();
    await user.click(await screen.findByRole('button', { name: 'Approve' }));
    const d = await dialog();
    const amount = within(d).getByLabelText(/Approved amount \(UGX\)/) as HTMLInputElement;
    expect(amount.value).toBe('5000000'); // defaults to the reserve
    expect(within(d).queryByLabelText(/^Reason/)).toBeNull(); // a first approval needs no reason
    expect(within(d).getByLabelText('Note (optional)')).toBeTruthy();

    await user.clear(amount);
    await user.type(amount, '0');
    expect(saveBtn(d, 'Approve').disabled).toBe(true);
    await user.clear(amount);
    await user.type(amount, '20000001');
    expect(saveBtn(d, 'Approve').disabled).toBe(true);
    await user.clear(amount);
    await user.type(amount, '15000000');
    expect(saveBtn(d, 'Approve').disabled).toBe(false);
    await user.click(saveBtn(d, 'Approve'));

    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('ins_transition_claim', {
      p_claim_id: 'c1', p_to: 'approved', p_note: null, p_amount: 15_000_000,
    }));
    await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull());
    // The page reloaded: the approved claim now offers Un-approve and shows the approved amount.
    expect(await screen.findByRole('button', { name: 'Un-approve' })).toBeTruthy();
    expect(rowValue('Approved')).toBe(formatMoney(15_000_000, 'UGX'));
  });

  it('a re-approval is a revised approval and needs a reason', async () => {
    const user = userEvent.setup();
    approvals = [{ id: 'a1', kind: 'cleared', previous_amount: 5_000_000, new_amount: null, reason: 'Wrong policy', note: null, effective_at: '2026-06-28T08:00:00Z' }];
    renderDetail();
    await user.click(await screen.findByRole('button', { name: 'Approve' }));
    const d = await dialog();
    expect(within(d).getByText(/this is a revised approval/)).toBeTruthy();
    expect(saveBtn(d, 'Approve').disabled).toBe(true); // amount is filled, reason is not
    await user.type(within(d).getByLabelText(/^Reason/), '  Corrected assessor report  ');
    expect(saveBtn(d, 'Approve').disabled).toBe(false);
    await user.click(saveBtn(d, 'Approve'));
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('ins_transition_claim', {
      p_claim_id: 'c1', p_to: 'approved', p_note: 'Corrected assessor report', p_amount: 5_000_000,
    }));
  });

  it('does not cap the approved amount when the policy has no sum insured', async () => {
    const user = userEvent.setup();
    claim = baseClaim({ ins_policies: { policy_no: 'POL-9', sum_insured: 0, currency: 'UGX', expiry_date: '2026-12-31', ins_clients: null } });
    renderDetail();
    await user.click(await screen.findByRole('button', { name: 'Approve' }));
    const d = await dialog();
    const amount = within(d).getByLabelText(/Approved amount/);
    await user.clear(amount);
    await user.type(amount, '999999999');
    expect(saveBtn(d, 'Approve').disabled).toBe(false);
  });

  it('repudiating needs a reason and sends no amount', async () => {
    const user = userEvent.setup();
    renderDetail();
    await user.click(await screen.findByRole('button', { name: 'Repudiate' }));
    const d = await dialog();
    expect(saveBtn(d, 'Repudiate').disabled).toBe(true);
    await user.type(within(d).getByLabelText(/^Reason/), '   ');
    expect(saveBtn(d, 'Repudiate').disabled).toBe(true); // whitespace is not a reason
    await user.type(within(d).getByLabelText(/^Reason/), 'Cover excluded');
    await user.click(saveBtn(d, 'Repudiate'));
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('ins_transition_claim', {
      p_claim_id: 'c1', p_to: 'repudiated', p_note: 'Cover excluded', p_amount: null,
    }));
    expect(await screen.findByRole('button', { name: 'Close' })).toBeTruthy();
  });

  it('un-approving needs a reason', async () => {
    const user = userEvent.setup();
    claim = baseClaim({ status: 'approved', approved_amount: 4_000_000 });
    renderDetail();
    await user.click(await screen.findByRole('button', { name: 'Un-approve' }));
    const d = await dialog();
    expect(within(d).getByText(/Nothing is reversed, because nothing was posted/)).toBeTruthy();
    expect(saveBtn(d, 'Un-approve').disabled).toBe(true);
    await user.type(within(d).getByLabelText(/^Reason/), 'Approved in error');
    await user.click(saveBtn(d, 'Un-approve'));
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('ins_transition_claim', {
      p_claim_id: 'c1', p_to: 'assessing', p_note: 'Approved in error', p_amount: null,
    }));
  });

  it('starting an assessment and closing need no reason; a blank note is sent as null', async () => {
    const user = userEvent.setup();
    claim = baseClaim({ status: 'notified' });
    renderDetail();
    await user.click(await screen.findByRole('button', { name: 'Start assessment' }));
    let d = await dialog();
    expect(saveBtn(d, 'Start assessment').disabled).toBe(false);
    await user.click(saveBtn(d, 'Start assessment'));
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('ins_transition_claim', {
      p_claim_id: 'c1', p_to: 'assessing', p_note: null, p_amount: null,
    }));
    await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull());
    expect(await screen.findByRole('button', { name: 'Approve' })).toBeTruthy();

    mockRpc.mockClear();
    claim = baseClaim({ status: 'settled' });
    const { unmount } = renderDetail();
    unmount();
    renderDetail();
    await user.click((await screen.findAllByRole('button', { name: 'Close' }))[0]);
    d = await dialog();
    await user.type(within(d).getByLabelText('Note (optional)'), ' File complete ');
    await user.click(saveBtn(d, 'Close'));
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('ins_transition_claim', {
      p_claim_id: 'c1', p_to: 'closed', p_note: 'File complete', p_amount: null,
    }));
  });

  it('Cancel closes the dialog without calling the server', async () => {
    const user = userEvent.setup();
    renderDetail();
    await user.click(await screen.findByRole('button', { name: 'Repudiate' }));
    const d = await dialog();
    await user.click(within(d).getByRole('button', { name: 'Cancel' }));
    await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull());
    expect(mockRpc).not.toHaveBeenCalled();
  });

  it('keeps the dialog open and shows the server message when a transition is refused', async () => {
    const user = userEvent.setup();
    mockRpc.mockResolvedValueOnce({ data: null, error: { message: 'INS_CLAIM_SELF_APPROVAL: The person who registered a claim cannot approve it' } });
    renderDetail();
    await user.click(await screen.findByRole('button', { name: 'Approve' }));
    const d = await dialog();
    await user.click(saveBtn(d, 'Approve'));
    expect(await screen.findByText('The person who registered a claim cannot approve it')).toBeTruthy();
    expect(screen.getByRole('dialog')).toBeTruthy();
    expect(claim?.status).toBe('assessing');
    await waitFor(() => expect(saveBtn(screen.getByRole('dialog'), 'Approve').disabled).toBe(false)); // can retry
  });
});

describe('ClaimDetail: revising the reserve', () => {
  it.each([
    ['notified', true], ['assessing', true], ['approved', true],
    ['settled', false], ['repudiated', false], ['closed', false],
  ])('%s: revise button shown = %s', async (status, shown) => {
    claim = baseClaim({ status });
    renderDetail();
    await screen.findByText('CLM-2026-00007');
    expect(!!screen.queryByRole('button', { name: 'Revise reserve' })).toBe(shown);
  });

  it('applies the same checks as the server before saving, then sends the revision', async () => {
    const user = userEvent.setup();
    renderDetail();
    await user.click(await screen.findByRole('button', { name: 'Revise reserve' }));
    const d = await dialog();
    const input = within(d).getByLabelText(/New reserve \(UGX\)/) as HTMLInputElement;
    expect(input.value).toBe('5000000');
    expect(saveBtn(d, 'Save reserve').disabled).toBe(true);

    await user.type(within(d).getByLabelText(/Reason/), 'Loss developing');
    expect(within(d).getByText(/The reserve is already/)).toBeTruthy(); // same figure
    expect(saveBtn(d, 'Save reserve').disabled).toBe(true);

    await user.clear(input);
    await user.type(input, '25000000');
    expect(within(d).getByText(/cannot exceed the sum insured/)).toBeTruthy();
    expect(saveBtn(d, 'Save reserve').disabled).toBe(true);

    await user.clear(input);
    await user.type(input, '8000000');
    await waitFor(() => expect(saveBtn(d, 'Save reserve').disabled).toBe(false));

    await user.clear(within(d).getByLabelText(/Reason/));
    await user.type(within(d).getByLabelText(/Reason/), 'abc');
    expect(within(d).getByText('Give a reason of at least 5 characters.')).toBeTruthy();
    expect(saveBtn(d, 'Save reserve').disabled).toBe(true);

    await user.clear(within(d).getByLabelText(/Reason/));
    await user.type(within(d).getByLabelText(/Reason/), 'Loss developing');
    await user.click(saveBtn(d, 'Save reserve'));
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('ins_revise_claim_reserve', {
      p_claim_id: 'c1', p_new_amount: 8_000_000, p_reason: 'Loss developing',
    }));
    await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull());
    await waitFor(() => expect(rowValue('Reserve')).toBe(formatMoney(8_000_000, 'UGX'))); // page reloaded
  });

  it('rejects a negative reserve', async () => {
    const user = userEvent.setup();
    renderDetail();
    await user.click(await screen.findByRole('button', { name: 'Revise reserve' }));
    const d = await dialog();
    const input = within(d).getByLabelText(/New reserve/);
    await user.clear(input);
    await user.type(input, '-1');
    await user.type(within(d).getByLabelText(/Reason/), 'Mistake in estimate');
    expect(within(d).getByText('Enter a reserve of zero or more.')).toBeTruthy();
    expect(saveBtn(d, 'Save reserve').disabled).toBe(true);
  });

  it('closes the dialog and shows the message when the server refuses the revision', async () => {
    const user = userEvent.setup();
    mockRpc.mockResolvedValueOnce({ data: null, error: { message: 'INS_CLAIM_NOT_OPEN: The claim is no longer open' } });
    renderDetail();
    await user.click(await screen.findByRole('button', { name: 'Revise reserve' }));
    const d = await dialog();
    const input = within(d).getByLabelText(/New reserve/);
    await user.clear(input);
    await user.type(input, '6000000');
    await user.type(within(d).getByLabelText(/Reason/), 'Updated estimate');
    await user.click(saveBtn(d, 'Save reserve'));
    expect(await screen.findByText('The claim is no longer open')).toBeTruthy();
    await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull());
  });
});
