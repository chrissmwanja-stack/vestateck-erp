import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import { MemoryRouter } from 'react-router-dom';
import ContractApprovals from './ContractApprovals';

// Coverage for the 2026-09-21 workflow rebuild: decisions must go through
// the decide_contract RPC (never a direct table update), the queue shows
// only pending_approval rows, rejection requires notes client-side before
// the RPC is even attempted, and a contract's creator gets disabled
// action buttons (the RPC enforces the same separation server-side).

const mockFrom = vi.fn();
const mockRpc = vi.fn();
vi.mock('../../../../../lib/supabaseClient', () => ({
  supabase: {
    from: (...args: unknown[]) => mockFrom(...args),
    rpc: (...args: unknown[]) => mockRpc(...args),
  },
}));

const mockUseAuth = vi.fn();
vi.mock('../../../../../lib/authContext', () => ({
  useAuth: () => mockUseAuth(),
}));

const MY_ID = 'u-me';
const OTHER_CONTRACT = {
  id: 'c-other',
  contract_no: 'LAW-C-0002',
  title: 'Supply agreement',
  party_name: 'Acme Ltd',
  status: 'pending_approval',
  value: 1200000,
  currency: 'UGX',
  created_by: 'u-other',
  created_at: '2026-09-20T00:00:00Z',
  law_contract_types: { name: 'Supplier' },
};
const MY_CONTRACT = {
  ...OTHER_CONTRACT,
  id: 'c-mine',
  contract_no: 'LAW-C-0001',
  title: 'My own draft',
  created_by: MY_ID,
};

function selectChain(rows: unknown[]) {
  const chain: Record<string, unknown> = {};
  for (const m of ['select', 'eq', 'order']) chain[m] = vi.fn(() => chain);
  (chain as { then: unknown }).then = (resolve: (v: unknown) => void) =>
    resolve({ data: rows, error: null });
  return chain;
}

beforeEach(() => {
  vi.clearAllMocks();
  mockUseAuth.mockReturnValue({ session: { user: { id: MY_ID, user_metadata: {} } } });
  mockFrom.mockReturnValue(selectChain([MY_CONTRACT, OTHER_CONTRACT]));
  mockRpc.mockResolvedValue({ data: null, error: null });
});

function renderScreen() {
  return render(
    <MemoryRouter>
      <ContractApprovals />
    </MemoryRouter>,
  );
}

describe('ContractApprovals', () => {
  it('lists only pending_approval contracts (query is status-filtered)', async () => {
    renderScreen();
    expect(await screen.findByText('LAW-C-0001')).toBeTruthy();
    expect(screen.getByText('LAW-C-0002')).toBeTruthy();
    const from = mockFrom.mock.results[0].value as Record<string, ReturnType<typeof vi.fn>>;
    expect(from.eq).toHaveBeenCalledWith('status', 'pending_approval');
  });

  it('disables Approve/Reject on contracts the current user created', async () => {
    renderScreen();
    await screen.findByText('LAW-C-0001');
    const rows = screen.getAllByRole('row').slice(1); // skip header
    const mine = rows.find((r) => r.textContent?.includes('LAW-C-0001'))!;
    const other = rows.find((r) => r.textContent?.includes('LAW-C-0002'))!;
    const mineApprove = mine.querySelector('button[color="success"], button') as HTMLButtonElement;
    const buttons = (row: HTMLElement) => Array.from(row.querySelectorAll('button')).map((b) => b.textContent);
    expect(buttons(mine)).toContain('Approve');
    const myApproveBtn = Array.from(mine.querySelectorAll('button')).find((b) => b.textContent === 'Approve')!;
    expect((myApproveBtn as HTMLButtonElement).disabled).toBe(true);
    const otherApproveBtn = Array.from(other.querySelectorAll('button')).find((b) => b.textContent === 'Approve')!;
    expect((otherApproveBtn as HTMLButtonElement).disabled).toBe(false);
    expect(mineApprove).toBeTruthy();
  });

  it('approves another user\'s contract via the decide_contract RPC and removes the row', async () => {
    const user = userEvent.setup();
    renderScreen();
    await screen.findByText('LAW-C-0002');
    const rows = screen.getAllByRole('row').slice(1);
    const other = rows.find((r) => r.textContent?.includes('LAW-C-0002'))!;
    await user.click(Array.from(other.querySelectorAll('button')).find((b) => b.textContent === 'Approve')!);
    await user.type(await screen.findByLabelText(/Notes/), 'Looks fine');
    await user.click(screen.getByRole('button', { name: 'Approve & activate' }));
    await waitFor(() =>
      expect(mockRpc).toHaveBeenCalledWith('decide_contract', {
        p_contract_id: 'c-other',
        p_decision: 'approved',
        p_notes: 'Looks fine',
      }),
    );
    await waitFor(() => expect(screen.queryByText('LAW-C-0002')).toBeNull());
  });

  it('blocks an empty rejection reason client-side before any RPC call', async () => {
    const user = userEvent.setup();
    renderScreen();
    await screen.findByText('LAW-C-0002');
    const rows = screen.getAllByRole('row').slice(1);
    const other = rows.find((r) => r.textContent?.includes('LAW-C-0002'))!;
    await user.click(Array.from(other.querySelectorAll('button')).find((b) => b.textContent === 'Reject')!);
    await user.click(screen.getByRole('button', { name: 'Reject' }));
    expect(await screen.findByText('A rejection reason is required.')).toBeTruthy();
    expect(mockRpc).not.toHaveBeenCalled();
    await user.type(screen.getByLabelText(/Rejection reason/), 'Missing clause');
    await user.click(screen.getByRole('button', { name: 'Reject' }));
    await waitFor(() =>
      expect(mockRpc).toHaveBeenCalledWith('decide_contract', {
        p_contract_id: 'c-other',
        p_decision: 'rejected',
        p_notes: 'Missing clause',
      }),
    );
  });

  it('surfaces RPC errors instead of swallowing them', async () => {
    mockRpc.mockResolvedValue({ data: null, error: { message: 'you cannot decide a contract you created' } });
    const user = userEvent.setup();
    renderScreen();
    await screen.findByText('LAW-C-0002');
    const rows = screen.getAllByRole('row').slice(1);
    const other = rows.find((r) => r.textContent?.includes('LAW-C-0002'))!;
    await user.click(Array.from(other.querySelectorAll('button')).find((b) => b.textContent === 'Approve')!);
    await user.click(screen.getByRole('button', { name: 'Approve & activate' }));
    expect(await screen.findByText(/cannot decide a contract you created/)).toBeTruthy();
    expect(screen.getByText('LAW-C-0002')).toBeTruthy(); // row stays in the queue
  });
});
