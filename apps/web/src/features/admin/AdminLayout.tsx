import {
  Box,
  Chip,
  Divider,
  List,
  ListItemButton,
  ListItemIcon,
  ListItemText,
  ListSubheader,
  Stack,
  Typography,
} from '@mui/material';
import {
  AdminPanelSettings,
  Business,
  Campaign,
  Category,
  Dashboard,
  Flag,
  Groups,
  HealthAndSafety,
  History,
  People,
  Security,
  Settings as SettingsIcon,
} from '@mui/icons-material';
import { Link as RouterLink, Outlet, matchPath, useLocation } from 'react-router-dom';
import { usePlatformAdminSession } from './usePlatformAdminSession';

// The operator console shell. Everything under /admin that is *platform*
// administration (not a customer company's own admin screens) renders
// inside this: a persistent left rail with the console's few sections, a
// slim ochre-accented header naming where you are, and the page.
//
// Why a separate shell rather than ModuleTree: ModuleTree lists one
// company's modules. The console is not inside any company -- it is the
// vendor's view *over* all of them. Before this, the console borrowed a
// "Platform Administration" portal inside ModuleTree, four of whose seven
// entries were tenant-admin screens (Company Setup, Invite Team, Manage
// Team, Approval Workflow) that silently operated on the platform admin's
// reserved home tenant. Those live inside customer workspaces and are
// reached through View-as; they are no longer offered here.
//
// Route table: every console route, its label, and which rail item it
// belongs to (so Company Detail highlights "Companies"). Keep this in
// sync with the RequirePlatformAdmin route block in App.tsx -- any
// screen routed there but missing here renders inside the shell with
// a generic header and NO rail entry, so it must be listed.
interface ConsoleRoute {
  pattern: string;
  label: string;
  section: SectionId;
}

type SectionId =
  | 'overview'
  | 'companies'
  | 'users'
  | 'team'
  | 'audit'
  | 'templates'
  | 'announcements'
  | 'flags'
  | 'health'
  | 'settings';

const CONSOLE_ROUTES: ConsoleRoute[] = [
  { pattern: '/admin', label: 'Overview', section: 'overview' },
  { pattern: '/admin/companies', label: 'Companies', section: 'companies' },
  { pattern: '/admin/companies/:tenantId', label: 'Company detail', section: 'companies' },
  { pattern: '/admin/users', label: 'Users', section: 'users' },
  { pattern: '/admin/team', label: 'Platform team', section: 'team' },
  { pattern: '/admin/audit', label: 'Audit log', section: 'audit' },
  { pattern: '/admin/templates', label: 'Industry templates', section: 'templates' },
  { pattern: '/admin/announcements', label: 'Announcements', section: 'announcements' },
  { pattern: '/admin/flags', label: 'Feature flags', section: 'flags' },
  { pattern: '/admin/health', label: 'Platform health', section: 'health' },
  { pattern: '/admin/settings', label: 'Platform settings', section: 'settings' },
];

export interface ConsoleSection {
  id: SectionId;
  label: string;
  to: string;
  icon: JSX.Element;
  hint: string;
}

// The rail, in display order, grouped. null label = no group header
// (Overview stands alone at the top).
export const CONSOLE_GROUPS: { label: string | null; items: ConsoleSection[] }[] = [
  {
    label: null,
    items: [{ id: 'overview', label: 'Overview', to: '/admin', icon: <Dashboard fontSize="small" />, hint: 'KPIs, alerts, onboarding' }],
  },
  {
    label: 'Customers',
    items: [
      { id: 'companies', label: 'Companies', to: '/admin/companies', icon: <Business fontSize="small" />, hint: 'Every customer on the platform' },
      { id: 'users', label: 'Users', to: '/admin/users', icon: <People fontSize="small" />, hint: 'Everyone, across all companies' },
    ],
  },
  {
    label: 'Platform',
    items: [
      { id: 'templates', label: 'Templates', to: '/admin/templates', icon: <Category fontSize="small" />, hint: 'Industry starter packages' },
      { id: 'announcements', label: 'Announcements', to: '/admin/announcements', icon: <Campaign fontSize="small" />, hint: 'Notices to all users' },
      { id: 'flags', label: 'Feature flags', to: '/admin/flags', icon: <Flag fontSize="small" />, hint: 'Rollouts and kill switches' },
    ],
  },
  {
    label: 'Security',
    items: [
      { id: 'team', label: 'Platform team', to: '/admin/team', icon: <Groups fontSize="small" />, hint: 'Who can operate this console' },
      { id: 'audit', label: 'Audit log', to: '/admin/audit', icon: <History fontSize="small" />, hint: 'Who did what, and why' },
    ],
  },
  {
    label: 'System',
    items: [
      { id: 'health', label: 'Health', to: '/admin/health', icon: <HealthAndSafety fontSize="small" />, hint: 'Jobs, database, backlog' },
      { id: 'settings', label: 'Settings', to: '/admin/settings', icon: <SettingsIcon fontSize="small" />, hint: 'Branding, security, notifications' },
    ],
  },
];

// Flat view, kept for callers that want every section in rail order.
export const CONSOLE_SECTIONS: ConsoleSection[] = CONSOLE_GROUPS.flatMap((g) => g.items);

// Exported so App.tsx and tests share one definition of "is this a
// console route" (ModuleTree is hidden and AdminLayout shown for these).
export function isConsoleRoute(pathname: string): boolean {
  return CONSOLE_ROUTES.some((r) => matchPath({ path: r.pattern, end: true }, pathname));
}

export function resolveConsoleRoute(pathname: string): ConsoleRoute {
  return (
    CONSOLE_ROUTES.find((r) => matchPath({ path: r.pattern, end: true }, pathname)) ?? {
      pattern: pathname,
      label: 'Platform administration',
      section: 'overview',
    }
  );
}

export const CONSOLE_RAIL_WIDTH = 232;

export default function AdminLayout() {
  const location = useLocation();
  const current = resolveConsoleRoute(location.pathname);
  const { session } = usePlatformAdminSession();

  return (
    <Box sx={{ display: 'flex', minHeight: 'calc(100vh - 64px)' }}>
      <Box
        component="nav"
        aria-label="Platform console"
        sx={{
          width: CONSOLE_RAIL_WIDTH,
          minWidth: CONSOLE_RAIL_WIDTH,
          borderRight: 1,
          borderColor: 'divider',
          bgcolor: 'background.paper',
          position: 'sticky',
          top: 64,
          alignSelf: 'flex-start',
          height: 'calc(100vh - 64px)',
          display: 'flex',
          flexDirection: 'column',
        }}
      >
        <Stack direction="row" alignItems="center" spacing={1} sx={{ px: 2, pt: 2, pb: 1.5 }}>
          <AdminPanelSettings sx={{ color: 'secondary.main' }} />
          <Box>
            <Typography
              variant="overline"
              sx={{ color: 'secondary.main', fontWeight: 700, letterSpacing: 1.2, lineHeight: 1.2, display: 'block' }}
            >
              Platform console
            </Typography>
            <Typography variant="caption" color="text.secondary">
              Operator view over every company
            </Typography>
          </Box>
        </Stack>
        <Divider />
        <List dense sx={{ px: 1, py: 1 }}>
          {CONSOLE_GROUPS.map((group) => (
            <Box key={group.label ?? '__top'}>
              {group.label && (
                <ListSubheader
                  disableSticky
                  sx={{ lineHeight: '22px', mt: 0.5, bgcolor: 'transparent', color: 'text.secondary', fontSize: 11, fontWeight: 700, letterSpacing: 0.8, textTransform: 'uppercase', px: 1.5 }}
                >
                  {group.label}
                </ListSubheader>
              )}
              {group.items.map((s) => {
                const active = current.section === s.id;
                return (
                  <ListItemButton
                    key={s.id}
                    component={RouterLink}
                    to={s.to}
                    selected={active}
                    sx={{
                      borderRadius: 1,
                      mb: 0.25,
                      '&.Mui-selected': {
                        bgcolor: 'action.selected',
                        borderLeft: (t) => `3px solid ${t.palette.secondary.main}`,
                        pl: '13px',
                      },
                    }}
                  >
                    <ListItemIcon sx={{ minWidth: 32, color: active ? 'secondary.main' : 'text.secondary' }}>{s.icon}</ListItemIcon>
                    <ListItemText
                      primary={
                        <Typography variant="body2" fontWeight={active ? 700 : 500}>
                          {s.label}
                        </Typography>
                      }
                      secondary={s.hint}
                      secondaryTypographyProps={{ variant: 'caption', noWrap: true }}
                    />
                  </ListItemButton>
                );
              })}
            </Box>
          ))}
        </List>
        <Box sx={{ flex: 1 }} />
        <Divider />
        <Box sx={{ p: 1.5 }}>
          <ListItemButton component={RouterLink} to="/account/security" sx={{ borderRadius: 1 }} dense>
            <ListItemIcon sx={{ minWidth: 32, color: 'text.secondary' }}>
              <Security fontSize="small" />
            </ListItemIcon>
            <ListItemText
              primary={
                <Typography variant="body2" fontWeight={500}>
                  My security
                </Typography>
              }
              secondary={
                session ? (
                  session.hasMfaFactor ? (
                    session.sessionIsMfa ? (
                      'Authenticator verified'
                    ) : (
                      'Step-up needed'
                    )
                  ) : (
                    <Chip size="small" label="Enrol authenticator" color="warning" variant="outlined" sx={{ height: 18, fontSize: 10 }} />
                  )
                ) : (
                  ' '
                )
              }
              secondaryTypographyProps={{ variant: 'caption', component: 'div' }}
            />
          </ListItemButton>
          <Typography variant="caption" color="text.secondary" sx={{ px: 1.5, display: 'block', mt: 1 }}>
            Customer-side admin (team, setup, approvals) is reached through <b>View as</b> on a company.
          </Typography>
        </Box>
      </Box>

      <Box component="section" sx={{ flex: 1, minWidth: 0, px: 4, pt: 3, pb: 6 }}>
        <Stack
          direction="row"
          alignItems="center"
          spacing={1}
          sx={{ borderBottom: (t) => `2px solid ${t.palette.secondary.main}`, pb: 1, mb: 3 }}
        >
          <Typography variant="overline" sx={{ color: 'secondary.main', fontWeight: 700, letterSpacing: 1.2 }}>
            {current.label}
          </Typography>
        </Stack>
        <Outlet />
      </Box>
    </Box>
  );
}
