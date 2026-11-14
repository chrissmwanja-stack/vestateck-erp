import { render as rtlRender, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import type { ReactElement } from 'react';
import { MemoryRouter } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ToastProvider } from '../../../../lib/toastContext';
import ProjectCategoriesAdmin from './admin/ProjectCategoriesAdmin';
import TaskTypesAdmin from './admin/TaskTypesAdmin';
import NewProject from './projects/NewProject';
import ProjectsList from './projects/ProjectsList';
import MilestonesList from './tasks/MilestonesList';

const h = vi.hoisted(() => {
  type Res = { data: unknown; error: { message: string; code?: string } | null };
  return {
    results: {} as Record<string, Res>,
    inserts: [] as { table: string; payload: Record<string, unknown> }[],
    reportError: vi.fn(),
  };
});

vi.mock('../../../../lib/supabaseClient', () => {
  const chain = (table: string) => {
    let single = false;
    const c: Record<string, unknown> = {};
    for (const m of ['select', 'eq', 'order', 'limit', 'not']) c[m] = vi.fn(() => c);
    c.single = vi.fn(() => { single = true; return c; });
    c.insert = vi.fn((payload: Record<string, unknown>) => {
      h.inserts.push({ table, payload });
      return Promise.resolve(h.results[`${table}:insert`] ?? { data: null, error: null });
    });
    c.then = (resolve: (v: unknown) => unknown, reject: (e: unknown) => unknown) =>
      Promise.resolve(h.results[single ? `${table}:single` : table] ?? { data: [], error: null }).then(resolve, reject);
    return c;
  };
  return { supabase: { from: (table: string) => chain(table), rpc: vi.fn(() => Promise.resolve({ data: null, error: null })) } };
});
vi.mock('../../../../lib/authContext', () => ({
  useAuth: () => ({ session: { user: { user_metadata: { tenant_id: 'tenant-from-session' } } } }),
}));
vi.mock('../../../../lib/errorTracking', () => ({ reportError: h.reportError }));
vi.mock('../../../../lib/reportExport', () => ({ exportReportToExcel: vi.fn(), exportReportToPdf: vi.fn() }));

// These screens surface failed requests through useToast(), which needs the provider.
const render = (ui: ReactElement) => rtlRender(ui, { wrapper: ToastProvider });

beforeEach(() => {
  for (const k of Object.keys(h.results)) delete h.results[k];
  h.inserts.length = 0;
  h.reportError.mockClear();
});

const failure = { data: null, error: { message: 'permission denied' } };

describe('PMO: failed loads are surfaced', () => {
  it('project categories: toasts when the list cannot be loaded', async () => {
    h.results.pmo_project_categories = failure;
    render(<ProjectCategoriesAdmin />);
    expect(await screen.findByText('Could not load project categories.')).toBeTruthy();
  });

  it('task types: toasts when the list cannot be loaded', async () => {
    h.results.pmo_task_types = failure;
    render(<TaskTypesAdmin />);
    expect(await screen.findByText('Could not load task types.')).toBeTruthy();
  });

  it('projects list: toasts when projects cannot be loaded', async () => {
    h.results.pmo_projects = failure;
    render(<MemoryRouter><ProjectsList /></MemoryRouter>);
    expect(await screen.findByText('Could not load projects.')).toBeTruthy();
  });

  it('milestones: toasts when the milestone list cannot be loaded', async () => {
    h.results.pmo_milestones = failure;
    render(<MilestonesList />);
    expect(await screen.findByText('Could not load milestones.')).toBeTruthy();
  });

  // The toast provider shows one message at a time, so each failing query gets its own test.
  it('milestones: toasts when the project list cannot be loaded', async () => {
    h.results.pmo_projects = failure;
    render(<MilestonesList />);
    expect(await screen.findByText('Could not load projects.')).toBeTruthy();
  });
});

describe('PMO: tenant lookup before insert', () => {
  async function createProject() {
    const user = userEvent.setup();
    render(<MemoryRouter><NewProject /></MemoryRouter>);
    await user.type(await screen.findByLabelText(/project name/i), 'Road upgrade');
    await user.click(screen.getByRole('button', { name: /create project/i }));
    await waitFor(() => expect(h.inserts).toHaveLength(1));
  }

  it('reports a real lookup failure and still saves with the session tenant', async () => {
    const err = { message: 'connection reset', code: '08006' };
    h.results['pmo_project_categories:single'] = { data: null, error: err };
    await createProject();
    expect(h.inserts[0].payload.tenant_id).toBe('tenant-from-session');
    expect(h.reportError).toHaveBeenCalledWith(err, { source: 'NewProject.tenantLookup' });
  });

  it('does not report "no rows" (PGRST116)', async () => {
    h.results['pmo_project_categories:single'] = { data: null, error: { message: 'no rows', code: 'PGRST116' } };
    await createProject();
    expect(h.reportError).not.toHaveBeenCalled();
  });
});
