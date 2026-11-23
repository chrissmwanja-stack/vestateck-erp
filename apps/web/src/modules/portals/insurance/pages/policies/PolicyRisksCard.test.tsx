import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import PolicyRisksCard from './PolicyRisksCard';

// Risks and motor certificate for a draft policy. The card only offers what the server will
// accept: risks of the same client that are active and not yet linked, and issued certificates
// that belong to a risk already linked to this policy. The certificate section appears only on a
// line that needs one (flagged, or code MOTOR). Every change goes through an RPC, then the card
// reloads and tells the policy page.

const mockFrom = vi.fn();
const mockRpc = vi.fn();
vi.mock('../../../../../lib/supabaseClient', () => ({
  supabase: { from: (...a: unknown[]) => mockFrom(...a), rpc: (...a: unknown[]) => mockRpc(...a) },
}));

type Row = Record<string, unknown>;
const riskRow = (id: string, description: string, reg: string | null, over: Row = {}): Row => ({ id, client_id: 'cl1', risk_type: 'vehicle', description, reg_no: reg, chassis_no: null, status: 'active', ...over });
const cert = (id: string, serial: string, risk_id: string | null, over: Row = {}): Row => ({ id, serial_no: serial, status: 'issued', issued_to: 'Acme', risk_id, policy_id: null, issued_at: '2026-11-01', close_reason: null, ins_risks: null, ...over });

let line: Row | null;
let linked: Row[];
let clientRisks: Row[];
let attached: Row[];
let available: Row[];
let loadError: { message: string } | null;
let calls: Array<[string, string, unknown[]]>;

function builder(name: string) {
  const used = new Set<string>();
  const chain: Record<string, unknown> = {};
  for (const m of ['select', 'eq', 'is', 'order']) chain[m] = vi.fn((...a: unknown[]) => { used.add(m); calls.push([name, m, a]); return chain; });
  (chain as { then: unknown }).then = (resolve: (v: unknown) => void) => {
    if (loadError) return resolve({ data: null, error: loadError });
    let data: Row[] = [];
    if (name === 'ins_product_lines') data = line ? [line] : [];
    if (name === 'ins_policy_risks') data = linked;
    if (name === 'ins_risks') data = clientRisks;
    if (name === 'ins_certificate_stock') data = used.has('is') ? available : attached;
    return resolve({ data, error: null });
  };
  return chain;
}

beforeEach(() => {
  vi.clearAllMocks();
  line = { code: 'MOTOR', requires_certificate: true };
  linked = [];
  clientRisks = [];
  attached = [];
  available = [];
  loadError = null;
  calls = [];
  mockFrom.mockImplementation((name: string) => builder(name));
  mockRpc.mockImplementation(async (fn: string, args: Row) => {
    if (fn === 'ins_link_policy_risk') {
      const r = clientRisks.find((x) => x.id === args.p_risk_id)!;
      linked = [...linked, { risk_id: r.id, ins_risks: r }];
    }
    if (fn === 'ins_unlink_policy_risk') linked = linked.filter((l) => l.risk_id !== args.p_risk_id);
    if (fn === 'ins_attach_certificate') {
      const c = available.find((x) => x.serial_no === args.p_serial_no)!;
      attached = [{ ...c, policy_id: 'p1' }];
      available = available.filter((x) => x !== c);
    }
    return { data: {}, error: null };
  });
});

function renderCard(over: Partial<{ canManage: boolean; onChanged: () => void }> = {}) {
  const onChanged = over.onChanged ?? vi.fn();
  render(<PolicyRisksCard policyId="p1" clientId="cl1" productLineId="l1" canManage={over.canManage ?? true} onChanged={onChanged} />);
  return onChanged as ReturnType<typeof vi.fn>;
}
const rpcCalls = (fn: string) => mockRpc.mock.calls.filter((c) => c[0] === fn);

describe('PolicyRisksCard: what it reads', () => {
  it('reads the line, this policy\'s risks and certificate, the client\'s active risks and the issued certificates not yet on a policy', async () => {
    renderCard();
    await screen.findByText('Insured risks and certificate');
    await waitFor(() => expect(calls.length).toBeGreaterThan(8));
    expect(calls).toEqual(expect.arrayContaining([
      ['ins_product_lines', 'eq', ['id', 'l1']],
      ['ins_policy_risks', 'eq', ['policy_id', 'p1']],
      ['ins_risks', 'eq', ['client_id', 'cl1']],
      ['ins_risks', 'eq', ['status', 'active']],
      ['ins_certificate_stock', 'eq', ['policy_id', 'p1']],
      ['ins_certificate_stock', 'eq', ['status', 'issued']],
      ['ins_certificate_stock', 'is', ['policy_id', null]],
    ]));
  });

  it('shows a load failure', async () => {
    loadError = { message: 'permission denied for table ins_policy_risks' };
    renderCard();
    expect(await screen.findByText('permission denied for table ins_policy_risks')).toBeTruthy();
  });
});

describe('PolicyRisksCard: linked risks', () => {
  it('says when no risk is linked', async () => {
    renderCard();
    expect(await screen.findByText('No risk linked to this policy yet.')).toBeTruthy();
  });

  it('describes each linked risk with its registration and chassis, or "Risk" when it cannot be read', async () => {
    linked = [
      { risk_id: 'r1', ins_risks: riskRow('r1', 'Toyota Hilux', 'UAB 123X', { chassis_no: 'CH-001' }) },
      { risk_id: 'r2', ins_risks: riskRow('r2', 'Warehouse', null) },
      { risk_id: 'r3', ins_risks: null },
    ];
    renderCard();
    expect(await screen.findByText('Toyota Hilux (UAB 123X) chassis CH-001')).toBeTruthy();
    expect(screen.getByText('Warehouse')).toBeTruthy();
    expect(screen.getByText('Risk')).toBeTruthy();
  });

  it('unlinks through the RPC, then reloads and tells the policy page', async () => {
    const user = userEvent.setup();
    linked = [{ risk_id: 'r1', ins_risks: riskRow('r1', 'Toyota Hilux', 'UAB 123X') }];
    const onChanged = renderCard();
    await user.click(await screen.findByRole('button', { name: 'Unlink' }));
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('ins_unlink_policy_risk', { p_policy_id: 'p1', p_risk_id: 'r1' }));
    expect(await screen.findByText('No risk linked to this policy yet.')).toBeTruthy();
    expect(onChanged).toHaveBeenCalledTimes(1);
  });

  it('shows the linked risks to a member, with no way to change them', async () => {
    linked = [{ risk_id: 'r1', ins_risks: riskRow('r1', 'Toyota Hilux', 'UAB 123X') }];
    clientRisks = [riskRow('r9', 'Spare car', 'UAC 9')];
    renderCard({ canManage: false });
    await screen.findByText(/Toyota Hilux/);
    expect(screen.queryByRole('button', { name: 'Unlink' })).toBeNull();
    expect(screen.queryByLabelText('Client risk')).toBeNull();
    expect(screen.queryByRole('button', { name: 'Link risk' })).toBeNull();
  });
});

describe('PolicyRisksCard: linking a risk', () => {
  it('offers only the client\'s risks that are not linked yet', async () => {
    const user = userEvent.setup();
    linked = [{ risk_id: 'r1', ins_risks: riskRow('r1', 'Toyota Hilux', 'UAB 123X') }];
    clientRisks = [riskRow('r1', 'Toyota Hilux', 'UAB 123X'), riskRow('r2', 'Spare car', 'UAC 9'), riskRow('r3', 'Warehouse', null)];
    renderCard();
    await user.click(await screen.findByLabelText('Client risk'));
    const options = (await screen.findAllByRole('option')).map((o) => o.textContent);
    expect(options).toEqual(['Spare car (UAC 9)', 'Warehouse']);
  });

  it('shows no link control when every risk of the client is already linked', async () => {
    linked = [{ risk_id: 'r1', ins_risks: riskRow('r1', 'Toyota Hilux', 'UAB 123X') }];
    clientRisks = [riskRow('r1', 'Toyota Hilux', 'UAB 123X')];
    renderCard();
    await screen.findByText(/Toyota Hilux/);
    expect(screen.queryByLabelText('Client risk')).toBeNull();
  });

  it('keeps Link risk disabled until a risk is chosen, links it through the RPC and clears the choice', async () => {
    const user = userEvent.setup();
    clientRisks = [riskRow('r2', 'Spare car', 'UAC 9')];
    const onChanged = renderCard();
    const link = (await screen.findByRole('button', { name: 'Link risk' })) as HTMLButtonElement;
    expect(link.disabled).toBe(true);
    await user.click(screen.getByLabelText('Client risk'));
    await user.click(await screen.findByRole('option', { name: 'Spare car (UAC 9)' }));
    expect(link.disabled).toBe(false);
    await user.click(link);
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('ins_link_policy_risk', { p_policy_id: 'p1', p_risk_id: 'r2' }));
    expect(await screen.findByText('Spare car (UAC 9)')).toBeTruthy(); // now in the linked list
    expect(onChanged).toHaveBeenCalledTimes(1);
  });

  it('shows the server message when linking is refused, and does not tell the policy page', async () => {
    const user = userEvent.setup();
    clientRisks = [riskRow('r2', 'Spare car', 'UAC 9')];
    mockRpc.mockResolvedValueOnce({ data: null, error: { message: 'INS_POLICY_NOT_DRAFT: Only a draft policy can change its risks' } });
    const onChanged = renderCard();
    await user.click(await screen.findByLabelText('Client risk'));
    await user.click(await screen.findByRole('option', { name: 'Spare car (UAC 9)' }));
    await user.click(screen.getByRole('button', { name: 'Link risk' }));
    expect(await screen.findByText('Only a draft policy can change its risks')).toBeTruthy();
    expect(onChanged).not.toHaveBeenCalled();
  });

  it('disables the actions while one is running, so it runs once', async () => {
    const user = userEvent.setup();
    linked = [{ risk_id: 'r1', ins_risks: riskRow('r1', 'Toyota Hilux', 'UAB 123X') }];
    clientRisks = [riskRow('r2', 'Spare car', 'UAC 9')];
    let release: (v: unknown) => void = () => {};
    mockRpc.mockImplementationOnce(() => new Promise((resolve) => { release = resolve; }));
    renderCard();
    await user.click(await screen.findByLabelText('Client risk'));
    await user.click(await screen.findByRole('option', { name: 'Spare car (UAC 9)' }));
    await user.click(screen.getByRole('button', { name: 'Link risk' }));
    await waitFor(() => expect((screen.getByRole('button', { name: 'Unlink' }) as HTMLButtonElement).disabled).toBe(true));
    expect((screen.getByRole('button', { name: 'Link risk' }) as HTMLButtonElement).disabled).toBe(true);
    release({ data: {}, error: null });
    await waitFor(() => expect((screen.getByRole('button', { name: 'Unlink' }) as HTMLButtonElement).disabled).toBe(false));
    expect(rpcCalls('ins_link_policy_risk')).toHaveLength(1);
  });

  it('works without a change callback', async () => {
    const user = userEvent.setup();
    linked = [{ risk_id: 'r1', ins_risks: riskRow('r1', 'Toyota Hilux', 'UAB 123X') }];
    render(<PolicyRisksCard policyId="p1" clientId="cl1" productLineId="l1" canManage />);
    await user.click(await screen.findByRole('button', { name: 'Unlink' }));
    await waitFor(() => expect(rpcCalls('ins_unlink_policy_risk')).toHaveLength(1));
    expect(await screen.findByText('No risk linked to this policy yet.')).toBeTruthy();
  });
});

describe('PolicyRisksCard: certificate', () => {
  const withLinkedRisk = () => { linked = [{ risk_id: 'r1', ins_risks: riskRow('r1', 'Toyota Hilux', 'UAB 123X') }]; };

  it.each([
    ['flagged as needing one', { code: 'FIRE', requires_certificate: true }, true],
    ['the MOTOR code', { code: 'MOTOR', requires_certificate: false }, true],
    ['neither', { code: 'FIRE', requires_certificate: false }, false],
  ])('certificate section for a line with %s: shown = %s', async (_n, lineRow, shown) => {
    line = lineRow;
    renderCard();
    await screen.findByText('Insured risks and certificate');
    await waitFor(() => expect(calls.some((c) => c[0] === 'ins_certificate_stock')).toBe(true));
    await waitFor(() => expect(!!screen.queryByText('Certificate', { selector: 'h6' })).toBe(shown));
    if (!shown) {
      expect(screen.queryByText(/needs a certificate/)).toBeNull();
      expect(screen.queryByText(/is attached/)).toBeNull();
    }
  });

  it('warns that the policy cannot bind without an attached certificate', async () => {
    renderCard();
    expect(await screen.findByText(/cannot be bound until an issued certificate is attached/)).toBeTruthy();
  });

  it('shows an attached certificate as ready, and offers no attach control even to a manager', async () => {
    withLinkedRisk();
    attached = [cert('k1', 'UG0000101', 'r1', { policy_id: 'p1' })];
    available = [cert('k2', 'UG0000102', 'r1')];
    renderCard();
    expect(await screen.findByText('Certificate UG0000101 is attached. It is used when the policy is bound.')).toBeTruthy();
    expect(screen.queryByText(/cannot be bound/)).toBeNull();
    expect(screen.queryByLabelText('Certificate')).toBeNull();
    expect(screen.queryByRole('button', { name: 'Attach certificate' })).toBeNull();
  });

  it('points a manager to the stock screen when no issued certificate belongs to a linked risk', async () => {
    withLinkedRisk();
    available = [cert('k2', 'UG0000102', 'rX'), cert('k3', 'UG0000103', null)]; // other risks only
    renderCard();
    expect(await screen.findByText('No issued certificate for a linked risk. Issue one on the certificate stock screen.')).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Attach certificate' })).toBeNull();
  });

  it('offers only issued certificates for a linked risk, and attaches the chosen one', async () => {
    const user = userEvent.setup();
    withLinkedRisk();
    available = [cert('k1', 'UG0000101', 'r1'), cert('k2', 'UG0000102', 'rX'), cert('k3', 'UG0000103', 'r1')];
    const onChanged = renderCard();
    await user.click(await screen.findByLabelText('Certificate'));
    const options = (await screen.findAllByRole('option')).map((o) => o.textContent);
    expect(options).toEqual(['UG0000101', 'UG0000103']);
    await user.click(screen.getByRole('option', { name: 'UG0000103' }));
    await user.click(screen.getByRole('button', { name: 'Attach certificate' }));
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('ins_attach_certificate', { p_policy_id: 'p1', p_serial_no: 'UG0000103' }));
    expect(await screen.findByText('Certificate UG0000103 is attached. It is used when the policy is bound.')).toBeTruthy();
    expect(onChanged).toHaveBeenCalledTimes(1);
  });

  it('keeps Attach disabled until a certificate is chosen', async () => {
    withLinkedRisk();
    available = [cert('k1', 'UG0000101', 'r1')];
    renderCard();
    expect((await screen.findByRole('button', { name: 'Attach certificate' }) as HTMLButtonElement).disabled).toBe(true);
  });

  it('gives a member the certificate status but no attach control', async () => {
    withLinkedRisk();
    available = [cert('k1', 'UG0000101', 'r1')];
    renderCard({ canManage: false });
    expect(await screen.findByText(/cannot be bound until an issued certificate is attached/)).toBeTruthy();
    expect(screen.queryByLabelText('Certificate')).toBeNull();
    expect(screen.queryByText(/No issued certificate for a linked risk/)).toBeNull();
  });

  it('shows the server message when attaching is refused', async () => {
    const user = userEvent.setup();
    withLinkedRisk();
    available = [cert('k1', 'UG0000101', 'r1')];
    mockRpc.mockResolvedValueOnce({ data: null, error: { message: 'INS_CERT_STATE: The certificate is no longer available' } });
    renderCard();
    await user.click(await screen.findByLabelText('Certificate'));
    await user.click(await screen.findByRole('option', { name: 'UG0000101' }));
    await user.click(screen.getByRole('button', { name: 'Attach certificate' }));
    expect(await screen.findByText('The certificate is no longer available')).toBeTruthy();
  });
});
