import { render as rtlRender, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import type { ReactElement } from 'react';
import { MemoryRouter } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ToastProvider } from '../../../../lib/toastContext';
import LeadStatusesAdmin from './admin/LeadStatusesAdmin';
import QualifiedLeads from './leads/QualifiedLeads';
import ProposalTracking from './proposals/ProposalTracking';
import LeadSourceReport from './reports/LeadSourceReport';
import WinLossReport from './reports/WinLossReport';
import NewTender from './tenders/NewTender';
import TenderTracking from './tenders/TenderTracking';

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
    for (const m of ['select', 'eq', 'order', 'limit', 'in']) c[m] = vi.fn(() => c);
    c.single = vi.fn(() => { single = true; return c; });
    c.insert = vi.fn((payload: Record<string, unknown>) => {
      h.inserts.push({ table, payload });
      const r = Promise.resolve(h.results[`${table}:insert`] ?? { data: null, error: null });
      // NewTender chains .select().single() after insert; the seed loop awaits it directly.
      return Object.assign(r, { select: () => ({ single: () => r }) });
    });
    c.then = (resolve: (v: unknown) => unknown, reject: (e: unknown) => unknown) =>
      Promise.resolve(h.results[single ? `${table}:single` : table] ?? { data: [], error: null }).then(resolve, reject);
    return c;
  };
  return { supabase: { from: (table: string) => chain(table) } };
});
vi.mock('../../../../lib/authContext', () => ({
  useAuth: () => ({ session: { user: { id: 'u1', user_metadata: { tenant_id: 'tenant-from-session' } } } }),
}));
vi.mock('../../../../lib/ResolveTenantId', () => ({
  resolveTenantId: vi.fn(() => Promise.resolve({ ok: true, tenantId: 'tenant-1' })),
}));
vi.mock('../../../../lib/errorTracking', () => ({ reportError: h.reportError }));
vi.mock('../../../../lib/reportExport', () => ({ exportReportToExcel: vi.fn(), exportReportToPdf: vi.fn() }));

// These screens surface failed requests through useToast(), which needs the provider.
const render = (ui: ReactElement) => rtlRender(ui, { wrapper: ToastProvider });
const renderRouted = (ui: ReactElement) => render(<MemoryRouter>{ui}</MemoryRouter>);

beforeEach(() => {
  for (const k of Object.keys(h.results)) delete h.results[k];
  h.inserts.length = 0;
  h.reportError.mockClear();
});

const failure = { data: null, error: { message: 'permission denied' } };

describe('Business Development: failed loads are surfaced', () => {
  it('lead statuses: toasts when the list cannot be loaded', async () => {
    h.results.bd_lead_statuses = failure;
    render(<LeadStatusesAdmin />);
    expect(await screen.findByText('Could not load lead statuses.')).toBeTruthy();
  });

  it('lead statuses: a failed seed insert is reported, not silent', async () => {
    h.results['bd_lead_statuses:insert'] = failure;
    render(<LeadStatusesAdmin />);
    await userEvent.click(await screen.findByRole('button', { name: /seed 6 statuses/i }));
    expect(await screen.findByText('Could not add 6 of 6 default statuses.')).toBeTruthy();
  });

  it('qualified leads: toasts when leads cannot be loaded', async () => {
    h.results.bd_leads = failure;
    renderRouted(<QualifiedLeads />);
    expect(await screen.findByText('Could not load qualified leads.')).toBeTruthy();
  });

  it('proposal tracking: toasts when proposals cannot be loaded', async () => {
    h.results.bd_proposals = failure;
    renderRouted(<ProposalTracking />);
    expect(await screen.findByText('Could not load proposals.')).toBeTruthy();
  });

  it('tender tracking: toasts when tenders cannot be loaded', async () => {
    h.results.bd_tenders = failure;
    renderRouted(<TenderTracking />);
    expect(await screen.findByText('Could not load tenders.')).toBeTruthy();
  });

  it('lead source report: toasts and builds no figures from a failed query', async () => {
    h.results.bd_leads = failure;
    render(<LeadSourceReport />);
    expect(await screen.findByText('Could not load the lead source report.')).toBeTruthy();
    expect(screen.queryByText('Unknown')).toBeNull();
  });

  it('win/loss report: toasts when opportunities cannot be loaded', async () => {
    h.results.bd_opportunities = failure;
    render(<WinLossReport />);
    expect(await screen.findByText('Could not load the win/loss report.')).toBeTruthy();
  });
});

describe('Business Development: tenant lookup before insert', () => {
  const submit = async () => {
    renderRouted(<NewTender />);
    await userEvent.type(await screen.findByLabelText(/tender title/i), 'Road works');
    await userEvent.click(screen.getByRole('button', { name: /create tender/i }));
    await waitFor(() => expect(h.inserts.some(i => i.table === 'bd_tenders')).toBe(true));
    return h.inserts.find(i => i.table === 'bd_tenders')!.payload;
  };

  it('a real lookup error is reported and the session tenant is still used', async () => {
    const err = { message: 'boom', code: '42501' };
    h.results['bd_clients:single'] = { data: null, error: err };
    const payload = await submit();
    expect(h.reportError).toHaveBeenCalledWith(err, { source: 'NewTender.tenantLookup' });
    expect(payload.tenant_id).toBe('tenant-from-session');
  });

  it('PGRST116 (no rows) is an expected empty result and is not reported', async () => {
    h.results['bd_clients:single'] = { data: null, error: { message: 'no rows', code: 'PGRST116' } };
    const payload = await submit();
    expect(h.reportError).not.toHaveBeenCalled();
    expect(payload.tenant_id).toBe('tenant-from-session');
  });

  it('a successful lookup uses the looked-up tenant', async () => {
    h.results['bd_clients:single'] = { data: { tenant_id: 'tenant-looked-up' }, error: null };
    const payload = await submit();
    expect(h.reportError).not.toHaveBeenCalled();
    expect(payload.tenant_id).toBe('tenant-looked-up');
  });
});
