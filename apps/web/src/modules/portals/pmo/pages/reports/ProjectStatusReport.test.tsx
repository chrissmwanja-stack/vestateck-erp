import { render, screen, waitFor, within } from '@testing-library/react';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import ProjectStatusReport from './ProjectStatusReport';

// ProjectStatusReport does a single chained query:
//   .from("pmo_projects").select(...).order("end_date", ...).limit(300)
// awaited directly (no pagination beyond .limit()), so the mock needs to
// support that chain and resolve on the final call.

const mockFrom = vi.fn();
vi.mock('../../../../../lib/supabaseClient', () => ({
  supabase: { from: (...args: unknown[]) => mockFrom(...args) },
}));

function mockProjects(projects: unknown[]) {
  mockFrom.mockImplementation((table: string) => {
    if (table !== 'pmo_projects') {
      throw new Error(`ProjectStatusReport test mock: unexpected table "${table}"`);
    }
    const chain = {
      select: () => chain,
      order: () => chain,
      limit: () => Promise.resolve({ data: projects, error: null }),
    };
    return chain;
  });
}

const PAST = '2020-01-01';
const FUTURE = '2099-01-01';

function row(name: string) {
  return screen.getAllByRole('row').find((r) => within(r).queryByText(name));
}

beforeEach(() => {
  mockFrom.mockReset();
});

describe('ProjectStatusReport', () => {
  it('counts a past-due task that is not done as overdue and flags health', async () => {
    mockProjects([
      {
        id: 'p1',
        name: 'Kampala Tower',
        status: 'in_progress',
        end_date: FUTURE,
        pmo_tasks: [
          { id: 't1', status: 'in_progress', due_date: PAST, completion_percent: 50 },
          { id: 't2', status: 'todo', due_date: PAST, completion_percent: 0 },
        ],
        pmo_milestones: [],
      },
    ]);

    render(<ProjectStatusReport />);

    await waitFor(() => expect(screen.getByText('Kampala Tower')).toBeInTheDocument());
    const r = row('Kampala Tower')!;
    // Tasks (done/total)
    expect(within(r).getByText('0/2')).toBeInTheDocument();
    // Overdue chip
    expect(within(r).getByText('2')).toBeInTheDocument();
    // Health: any overdue task makes the project "Overdue tasks"
    expect(within(r).getByText('Overdue tasks')).toBeInTheDocument();
  });

  it('does not count done, undated, or future-due tasks as overdue', async () => {
    mockProjects([
      {
        id: 'p1',
        name: 'Entebbe Depot',
        status: 'in_progress',
        end_date: FUTURE,
        pmo_tasks: [
          { id: 't1', status: 'done', due_date: PAST, completion_percent: 100 },
          { id: 't2', status: 'todo', due_date: null, completion_percent: 0 },
          { id: 't3', status: 'todo', due_date: FUTURE, completion_percent: 0 },
        ],
        pmo_milestones: [],
      },
    ]);

    render(<ProjectStatusReport />);

    await waitFor(() => expect(screen.getByText('Entebbe Depot')).toBeInTheDocument());
    const r = row('Entebbe Depot')!;
    expect(within(r).getByText('1/3')).toBeInTheDocument();
    expect(within(r).getByText('On track')).toBeInTheDocument();
    // Overdue count cell shows 0
    const cells = within(r).getAllByRole('cell');
    expect(cells[4]).toHaveTextContent('0');
  });

  it('shows zero totals and falls back to milestones when a project has no tasks', async () => {
    mockProjects([
      {
        id: 'p1',
        name: 'Jinja Yard',
        status: 'planning',
        end_date: FUTURE,
        pmo_tasks: [],
        pmo_milestones: [{ id: 'm1', status: 'done', due_date: null, completion_percent: 100 }],
      },
    ]);

    render(<ProjectStatusReport />);

    await waitFor(() => expect(screen.getByText('Jinja Yard')).toBeInTheDocument());
    const r = row('Jinja Yard')!;
    expect(within(r).getByText('0/0')).toBeInTheDocument();
    expect(within(r).getByText('1/1')).toBeInTheDocument(); // milestones done/total
  });

  it('marks a completed project as Completed regardless of overdue tasks', async () => {
    mockProjects([
      {
        id: 'p1',
        name: 'Mbarara Road',
        status: 'completed',
        end_date: PAST,
        pmo_tasks: [{ id: 't1', status: 'todo', due_date: PAST, completion_percent: 0 }],
        pmo_milestones: [],
      },
    ]);

    render(<ProjectStatusReport />);

    await waitFor(() => expect(screen.getByText('Mbarara Road')).toBeInTheDocument());
    expect(within(row('Mbarara Road')!).getByText('Completed')).toBeInTheDocument();
  });

  it('renders the empty state when there are no projects', async () => {
    mockProjects([]);

    render(<ProjectStatusReport />);

    await waitFor(() =>
      expect(screen.getByText(/No projects for this filter/i)).toBeInTheDocument(),
    );
  });
});