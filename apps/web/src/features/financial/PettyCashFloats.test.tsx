import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { createQueryLog } from '../../test/queryChain';
import PettyCashFloats from './PettyCashFloats';

// PettyCashFloats manages the floats themselves (create / edit) and their
// replenishments. Client-side branching worth pinning down:
//
//  - creating a float looks up the tenant and sends tenant_id; EDITING a
//    float must not (the row already has one) and must not need the lookup;
//  - payloads are trimmed/parsed, and a replenishment funded from cash must
//    send bank_account as NULL even if one was typed before switching;
//  - validation and tenant-lookup failures stop the write; a failed write
//    keeps the form open with the database message;
//  - the list resolves cost center and custodian labels in batched queries
//    and falls back to a dash for rows it cannot resolve.

const FLOAT_ROW = {
  petty_cash_float_id: 'pf1',
  cost_center_id: 'cc1',
  custodian_user_id: 'u-cust',
  float_name: 'Site A float',
  ceiling_amount: 1000,
  currency: 'UGX',
  is_active: true,
  total_replenished: 1000,
  total_spent: 500,
  current_balance: 500,
};

const COST_CENTERS = [
  { id: 'cc1', tenant_id: 't1', name: 'Site A', project_code: 'PRJ-1', budget_amount: 0, created_at: '' },
];
const USERS = [
  { id: 'u-cust', name: 'Grace Auma' },
  { id: 'u-other', name: 'Brian Okello' },
];

const mockFrom = vi.fn();
const mockGetUser = vi.fn();
vi.mock('../../lib/supabaseClient', () => ({
  supabase: { from: (...args: unknown[]) => mockFrom(...args), auth: { getUser: () => mockGetUser() } },
}));

const q = createQueryLog();
let floatInserts: Record<string, unknown>[];
let floatUpdates: { payload: Record<string, unknown>; column: unknown; value: unknown }[];
let replenishInserts: Record<string, unknown>[];

function setup(
  opts: {
    floats?: unknown[];
    tenantId?: string | null;
    saveError?: { message: string } | null;
  } = {},
) {
  const { floats = [FLOAT_ROW], tenantId = 'tenant-42', saveError = null } = opts;
  q.reset();
  floatInserts = [];
  floatUpdates = [];
  replenishInserts = [];
  mockGetUser.mockResolvedValue({ data: { user: { id: 'u1' } } });

  mockFrom.mockImplementation((table: string) => {
    switch (table) {
      case 'petty_cash_float_balances':
        return q.chain(table, floats);
      case 'cost_centers':
        return q.chain(table, COST_CENTERS);
      case 'app_users': {
        // Serves the custodian list/labels (awaited chain) and the tenant
        // lookup (.eq().single()).
        const t = q.chain(table, USERS);
        t.single = () => Promise.resolve({ data: tenantId ? { tenant_id: tenantId } : null, error: null });
        return t;
      }
      case 'petty_cash_floats':
        return {
          insert: (payload: Record<string, unknown>) => {
            floatInserts.push(payload);
            return Promise.resolve({ error: saveError });
          },
          update: (payload: Record<string, unknown>) => ({
            eq: (column: unknown, value: unknown) => {
              floatUpdates.push({ payload, column, value });
              return Promise.resolve({ error: saveError });
            },
          }),
        };
      case 'petty_cash_replenishments':
        return {
          insert: (payload: Record<string, unknown>) => {
            replenishInserts.push(payload);
            return Promise.resolve({ error: saveError });
          },
        };
      default:
        throw new Error(`setup: no handler for table "${table}"`);
    }
  });
}

beforeEach(() => {
  vi.clearAllMocks();
});

type User = ReturnType<typeof userEvent.setup>;

async function openNewFloat(user: User) {
  await user.click(screen.getByRole('button', { name: /new/i }));
  const heading = await screen.findByRole('heading', { name: 'New Petty Cash Float' });
  return within(heading.parentElement as HTMLElement);
}

type Form = Awaited<ReturnType<typeof openNewFloat>>;

async function pick(user: User, form: Form, label: RegExp, optionName: string) {
  await user.click(form.getByLabelText(label));
  await user.click(await screen.findByRole('option', { name: optionName }));
}

async function fillNewFloat(user: User, form: Form, ceiling = '1000') {
  await user.type(form.getByLabelText(/^float name/i), '  Site B float ');
  await pick(user, form, /^cost center/i, 'PRJ-1 — Site A');
  await pick(user, form, /^custodian/i, 'Grace Auma');
  await user.type(form.getByLabelText(/^ceiling amount/i), ceiling);
}

async function openReplenish(user: User) {
  await screen.findByText('Site A float');
  await user.click(screen.getByRole('button', { name: /replenish/i }));
  const heading = await screen.findByRole('heading', { name: /^Replenish — Site A float/ });
  return within(heading.parentElement as HTMLElement);
}

describe('PettyCashFloats', () => {
  describe('list', () => {
    it('resolves cost center and custodian labels in one batched query each', async () => {
      setup();
      render(<PettyCashFloats />);

      const row = (await screen.findByText('Site A float')).closest('tr') as HTMLElement;
      expect(within(row).getByText('PRJ-1 Site A')).toBeInTheDocument();
      expect(within(row).getByText('Grace Auma')).toBeInTheDocument();
      expect(within(row).getByText('Active')).toBeInTheDocument();
      expect(q.callsTo('cost_centers', 'in')).toHaveLength(1);
      expect(q.callsTo('cost_centers', 'in')[0].args).toEqual(['id', ['cc1']]);
    });

    it('shows a dash for a custodian that cannot be resolved', async () => {
      setup({ floats: [{ ...FLOAT_ROW, custodian_user_id: 'u-gone' }] });
      render(<PettyCashFloats />);

      const row = (await screen.findByText('Site A float')).closest('tr') as HTMLElement;
      expect(within(row).getByText('—')).toBeInTheDocument();
    });

    it('shows the empty state and skips the label lookups when there are no floats', async () => {
      setup({ floats: [] });
      render(<PettyCashFloats />);

      expect(await screen.findByText('No petty cash floats set up yet.')).toBeInTheDocument();
      expect(q.callsTo('cost_centers', 'in')).toHaveLength(0);
    });

    it('shows a load error when the query fails', async () => {
      setup();
      mockFrom.mockImplementation((table: string) =>
        table === 'petty_cash_float_balances' ? q.chain(table, [], new Error('JWT expired')) : q.chain(table, []),
      );
      render(<PettyCashFloats />);

      expect(await screen.findByText('JWT expired')).toBeInTheDocument();
    });
  });

  describe('creating a float', () => {
    it('sends the tenant_id and a clean payload', async () => {
      const user = userEvent.setup();
      setup();
      render(<PettyCashFloats />);
      await screen.findByText('Site A float');
      const form = await openNewFloat(user);

      await fillNewFloat(user, form);
      await user.click(form.getByRole('button', { name: 'Save' }));

      await waitFor(() => expect(floatInserts).toHaveLength(1));
      expect(floatInserts[0]).toEqual({
        float_name: 'Site B float',
        cost_center_id: 'cc1',
        custodian_user_id: 'u-cust',
        ceiling_amount: 1000,
        currency: 'UGX',
        is_active: true,
        tenant_id: 'tenant-42',
      });
      expect(floatUpdates).toHaveLength(0);
    });

    it('requires a name, cost center, custodian and ceiling before any lookup', async () => {
      const user = userEvent.setup();
      setup();
      render(<PettyCashFloats />);
      await screen.findByText('Site A float');
      const form = await openNewFloat(user);

      await user.click(form.getByRole('button', { name: 'Save' }));

      expect(await form.findByText('Name, cost center, custodian, and ceiling amount are required.')).toBeInTheDocument();
      expect(mockGetUser).not.toHaveBeenCalled();
      expect(floatInserts).toHaveLength(0);
    });

    it.each([['0'], ['-100']])('rejects a ceiling of %s', async (ceiling) => {
      const user = userEvent.setup();
      setup();
      render(<PettyCashFloats />);
      await screen.findByText('Site A float');
      const form = await openNewFloat(user);

      await fillNewFloat(user, form, ceiling);
      await user.click(form.getByRole('button', { name: 'Save' }));

      expect(await form.findByText('Ceiling amount must be a valid number greater than 0.')).toBeInTheDocument();
      expect(floatInserts).toHaveLength(0);
    });

    it('does not insert when the tenant cannot be determined', async () => {
      const user = userEvent.setup();
      setup({ tenantId: null });
      render(<PettyCashFloats />);
      await screen.findByText('Site A float');
      const form = await openNewFloat(user);

      await fillNewFloat(user, form);
      await user.click(form.getByRole('button', { name: 'Save' }));

      expect(await form.findByText('Could not determine your tenant. Contact an admin.')).toBeInTheDocument();
      expect(floatInserts).toHaveLength(0);
    });

    it('keeps the form open and shows the database error when the insert fails', async () => {
      const user = userEvent.setup();
      setup({ saveError: { message: 'row-level security policy violation' } });
      render(<PettyCashFloats />);
      await screen.findByText('Site A float');
      const form = await openNewFloat(user);

      await fillNewFloat(user, form);
      await user.click(form.getByRole('button', { name: 'Save' }));

      expect(await form.findByText('row-level security policy violation')).toBeInTheDocument();
      expect(screen.getByRole('heading', { name: 'New Petty Cash Float' })).toBeInTheDocument();
    });
  });

  describe('editing a float', () => {
    it('updates by id without tenant_id and without the tenant lookup', async () => {
      const user = userEvent.setup();
      setup();
      render(<PettyCashFloats />);
      await screen.findByText('Site A float');

      await user.click(screen.getByRole('button', { name: /^edit/i }));
      const heading = await screen.findByRole('heading', { name: 'Edit Petty Cash Float' });
      const form = within(heading.parentElement as HTMLElement);
      expect(form.getByLabelText(/^float name/i)).toHaveValue('Site A float');
      expect(form.getByLabelText(/^ceiling amount/i)).toHaveValue(1000);

      const ceiling = form.getByLabelText(/^ceiling amount/i);
      await user.clear(ceiling);
      await user.type(ceiling, '1500');
      await user.click(form.getByRole('button', { name: 'Save' }));

      await waitFor(() => expect(floatUpdates).toHaveLength(1));
      expect(floatUpdates[0]).toEqual({
        payload: {
          float_name: 'Site A float',
          cost_center_id: 'cc1',
          custodian_user_id: 'u-cust',
          ceiling_amount: 1500,
          currency: 'UGX',
          is_active: true,
        },
        column: 'id',
        value: 'pf1',
      });
      expect(floatUpdates[0].payload).not.toHaveProperty('tenant_id');
      expect(floatInserts).toHaveLength(0);
      expect(mockGetUser).not.toHaveBeenCalled();
    });
  });

  describe('replenishing a float', () => {
    it('sends a bank replenishment with a trimmed bank account and the float id', async () => {
      const user = userEvent.setup();
      setup();
      render(<PettyCashFloats />);
      const form = await openReplenish(user);

      await user.type(form.getByLabelText(/^amount/i), '400');
      await user.type(form.getByLabelText(/^date/i), '2026-09-03');
      await user.type(form.getByLabelText(/^bank account/i), '  Stanbic-001 ');
      await user.type(form.getByLabelText(/^description/i), '  Top-up ');
      await user.click(form.getByRole('button', { name: 'Record Replenishment' }));

      await waitFor(() => expect(replenishInserts).toHaveLength(1));
      expect(replenishInserts[0]).toEqual({
        tenant_id: 'tenant-42',
        petty_cash_float_id: 'pf1',
        amount: 400,
        replenished_date: '2026-09-03',
        funded_from: 'bank',
        bank_account: 'Stanbic-001',
        description: 'Top-up',
      });
    });

    it('sends bank_account as null for a cash replenishment even if one was typed first', async () => {
      const user = userEvent.setup();
      setup();
      render(<PettyCashFloats />);
      const form = await openReplenish(user);

      await user.type(form.getByLabelText(/^amount/i), '400');
      await user.type(form.getByLabelText(/^date/i), '2026-09-03');
      await user.type(form.getByLabelText(/^bank account/i), 'Stanbic-001');
      await user.click(form.getByLabelText(/^funded from/i));
      await user.click(await screen.findByRole('option', { name: 'Cash' }));
      expect(form.queryByLabelText(/^bank account/i)).not.toBeInTheDocument();
      await user.click(form.getByRole('button', { name: 'Record Replenishment' }));

      await waitFor(() => expect(replenishInserts).toHaveLength(1));
      expect(replenishInserts[0]).toMatchObject({ funded_from: 'cash', bank_account: null, description: null });
    });

    it('requires an amount and a date', async () => {
      const user = userEvent.setup();
      setup();
      render(<PettyCashFloats />);
      const form = await openReplenish(user);

      await user.click(form.getByRole('button', { name: 'Record Replenishment' }));

      expect(await form.findByText('Amount and date are required.')).toBeInTheDocument();
      expect(replenishInserts).toHaveLength(0);
    });

    it('rejects a zero amount', async () => {
      const user = userEvent.setup();
      setup();
      render(<PettyCashFloats />);
      const form = await openReplenish(user);

      await user.type(form.getByLabelText(/^amount/i), '0');
      await user.type(form.getByLabelText(/^date/i), '2026-09-03');
      await user.click(form.getByRole('button', { name: 'Record Replenishment' }));

      expect(await form.findByText('Amount must be a valid number greater than 0.')).toBeInTheDocument();
      expect(replenishInserts).toHaveLength(0);
    });

    it('keeps the form open and shows the database error when the insert fails', async () => {
      const user = userEvent.setup();
      setup({ saveError: { message: 'insufficient privilege' } });
      render(<PettyCashFloats />);
      const form = await openReplenish(user);

      await user.type(form.getByLabelText(/^amount/i), '400');
      await user.type(form.getByLabelText(/^date/i), '2026-09-03');
      await user.click(form.getByRole('button', { name: 'Record Replenishment' }));

      expect(await form.findByText('insufficient privilege')).toBeInTheDocument();
      expect(screen.getByRole('heading', { name: /^Replenish — Site A float/ })).toBeInTheDocument();
    });
  });
});