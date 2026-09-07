import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import DelegationManager from './DelegationManager';

// A delegate's authority is capped at what the delegator personally holds,
// so the client-side logic worth pinning down here (the grant_delegation
// RPC enforces the cap itself server-side): the embedded-select-fails
// fallback to two flat queries for "which stages do I hold" (PostgREST FK
// embedding can fall through depending on schema-cache state), the
// "All stages I hold" -> no-stage-filter mapping on submit, the grant-form
// validation gate, and the active/expired/revoked status logic that
// decides whether a Revoke button shows at all.

const USER_ID = 'me1';

const COLLEAGUE_A = { id: 'u2', name: 'Amina', email: 'amina@x.com', role_title: 'Cost Control Manager' };
const COLLEAGUE_B = { id: 'u3', name: 'Bosco', email: 'bosco@x.com', role_title: 'Budget Controller' };
const STAGE_A = { id: 's1', name: 'Cost Control Manager' };

const mockFrom = vi.fn();
const mockRpc = vi.fn();

vi.mock('../../lib/supabaseClient', () => ({
  supabase: {
    from: (table: string) => mockFrom(table),
    rpc: (...args: [string, unknown?]) => mockRpc(...args),
  },
}));

function setup(opts: {
  colleagues?: unknown[];
  assignmentsEmbedded?: unknown[];
  assignErr?: { message: string } | null;
  fallbackAssignments?: unknown[];
  fallbackStages?: unknown[];
  granted?: unknown[];
  received?: unknown[];
  grantError?: { message: string } | null;
  revokeError?: { message: string } | null;
} = {}) {
  const {
    colleagues = [COLLEAGUE_A, COLLEAGUE_B],
    assignmentsEmbedded = [{ workflow_stage_id: 's1', workflow_stages: STAGE_A }],
    assignErr = null,
    fallbackAssignments = [],
    fallbackStages = [],
    granted = [],
    received = [],
    grantError = null,
    revokeError = null,
  } = opts;

  const revokeCalls: string[] = [];

  mockFrom.mockImplementation((table: string) => {
    if (table === 'app_users') {
      return { select: () => ({ neq: () => Promise.resolve({ data: colleagues, error: null }) }) };
    }
    if (table === 'approval_assignments') {
      return {
        select: (cols: string) => ({
          eq: () => {
            if (cols.includes('workflow_stages(')) {
              return Promise.resolve({ data: assignmentsEmbedded, error: assignErr });
            }
            return Promise.resolve({ data: fallbackAssignments, error: null });
          },
        }),
      };
    }
    if (table === 'workflow_stages') {
      return { select: () => ({ in: () => Promise.resolve({ data: fallbackStages, error: null }) }) };
    }
    if (table === 'approval_delegations') {
      return {
        select: () => ({
          eq: (col: string) => ({
            order: () =>
              Promise.resolve({
                data: col === 'delegator_user_id' ? granted : received,
                error: null,
              }),
          }),
        }),
        update: () => ({
          eq: (_col: string, id: string) => {
            revokeCalls.push(id);
            return Promise.resolve({ error: revokeError });
          },
        }),
      };
    }
    throw new Error(`setup: no handler for table "${table}"`);
  });

  mockRpc.mockImplementation((fnName: string, params?: unknown) => {
    if (fnName === 'grant_delegation') return Promise.resolve({ data: null, error: grantError, params });
    throw new Error(`unhandled rpc: ${fnName}`);
  });

  return { revokeCalls };
}

beforeEach(() => {
  mockFrom.mockReset();
  mockRpc.mockReset();
});

async function pickDelegate(user: ReturnType<typeof userEvent.setup>, name: string) {
  await user.click(screen.getByLabelText('Delegate to'));
  await user.click(await screen.findByRole('option', { name: new RegExp(name) }));
}

describe('DelegationManager', () => {
  it('shows a no-assignments notice and disables the grant form when the user holds no stages', async () => {
    setup({ assignmentsEmbedded: [] });

    render(<DelegationManager userId={USER_ID} />);

    await waitFor(() =>
      expect(
        screen.getByText(/you don't currently hold any approval assignments/i)
      ).toBeInTheDocument()
    );
    expect(screen.getByLabelText('Delegate to')).toBeDisabled();
    expect(screen.getByRole('button', { name: /grant delegation/i })).toBeDisabled();
  });

  it('loads stage options from the embedded assignments query when it succeeds', async () => {
    setup();

    render(<DelegationManager userId={USER_ID} />);

    await waitFor(() => expect(screen.getByRole('button', { name: /grant delegation/i })).toBeEnabled());
    await userEvent.setup().click(screen.getByLabelText('Stage'));
    expect(await screen.findByRole('option', { name: 'Cost Control Manager' })).toBeInTheDocument();
    expect(screen.getByRole('option', { name: 'All stages I hold' })).toBeInTheDocument();
  });

  it('falls back to two flat queries when the embedded assignments select errors', async () => {
    setup({
      assignmentsEmbedded: [],
      assignErr: { message: 'could not embed workflow_stages' },
      fallbackAssignments: [{ workflow_stage_id: 's1' }],
      fallbackStages: [STAGE_A],
    });

    render(<DelegationManager userId={USER_ID} />);

    await waitFor(() => expect(screen.getByRole('button', { name: /grant delegation/i })).toBeEnabled());
    await userEvent.setup().click(screen.getByLabelText('Stage'));
    expect(await screen.findByRole('option', { name: 'Cost Control Manager' })).toBeInTheDocument();
  });

  it('requires a delegate before granting', async () => {
    setup();
    const user = userEvent.setup();
    render(<DelegationManager userId={USER_ID} />);
    await waitFor(() => expect(screen.getByRole('button', { name: /grant delegation/i })).toBeEnabled());

    await user.click(screen.getByRole('button', { name: /grant delegation/i }));

    expect(screen.getByText("Pick who you're delegating to.")).toBeInTheDocument();
    expect(mockRpc).not.toHaveBeenCalled();
  });

  it('requires an end date/time', async () => {
    setup();
    const user = userEvent.setup();
    render(<DelegationManager userId={USER_ID} />);
    await waitFor(() => expect(screen.getByRole('button', { name: /grant delegation/i })).toBeEnabled());

    await pickDelegate(user, 'Amina');
    // The Ends field is `required`, so MUI appends a hidden "*" to its
    // label ("Ends *") -- match loosely rather than the exact string.
    await user.clear(screen.getByLabelText(/^Ends/));
    await user.click(screen.getByRole('button', { name: /grant delegation/i }));

    expect(screen.getByText('An end date/time is required.')).toBeInTheDocument();
    expect(mockRpc).not.toHaveBeenCalled();
  });

  it('grants a delegation with no stage filter when "All stages I hold" is left selected', async () => {
    setup();
    const user = userEvent.setup();
    render(<DelegationManager userId={USER_ID} />);
    await waitFor(() => expect(screen.getByRole('button', { name: /grant delegation/i })).toBeEnabled());

    await pickDelegate(user, 'Amina');
    await user.click(screen.getByRole('button', { name: /grant delegation/i }));

    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('grant_delegation', expect.any(Object)));
    const params = mockRpc.mock.calls[0][1] as Record<string, unknown>;
    expect(params.p_delegate_user_id).toBe('u2');
    expect(params.p_workflow_stage_id).toBeUndefined();
    expect(screen.getByText('Delegation granted to Amina.')).toBeInTheDocument();
  });

  it('grants a delegation scoped to a specific stage when one is chosen', async () => {
    setup();
    const user = userEvent.setup();
    render(<DelegationManager userId={USER_ID} />);
    await waitFor(() => expect(screen.getByRole('button', { name: /grant delegation/i })).toBeEnabled());

    await pickDelegate(user, 'Amina');
    await user.click(screen.getByLabelText('Stage'));
    await user.click(await screen.findByRole('option', { name: 'Cost Control Manager' }));
    await user.click(screen.getByRole('button', { name: /grant delegation/i }));

    await waitFor(() => expect(mockRpc).toHaveBeenCalled());
    const params = mockRpc.mock.calls[0][1] as Record<string, unknown>;
    expect(params.p_workflow_stage_id).toBe('s1');
  });

  it('shows the RPC error message and leaves the form filled in on failure', async () => {
    setup({ grantError: { message: 'delegate already has an active delegation for this stage' } });
    const user = userEvent.setup();
    render(<DelegationManager userId={USER_ID} />);
    await waitFor(() => expect(screen.getByRole('button', { name: /grant delegation/i })).toBeEnabled());

    await pickDelegate(user, 'Amina');
    await user.click(screen.getByRole('button', { name: /grant delegation/i }));

    await waitFor(() =>
      expect(
        screen.getByText('delegate already has an active delegation for this stage')
      ).toBeInTheDocument()
    );
    expect(screen.queryByText(/delegation granted to/i)).not.toBeInTheDocument();
  });

  it('shows Revoke only for a delegation that is active and not yet ended, not for expired or revoked ones', async () => {
    const future = new Date(Date.now() + 86_400_000).toISOString();
    const past = new Date(Date.now() - 86_400_000).toISOString();
    setup({
      granted: [
        { id: 'd1', delegator_user_id: USER_ID, delegate_user_id: 'u2', workflow_stage_id: null, starts_at: past, ends_at: future, status: 'active', created_at: past },
        { id: 'd2', delegator_user_id: USER_ID, delegate_user_id: 'u3', workflow_stage_id: null, starts_at: past, ends_at: past, status: 'active', created_at: past },
        { id: 'd3', delegator_user_id: USER_ID, delegate_user_id: 'u3', workflow_stage_id: null, starts_at: past, ends_at: future, status: 'revoked', created_at: past },
      ],
    });

    render(<DelegationManager userId={USER_ID} />);

    const activeRow = (await screen.findByText('Amina')).closest('tr') as HTMLElement;
    expect(within(activeRow).getByText('Active')).toBeInTheDocument();
    expect(within(activeRow).getByRole('button', { name: /revoke/i })).toBeInTheDocument();

    const rows = screen.getAllByText('Bosco').map((el) => el.closest('tr') as HTMLElement);
    const expiredRow = rows.find((r) => within(r).queryByText('Expired'));
    const revokedRow = rows.find((r) => within(r).queryByText('Revoked'));
    expect(expiredRow).toBeTruthy();
    expect(revokedRow).toBeTruthy();
    expect(within(expiredRow!).queryByRole('button', { name: /revoke/i })).not.toBeInTheDocument();
    expect(within(revokedRow!).queryByRole('button', { name: /revoke/i })).not.toBeInTheDocument();
  });

  it('revokes a delegation via a status update when Revoke is clicked', async () => {
    const future = new Date(Date.now() + 86_400_000).toISOString();
    const { revokeCalls } = setup({
      granted: [
        { id: 'd1', delegator_user_id: USER_ID, delegate_user_id: 'u2', workflow_stage_id: null, starts_at: future, ends_at: future, status: 'active', created_at: future },
      ],
    });
    const user = userEvent.setup();

    render(<DelegationManager userId={USER_ID} />);
    await screen.findByText('Amina');

    await user.click(screen.getByRole('button', { name: /revoke/i }));

    await waitFor(() => expect(revokeCalls).toEqual(['d1']));
  });

  it('resolves the delegator name on the received table via the colleague list', async () => {
    const future = new Date(Date.now() + 86_400_000).toISOString();
    setup({
      received: [
        { id: 'd9', delegator_user_id: 'u2', delegate_user_id: USER_ID, workflow_stage_id: null, starts_at: future, ends_at: future, status: 'active', created_at: future },
      ],
    });

    render(<DelegationManager userId={USER_ID} />);

    expect(await screen.findByText('Amina')).toBeInTheDocument();
    expect(screen.queryByText('No one has delegated approval authority to you.')).not.toBeInTheDocument();
  });
});