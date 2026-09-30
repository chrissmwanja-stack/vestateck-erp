import { render, screen } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import AdminLayout, { isConsoleRoute, resolveConsoleRoute } from './AdminLayout';

// The console shell: one persistent rail covering EVERY console route
// (grouped into Customers / Platform / Security / System), no
// tenant-admin entries, and a route table App.tsx shares so "hide
// ModuleTree here" can't drift from "wrap in AdminLayout here".

let adminSession: { isPlatformAdmin: boolean; hasMfaFactor: boolean; sessionIsMfa: boolean; canAct: boolean } | null = {
  isPlatformAdmin: true,
  hasMfaFactor: true,
  sessionIsMfa: true,
  canAct: true,
};
vi.mock('./usePlatformAdminSession', () => ({
  usePlatformAdminSession: () => ({ session: adminSession, loading: false, error: null, refresh: vi.fn() }),
}));

function renderAt(path: string) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <Routes>
        <Route element={<AdminLayout />}>
          <Route path="/admin" element={<div>Overview page</div>} />
          <Route path="/admin/companies" element={<div>Companies page</div>} />
          <Route path="/admin/companies/:tenantId" element={<div>Detail page</div>} />
          <Route path="/admin/users" element={<div>Users page</div>} />
          <Route path="/admin/team" element={<div>Team page</div>} />
          <Route path="/admin/audit" element={<div>Audit page</div>} />
          <Route path="/admin/templates" element={<div>Templates page</div>} />
          <Route path="/admin/announcements" element={<div>Announcements page</div>} />
          <Route path="/admin/flags" element={<div>Flags page</div>} />
          <Route path="/admin/health" element={<div>Health page</div>} />
          <Route path="/admin/settings" element={<div>Settings page</div>} />
        </Route>
      </Routes>
    </MemoryRouter>
  );
}

beforeEach(() => {
  adminSession = { isPlatformAdmin: true, hasMfaFactor: true, sessionIsMfa: true, canAct: true };
});

describe('isConsoleRoute / resolveConsoleRoute', () => {
  it('recognises exactly the console routes', () => {
    expect(isConsoleRoute('/admin')).toBe(true);
    expect(isConsoleRoute('/admin/companies')).toBe(true);
    expect(isConsoleRoute('/admin/companies/abc-123')).toBe(true);
    expect(isConsoleRoute('/admin/users')).toBe(true);
    expect(isConsoleRoute('/admin/team')).toBe(true);
    expect(isConsoleRoute('/admin/audit')).toBe(true);
    expect(isConsoleRoute('/admin/templates')).toBe(true);
    expect(isConsoleRoute('/admin/announcements')).toBe(true);
    expect(isConsoleRoute('/admin/flags')).toBe(true);
    expect(isConsoleRoute('/admin/health')).toBe(true);
    expect(isConsoleRoute('/admin/settings')).toBe(true);
    // tenant-side screens that happen to share the /admin prefix
    expect(isConsoleRoute('/admin/approval-workflow')).toBe(false);
    expect(isConsoleRoute('/admin/departments')).toBe(false);
    expect(isConsoleRoute('/admin/cost-codes')).toBe(false);
    expect(isConsoleRoute('/setup')).toBe(false);
  });

  it('maps Company Detail to the Companies section', () => {
    expect(resolveConsoleRoute('/admin/companies/abc').section).toBe('companies');
    expect(resolveConsoleRoute('/admin/companies/abc').label).toBe('Company detail');
  });

  it('resolves a real label for every routed console screen (no fallback)', () => {
    // These six were routed in App.tsx but once fell through to the
    // generic "Platform administration" fallback -- if a new screen is
    // added to App.tsx without a CONSOLE_ROUTES entry, this breaks.
    expect(resolveConsoleRoute('/admin/users').label).toBe('Users');
    expect(resolveConsoleRoute('/admin/team').label).toBe('Platform team');
    expect(resolveConsoleRoute('/admin/templates').label).toBe('Industry templates');
    expect(resolveConsoleRoute('/admin/announcements').label).toBe('Announcements');
    expect(resolveConsoleRoute('/admin/flags').label).toBe('Feature flags');
    expect(resolveConsoleRoute('/admin/health').label).toBe('Platform health');
  });
});

describe('AdminLayout', () => {
  it('renders the rail with every console section and the page', () => {
    renderAt('/admin/companies');
    const nav = screen.getByRole('navigation', { name: /platform console/i });
    // All ten rail items, so no console screen is unreachable once the
    // ModuleTree is swapped out for the shell.
    expect(nav).toHaveTextContent('Overview');
    expect(nav).toHaveTextContent('Companies');
    expect(nav).toHaveTextContent('Users');
    expect(nav).toHaveTextContent('Templates');
    expect(nav).toHaveTextContent('Announcements');
    expect(nav).toHaveTextContent('Feature flags');
    expect(nav).toHaveTextContent('Platform team');
    expect(nav).toHaveTextContent('Audit log');
    expect(nav).toHaveTextContent('Health');
    expect(nav).toHaveTextContent('Settings');
    // Group headers
    expect(nav).toHaveTextContent('Customers');
    expect(nav).toHaveTextContent('Platform');
    expect(nav).toHaveTextContent('Security');
    expect(nav).toHaveTextContent('System');
    expect(screen.getByText('Companies page')).toBeInTheDocument();
  });

  it('shows the page-specific header label on the health screen', () => {
    renderAt('/admin/health');
    expect(screen.getByText('Platform health')).toBeInTheDocument();
    expect(screen.getByText('Health page')).toBeInTheDocument();
  });

  it('shows the page-specific header label on the templates screen', () => {
    renderAt('/admin/templates');
    expect(screen.getByText('Industry templates')).toBeInTheDocument();
    expect(screen.getByText('Templates page')).toBeInTheDocument();
  });

  it('does not offer tenant-admin screens in the rail', () => {
    renderAt('/admin');
    const nav = screen.getByRole('navigation', { name: /platform console/i });
    expect(nav).not.toHaveTextContent('Invite Team');
    expect(nav).not.toHaveTextContent('Manage Team');
    expect(nav).not.toHaveTextContent('Company Setup');
    expect(nav).not.toHaveTextContent('Approval Workflow');
    expect(nav).toHaveTextContent(/reached through View as/i);
  });

  it('highlights Companies while on a company detail page', () => {
    renderAt('/admin/companies/abc');
    const companies = screen.getByRole('link', { name: /Companies/ });
    expect(companies).toHaveClass('Mui-selected');
    expect(screen.getByRole('link', { name: /Overview/ })).not.toHaveClass('Mui-selected');
  });

  it('highlights its own rail item on the newly-routed screens, not Overview', () => {
    // Regression: /admin/users & co. used to fall through to the
    // overview section, so Overview lit up on every one of them.
    renderAt('/admin/users');
    expect(screen.getByRole('link', { name: /Users/ })).toHaveClass('Mui-selected');
    expect(screen.getByRole('link', { name: /Overview/ })).not.toHaveClass('Mui-selected');
  });

  it('nags to enrol an authenticator when none is enrolled', () => {
    adminSession = { isPlatformAdmin: true, hasMfaFactor: false, sessionIsMfa: false, canAct: true };
    renderAt('/admin');
    expect(screen.getByText('Enrol authenticator')).toBeInTheDocument();
    expect(screen.getByRole('link', { name: /my security/i })).toHaveAttribute('href', '/account/security');
  });

  it('shows step-up state when a factor exists but the session is aal1', () => {
    adminSession = { isPlatformAdmin: true, hasMfaFactor: true, sessionIsMfa: false, canAct: false };
    renderAt('/admin');
    expect(screen.getByText('Step-up needed')).toBeInTheDocument();
  });
});
