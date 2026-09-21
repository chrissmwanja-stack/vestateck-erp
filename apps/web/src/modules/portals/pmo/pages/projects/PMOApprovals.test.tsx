import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import { MemoryRouter } from 'react-router-dom';
import PMOApprovals from './PMOApprovals';

// Mirror of ContractApprovals.test for the PMO flow: decisions via the
// decide_pmo_project RPC only, queue limited to pending_approval,
// rejection requires notes before the RPC, self-created projects get
// disabled actions (the RPC enforces it server-side).

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
const OTHER_PROJECT = {
  id: 'p-other',
  project_no: 'PRJ-0002',
  name: 'Drainage upgrade',
  client_name: 'City Council',
  status: 'pending_approval',
  budget: 800000,
  currency: 'UGX',
  created_by: 'u-other',
  created_at: '2026-09-20T00:00:00Z',
  pmo_project_categories: { name: 'Civil' },
};
const MY_PROJECT = { ...OTHER_PROJECT, id: 'p-mine', project_no: 'PRJ-0001', name: 'My own project', created_by: MY_ID };

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
  mockFrom.mockReturnValue(selectChain([MY_PROJECT, OTHER_PROJECT]));
  mockRpc.mockResolvedValue({ data: null, error: null });
});

function renderScreen() {
  return render(
    <MemoryRouter>
      <PMOApprovals />
    </MemoryRouter>,
  );
}

const rowFor = (projectNo: string) =>
  screen.getAllByRole('row').slice(1).find((r) => r.textContent?.includes(projectNo))!;

const buttonsIn = (row: HTMLElement) => Array.from(row.querySelectorAll('button'));

describe('PMOApprovals', () => {
  it('queries only pending_approval projects', async () => {
    renderScreen();
    expect(await screen.findByText('PRJ-0001')).toBeTruthy();
    const from = mockFrom.mock.results[0].value as Record<string, ReturnType<typeof vi.fn>>;
    expect(from.eq).toHaveBeenCalledWith('status', 'pending_approval');
  });

  it('disables Approve/Reject on the current user\'s own submissions', async () => {
    renderScreen();
    await screen.findByText('PRJ-0001');
    const ownApprove = buttonsIn(rowFor('PRJ-0001')).find((b) => b.textContent === 'Approve') as HTMLButtonElement;
    const otherApprove = buttonsIn(rowFor('PRJ-0002')).find((b) => b.textContent === 'Approve') as HTMLButtonElement;
    expect(ownApprove.disabled).toBe(true);
    expect(otherApprove.disabled).toBe(false);
  });

  it('approves via decide_pmo_project and removes the row on success', async () => {
    const user = userEvent.setup();
    renderScreen();
    await screen.findByText('PRJ-0002');
    await user.click(buttonsIn(rowFor('PRJ-0002')).find((b) => b.textContent === 'Approve')!);
    await user.type(await screen.findByLabelText(/Notes/), 'Budget ok');
    await user.click(screen.getByRole('button', { name: 'Approve & start' }));
    await waitFor(() =>
      expect(mockRpc).toHaveBeenCalledWith('decide_pmo_project', {
        p_project_id: 'p-other',
        p_decision: 'approved',
        p_notes: 'Budget ok',
      }),
    );
    await waitFor(() => expect(screen.queryByText('PRJ-0002')).toBeNull());
  });

  it('requires a rejection reason before calling the RPC', async () => {
    const user = userEvent.setup();
    renderScreen();
    await screen.findByText('PRJ-0002');
    await user.click(buttonsIn(rowFor('PRJ-0002')).find((b) => b.textContent === 'Reject')!);
    await user.click(screen.getByRole('button', { name: 'Reject' }));
    expect(await screen.findByText('A rejection reason is required.')).toBeTruthy();
    expect(mockRpc).not.toHaveBeenCalled();
    await user.type(screen.getByLabelText(/Rejection reason/), 'Rescope');
    await user.click(screen.getByRole('button', { name: 'Reject' }));
    await waitFor(() =>
      expect(mockRpc).toHaveBeenCalledWith('decide_pmo_project', {
        p_project_id: 'p-other',
        p_decision: 'rejected',
        p_notes: 'Rescope',
      }),
    );
  });

  it('shows the RPC error and keeps the row queued', async () => {
    mockRpc.mockResolvedValue({ data: null, error: { message: 'you cannot decide a project you created' } });
    const user = userEvent.setup();
    renderScreen();
    await screen.findByText('PRJ-0002');
    await user.click(buttonsIn(rowFor('PRJ-0002')).find((b) => b.textContent === 'Approve')!);
    await user.click(screen.getByRole('button', { name: 'Approve & start' }));
    expect(await screen.findByText(/cannot decide a project you created/)).toBeTruthy();
    expect(screen.getByText('PRJ-0002')).toBeTruthy();
  });
});
