import { render, screen } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import { describe, expect, it } from 'vitest';
import CompanyAdminLayout, { isCompanyAdminRoute, resolveCompanyAdminRoute } from './CompanyAdminLayout';

// The Company Admin shell: one persistent rail covering every
// /company-admin/* route, grouped into Organization / Users & access /
// Workflows / Setup. Route table shared with App.tsx so "hide
// ModuleTree here" can't drift from "wrap in CompanyAdminLayout here".

function renderAt(path: string) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <Routes>
        <Route element={<CompanyAdminLayout />}>
          <Route path="/company-admin" element={<div>Dashboard page</div>} />
          <Route path="/company-admin/organization/departments" element={<div>Departments page</div>} />
          <Route path="/company-admin/organization/organizations" element={<div>Organizations page</div>} />
          <Route path="/company-admin/users/members" element={<div>Members page</div>} />
          <Route path="/company-admin/users/invite" element={<div>Invite page</div>} />
          <Route path="/company-admin/workflows/approvals" element={<div>Approvals page</div>} />
          <Route path="/company-admin/setup" element={<div>Setup page</div>} />
        </Route>
      </Routes>
    </MemoryRouter>
  );
}

describe('isCompanyAdminRoute / resolveCompanyAdminRoute', () => {
  it('recognises exactly the company-admin routes', () => {
    expect(isCompanyAdminRoute('/company-admin')).toBe(true);
    expect(isCompanyAdminRoute('/company-admin/organization/departments')).toBe(true);
    expect(isCompanyAdminRoute('/company-admin/organization/organizations')).toBe(true);
    expect(isCompanyAdminRoute('/company-admin/users/members')).toBe(true);
    expect(isCompanyAdminRoute('/company-admin/users/invite')).toBe(true);
    expect(isCompanyAdminRoute('/company-admin/workflows/approvals')).toBe(true);
    expect(isCompanyAdminRoute('/company-admin/setup')).toBe(true);
    // platform console and module screens are NOT company-admin routes
    expect(isCompanyAdminRoute('/admin')).toBe(false);
    expect(isCompanyAdminRoute('/admin/companies')).toBe(false);
    expect(isCompanyAdminRoute('/requests/new')).toBe(false);
    expect(isCompanyAdminRoute('/company-admin/anything-else')).toBe(false);
  });

  it('resolves a real label for every routed screen (no fallback)', () => {
    expect(resolveCompanyAdminRoute('/company-admin').label).toBe('Dashboard');
    expect(resolveCompanyAdminRoute('/company-admin/users/members').label).toBe('Team members');
    expect(resolveCompanyAdminRoute('/company-admin/workflows/approvals').label).toBe('Approval workflow');
  });
});

describe('CompanyAdminLayout', () => {
  it('renders the rail with every section and the page', () => {
    renderAt('/company-admin');
    const nav = screen.getByRole('navigation', { name: /company administration/i });
    expect(nav).toHaveTextContent('Dashboard');
    expect(nav).toHaveTextContent('Departments');
    expect(nav).toHaveTextContent('Organizations');
    expect(nav).toHaveTextContent('Team members');
    expect(nav).toHaveTextContent('Invite member');
    expect(nav).toHaveTextContent('Approval workflow');
    expect(nav).toHaveTextContent('Setup checklist');
    // group headers
    expect(nav).toHaveTextContent('Organization');
    expect(nav).toHaveTextContent('Users & access');
    expect(nav).toHaveTextContent('Workflows');
    expect(nav).toHaveTextContent('Setup');
    expect(screen.getByText('Dashboard page')).toBeInTheDocument();
  });

  it('highlights the current section', () => {
    renderAt('/company-admin/users/members');
    expect(screen.getByRole('link', { name: /Team members/ })).toHaveClass('Mui-selected');
    expect(screen.getByRole('link', { name: /Dashboard/ })).not.toHaveClass('Mui-selected');
  });

  it('does not offer platform-console or module-admin screens', () => {
    renderAt('/company-admin');
    const nav = screen.getByRole('navigation', { name: /company administration/i });
    expect(nav).not.toHaveTextContent('Companies');
    expect(nav).not.toHaveTextContent('Audit log');
    expect(nav).not.toHaveTextContent('Chart of Accounts');
  });
});
