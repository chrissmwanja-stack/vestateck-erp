import { render as rtlRender, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import type { ReactElement } from 'react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ToastProvider } from '../../../../lib/toastContext';
import MachineTypesAdmin from './admin/MachineTypesAdmin';
import MaintenanceSchedule from './maintenance/MaintenanceSchedule';
import DowntimeReport from './reports/DowntimeReport';
import EquipmentAssignments from './equipment/EquipmentAssignments';

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
    for (const m of ['select', 'eq', 'order', 'limit']) c[m] = vi.fn(() => c);
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

describe('Machine Operation: failed loads are surfaced', () => {
  it('machine types: toasts when the list cannot be loaded', async () => {
    h.results.machine_types = failure;
    render(<MachineTypesAdmin />);
    expect(await screen.findByText('Could not load machine types.')).toBeTruthy();
  });

  it('maintenance schedule: toasts when the schedule cannot be loaded', async () => {
    h.results.maintenance_requests = failure;
    render(<MaintenanceSchedule />);
    expect(await screen.findByText('Could not load the maintenance schedule.')).toBeTruthy();
  });

  it('downtime report: toasts and shows no figures built from a failed query', async () => {
    h.results.maintenance_requests = failure;
    render(<DowntimeReport />);
    expect(await screen.findByText('Could not load the downtime report.')).toBeTruthy();
    expect(screen.queryByText('Unknown')).toBeNull();
  });
});

describe('Machine Operation: tenant lookup before insert', () => {
  async function createAssignment() {
    h.results.machines = { data: [{ id: 'm1', name: 'Cat 320', machine_no: 'EX-01' }], error: null };
    h.results.machine_assignments = { data: [], error: null };
    const user = userEvent.setup();
    render(<EquipmentAssignments />);
    await user.click(await screen.findByRole('button', { name: /new assignment/i }));
    await user.click(await screen.findByLabelText(/machine \*/i));
    await user.click(await screen.findByRole('option', { name: /EX-01/ }));
    await user.click(screen.getByRole('button', { name: /^create$/i }));
    await waitFor(() => expect(h.inserts).toHaveLength(1));
  }

  it('reports a real lookup failure and still saves with the session tenant', async () => {
    const err = { message: 'connection reset', code: '08006' };
    h['results']['machines:single'] = { data: null, error: err };
    await createAssignment();
    expect(h.inserts[0].payload.tenant_id).toBe('tenant-from-session');
    expect(h.reportError).toHaveBeenCalledWith(err, { source: 'EquipmentAssignments.tenantLookup' });
  });

  it('does not report "no rows" (PGRST116), which is an expected empty result', async () => {
    h.results['machines:single'] = { data: null, error: { message: 'no rows', code: 'PGRST116' } };
    await createAssignment();
    expect(h.inserts[0].payload.tenant_id).toBe('tenant-from-session');
    expect(h.reportError).not.toHaveBeenCalled();
  });

  it('uses the looked-up tenant when the query succeeds', async () => {
    h.results['machines:single'] = { data: { tenant_id: 'tenant-from-db' }, error: null };
    await createAssignment();
    expect(h.inserts[0].payload.tenant_id).toBe('tenant-from-db');
    expect(h.reportError).not.toHaveBeenCalled();
  });
});
