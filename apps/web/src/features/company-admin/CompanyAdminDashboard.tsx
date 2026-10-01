import { useCallback, useEffect, useState } from 'react';
import {
  Alert,
  Box,
  Button,
  Card,
  CardContent,
  Chip,
  CircularProgress,
  LinearProgress,
  Paper,
  Stack,
  Typography,
} from '@mui/material';
import {
  CheckCircle as DoneIcon,
  HelpOutline as UnknownIcon,
  RadioButtonUnchecked as OpenIcon,
} from '@mui/icons-material';
import { Link as RouterLink } from 'react-router-dom';
import { supabase } from '../../lib/supabaseClient';
import { readinessChecks, readinessHeadline, readinessPercent, type ReadinessInput } from './companyReadiness';

// Company Admin landing page. Answers one question:
//
//   "Is this company properly configured and ready to operate?"
//
// Deliberately NOT a transaction dashboard -- business activity lives in
// the modules. This is setup/governance status: organization, people,
// modules, workflow. Every count query is tolerated independently, so a
// table a given role can't read shows as "unknown" instead of breaking
// the page.

interface Snapshot extends ReadinessInput {
  tenantName: string | null;
  modules: string[];
}

// Head-count query that tolerates being pointed at any tenant table.
// The generated client types supabase.from() as two literal-union
// overloads, so a helper taking a runtime table name needs this one
// scoped cast; the tables themselves are the real ones (each has a
// tenant-scoped SELECT policy verified in the migrations).
async function countOrNull(table: string, tenantId: string, extra?: (q: any) => any): Promise<number | null> {
  let q = (supabase.from as (t: string) => any)(table)
    .select('id', { count: 'exact', head: true })
    .eq('tenant_id', tenantId);
  if (extra) q = extra(q);
  const { count, error } = await q;
  return error ? null : count ?? 0;
}

export default function CompanyAdminDashboard() {
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [failedAll, setFailedAll] = useState(false);

  const load = useCallback(async () => {
    setFailedAll(false);
    // Impersonation-aware: resolves to the company being viewed-as.
    const { data: tenantId } = await supabase.rpc('get_my_tenant_id');
    if (!tenantId) {
      setFailedAll(true);
      setSnapshot(null);
      return;
    }
    const [departments, positions, members, teamInvites, stages, assignments, modulesRes, tenantRes] =
      await Promise.all([
        countOrNull('departments', tenantId),
        countOrNull('hr_positions', tenantId),
        countOrNull('app_users', tenantId),
        countOrNull('invitations', tenantId, (q) => q.eq('role_bundle', 'member')),
        countOrNull('workflow_stages', tenantId),
        countOrNull('approval_assignments', tenantId),
        supabase.from('tenant_modules').select('module').eq('tenant_id', tenantId),
        supabase.from('tenants').select('name').eq('id', tenantId).maybeSingle(),
      ]);
    setSnapshot({
      tenantName: (tenantRes.data?.name as string | undefined) ?? null,
      departments,
      positions,
      members,
      teamInvites,
      modulesEnabled: modulesRes.error ? null : (modulesRes.data?.length ?? 0),
      workflowStages: stages,
      approvalAssignments: assignments,
      modules: (modulesRes.data ?? []).map((m: { module: string }) => m.module),
    });
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  if (failedAll) {
    return (
      <Alert severity="error" sx={{ maxWidth: 640 }}>
        Could not determine your company context. Refresh the page; if this persists, your session may have expired.
      </Alert>
    );
  }

  if (!snapshot) {
    return (
      <Box display="flex" justifyContent="center" py={6}>
        <CircularProgress />
      </Box>
    );
  }

  const checks = readinessChecks(snapshot);
  const percent = readinessPercent(checks);

  return (
    <Box sx={{ maxWidth: 1100 }}>
      {/* READINESS HEADER */}
      <Paper
        sx={{
          background: 'linear-gradient(135deg, #123B44 0%, #1B5560 60%, #2E6B76 100%)',
          color: '#fff',
          borderRadius: 2,
          p: { xs: 2.5, md: 3 },
          mb: 3,
        }}
      >
        <Typography variant="overline" sx={{ color: '#E0B368', letterSpacing: 1.2, fontWeight: 700 }}>
          Company administration
        </Typography>
        <Typography variant="h5" sx={{ fontWeight: 700 }}>
          {snapshot.tenantName ?? 'Your company'}
        </Typography>
        <Typography variant="body2" sx={{ opacity: 0.85, mb: 2, maxWidth: 640 }}>
          {readinessHeadline(percent)}
        </Typography>
        <Stack direction="row" alignItems="center" spacing={2}>
          <Box sx={{ flex: 1, maxWidth: 420 }}>
            <LinearProgress
              variant="determinate"
              value={percent ?? 0}
              sx={{ height: 8, borderRadius: 4, bgcolor: 'rgba(255,255,255,0.2)', '& .MuiLinearProgress-bar': { bgcolor: '#E0B368', borderRadius: 4 } }}
            />
          </Box>
          <Typography variant="subtitle1" sx={{ fontWeight: 700 }}>
            {percent == null ? '—' : `${percent}% ready`}
          </Typography>
        </Stack>
      </Paper>

      <Box sx={{ display: 'grid', gridTemplateColumns: { xs: '1fr', lg: '1.6fr 1fr' }, gap: 2 }}>
        {/* READINESS CHECKS */}
        <Stack spacing={1.5}>
          <Typography variant="subtitle2">Setup status</Typography>
          {checks.map((c) => (
            <Card key={c.key} variant="outlined">
              <CardContent sx={{ py: 1.75, '&:last-child': { pb: 1.75 } }}>
                <Stack direction="row" spacing={2} alignItems="flex-start">
                  <Box sx={{ pt: 0.25 }}>
                    {c.done === true ? (
                      <DoneIcon color="success" />
                    ) : c.done === null ? (
                      <UnknownIcon color="disabled" />
                    ) : (
                      <OpenIcon color="disabled" />
                    )}
                  </Box>
                  <Box sx={{ flexGrow: 1, minWidth: 0 }}>
                    <Stack direction="row" spacing={1} alignItems="center" flexWrap="wrap" useFlexGap>
                      <Typography variant="subtitle1">{c.label}</Typography>
                      {c.done === true && <Chip size="small" label="Done" color="success" variant="outlined" />}
                      {c.done === null && <Chip size="small" label="Unknown" variant="outlined" />}
                    </Stack>
                    <Typography variant="body2" color="text.secondary" sx={{ mb: c.linkTo ? 1 : 0 }}>
                      {c.detail}
                    </Typography>
                    {c.linkTo && (
                      <Button component={RouterLink} to={c.linkTo} size="small" variant={c.done ? 'outlined' : 'contained'}>
                        {c.linkLabel}
                      </Button>
                    )}
                  </Box>
                </Stack>
              </CardContent>
            </Card>
          ))}
        </Stack>

        {/* AT A GLANCE */}
        <Stack spacing={2}>
          <Paper variant="outlined" sx={{ p: 2, borderRadius: 2 }}>
            <Typography variant="subtitle2" sx={{ mb: 1 }}>
              Modules enabled
            </Typography>
            {snapshot.modules.length ? (
              <Stack direction="row" spacing={0.75} flexWrap="wrap" useFlexGap>
                {snapshot.modules.map((m) => (
                  <Chip key={m} size="small" label={m} variant="outlined" />
                ))}
              </Stack>
            ) : (
              <Typography variant="body2" color="text.secondary">
                {snapshot.modulesEnabled == null ? 'Could not be read.' : 'None yet.'}
              </Typography>
            )}
            <Typography variant="caption" color="text.secondary" sx={{ display: 'block', mt: 1.5 }}>
              Module entitlements are managed by the platform team; per-module configuration lives inside each
              module&apos;s Administration section.
            </Typography>
          </Paper>

          <Paper variant="outlined" sx={{ p: 2, borderRadius: 2 }}>
            <Typography variant="subtitle2" sx={{ mb: 1 }}>
              At a glance
            </Typography>
            <Stack spacing={0.75}>
              <Typography variant="body2">
                Team: <b>{snapshot.members ?? '—'}</b> member{(snapshot.members ?? 0) === 1 ? '' : 's'}
                {snapshot.teamInvites ? ` · ${snapshot.teamInvites} invite${snapshot.teamInvites === 1 ? '' : 's'} out` : ''}
              </Typography>
              <Typography variant="body2">
                Workflow: <b>{snapshot.workflowStages ?? '—'}</b> stages · <b>{snapshot.approvalAssignments ?? '—'}</b> approver
                assignments
              </Typography>
              <Typography variant="body2">
                Organization: <b>{snapshot.departments ?? '—'}</b> departments · <b>{snapshot.positions ?? '—'}</b> positions
              </Typography>
            </Stack>
          </Paper>

          <Paper variant="outlined" sx={{ p: 2, borderRadius: 2 }}>
            <Typography variant="subtitle2" sx={{ mb: 1 }}>
              Shortcuts
            </Typography>
            <Stack spacing={1}>
              <Button component={RouterLink} to="/company-admin/users/members" variant="outlined" size="small">
                Manage team
              </Button>
              <Button component={RouterLink} to="/company-admin/workflows/approvals" variant="outlined" size="small">
                Approval workflow
              </Button>
              <Button component={RouterLink} to="/company-admin/setup" variant="outlined" size="small">
                Setup checklist
              </Button>
            </Stack>
          </Paper>
        </Stack>
      </Box>
    </Box>
  );
}
