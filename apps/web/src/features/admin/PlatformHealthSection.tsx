import { useMemo } from 'react';
import {
  Box,
  Button,
  Chip,
  Link,
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
import { Link as RouterLink } from 'react-router-dom';
import {
  MODULE_LABEL,
  STAGE_HINTS,
  STAGE_LABELS,
  funnelSummary,
  normaliseFunnel,
  sortStalled,
  trendLabel,
  trendOf,
  underusedModules,
  type FunnelRow,
  type ModuleUsageRow,
  type QuietRow,
  type StalledRow,
  type TrialRow,
} from './platformHealth';

// The "what needs me today" layer of the Overview (item 5). Four panels
// fed by the keys 20260922220000 added to get_platform_dashboard_stats():
//
//   Onboarding funnel  -- where every non-internal company sits on the
//                         path created -> ... -> live, as a bar strip.
//   Stalled in setup   -- stuck at one setup stage for 7+ days, with the
//                         concrete next step and how long it has waited.
//   Going quiet        -- was live, nothing for 30+ days: retention.
//   Module usage       -- enabled vs actually touched in the last 30
//                         days, with trend vs the previous 30. Modules
//                         that are on for many but used by few are
//                         called out: that is churn before it happens.
//
// All optional: an older RPC that lacks the keys renders nothing here
// rather than breaking the page.

interface Props {
  funnel?: FunnelRow[] | null;
  stalled?: StalledRow[] | null;
  quiet?: QuietRow[] | null;
  moduleUsage?: ModuleUsageRow[] | null;
  trials?: TrialRow[] | null;
  onViewAs?: (tenant: { id: string; name: string }) => void;
  viewAsDisabledReason?: string | null;
}

const FUNNEL_COLORS = ['#DCE8EA', '#B7CDD1', '#8FB0B6', '#4C818B', '#2E6B76', '#C4872B', '#123B44'];

export default function PlatformHealthSection({ funnel, stalled, quiet, moduleUsage, trials, onViewAs, viewAsDisabledReason }: Props) {
  const hasData = !!(funnel || stalled || quiet || moduleUsage);
  const f = useMemo(() => normaliseFunnel(funnel), [funnel]);
  const summary = useMemo(() => funnelSummary(f), [f]);
  const stalledRows = useMemo(() => sortStalled(stalled ?? []), [stalled]);
  const quietRows = quiet ?? [];
  const usage = moduleUsage ?? [];
  const underused = useMemo(() => underusedModules(usage), [usage]);
  const trialRows = trials ?? [];

  if (!hasData) return null;

  const maxCount = Math.max(1, ...f.map((r) => r.count));

  return (
    <Box sx={{ mb: 3 }} data-testid="platform-health">
      {/* Funnel */}
      <Paper variant="outlined" sx={{ p: 2, borderRadius: 2, mb: 2 }}>
        <Stack direction="row" justifyContent="space-between" alignItems="baseline" flexWrap="wrap" gap={1} sx={{ mb: 1.5 }}>
          <Box>
            <Typography variant="subtitle2">Onboarding funnel</Typography>
            <Typography variant="caption" color="text.secondary">
              Every customer company by the furthest step it has completed in order. Internal tenant excluded.
            </Typography>
          </Box>
          <Stack direction="row" spacing={1}>
            <Chip size="small" label={`${summary.inSetup} in setup`} variant="outlined" />
            <Chip size="small" label={`${summary.notLive} used, not live`} sx={{ bgcolor: '#F6E7CE', color: '#8F5D14' }} />
            <Chip size="small" label={`${summary.live} live`} sx={{ bgcolor: '#123B44', color: '#fff' }} />
          </Stack>
        </Stack>
        <Box sx={{ display: 'grid', gridTemplateColumns: `repeat(${f.length}, 1fr)`, gap: 1, alignItems: 'end' }}>
          {f.map((r, i) => (
            <Tooltip key={r.stage_key} title={STAGE_HINTS[r.stage_key]}>
              <Box component={RouterLink} to={`/admin/companies?stage=${r.stage_key}`} sx={{ textDecoration: 'none', color: 'inherit', display: 'block' }}>
                <Box sx={{ height: 72, display: 'flex', alignItems: 'flex-end' }}>
                  <Box
                    sx={{
                      width: '100%',
                      height: `${Math.max(6, (r.count / maxCount) * 100)}%`,
                      bgcolor: FUNNEL_COLORS[i],
                      borderRadius: 1,
                      transition: 'height .2s',
                    }}
                  />
                </Box>
                <Typography variant="h6" sx={{ lineHeight: 1.2, mt: 0.5 }}>
                  {r.count}
                </Typography>
                <Typography variant="caption" color="text.secondary" sx={{ display: 'block', lineHeight: 1.2 }}>
                  {STAGE_LABELS[r.stage_key]}
                </Typography>
              </Box>
            </Tooltip>
          ))}
        </Box>
      </Paper>

      <Box sx={{ display: 'grid', gridTemplateColumns: { xs: '1fr', lg: '1fr 1fr' }, gap: 2, mb: 2 }}>
        {/* Stalled */}
        <Paper variant="outlined" sx={{ p: 2, borderRadius: 2 }}>
          <Stack direction="row" justifyContent="space-between" alignItems="baseline" sx={{ mb: 1 }}>
            <Typography variant="subtitle2">Stalled in setup</Typography>
            <Typography variant="caption" color="text.secondary">
              Same step for 7+ days
            </Typography>
          </Stack>
          {stalledRows.length === 0 ? (
            <Typography variant="body2" color="text.secondary" sx={{ py: 2 }}>
              Nothing stuck — every company in setup moved in the last week.
            </Typography>
          ) : (
            <Table size="small">
              <TableHead>
                <TableRow>
                  <TableCell>Company</TableCell>
                  <TableCell>Next step</TableCell>
                  <TableCell align="right">Waiting</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {stalledRows.slice(0, 8).map((r) => (
                  <TableRow key={r.id} hover>
                    <TableCell>
                      <Link component={RouterLink} to={`/admin/companies/${r.id}`} underline="hover">
                        {r.name}
                      </Link>
                      <Typography variant="caption" color="text.secondary" display="block">
                        {STAGE_LABELS[r.stage_key]}
                        {r.contact_email ? ` · ${r.contact_email}` : ''}
                      </Typography>
                    </TableCell>
                    <TableCell>
                      <Typography variant="body2">{r.next_step ?? '—'}</Typography>
                    </TableCell>
                    <TableCell align="right">
                      <Chip size="small" label={`${r.days_in_stage}d`} color={r.days_in_stage >= 21 ? 'error' : 'warning'} variant="outlined" />
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
          {stalledRows.length > 8 && (
            <Button size="small" component={RouterLink} to="/admin/companies?flag=stalled" sx={{ mt: 1 }}>
              All {stalledRows.length} stalled
            </Button>
          )}
        </Paper>

        {/* Quiet */}
        <Paper variant="outlined" sx={{ p: 2, borderRadius: 2 }}>
          <Stack direction="row" justifyContent="space-between" alignItems="baseline" sx={{ mb: 1 }}>
            <Typography variant="subtitle2">Going quiet</Typography>
            <Typography variant="caption" color="text.secondary">
              Was in use; nothing for 30+ days
            </Typography>
          </Stack>
          {quietRows.length === 0 ? (
            <Typography variant="body2" color="text.secondary" sx={{ py: 2 }}>
              No active customer has gone quiet.
            </Typography>
          ) : (
            <Table size="small">
              <TableHead>
                <TableRow>
                  <TableCell>Company</TableCell>
                  <TableCell>Plan</TableCell>
                  <TableCell align="right">Quiet for</TableCell>
                  <TableCell align="right" />
                </TableRow>
              </TableHead>
              <TableBody>
                {quietRows.slice(0, 8).map((r) => (
                  <TableRow key={r.id} hover>
                    <TableCell>
                      <Link component={RouterLink} to={`/admin/companies/${r.id}`} underline="hover">
                        {r.name}
                      </Link>
                      <Typography variant="caption" color="text.secondary" display="block">
                        {r.member_count} member{r.member_count === 1 ? '' : 's'}
                        {r.contact_email ? ` · ${r.contact_email}` : ''}
                      </Typography>
                    </TableCell>
                    <TableCell>
                      <Chip size="small" label={r.plan} variant="outlined" />
                    </TableCell>
                    <TableCell align="right">
                      <Chip size="small" label={`${r.days_quiet}d`} color={r.days_quiet >= 60 ? 'error' : 'warning'} variant="outlined" />
                    </TableCell>
                    <TableCell align="right">
                      {onViewAs && (
                        <Tooltip title={viewAsDisabledReason ?? 'See what they last did'}>
                          <span>
                            <Button size="small" disabled={!!viewAsDisabledReason} onClick={() => onViewAs({ id: r.id, name: r.name })}>
                              View as
                            </Button>
                          </span>
                        </Tooltip>
                      )}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
          {quietRows.length > 8 && (
            <Button size="small" component={RouterLink} to="/admin/companies?flag=quiet" sx={{ mt: 1 }}>
              All {quietRows.length} quiet
            </Button>
          )}
        </Paper>
      </Box>

      <Box sx={{ display: 'grid', gridTemplateColumns: { xs: '1fr', lg: trialRows.length ? '1.4fr 0.6fr' : '1fr' }, gap: 2 }}>
        {/* Module usage */}
        <Paper variant="outlined" sx={{ p: 2, borderRadius: 2 }}>
          <Stack direction="row" justifyContent="space-between" alignItems="baseline" flexWrap="wrap" gap={1} sx={{ mb: 1 }}>
            <Box>
              <Typography variant="subtitle2">Module usage — last 30 days</Typography>
              <Typography variant="caption" color="text.secondary">
                Enabled = switched on for the company. Active = at least one record created in the window.
              </Typography>
            </Box>
            {underused.length > 0 && (
              <Tooltip title="Switched on for several companies but used by fewer than half of them in the last 30 days. Worth a training nudge before renewal.">
                <Chip size="small" color="warning" variant="outlined" label={`Under-used: ${underused.map((u) => MODULE_LABEL[u.module] ?? u.module).join(', ')}`} />
              </Tooltip>
            )}
          </Stack>
          {usage.length === 0 ? (
            <Typography variant="body2" color="text.secondary" sx={{ py: 2 }}>
              No usage data yet.
            </Typography>
          ) : (
            <Table size="small">
              <TableHead>
                <TableRow>
                  <TableCell>Module</TableCell>
                  <TableCell align="right">Enabled</TableCell>
                  <TableCell align="right">Active</TableCell>
                  <TableCell sx={{ width: '30%' }}>Adoption</TableCell>
                  <TableCell align="right">Records</TableCell>
                  <TableCell>Trend</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {usage.map((m) => {
                  const pct = m.tenants_enabled > 0 ? Math.round((m.tenants_active_30d / m.tenants_enabled) * 100) : 0;
                  const t = trendOf(m.events_30d, m.events_prev_30d);
                  const color = t === 'up' || t === 'new' ? 'success.main' : t === 'down' ? 'error.main' : 'text.secondary';
                  return (
                    <TableRow key={m.module} hover>
                      <TableCell>{MODULE_LABEL[m.module] ?? m.module}</TableCell>
                      <TableCell align="right">{m.tenants_enabled}</TableCell>
                      <TableCell align="right">{m.tenants_active_30d}</TableCell>
                      <TableCell>
                        <Stack direction="row" alignItems="center" spacing={1}>
                          <Box sx={{ flex: 1, bgcolor: 'action.hover', borderRadius: 1, height: 6 }}>
                            <Box sx={{ width: `${pct}%`, bgcolor: pct >= 50 ? '#1B5560' : '#C4872B', borderRadius: 1, height: 6 }} />
                          </Box>
                          <Typography variant="caption" color="text.secondary" sx={{ minWidth: 32, textAlign: 'right' }}>
                            {m.tenants_enabled > 0 ? `${pct}%` : '—'}
                          </Typography>
                        </Stack>
                      </TableCell>
                      <TableCell align="right">{m.events_30d.toLocaleString()}</TableCell>
                      <TableCell>
                        <Typography variant="caption" sx={{ color }}>
                          {trendLabel(m.events_30d, m.events_prev_30d)}
                        </Typography>
                      </TableCell>
                    </TableRow>
                  );
                })}
              </TableBody>
            </Table>
          )}
        </Paper>

        {/* Trials */}
        {trialRows.length > 0 && (
          <Paper variant="outlined" sx={{ p: 2, borderRadius: 2 }}>
            <Stack direction="row" justifyContent="space-between" alignItems="baseline" sx={{ mb: 1 }}>
              <Typography variant="subtitle2">Trials ending</Typography>
              <Typography variant="caption" color="text.secondary">
                Next 14 days
              </Typography>
            </Stack>
            <Table size="small">
              <TableBody>
                {trialRows.slice(0, 8).map((r) => (
                  <TableRow key={r.id} hover>
                    <TableCell>
                      <Link component={RouterLink} to={`/admin/companies/${r.id}`} underline="hover">
                        {r.name}
                      </Link>
                      <Typography variant="caption" color="text.secondary" display="block">
                        {STAGE_LABELS[r.stage_key]} · {r.member_count} member{r.member_count === 1 ? '' : 's'}
                      </Typography>
                    </TableCell>
                    <TableCell align="right">
                      <Chip size="small" label={r.days_left === 0 ? 'today' : `${r.days_left}d`} color={r.days_left <= 3 ? 'error' : 'warning'} variant="outlined" />
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </Paper>
        )}
      </Box>
    </Box>
  );
}
