import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import CompanyDetail, { buildProfilePatch, daysUntil } from './CompanyDetail';

// Company Detail is the operator's per-customer screen. These tests pin
// the client half of the item-2 contract (20260922180000):
//   * the Summary tab renders profile / seats / lifecycle from
//     get_tenant_profile();
//   * profile edits send a *minimal* jsonb patch to update_tenant_profile
//     (only changed keys -- that's what the audit diff relies on);
//   * read-only and suspend go through a reason dialog and the right RPC;
//   * privileged buttons are disabled with the MFA hint when the session
//     is not stepped up.

const mockRpc = vi.fn();
const mockFrom = vi.fn();
vi.mock('../../lib/supabaseClient', () => ({
  supabase: {
    rpc: (...args: unknown[]) => mockRpc(...args),
    from: (...args: unknown[]) => mockFrom(...args),
  },
}));

let adminSession = { isPlatformAdmin: true, hasMfaFactor: false, sessionIsMfa: false, canAct: true };
vi.mock('./usePlatformAdminSession', async () => {
  const actual = await vi.importActual<typeof import('./usePlatformAdminSession')>('./usePlatformAdminSession');
  return {
    ...actual,
    usePlatformAdminSession: () => ({ session: adminSession, loading: false, error: null, refresh: vi.fn() }),
  };
});

const TENANT: Parameters<typeof buildProfilePatch>[0] = {
  id: 't1',
  name: 'Acme Ltd',
  status: 'active' as const,
  created_at: '2026-01-10T08:00:00Z',
  industry_template: 'general',
  contact_name: 'Jane Doe',
  contact_email: 'jane@acme.example',
  contact_phone: null,
  tax_id: '1000123456',
  address: null,
  country: 'UG',
  plan: 'standard',
  subscription_status: 'active',
  seat_limit: 10,
  trial_ends_at: null,
  renews_at: null,
  status_changed_at: null,
  read_only: false,
  read_only_reason: null,
  read_only_since: null,
  updated_at: '2026-09-01T08:00:00Z',
};

function profileFor(tenant: typeof TENANT) {
  return {
    tenant,
    seats: { limit: tenant.seat_limit, members: 4, pending_invites: 2 },
    activity: {
      modules: 3,
      requests_30d: 12,
      last_request_at: '2026-09-20T10:00:00Z',
      last_sign_in_at: '2026-09-21T10:00:00Z',
      company_admins: [{ name: 'Jane Doe', email: 'jane@acme.example' }],
    },
    last_status_event: null,
    recent_events: [
      {
        id: 'e1',
        action: 'tenant.modules.set',
        reason: null,
        created_at: '2026-09-15T10:00:00Z',
        actor_email: 'owner@vestateck.example',
        mfa_verified: true,
      },
    ],
    notes_count: 0,
  };
}

const ANALYTICS = {
  requests_by_status: [],
  requests_by_month: [],
  purchase_orders: { count: 0, total_value: 0 },
  members_by_department: [],
  top_requesters: [],
};

function setupRpc(tenant = TENANT) {
  mockRpc.mockImplementation((fn: string) => {
    switch (fn) {
      case 'get_tenant_profile':
        return Promise.resolve({ data: profileFor(tenant), error: null });
      case 'get_company_analytics':
        return Promise.resolve({ data: ANALYTICS, error: null });
      case 'get_tenant_workflow_stages':
        return Promise.resolve({ data: [], error: null });
      default:
        return Promise.resolve({ data: null, error: null });
    }
  });
}

function renderDetail(initialPath = '/admin/companies/t1') {
  return render(
    <MemoryRouter initialEntries={[initialPath]}>
      <Routes>
        <Route path="/admin/companies/:tenantId" element={<CompanyDetail />} />
        <Route path="/requests/new" element={<div>New request page</div>} />
      </Routes>
    </MemoryRouter>
  );
}

beforeEach(() => {
  mockRpc.mockReset();
  mockFrom.mockReset();
  adminSession = { isPlatformAdmin: true, hasMfaFactor: false, sessionIsMfa: false, canAct: true };
});

describe('buildProfilePatch', () => {
  it('returns only the keys that differ from the saved row, with typed values', () => {
    const draft = {
      name: 'Acme Ltd',
      contact_name: 'Jane Doe',
      contact_email: 'jane@acme.example',
      contact_phone: '+256 700 000000',
      tax_id: '1000123456',
      address: '',
      country: 'UG',
      plan: 'enterprise',
      subscription_status: 'active',
      seat_limit: '',
      trial_ends_at: '',
      renews_at: '2026-12-31',
    };
    const patch = buildProfilePatch(TENANT, draft);
    expect(Object.keys(patch).sort()).toEqual(['contact_phone', 'plan', 'renews_at', 'seat_limit']);
    expect(patch.contact_phone).toBe('+256 700 000000');
    expect(patch.plan).toBe('enterprise');
    expect(patch.seat_limit).toBeNull(); // blank = unlimited
    expect(typeof patch.renews_at).toBe('string');
    expect(new Date(patch.renews_at as string).getFullYear()).toBe(2026);
  });

  it('is empty when nothing changed', () => {
    const draft = {
      name: TENANT.name,
      contact_name: TENANT.contact_name ?? '',
      contact_email: TENANT.contact_email ?? '',
      contact_phone: '',
      tax_id: TENANT.tax_id ?? '',
      address: '',
      country: 'UG',
      plan: 'standard',
      subscription_status: 'active',
      seat_limit: '10',
      trial_ends_at: '',
      renews_at: '',
    };
    expect(buildProfilePatch(TENANT, draft)).toEqual({});
  });
});

describe('daysUntil', () => {
  it('rounds up and goes negative once past', () => {
    const now = new Date('2026-09-22T12:00:00Z');
    expect(daysUntil('2026-09-25T00:00:00Z', now)).toBe(3);
    expect(daysUntil('2026-09-20T00:00:00Z', now)).toBe(-2);
    expect(daysUntil(null, now)).toBeNull();
  });
});

describe('CompanyDetail summary tab', () => {
  it('renders profile, seats and lifecycle from get_tenant_profile', async () => {
    setupRpc();
    renderDetail();

    expect(await screen.findByRole('heading', { name: 'Acme Ltd' })).toBeInTheDocument();
    expect(mockRpc).toHaveBeenCalledWith('get_tenant_profile', { p_tenant_id: 't1' });

    expect(screen.getByText('6 / 10')).toBeInTheDocument(); // 4 members + 2 pending of 10
    expect(screen.getByText('jane@acme.example')).toBeInTheDocument();
    expect(screen.getByText('1000123456')).toBeInTheDocument();
    expect(screen.getByText('Modules changed')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Make read-only' })).toBeEnabled();
    expect(screen.getByRole('button', { name: 'Suspend' })).toBeEnabled();
    expect(screen.getByRole('link', { name: /full audit log/i })).toHaveAttribute('href', '/admin/audit?tenant=t1');
  });

  it('sends only the changed fields to update_tenant_profile and refreshes', async () => {
    setupRpc();
    const user = userEvent.setup();
    renderDetail();
    await screen.findByRole('heading', { name: 'Acme Ltd' });

    await user.click(screen.getByRole('button', { name: 'Edit' }));
    const phone = screen.getByLabelText('Contact phone');
    await user.type(phone, '+256 700 111222');

    mockRpc.mockImplementationOnce((fn: string) => {
      expect(fn).toBe('update_tenant_profile');
      return Promise.resolve({ data: { ...TENANT, contact_phone: '+256 700 111222' }, error: null });
    });
    await user.click(screen.getByRole('button', { name: 'Save' }));

    await waitFor(() =>
      expect(mockRpc).toHaveBeenCalledWith('update_tenant_profile', {
        p_tenant_id: 't1',
        p_patch: { contact_phone: '+256 700 111222' },
      })
    );
    expect(await screen.findByText('Profile saved.')).toBeInTheDocument();
  });

  it('requires a reason to enable read-only and calls set_tenant_read_only', async () => {
    setupRpc();
    const user = userEvent.setup();
    renderDetail();
    await screen.findByRole('heading', { name: 'Acme Ltd' });

    await user.click(screen.getByRole('button', { name: 'Make read-only' }));
    const dialog = await screen.findByRole('dialog');
    const confirm = within(dialog).getByRole('button', { name: 'Make read-only' });
    expect(confirm).toBeDisabled();

    await user.type(within(dialog).getByLabelText(/reason/i), 'Invoice 60 days overdue');
    expect(confirm).toBeEnabled();
    await user.click(confirm);

    await waitFor(() =>
      expect(mockRpc).toHaveBeenCalledWith('set_tenant_read_only', {
        p_tenant_id: 't1',
        p_read_only: true,
        p_reason: 'Invoice 60 days overdue',
      })
    );
  });

  it('shows the read-only banner with reason and offers to lift it', async () => {
    setupRpc({
      ...TENANT,
      read_only: true,
      read_only_reason: 'Payment overdue',
      read_only_since: '2026-09-18T00:00:00Z',
    });
    renderDetail();
    await screen.findByRole('heading', { name: 'Acme Ltd' });

    expect(screen.getByText(/Payment overdue/)).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Lift read-only' })).toBeInTheDocument();
  });

  it('routes suspend through the reason dialog and set_tenant_status', async () => {
    setupRpc();
    const user = userEvent.setup();
    renderDetail();
    await screen.findByRole('heading', { name: 'Acme Ltd' });

    await user.click(screen.getByRole('button', { name: 'Suspend' }));
    const dialog = await screen.findByRole('dialog');
    await user.type(within(dialog).getByLabelText(/reason/i), 'Contract terminated');
    await user.click(within(dialog).getByRole('button', { name: 'Suspend' }));

    await waitFor(() =>
      expect(mockRpc).toHaveBeenCalledWith('set_tenant_status', {
        p_tenant_id: 't1',
        p_status: 'suspended',
        p_reason: 'Contract terminated',
      })
    );
  });

  it('disables privileged buttons with the MFA hint when the session is not stepped up', async () => {
    adminSession = { isPlatformAdmin: true, hasMfaFactor: true, sessionIsMfa: false, canAct: false };
    setupRpc();
    renderDetail();
    await screen.findByRole('heading', { name: 'Acme Ltd' });

    expect(screen.getByRole('button', { name: 'Suspend' })).toBeDisabled();
    expect(screen.getByRole('button', { name: 'Make read-only' })).toBeDisabled();
    expect(screen.getByRole('button', { name: 'View as' })).toBeDisabled();
    expect(screen.getByRole('button', { name: 'Edit' })).toBeDisabled();
  });

  it('warns when a trial is about to end', async () => {
    const soon = new Date(Date.now() + 3 * 86_400_000).toISOString();
    setupRpc({ ...TENANT, plan: 'trial', subscription_status: 'trialing', trial_ends_at: soon });
    renderDetail();
    await screen.findByRole('heading', { name: 'Acme Ltd' });
    expect(screen.getByText(/Trial ends in 3 days/)).toBeInTheDocument();
  });

  it('surfaces the friendly server error when a profile save is refused', async () => {
    setupRpc();
    const user = userEvent.setup();
    renderDetail();
    await screen.findByRole('heading', { name: 'Acme Ltd' });

    await user.click(screen.getByRole('button', { name: 'Edit' }));
    await user.type(screen.getByLabelText('Contact phone'), '123');
    mockRpc.mockImplementationOnce(() =>
      Promise.resolve({ data: null, error: { message: 'PLATFORM_MFA_REQUIRED: Editing a company\'s profile requires MFA' } })
    );
    await user.click(screen.getByRole('button', { name: 'Save' }));

    expect(await screen.findByText("Editing a company's profile requires MFA")).toBeInTheDocument();
  });
});
