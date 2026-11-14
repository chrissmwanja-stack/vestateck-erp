import { render as rtlRender, screen } from '@testing-library/react';
import type { ReactElement } from 'react';
import { MemoryRouter } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ToastProvider } from '../../../../lib/toastContext';
import AuditsList from './audits/AuditsList';
import MetricTypesAdmin from './admin/MetricTypesAdmin';
import ExcellenceReport from './reports/ExcellenceReport';
import NewInitiative from './initiatives/NewInitiative';

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

describe('Sustainability: failed loads are surfaced', () => {
  it('audits: toasts when the list cannot be loaded', async () => {
    h.results.sustainability_audits = failure;
    render(<AuditsList />);
    expect(await screen.findByText('Could not load audits.')).toBeTruthy();
  });

  it('metric types: toasts when the list cannot be loaded', async () => {
    h.results.sustainability_metric_types = failure;
    render(<MetricTypesAdmin />);
    expect(await screen.findByText('Could not load metric types.')).toBeTruthy();
  });

  it('excellence report: toasts when initiatives cannot be loaded', async () => {
    h.results.sustainability_initiatives = failure;
    render(<ExcellenceReport />);
    expect(await screen.findByText('Could not load the sustainability report.')).toBeTruthy();
  });

  it('new initiative: toasts when the category list cannot be loaded', async () => {
    h.results.sustainability_initiative_categories = failure;
    render(<MemoryRouter><NewInitiative /></MemoryRouter>);
    expect(await screen.findByText('Could not load initiative categories.')).toBeTruthy();
  });
});
