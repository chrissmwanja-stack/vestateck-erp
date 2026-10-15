import { fireEvent, render, screen, within } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import CommissionStatements from './CommissionStatements';
const { from } = vi.hoisted(() => ({ from: vi.fn() }));
vi.mock('../../../../../lib/supabaseClient', () => ({ supabase: { from } }));
vi.mock('../../../../../lib/reportExport', () => ({
  exportReportToExcel: vi.fn(),
  exportReportToPdf: vi.fn(),
}));
const chain = (data: unknown[]) => {
  const q = {
    select: () => q,
    eq: () => q,
    neq: () => q,
    order: () => q,
    then: (resolve: (value: unknown) => void) => resolve({ data, error: null }),
  };
  return q;
};
describe('non-lead insurer commission statement', () => {
  it('projects the selected co-insurer allocation rather than the lead or full policy totals', async () => {
    const today = new Date().toISOString().slice(0, 10);
    from.mockImplementation((name: string) => {
      if (name === 'ins_insurers') return chain([{ id: 'beta', name: 'Beta' }]);
      if (name === 'ins_policies')
        return chain([
          {
            id: 'p1',
            policy_no: 'POL-CO',
            status: 'active',
            insurer_id: 'alpha',
            gross_premium: 1000,
            commission_rate_pct: 10,
            commission_amount: 140,
            net_premium_to_insurer: 860,
            bound_at: `${today}T08:00:00Z`,
            currency: 'UGX',
            ins_clients: { bd_clients: { name: 'Acme' } },
            ins_policy_insurer_shares: [
              {
                id: 'share-b',
                insurer_id: 'beta',
                premium_amount: 400,
                commission_rate_pct: 20,
                commission_amount: 80,
                payable_amount: 410,
              },
            ],
          },
        ]);
      return chain([
        {
          id: 'entry-b',
          policy_id: 'p1',
          insurer_id: 'beta',
          amount: 80,
          status: 'deferred',
        },
      ]);
    });
    render(<CommissionStatements />);
    fireEvent.mouseDown(
      await screen.findByRole('combobox', { name: 'Insurer' }),
    );
    fireEvent.click(await screen.findByRole('option', { name: 'Beta' }));
    fireEvent.click(screen.getByRole('button', { name: 'Generate' }));
    const row = (await screen.findByText('POL-CO')).closest('tr')!;
    expect(within(row).getByText('20%')).toBeInTheDocument();
    expect(within(row).queryByText('10%')).not.toBeInTheDocument();
    expect(within(row).getByText('Deferred')).toBeInTheDocument();
  });
});
