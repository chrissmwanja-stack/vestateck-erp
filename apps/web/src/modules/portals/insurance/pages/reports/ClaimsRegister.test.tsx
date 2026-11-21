import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import ClaimsRegister from './ClaimsRegister';

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
  claim_id: 'c1', claim_no: 'CLM-00001', insurer_claim_ref: null, policy_id: 'p1', policy_no: 'POL-1', client_id: 'k1',
  client_name: 'Acme Ltd', insurer_id: 'i1', insurer_name: 'Alpha Assurance', product_line_id: 'l1', product_line_name: 'Fire',
  currency: 'UGX', loss_date: '2026-11-01', notified_date: '2026-11-02', status_as_at: 'notified', is_open: true,
  reserve_as_at: 500, approved_amount: null, paid_as_at: 0, outstanding_amount: 500, age_days: 19, days_since_activity: 19,
  age_bucket: '0-30', ...over,
});

beforeEach(() => {
  mockExcel.mockReset(); mockPdf.mockReset(); rpcMock.mockClear();
  report = [
    line({}),
    line({ claim_id: 'c2', claim_no: 'CLM-00002', policy_no: 'POL-2', client_name: 'Beta Co', insurer_name: 'Beta Re', currency: 'USD',
      status_as_at: 'approved', approved_amount: 250.5, paid_as_at: 50, reserve_as_at: 300, outstanding_amount: 200.5, age_days: 200,
      days_since_activity: 40, age_bucket: '180+' }),
  ];
});

const mount = () => render(<MemoryRouter><ClaimsRegister /></MemoryRouter>);

describe('claims register report', () => {
  it('asks the server for the chosen date, open claims by default', async () => {
    mount();
    await screen.findByText('CLM-00001');
    expect(rpcMock).toHaveBeenCalledWith('ins_report_claims_register', { p_as_of: expect.stringMatching(/^\d{4}-\d{2}-\d{2}$/), p_scope: 'open' });
  });

  it('lists each claim and totals currencies separately', async () => {
    mount();
    await screen.findByText('CLM-00001');
    expect(screen.getByText('CLM-00002')).toBeInTheDocument();
    expect(screen.getAllByText('Approved')).toHaveLength(2); // column header and the approved claim's status
    const text = (document.body.textContent ?? '').replace(/\s+/g, ' ');
    expect(text).toContain('Total outstanding: USh 500 US$200.50');
    expect(text).not.toContain('700');
  });

  it('exports every row shown, saying what it covers in the subtitle', async () => {
    mount();
    await userEvent.click(await screen.findByRole('button', { name: 'Export Excel' }));
    const [, , , rows] = mockExcel.mock.calls[0];
    expect(rows.map((r: { claim_no: string }) => r.claim_no)).toEqual(['CLM-00001', 'CLM-00002']);
    await userEvent.click(screen.getByRole('button', { name: 'Export PDF' }));
    const subtitle = mockPdf.mock.calls[0][4] as string;
    expect(subtitle).toContain('Open claims');
    expect(subtitle).toContain('Outstanding:');
  });

  it('offers no export when no claims were open', async () => {
    report = [];
    mount();
    await screen.findByText('No claims were open on this date.');
    expect(screen.queryByRole('button', { name: 'Export Excel' })).not.toBeInTheDocument();
  });
});
