import { useCallback, useEffect, useState } from 'react';
import {
  Alert,
  Box,
  Button,
  Card,
  CardContent,
  Chip,
  CircularProgress,
  Stack,
  Typography,
} from '@mui/material';
import { CheckCircle as CheckCircleIcon, RadioButtonUnchecked as OpenIcon } from '@mui/icons-material';
import { Link as RouterLink } from 'react-router-dom';
import { supabase } from '../../lib/supabaseClient';
import { useTenantAdminAccess } from './useTenantAdminAccess';

// Guided first-look for a company admin: departments -> positions ->
// invite team. Each step just links out to the existing admin screens
// (DepartmentsAdmin / PositionsAdmin / InviteMember) and reports whether
// there's anything there yet -- it doesn't duplicate their forms.
//
// Not gated to "first login only": there's no reliable signal for that
// without adding more state, and this doubles as a handy at-a-glance
// setup status page even after day one. Gated to tenant admins the same
// way InviteMember is.

interface Step {
  key: 'departments' | 'positions' | 'team';
  title: string;
  description: string;
  linkTo: string;
  linkLabel: string;
}

const STEPS: Step[] = [
  {
    key: 'departments',
    title: 'Set up departments',
    description: 'Departments are the backbone of your org chart and reporting lines.',
    linkTo: '/company-admin/organization/departments',
    linkLabel: 'Manage departments',
  },
  {
    key: 'positions',
    title: 'Add job positions',
    description: 'Positions need to exist before employees can be added or bulk-imported.',
    linkTo: '/hr/admin/positions',
    linkLabel: 'Manage positions',
  },
  {
    key: 'team',
    title: 'Invite your team',
    description: 'Bring in teammates and choose which modules and roles they get.',
    linkTo: '/company-admin/users/invite',
    linkLabel: 'Invite teammates',
  },
];

// Access check is the shared useTenantAdminAccess hook (same one
// InviteMember/TeamMembersAdmin use): is_company_admin or platform admin,
// impersonation-aware, re-fetched on auth changes. The /company-admin/setup
// route is additionally wrapped in RequireTenantAdmin, so this is belt and
// braces. (This file used to carry a forked copy of the hook keyed to the
// legacy staff_roles 'admin' row -- retired with the Phase 3 cleanup.)

export default function CompanySetupChecklist() {
  const access = useTenantAdminAccess();
  const [counts, setCounts] = useState<Record<Step['key'], number> | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async (tenantId: string) => {
    setLoading(true);
    setError(null);

    const [departments, positions, teamInvites] = await Promise.all([
      supabase
        .from('departments')
        .select('id', { count: 'exact', head: true })
        .eq('tenant_id', tenantId),
      supabase
        .from('hr_positions')
        .select('id', { count: 'exact', head: true })
        .eq('tenant_id', tenantId),
      supabase
        .from('invitations')
        .select('id', { count: 'exact', head: true })
        .eq('tenant_id', tenantId)
        .eq('role_bundle', 'member'),
    ]);

    const firstError = departments.error || positions.error || teamInvites.error;
    if (firstError) {
      setError(firstError.message);
      setLoading(false);
      return;
    }

    setCounts({
      departments: departments.count ?? 0,
      positions: positions.count ?? 0,
      team: teamInvites.count ?? 0,
    });
    setLoading(false);
  }, []);

  useEffect(() => {
    if (access?.isAdmin && access.tenantId) load(access.tenantId);
  }, [access?.isAdmin, access?.tenantId, load]);

  if (access?.isAdmin === false) {
    return (
      <Alert severity="warning" sx={{ maxWidth: 600, mx: 'auto', mt: 4 }}>
        Company setup is only available to admins.
      </Alert>
    );
  }

  const doneCount = counts ? STEPS.filter((s) => counts[s.key] > 0).length : 0;

  return (
    <Box sx={{ maxWidth: 720 }}>
      <Typography variant="h5" sx={{ mb: 1 }}>
        Company setup
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        {counts
          ? `${doneCount} of ${STEPS.length} steps have something in them.`
          : 'Get your company ready before real data starts flowing in.'}
      </Typography>

      {error && <Alert severity="error" sx={{ mb: 2 }}>{error}</Alert>}

      {loading ? (
        <Box display="flex" justifyContent="center" py={4}>
          <CircularProgress size={24} />
        </Box>
      ) : (
        <Stack spacing={2}>
          {STEPS.map((step) => {
            const count = counts?.[step.key] ?? 0;
            const done = count > 0;
            return (
              <Card key={step.key} variant="outlined">
                <CardContent>
                  <Stack direction="row" spacing={2} alignItems="flex-start">
                    <Box sx={{ pt: 0.5 }}>
                      {done ? (
                        <CheckCircleIcon color="success" />
                      ) : (
                        <OpenIcon color="disabled" />
                      )}
                    </Box>
                    <Box sx={{ flexGrow: 1 }}>
                      <Stack direction="row" spacing={1} alignItems="center">
                        <Typography variant="subtitle1">{step.title}</Typography>
                        {done && (
                          <Chip
                            size="small"
                            label={step.key === 'team' ? `${count} invited` : `${count} added`}
                            color="success"
                            variant="outlined"
                          />
                        )}
                      </Stack>
                      <Typography variant="body2" color="text.secondary" sx={{ mb: 1.5 }}>
                        {step.description}
                      </Typography>
                      <Button
                        component={RouterLink}
                        to={step.linkTo}
                        variant={done ? 'outlined' : 'contained'}
                        size="small"
                      >
                        {step.linkLabel}
                      </Button>
                    </Box>
                  </Stack>
                </CardContent>
              </Card>
            );
          })}
        </Stack>
      )}
    </Box>
  );
}