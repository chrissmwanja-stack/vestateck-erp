import { render, screen, waitFor, within } from '@testing-library/react';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import ProjectStatusReport from './ProjectStatusReport';

// ProjectStatusReport is read-only: a single pmo_projects select with an
// embedded pmo_tasks relation, awaited directly (no .order()/.limit()), so
// the shared mockSupabaseTable harness doesn't fit. Mocked directly here.

const mockFrom = vi.fn();
vi.mock('../../../../../lib/supabaseClient', () => ({
  supabase: { from: (...args: unknown[]) => mockFrom(...args) },
}));

function mockProjects(projects: unknown[]) {
  mockFrom.mockImplementation((table: string) => {
    if (table !== 'pmo_projects') {
      throw new Error(`ProjectStatusReport test mock: unexpected table "${table}"`);
    }
    return { select: () => Promise.resolve({ data: projects, error: null }) };
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
  it('counts a past-due task that is not done as overdue', async () => {
    mockProjects([
      {
        id: 'p1',
        name: 'Kampala Tower',
        status: 'in_progress',
        pmo_tasks: [
          { id: 't1', status: 'in_progress', due_date: PAST },
          { id: 't2', status: 'todo', due_date: PAST },
        ],
      },
    ]);

    render(<ProjectStatusReport />);

    await waitFor(() => expect(screen.getByText('Kampala Tower')).toBeInTheDocument());
    const cells = within(row('Kampala Tower')!).getAllByRole('cell');
    // Project | Status | Total | Completed | Overdue | Progress
    expect(cells[2]).toHaveTextContent('2');
    expect(cells[3]).toHaveTextContent('0');
    expect(cells[4]).toHaveTextContent('2');
  });

  it('does not count done, undated, or future-due tasks as overdue', async () => {
    mockProjects([
      {
        id: 'p1',
        name: 'Entebbe Depot',
        status: 'in_progress',
        pmo_tasks: [
          { id: 't1', status: 'done', due_date: PAST },
          { id: 't2', status: 'todo', due_date: null },
          { id: 't3', status: 'todo', due_date: FUTURE },
        ],
      },
    ]);

    render(<ProjectStatusReport />);

    await waitFor(() => expect(screen.getByText('Entebbe Depot')).toBeInTheDocument());
    const cells = within(row('Entebbe Depot')!).getAllByRole('cell');
    expect(cells[2]).toHaveTextContent('3');
    expect(cells[3]).toHaveTextContent('1');
    expect(cells[4]).toHaveTextContent('0');
    expect(cells[5]).toHaveTextContent('33%');
  });

  it('shows zero totals for a project with no tasks', async () => {
    mockProjects([{ id: 'p1', name: 'Jinja Yard', status: 'planning', pmo_tasks: [] }]);

    render(<ProjectStatusReport />);

    await waitFor(() => expect(screen.getByText('Jinja Yard')).toBeInTheDocument());
    const cells = within(row('Jinja Yard')!).getAllByRole('cell');
    expect(cells[2]).toHaveTextContent('0');
    expect(cells[4]).toHaveTextContent('0');
    expect(cells[5]).toHaveTextContent('0%');
  });

  it('renders the empty state when there are no projects', async () => {
    mockProjects([]);

    render(<ProjectStatusReport />);

    await waitFor(() =>
      expect(screen.getByText(/No projects yet/i)).toBeInTheDocument(),
    );
  });
});