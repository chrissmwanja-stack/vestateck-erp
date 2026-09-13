import { render, screen, waitFor } from '@testing-library/react';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import GanttChart from './GanttChart';

// GanttChart is read-only (no admin gate, no writes) -- it queries
// pmo_tasks, pmo_milestones, and pmo_task_dependencies in a single
// Promise.all with a select().order().limit() chain per table, which
// doesn't fit the shared mockSupabaseTable harness (single table,
// select().order() only, no .limit()). Mocked directly here instead.

const mockFrom = vi.fn();
vi.mock('../../../../../lib/supabaseClient', () => ({
  supabase: { from: (...args: unknown[]) => mockFrom(...args) },
}));

function mockPmoData(
  tasks: unknown[],
  milestones: unknown[],
  dependencies: unknown[] = [],
  errors: { tasks?: { message: string }; milestones?: { message: string }; dependencies?: { message: string } } = {},
) {
  mockFrom.mockImplementation((table: string) => {
    if (table !== 'pmo_tasks' && table !== 'pmo_milestones' && table !== 'pmo_task_dependencies') {
      throw new Error(`GanttChart test mock: unexpected table "${table}"`);
    }
    const rows = table === 'pmo_tasks' ? tasks : table === 'pmo_milestones' ? milestones : dependencies;
    const error = table === 'pmo_tasks' ? errors.tasks ?? null : table === 'pmo_milestones' ? errors.milestones ?? null : errors.dependencies ?? null;
    return {
      select: () => ({
        order: () => ({
          limit: () => Promise.resolve({ data: rows, error }),
        }),
      }),
    };
  });
}

const TASK_WITH_RANGE = {
  id: 't1',
  title: 'Pour foundation',
  status: 'in_progress',
  start_date: '2026-08-01',
  due_date: '2026-08-10',
  completion_percent: 40,
  pmo_projects: { name: 'Kampala Tower' },
};

const TASK_NO_DATES = {
  id: 't2',
  title: 'Undated backlog item',
  status: 'todo',
  start_date: null,
  due_date: null,
  pmo_projects: { name: 'Kampala Tower' },
};

const MILESTONE_A = {
  id: 'm1',
  title: 'Foundation sign-off',
  due_date: '2026-08-12',
  completion_percent: 0,
  pmo_projects: { name: 'Kampala Tower' },
};

beforeEach(() => {
  mockFrom.mockReset();
});

describe('GanttChart', () => {
  it('shows the empty state when nothing has dates', async () => {
    mockPmoData([], []);

    render(<GanttChart />);

    await waitFor(() =>
      expect(screen.getByText(/No tasks or milestones with dates yet/)).toBeInTheDocument(),
    );
  });

  it('renders a dated task and milestone grouped under their project, and reports counts', async () => {
    mockPmoData([TASK_WITH_RANGE], [MILESTONE_A]);

    render(<GanttChart />);

    await waitFor(() => expect(screen.getByText('Pour foundation')).toBeInTheDocument());
    expect(screen.getByText('Foundation sign-off')).toBeInTheDocument();
    expect(screen.getByText('Kampala Tower (2)')).toBeInTheDocument();
    expect(screen.getByText('1 Tasks')).toBeInTheDocument();
    expect(screen.getByText('1 Milestones')).toBeInTheDocument();
  });

  it('counts a task with no start_date or due_date as hidden rather than rendering a zero-width bar', async () => {
    mockPmoData([TASK_WITH_RANGE, TASK_NO_DATES], []);

    render(<GanttChart />);

    await waitFor(() => expect(screen.getByText('Pour foundation')).toBeInTheDocument());
    expect(screen.queryByText('Undated backlog item')).not.toBeInTheDocument();
    expect(screen.getByText('1 without dates hidden')).toBeInTheDocument();
  });

  it('surfaces a load error from either query', async () => {
    mockPmoData([], [], [], { tasks: { message: 'permission denied for table pmo_tasks' } });

    render(<GanttChart />);

    await waitFor(() =>
      expect(screen.getByText('permission denied for table pmo_tasks')).toBeInTheDocument(),
    );
  });

  it('highlights the critical path across a chain of dependent tasks and skips a lone dependency-free task', async () => {
    const taskA = { id: 't1', title: 'Design', status: 'done', start_date: '2026-08-01', due_date: '2026-08-05', completion_percent: 100, pmo_projects: { name: 'Kampala Tower' } };
    const taskB = { id: 't2', title: 'Foundation', status: 'in_progress', start_date: '2026-08-06', due_date: '2026-08-15', completion_percent: 40, pmo_projects: { name: 'Kampala Tower' } };
    const taskC = { id: 't3', title: 'Unrelated cleanup', status: 'todo', start_date: '2026-08-01', due_date: '2026-08-02', completion_percent: 0, pmo_projects: { name: 'Kampala Tower' } };
    mockPmoData(
      [taskA, taskB, taskC],
      [],
      [{ predecessor_task_id: 't1', successor_task_id: 't2' }],
    );

    render(<GanttChart />);

    await waitFor(() => expect(screen.getByText('Design')).toBeInTheDocument());
    // Design (5 days) -> Foundation (10 days) = 15-day critical path across 2 tasks.
    expect(screen.getByText('Critical path: 15d across 2 tasks')).toBeInTheDocument();
  });

  it('does not report a critical path when no dependency links the visible tasks', async () => {
    const taskA = { id: 't1', title: 'Solo task', status: 'todo', start_date: '2026-08-01', due_date: '2026-08-05', completion_percent: 0, pmo_projects: { name: 'Kampala Tower' } };
    mockPmoData([taskA], []);

    render(<GanttChart />);

    await waitFor(() => expect(screen.getByText('Solo task')).toBeInTheDocument());
    expect(screen.queryByText(/Critical path:/)).not.toBeInTheDocument();
  });
});