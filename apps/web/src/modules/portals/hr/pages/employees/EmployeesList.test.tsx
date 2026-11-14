import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import EmployeesList from './EmployeesList';

// "Reports to" sets hr_employees.manager_id, the line manager who can decide
// that employee's leave (20261114100000_hr_leave_deciders.sql). These tests pin
// the three things that matter: it is written, it is not offered for self or
// downline, and editing an employee no longer wipes the stored hire date.

const h = vi.hoisted(() => ({
  employees: [] as Record<string, unknown>[],
  updates: [] as { table: string; payload: Record<string, unknown>; id: string }[],
  inserts: [] as { table: string; payload: Record<string, unknown> }[],
}));

vi.mock('../../../../../lib/supabaseClient', () => {
  const chain = (table: string) => {
    const c: Record<string, unknown> = {};
    for (const m of ['select', 'order']) c[m] = vi.fn(() => c);
    c.eq = vi.fn(() => c);
    c.single = vi.fn(() => Promise.resolve({ data: { tenant_id: 'tenant-1' }, error: null }));
    c.update = vi.fn((payload: Record<string, unknown>) => ({
      eq: (_col: string, id: string) => {
        h.updates.push({ table, payload, id });
        return Promise.resolve({ error: null });
      },
    }));
    c.insert = vi.fn((payload: Record<string, unknown>) => {
      h.inserts.push({ table, payload });
      return Promise.resolve({ error: null });
    });
    c.then = (resolve: (v: unknown) => unknown, reject: (e: unknown) => unknown) =>
      Promise.resolve({ data: table === 'hr_employees' ? h.employees : [], error: null }).then(resolve, reject);
    return c;
  };
  return { supabase: { from: (t: string) => chain(t) } };
});
vi.mock('../../../../../lib/authContext', () => ({
  useAuth: () => ({ session: { user: { id: 'user-hr' } } }),
}));
vi.mock('../../../../../components/bulk-import/BulkImportDialog', () => ({ default: () => null }));

const emp = (id: string, first: string, over: Record<string, unknown> = {}) => ({
  id,
  tenant_id: 'tenant-1',
  employee_no: `HR-EMP-2026-${id}`,
  first_name: first,
  last_name: 'Test',
  email: `${first.toLowerCase()}@example.com`,
  phone: null,
  department_id: null,
  position_id: null,
  manager_id: null,
  hire_date: null,
  employment_status: 'active',
  is_active: true,
  created_at: '2026-01-01',
  departments: null,
  hr_positions: null,
  ...over,
});

// Chain of command: Boss <- Mid <- Junior. Dora is unrelated, Gone is inactive.
beforeEach(() => {
  h.updates.length = 0;
  h.inserts.length = 0;
  h.employees = [
    emp('0001', 'Boss'),
    emp('0002', 'Mid', { manager_id: '0001', hire_date: '2024-03-15' }),
    emp('0003', 'Junior', { manager_id: '0002' }),
    emp('0004', 'Dora'),
    emp('0005', 'Gone', { is_active: false }),
  ];
});

const renderList = () => render(<MemoryRouter><EmployeesList /></MemoryRouter>);

// Names also appear in the "Reports to" column, so rows are found by the
// (unique) employee number instead.
const rowFor = async (id: string) => (await screen.findByText(`HR-EMP-2026-${id}`)).closest('tr') as HTMLElement;

async function openEdit(user: ReturnType<typeof userEvent.setup>, id: string) {
  await user.click(within(await rowFor(id)).getByRole('button', { name: 'Edit' }));
}

describe('EmployeesList: Reports to', () => {
  it('shows each employee\'s line manager in the table', async () => {
    renderList();
    const row = await rowFor('0002');
    expect(within(row).getByText('Boss Test')).toBeInTheDocument();
    expect(within(await rowFor('0004')).queryByText('Boss Test')).not.toBeInTheDocument();
  });

  it('offers neither the employee nor anyone below them, nor inactive people', async () => {
    const user = userEvent.setup();
    renderList();
    await openEdit(user, '0002');
    await user.click(screen.getByLabelText('Reports to'));

    expect(await screen.findByRole('option', { name: 'Boss Test' })).toBeInTheDocument();
    expect(screen.getByRole('option', { name: 'Dora Test' })).toBeInTheDocument();
    expect(screen.queryByRole('option', { name: 'Mid Test' })).not.toBeInTheDocument();
    expect(screen.queryByRole('option', { name: 'Junior Test' })).not.toBeInTheDocument();
    expect(screen.queryByRole('option', { name: 'Gone Test' })).not.toBeInTheDocument();
  });

  it('keeps the current manager in the list even when that manager is inactive', async () => {
    h.employees = [emp('0005', 'Gone', { is_active: false }), emp('0006', 'Kim', { manager_id: '0005' })];
    const user = userEvent.setup();
    renderList();
    await openEdit(user, '0006');
    await user.click(screen.getByLabelText('Reports to'));
    expect(await screen.findByRole('option', { name: 'Gone Test' })).toBeInTheDocument();
  });

  it('editing keeps the stored manager and hire date instead of clearing them', async () => {
    const user = userEvent.setup();
    renderList();
    await openEdit(user, '0002');
    await user.click(screen.getByRole('button', { name: 'Update' }));

    await waitFor(() => expect(h.updates).toHaveLength(1));
    expect(h.updates[0].id).toBe('0002');
    expect(h.updates[0].payload).toMatchObject({ manager_id: '0001', hire_date: '2024-03-15' });
  });

  it('saves a newly chosen manager', async () => {
    const user = userEvent.setup();
    renderList();
    await openEdit(user, '0004');
    await user.click(screen.getByLabelText('Reports to'));
    await user.click(await screen.findByRole('option', { name: 'Boss Test' }));
    await user.click(screen.getByRole('button', { name: 'Update' }));

    await waitFor(() => expect(h.updates).toHaveLength(1));
    expect(h.updates[0].payload).toMatchObject({ manager_id: '0001' });
  });

  it('clearing the manager saves null', async () => {
    const user = userEvent.setup();
    renderList();
    await openEdit(user, '0002');
    await user.click(screen.getByLabelText('Reports to'));
    await user.click(await screen.findByRole('option', { name: '-- None --' }));
    await user.click(screen.getByRole('button', { name: 'Update' }));

    await waitFor(() => expect(h.updates).toHaveLength(1));
    expect(h.updates[0].payload.manager_id).toBeNull();
  });

  it('a new employee can be created with a manager', async () => {
    const user = userEvent.setup();
    renderList();
    await rowFor('0001');
    await user.click(screen.getByRole('button', { name: 'New Employee' }));
    await user.type(screen.getByLabelText('First Name *'), 'Nia');
    await user.type(screen.getByLabelText('Last Name *'), 'New');
    await user.type(screen.getByLabelText('Email *'), 'nia@example.com');
    await user.click(screen.getByLabelText('Reports to'));
    await user.click(await screen.findByRole('option', { name: 'Dora Test' }));
    await user.click(screen.getByRole('button', { name: 'Create' }));

    await waitFor(() => expect(h.inserts).toHaveLength(1));
    expect(h.inserts[0].payload).toMatchObject({ first_name: 'Nia', manager_id: '0004', tenant_id: 'tenant-1' });
  });
});
