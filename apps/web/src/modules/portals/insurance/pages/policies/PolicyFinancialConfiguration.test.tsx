import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import PolicyFinancialConfiguration from './PolicyFinancialConfiguration';
import type { FinancialDetails } from '../../financialConfiguration';
const { call, rowCall } = vi.hoisted(() => ({
  call: vi.fn(),
  rowCall: vi.fn(),
}));
vi.mock('../../db', () => ({
  rpc: call,
  rows: rowCall,
  errorText: (e: Error) => e.message,
  table: () => {
    const q = { select: () => q, eq: () => q, order: () => q };
    return q;
  },
}));
vi.mock('../../../../../lib/reportExport', () => ({
  exportReportToPdf: vi.fn(),
  exportReportToExcel: vi.fn(),
}));
let details: FinancialDetails;
beforeEach(() => {
  details = {
    policy_id: 'p1',
    policy_no: 'POL-01',
    status: 'draft',
    currency: 'UGX',
    gross_premium: 1000,
    shares: [],
    charges: [],
    snapshot: null,
    can_configure: true,
    client_name: 'Acme',
  };
  rowCall.mockReset().mockResolvedValue([{ id: 'ins-a', name: 'Alpha' }]);
  call
    .mockReset()
    .mockImplementation(async (name: string) =>
      name === 'ins_policy_financial_details'
        ? details
        : name === 'ins_policy_charge_income_accounts'
          ? []
          : undefined,
    );
});
describe('policy financial configuration', () => {
  it('leaves the single-insurer path available without configuration', async () => {
    render(<PolicyFinancialConfiguration policyId="p1" onChanged={vi.fn()} />);
    await screen.findByText(/Single insurer from policy header/);
    expect(
      screen.getByRole('button', { name: 'Save financial configuration' }),
    ).toBeDisabled();
  });
  it('marks unsaved configuration as dirty so the parent can prevent binding', async () => {
    const dirty = vi.fn();
    render(
      <PolicyFinancialConfiguration
        policyId="p1"
        onChanged={vi.fn()}
        onDirtyChange={dirty}
      />,
    );
    fireEvent.click(
      await screen.findByRole('button', { name: 'Add insurer share' }),
    );
    await waitFor(() => expect(dirty).toHaveBeenLastCalledWith(true));
    expect(screen.getByText(/Unsaved configuration/)).toBeInTheDocument();
  });
  it('locks all financial editing after binding and identifies the claims limitation', async () => {
    details.status = 'active';
    details.shares = [
      {
        id: 's1',
        insurer_id: 'ins-a',
        insurer_name: 'Alpha',
        is_lead: true,
        share_pct: 100,
        commission_rate_pct: 10,
        insurer_policy_no: 'A-01',
        reviewed: true,
      },
    ];
    render(<PolicyFinancialConfiguration policyId="p1" onChanged={vi.fn()} />);
    await screen.findByText('Alpha (lead)');
    expect(
      screen.queryByRole('button', { name: 'Add insurer share' }),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByRole('button', { name: 'Save financial configuration' }),
    ).not.toBeInTheDocument();
    expect(
      screen.getByText(/Claims remain lead-insurer-based/),
    ).toBeInTheDocument();
  });
  it('retains blank renewal amounts and requires fresh review', async () => {
    details.charges = [
      {
        kind: 'broker_fee',
        description: 'Renewed broker fee',
        amount: null,
        recipient_mode: 'broker',
        recipient_insurer_id: null,
        vat_mode: 'not_calculated',
        vat_rate_pct: null,
        income_gl_account_id: null,
        reviewed: false,
      },
    ];
    render(<PolicyFinancialConfiguration policyId="p1" onChanged={vi.fn()} />);
    expect(await screen.findByLabelText('Current charge amount')).toHaveValue(
      null,
    );
    expect(
      screen.getByRole('checkbox', {
        name: 'Charge and tax treatment reviewed',
      }),
    ).not.toBeChecked();
  });
  it('does not offer financial configuration to an Insurance member', async () => {
    details.can_configure = false;
    render(<PolicyFinancialConfiguration policyId="p1" onChanged={vi.fn()} />);
    await screen.findByText('Insurer shares & policy charges');
    expect(
      screen.queryByRole('button', { name: 'Add charge line' }),
    ).not.toBeInTheDocument();
    expect(call).not.toHaveBeenCalledWith('ins_policy_charge_income_accounts');
  });
});
