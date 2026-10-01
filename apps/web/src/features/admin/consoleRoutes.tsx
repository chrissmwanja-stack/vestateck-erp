import { lazy, type ComponentType, type LazyExoticComponent, type ReactElement } from 'react';
import { matchPath } from 'react-router-dom';
import {
  AdminPanelSettings,
  Business,
  Campaign,
  Dashboard,
  Flag,
  History,
  LibraryBooks,
  MonitorHeart,
  People,
  Settings as SettingsIcon,
} from '@mui/icons-material';

// The platform console's ONE route table.
//
// Everything that needs to know "what is a console page" derives from this
// file, so the lists can no longer drift apart:
//
//   - App.tsx renders its <Route>s by mapping CONSOLE_ROUTES (a page that is
//     not in this table has no route at all, and vice versa),
//   - AdminLayout's left rail is CONSOLE_SECTIONS, grouped by CONSOLE_GROUPS,
//   - isConsoleRoute() decides when App.tsx swaps ModuleTree for the console
//     shell,
//   - ModuleTree's "Platform Administration" portal is built from
//     CONSOLE_SECTIONS.
//
// Before this, six of the eleven console routes were registered in App.tsx
// but missing from the shell's route table, so they rendered outside the
// console (ModuleTree back, no rail, wrong header) and four had no link
// anywhere.
//
// Paths are deliberately still under /admin. When the console moves to
// /platform/*, change the patterns and the `to`s here and add redirects; no
// other file needs to know.

export type SectionId =
  | 'overview'
  | 'companies'
  | 'users'
  | 'templates'
  | 'announcements'
  | 'flags'
  | 'team'
  | 'audit'
  | 'health'
  | 'settings';

export type GroupId = 'overview' | 'customers' | 'platform' | 'security' | 'system';

export interface ConsoleGroup {
  id: GroupId;
  // null = no heading (the Overview entry stands alone at the top).
  label: string | null;
}

export interface ConsoleSection {
  id: SectionId;
  label: string;
  to: string;
  icon: ReactElement;
  hint: string;
  group: GroupId;
}

export interface ConsoleRoute {
  pattern: string;
  label: string;
  section: SectionId;
  Component: LazyExoticComponent<ComponentType>;
}

export const CONSOLE_GROUPS: ConsoleGroup[] = [
  { id: 'overview', label: null },
  { id: 'customers', label: 'Customers' },
  { id: 'platform', label: 'Platform' },
  { id: 'security', label: 'Security' },
  { id: 'system', label: 'System' },
];

export const CONSOLE_SECTIONS: ConsoleSection[] = [
  { id: 'overview', label: 'Overview', to: '/admin', icon: <Dashboard fontSize="small" />, hint: 'KPIs, alerts, onboarding', group: 'overview' },
  { id: 'companies', label: 'Companies', to: '/admin/companies', icon: <Business fontSize="small" />, hint: 'Every customer on the platform', group: 'customers' },
  { id: 'users', label: 'Users', to: '/admin/users', icon: <People fontSize="small" />, hint: 'Everyone, across companies', group: 'customers' },
  { id: 'templates', label: 'Industry templates', to: '/admin/templates', icon: <LibraryBooks fontSize="small" />, hint: 'Starter setups per industry', group: 'platform' },
  { id: 'flags', label: 'Feature flags', to: '/admin/flags', icon: <Flag fontSize="small" />, hint: 'Per-company rollouts', group: 'platform' },
  { id: 'announcements', label: 'Announcements', to: '/admin/announcements', icon: <Campaign fontSize="small" />, hint: 'Notices to company users', group: 'platform' },
  { id: 'team', label: 'Platform team', to: '/admin/team', icon: <AdminPanelSettings fontSize="small" />, hint: 'Who can operate this console', group: 'security' },
  { id: 'audit', label: 'Audit log', to: '/admin/audit', icon: <History fontSize="small" />, hint: 'Who did what, and why', group: 'security' },
  { id: 'health', label: 'Platform health', to: '/admin/health', icon: <MonitorHeart fontSize="small" />, hint: 'Is the platform itself well?', group: 'system' },
  { id: 'settings', label: 'Settings', to: '/admin/settings', icon: <SettingsIcon fontSize="small" />, hint: 'Branding, security, notifications', group: 'system' },
];

// Rail display order: CONSOLE_SECTIONS grouped under CONSOLE_GROUPS. This
// is what AdminLayout renders as its left rail -- derived, so the rail can
// never drift from the section list.
export const CONSOLE_RAIL: { label: string | null; items: ConsoleSection[] }[] = CONSOLE_GROUPS.map((g) => ({
  label: g.label,
  items: CONSOLE_SECTIONS.filter((s) => s.group === g.id),
}));

// Lazy so importing this file (AdminLayout, moduleTreeData, tests) does not
// pull every console page into the bundle or the test run.
export const CONSOLE_ROUTES: ConsoleRoute[] = [
  { pattern: '/admin', label: 'Overview', section: 'overview', Component: lazy(() => import('./PlatformDashboard')) },
  { pattern: '/admin/companies', label: 'Companies', section: 'companies', Component: lazy(() => import('./CompaniesConsole')) },
  { pattern: '/admin/companies/:tenantId', label: 'Company detail', section: 'companies', Component: lazy(() => import('./CompanyDetail')) },
  { pattern: '/admin/users', label: 'Users', section: 'users', Component: lazy(() => import('./PlatformUsersDirectory')) },
  { pattern: '/admin/templates', label: 'Industry templates', section: 'templates', Component: lazy(() => import('./IndustryTemplatesAdmin')) },
  { pattern: '/admin/flags', label: 'Feature flags', section: 'flags', Component: lazy(() => import('./FeatureFlagsAdmin')) },
  { pattern: '/admin/announcements', label: 'Announcements', section: 'announcements', Component: lazy(() => import('./AnnouncementsAdmin')) },
  { pattern: '/admin/team', label: 'Platform team', section: 'team', Component: lazy(() => import('./PlatformTeam')) },
  { pattern: '/admin/audit', label: 'Audit log', section: 'audit', Component: lazy(() => import('./PlatformAuditLog')) },
  { pattern: '/admin/health', label: 'Platform health', section: 'health', Component: lazy(() => import('./PlatformHealthPage')) },
  { pattern: '/admin/settings', label: 'Platform settings', section: 'settings', Component: lazy(() => import('./AdminSettingsPage')) },
];

// True for exactly the console's own pages. Tenant-side screens that merely
// share the /admin prefix (/admin/departments, /admin/cost-codes,
// /admin/approval-workflow, ...) are NOT console routes.
export function isConsoleRoute(pathname: string): boolean {
  return CONSOLE_ROUTES.some((r) => matchPath({ path: r.pattern, end: true }, pathname));
}

export function resolveConsoleRoute(pathname: string): Pick<ConsoleRoute, 'pattern' | 'label' | 'section'> {
  return (
    CONSOLE_ROUTES.find((r) => matchPath({ path: r.pattern, end: true }, pathname)) ?? {
      pattern: pathname,
      label: 'Platform administration',
      section: 'overview',
    }
  );
}