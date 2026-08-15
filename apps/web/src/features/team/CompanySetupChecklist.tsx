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
    linkTo: '/admin/departments',
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
    linkTo: '/team/invite',
    linkLabel: 'Invite teammates',
  },
];

// app_users' only SELECT policy scopes by tenant_id, not by your own id,
// so a query without .eq('id', ...) can return every user in your tenant
// and .single() throws on more than one row. Get the caller's own id
// from the session first, then filter on it.
function useTenantAdminAccess() {
  const [state, setState] = useState<{ isAdmin: boolean; tenantId: string | null } | null>(null);
  useEffect(() => {
    let cancelled = false;
    supabase.auth.getSession().then(async ({ data: sessionData }) => {
      const userId = sessionData.session?.user.id;
      if (!userId) {
        if (!cancelled) setState({ isAdmin: false, tenantId: null });
        return;
      }
      const { data: appUser, error: appUserError } = await supabase
        .from('app_users')
        .select('tenant_id, is_platform_admin')
        .eq('id', userId)
        .maybeSingle();
      if (cancelled || appUserError || !appUser) {
        if (!cancelled) setState({ isAdmin: false, tenantId: null });
        return;
      }
      // app_users.tenant_id is the caller's real (home) tenant and doesn't
      // move during impersonation. get_my_tenant_id() resolves to the
      // impersonated tenant server-side, so it's the one that actually
      // matches what invitations/staff_roles/RLS are scoped to right now.
      const { data: effectiveTenantId, error: tenantIdError } = await supabase.rpc('get_my_tenant_id');
      if (cancelled) return;
      const tenantId = tenantIdError || !effectiveTenantId ? appUser.tenant_id : effectiveTenantId;
      // Platform admins get full access to every module while impersonating
      // a tenant (view mode included) -- they don't need a staff_roles admin
      // row in that company to manage it.
      if (appUser.is_platform_admin) {
        setState({ isAdmin: true, tenantId });
        return;
      }
      const { data: adminRole } = await supabase
        .from('staff_roles')
        .select('id')
        .eq('user_id', userId)
        .eq('tenant_id', tenantId)
        .eq('role', 'admin')
        .limit(1)
        .maybeSingle();
      if (cancelled) return;
      setState({ isAdmin: !!adminRole, tenantId });
    });
    return () => {
      cancelled = true;
    };
  }, []);
  return state;
}

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