import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import TasksList from './TasksList';

// TasksList touches three tables (pmo_tasks, pmo_projects, pmo_task_types)
// with a different select/order/eq chain shape per call site -- fetchTasks
// conditionally chains .eq() onto .order() depending on the status filter,
// the tenant lookup on create is a one-off .select().eq().single(), and
// edit uses .update().eq(). That doesn't fit the shared mockSupabaseTable
// harness (built for one table's worth of select().order() + CRUD), so
// this mocks supabase.from() directly per table, same approach as
// GanttChart.test.tsx.

const mockFrom = vi.fn();
vi.mock('../../../../../lib/supabaseClient', () => ({
  supabase: { from: (...args: unknown[]) => mockFrom(...args) },
}));

const mockUseAuth = vi.fn();
vi.mock('../../../../../lib/authContext', () => ({
  useAuth: () => mockUseAuth(),
}));

const TASK = {
  id: 't1',
  project_id: 'p1',
  title: 'Pour foundation',
  status: 'in_progress',
  priority: 'high',
  type_id: null,
  start_date: '2026-08-01',
  due_date: '2026-08-10',
  completion_percent: 40,
  created_at: '2026-08-01T00:00:00Z',
  projects: { name: 'Kampala Tower' },
  task_types: null,
};

function setup(
  options: {
    tasks?: unknown[];
    updateError?: { message: string } | null;
    insertError?: { message: string } | null;
  } = {},
) {
  const tasks = options.tasks ?? [TASK];
  const updates: Array<{ payload: any; id: string }> = [];
  const inserts: unknown[] = [];

  mockFrom.mockImplementation((table: string) => {
    if (table === 'pmo_tasks') {
      return {
        // fetchTasks does `let query = ...select().order(); if (filter) query = query.eq(...); await query`
        // -- order() must be both directly awaitable (thenable) AND
        // chainable via .eq() into its own promise, since the component
        // may or may not call .eq() before awaiting.
        select: () => ({
          order: () => ({
            then: (resolve: (v: { data: unknown; error: null }) => void) =>
              Promise.resolve({ data: tasks, error: null }).then(resolve),
            eq: () => Promise.resolve({ data: tasks, error: null }),
          }),
        }),
        insert: (payload: unknown) => {
          inserts.push(payload);
          return Promise.resolve({ error: options.insertError ?? null });
        },
        update: (payload: unknown) => ({
          eq: (_col: string, id: string) => {
            updates.push({ payload, id });
            return Promise.resolve({ error: options.updateError ?? null });
          },
        }),
      };
    }
    if (table === 'pmo_projects') {
      return {
        select: (cols: string) => {
          if (cols === 'tenant_id') {
            return { eq: () => ({ single: () => Promise.resolve({ data: { tenant_id: 't1' }, error: null }) }) };
          }
          return { order: () => Promise.resolve({ data: [{ id: 'p1', name: 'Kampala Tower' }], error: null }) };
        },
      };
    }
    if (table === 'pmo_task_types') {
      return {
        select: () => ({ eq: () => ({ order: () => Promise.resolve({ data: [], error: null }) }) }),
      };
    }
    throw new Error(`TasksList test mock: unexpected table "${table}"`);
  });

  return { updates, inserts };
}

beforeEach(() => {
  mockFrom.mockReset();
  mockUseAuth.mockReturnValue({ session: { user: { id: 'u1' } } });
});

describe('TasksList', () => {
  it('renders existing tasks with their completion percent', async () => {
    setup();
    render(<TasksList />);

    await waitFor(() => expect(screen.getByText('Pour foundation')).toBeInTheDocument());
    expect(screen.getByText('40%')).toBeInTheDocument();
  });

  it('opens the edit dialog pre-filled, locks the project field, and sends only the editable fields on save', async () => {
    const { updates } = setup();
    const user = userEvent.setup();
    render(<TasksList />);

    await waitFor(() => expect(screen.getByText('Pour foundation')).toBeInTheDocument());
    await user.click(screen.getByRole('button', { name: /edit/i }));

    const dialog = await screen.findByRole('dialog');
    expect(within(dialog).getByText('Edit Task')).toBeInTheDocument();
    expect(within(dialog).getByDisplayValue('Pour foundation')).toBeInTheDocument();
    expect(within(dialog).getByLabelText(/Project/)).toHaveAttribute('aria-disabled', 'true');

    const percentInput = within(dialog).getByLabelText(/Completion %/);
    await user.clear(percentInput);
    await user.type(percentInput, '75');
    await user.click(within(dialog).getByRole('button', { name: 'Save' }));

    await waitFor(() => expect(updates).toHaveLength(1));
    expect(updates[0].id).toBe('t1');
    expect(updates[0].payload).toMatchObject({ completion_percent: 75, status: 'in_progress' });
    expect(updates[0].payload).not.toHaveProperty('project_id');
    expect(updates[0].payload).not.toHaveProperty('tenant_id');
    expect(updates[0].payload).not.toHaveProperty('assignee_id');
  });

  it('rejects a completion percent outside 0-100 without saving', async () => {
    const { updates } = setup();
    const user = userEvent.setup();
    render(<TasksList />);

    await waitFor(() => expect(screen.getByText('Pour foundation')).toBeInTheDocument());
    await user.click(screen.getByRole('button', { name: /edit/i }));

    const dialog = await screen.findByRole('dialog');
    const percentInput = within(dialog).getByLabelText(/Completion %/);
    await user.clear(percentInput);
    await user.type(percentInput, '150');
    await user.click(within(dialog).getByRole('button', { name: 'Save' }));

    expect(await within(dialog).findByText(/between 0 and 100/)).toBeInTheDocument();
    expect(updates).toHaveLength(0);
  });

  it('creates a new task with the resolved tenant_id and the typed completion percent', async () => {
    const { inserts } = setup({ tasks: [] });
    const user = userEvent.setup();
    render(<TasksList />);

    await waitFor(() => expect(screen.getByText(/No tasks yet/)).toBeInTheDocument());
    await user.click(screen.getByRole('button', { name: 'New Task' }));

    const dialog = await screen.findByRole('dialog');
    expect(within(dialog).getByText('New Task')).toBeInTheDocument();
    expect(within(dialog).getByLabelText(/Project/)).not.toBeDisabled();

    await user.click(within(dialog).getByLabelText(/Project/));
    await user.click(await screen.findByRole('option', { name: 'Kampala Tower' }));
    await user.type(within(dialog).getByLabelText(/Title/), 'Frame roof');
    await user.click(within(dialog).getByRole('button', { name: 'Create' }));

    await waitFor(() => expect(inserts).toHaveLength(1));
    expect(inserts[0]).toMatchObject({
      project_id: 'p1',
      title: 'Frame roof',
      completion_percent: 0,
      tenant_id: 't1',
      assignee_id: 'u1',
    });
  });
});