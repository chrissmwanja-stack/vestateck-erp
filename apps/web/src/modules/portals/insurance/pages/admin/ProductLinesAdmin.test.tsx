import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import ProductLinesAdmin from './ProductLinesAdmin';

// Product lines say whether their policies need a certificate before binding. The setting is
// on the line, not a guess from its code: MOTOR always needs one, any other line (a motor line
// coded MOT, say) needs the setting switched on, and the screen warns when a line looks like
// motor but the setting is off, because the server then binds those policies with no certificate.

const mockFrom = vi.fn();
vi.mock('../../../../../lib/supabaseClient', () => ({ supabase: { from: (...a: unknown[]) => mockFrom(...a) } }));

const line = (over: Record<string, unknown>) => ({ id: 'l1', code: 'FIRE', name: 'Fire', class: 'general', is_active: true, requires_certificate: false, ...over });
let lines: unknown[] = [];
let inserts: unknown[] = [];
let updates: { values: unknown; id: unknown }[] = [];

function builder() {
  const chain: Record<string, unknown> = {};
  for (const m of ['select', 'order']) chain[m] = vi.fn(() => chain);
  chain.insert = vi.fn(async (v: unknown) => { inserts.push(v); return { data: null, error: null }; });
  chain.update = vi.fn((v: unknown) => {
    const u = { values: v, id: undefined as unknown };
    updates.push(u);
    const c: Record<string, unknown> = { eq: (_col: string, id: unknown) => { u.id = id; return Promise.resolve({ data: null, error: null }); } };
    return c;
  });
  (chain as { then: unknown }).then = (resolve: (v: unknown) => void) => resolve({ data: lines, error: null });
  return chain;
}

beforeEach(() => {
  lines = [
    line({ id: 'm', code: 'MOTOR', name: 'Motor Fleet', requires_certificate: true }),
    line({ id: 'c', code: 'MOT', name: 'Cars' }),
    line({ id: 'f', code: 'FIRE', name: 'Fire' }),
  ];
  inserts = [];
  updates = [];
  mockFrom.mockReset();
  mockFrom.mockImplementation(() => builder());
});

describe('certificate setting on existing lines', () => {
  it('shows MOTOR as always on, and warns about a line that looks like motor with the setting off', async () => {
    render(<ProductLinesAdmin />);
    const motor = await screen.findByLabelText('Needs certificate: Motor Fleet');
    expect(motor).toBeChecked();
    expect(motor).toBeDisabled();
    expect(screen.getByLabelText('Needs certificate: Cars')).not.toBeChecked();
    expect(screen.getByLabelText('Needs certificate: Fire')).not.toBeChecked();
    expect(screen.getAllByText('Looks like motor: check')).toHaveLength(1);
  });

  it('switches the requirement on for a line the company coded differently', async () => {
    render(<ProductLinesAdmin />);
    await userEvent.click(await screen.findByLabelText('Needs certificate: Cars'));
    await waitFor(() => expect(updates).toHaveLength(1));
    expect(updates[0]).toEqual({ values: { requires_certificate: true }, id: 'c' });
  });

  it('asks before turning a requirement off, and does nothing if kept on', async () => {
    lines = [line({ id: 'c', code: 'MOT', name: 'Cars', requires_certificate: true })];
    render(<ProductLinesAdmin />);
    await userEvent.click(await screen.findByLabelText('Needs certificate: Cars'));
    const dialog = await screen.findByRole('dialog');
    expect(within(dialog).getByText(/will bind without a certificate/i)).toBeInTheDocument();
    await userEvent.click(within(dialog).getByRole('button', { name: 'Keep it on' }));
    expect(updates).toHaveLength(0);

    await userEvent.click(screen.getByLabelText('Needs certificate: Cars'));
    await userEvent.click(within(await screen.findByRole('dialog')).getByRole('button', { name: 'Turn off' }));
    await waitFor(() => expect(updates).toHaveLength(1));
    expect(updates[0]).toEqual({ values: { requires_certificate: false }, id: 'c' });
  });
});

describe('new product line', () => {
  const open = async () => {
    render(<ProductLinesAdmin />);
    await userEvent.click(await screen.findByRole('button', { name: 'New product line' }));
    return screen.getByRole('dialog');
  };

  it('forces the setting on for the code MOTOR', async () => {
    const dialog = await open();
    await userEvent.type(within(dialog).getByLabelText(/^Code/), 'motor');
    await userEvent.type(within(dialog).getByLabelText(/^Name/), 'Motor private');
    const toggle = within(dialog).getByLabelText(/Policies need an issued certificate/);
    expect(toggle).toBeChecked();
    expect(toggle).toBeDisabled();
    await userEvent.click(within(dialog).getByRole('button', { name: 'Save' }));
    await waitFor(() => expect(inserts).toHaveLength(1));
    expect(inserts[0]).toEqual({ code: 'MOTOR', name: 'Motor private', class: 'general', requires_certificate: true });
  });

  it('warns on a motor-looking line with the setting off, and clears the warning once it is on', async () => {
    const dialog = await open();
    await userEvent.type(within(dialog).getByLabelText(/^Code/), 'MOT');
    await userEvent.type(within(dialog).getByLabelText(/^Name/), 'Cars');
    expect(within(dialog).getByText(/bind with no certificate and no error/i)).toBeInTheDocument();
    await userEvent.click(within(dialog).getByLabelText(/Policies need an issued certificate/));
    expect(within(dialog).queryByText(/bind with no certificate and no error/i)).not.toBeInTheDocument();
    await userEvent.click(within(dialog).getByRole('button', { name: 'Save' }));
    await waitFor(() => expect(inserts).toHaveLength(1));
    expect(inserts[0]).toEqual({ code: 'MOT', name: 'Cars', class: 'general', requires_certificate: true });
  });

  it('leaves an ordinary line without the requirement and without a warning', async () => {
    const dialog = await open();
    await userEvent.type(within(dialog).getByLabelText(/^Code/), 'FIRE');
    await userEvent.type(within(dialog).getByLabelText(/^Name/), 'Fire and allied perils');
    expect(within(dialog).queryByText(/looks like motor/i)).not.toBeInTheDocument();
    await userEvent.click(within(dialog).getByRole('button', { name: 'Save' }));
    await waitFor(() => expect(inserts).toHaveLength(1));
    expect(inserts[0]).toEqual({ code: 'FIRE', name: 'Fire and allied perils', class: 'general', requires_certificate: false });
  });
});
