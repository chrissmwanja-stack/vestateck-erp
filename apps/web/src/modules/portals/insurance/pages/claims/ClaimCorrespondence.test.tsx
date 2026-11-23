import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import ClaimCorrespondence from './ClaimCorrespondence';

// Claim correspondence log: newest first, direction in/out, channel, subject, optional body and
// reference. Logging goes through ins_log_claim_correspondence only. The subject is required
// (the button stays disabled without one); a blank body or reference is sent as null; the form
// resets after a successful log and keeps what was typed when the server refuses.
//
// NOTE: this component is not mounted by ClaimDetail or any route today, so the log has no way
// in from the UI. The tests cover it as a unit so it is safe to wire up.

const mockFrom = vi.fn();
const mockRpc = vi.fn();
vi.mock('../../../../../lib/supabaseClient', () => ({
  supabase: { from: (...a: unknown[]) => mockFrom(...a), rpc: (...a: unknown[]) => mockRpc(...a) },
}));

type Item = { id: string; direction: 'in' | 'out'; channel: string; subject: string; body: string | null; reference: string | null; occurred_at: string };
let items: Item[];
let loadError: { message: string } | null;
let chainCalls: Array<[string, unknown[]]>;

function builder() {
  const chain: Record<string, unknown> = {};
  for (const m of ['select', 'eq', 'order']) chain[m] = vi.fn((...args: unknown[]) => { chainCalls.push([m, args]); return chain; });
  (chain as { then: unknown }).then = (resolve: (v: unknown) => void) => resolve({ data: loadError ? null : items, error: loadError });
  return chain;
}

beforeEach(() => {
  vi.clearAllMocks();
  items = [];
  loadError = null;
  chainCalls = [];
  mockFrom.mockImplementation((name: string) => {
    if (name === 'ins_claim_correspondence') return builder();
    throw new Error(`unexpected table ${name}`);
  });
  mockRpc.mockImplementation(async (fn: string, args: Record<string, unknown>) => {
    if (fn === 'ins_log_claim_correspondence') {
      items = [{ id: 'new', direction: args.p_direction as 'in' | 'out', channel: args.p_channel as string, subject: args.p_subject as string,
        body: args.p_body as string | null, reference: args.p_reference as string | null, occurred_at: '2026-06-12T09:30:00Z' }, ...items];
    }
    return { data: { id: 'new' }, error: null };
  });
});

const renderLog = () => render(<ClaimCorrespondence claimId="c1" />);
const logBtn = () => screen.getByRole('button', { name: 'Log' }) as HTMLButtonElement;
const subject = () => screen.getByLabelText('Subject') as HTMLInputElement;

describe('ClaimCorrespondence: display', () => {
  it('asks for this claim\'s entries newest first and shows the empty state', async () => {
    renderLog();
    expect(await screen.findByText('No correspondence logged.')).toBeTruthy();
    expect(chainCalls).toEqual(expect.arrayContaining([['eq', ['claim_id', 'c1']], ['order', ['occurred_at', { ascending: false }]]]));
  });

  it('shows direction, channel, subject, body and reference, with a dash when there is no reference', async () => {
    items = [
      { id: '1', direction: 'in', channel: 'email', subject: 'Insurer acknowledgement', body: 'Claim received, ref to follow', reference: 'BRT/778', occurred_at: '2026-06-12T09:30:00Z' },
      { id: '2', direction: 'out', channel: 'letter', subject: 'Repudiation notice', body: null, reference: null, occurred_at: '2026-06-10T14:05:00Z' },
    ];
    renderLog();
    await screen.findByText('Insurer acknowledgement');
    const row1 = screen.getAllByRole('row').find((r) => r.textContent?.includes('Insurer acknowledgement')) as HTMLElement;
    const row2 = screen.getAllByRole('row').find((r) => r.textContent?.includes('Repudiation notice')) as HTMLElement;
    expect(within(row1).getByText('in')).toBeTruthy();
    expect(within(row1).getByText('email')).toBeTruthy();
    expect(within(row1).getByText('Claim received, ref to follow')).toBeTruthy();
    expect(within(row1).getByText('BRT/778')).toBeTruthy();
    expect(within(row2).getByText('out')).toBeTruthy();
    expect(within(row2).getByText('letter')).toBeTruthy();
    expect(within(row2).getByText('—')).toBeTruthy();
    expect(screen.getAllByRole('row').slice(1)[0]).toBe(row1); // order as returned (newest first)
  });

  // DR-46: the platform business day is Africa/Kampala (UTC+3), so an entry logged at 22:30 UTC
  // belongs to the next day and must show as 01:30 there, not as the UTC day and time.
  it('shows the time on the Kampala business clock', async () => {
    items = [{ id: '1', direction: 'in', channel: 'email', subject: 'Late call', body: null, reference: null, occurred_at: '2026-06-12T22:30:00Z' }];
    renderLog();
    await screen.findByText('Late call');
    expect(screen.getByText('2026-06-13 01:30')).toBeTruthy();
  });

  it('shows a load failure in the card', async () => {
    loadError = { message: 'permission denied for table ins_claim_correspondence' };
    renderLog();
    expect(await screen.findByText('permission denied for table ins_claim_correspondence')).toBeTruthy();
    expect(screen.queryByRole('progressbar')).toBeNull();
  });
});

describe('ClaimCorrespondence: logging', () => {
  it('defaults to an outgoing email and needs a subject before it can log', async () => {
    const user = userEvent.setup();
    renderLog();
    await screen.findByText('No correspondence logged.');
    expect(screen.getByLabelText('Dir').textContent).toBe('Out');
    expect(screen.getByLabelText('Channel').textContent).toBe('Email');
    expect(logBtn().disabled).toBe(true);
    await user.type(subject(), '   ');
    expect(logBtn().disabled).toBe(true); // whitespace is not a subject
    await user.type(subject(), 'Assessor appointed');
    expect(logBtn().disabled).toBe(false);
  });

  it('logs every field through the RPC, resets the form and shows the new entry', async () => {
    const user = userEvent.setup();
    renderLog();
    await screen.findByText('No correspondence logged.');
    await user.click(screen.getByLabelText('Dir'));
    await user.click(await screen.findByRole('option', { name: 'In' }));
    await user.click(screen.getByLabelText('Channel'));
    await user.click(await screen.findByRole('option', { name: 'Phone' }));
    await user.type(subject(), 'Assessor appointed');
    await user.type(screen.getByLabelText('Reference'), 'BRT/901');
    await user.type(screen.getByLabelText('Body'), 'Visit booked for Friday');
    await user.click(logBtn());

    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('ins_log_claim_correspondence', {
      p_claim_id: 'c1', p_direction: 'in', p_channel: 'phone', p_subject: 'Assessor appointed', p_body: 'Visit booked for Friday', p_reference: 'BRT/901',
    }));
    expect(await screen.findByText('Visit booked for Friday')).toBeTruthy(); // reloaded, new entry listed
    await waitFor(() => expect(subject().value).toBe(''));
    expect((screen.getByLabelText('Body') as HTMLInputElement).value).toBe('');
    expect((screen.getByLabelText('Reference') as HTMLInputElement).value).toBe('');
    expect(screen.getByLabelText('Dir').textContent).toBe('Out'); // back to the defaults
    expect(screen.getByLabelText('Channel').textContent).toBe('Email');
    expect(logBtn().disabled).toBe(true);
  });

  it('sends a blank body and reference as null', async () => {
    const user = userEvent.setup();
    renderLog();
    await screen.findByText('No correspondence logged.');
    await user.type(subject(), 'Reminder sent');
    await user.click(logBtn());
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('ins_log_claim_correspondence', {
      p_claim_id: 'c1', p_direction: 'out', p_channel: 'email', p_subject: 'Reminder sent', p_body: null, p_reference: null,
    }));
  });

  it('keeps what was typed and shows the server message when logging is refused', async () => {
    const user = userEvent.setup();
    mockRpc.mockResolvedValueOnce({ data: null, error: { message: 'INS_ACCESS_DENIED: Not allowed' } });
    renderLog();
    await screen.findByText('No correspondence logged.');
    await user.type(subject(), 'Reminder sent');
    await user.type(screen.getByLabelText('Body'), 'Second reminder');
    await user.click(logBtn());
    expect(await screen.findByText('Not allowed')).toBeTruthy();
    expect(subject().value).toBe('Reminder sent');
    expect((screen.getByLabelText('Body') as HTMLInputElement).value).toBe('Second reminder');
    await waitFor(() => expect(logBtn().disabled).toBe(false)); // can retry
  });

  it('disables Log while the write is in flight, so one click logs one entry', async () => {
    const user = userEvent.setup();
    let release: (v: unknown) => void = () => {};
    mockRpc.mockImplementationOnce(() => new Promise((resolve) => { release = resolve; }));
    renderLog();
    await screen.findByText('No correspondence logged.');
    await user.type(subject(), 'Reminder sent');
    await user.click(logBtn());
    await waitFor(() => expect(logBtn().disabled).toBe(true));
    release({ data: { id: 'new' }, error: null });
    await waitFor(() => expect(subject().value).toBe(''));
    expect(mockRpc).toHaveBeenCalledTimes(1);
  });
});
