import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import MaterialCatalogAdmin from './MaterialCatalogAdmin';

// Regression coverage for a real bug: "New material" sent tenant_id: ''
// on create (a comment claimed a BEFORE INSERT trigger filled it, but
// that trigger -- and the table's INSERT RLS policy -- didn't survive
// the 2026-08-19 migration squash; see
// 20260822120000_material_catalog_insert_policy.sql). The fix resolves
// tenant_id client-side via app_users on create, the same pattern
// AccountsAdmin.tsx/EmployeesList.tsx already use, and never touches
// app_users on edit (tenant_id is immutable after creation). This file
// asserts both halves directly: the real tenant_id reaches the insert
// payload, and update never queries app_users at all.
//
// This screen queries four different tables (material_catalog,
// material_types, material_groups, app_users) plus useAuth() for the
// session, so it's mocked with a bespoke per-table dispatcher below
// rather than the single-table lookupAdminHarness.

const mockFrom = vi.fn();
vi.mock('../../lib/supabaseClient', () => ({
  supabase: { from: (...args: unknown[]) => mockFrom(...args) },
}));

const mockUseAuth = vi.fn();
vi.mock('../../lib/authContext', () => ({
  useAuth: () => mockUseAuth(),
}));

const mockAmIFinance = vi.fn();
vi.mock('../../lib/supabaseClient', () => ({
  supabase: {
    from: (...args: unknown[]) => mockFrom(...args),
    rpc: (...args: unknown[]) => mockAmIFinance(...args),
  },
}));

const TYPE_A = { id: 'ty1', code: 'CON', name: 'Consumable' };
const GROUP_A = { id: 'gr1', code: 'GEN', name: 'General' };

const MATERIAL_A = {
  id: 'm1',
  code: 'MAT-001',
  name: 'Cement',
  unit: 'Bag',
  old_material_code: null,
  is_active: true,
  created_at: '2026-08-01T00:00:00Z',
  material_type_id: 'ty1',
  material_group_id: 'gr1',
  material_type: { name: 'Consumable' },
  material_group: { name: 'General' },
};

function setupFromMock(opts: {
  materialRows?: unknown[];
  insertError?: { message: string } | null;
  updateError?: { message: string } | null;
  appUserTenantId?: string | null;
  appUserError?: { message: string } | null;
} = {}) {
  const {
    materialRows = [],
    insertError = null,
    updateError = null,
    appUserTenantId = 't1',
    appUserError = null,
  } = opts;

  const calls = {
    inserts: [] as unknown[],
    updates: [] as Array<{ payload: unknown; id: string }>,
    appUsersQueried: 0,
  };

  mockFrom.mockImplementation((table: string) => {
    if (table === 'material_catalog') {
      return {
        select: () => ({
          order: () => Promise.resolve({ data: materialRows, error: null }),
        }),
        insert: (payload: unknown) => {
          calls.inserts.push(payload);
          return Promise.resolve({ error: insertError });
        },
        update: (payload: unknown) => ({
          eq: (_col: string, id: string) => {
            calls.updates.push({ payload, id });
            return Promise.resolve({ error: updateError });
          },
        }),
      };
    }
    if (table === 'material_types') {
      return { select: () => ({ eq: () => ({ order: () => Promise.resolve({ data: [TYPE_A], error: null }) }) }) };
    }
    if (table === 'material_groups') {
      return { select: () => ({ eq: () => ({ order: () => Promise.resolve({ data: [GROUP_A], error: null }) }) }) };
    }
    if (table === 'app_users') {
      return {
        select: () => ({
          eq: () => ({
            single: () => {
              calls.appUsersQueried++;
              return Promise.resolve({
                data: appUserTenantId ? { tenant_id: appUserTenantId } : null,
                error: appUserError,
              });
            },
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
  mockUseAuth.mockReturnValue({ session: { user: { id: 'u1' } } });
});

describe('MaterialCatalogAdmin', () => {
  it('hides New material and the Actions column when am_i_finance resolves false', async () => {
    mockAmIFinance.mockResolvedValue({ data: false, error: null });
    setupFromMock({ materialRows: [MATERIAL_A] });

    render(<MaterialCatalogAdmin />);

    await waitFor(() => expect(screen.getByText('Cement')).toBeInTheDocument());
    expect(screen.queryByRole('button', { name: 'New material' })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Edit' })).not.toBeInTheDocument();
  });

  it('lists materials with their joined type and group names', async () => {
    mockAmIFinance.mockResolvedValue({ data: true, error: null });
    setupFromMock({ materialRows: [MATERIAL_A] });

    render(<MaterialCatalogAdmin />);

    await waitFor(() => expect(screen.getByText('Cement')).toBeInTheDocument());
    const row = screen.getByText('Cement').closest('tr') as HTMLElement;
    expect(within(row).getByText('MAT-001')).toBeInTheDocument();
    expect(within(row).getByText('Consumable')).toBeInTheDocument();
    expect(within(row).getByText('General')).toBeInTheDocument();
    expect(within(row).getByText('Active')).toBeInTheDocument();
  });

  it('creating a material resolves and sends the real tenant_id, not an empty string', async () => {
    const user = userEvent.setup();
    mockAmIFinance.mockResolvedValue({ data: true, error: null });
    const calls = setupFromMock({ materialRows: [], appUserTenantId: 't1' });

    render(<MaterialCatalogAdmin />);
    await waitFor(() => expect(screen.getByText('No materials yet.')).toBeInTheDocument());

    await user.click(screen.getByRole('button', { name: 'New material' }));
    await user.type(screen.getByLabelText('Name'), 'Steel Rebar');
    await user.click(screen.getByRole('button', { name: 'Save' }));

    await waitFor(() => expect(calls.inserts).toHaveLength(1));
    expect(calls.appUsersQueried).toBe(1);
    expect(calls.inserts[0]).toMatchObject({ name: 'Steel Rebar', tenant_id: 't1' });
    // the historical bug sent '' -- pin down that it's specifically not that
    expect((calls.inserts[0] as { tenant_id: string }).tenant_id).not.toBe('');
  });

  it('editing an existing material never queries app_users (tenant_id is immutable after create)', async () => {
    const user = userEvent.setup();
    mockAmIFinance.mockResolvedValue({ data: true, error: null });
    const calls = setupFromMock({ materialRows: [MATERIAL_A] });

    render(<MaterialCatalogAdmin />);
    await waitFor(() => expect(screen.getByText('Cement')).toBeInTheDocument());

    await user.click(screen.getByRole('button', { name: 'Edit' }));
    const nameField = screen.getByLabelText('Name');
    await user.clear(nameField);
    await user.type(nameField, 'Cement (Portland)');
    await user.click(screen.getByRole('button', { name: 'Save' }));

    await waitFor(() => expect(calls.updates).toHaveLength(1));
    expect(calls.appUsersQueried).toBe(0);
    expect(calls.updates[0]).toMatchObject({ id: 'm1', payload: { name: 'Cement (Portland)' } });
  });

  it('a missing session blocks the create with a clear error and never attempts the insert', async () => {
    const user = userEvent.setup();
    mockAmIFinance.mockResolvedValue({ data: true, error: null });
    mockUseAuth.mockReturnValue({ session: null });
    const calls = setupFromMock({ materialRows: [] });

    render(<MaterialCatalogAdmin />);
    await waitFor(() => expect(screen.getByText('No materials yet.')).toBeInTheDocument());

    await user.click(screen.getByRole('button', { name: 'New material' }));
    await user.type(screen.getByLabelText('Name'), 'Steel Rebar');
    await user.click(screen.getByRole('button', { name: 'Save' }));

    expect(await screen.findByText('Could not determine your session. Please refresh and try again.')).toBeInTheDocument();
    expect(calls.inserts).toHaveLength(0);
  });

  it('a duplicate code insert error shows a friendly message', async () => {
    const user = userEvent.setup();
    mockAmIFinance.mockResolvedValue({ data: true, error: null });
    setupFromMock({ materialRows: [], insertError: { message: 'duplicate key value violates unique constraint' } });

    render(<MaterialCatalogAdmin />);
    await waitFor(() => expect(screen.getByText('No materials yet.')).toBeInTheDocument());

    await user.click(screen.getByRole('button', { name: 'New material' }));
    await user.type(screen.getByLabelText('Name'), 'Steel Rebar');
    await user.type(screen.getByLabelText('Code (optional)'), 'MAT-001');
    await user.click(screen.getByRole('button', { name: 'Save' }));

    expect(await screen.findByText('Code "MAT-001" is already in use.')).toBeInTheDocument();
  });
});