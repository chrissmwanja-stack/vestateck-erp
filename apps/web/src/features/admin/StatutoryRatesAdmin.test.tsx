import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import StatutoryRatesAdmin from './StatutoryRatesAdmin';

// This screen closes a real gap: seed_statutory_rate_table() and direct
// inserts into statutory_rate_tables (20260904090500_payroll_paye_nssf_workstream_f.sql)
// had no UI at all -- calculate_statutory_deductions() would silently
// return zeros for every tenant until someone ran the RPC by hand via
// SQL/API. Covers both the seed path (RPC) and the manual add-a-row
// path (direct table insert, for correcting a single band without
// reseeding everything), plus that the PAYE-uncertainty warning is
// actually rendered -- that warning is the whole point of this screen
// existing rather than just calling seed_statutory_rate_table() blind.

const mockFrom = vi.fn();
const mockRpc = vi.fn();
vi.mock('../../lib/supabaseClient', () => ({
  supabase: {
    from: (...args: unknown[]) => mockFrom(...args),
    rpc: (...args: unknown[]) => mockRpc(...args),
  },
}));

const mockUseAuth = vi.fn();
vi.mock('../../lib/authContext', () => ({
  useAuth: () => mockUseAuth(),
}));

const PAYE_BAND_1 = {
  id: 'r1',
  rate_type: 'paye',
  effective_date: '2026-09-01',
  band_order: 1,
  lower_bound: 0,
  upper_bound: 335000,
  rate: 0,
  base_tax: 0,
};

const NSSF_EMPLOYEE = {
  id: 'r2',
  rate_type: 'nssf_employee',
  effective_date: '2026-09-01',
  band_order: 1,
  lower_bound: 0,
  upper_bound: null,
  rate: 5,
  base_tax: 0,
};

function setupFromMock(opts: { rows?: unknown[]; insertError?: { message: string } | null; appUserTenantId?: string | null } = {}) {
  const { rows = [], insertError = null, appUserTenantId = 't1' } = opts;
  const calls = { inserts: [] as unknown[], selectCount: 0 };

  mockFrom.mockImplementation((table: string) => {
    if (table === 'statutory_rate_tables') {
      return {
        select: () => ({
          order: () => ({
            order: () => ({
              order: () => {
                calls.selectCount++;
                return Promise.resolve({ data: rows, error: null });
              },
            }),
          }),
        }),
        insert: (payload: unknown) => {
          calls.inserts.push(payload);
          return Promise.resolve({ error: insertError });
        },
      };
    }
    if (table === 'app_users') {
      return {
        select: () => ({
          eq: () => ({
            single: () => Promise.resolve({ data: appUserTenantId ? { tenant_id: appUserTenantId } : null, error: null }),
          }),
        }),
      };
    }
    throw new Error(`setupFromMock: no handler for table "${table}"`);
  });

  return calls;
}

beforeEach(() => {
  mockFrom.mockReset();
  mockRpc.mockReset();
  mockUseAuth.mockReturnValue({ session: { user: { id: 'u1' } } });
});

describe('StatutoryRatesAdmin', () => {
  it('shows the PAYE-uncertainty warning regardless of whether rates exist', async () => {
    setupFromMock({ rows: [] });
    render(<StatutoryRatesAdmin />);

    await waitFor(() => expect(screen.getByText(/No rate rows yet/)).toBeInTheDocument());
    expect(screen.getByText(/not confirmed against an authoritative source/)).toBeInTheDocument();
  });

  it('empty state offers to seed starter rates, and calls the RPC with the chosen date', async () => {
    const user = userEvent.setup();
    setupFromMock({ rows: [] });
    mockRpc.mockResolvedValue({ error: null });

    render(<StatutoryRatesAdmin />);

    await waitFor(() => expect(screen.getByRole('button', { name: /Seed Starter Rates/ })).toBeInTheDocument());
    await user.click(screen.getByRole('button', { name: /Seed Starter Rates/ }));

    // Confirmation dialog opens with today's date pre-filled.
    const dialog = await screen.findByRole('dialog');
    await user.click(within(dialog).getByRole('button', { name: /Seed Starter Rates/ }));

    await waitFor(() =>
      expect(mockRpc).toHaveBeenCalledWith('seed_statutory_rate_table', expect.objectContaining({ p_effective_date: expect.any(String) }))
    );
  });

  it('lists existing PAYE and NSSF rows with formatted bounds', async () => {
    setupFromMock({ rows: [PAYE_BAND_1, NSSF_EMPLOYEE] });
    render(<StatutoryRatesAdmin />);

    await waitFor(() => expect(screen.getByText('PAYE')).toBeInTheDocument());
    expect(screen.getByText('NSSF (Employee)')).toBeInTheDocument();

    const payeRow = screen.getByText('PAYE').closest('tr') as HTMLElement;
    expect(within(payeRow).getByText('UGX 335,000')).toBeInTheDocument();

    const nssfRow = screen.getByText('NSSF (Employee)').closest('tr') as HTMLElement;
    expect(within(nssfRow).getByText('5%')).toBeInTheDocument();
    expect(within(nssfRow).getAllByText('—').length).toBeGreaterThan(0); // flat rate, no band/bounds
  });

  it('does not offer "Seed Starter Rates" once rows already exist', async () => {
    setupFromMock({ rows: [PAYE_BAND_1] });
    render(<StatutoryRatesAdmin />);

    await waitFor(() => expect(screen.getByText('PAYE')).toBeInTheDocument());
    expect(screen.queryByRole('button', { name: /Seed Starter Rates/ })).not.toBeInTheDocument();
  });

  it('manually adding a row resolves tenant_id and inserts the typed values', async () => {
    const user = userEvent.setup();
    const calls = setupFromMock({ rows: [], appUserTenantId: 'tenant-42' });

    render(<StatutoryRatesAdmin />);
    await waitFor(() => expect(screen.getByText(/No rate rows yet/)).toBeInTheDocument());

    await user.click(screen.getByRole('button', { name: 'Add Rate Row' }));
    await user.clear(screen.getByLabelText('Rate (%)'));
    await user.type(screen.getByLabelText('Rate (%)'), '25');

    await user.click(screen.getByRole('button', { name: 'Save' }));

    await waitFor(() => expect(calls.inserts).toHaveLength(1));
    const inserted = calls.inserts[0] as Record<string, unknown>;
    expect(inserted.tenant_id).toBe('tenant-42');
    expect(inserted.rate_type).toBe('paye');
    expect(inserted.rate).toBe(25);
  });

  it('blocks save with no rate entered', async () => {
    const user = userEvent.setup();
    const calls = setupFromMock({ rows: [] });

    render(<StatutoryRatesAdmin />);
    await waitFor(() => expect(screen.getByText(/No rate rows yet/)).toBeInTheDocument());

    await user.click(screen.getByRole('button', { name: 'Add Rate Row' }));
    await user.click(screen.getByRole('button', { name: 'Save' }));

    expect(await screen.findByText('Rate is required.')).toBeInTheDocument();
    expect(calls.inserts).toHaveLength(0);
  });
});