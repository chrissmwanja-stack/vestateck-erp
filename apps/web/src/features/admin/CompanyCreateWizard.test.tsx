import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import CompanyCreateWizard from './CompanyCreateWizard';
import { REGISTRY_FIXTURE, registryState } from '../../test/moduleRegistryMock';
import type { PlatformModule } from '../../lib/useModuleRegistry';
import type { TemplateRow } from './platformConfig';

// Platform-admin-only tenant provisioning: create-tenant (edge function) ->
// set_tenant_modules (RPC, non-fatal on failure) -> invite-user (edge
// function, also non-fatal -- the tenant already exists by that point).
// Worth pinning down client-side: the two-step Next gate (name length +
// a real email, not just "contains @"), the default module preselection,
// and that a failure at each of the three calls degrades the right way
// instead of all being treated as a hard stop.

// The shared fixture mirrors the construction-era registry; add the insurance
// vertical so the wizard can offer its module.
const INSURANCE_MODULE: PlatformModule = {
  key: 'insurance',
  name: 'Insurance Brokerage',
  tier: 'vertical',
  vertical: 'insurance',
  route_base: '/insurance',
  depends_on: [],
  tenant_entitled: true,
  is_active: true,
  sort_order: 100,
};
const REGISTRY = registryState([...REGISTRY_FIXTURE, INSURANCE_MODULE]);

vi.mock('../../lib/useModuleRegistry', () => ({
  useModuleRegistry: () => REGISTRY,
}));

const item = (kind: string, sort_order: number, name: string) => ({ kind, sort_order, name, payload: {} });
const modItems = (...keys: string[]) => keys.map((k, i) => item('module', i + 1, k));

const tpl = (over: Partial<TemplateRow> & Pick<TemplateRow, 'key' | 'name'>): TemplateRow => ({
  description: null,
  is_active: true,
  is_default: false,
  sort_order: 10,
  updated_at: '2026-10-09T00:00:00Z',
  department_count: 0,
  module_count: 0,
  stage_count: 0,
  tenants_using: 0,
  items: [],
  ...over,
});

const TEMPLATES: TemplateRow[] = [
  tpl({
    key: 'general', name: 'General', description: 'General business', is_default: true, sort_order: 10,
    department_count: 8, module_count: 6, stage_count: 2,
    items: [
      ...modItems('hr', 'legal', 'bd', 'it', 'pmo', 'procurement'),
      item('workflow_stage', 1, 'Cost Control Engineer'),
      item('workflow_stage', 2, 'Finance'),
    ],
  }),
  tpl({
    key: 'construction', name: 'Construction', sort_order: 20,
    department_count: 10, module_count: 8, stage_count: 0,
    items: modItems('hr', 'legal', 'bd', 'it', 'pmo', 'procurement', 'machine_operation', 'sustainability'),
  }),
  tpl({
    key: 'insurance', name: 'Insurance Brokerage', description: 'Standalone insurance brokerage', sort_order: 30,
    department_count: 8, module_count: 4, stage_count: 0,
    items: [...modItems('insurance', 'hr', 'it', 'legal'), item('gl_account', 1, '1000'), item('gl_account', 2, '1020')],
  }),
];

const mockInvoke = vi.fn();
const mockRpc = vi.fn();

vi.mock('../../lib/supabaseClient', () => ({
  supabase: {
    functions: { invoke: (...args: [string, unknown]) => mockInvoke(...args) },
    rpc: (...args: [string, unknown]) => mockRpc(...args),
  },
}));

function setup(opts: {
  templatesResult?: { data: unknown; error: { message: string } | null };
  createTenantResult?: { data: unknown; error: { message: string } | null };
  setModulesResult?: { data: unknown; error: { message: string } | null };
  inviteResult?: { data: unknown; error: { message: string } | null };
} = {}) {
  const {
    templatesResult = { data: TEMPLATES, error: null },
    createTenantResult = { data: { tenant: { id: 'tenant1' } }, error: null },
    setModulesResult = { data: null, error: null },
    inviteResult = { data: null, error: null },
  } = opts;

  mockInvoke.mockImplementation((fnName: string) => {
    if (fnName === 'create-tenant') return Promise.resolve(createTenantResult);
    if (fnName === 'invite-user') return Promise.resolve(inviteResult);
    throw new Error(`unhandled invoke: ${fnName}`);
  });
  mockRpc.mockImplementation((fnName: string) => {
    if (fnName === 'list_industry_templates') return Promise.resolve(templatesResult);
    if (fnName === 'set_tenant_modules') return Promise.resolve(setModulesResult);
    throw new Error(`unhandled rpc: ${fnName}`);
  });
}

beforeEach(() => {
  mockInvoke.mockReset();
  mockRpc.mockReset();
  setup();
});

async function fillStepOne(user: ReturnType<typeof userEvent.setup>, name = 'Nile Construction Co.', email = 'admin@nile.com') {
  await user.type(screen.getByLabelText('Company name'), name);
  await user.type(screen.getByLabelText('First admin email'), email);
}

async function goToStepTwo(user: ReturnType<typeof userEvent.setup>) {
  await user.click(screen.getByRole('button', { name: 'Next' }));
  // Templates load asynchronously; the default one is preselected once they arrive.
  await waitFor(() => expect(screen.getByLabelText('Industry template')).toHaveTextContent('General'));
}

function renderWizard(onCreated = vi.fn(), onClose = vi.fn()) {
  const utils = render(<CompanyCreateWizard open onClose={onClose} onCreated={onCreated} />);
  return { ...utils, onCreated, onClose };
}

describe('CompanyCreateWizard', () => {
  it('keeps Next disabled until the name is more than one character and the email is a real address', async () => {
    const user = userEvent.setup();
    renderWizard();

    const next = screen.getByRole('button', { name: 'Next' });
    expect(next).toBeDisabled();

    await user.type(screen.getByLabelText('Company name'), 'A');
    await user.type(screen.getByLabelText('First admin email'), 'admin@nile.com');
    expect(next).toBeDisabled(); // name is only 1 char

    await user.type(screen.getByLabelText('Company name'), 'cme');
    expect(next).toBeEnabled();

    // "contains @" alone (canNext) isn't enough -- isValidEmail also gates Next.
    await user.clear(screen.getByLabelText('First admin email'));
    await user.type(screen.getByLabelText('First admin email'), 'admin@nile');
    expect(next).toBeDisabled();
  });

  it('preselects the default module set and updates the count when toggled', async () => {
    const user = userEvent.setup();
    renderWizard();
    await fillStepOne(user);
    await goToStepTwo(user);

    expect(screen.getByText(/6 modules selected/)).toBeInTheDocument();
    expect(screen.getByRole('checkbox', { name: /^Human Resources/ })).toBeChecked();
    expect(screen.getByRole('checkbox', { name: /^Sustainability/ })).not.toBeChecked();

    await user.click(screen.getByRole('checkbox', { name: /^Sustainability/ }));
    expect(screen.getByText(/7 modules selected/)).toBeInTheDocument();
  });

  it('keeps entered data when going back from step 2 to step 1', async () => {
    const user = userEvent.setup();
    renderWizard();
    await fillStepOne(user, 'Nile Construction Co.', 'admin@nile.com');
    await goToStepTwo(user);

    await user.click(screen.getByRole('button', { name: 'Back' }));

    expect(screen.getByLabelText('Company name')).toHaveValue('Nile Construction Co.');
    expect(screen.getByLabelText('First admin email')).toHaveValue('admin@nile.com');
  });

  it('creates the tenant, applies the selected modules, invites the admin, and shows the success screen', async () => {
    setup();
    const user = userEvent.setup();
    const { onCreated } = renderWizard();
    await fillStepOne(user, 'Nile Construction Co.', 'admin@nile.com');
    await goToStepTwo(user);

    await user.click(screen.getByRole('button', { name: /create & invite/i }));

    await waitFor(() => expect(screen.getByText('Company created')).toBeInTheDocument());
    expect(mockInvoke).toHaveBeenCalledWith('create-tenant', {
      body: { name: 'Nile Construction Co.', industry_template: 'general' },
    });
    expect(mockRpc).toHaveBeenCalledWith('set_tenant_modules', {
      p_tenant_id: 'tenant1',
      p_modules: ['hr', 'legal', 'bd', 'it', 'pmo', 'procurement'],
    });
    expect(mockInvoke).toHaveBeenCalledWith('invite-user', {
      body: { tenant_id: 'tenant1', role_bundle: 'company_admin', email: 'admin@nile.com' },
    });
    expect(onCreated).toHaveBeenCalled();
    expect(screen.getByRole('button', { name: 'Done' })).toBeInTheDocument();
  });

  it('shows the create-tenant error and does not attempt modules or invite', async () => {
    setup({ createTenantResult: { data: null, error: { message: 'edge function timed out' } } });
    const user = userEvent.setup();
    const { onCreated } = renderWizard();
    await fillStepOne(user);
    await goToStepTwo(user);

    await user.click(screen.getByRole('button', { name: /create & invite/i }));

    await waitFor(() => expect(screen.getByText('edge function timed out')).toBeInTheDocument());
    expect(mockRpc).not.toHaveBeenCalledWith('set_tenant_modules', expect.anything());
    expect(mockInvoke).not.toHaveBeenCalledWith('invite-user', expect.anything());
    expect(onCreated).not.toHaveBeenCalled();
    expect(screen.queryByText('Company created')).not.toBeInTheDocument();
  });

  it('errors when create-tenant succeeds but returns no tenant id', async () => {
    setup({ createTenantResult: { data: { tenant: null }, error: null } });
    const user = userEvent.setup();
    renderWizard();
    await fillStepOne(user);
    await goToStepTwo(user);

    await user.click(screen.getByRole('button', { name: /create & invite/i }));

    await waitFor(() =>
      expect(screen.getByText(/tenant created but no id returned/i)).toBeInTheDocument()
    );
    expect(mockRpc).not.toHaveBeenCalledWith('set_tenant_modules', expect.anything());
  });

  it('treats a set_tenant_modules failure as non-fatal: still reaches the success screen with a warning', async () => {
    setup({ setModulesResult: { data: null, error: { message: 'permission denied' } } });
    const user = userEvent.setup();
    const { onCreated } = renderWizard();
    await fillStepOne(user);
    await goToStepTwo(user);

    await user.click(screen.getByRole('button', { name: /create & invite/i }));

    await waitFor(() => expect(screen.getByText('Company created')).toBeInTheDocument());
    expect(screen.getByText(/modules not fully applied: permission denied/i)).toBeInTheDocument();
    expect(onCreated).toHaveBeenCalled();
  });

  it('treats an invite-user failure as non-fatal: company still counts as created', async () => {
    setup({ inviteResult: { data: null, error: { message: 'mailer unavailable' } } });
    const user = userEvent.setup();
    const { onCreated } = renderWizard();
    await fillStepOne(user, 'Nile Construction Co.', 'admin@nile.com');
    await goToStepTwo(user);

    await user.click(screen.getByRole('button', { name: /create & invite/i }));

    await waitFor(() =>
      expect(
        screen.getByText(/company created \(nile construction co\.\) but inviting admin failed: mailer unavailable/i)
      ).toBeInTheDocument()
    );
    expect(onCreated).toHaveBeenCalled();
  });

  it('resets the form when the dialog is closed and reopened', async () => {
    const user = userEvent.setup();
    const { rerender, onClose, onCreated } = renderWizard();
    await fillStepOne(user, 'Nile Construction Co.', 'admin@nile.com');

    rerender(<CompanyCreateWizard open={false} onClose={onClose} onCreated={onCreated} />);
    rerender(<CompanyCreateWizard open onClose={onClose} onCreated={onCreated} />);

    expect(screen.getByLabelText('Company name')).toHaveValue('');
    expect(screen.getByLabelText('First admin email')).toHaveValue('');
  });

  it('offers every active template from the database, not a hard-coded pair', async () => {
    const user = userEvent.setup();
    renderWizard();
    await fillStepOne(user);
    await goToStepTwo(user);

    await user.click(screen.getByLabelText('Industry template'));
    expect(screen.getByRole('option', { name: 'General' })).toBeInTheDocument();
    expect(screen.getByRole('option', { name: 'Construction' })).toBeInTheDocument();
    expect(screen.getByRole('option', { name: 'Insurance Brokerage' })).toBeInTheDocument();
  });

  it('selecting Insurance Brokerage preselects exactly its modules, not the construction defaults', async () => {
    const user = userEvent.setup();
    renderWizard();
    await fillStepOne(user);
    await goToStepTwo(user);

    await user.click(screen.getByLabelText('Industry template'));
    await user.click(screen.getByRole('option', { name: 'Insurance Brokerage' }));

    expect(screen.getByText(/4 modules selected/)).toBeInTheDocument();
    expect(screen.getByRole('checkbox', { name: /^Insurance Brokerage/ })).toBeChecked();
    expect(screen.getByRole('checkbox', { name: /^Human Resources/ })).toBeChecked();
    expect(screen.getByRole('checkbox', { name: /^Business Development/ })).not.toBeChecked();
    expect(screen.getByRole('checkbox', { name: /^Project Management/ })).not.toBeChecked();
    expect(screen.getByRole('checkbox', { name: /^Procurement/ })).not.toBeChecked();
    expect(screen.getByText(/no approval pipeline/i)).toBeInTheDocument();
    expect(screen.getByText(/2 GL accounts/)).toBeInTheDocument();
  });

  it('creates an insurance company with the insurance template and its modules', async () => {
    const user = userEvent.setup();
    renderWizard();
    await fillStepOne(user, 'Kampala Brokers Ltd', 'admin@kb.co.ug');
    await goToStepTwo(user);
    await user.click(screen.getByLabelText('Industry template'));
    await user.click(screen.getByRole('option', { name: 'Insurance Brokerage' }));

    await user.click(screen.getByRole('button', { name: /create & invite/i }));

    await waitFor(() => expect(screen.getByText('Company created')).toBeInTheDocument());
    expect(mockInvoke).toHaveBeenCalledWith('create-tenant', {
      body: { name: 'Kampala Brokers Ltd', industry_template: 'insurance' },
    });
    expect(mockRpc).toHaveBeenCalledWith('set_tenant_modules', {
      p_tenant_id: 'tenant1',
      p_modules: ['insurance', 'hr', 'it', 'legal'],
    });
  });

  it('shows the selected template\'s approval stages instead of a fixed pipeline', async () => {
    const user = userEvent.setup();
    renderWizard();
    await fillStepOne(user);
    await goToStepTwo(user);

    expect(screen.getByText(/2-stage approval pipeline/)).toBeInTheDocument();
    expect(screen.getByText('Cost Control Engineer')).toBeInTheDocument();
  });

  it('blocks creation and shows the error when templates cannot be loaded', async () => {
    setup({ templatesResult: { data: null, error: { message: 'PLATFORM_MFA_REQUIRED: verify your second factor' } } });
    const user = userEvent.setup();
    renderWizard();
    await fillStepOne(user);
    await user.click(screen.getByRole('button', { name: 'Next' }));

    await waitFor(() => expect(screen.getByText(/verify your second factor/)).toBeInTheDocument());
    expect(screen.getByRole('button', { name: /create & invite/i })).toBeDisabled();
    expect(mockInvoke).not.toHaveBeenCalledWith('create-tenant', expect.anything());
  });
});
