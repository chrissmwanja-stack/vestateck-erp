import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { createQueryLog } from '../../test/queryChain';
import ExpenditureSlips from './ExpenditureSlips';

// ExpenditureSlips records money spent against a cost center, optionally
// drawn from a petty cash float. Client-side branching worth pinning down:
//
//  - the insert payload: the tenant_id looked up from app_users, trimmed
//    text, a numeric amount, and NULL (not '') for the optional
//    organization and petty cash float;
//  - petty cash floats offered are only the ACTIVE floats of the chosen
//    cost center; the "exceeds balance" warning is advisory -- it must not
//    block the save (the float simply needs replenishing);
//  - validation and tenant-lookup failures stop the write;
//  - the list resolves embedded cost center / organization / recorder
//    objects whether PostgREST returns them as an object or an array, and
//    the search filters reach the query.

const SLIP_ROW = {
  id: 'sl1',
  slip_number: 'SLP-001',
  slip_date: '2026-09-01',
  payee_name: 'Hardware Ltd',
  purpose: 'Nails',
  amount: 250,
  currency: 'UGX',
  created_at: '2026-09-01T09:00:00Z',
  petty_cash_float_id: null,
  cost_centers: [{ name: 'Site A', project_code: 'PRJ-1' }],
  organization: { company_code: 'CO1', site_name: 'Kampala HQ' },
  recorded_by_user: [{ name: 'Amina' }],
};

const COST_CENTERS = [
  { id: 'cc1', tenant_id: 't1', name: 'Site A', project_code: 'PRJ-1', budget_amount: 0, created_at: '' },
  { id: 'cc2', tenant_id: 't1', name: 'Site B', project_code: 'PRJ-2', budget_amount: 0, created_at: '' },
];
const FLOAT_CC1 = {
  petty_cash_float_id: 'pf1',
  float_name: 'Petty A',
  cost_center_id: 'cc1',
  ceiling_amount: 1000,
  current_balance: 500,
  currency: 'UGX',
  is_active: true,
};
const FLOAT_CC2 = { ...FLOAT_CC1, petty_cash_float_id: 'pf2', float_name: 'Petty B', cost_center_id: 'cc2' };

const mockFrom = vi.fn();
const mockGetUser = vi.fn();
vi.mock('../../lib/supabaseClient', () => ({
  supabase: { from: (...args: unknown[]) => mockFrom(...args), auth: { getUser: () => mockGetUser() } },
}));

const q = createQueryLog();
let inserts: Record<string, unknown>[];

function setup(
  opts: {
    slips?: unknown[];
    floats?: unknown[];
    insertError?: { message: string } | null;
    tenantId?: string | null;
    profileError?: { message: string } | null;
  } = {},
) {
  const { slips = [SLIP_ROW], floats = [FLOAT_CC1, FLOAT_CC2], insertError = null, tenantId = 'tenant-42', profileError = null } = opts;
  q.reset();
  inserts = [];
  mockGetUser.mockResolvedValue({ data: { user: { id: 'u1' } } });

  mockFrom.mockImplementation((table: string) => {
    switch (table) {
      case 'expenditure_slips': {
        const t = q.chain(table, slips);
        t.insert = (payload: Record<string, unknown>) => {
          inserts.push(payload);
          return Promise.resolve({ error: insertError });
        };
        return t;
      }
      case 'organizations':
        return q.chain(table, [{ id: 'org1', company_code: 'CO1', site_name: 'Kampala HQ' }]);
      case 'cost_centers':
        return q.chain(table, COST_CENTERS);
      case 'petty_cash_float_balances':
        return q.chain(table, floats);
      case 'app_users': {
        const t = q.chain(table, []);
        t.single = () =>
          Promise.resolve({ data: tenantId ? { tenant_id: tenantId } : null, error: profileError });
        return t;
      }
      default:
        throw new Error(`setup: no handler for table "${table}"`);
    }
  });
}

beforeEach(() => {
  vi.clearAllMocks();
});

async function openForm(user: ReturnType<typeof userEvent.setup>) {
  await user.click(screen.getByRole('button', { name: /new expenditure slip|^new/i }));
  const heading = await screen.findByRole('heading', { name: 'New Expenditure Slip' });
  return within(heading.parentElement as HTMLElement);
}

type Form = Awaited<ReturnType<typeof openForm>>;
type User = ReturnType<typeof userEvent.setup>;

async function pick(user: User, form: Form, label: RegExp, optionName: string) {
  await user.click(form.getByLabelText(label));
  await user.click(await screen.findByRole('option', { name: optionName }));
}

async function fillRequired(user: User, form: Form, amount = '300') {
  await pick(user, form, /^cost center/i, 'PRJ-1 — Site A');
  await user.type(form.getByLabelText(/^slip no/i), '  SLP-002 ');
  await user.type(form.getByLabelText(/^slip date/i), '2026-09-02');
  await user.type(form.getByLabelText(/^payee name/i), ' Hardware Ltd ');
  await user.type(form.getByLabelText(/^purpose/i), ' Cement ');
  await user.type(form.getByLabelText(/^amount/i), amount);
}

describe('ExpenditureSlips', () => {
  describe('saving a slip', () => {
    it('sends the tenant_id and a clean payload, with NULL for the optional organization and float', async () => {
      const user = userEvent.setup();
      setup();
      render(<ExpenditureSlips />);
      const form = await openForm(user);

      await fillRequired(user, form);
      await user.click(form.getByRole('button', { name: 'Save' }));

      await waitFor(() => expect(inserts).toHaveLength(1));
      expect(inserts[0]).toEqual({
        tenant_id: 'tenant-42',
        cost_center_id: 'cc1',
        organization_id: null,
        slip_number: 'SLP-002',
        slip_date: '2026-09-02',
        payee_name: 'Hardware Ltd',
        purpose: 'Cement',
        amount: 300,
        currency: 'UGX',
        petty_cash_float_id: null,
      });
      await waitFor(() => expect(screen.queryByRole('heading', { name: 'New Expenditure Slip' })).not.toBeInTheDocument());
    });

    it('offers only the active floats of the chosen cost center and sends the selected float', async () => {
      const user = userEvent.setup();
      setup();
      render(<ExpenditureSlips />);
      const form = await openForm(user);

      expect(form.getByText('Pick a cost center first to see its floats')).toBeInTheDocument();
      await pick(user, form, /^cost center/i, 'PRJ-1 — Site A');
      await user.click(form.getByLabelText(/^petty cash float/i));
      expect(await screen.findByRole('option', { name: 'Petty A — balance 500 UGX' })).toBeInTheDocument();
      expect(screen.queryByRole('option', { name: /Petty B/ })).not.toBeInTheDocument();
      // Inactive floats are excluded by the query itself, not client-side.
      expect(q.callsTo('petty_cash_float_balances', 'eq')[0].args).toEqual(['is_active', true]);
      await user.click(screen.getByRole('option', { name: 'Petty A — balance 500 UGX' }));

      await user.type(form.getByLabelText(/^slip no/i), 'SLP-003');
      await user.type(form.getByLabelText(/^slip date/i), '2026-09-02');
      await user.type(form.getByLabelText(/^payee name/i), 'Hardware Ltd');
      await user.type(form.getByLabelText(/^purpose/i), 'Cement');
      await user.type(form.getByLabelText(/^amount/i), '200');
      await user.click(form.getByRole('button', { name: 'Save' }));

      await waitFor(() => expect(inserts).toHaveLength(1));
      expect(inserts[0]).toMatchObject({ cost_center_id: 'cc1', petty_cash_float_id: 'pf1' });
    });

    it('only warns, and still saves, when the amount exceeds the float balance', async () => {
      const user = userEvent.setup();
      setup();
      render(<ExpenditureSlips />);
      const form = await openForm(user);

      await fillRequired(user, form, '800');
      await user.click(form.getByLabelText(/^petty cash float/i));
      await user.click(await screen.findByRole('option', { name: 'Petty A — balance 500 UGX' }));

      expect(await form.findByText(/exceeds the float's current balance \(500 UGX\)/i)).toBeInTheDocument();
      await user.click(form.getByRole('button', { name: 'Save' }));

      await waitFor(() => expect(inserts).toHaveLength(1));
      expect(inserts[0]).toMatchObject({ amount: 800, petty_cash_float_id: 'pf1' });
    });

    it('requires every core field before looking anything up', async () => {
      const user = userEvent.setup();
      setup();
      render(<ExpenditureSlips />);
      const form = await openForm(user);

      await user.click(form.getByRole('button', { name: 'Save' }));

      expect(
        await form.findByText('Cost center, slip number, date, payee, purpose, and amount are all required.'),
      ).toBeInTheDocument();
      expect(mockGetUser).not.toHaveBeenCalled();
      expect(inserts).toHaveLength(0);
    });

    it.each([['0'], ['-5']])('rejects an amount of %s', async (amount) => {
      const user = userEvent.setup();
      setup();
      render(<ExpenditureSlips />);
      const form = await openForm(user);

      await fillRequired(user, form, amount);
      await user.click(form.getByRole('button', { name: 'Save' }));

      expect(await form.findByText('Amount must be a valid number greater than 0.')).toBeInTheDocument();
      expect(inserts).toHaveLength(0);
    });

    it('does not insert when the tenant cannot be determined', async () => {
      const user = userEvent.setup();
      setup({ tenantId: null, profileError: { message: 'No rows found' } });
      render(<ExpenditureSlips />);
      const form = await openForm(user);

      await fillRequired(user, form);
      await user.click(form.getByRole('button', { name: 'Save' }));

      expect(await form.findByText('No rows found')).toBeInTheDocument();
      expect(inserts).toHaveLength(0);
    });

    it('keeps the form open and shows the database error when the insert fails', async () => {
      const user = userEvent.setup();
      setup({ insertError: { message: 'duplicate key value violates unique constraint' } });
      render(<ExpenditureSlips />);
      const form = await openForm(user);

      await fillRequired(user, form);
      await user.click(form.getByRole('button', { name: 'Save' }));

      expect(await form.findByText('duplicate key value violates unique constraint')).toBeInTheDocument();
      expect(screen.getByRole('heading', { name: 'New Expenditure Slip' })).toBeInTheDocument();
    });
  });

  describe('list and search', () => {
    it('resolves the cost center, organization and recorder from objects or one-element arrays', async () => {
      setup();
      render(<ExpenditureSlips />);

      const cell = await screen.findByText('SLP-001');
      const row = cell.closest('tr') as HTMLElement;
      expect(within(row).getByText('Hardware Ltd')).toBeInTheDocument();
      expect(within(row).getByText(/PRJ-1/)).toBeInTheDocument();
      expect(within(row).getByText(/CO1/)).toBeInTheDocument();
      expect(within(row).getByText('Amina')).toBeInTheDocument();
    });

    it('applies the search filters to the query and drops them on Clear', async () => {
      const user = userEvent.setup();
      setup();
      render(<ExpenditureSlips />);
      await screen.findByText('SLP-001');

      await user.type(screen.getByLabelText('Slip No'), ' 001 ');
      await user.type(screen.getByLabelText('Date From'), '2026-09-01');
      await user.type(screen.getByLabelText('Date To'), '2026-09-30');
      q.reset();
      await user.click(screen.getByRole('button', { name: 'Search' }));

      await waitFor(() => expect(q.callsTo('expenditure_slips', 'ilike')).toHaveLength(1));
      expect(q.callsTo('expenditure_slips', 'ilike')[0].args).toEqual(['slip_number', '%001%']);
      expect(q.callsTo('expenditure_slips', 'gte')[0].args).toEqual(['slip_date', '2026-09-01']);
      expect(q.callsTo('expenditure_slips', 'lte')[0].args).toEqual(['slip_date', '2026-09-30']);

      q.reset();
      await user.click(screen.getByRole('button', { name: 'Clear' }));
      await waitFor(() => expect(q.callsTo('expenditure_slips', 'select')).toHaveLength(1));
      expect(q.callsTo('expenditure_slips', 'ilike')).toHaveLength(0);
      expect(q.callsTo('expenditure_slips', 'gte')).toHaveLength(0);
    });

    it('shows a load error when the query fails', async () => {
      setup();
      mockFrom.mockImplementation((table: string) =>
        table === 'expenditure_slips' ? q.chain(table, [], new Error('JWT expired')) : q.chain(table, []),
      );
      render(<ExpenditureSlips />);

      expect(await screen.findByText('JWT expired')).toBeInTheDocument();
    });
  });
});