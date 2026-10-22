import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import RenewalsList from './RenewalsList';

let canManage = false;
vi.mock('../../access', () => ({ useInsuranceAccess: () => ({ canManage, loading: false }) }));
// The notification sweep is covered in renewalNotificationSweep.test.ts; keep it out of these rpc assertions.
vi.mock('../../renewalNotificationSweep', () => ({ useRenewalNotificationSweep: () => undefined }));

const rpcCalls: { fn: string; args: Record<string, unknown> }[] = [];
let bulkResponse: unknown = [];
let pipeline: unknown[] = [];
vi.mock('../../../../../lib/supabaseClient', () => ({
  supabase: {
    from: () => {
      const chain: Record<string, unknown> = {};
      for (const m of ['select', 'order']) chain[m] = vi.fn(() => chain);
      (chain as { then: unknown }).then = (resolve: (v: unknown) => void) => resolve({ data: pipeline, error: null });
      return chain;
    },
    rpc: (fn: string, args: Record<string, unknown>) => {
      rpcCalls.push({ fn, args });
      return Promise.resolve({ data: fn === 'ins_create_renewal_drafts' ? bulkResponse : null, error: null });
    },
  },
}));

const row = (over: Record<string, unknown>) => ({
  policy_id: 'p', policy_no: 'POL-0', client_name: 'Client', insurer_name: 'Jubilee', product_name: 'Motor',
  inception_date: '2025-12-01', expiry_date: '2026-12-01', days_to_expiry: 40, gross_premium: 1000, commission_rate_pct: 10,
  currency: 'UGX', renewal_draft_id: null, renewal_outcome: null, renewal_outcome_reason: null, ...over,
});

function mount() {
  render(<MemoryRouter><RenewalsList /></MemoryRouter>);
}

beforeEach(() => {
  canManage = false; rpcCalls.length = 0; bulkResponse = [];
  pipeline = [
    row({ policy_id: 'p1', policy_no: 'POL-1' }),
    row({ policy_id: 'p2', policy_no: 'POL-2' }),
    row({ policy_id: 'p3', policy_no: 'POL-3', renewal_draft_id: 'd3' }),
    row({ policy_id: 'p4', policy_no: 'POL-4', renewal_outcome: 'lost', renewal_outcome_reason: 'Went to another broker' }),
  ];
});

describe('renewals list', () => {
  it('counts only open policies and keeps closed ones apart', async () => {
    mount();
    await screen.findByText('POL-1');
    expect(screen.getByText('All open (3)')).toBeInTheDocument();
    expect(screen.getByText('Closed out (1)')).toBeInTheDocument();
    expect(screen.queryByText('POL-4')).not.toBeInTheDocument();
    await userEvent.click(screen.getByText('Closed out (1)'));
    expect(await screen.findByText('POL-4')).toBeInTheDocument();
    expect(screen.getByText('Lost to another broker or insurer')).toBeInTheDocument();
  });

  it('does not let a policy that already has a draft be ticked', async () => {
    mount();
    await screen.findByText('POL-1');
    expect(screen.getByLabelText('Select POL-3')).toBeDisabled();
    expect(screen.getByLabelText('Select POL-1')).toBeEnabled();
  });

  it('opens drafts for the ticked policies in one call and reports refusals', async () => {
    bulkResponse = [
      { policy_id: 'p1', policy_no: 'POL-1', ok: true, draft_id: 'd1' },
      { policy_id: 'p2', policy_no: 'POL-2', ok: false, error: 'INS_RENEWAL_CLOSED: a renewal outcome is recorded for this policy' },
    ];
    mount();
    await userEvent.click(await screen.findByLabelText('Select POL-1'));
    await userEvent.click(screen.getByLabelText('Select POL-2'));
    await userEvent.click(screen.getByRole('button', { name: 'Start 2 renewals' }));
    await waitFor(() => expect(rpcCalls).toEqual([{ fn: 'ins_create_renewal_drafts', args: { p_policy_ids: ['p1', 'p2'] } }]));
    expect(await screen.findByText(/1 renewal draft opened, 1 not opened/)).toBeInTheDocument();
    expect(screen.getByText(/POL-2: a renewal outcome is recorded for this policy/)).toBeInTheDocument();
  });

  it('selects every eligible policy with the header box', async () => {
    mount();
    await userEvent.click(await screen.findByLabelText('Select all policies without a renewal draft'));
    expect(screen.getByRole('button', { name: 'Start 2 renewals' })).toBeInTheDocument();
  });

  it('closes out a renewal only with an outcome and a reason', async () => {
    mount();
    const rowEl = (await screen.findByText('POL-1')).closest('tr') as HTMLElement;
    await userEvent.click(within(rowEl).getByRole('button', { name: 'Close out' }));
    const dialog = await screen.findByRole('dialog');
    const submit = within(dialog).getByRole('button', { name: 'Close out' });
    expect(submit).toBeDisabled();
    await userEvent.click(within(dialog).getByLabelText('What happened'));
    await userEvent.click(await screen.findByRole('option', { name: 'Client declined to renew' }));
    await userEvent.type(within(dialog).getByLabelText(/Reason/), 'Closing the business');
    await userEvent.click(submit);
    await waitFor(() => expect(rpcCalls).toEqual([{ fn: 'ins_record_renewal_outcome', args: { p_policy_id: 'p1', p_outcome: 'declined', p_reason: 'Closing the business' } }]));
  });

  it('offers Reopen on a closed renewal to managers only', async () => {
    mount();
    await userEvent.click(await screen.findByText('Closed out (1)'));
    await screen.findByText('POL-4');
    expect(screen.queryByRole('button', { name: 'Reopen' })).not.toBeInTheDocument();
  });

  it('lets a manager reopen a closed renewal', async () => {
    canManage = true; mount();
    await userEvent.click(await screen.findByText('Closed out (1)'));
    await userEvent.click(await screen.findByRole('button', { name: 'Reopen' }));
    await waitFor(() => expect(rpcCalls).toEqual([{ fn: 'ins_clear_renewal_outcome', args: { p_policy_id: 'p4' } }]));
  });
});
