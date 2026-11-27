import { fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import NewClaim from './NewClaim';

// Report-a-claim form. Only bound (active/renewed) policies can be claimed against. The
// form blocks a claim before the RPC is called when the loss date is outside the policy
// period, the notified date precedes the loss, or the reserve is negative or above the sum
// insured. The write goes through ins_create_claim only, never a direct table insert.
//
// The policies mock projects rows down to the columns the component actually selects, the
// way PostgREST does. A column the screen validates against but forgets to select would
// therefore be undefined here, as it is in production.

const mockFrom = vi.fn();
const mockRpc = vi.fn();
vi.mock('../../../../../lib/supabaseClient', () => ({
  supabase: {
    from: (...args: unknown[]) => mockFrom(...args),
    rpc: (...args: unknown[]) => mockRpc(...args),
  },
}));

const POLICIES = [
  {
    id: 'p1', policy_no: 'POL-001', status: 'active', currency: 'UGX', sum_insured: 50_000_000,
    inception_date: '2026-01-01T00:00:00Z', expiry_date: '2026-12-31',
    ins_clients: { bd_clients: { name: 'Acme Traders' } },
  },
  {
    id: 'p2', policy_no: 'POL-002', status: 'renewed', currency: 'USD', sum_insured: 0,
    inception_date: '2026-03-01', expiry_date: '2027-02-28',
    ins_clients: { bd_clients: { name: 'Globe Ltd' } },
  },
];

// Top-level column names of a PostgREST select string ("a, b, rel(c, d)" -> a, b, rel).
function topLevelColumns(select: string): string[] {
  const cols: string[] = [];
  let depth = 0;
  let cur = '';
  for (const ch of select) {
    if (ch === '(') depth++;
    if (ch === ')') depth--;
    if (ch === ',' && depth === 0) { cols.push(cur.trim()); cur = ''; } else cur += ch;
  }
  if (cur.trim()) cols.push(cur.trim());
  return cols.map((c) => c.replace(/\(.*$/, '').trim());
}

let selectArg = '';
let inFilter: unknown[] = [];
let policyError: { message: string } | null = null;
let policyRows: typeof POLICIES = POLICIES;

function policiesChain() {
  const chain: Record<string, unknown> = {};
  chain.select = vi.fn((s: string) => { selectArg = s; return chain; });
  chain.in = vi.fn((col: string, vals: unknown[]) => { inFilter = [col, vals]; return chain; });
  chain.order = vi.fn(() => chain);
  (chain as { then: unknown }).then = (resolve: (v: unknown) => void) => {
    const cols = topLevelColumns(selectArg);
    const data = policyRows.map((r) => Object.fromEntries(Object.entries(r).filter(([k]) => cols.includes(k))));
    return resolve({ data: policyError ? null : data, error: policyError });
  };
  return chain;
}

function renderForm(url = '/insurance/claims/new') {
  return render(
    <MemoryRouter initialEntries={[url]}>
      <Routes>
        <Route path="/insurance/claims/new" element={<NewClaim />} />
        <Route path="/insurance/claims" element={<div>CLAIMS LIST PAGE</div>} />
        <Route path="/insurance/claims/:id" element={<div>CLAIM DETAIL PAGE</div>} />
      </Routes>
    </MemoryRouter>,
  );
}

async function choosePolicy(user: ReturnType<typeof userEvent.setup>, label: RegExp) {
  await user.click(await screen.findByLabelText(/^Policy/));
  await user.click(await screen.findByRole('option', { name: label }));
}

const setDate = (label: string, value: string) => fireEvent.change(screen.getByLabelText(label), { target: { value } });
const reportButton = () => screen.getByRole('button', { name: /Report claim|Saving/ }) as HTMLButtonElement;

beforeEach(() => {
  vi.clearAllMocks();
  selectArg = '';
  inFilter = [];
  policyError = null;
  policyRows = POLICIES;
  mockFrom.mockImplementation((name: string) => {
    if (name === 'ins_policies') return policiesChain();
    throw new Error(`unexpected table ${name}`);
  });
  mockRpc.mockResolvedValue({ data: { id: 'claim-9' }, error: null });
});

describe('NewClaim', () => {
  it('offers only bound policies and selects every column the validation reads', async () => {
    renderForm();
    await screen.findByLabelText(/^Policy/);
    expect(inFilter).toEqual(['status', ['active', 'renewed']]);
    expect(topLevelColumns(selectArg)).toEqual(expect.arrayContaining(['id', 'policy_no', 'currency', 'sum_insured', 'inception_date', 'expiry_date']));
  });

  it('shows an info notice when there is nothing to claim against', async () => {
    policyRows = [];
    renderForm();
    expect(await screen.findByText('There are no bound policies to claim against.')).toBeTruthy();
  });

  it('surfaces a policy load failure instead of an empty form silently', async () => {
    policyError = { message: 'permission denied for table ins_policies' };
    renderForm();
    expect(await screen.findByText('permission denied for table ins_policies')).toBeTruthy();
    expect(screen.queryByText('There are no bound policies to claim against.')).toBeNull(); // a failed load is not "no policies"
    expect(mockRpc).not.toHaveBeenCalled();
  });

  it('cannot be submitted until a policy is chosen and the loss is described', async () => {
    const user = userEvent.setup();
    renderForm();
    await screen.findByLabelText(/^Policy/);
    expect(reportButton().disabled).toBe(true);

    await choosePolicy(user, /POL-001/);
    expect(reportButton().disabled).toBe(true); // description still blank
    expect(screen.getByText('Describe the loss.')).toBeTruthy();

    await user.type(screen.getByLabelText(/Description of loss/), '   ');
    expect(reportButton().disabled).toBe(true); // whitespace is not a description

    await user.type(screen.getByLabelText(/Description of loss/), 'Warehouse fire');
    await waitFor(() => expect(reportButton().disabled).toBe(false));
  });

  it('choosing a policy shows its sum insured and does not break the form', async () => {
    const user = userEvent.setup();
    renderForm();
    await choosePolicy(user, /POL-001/);
    expect(await screen.findByText(/Estimated exposure\. Sum insured/)).toBeTruthy();
    expect(screen.getByLabelText(/Initial reserve \(UGX\)/)).toBeTruthy();
  });

  it('preselects the policy from the ?policy= query parameter', async () => {
    renderForm('/insurance/claims/new?policy=p2');
    expect(await screen.findByLabelText(/Initial reserve \(USD\)/)).toBeTruthy();
  });

  it('rejects a loss date outside the policy period, before the RPC', async () => {
    const user = userEvent.setup();
    renderForm();
    await choosePolicy(user, /POL-001/);
    await user.type(screen.getByLabelText(/Description of loss/), 'Theft');

    setDate('Loss date', '2025-12-31');
    setDate('Notified date', '2026-01-05');
    expect(await screen.findByText(/loss date must fall within the policy period \(2026-01-01T00:00:00Z to 2026-12-31\)/)).toBeTruthy();
    expect(reportButton().disabled).toBe(true);

    setDate('Loss date', '2027-01-01');
    setDate('Notified date', '2027-01-02');
    expect(await screen.findByText(/loss date must fall within the policy period/)).toBeTruthy();

    // Boundaries are inclusive, and a timestamp inception date compares by its date part.
    setDate('Loss date', '2026-01-01');
    setDate('Notified date', '2026-01-01');
    await waitFor(() => expect(reportButton().disabled).toBe(false));
    setDate('Loss date', '2026-12-31');
    setDate('Notified date', '2026-12-31');
    await waitFor(() => expect(reportButton().disabled).toBe(false));
    expect(mockRpc).not.toHaveBeenCalled();
  });

  it('rejects a notified date before the loss date', async () => {
    const user = userEvent.setup();
    renderForm();
    await choosePolicy(user, /POL-001/);
    await user.type(screen.getByLabelText(/Description of loss/), 'Theft');
    setDate('Loss date', '2026-06-10');
    setDate('Notified date', '2026-06-09');
    expect(await screen.findByText('The notified date cannot be before the loss date.')).toBeTruthy();
    expect(reportButton().disabled).toBe(true);
  });

  it('rejects a negative reserve and a reserve above the sum insured', async () => {
    const user = userEvent.setup();
    renderForm();
    await choosePolicy(user, /POL-001/);
    await user.type(screen.getByLabelText(/Description of loss/), 'Flood');
    setDate('Loss date', '2026-06-10');
    setDate('Notified date', '2026-06-11');
    const reserve = screen.getByLabelText(/Initial reserve/);

    fireEvent.change(reserve, { target: { value: '-5' } });
    expect(await screen.findByText('The reserve cannot be negative.')).toBeTruthy();
    expect(reportButton().disabled).toBe(true);

    fireEvent.change(reserve, { target: { value: '50000001' } });
    expect(await screen.findByText('The reserve cannot exceed the sum insured.')).toBeTruthy();

    fireEvent.change(reserve, { target: { value: '50000000' } }); // equal to the sum insured is allowed
    await waitFor(() => expect(reportButton().disabled).toBe(false));
  });

  it('does not cap the reserve when the policy has no sum insured', async () => {
    const user = userEvent.setup();
    renderForm();
    await choosePolicy(user, /POL-002/);
    await user.type(screen.getByLabelText(/Description of loss/), 'Cargo loss');
    setDate('Loss date', '2026-06-10');
    setDate('Notified date', '2026-06-11');
    fireEvent.change(screen.getByLabelText(/Initial reserve/), { target: { value: '999999999' } });
    await waitFor(() => expect(reportButton().disabled).toBe(false));
  });

  it('reports the claim through ins_create_claim with trimmed values and opens it', async () => {
    const user = userEvent.setup();
    renderForm();
    await choosePolicy(user, /POL-001/);
    await user.type(screen.getByLabelText(/Description of loss/), '  Warehouse fire  ');
    setDate('Loss date', '2026-06-10');
    setDate('Notified date', '2026-06-11');
    await user.type(screen.getByLabelText('Insurer claim reference'), '  INS-77  ');
    fireEvent.change(screen.getByLabelText(/Initial reserve/), { target: { value: '12500.5' } });

    await user.click(reportButton());
    await waitFor(() => expect(mockRpc).toHaveBeenCalledTimes(1));
    expect(mockRpc).toHaveBeenCalledWith('ins_create_claim', {
      p_policy_id: 'p1',
      p_loss_date: '2026-06-10',
      p_notified_date: '2026-06-11',
      p_loss_description: 'Warehouse fire',
      p_insurer_claim_ref: 'INS-77',
      p_reserve_amount: 12500.5,
    });
    expect(await screen.findByText('CLAIM DETAIL PAGE')).toBeTruthy();
    expect(mockFrom).not.toHaveBeenCalledWith('ins_claims');
  });

  it('sends null for a blank insurer reference and 0 for a blank reserve', async () => {
    const user = userEvent.setup();
    renderForm();
    await choosePolicy(user, /POL-001/);
    await user.type(screen.getByLabelText(/Description of loss/), 'Collision');
    setDate('Loss date', '2026-06-10');
    setDate('Notified date', '2026-06-10');
    fireEvent.change(screen.getByLabelText(/Initial reserve/), { target: { value: '' } });
    await user.click(reportButton());
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('ins_create_claim', expect.objectContaining({
      p_insurer_claim_ref: null, p_reserve_amount: 0,
    })));
  });

  it('keeps the form and shows the error when the RPC refuses, and allows a retry', async () => {
    const user = userEvent.setup();
    mockRpc.mockResolvedValueOnce({ data: null, error: { message: 'Policy is not in force on the loss date' } });
    renderForm();
    await choosePolicy(user, /POL-001/);
    await user.type(screen.getByLabelText(/Description of loss/), 'Collision');
    setDate('Loss date', '2026-06-10');
    setDate('Notified date', '2026-06-10');
    await user.click(reportButton());

    expect(await screen.findByText('Policy is not in force on the loss date')).toBeTruthy();
    expect(screen.queryByText('CLAIM DETAIL PAGE')).toBeNull();
    expect((screen.getByLabelText(/Description of loss/) as HTMLTextAreaElement).value).toBe('Collision');
    await waitFor(() => expect(reportButton().disabled).toBe(false));

    await user.click(reportButton());
    expect(await screen.findByText('CLAIM DETAIL PAGE')).toBeTruthy();
    expect(mockRpc).toHaveBeenCalledTimes(2);
  });

  it('Cancel goes back to the claims list without writing', async () => {
    const user = userEvent.setup();
    renderForm();
    await screen.findByLabelText(/^Policy/);
    await user.click(within(document.body).getByRole('button', { name: 'Cancel' }));
    expect(await screen.findByText('CLAIMS LIST PAGE')).toBeTruthy();
    expect(mockRpc).not.toHaveBeenCalled();
  });
});
