import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import OpportunityStagesAdmin from './OpportunityStagesAdmin';
import { mockSupabaseTable } from '../../../../../test/lookupAdminHarness';

// Most complex of the BD lookup-admin family: stages carry a
// probability_default that drives the Pipeline Board's weighted
// forecast (value x probability), so handleStageChange's
// label/probability/color cascade when the enum dropdown changes is
// worth locking down on its own, separately from the generic CRUD
// coverage shared with the simpler lookup pages.

const mockFrom = vi.fn();
vi.mock('../../../../../lib/supabaseClient', () => ({
  supabase: { from: (...args: unknown[]) => mockFrom(...args) },
}));

const mockUseAuth = vi.fn();
vi.mock('../../../../../lib/authContext', () => ({
  useAuth: () => mockUseAuth(),
}));

const STAGE_A = {
  id: 'os1',
  tenant_id: 't1',
  stage: 'identification',
  label: 'Identification',
  order_index: 0,
  probability_default: 10,
  color: '#90caf9',
  is_active: true,
};

beforeEach(() => {
  mockFrom.mockReset();
  mockUseAuth.mockReturnValue({ session: { user: { id: 'u1', user_metadata: {} } } });
  vi.restoreAllMocks();
});

describe('OpportunityStagesAdmin', () => {
  it('shows the seed-defaults empty state and bulk-inserts all 6 stages in order with their default probabilities', async () => {
    const user = userEvent.setup();
    const { calls } = mockSupabaseTable(mockFrom, 'bd_opportunity_stages', { rows: [] });

    render(<OpportunityStagesAdmin />);
    await waitFor(() => expect(screen.getByText(/No stages yet/)).toBeInTheDocument());

    await user.click(screen.getByRole('button', { name: 'Seed Default 6 Stages' }));

    await waitFor(() => expect(calls.inserts).toHaveLength(6));
    expect(calls.inserts.map((i: any) => i.stage)).toEqual([
      'identification',
      'qualification',
      'proposal',
      'negotiation',
      'closed_won',
      'closed_lost',
    ]);
    expect(calls.inserts.map((i: any) => i.probability_default)).toEqual([10, 25, 50, 75, 100, 0]);
    expect(calls.inserts.map((i: any) => i.order_index)).toEqual([0, 1, 2, 3, 4, 5]);
  });

  it('lists a stage with its enum, order, and probability', async () => {
    mockSupabaseTable(mockFrom, 'bd_opportunity_stages', { rows: [STAGE_A] });

    render(<OpportunityStagesAdmin />);

    await waitFor(() => expect(screen.getByText('identification')).toBeInTheDocument());
    expect(screen.getByText('Identification')).toBeInTheDocument();
    expect(screen.getByText('10%')).toBeInTheDocument();
  });

  it('a new stage defaults order_index to the current stage count', async () => {
    const user = userEvent.setup();
    const { calls } = mockSupabaseTable(mockFrom, 'bd_opportunity_stages', { rows: [STAGE_A] });

    render(<OpportunityStagesAdmin />);
    await waitFor(() => expect(screen.getByText('Identification')).toBeInTheDocument());

    await user.click(screen.getByRole('button', { name: 'New Stage' }));
    // order_index defaults to stages.length (1), shown in the Order Index field
    expect(screen.getByLabelText('Order Index')).toHaveValue(1);

    await user.click(screen.getByRole('button', { name: 'Create' }));

    await waitFor(() => expect(calls.inserts).toHaveLength(1));
    expect(calls.inserts[0]).toMatchObject({ order_index: 1, stage: 'identification' });
  });

  it('changing the stage dropdown cascades label, probability, and color from STAGE_OPTIONS', async () => {
    const user = userEvent.setup();
    const { calls } = mockSupabaseTable(mockFrom, 'bd_opportunity_stages', { rows: [] });

    render(<OpportunityStagesAdmin />);
    await waitFor(() => expect(screen.getByText(/No stages yet/)).toBeInTheDocument());

    await user.click(screen.getByRole('button', { name: 'New Stage' }));
    await user.click(screen.getByLabelText('Stage Enum *'));
    await user.click(await screen.findByRole('option', { name: 'Negotiation (negotiation)' }));

    expect(screen.getByLabelText('Display Label *')).toHaveValue('Negotiation');
    expect(screen.getByText('Default Probability: 75%')).toBeInTheDocument();

    await user.click(screen.getByRole('button', { name: 'Create' }));

    await waitFor(() => expect(calls.inserts).toHaveLength(1));
    expect(calls.inserts[0]).toMatchObject({
      stage: 'negotiation',
      label: 'Negotiation',
      probability_default: 75,
      color: '#ff8a65',
    });
  });

  it('editing preserves a custom label across a stage-enum change (label only auto-fills when it still matches the previous stage default)', async () => {
    const user = userEvent.setup();
    const { calls } = mockSupabaseTable(mockFrom, 'bd_opportunity_stages', {
      rows: [{ ...STAGE_A, label: 'Custom Discovery Phase' }],
    });

    render(<OpportunityStagesAdmin />);
    await waitFor(() => expect(screen.getByText('Custom Discovery Phase')).toBeInTheDocument());

    const row = screen.getByText('identification').closest('tr') as HTMLElement;
    await user.click(within(row).getAllByRole('button')[0]); // Edit
    expect(screen.getByDisplayValue('Custom Discovery Phase')).toBeInTheDocument();

    await user.click(screen.getByLabelText('Stage Enum *'));
    await user.click(await screen.findByRole('option', { name: 'Proposal (proposal)' }));

    // custom label survives the enum change since it doesn't match the
    // outgoing stage's default label
    expect(screen.getByLabelText('Display Label *')).toHaveValue('Custom Discovery Phase');

    await user.click(screen.getByRole('button', { name: 'Update' }));

    await waitFor(() => expect(calls.updates).toHaveLength(1));
    expect(calls.updates[0].payload).toMatchObject({
      stage: 'proposal',
      label: 'Custom Discovery Phase',
      probability_default: 50,
    });
  });

  it('delete: confirms, deletes, and refetches', async () => {
    const user = userEvent.setup();
    vi.spyOn(window, 'confirm').mockReturnValue(true);
    const { calls } = mockSupabaseTable(mockFrom, 'bd_opportunity_stages', { rows: [STAGE_A] });

    render(<OpportunityStagesAdmin />);
    await waitFor(() => expect(screen.getByText('Identification')).toBeInTheDocument());

    const row = screen.getByText('identification').closest('tr') as HTMLElement;
    const iconButtons = within(row).getAllByRole('button');
    await user.click(iconButtons[iconButtons.length - 1]); // Delete

    await waitFor(() => expect(calls.deletes).toEqual(['os1']));
    expect(calls.selectCount).toBe(2);
  });

  it('a failed delete alerts and leaves the stage in place', async () => {
    const user = userEvent.setup();
    vi.spyOn(window, 'confirm').mockReturnValue(true);
    const alertSpy = vi.spyOn(window, 'alert').mockImplementation(() => {});
    mockSupabaseTable(mockFrom, 'bd_opportunity_stages', {
      rows: [STAGE_A],
      deleteError: { message: 'violates foreign key constraint' },
    });

    render(<OpportunityStagesAdmin />);
    await waitFor(() => expect(screen.getByText('Identification')).toBeInTheDocument());

    const row = screen.getByText('identification').closest('tr') as HTMLElement;
    const iconButtons = within(row).getAllByRole('button');
    await user.click(iconButtons[iconButtons.length - 1]);

    await waitFor(() =>
      expect(alertSpy).toHaveBeenCalledWith(expect.stringContaining('violates foreign key constraint')),
    );
    expect(screen.getByText('Identification')).toBeInTheDocument();
  });
});
