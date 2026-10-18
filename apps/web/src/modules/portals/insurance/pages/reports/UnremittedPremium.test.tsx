import { render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import UnremittedPremium from './UnremittedPremium';

const mockExcel = vi.fn();
const mockPdf = vi.fn();
vi.mock('../../../../../lib/reportExport', () => ({
  exportReportToExcel: (...a: unknown[]) => mockExcel(...a),
  exportReportToPdf: (...a: unknown[]) => mockPdf(...a),
}));

let report: unknown[] = [];
vi.mock('../../../../../lib/supabaseClient', () => ({
  supabase: {
    rpc: vi.fn(() => Promise.resolve({ data: report, error: null })),
    from: (name: string) => {
      const data: Record<string, unknown> = {
        ins_insurers: [{ id: 'i1', name: 'Jubilee' }, { id: 'i2', name: 'UAP' }],
        ins_policies: [
          { id: 'p1', currency: 'UGX', ins_clients: { bd_clients: { name: 'Acme Ltd' } } },
          { id: 'p2', currency: 'USD', ins_clients: { bd_clients: { name: 'Beta Co' } } },
        ],
        tenant_ledger_settings: [{ functional_currency: 'UGX' }],
      };
      const chain: Record<string, unknown> = {};
      for (const m of ['select', 'order', 'in']) chain[m] = vi.fn(() => chain);
      (chain as { then: unknown }).then = (resolve: (v: unknown) => void) => resolve({ data: data[name], error: null });
      return chain;
    },
  },
}));

const line = (over: Record<string, unknown>) => ({
  policy_id: 'p1', policy_no: 'POL-1', insurer_id: 'i1', unremitted_amount: 1000, receipt_date: '2026-10-01', deadline_date: '2026-10-05', status: 'overdue', ...over,
});

beforeEach(() => {
  mockExcel.mockReset(); mockPdf.mockReset();
  report = [line({}), line({ policy_id: 'p2', policy_no: 'POL-2', insurer_id: 'i2', unremitted_amount: 250.5, status: 'within_deadline', deadline_date: '2026-12-01' })];
});

const mount = () => render(<MemoryRouter><UnremittedPremium /></MemoryRouter>);

describe('unremitted premium export', () => {
  it('exports every row shown to Excel, with client, insurer and currency filled in', async () => {
    mount();
    await userEvent.click(await screen.findByRole('button', { name: 'Export Excel' }));
    expect(mockExcel).toHaveBeenCalledTimes(1);
    const [name, sheet, , rows] = mockExcel.mock.calls[0];
    expect(name).toMatch(/^unremitted-premium-\d{4}-\d{2}-\d{2}$/);
    expect(sheet).toBe('Unremitted premium');
    expect(rows).toHaveLength(2);
    expect(rows[0]).toMatchObject({ policy_no: 'POL-1', client: 'Acme Ltd', insurer: 'Jubilee', currency: 'UGX', amount: 1000, status: 'Overdue' });
    expect(rows[1]).toMatchObject({ client: 'Beta Co', currency: 'USD', amount: 250.5 });
  });

  it('exports only the rows left after a status filter, and says so in the PDF subtitle', async () => {
    mount();
    await userEvent.click(await screen.findByText(/^Overdue \(1\)/));
    await userEvent.click(screen.getByRole('button', { name: 'Export PDF' }));
    const [, title, , rows, subtitle] = mockPdf.mock.calls[0];
    expect(title).toBe('Unremitted premium');
    expect(rows.map((r: { policy_no: string }) => r.policy_no)).toEqual(['POL-1']);
    expect(subtitle).toContain('Status: Overdue');
    expect(subtitle).toContain('Total held, not remitted');
  });

  it('offers no export when there is nothing to export', async () => {
    report = [];
    mount();
    await screen.findByText('No premium is being held for remittance.');
    expect(screen.queryByRole('button', { name: 'Export Excel' })).not.toBeInTheDocument();
    expect(within(document.body).queryByRole('button', { name: 'Export PDF' })).not.toBeInTheDocument();
  });
});
