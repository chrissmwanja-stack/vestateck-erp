import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import BankAccountsAdmin from './BankAccountsAdmin';

// The registry (D4a) had no UI: names were backfilled from statements and
// transactions, and mapping a GL account needed SQL. This screen is where
// finance finishes that. The client-side branching worth pinning down:
// what an insert/update payload contains (name, kind and a mapped GL
// account are immutable server-side, so an update must never send them),
// the client money GL requirement, that guard-trigger errors read as
// sentences, and that people without the finance role cannot write.

const mockFrom = vi.fn();
const mockRpc = vi.fn();
vi.mock('../../lib/supabaseClient', () => ({
  supabase: {
    from: (...args: unknown[]) => mockFrom(...args),
    rpc: (...args: unknown[]) => mockRpc(...args),
  },
}));
vi.mock('../../lib/authContext', () => ({ useAuth: () => ({ session: { user: { id: 'u1' } } }) }));
vi.mock('../../lib/ResolveTenantId', () => ({
  resolveTenantId: async () => ({ ok: true, tenantId: 'tenant-42' }),
}));

const GL_BANK = { id: 'gl-1', account_code: '1010', name: 'Stanbic Operating' };
const GL_CLIENT = { id: 'gl-2', account_code: '1020', name: 'Client Money Bank' };
const OPERATING = {
  id: 'b1',
  name: 'Stanbic-001',
  kind: 'operating',
  currency: 'UGX',
  gl_account_id: 'gl-1',
  bank_name: 'Stanbic',
  account_number: '001',
  is_active: true,
};
const UNMAPPED = { ...OPERATING, id: 'b2', name: 'Legacy-Bank', gl_account_id: null, bank_name: null, account_number: null };
const UNREGISTERED = { name: 'Centenary-77', row_count: 12, sources: ['bank_statement_lines'], last_seen_on: '2026-10-03' };

let inserts: Record<string, unknown>[];
let updates: { payload: Record<string, unknown>; id: unknown }[];

function setup(opts: {
  canWrite?: boolean;
  accounts?: unknown[];
  unregistered?: unknown[];
  insertError?: { message: string } | null;
  updateError?: { message: string } | null;
} = {}) {
  const { canWrite = true, accounts = [OPERATING, UNMAPPED], unregistered = [UNREGISTERED], insertError = null, updateError = null } = opts;
  inserts = [];
  updates = [];
  mockRpc.mockResolvedValue({ data: canWrite, error: null });

  const readBuilder = (data: unknown[]) => {
    const b: any = {};
    for (const m of ['select', 'eq', 'order']) b[m] = () => b;
    b.then = (resolve: (v: { data: unknown; error: unknown }) => void) => resolve({ data, error: null });
    return b;
  };

  mockFrom.mockImplementation((table: string) => {
    if (table === 'fin_bank_accounts') {
      const b: any = readBuilder(accounts);
      b.insert = (payload: Record<string, unknown>) => {
        inserts.push(payload);
        return Promise.resolve({ error: insertError });
      };
      b.update = (payload: Record<string, unknown>) => ({
        eq: (_col: string, id: unknown) => {
          updates.push({ payload, id });
          return Promise.resolve({ error: updateError });
        },
      });
      return b;
    }
    if (table === 'gl_accounts') return readBuilder([GL_BANK, GL_CLIENT]);
    if (table === 'fin_unregistered_bank_accounts') return readBuilder(unregistered);
    throw new Error(`unexpected table ${table}`);
  });
}

async function pickOption(user: ReturnType<typeof userEvent.setup>, label: string, option: string) {
  await user.click(screen.getByRole('combobox', { name: label }));
  await user.click(await screen.findByRole('option', { name: option }));
}

describe('BankAccountsAdmin', () => {
  beforeEach(() => {
    mockFrom.mockReset();
    mockRpc.mockReset();
  });

  it('lists registered accounts with their GL mapping and flags unmapped ones', async () => {
    setup();
    render(<BankAccountsAdmin />);

    await screen.findByText('Stanbic-001');
    expect(screen.getByText('1010 — Stanbic Operating')).toBeTruthy();
    expect(screen.getByText('Legacy-Bank')).toBeTruthy();
    expect(screen.getByText('Not mapped')).toBeTruthy();
  });

  it('registers an unregistered name from the panel, trimming fields and sending the tenant id', async () => {
    setup();
    const user = userEvent.setup();
    render(<BankAccountsAdmin />);

    const panel = await screen.findByTestId('unregistered-panel');
    await user.click(within(panel).getByRole('button', { name: 'Register' }));

    const name = await screen.findByLabelText(/^Name/);
    expect((name as HTMLInputElement).value).toBe('Centenary-77');
    await user.type(screen.getByLabelText('Bank name'), '  Centenary  ');
    await user.click(screen.getByRole('button', { name: 'Save' }));

    await waitFor(() => expect(inserts).toHaveLength(1));
    expect(inserts[0]).toEqual({
      tenant_id: 'tenant-42',
      name: 'Centenary-77',
      kind: 'operating',
      currency: 'UGX',
      gl_account_id: null,
      bank_name: 'Centenary',
      account_number: null,
    });
  });

  it('requires a GL account for a client money account and does not call the server without one', async () => {
    setup();
    const user = userEvent.setup();
    render(<BankAccountsAdmin />);

    await user.click(await screen.findByRole('button', { name: 'Add Bank Account' }));
    await user.type(await screen.findByLabelText(/^Name/), 'Client-Trust');
    await pickOption(user, 'Type', 'Client money');
    await user.click(screen.getByRole('button', { name: 'Save' }));

    await screen.findByText('A client money account needs its own GL account.');
    expect(inserts).toHaveLength(0);
  });

  it('shows a guard-trigger refusal as a plain sentence without the error code', async () => {
    setup({
      insertError: {
        message: 'BANK_ACCOUNT_SEGREGATION: GL account 1010 is already used by a operating bank account; client money and operating money need separate GL accounts',
      },
    });
    const user = userEvent.setup();
    render(<BankAccountsAdmin />);

    await user.click(await screen.findByRole('button', { name: 'Add Bank Account' }));
    await user.type(await screen.findByLabelText(/^Name/), 'Client-Trust');
    await pickOption(user, 'Type', 'Client money');
    await pickOption(user, 'GL account', '1010 — Stanbic Operating');
    await user.click(screen.getByRole('button', { name: 'Save' }));

    const msg = await screen.findByText(/already used by a operating bank account/);
    expect(msg.textContent).not.toContain('BANK_ACCOUNT_SEGREGATION');
  });

  it('reports a duplicate name clearly', async () => {
    setup({ insertError: { message: 'duplicate key value violates unique constraint "fin_bank_accounts_tenant_name_unique"' } });
    const user = userEvent.setup();
    render(<BankAccountsAdmin />);

    await user.click(await screen.findByRole('button', { name: 'Add Bank Account' }));
    await user.type(await screen.findByLabelText(/^Name/), 'Stanbic-001');
    await user.click(screen.getByRole('button', { name: 'Save' }));

    await screen.findByText('A bank account named "Stanbic-001" already exists.');
  });

  it('never sends name, kind or an already-mapped GL account in an update', async () => {
    setup();
    const user = userEvent.setup();
    render(<BankAccountsAdmin />);

    const row = (await screen.findByText('Stanbic-001')).closest('tr') as HTMLElement;
    await user.click(within(row).getByRole('button', { name: /Edit/ }));
    const bankName = await screen.findByLabelText('Bank name');
    await user.clear(bankName);
    await user.type(bankName, 'Stanbic Bank');
    await user.click(screen.getByRole('button', { name: 'Save' }));

    await waitFor(() => expect(updates).toHaveLength(1));
    expect(updates[0].id).toBe('b1');
    expect(Object.keys(updates[0].payload).sort()).toEqual(['account_number', 'bank_name', 'currency']);
    expect(updates[0].payload.bank_name).toBe('Stanbic Bank');
  });

  it('lets an unmapped account gain a GL account once, via update', async () => {
    setup();
    const user = userEvent.setup();
    render(<BankAccountsAdmin />);

    const row = (await screen.findByText('Legacy-Bank')).closest('tr') as HTMLElement;
    await user.click(within(row).getByRole('button', { name: /Edit/ }));
    await pickOption(user, 'GL account', '1010 — Stanbic Operating');
    await user.click(screen.getByRole('button', { name: 'Save' }));

    await waitFor(() => expect(updates).toHaveLength(1));
    expect(updates[0].payload.gl_account_id).toBe('gl-1');
  });

  it('deactivates an account by flipping is_active, never deleting', async () => {
    setup();
    const user = userEvent.setup();
    render(<BankAccountsAdmin />);

    const row = (await screen.findByText('Stanbic-001')).closest('tr') as HTMLElement;
    await user.click(within(row).getByRole('button', { name: 'Deactivate' }));

    await waitFor(() => expect(updates).toHaveLength(1));
    expect(updates[0]).toEqual({ payload: { is_active: false }, id: 'b1' });
  });

  it('is read-only without the finance role', async () => {
    setup({ canWrite: false });
    render(<BankAccountsAdmin />);

    await screen.findByText(/Viewing only/);
    expect((screen.getByRole('button', { name: 'Add Bank Account' }) as HTMLButtonElement).disabled).toBe(true);
    const row = screen.getByText('Stanbic-001').closest('tr') as HTMLElement;
    expect((within(row).getByRole('button', { name: 'Deactivate' }) as HTMLButtonElement).disabled).toBe(true);
  });
});
