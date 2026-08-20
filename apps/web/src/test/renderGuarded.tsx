import type { ReactElement } from 'react';
import { render } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router-dom';

// Shared by the RequireAuth/RequireModule/RequireFinanceTeam/
// RequirePlatformAdmin tests -- they're all the same shape: a guard
// element wrapping one protected route, reached via a nested-route
// <Outlet/>, with a sibling /login (or /) route to land on if the
// guard denies/redirects.
export function renderGuarded(guard: ReactElement, initialPath = '/protected') {
  return render(
    <MemoryRouter initialEntries={[initialPath]}>
      <Routes>
        <Route path="/login" element={<div>Login page</div>} />
        <Route path="/" element={<div>Workspace home</div>} />
        <Route element={guard}>
          <Route path={initialPath} element={<div>Protected content</div>} />
        </Route>
      </Routes>
    </MemoryRouter>
  );
}
