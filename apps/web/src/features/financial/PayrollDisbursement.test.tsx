
import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { createQueryLog } from '../../test/queryChain';
import PayrollDisbursement from './PayrollDisbursement';

// PayrollDisbursement is the Finance end of the HR -> PM -> Finance payroll
// flow: it records the cash/bank payment for an HR-approved run. Client-side
// branching worth pinning down:
//
//  - which runs can still be paid (a fully disbursed run, or one with
//    nothing remaining, has no button) and the amount the dialog suggests
//    (net pay total minus what has already gone out, to 2 decimals);
//  - the cash_bank_transactions payload: always a 'payment' against the
//    'payroll_run', the real tenant_id, UGX, trimmed bank account only for
//    bank payments, and a default description naming the period;
//  - validation (amount > 0, bank account for bank payments, a date) and
//    tenant-lookup failures stop the write; a failed insert keeps the dialog
//    open;
//  - people who are not on the finance team get an explanation.

const APPROVED = { id: 'run1', period: '2026-08', status: 'approved', approved_at: '2026-08-30T08:00:00Z', amount_disbursed: 0 };
const PARTIAL = { id: 'run2', period: '2026-07', status: 'approved', approved_at: '2026-07-30T08:00:00Z', amount_disbursed: 400000 };
const DONE = { id: 'run3', period: '2026-06', status: 'disbursed', approved_at: '2026-06-30T08:00:00Z', amount_disbursed: 1000000 };

const EMPLOYEE = (first: string, no: string) => ({ first_name: first, last_name: 'Test', employee_no: no });
const ITEMS = [
  { id: 'i1', payroll_run_id: 'run1', net_pay: 600000, hr_employees: EMPLOYEE('Amina', 'E-1') },
  { id: 'i2', payroll_run_id: 'run1', net_pay: 400000, hr_employees: EMPLOYEE('Brian', 'E-2') },
  { id: 'i3', payroll_run_id: 'run2', net_pay: 1000000, hr_employees: EMPLOYEE('Grace', 'E-3') },
  { id: 'i4', payroll_run_id: 'run3', net_pay: 1000000, hr_employees: EMPLOYEE('Okello', 'E-4') },
];

const mockFrom = vi.fn();
const mockRpc = vi.fn();
const mockGetUser = vi.fn();
vi.mock('../../lib/supabaseClient', () => ({
  supabase: {
    from: (...args: unknown[]) => mockFrom(...args),
    rpc: (...args: unknown[]) => mockRpc(...args),
    auth: { getUser: () => mockGetUser() },
  },
}));

const q = createQueryLog();
let inserts: Record<string, unknown>[];

function setup(
  opts: {
    runs?: unknown[];
    isFinance?: boolean;
    rpcError?: { message: string } | null;
    insertError?: { message: string } | null;
    tenantId?: string | null;
    runsError?: Error | null;
  } = {},
) {
  const { runs = [APPROVED], isFinance = true, rpcError = null, insertError = null, tenantId = 'tenant-42', runsError = null } = opts;
  q.reset();
  inserts = [];
  mockRpc.mockResolvedValue({ data: isFinance, error: rpcError });
  mockGetUser.mockResolvedValue({ data: { user: { id: 'u1' } } });

  mockFrom.mockImplementation((table: string) => {
    switch (table) {
      case 'hr_payroll_runs':
        return q.chain(table, runs, runsError);
      case 'hr_payroll_items':
        return q.chain(table, ITEMS);
      case 'cash_bank_transactions':
        return {
          insert: (payload: Record<string, unknown>) => {
            inserts.push(payload);
            return Promise.resolve({ error: insertError });
          },
        };
      case 'app_users': {
        const t = q.chain(table, []);
        t.single = () => Promise.resolve({ data: tenantId ? { tenant_id: tenantId } : null, error: null });
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

type User = ReturnType<typeof userEvent.setup>;

async function openDialog(user: User) {
  await user.click(await screen.findByRole('button', { name: 'Record Disbursement' }));
  const dialog = await screen.findByRole('dialog');
  return within(dialog);
}

type Dialog = Awaited<ReturnType<typeof openDialog>>;

async function setAmount(user: User, dialog: Dialog, value: string) {
  const amount = dialog.getByLabelText(/^amount/i);
  await user.clear(amount);
  await user.type(amount, value);
}

async function setDate(user: User, dialog: Dialog, value: string) {
  const date = dialog.getByLabelText(/^transaction date/i);
  await user.clear(date);
  await user.type(date, value);
}

describe('PayrollDisbursement', () => {
  describe('which runs can be paid', () => {
    it('loads approved and disbursed runs only', async () => {
      setup();
      render(<PayrollDisbursement />);

      await screen.findByText('Approved · awaiting disbursement');
      expect(q.callsTo('hr_payroll_runs', 'in')[0].args).toEqual(['status', ['approved', 'disbursed']]);
    });

    it('offers the button only for runs with something left to pay', async () => {
      setup({ runs: [APPROVED, DONE] });
      render(<PayrollDisbursement />);

      await screen.findByText('Approved · awaiting disbursement');
      expect(screen.getByText('Disbursed')).toBeInTheDocument();
      expect(screen.getAllByRole('button', { name: 'Record Disbursement' })).toHaveLength(1);
    });

    it('treats a run with nothing remaining as disbursed even if its status is still approved', async () => {
      setup({ runs: [{ ...APPROVED, amount_disbursed: 1000000 }] });
      render(<PayrollDisbursement />);

      expect(await screen.findByText('Disbursed')).toBeInTheDocument();
      expect(screen.queryByRole('button', { name: 'Record Disbursement' })).not.toBeInTheDocument();
    });
  });

  describe('the disbursement dialog', () => {
    it('suggests the full net pay total for an untouched run', async () => {
      const user = userEvent.setup();
      setup();
      render(<PayrollDisbursement />);
      const dialog = await openDialog(user);

      expect(dialog.getByLabelText(/^amount/i)).toHaveValue(1000000);
      expect(dialog.getByText(/partial payments are allowed/i)).toBeInTheDocument();
    });

    it('suggests only the remaining balance for a partly paid run', async () => {
      const user = userEvent.setup();
      setup({ runs: [PARTIAL] });
      render(<PayrollDisbursement />);
      const dialog = await openDialog(user);

      expect(dialog.getByLabelText(/^amount/i)).toHaveValue(600000);
    });
  });

  describe('recording a disbursement', () => {
    it('sends a bank payment against the payroll run with a default description', async () => {
      const user = userEvent.setup();
      setup();
      render(<PayrollDisbursement />);
      const dialog = await openDialog(user);

      await user.type(dialog.getByLabelText(/^bank account/i), '  Stanbic-001 ');
      await setDate(user, dialog, '2026-09-03');
      await setAmount(user, dialog, '600000');
      await user.click(dialog.getByRole('button', { name: 'Record Disbursement' }));

      await waitFor(() => expect(inserts).toHaveLength(1));
      expect(inserts[0]).toEqual({
        tenant_id: 'tenant-42',
        transaction_type: 'payment',
        payment_method: 'bank',
        reference_type: 'payroll_run',
        reference_id: 'run1',
        amount: 600000,
        currency: 'UGX',
        transaction_date: '2026-09-03',
        bank_account: 'Stanbic-001',
        description: 'Payroll disbursement — 2026-08',
      });
    });

    it('sends bank_account as null for cash and keeps a typed description, trimmed', async () => {
      const user = userEvent.setup();
      setup();
      render(<PayrollDisbursement />);
      const dialog = await openDialog(user);

      await user.type(dialog.getByLabelText(/^bank account/i), 'Stanbic-001');
      await user.click(dialog.getByLabelText(/^payment method/i));
      await user.click(await screen.findByRole('option', { name: 'Cash' }));
      expect(dialog.queryByLabelText(/^bank account/i)).not.toBeInTheDocument();
      await user.type(dialog.getByLabelText(/^description/i), '  August salaries ');
      await setDate(user, dialog, '2026-09-03');
      await user.click(dialog.getByRole('button', { name: 'Record Disbursement' }));

      await waitFor(() => expect(inserts).toHaveLength(1));
      expect(inserts[0]).toMatchObject({ payment_method: 'cash', bank_account: null, description: 'August salaries' });
    });

    it('closes the dialog and reloads the runs after a successful insert', async () => {
      const user = userEvent.setup();
      setup();
      render(<PayrollDisbursement />);
      const dialog = await openDialog(user);

      await user.type(dialog.getByLabelText(/^bank account/i), 'Stanbic-001');
      q.reset();
      await user.click(dialog.getByRole('button', { name: 'Record Disbursement' }));

      await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument());
      expect(q.callsTo('hr_payroll_runs', 'select').length).toBeGreaterThanOrEqual(1);
    });

    it('requires a bank account for a bank payment', async () => {
      const user = userEvent.setup();
      setup();
      render(<PayrollDisbursement />);
      const dialog = await openDialog(user);

      await user.click(dialog.getByRole('button', { name: 'Record Disbursement' }));

      expect(await dialog.findByText('Bank account is required for bank disbursements.')).toBeInTheDocument();
      expect(inserts).toHaveLength(0);
    });

    it.each([['0'], ['-5']])('rejects an amount of %s', async (amount) => {
      const user = userEvent.setup();
      setup();
      render(<PayrollDisbursement />);
      const dialog = await openDialog(user);

      await user.type(dialog.getByLabelText(/^bank account/i), 'Stanbic-001');
      await setAmount(user, dialog, amount);
      await user.click(dialog.getByRole('button', { name: 'Record Disbursement' }));

      expect(await dialog.findByText('Amount must be a valid number greater than 0.')).toBeInTheDocument();
      expect(inserts).toHaveLength(0);
    });

    it('requires a transaction date', async () => {
      const user = userEvent.setup();
      setup();
      render(<PayrollDisbursement />);
      const dialog = await openDialog(user);

      await user.type(dialog.getByLabelText(/^bank account/i), 'Stanbic-001');
      await user.clear(dialog.getByLabelText(/^transaction date/i));
      await user.click(dialog.getByRole('button', { name: 'Record Disbursement' }));

      expect(await dialog.findByText('Transaction date is required.')).toBeInTheDocument();
      expect(inserts).toHaveLength(0);
    });

    it('does not insert when the tenant cannot be determined', async () => {
      const user = userEvent.setup();
      setup({ tenantId: null });
      render(<PayrollDisbursement />);
      const dialog = await openDialog(user);

      await user.type(dialog.getByLabelText(/^bank account/i), 'Stanbic-001');
      await user.click(dialog.getByRole('button', { name: 'Record Disbursement' }));

      expect(await dialog.findByText('Could not determine your tenant. Contact an admin.')).toBeInTheDocument();
      expect(inserts).toHaveLength(0);
    });

    it('keeps the dialog open and shows the database error when the insert fails', async () => {
      const user = userEvent.setup();
      setup({ insertError: { message: 'row-level security policy violation' } });
      render(<PayrollDisbursement />);
      const dialog = await openDialog(user);

      await user.type(dialog.getByLabelText(/^bank account/i), 'Stanbic-001');
      await user.click(dialog.getByRole('button', { name: 'Record Disbursement' }));

      expect(await dialog.findByText('row-level security policy violation')).toBeInTheDocument();
      expect(screen.getByRole('dialog')).toBeInTheDocument();
    });
  });

  describe('access and errors', () => {
    it('tells a non-finance user why they cannot pay', async () => {
      setup({ isFinance: false });
      render(<PayrollDisbursement />);

      expect(await screen.findByText(/not currently listed as a finance team member/i)).toBeInTheDocument();
    });

    it('treats a failed access check as no access', async () => {
      setup({ isFinance: true, rpcError: { message: 'function does not exist' } });
      render(<PayrollDisbursement />);

      expect(await screen.findByText(/not currently listed as a finance team member/i)).toBeInTheDocument();
    });

    it('does not show the finance notice to a finance user', async () => {
      setup({ isFinance: true });
      render(<PayrollDisbursement />);

      await screen.findByText('Approved · awaiting disbursement');
      expect(screen.queryByText(/not currently listed as a finance team member/i)).not.toBeInTheDocument();
    });

    it('shows a load error when the runs query fails', async () => {
      setup({ runsError: new Error('JWT expired') });
      render(<PayrollDisbursement />);

      expect(await screen.findByText('JWT expired')).toBeInTheDocument();
    });
  });
});