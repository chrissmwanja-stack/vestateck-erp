import { useCallback, useEffect, useState } from 'react';
import {
  Alert,
  Box,
  Button,
  Chip,
  CircularProgress,
  Paper,
  Stack,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableRow,
  Tooltip,
  Typography,
} from '@mui/material';
import { Refresh } from '@mui/icons-material';
import { Link as RouterLink } from 'react-router-dom';
import { supabase } from '../../lib/supabaseClient';
import { friendlyPlatformError } from './usePlatformAdminSession';
import {
  JOB_EXPECTED_HOURS,
  JOB_LABEL,
  cronLevel,
  formatBytes,
  hoursAgo,
  jobLevel,
  normaliseHealth,
  overallLevel,
  type HealthLevel,
  type PlatformHealth,
} from './platformConfig';

// /admin/health -- is the platform itself well?
//
// Distinct from the Overview's "health" section, which is about the
// *business* (onboarding funnel, quiet companies). This page is about the
// *system*: did the scheduled jobs run, is anything stuck in approval for
// weeks, how big is the database, which migration is live, is pg_cron
// installed. One RPC (get_platform_health, 20260923090000) builds the
// whole document so the page has nothing to compute -- the helpers in
// platformConfig.ts only decide what colour each line is.

const LEVEL_COLOR: Record<HealthLevel, 'success' | 'warning' | 'error' | 'default'> = {
  ok: 'success',
  warn: 'warning',
  error: 'error',
  unknown: 'default',
};
const LEVEL_LABEL: Record<HealthLevel, string> = { ok: 'Healthy', warn: 'Needs a look', error: 'Problem', unknown: 'No data' };

function Stat({ label, value, hint }: { label: string; value: string | number; hint?: string }) {
  return (
    <Paper variant="outlined" sx={{ p: 2, minWidth: 160, flex: '1 1 160px' }}>
      <Typography variant="caption" color="text.secondary">
        {label}
      </Typography>
      <Typography variant="h6">{value}</Typography>
      {hint && (
        <Typography variant="caption" color="text.secondary">
          {hint}
        </Typography>
      )}
    </Paper>
  );
}

function Section({ title, hint, children }: { title: string; hint?: string; children: React.ReactNode }) {
  return (
    <Paper variant="outlined" sx={{ p: 2 }}>
      <Typography variant="subtitle1" fontWeight={600}>
        {title}
      </Typography>
      {hint && (
        <Typography variant="caption" color="text.secondary" display="block" sx={{ mb: 1 }}>
          {hint}
        </Typography>
      )}
      {children}
    </Paper>
  );
}

export default function PlatformHealthPage() {
  const [health, setHealth] = useState<PlatformHealth | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    const { data, error: err } = await supabase.rpc('get_platform_health');
    setLoading(false);
    if (err) {
      setError(friendlyPlatformError(err.message));
      return;
    }
    setError(null);
    setHealth(normaliseHealth(data ?? {}));
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  const now = new Date();
  const overall = health ? overallLevel(health, now) : 'unknown';

  return (
    <Box sx={{ p: 3 }}>
      <Stack direction="row" alignItems="flex-start" justifyContent="space-between" sx={{ mb: 2 }}>
        <Box>
          <Stack direction="row" spacing={1.5} alignItems="center">
            <Typography variant="h5">Platform health</Typography>
            {health && <Chip label={LEVEL_LABEL[overall]} color={LEVEL_COLOR[overall]} size="small" />}
          </Stack>
          <Typography variant="body2" color="text.secondary">
            Scheduled jobs, stuck work, database and storage footprint, live migration. Checked{' '}
            {health ? hoursAgo(health.checked_at, now) : '…'}.
          </Typography>
        </Box>
        <Button startIcon={loading ? <CircularProgress size={16} /> : <Refresh />} onClick={() => void load()} disabled={loading}>
          Refresh
        </Button>
      </Stack>

      {error && (
        <Alert severity="error" sx={{ mb: 2 }}>
          {error}
        </Alert>
      )}
      {!health && !error && <CircularProgress />}

      {health && (
        <Stack spacing={2}>
          <Stack direction="row" spacing={2} flexWrap="wrap" useFlexGap>
            <Stat label="Database" value={formatBytes(health.database.size_bytes)} hint={`PostgreSQL ${health.database.version}`} />
            <Stat
              label="Connections"
              value={`${health.database.connections} / ${health.database.max_connections || '?'}`}
              hint={health.database.max_connections && health.database.connections / health.database.max_connections > 0.8 ? 'over 80% — watch this' : 'in use / max'}
            />
            <Stat label="Migration" value={health.migrations.latest ?? 'n/a'} hint={health.migrations.count ? `${health.migrations.count} applied` : 'schema_migrations not readable'} />
            <Stat label="Storage" value={health.storage.available ? formatBytes(health.storage.buckets.reduce((a, b) => a + b.bytes, 0)) : 'n/a'} hint={health.storage.available ? `${health.storage.buckets.length} bucket${health.storage.buckets.length === 1 ? '' : 's'}` : 'storage schema not present'} />
            <Stat label="Read-only companies" value={health.read_only_tenants} />
            <Stat label="Open View-as sessions" value={health.open_impersonations} />
            <Stat label="Live announcements" value={health.announcements_live} />
          </Stack>

          <Section
            title="Background jobs"
            hint="The two sweeps run when a customer opens the relevant page (no fixed cadence). The operator digest is scheduled daily at 04:00 UTC."
          >
            {health.jobs.length === 0 ? (
              <Typography variant="body2" color="text.secondary">
                No job has recorded a run yet. Sweeps log themselves the first time a customer opens Maintenance or
                Certifications after this release; the digest logs at its next scheduled run.
              </Typography>
            ) : (
              <Table size="small">
                <TableHead>
                  <TableRow>
                    <TableCell>Job</TableCell>
                    <TableCell>Status</TableCell>
                    <TableCell>Last run</TableCell>
                    <TableCell align="right">Affected</TableCell>
                    <TableCell align="right">Runs (7d)</TableCell>
                    <TableCell align="right">Errors (7d)</TableCell>
                    <TableCell>Detail</TableCell>
                  </TableRow>
                </TableHead>
                <TableBody>
                  {health.jobs.map((j) => {
                    const lvl = jobLevel(j, now);
                    const expected = JOB_EXPECTED_HOURS[j.job];
                    return (
                      <TableRow key={j.job}>
                        <TableCell>
                          {JOB_LABEL[j.job] ?? j.job}
                          {j.tenants_7d > 0 && (
                            <Typography variant="caption" color="text.secondary" display="block">
                              {j.tenants_7d} compan{j.tenants_7d === 1 ? 'y' : 'ies'} this week
                            </Typography>
                          )}
                        </TableCell>
                        <TableCell>
                          <Tooltip title={expected ? `Expected at least every ${expected} h` : 'Usage-driven; no expected cadence'}>
                            <Chip size="small" label={LEVEL_LABEL[lvl]} color={LEVEL_COLOR[lvl]} />
                          </Tooltip>
                        </TableCell>
                        <TableCell>{hoursAgo(j.last_run_at, now)}</TableCell>
                        <TableCell align="right">{j.last_affected ?? '—'}</TableCell>
                        <TableCell align="right">{j.runs_7d}</TableCell>
                        <TableCell align="right">{j.errors_7d}</TableCell>
                        <TableCell sx={{ maxWidth: 320 }}>
                          <Typography variant="caption" color="text.secondary" noWrap title={j.last_detail ?? ''}>
                            {j.last_detail ?? ''}
                          </Typography>
                        </TableCell>
                      </TableRow>
                    );
                  })}
                </TableBody>
              </Table>
            )}
          </Section>

          <Section title="Scheduler (pg_cron)" hint={health.cron.installed ? 'What the database scheduler knows about.' : 'pg_cron is not installed on this database — the operator digest will not run on its own.'}>
            {!health.cron.installed ? (
              <Alert severity="warning">Enable the pg_cron extension in the Supabase dashboard (Database → Extensions), then re-apply the digest migration or call cron.schedule manually.</Alert>
            ) : health.cron.jobs.length === 0 ? (
              <Typography variant="body2" color="text.secondary">
                No cron jobs registered.
              </Typography>
            ) : (
              <Table size="small">
                <TableHead>
                  <TableRow>
                    <TableCell>Job</TableCell>
                    <TableCell>Schedule</TableCell>
                    <TableCell>Status</TableCell>
                    <TableCell>Last run</TableCell>
                    <TableCell>Message</TableCell>
                  </TableRow>
                </TableHead>
                <TableBody>
                  {health.cron.jobs.map((c) => {
                    const lvl = cronLevel(c);
                    return (
                      <TableRow key={c.jobname}>
                        <TableCell>{c.jobname}</TableCell>
                        <TableCell>
                          <code>{c.schedule}</code>
                        </TableCell>
                        <TableCell>
                          <Chip size="small" label={c.active ? c.last_status ?? 'not run yet' : 'inactive'} color={LEVEL_COLOR[lvl]} />
                        </TableCell>
                        <TableCell>{hoursAgo(c.last_start, now)}</TableCell>
                        <TableCell sx={{ maxWidth: 320 }}>
                          <Typography variant="caption" color="text.secondary" noWrap title={c.last_message ?? ''}>
                            {c.last_message ?? ''}
                          </Typography>
                        </TableCell>
                      </TableRow>
                    );
                  })}
                </TableBody>
              </Table>
            )}
          </Section>

          <Stack direction={{ xs: 'column', md: 'row' }} spacing={2}>
            <Box sx={{ flex: 1 }}>
              <Section title="Stuck approvals" hint="Open requests that have not moved stage for more than 7 days, per company. Usually an approver who left or a role nobody holds.">
                {health.stuck_approvals.length === 0 ? (
                  <Typography variant="body2" color="text.secondary">
                    Nothing stuck.
                  </Typography>
                ) : (
                  <Table size="small">
                    <TableBody>
                      {health.stuck_approvals.map((s) => (
                        <TableRow key={s.tenant_id}>
                          <TableCell>
                            <RouterLink to={`/admin/companies/${s.tenant_id}?tab=approvals`}>{s.tenant_name}</RouterLink>
                          </TableCell>
                          <TableCell align="right">{s.count}</TableCell>
                          <TableCell align="right">
                            <Typography variant="caption" color="text.secondary">
                              oldest {s.oldest_days} d
                            </Typography>
                          </TableCell>
                        </TableRow>
                      ))}
                    </TableBody>
                  </Table>
                )}
              </Section>
            </Box>
            <Box sx={{ flex: 1 }}>
              <Section title="Stale invitations" hint="Pending invites older than 7 days. Re-send or revoke from the company's page.">
                {health.stale_invites.length === 0 ? (
                  <Typography variant="body2" color="text.secondary">
                    None.
                  </Typography>
                ) : (
                  <Table size="small">
                    <TableBody>
                      {health.stale_invites.map((s) => (
                        <TableRow key={s.tenant_id}>
                          <TableCell>
                            <RouterLink to={`/admin/companies/${s.tenant_id}`}>{s.tenant_name}</RouterLink>
                          </TableCell>
                          <TableCell align="right">{s.count}</TableCell>
                          <TableCell align="right">
                            <Typography variant="caption" color="text.secondary">
                              oldest {s.oldest_days} d
                            </Typography>
                          </TableCell>
                        </TableRow>
                      ))}
                    </TableBody>
                  </Table>
                )}
              </Section>
            </Box>
          </Stack>

          <Stack direction={{ xs: 'column', md: 'row' }} spacing={2}>
            <Box sx={{ flex: 1 }}>
              <Section title="Operator digest" hint="Delivery of the daily digest email.">
                <Stack direction="row" spacing={2} flexWrap="wrap" useFlexGap>
                  <Stat label="Last generated" value={hoursAgo(health.digest.last_generated_at, now)} />
                  <Stat label="Pending delivery" value={health.digest.pending} hint="waiting for send-operator-digest" />
                  <Stat label="Failed (7d)" value={health.digest.failed_7d} hint={health.digest.failed_7d > 0 ? 'check RESEND_API_KEY / function logs' : undefined} />
                </Stack>
                <Typography variant="caption" color="text.secondary" sx={{ display: 'block', mt: 1 }}>
                  History and manual runs: <RouterLink to="/admin/settings?tab=notifications">Settings → Notifications</RouterLink>
                </Typography>
              </Section>
            </Box>
            <Box sx={{ flex: 1 }}>
              <Section title="Storage" hint="Objects per bucket, as reported by storage.objects.">
                {!health.storage.available ? (
                  <Typography variant="body2" color="text.secondary">
                    Not available.
                  </Typography>
                ) : health.storage.buckets.length === 0 ? (
                  <Typography variant="body2" color="text.secondary">
                    No objects stored yet.
                  </Typography>
                ) : (
                  <Table size="small">
                    <TableBody>
                      {health.storage.buckets.map((b) => (
                        <TableRow key={b.bucket}>
                          <TableCell>{b.bucket}</TableCell>
                          <TableCell align="right">{b.objects.toLocaleString()} objects</TableCell>
                          <TableCell align="right">{formatBytes(b.bytes)}</TableCell>
                        </TableRow>
                      ))}
                    </TableBody>
                  </Table>
                )}
              </Section>
            </Box>
          </Stack>
        </Stack>
      )}
    </Box>
  );
}
