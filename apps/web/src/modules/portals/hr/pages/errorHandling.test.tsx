import { render as rtlRender, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import type { ReactElement } from 'react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ToastProvider } from '../../../../lib/toastContext';
import LeaveTypesAdmin from './admin/LeaveTypesAdmin';
import PositionsAdmin from './admin/PositionsAdmin';
import AttendanceList from './attendance/AttendanceList';
import AttendanceReport from './reports/AttendanceReport';
import HeadcountReport from './reports/HeadcountReport';
import ApplicationsList from './recruitment/ApplicationsList';

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
    for (const m of ['select', 'eq', 'order', 'limit', 'gte', 'lte']) c[m] = vi.fn(() => c);
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

describe('HR: failed loads are surfaced', () => {
  it('leave types: toasts when the list cannot be loaded', async () => {
    h.results.hr_leave_types = failure;
    render(<LeaveTypesAdmin />);
    expect(await screen.findByText('Could not load leave types.')).toBeTruthy();
  });

  it('positions: toasts when the list cannot be loaded', async () => {
    h.results.hr_positions = failure;
    render(<PositionsAdmin />);
    expect(await screen.findByText('Could not load positions.')).toBeTruthy();
  });

  it('attendance report: toasts when the month cannot be loaded', async () => {
    h.results.hr_attendance = failure;
    render(<AttendanceReport />);
    expect(await screen.findByText('Could not load the attendance report.')).toBeTruthy();
  });

  it('headcount report: toasts and shows no totals from a failed query', async () => {
    h.results.hr_employees = failure;
    render(<HeadcountReport />);
    expect(await screen.findByText('Could not load the headcount report.')).toBeTruthy();
    expect(screen.queryByText('Unassigned')).toBeNull();
  });
});

describe('HR: attendance tenant lookup before insert', () => {
  async function createRecord() {
    h.results.hr_employees = { data: [{ id: 'e1', first_name: 'Amina', last_name: 'Nakato' }], error: null };
    h.results.hr_attendance = { data: [], error: null };
    const user = userEvent.setup();
    render(<AttendanceList />);
    await user.click(await screen.findByRole('button', { name: /new attendance/i }));
    await user.click(await screen.findByLabelText(/employee \*/i));
    await user.click(await screen.findByRole('option', { name: /Amina Nakato/ }));
    await user.click(screen.getByRole('button', { name: /^create$/i }));
    await waitFor(() => expect(h.inserts).toHaveLength(1));
  }

  it('reports a real lookup failure and still saves with the session tenant', async () => {
    const err = { message: 'connection reset', code: '08006' };
    h.results['hr_employees:single'] = { data: null, error: err };
    await createRecord();
    expect(h.inserts[0].payload.tenant_id).toBe('tenant-from-session');
    expect(h.reportError).toHaveBeenCalledWith(err, { source: 'AttendanceList.tenantLookup' });
  });

  it('does not report "no rows" (PGRST116)', async () => {
    h.results['hr_employees:single'] = { data: null, error: { message: 'no rows', code: 'PGRST116' } };
    await createRecord();
    expect(h.inserts[0].payload.tenant_id).toBe('tenant-from-session');
    expect(h.reportError).not.toHaveBeenCalled();
  });
});

describe('HR: applications reference a closed job posting', () => {
  const app = { id: 'a1', tenant_id: 't', job_posting_id: 'closed-job', candidate_name: 'Joel Okello', email: null, phone: null, stage: 'applied', created_at: '2026-11-01T08:00:00Z', hr_job_postings: null };

  async function openEdit() {
    h.results.hr_job_applications = { data: [app], error: null };
    h.results.hr_job_postings = { data: [], error: null };
    const user = userEvent.setup();
    render(<ApplicationsList />);
    await user.click(await screen.findByRole('button', { name: /edit application/i }));
  }

  it('toasts when the closed posting cannot be fetched', async () => {
    h.results['hr_job_postings:single'] = { data: null, error: { message: 'timeout', code: '57014' } };
    await openEdit();
    expect(await screen.findByText('Could not load the job posting for this application.')).toBeTruthy();
  });

  it('stays quiet when the posting no longer exists (PGRST116)', async () => {
    h.results['hr_job_postings:single'] = { data: null, error: { message: 'no rows', code: 'PGRST116' } };
    await openEdit();
    await screen.findByText('Edit Application');
    expect(screen.queryByText('Could not load the job posting for this application.')).toBeNull();
  });
});
