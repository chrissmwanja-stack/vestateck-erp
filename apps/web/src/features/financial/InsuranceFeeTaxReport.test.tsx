import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import InsuranceFeeTaxReport from './InsuranceFeeTaxReport';
const { call } = vi.hoisted(() => ({ call: vi.fn() }));
vi.mock('../../modules/portals/insurance/db', () => ({
  rpc: call,
  errorText: (e: Error) => e.message,
}));
vi.mock('../../lib/reportExport', () => ({
  exportReportToExcel: vi.fn(),
  exportReportToPdf: vi.fn(),
}));
describe('insurance fee VAT supplement', () => {
  it('shows VAT not calculated distinctly from an exemption, and uses the Finance-only RPC', async () => {
    call.mockResolvedValue([
      {
        charge_id: 'c1',
        policy_no: 'POL-01',
        invoice_date: '2026-10-15',
        description: 'Broker fee',
        currency: 'UGX',
        fee_amount: 50,
        vat_mode: 'not_calculated',
        vat_rate_pct: null,
        vat_amount: 0,
        invoice_line_total: 50,
        journal_entry_id: 'je1',
      },
    ]);
    render(<InsuranceFeeTaxReport />);
    fireEvent.click(screen.getByRole('button', { name: 'Run fee VAT report' }));
    await screen.findByText('VAT not calculated (not declared exempt)');
    expect(call).toHaveBeenCalledWith('ins_broker_fee_tax_rows', {
      p_date_from: null,
      p_date_to: null,
    });
    await waitFor(() =>
      expect(screen.getByRole('button', { name: 'Export PDF' })).toBeEnabled(),
    );
  });
});
