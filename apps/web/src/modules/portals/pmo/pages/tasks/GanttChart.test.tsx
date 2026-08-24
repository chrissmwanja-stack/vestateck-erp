import { render, screen, waitFor } from '@testing-library/react';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import GanttChart from './GanttChart';

// GanttChart is read-only (no admin gate, no writes) -- it queries
// pmo_tasks and pmo_milestones in a single Promise.all with a
// select().order().limit() chain per table, which doesn't fit the shared
// mockSupabaseTable harness (single table, select().order() only, no
// .limit()). Mocked directly here instead.

const mockFrom = vi.fn();
vi.mock('../../../../../lib/supabaseClient', () => ({
  supabase: { from: (...args: unknown[]) => mockFrom(...args) },
}));

function mockPmoData(
  tasks: unknown[],
  milestones: unknown[],
  errors: { tasks?: { message: string }; milestones?: { message: string } } = {},
) {
  mockFrom.mockImplementation((table: string) => {
    if (table !== 'pmo_tasks' && table !== 'pmo_milestones') {
      throw new Error(`GanttChart test mock: unexpected table "${table}"`);
    }
    const rows = table === 'pmo_tasks' ? tasks : milestones;
    const error = table === 'pmo_tasks' ? errors.tasks ?? null : errors.milestones ?? null;
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
    mockPmoData([], [], { tasks: { message: 'permission denied for table pmo_tasks' } });

    render(<GanttChart />);

    await waitFor(() =>
      expect(screen.getByText('permission denied for table pmo_tasks')).toBeInTheDocument(),
    );
  });
});