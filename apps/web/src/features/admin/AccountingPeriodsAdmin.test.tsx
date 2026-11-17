import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import AccountingPeriodsAdmin from './AccountingPeriodsAdmin';

// AccountingPeriodsAdmin lists periods and closes/reopens them. Since
// migration 20261117130000 those transitions go through the
// fin_close_accounting_period / fin_reopen_accounting_period RPCs rather than
// a table UPDATE -- direct UPDATE/DELETE on accounting_periods is revoked so a
// reopen cannot happen without a reason, a second finance user and an audit
// row. This pins down: the RPC being used (not .update()), the client-side
// reason guard, and that a server rejection (e.g. SEGREGATION_OF_DUTIES) is
// surfaced rather than swallowed.

const OPEN_PERIOD = {
  id: 'p-open',
  period_start: '2027-01-01',
  period_end: '2027-01-31',
  status: 'open',
  closed_at: null,
  closed_by: null,
};

const CLOSED_PERIOD = {
  id: 'p-closed',
  period_start: '2026-12-01',
  period_end: '2026-12-31',
  status: 'closed',
  closed_at: '2027-01-02T10:00:00Z',
  closed_by: 'u-1',
};

let calls: { rpc: [string, Record<string, unknown>][] };
let mockRpcRef: ReturnType<typeof setup>['mockRpc'];

vi.mock('../../lib/supabaseClient', () => ({
  supabase: {
    from: () => {
      const builder: any = {
        select: () => builder,
        order: () => builder,
        then: (resolve: (v: { data: unknown; error: unknown }) => void) =>
          resolve({ data: periods, error: null }),
      };
      return builder;
    },
    rpc: (fn: string, args: Record<string, unknown>) => mockRpcRef(fn, args),
  },
}));

vi.mock('../../lib/authContext', () => ({
  useAuth: () => ({ session: { user: { id: 'u-1' } } }),
}));

vi.mock('../../lib/ResolveTenantId', () => ({
  resolveTenantId: () => Promise.resolve({ ok: true, tenantId: 't-1' }),
}));

let periods: unknown[] = [OPEN_PERIOD, CLOSED_PERIOD];

function setup(opts: { rpcError?: { message: string } | null } = {}) {
  const { rpcError = null } = opts;
  calls = { rpc: [] };
  const mockRpc = vi.fn((fn: string, args: Record<string, unknown>) => {
    calls.rpc.push([fn, args]);
    return Promise.resolve({ data: null, error: rpcError });
  });
  return { mockRpc };
}

function activate(r: ReturnType<typeof setup>) {
  mockRpcRef = r.mockRpc;
}

beforeEach(() => {
  periods = [OPEN_PERIOD, CLOSED_PERIOD];
  vi.clearAllMocks();
});

describe('AccountingPeriodsAdmin', () => {
  it('lists periods', async () => {
    activate(setup());
    render(<AccountingPeriodsAdmin />);
    expect(await screen.findByText('2027-01-01')).toBeInTheDocument();
    expect(screen.getByText('2026-12-01')).toBeInTheDocument();
  });

  it('closes an open period through the RPC, not a table update', async () => {
    activate(setup());
    render(<AccountingPeriodsAdmin />);
    await screen.findByText('2027-01-01');

    await userEvent.click(screen.getAllByRole('button', { name: 'Close' })[0]);
    await userEvent.click(await screen.findByRole('button', { name: 'Close Period' }));

    await waitFor(() => expect(calls.rpc).toHaveLength(1));
    expect(calls.rpc[0][0]).toBe('fin_close_accounting_period');
    expect(calls.rpc[0][1]).toEqual({ p_period_id: 'p-open' });
  });

  it('refuses to reopen without a reason, without calling the server', async () => {
    activate(setup());
    render(<AccountingPeriodsAdmin />);
    await screen.findByText('2026-12-01');

    await userEvent.click(screen.getByRole('button', { name: 'Reopen' }));
    await userEvent.click(await screen.findByRole('button', { name: 'Reopen Period' }));

    expect(
      await screen.findByText(/A reason of at least 10 characters is required/)
    ).toBeInTheDocument();
    expect(calls.rpc).toHaveLength(0);
  });

  it('reopens with the reason once one is supplied', async () => {
    activate(setup());
    render(<AccountingPeriodsAdmin />);
    await screen.findByText('2026-12-01');

    await userEvent.click(screen.getByRole('button', { name: 'Reopen' }));
    const reason = await screen.findByLabelText(/Reason for reopening/);
    await userEvent.type(reason, 'late supplier invoice arrived after close');
    await userEvent.click(screen.getByRole('button', { name: 'Reopen Period' }));

    await waitFor(() => expect(calls.rpc).toHaveLength(1));
    expect(calls.rpc[0][0]).toBe('fin_reopen_accounting_period');
    expect(calls.rpc[0][1]).toEqual({
      p_period_id: 'p-closed',
      p_reason: 'late supplier invoice arrived after close',
    });
  });

  it('surfaces a server-side segregation-of-duties rejection instead of swallowing it', async () => {
    activate(
      setup({
        rpcError: {
          message:
            'SEGREGATION_OF_DUTIES: a closed accounting period must be reopened by a different finance user than the one who closed it',
        },
      })
    );
    render(<AccountingPeriodsAdmin />);
    await screen.findByText('2026-12-01');

    await userEvent.click(screen.getByRole('button', { name: 'Reopen' }));
    const reason = await screen.findByLabelText(/Reason for reopening/);
    await userEvent.type(reason, 'attempting to reopen my own close');
    await userEvent.click(screen.getByRole('button', { name: 'Reopen Period' }));

    expect(await screen.findByText(/SEGREGATION_OF_DUTIES/)).toBeInTheDocument();
  });
});
