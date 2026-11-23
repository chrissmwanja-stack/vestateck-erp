import { fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import RisksList from './RisksList';

// Insured-risk register. A manager registers risks and activates or deactivates them; everyone
// else reads. The form is checked before the RPC: a product line that needs a certificate needs a
// vehicle risk with a chassis number, the year must be 1950-2100 and the sum insured cannot be
// negative. Registering goes through ins_register_risk, status changes through ins_set_risk_status.

const mockFrom = vi.fn();
const mockRpc = vi.fn();
vi.mock('../../../../../lib/supabaseClient', () => ({
  supabase: { from: (...a: unknown[]) => mockFrom(...a), rpc: (...a: unknown[]) => mockRpc(...a) },
}));

let mockCanManage = true;
vi.mock('../../access', () => ({ useInsuranceAccess: () => ({ loading: false, canManage: mockCanManage }) }));

type Row = Record<string, unknown>;
const risk = (over: Row = {}): Row => ({
  id: 'r1', client_id: 'cl1', product_line_id: 'l1', risk_type: 'vehicle', description: 'Toyota Hilux', reg_no: 'UAB 123X', chassis_no: 'CH-001',
  engine_no: null, make: 'Toyota', model: 'Hilux', year_made: 2020, sum_insured: 45_000_000, status: 'active',
  ins_clients: { client_id: 'cl1', bd_clients: { name: 'Acme Traders' } }, ins_product_lines: { code: 'MOTOR', name: 'Motor' }, ...over,
});
const clients = [{ id: 'cl1', bd_clients: { name: 'Acme Traders' } }, { id: 'cl2', bd_clients: null }];
const lines = [
  { id: 'l1', code: 'MOTOR', name: 'Motor', requires_certificate: true },
  { id: 'l2', code: 'FIRE', name: 'Fire', requires_certificate: false },
];

let risks: Row[];
let loadError: { message: string } | null;
let calls: Array<[string, string, unknown[]]>;

function builder(name: string, getRows: () => Row[], getError: () => { message: string } | null = () => null) {
  const chain: Record<string, unknown> = {};
  for (const m of ['select', 'order', 'eq', 'range']) chain[m] = vi.fn((...a: unknown[]) => { calls.push([name, m, a]); return chain; });
  (chain as { then: unknown }).then = (resolve: (v: unknown) => void) => {
    const error = getError();
    return resolve({ data: error ? null : getRows(), error });
  };
  return chain;
}
const riskReads = () => mockFrom.mock.calls.filter((c) => c[0] === 'ins_risks').length;

beforeEach(() => {
  vi.clearAllMocks();
  mockCanManage = true;
  risks = [risk()];
  loadError = null;
  calls = [];
  mockFrom.mockImplementation((name: string) => {
    if (name === 'ins_risks') return builder(name, () => risks, () => loadError);
    if (name === 'ins_clients') return builder(name, () => clients);
    if (name === 'ins_product_lines') return builder(name, () => lines);
    throw new Error(`unexpected table ${name}`);
  });
  mockRpc.mockResolvedValue({ data: 'new-risk', error: null });
});

const renderRisks = () => render(<RisksList />);
const rowOf = (text: string) => screen.getAllByRole('row').find((r) => r.textContent?.includes(text)) as HTMLElement;
const dialog = () => screen.findByRole('dialog');
const saveBtn = () => within(screen.getByRole('dialog')).getByRole('button', { name: /Save risk|Saving/ }) as HTMLButtonElement;
const pick = async (user: ReturnType<typeof userEvent.setup>, label: string | RegExp, option: string | RegExp) => {
  await user.click(screen.getByLabelText(label));
  await user.click(await screen.findByRole('option', { name: option }));
};
const openForm = async (user: ReturnType<typeof userEvent.setup>) => {
  await user.click(await screen.findByRole('button', { name: 'New risk' }));
  await dialog();
};

describe('RisksList: display', () => {
  it('reads the risks, the clients and the active product lines', async () => {
    renderRisks();
    await screen.findByText('Toyota Hilux');
    expect(calls).toEqual(expect.arrayContaining([
      ['ins_product_lines', 'eq', ['is_active', true]],
      ['ins_risks', 'order', ['created_at', { ascending: false }]],
    ]));
  });

  it('lists each risk with its client, line, identifiers and sum insured, with dashes for blanks', async () => {
    risks = [risk(), risk({ id: 'r2', risk_type: 'property', description: 'Warehouse', reg_no: null, chassis_no: null, sum_insured: 120_000_000.5, status: 'inactive', ins_clients: null, ins_product_lines: { code: 'FIRE', name: 'Fire' } })];
    renderRisks();
    await screen.findByText('Toyota Hilux');
    expect(screen.getByText(/^2 risks\./)).toBeTruthy();
    const car = rowOf('Toyota Hilux');
    expect(within(car).getByText('Acme Traders')).toBeTruthy();
    expect(within(car).getByText('MOTOR')).toBeTruthy();
    expect(within(car).getByText('UAB 123X')).toBeTruthy();
    expect(within(car).getByText('CH-001')).toBeTruthy();
    expect(within(car).getByText((45_000_000).toLocaleString('en-UG', { maximumFractionDigits: 2 }))).toBeTruthy();
    expect(within(car).getByText('active')).toBeTruthy();
    const warehouse = rowOf('Warehouse');
    expect(within(warehouse).getAllByText('-')).toHaveLength(3); // client, reg no, chassis no
    expect(within(warehouse).getByText((120_000_000.5).toLocaleString('en-UG', { maximumFractionDigits: 2 }))).toBeTruthy();
    expect(within(warehouse).getByText('inactive')).toBeTruthy();
  });

  it('shows the empty state', async () => {
    risks = [];
    renderRisks();
    expect(await screen.findByText('No insured risks yet.')).toBeTruthy();
    expect(screen.getByText(/^0 risks\./)).toBeTruthy();
  });

  it('shows a load failure', async () => {
    loadError = { message: 'permission denied for table ins_risks' };
    renderRisks();
    expect(await screen.findByText('permission denied for table ins_risks')).toBeTruthy();
  });

  it('gives a member the register without the New risk button or the status column', async () => {
    mockCanManage = false;
    renderRisks();
    await screen.findByText('Toyota Hilux');
    expect(screen.queryByRole('button', { name: 'New risk' })).toBeNull();
    expect(screen.queryByRole('button', { name: /Deactivate|Activate/ })).toBeNull();
    expect(screen.getAllByRole('columnheader')).toHaveLength(8);
  });
});

describe('RisksList: activating and deactivating', () => {
  it('deactivates an active risk and activates an inactive one, then reloads', async () => {
    const user = userEvent.setup();
    risks = [risk(), risk({ id: 'r2', description: 'Warehouse', status: 'inactive', risk_type: 'property' })];
    renderRisks();
    await screen.findByText('Toyota Hilux');
    await user.click(within(rowOf('Toyota Hilux')).getByRole('button', { name: 'Deactivate' }));
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('ins_set_risk_status', { p_risk_id: 'r1', p_status: 'inactive' }));
    await user.click(within(rowOf('Warehouse')).getByRole('button', { name: 'Activate' }));
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('ins_set_risk_status', { p_risk_id: 'r2', p_status: 'active' }));
    await waitFor(() => expect(riskReads()).toBe(3));
  });

  it('disables only the risk being changed while it is in flight', async () => {
    const user = userEvent.setup();
    risks = [risk(), risk({ id: 'r2', description: 'Warehouse', chassis_no: 'CH-002', reg_no: 'UBB 1' })];
    let release: (v: unknown) => void = () => {};
    mockRpc.mockImplementationOnce(() => new Promise((resolve) => { release = resolve; }));
    renderRisks();
    await screen.findByText('Toyota Hilux');
    await user.click(within(rowOf('Toyota Hilux')).getByRole('button', { name: 'Deactivate' }));
    await waitFor(() => expect((within(rowOf('Toyota Hilux')).getByRole('button') as HTMLButtonElement).disabled).toBe(true));
    expect((within(rowOf('Warehouse')).getByRole('button') as HTMLButtonElement).disabled).toBe(false);
    release({ data: null, error: null });
    await waitFor(() => expect((within(rowOf('Toyota Hilux')).getByRole('button') as HTMLButtonElement).disabled).toBe(false));
    expect(mockRpc).toHaveBeenCalledTimes(1);
  });

  it('shows the server message when the change is refused', async () => {
    const user = userEvent.setup();
    mockRpc.mockResolvedValueOnce({ data: null, error: { message: 'INS_RISK_IN_USE: The risk is linked to a bound policy' } });
    renderRisks();
    await user.click(await screen.findByRole('button', { name: 'Deactivate' }));
    expect(await screen.findByText('The risk is linked to a bound policy')).toBeTruthy();
    expect(within(rowOf('Toyota Hilux')).getByText('active')).toBeTruthy();
  });
});

describe('RisksList: registering a risk', () => {
  it('says what is missing, one problem at a time, and keeps Save disabled until the form is valid', async () => {
    const user = userEvent.setup();
    renderRisks();
    await openForm(user);
    expect(saveBtn().disabled).toBe(true);
    expect(saveBtn().getAttribute('title')).toBe('Choose a client and a product line.');

    await pick(user, /^Client/, 'Acme Traders');
    await pick(user, /^Product line/, 'FIRE - Fire');
    expect(saveBtn().getAttribute('title')).toBe('Describe the risk.');
    await user.type(screen.getByLabelText(/^Description/), 'Warehouse');
    await waitFor(() => expect(saveBtn().disabled).toBe(false));
    expect(saveBtn().getAttribute('title')).toBeNull();
  });

  it('offers a client with no name by its id', async () => {
    const user = userEvent.setup();
    renderRisks();
    await openForm(user);
    await user.click(screen.getByLabelText(/^Client/));
    expect(await screen.findByRole('option', { name: 'cl2' })).toBeTruthy();
  });

  it('a certificate line needs a vehicle with a chassis number, and switches the type to vehicle', async () => {
    const user = userEvent.setup();
    renderRisks();
    await openForm(user);
    await pick(user, /^Client/, 'Acme Traders');
    await pick(user, 'Risk type', 'Property');
    expect(screen.queryByLabelText('Chassis no.')).toBeNull(); // vehicle-only field is hidden
    await pick(user, /^Product line/, 'MOTOR - Motor');
    expect(screen.getByLabelText('Risk type').textContent).toBe('Vehicle'); // forced to vehicle
    await user.type(screen.getByLabelText(/^Description/), 'Toyota Hilux');
    expect(saveBtn().getAttribute('title')).toBe('A vehicle needs a chassis number.');
    expect(saveBtn().disabled).toBe(true);
    await user.type(screen.getByLabelText('Chassis no.'), 'CH-001');
    await waitFor(() => expect(saveBtn().disabled).toBe(false));
  });

  it('a certificate line refuses a property risk', async () => {
    const user = userEvent.setup();
    renderRisks();
    await openForm(user);
    await pick(user, /^Client/, 'Acme Traders');
    await pick(user, /^Product line/, 'MOTOR - Motor');
    await user.type(screen.getByLabelText(/^Description/), 'Warehouse');
    await pick(user, 'Risk type', 'Property');
    expect(saveBtn().getAttribute('title')).toBe('A product line that needs a certificate needs a vehicle risk.');
    expect(saveBtn().disabled).toBe(true);
  });

  it('checks the year made and the sum insured', async () => {
    const user = userEvent.setup();
    renderRisks();
    await openForm(user);
    await pick(user, /^Client/, 'Acme Traders');
    await pick(user, /^Product line/, 'FIRE - Fire');
    await user.type(screen.getByLabelText(/^Description/), 'Warehouse');
    fireEvent.change(screen.getByLabelText('Year made'), { target: { value: '1949' } });
    expect(saveBtn().getAttribute('title')).toBe('Year made must be between 1950 and 2100.');
    fireEvent.change(screen.getByLabelText('Year made'), { target: { value: '2101' } });
    expect(saveBtn().disabled).toBe(true);
    fireEvent.change(screen.getByLabelText('Year made'), { target: { value: '2021' } });
    fireEvent.change(screen.getByLabelText('Sum insured'), { target: { value: '-5' } });
    expect(saveBtn().getAttribute('title')).toBe('Sum insured cannot be negative.');
    expect(saveBtn().disabled).toBe(true);
    fireEvent.change(screen.getByLabelText('Sum insured'), { target: { value: '0' } });
    await waitFor(() => expect(saveBtn().disabled).toBe(false));
  });

  it('registers a vehicle with every field, trimmed and converted, then closes and reloads', async () => {
    const user = userEvent.setup();
    renderRisks();
    await openForm(user);
    await pick(user, /^Client/, 'Acme Traders');
    await pick(user, /^Product line/, 'MOTOR - Motor');
    await user.type(screen.getByLabelText(/^Description/), '  Toyota Hilux  ');
    await user.type(screen.getByLabelText('Registration no.'), 'UAB 123X');
    await user.type(screen.getByLabelText('Chassis no.'), 'CH-001');
    await user.type(screen.getByLabelText('Engine no.'), 'EN-77');
    await user.type(screen.getByLabelText('Make'), 'Toyota');
    await user.type(screen.getByLabelText('Model'), 'Hilux');
    fireEvent.change(screen.getByLabelText('Year made'), { target: { value: '2020' } });
    fireEvent.change(screen.getByLabelText('Sum insured'), { target: { value: '45000000.5' } });
    await user.click(saveBtn());
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('ins_register_risk', {
      p_client_id: 'cl1', p_product_line_id: 'l1', p_risk_type: 'vehicle', p_description: 'Toyota Hilux', p_reg_no: 'UAB 123X', p_chassis_no: 'CH-001',
      p_engine_no: 'EN-77', p_make: 'Toyota', p_model: 'Hilux', p_year_made: 2020, p_sum_insured: 45_000_000.5,
    }));
    await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull());
    await waitFor(() => expect(riskReads()).toBe(2));
  });

  it('sends blank optional fields as null and a blank sum insured as 0', async () => {
    const user = userEvent.setup();
    renderRisks();
    await openForm(user);
    await pick(user, /^Client/, 'Acme Traders');
    await pick(user, /^Product line/, 'FIRE - Fire');
    await pick(user, 'Risk type', 'Property');
    await user.type(screen.getByLabelText(/^Description/), 'Warehouse');
    await user.click(saveBtn());
    await waitFor(() => expect(mockRpc).toHaveBeenCalledWith('ins_register_risk', {
      p_client_id: 'cl1', p_product_line_id: 'l2', p_risk_type: 'property', p_description: 'Warehouse', p_reg_no: null, p_chassis_no: null,
      p_engine_no: null, p_make: null, p_model: null, p_year_made: null, p_sum_insured: 0,
    }));
  });

  // Switching from Vehicle to Property hides the vehicle fields but the form keeps what was typed in
  // them. The server stores whatever it is given, so none of it may be sent with a non-vehicle risk.
  it('does not send vehicle details with a property risk typed before the type was changed', async () => {
    const user = userEvent.setup();
    renderRisks();
    await openForm(user);
    await pick(user, /^Client/, 'Acme Traders');
    await pick(user, /^Product line/, 'FIRE - Fire');
    await user.type(screen.getByLabelText('Registration no.'), 'UAB 123X');
    await pick(user, 'Risk type', 'Property');
    await user.type(screen.getByLabelText(/^Description/), 'Warehouse');
    await user.click(saveBtn());
    await waitFor(() => expect(mockRpc).toHaveBeenCalled());
    expect(mockRpc).toHaveBeenCalledWith('ins_register_risk', expect.objectContaining({ p_risk_type: 'property', p_reg_no: null }));
  });

  it('empties the form and the choices after a successful save', async () => {
    const user = userEvent.setup();
    renderRisks();
    await openForm(user);
    await pick(user, /^Client/, 'Acme Traders');
    await pick(user, /^Product line/, 'FIRE - Fire');
    await user.type(screen.getByLabelText(/^Description/), 'Warehouse');
    await user.click(saveBtn());
    await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull());
    await openForm(user);
    expect((screen.getByLabelText(/^Description/) as HTMLInputElement).value).toBe('');
    expect(saveBtn().getAttribute('title')).toBe('Choose a client and a product line.');
  });

  it('keeps the form and shows the server message when the risk is refused, and allows a retry', async () => {
    const user = userEvent.setup();
    mockRpc.mockResolvedValueOnce({ data: null, error: { message: 'INS_DUPLICATE: a risk with this chassis number already exists' } });
    renderRisks();
    await openForm(user);
    await pick(user, /^Client/, 'Acme Traders');
    await pick(user, /^Product line/, 'MOTOR - Motor');
    await user.type(screen.getByLabelText(/^Description/), 'Toyota Hilux');
    await user.type(screen.getByLabelText('Chassis no.'), 'CH-001');
    await user.click(saveBtn());
    expect(await screen.findByText(/already exists/)).toBeTruthy();
    expect(screen.getByRole('dialog')).toBeTruthy();
    expect((screen.getByLabelText(/^Description/) as HTMLInputElement).value).toBe('Toyota Hilux');
    await waitFor(() => expect(saveBtn().disabled).toBe(false));
    await user.click(saveBtn());
    await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull());
    expect(mockRpc).toHaveBeenCalledTimes(2);
  });

  it('shows Saving and disables Save while the write is in flight, so it is sent once', async () => {
    const user = userEvent.setup();
    let release: (v: unknown) => void = () => {};
    mockRpc.mockImplementationOnce(() => new Promise((resolve) => { release = resolve; }));
    renderRisks();
    await openForm(user);
    await pick(user, /^Client/, 'Acme Traders');
    await pick(user, /^Product line/, 'FIRE - Fire');
    await user.type(screen.getByLabelText(/^Description/), 'Warehouse');
    await user.click(saveBtn());
    await waitFor(() => expect(saveBtn().textContent).toBe('Saving…'));
    expect(saveBtn().disabled).toBe(true);
    release({ data: 'new-risk', error: null });
    await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull());
    expect(mockRpc).toHaveBeenCalledTimes(1);
  });

  it('Cancel closes without writing', async () => {
    const user = userEvent.setup();
    renderRisks();
    await openForm(user);
    await user.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Cancel' }));
    await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull());
    expect(mockRpc).not.toHaveBeenCalled();
  });
});
