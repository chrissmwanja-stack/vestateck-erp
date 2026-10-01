import {
  Apartment,
  AssignmentTurnedIn,
  Checklist,
  CorporateFare,
  Dashboard,
  People,
  PersonAdd,
  Rule,
} from '@mui/icons-material';
import { Box, Divider, List, ListItemButton, ListItemIcon, ListItemText, ListSubheader, Stack, Typography } from '@mui/material';
import { Link as RouterLink, Outlet, matchPath, useLocation } from 'react-router-dom';

// The Company Admin shell: one customer company's own administration,
// distinct from the platform console (/admin/*). Three administrative
// layers live in this codebase -- this is layer 2:
//
//   Platform Super Admin  -> features/admin/*, /admin/*
//   Company Admin         -> features/company-admin/*, /company-admin/*   (here)
//   Module Administration -> each module's pages/admin/*
//
// Company admins configure their organization, users & access, and
// approval workflows here. They do NOT automatically get transaction
// rights everywhere -- module access stays role-based. Platform admins
// reach this shell through View-as on a company.

interface CompanyAdminRoute {
  pattern: string;
  label: string;
  section: SectionId;
}

type SectionId = 'dashboard' | 'departments' | 'organizations' | 'members' | 'invite' | 'approvals' | 'setup';

const COMPANY_ADMIN_ROUTES: CompanyAdminRoute[] = [
  { pattern: '/company-admin', label: 'Dashboard', section: 'dashboard' },
  { pattern: '/company-admin/organization/departments', label: 'Departments', section: 'departments' },
  { pattern: '/company-admin/organization/organizations', label: 'Organizations', section: 'organizations' },
  { pattern: '/company-admin/users/members', label: 'Team members', section: 'members' },
  { pattern: '/company-admin/users/invite', label: 'Invite member', section: 'invite' },
  { pattern: '/company-admin/workflows/approvals', label: 'Approval workflow', section: 'approvals' },
  { pattern: '/company-admin/setup', label: 'Setup checklist', section: 'setup' },
];

export interface CompanyAdminSection {
  id: SectionId;
  label: string;
  to: string;
  icon: JSX.Element;
  hint: string;
}

export const COMPANY_ADMIN_GROUPS: { label: string | null; items: CompanyAdminSection[] }[] = [
  {
    label: null,
    items: [{ id: 'dashboard', label: 'Dashboard', to: '/company-admin', icon: <Dashboard fontSize="small" />, hint: 'Is this company ready?' }],
  },
  {
    label: 'Organization',
    items: [
      { id: 'departments', label: 'Departments', to: '/company-admin/organization/departments', icon: <Apartment fontSize="small" />, hint: 'Org chart backbone' },
      { id: 'organizations', label: 'Organizations', to: '/company-admin/organization/organizations', icon: <CorporateFare fontSize="small" />, hint: 'Company org units' },
    ],
  },
  {
    label: 'Users & access',
    items: [
      { id: 'members', label: 'Team members', to: '/company-admin/users/members', icon: <People fontSize="small" />, hint: 'Roles and module access' },
      { id: 'invite', label: 'Invite member', to: '/company-admin/users/invite', icon: <PersonAdd fontSize="small" />, hint: 'Bring someone in' },
    ],
  },
  {
    label: 'Workflows',
    items: [
      { id: 'approvals', label: 'Approval workflow', to: '/company-admin/workflows/approvals', icon: <Rule fontSize="small" />, hint: 'Stages, thresholds, approvers' },
    ],
  },
  {
    label: 'Setup',
    items: [
      { id: 'setup', label: 'Setup checklist', to: '/company-admin/setup', icon: <Checklist fontSize="small" />, hint: 'First-run steps' },
    ],
  },
];

export const COMPANY_ADMIN_SECTIONS: CompanyAdminSection[] = COMPANY_ADMIN_GROUPS.flatMap((g) => g.items);

// Exported so App.tsx can swap the ModuleTree out for this shell, the
// same way isConsoleRoute() works for the platform console.
export function isCompanyAdminRoute(pathname: string): boolean {
  return COMPANY_ADMIN_ROUTES.some((r) => matchPath({ path: r.pattern, end: true }, pathname));
}

export function resolveCompanyAdminRoute(pathname: string): CompanyAdminRoute {
  return (
    COMPANY_ADMIN_ROUTES.find((r) => matchPath({ path: r.pattern, end: true }, pathname)) ?? {
      pattern: pathname,
      label: 'Company administration',
      section: 'dashboard',
    }
  );
}

export const COMPANY_ADMIN_RAIL_WIDTH = 232;

export default function CompanyAdminLayout() {
  const location = useLocation();
  const current = resolveCompanyAdminRoute(location.pathname);

  return (
    <Box sx={{ display: 'flex', minHeight: 'calc(100vh - 64px)' }}>
      <Box
        component="nav"
        aria-label="Company administration"
        sx={{
          width: COMPANY_ADMIN_RAIL_WIDTH,
          minWidth: COMPANY_ADMIN_RAIL_WIDTH,
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
          <AssignmentTurnedIn sx={{ color: 'primary.main' }} />
          <Box>
            <Typography
              variant="overline"
              sx={{ color: 'primary.main', fontWeight: 700, letterSpacing: 1.2, lineHeight: 1.2, display: 'block' }}
            >
              Company admin
            </Typography>
            <Typography variant="caption" color="text.secondary">
              Your company&apos;s workspace settings
            </Typography>
          </Box>
        </Stack>
        <Divider />
        <List dense sx={{ px: 1, py: 1 }}>
          {COMPANY_ADMIN_GROUPS.map((group) => (
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
                        borderLeft: (t) => `3px solid ${t.palette.primary.main}`,
                        pl: '13px',
                      },
                    }}
                  >
                    <ListItemIcon sx={{ minWidth: 32, color: active ? 'primary.main' : 'text.secondary' }}>{s.icon}</ListItemIcon>
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
          <Typography variant="caption" color="text.secondary" sx={{ px: 1.5, display: 'block' }}>
            Module-specific configuration (finance, HR, procurement…) lives inside each module&apos;s own
            Administration section.
          </Typography>
        </Box>
      </Box>

      <Box component="section" sx={{ flex: 1, minWidth: 0, px: 4, pt: 3, pb: 6 }}>
        <Stack
          direction="row"
          alignItems="center"
          spacing={1}
          sx={{ borderBottom: (t) => `2px solid ${t.palette.primary.main}`, pb: 1, mb: 3 }}
        >
          <Typography variant="overline" sx={{ color: 'primary.main', fontWeight: 700, letterSpacing: 1.2 }}>
            {current.label}
          </Typography>
        </Stack>
        <Outlet />
      </Box>
    </Box>
  );
}
