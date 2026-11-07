import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import RemittancePosition from './RemittancePosition';

let position: unknown[] = [];
const rpcCalls: { fn: string; args: Record<string, unknown> }[] = [];
vi.mock('../../../../../lib/supabaseClient', () => ({
  supabase: {
    rpc: (fn: string, args: Record<string, unknown>) => {
      rpcCalls.push({ fn, args });
      return Promise.resolve({ data: position, error: null });
    },
    from: () => {
      const chain: Record<string, unknown> = {};
      (chain as { then: unknown }).then = (resolve: (v: unknown) => void) => resolve({ data: [], error: null });
      return chain;
    },
  },
}));

const row = (over: Record<string, unknown>) => ({
  insurer_id: 'i1', insurer_name: 'Jubilee', currency: 'UGX', unremitted_amount: 1200000,
  earliest_receipt: '2026-10-01', earliest_deadline: '2026-10-05', status: 'overdue', ...over,
});

function mount() {
  render(<MemoryRouter><RemittancePosition /></MemoryRouter>);
}

beforeEach(() => {
  rpcCalls.length = 0;
  position = [
    row({}),
    row({ insurer_id: 'i2', insurer_name: 'UAP', currency: 'USD', unremitted_amount: 500,
          earliest_receipt: '2026-11-01', earliest_deadline: '2026-11-30', status: 'within_deadline' }),
  ];
});

describe('remittance position', () => {
  it('loads the position RPC with the as-of date and renders both insurers', async () => {
    mount();
    await screen.findByText('Jubilee');
    expect(rpcCalls[0].fn).toBe('ins_insurer_remittance_position');
    expect(rpcCalls[0].args.p_as_of).toMatch(/^\d{4}-\d{2}-\d{2}$/);
    expect(screen.getByText('UAP')).toBeInTheDocument();
    expect(screen.getByText('Overdue')).toBeInTheDocument();
    expect(screen.getByText('Within deadline')).toBeInTheDocument();
    // currencies are shown per row, never merged
    expect(screen.getByText('UGX')).toBeInTheDocument();
    expect(screen.getByText('USD')).toBeInTheDocument();
  });

  it('filters by status', async () => {
    mount();
    await screen.findByText('Jubilee');
    await userEvent.click(screen.getByLabelText('Status'));
    // 'Overdue' is also a status chip in the table, so pick the dropdown option by role.
    await userEvent.click(await screen.findByRole('option', { name: 'Overdue' }));
    expect(screen.getByText('Jubilee')).toBeInTheDocument();
    expect(screen.queryByText('UAP')).not.toBeInTheDocument();
  });

  it('shows the empty state when nothing is unremitted', async () => {
    position = [];
    mount();
    expect(await screen.findByText('Nothing unremitted.')).toBeInTheDocument();
  });
});
