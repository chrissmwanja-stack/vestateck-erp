import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import CommissionEarned from './CommissionEarned';

const mockExcel = vi.fn();
const mockPdf = vi.fn();
vi.mock('../../../../../lib/reportExport', () => ({
  exportReportToExcel: (...a: unknown[]) => mockExcel(...a),
  exportReportToPdf: (...a: unknown[]) => mockPdf(...a),
}));

let report: unknown[] = [];
const rpcMock = vi.fn((_fn: string, _args: Record<string, unknown>) => Promise.resolve({ data: report, error: null }));
vi.mock('../../../../../lib/supabaseClient', () => ({
  supabase: { rpc: (fn: string, args: Record<string, unknown>) => rpcMock(fn, args) },
}));

const line = (over: Record<string, unknown>) => ({
  group_key: '2026-11', group_label: '2026-11', currency: 'UGX', placement: 0, recognised: 500, reversed: 0, cancellations: 0,
  endorsements: 0, other: 0, net_earned: 500, policy_count: 2, ...over,
});

beforeEach(() => {
  mockExcel.mockReset(); mockPdf.mockReset(); rpcMock.mockClear();
  report = [
    line({}),
    line({ group_key: '2026-10', group_label: '2026-10', placement: 300, recognised: 0, cancellations: -50, net_earned: 250 }),
    line({ currency: 'USD', recognised: 40, net_earned: 40, policy_count: 1 }),
  ];
});

const mount = () => render(<MemoryRouter><CommissionEarned /></MemoryRouter>);

describe('commission earned report', () => {
  it('asks the server for the period, grouped by month, leaving imported policies out', async () => {
    mount();
    await screen.findByText('Total commission earned:');
    expect(rpcMock).toHaveBeenCalledWith('ins_report_commission_earned', expect.objectContaining({ p_group_by: 'month', p_include_imported: false }));
  });

  it('asks again with imported policies when the switch is turned on', async () => {
    mount();
    await screen.findByText('Total commission earned:');
    await userEvent.click(screen.getByRole('checkbox', { name: 'Include imported policies' }));
    await screen.findByText('Total commission earned:');
    expect(rpcMock).toHaveBeenLastCalledWith('ins_report_commission_earned', expect.objectContaining({ p_include_imported: true }));
  });

  it('totals net earned for each currency on its own', async () => {
    mount();
    await screen.findByText('Total commission earned:');
    const text = (document.body.textContent ?? '').replace(/\s+/g, ' ');
    expect(text).toContain('Total commission earned: USh 750 US$40.00'); // UGX 500 + 250, USD on its own
    expect(text).not.toContain('790');
  });

  it('exports what is shown and names the period in the PDF subtitle', async () => {
    mount();
    await userEvent.click(await screen.findByRole('button', { name: 'Export PDF' }));
    const [name, title, , rows, subtitle] = mockPdf.mock.calls[0];
    expect(name).toMatch(/^commission-earned-/);
    expect(title).toBe('Commission earned');
    expect(rows).toHaveLength(3);
    expect(subtitle).toContain(' to ');
    expect(subtitle).toContain('By month');
    expect(subtitle).not.toContain('imported');
  });

  it('offers no export when nothing was earned', async () => {
    report = [];
    mount();
    await screen.findByText('No commission was earned in this period.');
    expect(screen.queryByRole('button', { name: 'Export PDF' })).not.toBeInTheDocument();
  });
});
