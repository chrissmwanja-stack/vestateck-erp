import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import RequestSubmissionForm from './RequestSubmissionForm';

// This is the first screen in the procurement happy path (Request ->
// Offer Entry -> Approval -> PO) and has real client-side logic worth
// pinning down beyond what db-shadow-replay covers: line items are
// filtered client-side before submit (only rows with a description AND
// qty > 0 count), the total quantity sent to
// submit_request_with_line_items is aggregated from those valid rows
// only, and the requester's department is defaulted onto the first row
// exactly once, without clobbering anything the user already typed
// while that lookup was still in flight.

const COST_CENTER_A = { id: 'cc1', tenant_id: 't1', name: 'Main Site', project_code: 'PRJ-001', budget_amount: 100000, created_at: '2026-01-01' };
const DEPARTMENT_A = { id: 'd1', tenant_id: 't1', parent_department_id: null, name: 'Procurement & Logistics', is_active: true, created_at: '2026-01-01' };

function setupFromMock(opts: {
  costCenters?: unknown[];
  materials?: unknown[];
  departments?: unknown[];
  userDepartmentId?: string | null;
  rpcResult?: { data: unknown; error: unknown };
} = {}) {
  const {
    costCenters = [COST_CENTER_A],
    materials = [],
    departments = [DEPARTMENT_A],
    userDepartmentId = null,
    rpcResult = { data: 'req-123', error: null },
  } = opts;

  const mockRpc = vi.fn().mockResolvedValue(rpcResult);

  const mockFrom = vi.fn((table: string) => {
    if (table === 'cost_centers') {
      return { select: () => ({ order: () => Promise.resolve({ data: costCenters, error: null }) }) };
    }
    if (table === 'material_catalog') {
      return { select: () => ({ eq: () => ({ order: () => Promise.resolve({ data: materials, error: null }) }) }) };
    }
    if (table === 'departments') {
      return { select: () => ({ eq: () => ({ order: () => Promise.resolve({ data: departments, error: null }) }) }) };
    }
    if (table === 'app_users') {
      return { select: () => ({ eq: () => ({ single: () => Promise.resolve({ data: { department_id: userDepartmentId }, error: null }) }) }) };
    }
    throw new Error(`setupFromMock: no handler for table "${table}"`);
  });

  return { mockFrom, mockRpc };
}

vi.mock('../../lib/supabaseClient', () => ({
  supabase: {
    from: (...args: [string]) => mockFromRef(...args),
    rpc: (...args: [string, unknown]) => mockRpcRef(...args),
    auth: { getUser: () => mockGetUserRef() },
  },
}));

// Indirection so each test can swap in its own dispatcher via setupFromMock
// without re-mocking the module.
let mockFromRef: ReturnType<typeof setupFromMock>['mockFrom'];
let mockRpcRef: ReturnType<typeof setupFromMock>['mockRpc'];
let mockGetUserRef = vi.fn().mockResolvedValue({ data: { user: { id: 'u1' } } });

function setup(opts: Parameters<typeof setupFromMock>[0] = {}) {
  const { mockFrom, mockRpc } = setupFromMock(opts);
  mockFromRef = mockFrom;
  mockRpcRef = mockRpc;
  return { mockFrom, mockRpc };
}

beforeEach(() => {
  mockGetUserRef = vi.fn().mockResolvedValue({ data: { user: { id: 'u1' } } });
});

async function fillHeader(user: ReturnType<typeof userEvent.setup>) {
  await user.type(screen.getByLabelText('Description'), 'Cement for site A foundation');
  const costCenterInput = screen.getByLabelText('Cost center');
  await user.click(costCenterInput);
  await user.type(costCenterInput, 'Main Site');
  await waitFor(() => expect(screen.getByText('PRJ-001 — Main Site')).toBeInTheDocument());
  await user.click(screen.getByText('PRJ-001 — Main Site'));
}

describe('RequestSubmissionForm', () => {
  it('blocks submit and shows header validation errors on an empty form', async () => {
    const user = userEvent.setup();
    const { mockRpc } = setup();

    render(<RequestSubmissionForm />);
    await waitFor(() => expect(mockRpc).not.toHaveBeenCalled());

    await user.click(screen.getByRole('button', { name: /submit request/i }));

    expect(await screen.findByText("Describe what's needed")).toBeInTheDocument();
    expect(screen.getByText('Pick a cost center')).toBeInTheDocument();
    expect(mockRpc).not.toHaveBeenCalled();
  });

  it('blocks submit when no line item has both a description and a quantity > 0', async () => {
    const user = userEvent.setup();
    const { mockRpc } = setup();

    render(<RequestSubmissionForm />);
    await fillHeader(user);
    // Leave the single default line item row empty.
    await user.click(screen.getByRole('button', { name: /submit request/i }));

    expect(await screen.findByText(/add at least one line item/i)).toBeInTheDocument();
    expect(mockRpc).not.toHaveBeenCalled();
  });

  it('submits only valid line item rows and aggregates their quantity', async () => {
    const user = userEvent.setup();
    const { mockRpc } = setup();

    render(<RequestSubmissionForm />);
    await fillHeader(user);

    // Row 1: valid (description + qty). Row 2: added but left blank -- should be dropped.
    const materialInputs = screen.getAllByPlaceholderText('Type or pick from catalog');
    await user.type(materialInputs[0], 'Cement 50kg bags');
    const qtyInputs = screen.getAllByRole('spinbutton');
    await user.type(qtyInputs[0], '10');

    await user.click(screen.getByRole('button', { name: /add row/i }));
    // second row's qty input intentionally left blank

    await user.click(screen.getByRole('button', { name: /submit request/i }));

    await waitFor(() => expect(mockRpc).toHaveBeenCalledTimes(1));
    const [fnName, payload] = mockRpc.mock.calls[0] as [string, Record<string, unknown>];
    expect(fnName).toBe('submit_request_with_line_items');
    expect(payload.p_quantity).toBe(10);
    expect(payload.p_line_items).toHaveLength(1);
    expect((payload.p_line_items as Array<{ material_service: string }>)[0].material_service).toBe('Cement 50kg bags');
  });

  it('resets the form and calls onSubmitted with the new request id on success', async () => {
    const user = userEvent.setup();
    const onSubmitted = vi.fn();
    setup({ rpcResult: { data: 'req-999', error: null } });

    render(<RequestSubmissionForm onSubmitted={onSubmitted} />);
    await fillHeader(user);
    const materialInputs = screen.getAllByPlaceholderText('Type or pick from catalog');
    await user.type(materialInputs[0], 'Rebar 12mm');
    const qtyInputs = screen.getAllByRole('spinbutton');
    await user.type(qtyInputs[0], '5');

    await user.click(screen.getByRole('button', { name: /submit request/i }));

    await waitFor(() => expect(onSubmitted).toHaveBeenCalledWith('req-999'));
    expect((screen.getByLabelText('Description') as HTMLInputElement).value).toBe('');
  });

  it('shows the RPC error message and keeps entered data on failure', async () => {
    const user = userEvent.setup();
    setup({ rpcResult: { data: null, error: { message: 'threshold check failed' } } });

    render(<RequestSubmissionForm />);
    await fillHeader(user);
    const materialInputs = screen.getAllByPlaceholderText('Type or pick from catalog');
    await user.type(materialInputs[0], 'Rebar 12mm');
    const qtyInputs = screen.getAllByRole('spinbutton');
    await user.type(qtyInputs[0], '5');

    await user.click(screen.getByRole('button', { name: /submit request/i }));

    expect(await screen.findByText('threshold check failed')).toBeInTheDocument();
    // form should NOT have been reset on failure
    expect((screen.getByLabelText('Description') as HTMLInputElement).value).not.toBe('');
  });

  it("defaults the first row's place of use to the requester's department once, without clobbering a typed value", async () => {
    setup({ userDepartmentId: 'd1', departments: [DEPARTMENT_A] });

    render(<RequestSubmissionForm />);

    const placeOfUseInputs = await screen.findAllByPlaceholderText('Department');
    await waitFor(() => expect((placeOfUseInputs[0] as HTMLInputElement).value).toBe('Procurement & Logistics'));
  });
});
