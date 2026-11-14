import { render as rtlRender, screen } from '@testing-library/react';
import type { ReactElement } from 'react';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ToastProvider } from '../../../../lib/toastContext';
import CaseTypesAdmin from './admin/CaseTypesAdmin';
import ComplianceRegister from './compliance/ComplianceRegister';
import ContractDetail from './contracts/ContractDetail';
import CaseStatusReport from './reports/CaseStatusReport';
import ExpiryReport from './reports/ExpiryReport';

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

describe('Law & Compliance: failed loads are surfaced', () => {
  it('case types: toasts when the list cannot be loaded', async () => {
    h.results.law_case_types = failure;
    render(<CaseTypesAdmin />);
    expect(await screen.findByText('Could not load case types.')).toBeTruthy();
  });

  it('compliance register: toasts when the register cannot be loaded', async () => {
    h.results.law_compliance_register = failure;
    render(<ComplianceRegister />);
    expect(await screen.findByText('Could not load the compliance register.')).toBeTruthy();
  });

  // The toast provider shows one message at a time, so each failing query gets its own test.
  it('compliance register: toasts when the staff list cannot be loaded', async () => {
    h.results.app_users = failure;
    render(<ComplianceRegister />);
    expect(await screen.findByText('Could not load the staff list.')).toBeTruthy();
  });

  it('case status report: toasts and builds no totals from a failed query', async () => {
    h.results.law_cases = failure;
    render(<CaseStatusReport />);
    expect(await screen.findByText('Could not load the case status report.')).toBeTruthy();
    expect(screen.queryByText('Uncategorized')).toBeNull();
  });

  it('expiry report: toasts when contracts cannot be loaded', async () => {
    h.results.law_contracts = failure;
    render(<ExpiryReport />);
    expect(await screen.findByText('Could not load the contract expiry report.')).toBeTruthy();
  });

  it('contract detail: a failed approver check is reported and the Approve action stays hidden', async () => {
    const err = { message: 'rpc failed' };
    const supa = (await import('../../../../lib/supabaseClient')).supabase as unknown as { rpc: ReturnType<typeof vi.fn> };
    supa.rpc.mockResolvedValueOnce({ data: null, error: err });
    h.results['law_contracts:single'] = {
      data: { id: 'c1', title: 'Lease', status: 'pending_approval', contract_no: 'C-1', law_contract_types: null },
      error: null,
    };
    render(
      <MemoryRouter initialEntries={['/legal/contracts/c1']}>
        <Routes><Route path="/legal/contracts/:id" element={<ContractDetail />} /></Routes>
      </MemoryRouter>,
    );
    await screen.findByText(/Lease/);
    expect(h.reportError).toHaveBeenCalledWith(err, { source: 'ContractDetail.hasModuleRole' });
    expect(screen.queryByRole('button', { name: /^approve$/i })).toBeNull();
  });
});
