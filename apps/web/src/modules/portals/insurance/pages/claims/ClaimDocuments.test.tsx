import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import ClaimDocuments from './ClaimDocuments';

// Claim document checklist: missing -> provided -> verified.
// Anyone with insurance access can track a document type and mark it provided; only a manager can
// verify, and only a provided document. Everything goes through the two RPCs. While a write is in
// flight every action is disabled, so a double click cannot send it twice.

const mockFrom = vi.fn();
const mockRpc = vi.fn();
vi.mock('../../../../../lib/supabaseClient', () => ({
  supabase: { from: (...a: unknown[]) => mockFrom(...a), rpc: (...a: unknown[]) => mockRpc(...a) },
}));

let mockCanManage = true;
vi.mock('../../access', () => ({ useInsuranceAccess: () => ({ loading: false, canManage: mockCanManage }) }));

type Doc = { id: string; doc_type: string; status: 'missing' | 'provided' | 'verified'; note: string | null; updated_at: string };
const doc = (doc_type: string, status: Doc['status'], note: string | null = null): Doc => ({ id: `d-${doc_type}`, doc_type, status, note, updated_at: '2026-06-12T09:00:00Z' });

let docs: Doc[];
let loadError: { message: string } | null;
let chainCalls: Array<[string, unknown[]]>;

function builder() {
  const chain: Record<string, unknown> = {};
  for (const m of ['select', 'eq', 'order']) chain[m] = vi.fn((...args: unknown[]) => { chainCalls.push([m, args]); return chain; });
  (chain as { then: unknown }).then = (resolve: (v: unknown) => void) =>
    resolve({ data: loadError ? null : [...docs].sort((a, b) => a.doc_type.localeCompare(b.doc_type)), error: loadError });
  return chain;
}

// Applies what the server would do, so the reload after a write reflects it.
function serverApplies(fn: string, args: Record<string, unknown>) {
  const type = args.p_doc_type as string;
  if (fn === 'ins_set_claim_document') {
    const existing = docs.find((d) => d.doc_type === type);
    if (existing) existing.status = args.p_status as Doc['status'];
    else docs.push(doc(type, args.p_status as Doc['status']));
  }
  if (fn === 'ins_verify_claim_document') docs.find((d) => d.doc_type === type)!.status = 'verified';
}

beforeEach(() => {
  vi.clearAllMocks();
  mockCanManage = true;
  docs = [];
  loadError = null;
  chainCalls = [];
  mockFrom.mockImplementation((name: string) => {
    if (name === 'ins_claim_documents') return builder();
    throw new Error(`unexpected table ${name}`);
  });
  mockRpc.mockImplementation(async (fn: string, args: Record<string, unknown>) => {
    serverApplies(fn, args);
    return { data: { id: 'x' }, error: null };
  });
});

const renderDocs = () => render(<ClaimDocuments claimId="c1" />);
const docRow = (type: string) => screen.getAllByRole('row').find((r) => within(r).queryByText(type)) as HTMLElement;
const btn = (name: string | RegExp) => screen.getByRole('button', { name }) as HTMLButtonElement;

describe('ClaimDocuments: display', () => {
  it('asks for this claim\'s documents in a stable order and shows the empty state', async () => {
    renderDocs();
    expect(await screen.findByText('No documents tracked yet.')).toBeTruthy();
    expect(chainCalls).toEqual(expect.arrayContaining([['eq', ['claim_id', 'c1']], ['order', ['doc_type']]]));
  });

  it('lists each document with its status chip and note, a dash when there is no note', async () => {
    docs = [doc('police_report', 'provided', 'Received by email'), doc('photos', 'missing')];
    renderDocs();
    await screen.findByText('police_report');
    expect(within(docRow('police_report')).getByText('provided')).toBeTruthy();
    expect(within(docRow('police_report')).getByText('Received by email')).toBeTruthy();
    expect(within(docRow('photos')).getByText('missing')).toBeTruthy();
    expect(within(docRow('photos')).getByText('—')).toBeTruthy();
    // Alphabetical, as the query orders them.
    const order = screen.getAllByRole('row').slice(1).map((r) => r.textContent ?? '');
    expect(order[0]).toContain('photos');
    expect(order[1]).toContain('police_report');
  });

  it('shows a load failure in the card instead of a silent empty list', async () => {
    loadError = { message: 'permission denied for table ins_claim_documents' };
    renderDocs();
    expect(await screen.findByText('permission denied for table ins_claim_documents')).toBeTruthy();
    expect(screen.queryByRole('progressbar')).toBeNull();
  });
});

describe('ClaimDocuments: actions by status and role', () => {
  it.each([
    ['missing, manager', 'missing', true, ['Mark provided']],
    ['missing, member', 'missing', false, ['Mark provided']],
    ['provided, manager', 'provided', true, ['Verify']],
    ['provided, member', 'provided', false, []],
    ['verified, manager', 'verified', true, []],
    ['verified, member', 'verified', false, []],
  ] as const)('%s', async (_n, status, canManage, expected) => {
    mockCanManage = canManage;
    docs = [doc('police_report', status)];
    renderDocs();
    await screen.findByText('police_report');
    const row = docRow('police_report');
    const shown = ['Mark provided', 'Verify'].filter((l) => within(row).queryByRole('button', { name: l }));
    expect(shown).toEqual(expected);
  });

  it('marks a document provided through the RPC, then shows it as provided', async () => {
    const user = userEvent.setup();
    docs = [doc('police_report', 'missing')];
    renderDocs();
    await user.click(await screen.findByRole('button', { name: 'Mark provided' }));
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('ins_set_claim_document', { p_claim_id: 'c1', p_doc_type: 'police_report', p_status: 'provided' }));
    expect(await screen.findByRole('button', { name: 'Verify' })).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Mark provided' })).toBeNull();
  });

  it('verifies a provided document through the RPC, after which no action remains', async () => {
    const user = userEvent.setup();
    docs = [doc('police_report', 'provided')];
    renderDocs();
    await user.click(await screen.findByRole('button', { name: 'Verify' }));
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('ins_verify_claim_document', { p_claim_id: 'c1', p_doc_type: 'police_report' }));
    await waitFor(() => expect(within(docRow('police_report')).getByText('verified')).toBeTruthy());
    expect(within(docRow('police_report')).queryByRole('button')).toBeNull();
  });

  it('shows the server message and stays usable when a write is refused', async () => {
    const user = userEvent.setup();
    docs = [doc('police_report', 'provided')];
    mockRpc.mockResolvedValueOnce({ data: null, error: { message: 'INS_ACCESS_DENIED: Not allowed' } });
    renderDocs();
    await user.click(await screen.findByRole('button', { name: 'Verify' }));
    expect(await screen.findByText('Not allowed')).toBeTruthy();
    await waitFor(() => expect(btn('Verify').disabled).toBe(false));
  });

  it('disables every action while a write is in flight, so it cannot be sent twice', async () => {
    const user = userEvent.setup();
    docs = [doc('police_report', 'missing'), doc('photos', 'missing')];
    let release: (v: unknown) => void = () => {};
    mockRpc.mockImplementationOnce(() => new Promise((resolve) => { release = resolve; }));
    renderDocs();
    const buttons = await screen.findAllByRole('button', { name: 'Mark provided' });
    await user.click(buttons[0]);
    await waitFor(() => expect((screen.getAllByRole('button', { name: 'Mark provided' }) as HTMLButtonElement[]).every((b) => b.disabled)).toBe(true));
    expect(btn('Add').disabled).toBe(true);
    release({ data: { id: 'x' }, error: null });
    await waitFor(() => expect((screen.getAllByRole('button', { name: 'Mark provided' }) as HTMLButtonElement[]).some((b) => b.disabled)).toBe(false));
    expect(mockRpc).toHaveBeenCalledTimes(1);
  });
});

describe('ClaimDocuments: adding document types', () => {
  it('cannot add a blank or whitespace-only type', async () => {
    const user = userEvent.setup();
    renderDocs();
    await screen.findByText('No documents tracked yet.');
    expect(btn('Add').disabled).toBe(true);
    await user.type(screen.getByLabelText('Add document type'), '   ');
    expect(btn('Add').disabled).toBe(true);
    expect(mockRpc).not.toHaveBeenCalled();
  });

  it('adds a trimmed custom type as missing, clears the field and lists it', async () => {
    const user = userEvent.setup();
    renderDocs();
    await screen.findByText('No documents tracked yet.');
    const input = screen.getByLabelText('Add document type') as HTMLInputElement;
    await user.type(input, '  valuation_report  ');
    await user.click(btn('Add'));
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('ins_set_claim_document', { p_claim_id: 'c1', p_doc_type: 'valuation_report', p_status: 'missing' }));
    expect(await screen.findByText('valuation_report')).toBeTruthy();
    await waitFor(() => expect(input.value).toBe(''));
  });

  it('offers the common types as quick adds, and drops one once it is tracked', async () => {
    const user = userEvent.setup();
    docs = [doc('police_report', 'missing')];
    renderDocs();
    await screen.findByText('police_report');
    expect(screen.queryByText('+ police_report')).toBeNull();
    for (const t of ['policy_schedule', 'photos', 'third_party_details', 'repair_estimates', 'medical_report']) {
      expect(screen.getByText(`+ ${t}`)).toBeTruthy();
    }
    await user.click(screen.getByText('+ photos'));
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('ins_set_claim_document', { p_claim_id: 'c1', p_doc_type: 'photos', p_status: 'missing' }));
    await waitFor(() => expect(screen.queryByText('+ photos')).toBeNull());
    expect(within(docRow('photos')).getByText('missing')).toBeTruthy();
  });

  it('shows the server message when adding a type is refused', async () => {
    const user = userEvent.setup();
    mockRpc.mockResolvedValueOnce({ data: null, error: { message: 'INS_CLAIM_NOT_FOUND: Claim not found' } });
    renderDocs();
    await screen.findByText('No documents tracked yet.');
    await user.type(screen.getByLabelText('Add document type'), 'photos');
    await user.click(btn('Add'));
    expect(await screen.findByText('Claim not found')).toBeTruthy();
  });
});
