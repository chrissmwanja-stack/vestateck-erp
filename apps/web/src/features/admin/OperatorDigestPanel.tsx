import { useCallback, useEffect, useState } from 'react';
import {
  Alert,
  Box,
  Button,
  Chip,
  CircularProgress,
  Collapse,
  Divider,
  Link,
  List,
  ListItem,
  ListItemText,
  Paper,
  Stack,
  Tooltip,
  Typography,
} from '@mui/material';
import { Link as RouterLink } from 'react-router-dom';
import { supabase } from '../../lib/supabaseClient';
import { STAGE_LABELS, type StageKey } from './platformHealth';
import { friendlyPlatformError } from './usePlatformAdminSession';
import { deliveryLabel, digestSections, digestSummary, periodLabel, type DigestPayload, type DigestRow } from './operatorDigest';

// The daily operator digest: what changed and what needs a human, across
// every company, generated at 07:00 Kampala by pg_cron and dropped on
// each platform admin as an in-app notification (plus email when
// recipients are configured). This panel shows the history and lets the
// operator generate one on demand.

function CompanyLine({ id, name, secondary }: { id: string; name: string; secondary: string }) {
  return (
    <ListItem disableGutters dense>
      <ListItemText
        primary={
          <Link component={RouterLink} to={`/admin/companies/${id}`} underline="hover">
            {name}
          </Link>
        }
        secondary={secondary}
      />
    </ListItem>
  );
}

function DigestBody({ p }: { p: DigestPayload }) {
  const sections = digestSections(p);
  return (
    <Box sx={{ pt: 1 }}>
      <Stack direction="row" spacing={1} flexWrap="wrap" useFlexGap sx={{ mb: 1.5 }}>
        <Chip size="small" variant="outlined" label={`${p.totals.companies} companies`} />
        <Chip size="small" variant="outlined" label={`${p.totals.live} live`} />
        <Chip size="small" variant="outlined" label={`${p.totals.users} users`} />
        {p.new_companies?.length > 0 && <Chip size="small" color="primary" label={`+${p.new_companies.length} new compan${p.new_companies.length === 1 ? 'y' : 'ies'}`} />}
        {p.new_users > 0 && <Chip size="small" color="primary" variant="outlined" label={`+${p.new_users} new users`} />}
      </Stack>

      {p.new_companies?.length > 0 && (
        <Box sx={{ mb: 1 }}>
          <Typography variant="caption" color="text.secondary">
            New companies
          </Typography>
          <List dense disablePadding>
            {p.new_companies.map((c) => (
              <CompanyLine key={c.id} id={c.id} name={c.name} secondary={`${c.plan} · ${c.status} · ${new Date(c.created_at).toLocaleString()}`} />
            ))}
          </List>
        </Box>
      )}

      {sections.length === 0 ? (
        <Alert severity="success" variant="outlined">
          All clear — nothing needed attention in this period.
        </Alert>
      ) : (
        sections.map((s) => (
          <Box key={s.key} sx={{ mb: 1 }} data-testid={`digest-section-${s.key}`}>
            <Typography variant="caption" sx={{ color: `${s.severity}.main`, fontWeight: 600 }}>
              {s.label} ({s.count})
            </Typography>
            <List dense disablePadding>
              {s.key === 'trials_ending' &&
                p.trials_ending.map((c) => (
                  <CompanyLine key={c.id} id={c.id} name={c.name} secondary={`${c.days_left === 0 ? 'ends today' : `${c.days_left} day(s) left`} · ${STAGE_LABELS[c.stage_key as StageKey] ?? c.stage_key}${c.contact_email ? ` · ${c.contact_email}` : ''}`} />
                ))}
              {s.key === 'stalled' &&
                p.stalled.map((c) => (
                  <CompanyLine key={c.id} id={c.id} name={c.name} secondary={`${c.days_in_stage}d at "${STAGE_LABELS[c.stage_key as StageKey] ?? c.stage_key}" — ${c.next_step ?? ''}`} />
                ))}
              {s.key === 'pending_over_threshold' &&
                p.pending_over_threshold.map((c) => (
                  <CompanyLine key={c.id} id={c.id} name={c.name} secondary={`pending for ${c.days_pending} day(s) · ${STAGE_LABELS[c.stage_key as StageKey] ?? c.stage_key}`} />
                ))}
              {s.key === 'quiet' &&
                p.quiet.map((c) => (
                  <CompanyLine key={c.id} id={c.id} name={c.name} secondary={`${c.plan} · quiet for ${c.days_quiet} day(s)${c.contact_email ? ` · ${c.contact_email}` : ''}`} />
                ))}
              {s.key === 'admins_without_mfa' &&
                p.admins_without_mfa.map((email) => (
                  <ListItem key={email} disableGutters dense>
                    <ListItemText
                      primary={email}
                      secondary={
                        <Link component={RouterLink} to="/admin/team" underline="hover">
                          Platform team
                        </Link>
                      }
                    />
                  </ListItem>
                ))}
              {s.key === 'open_impersonations' &&
                p.open_impersonations.map((s2, i) => (
                  <ListItem key={i} disableGutters dense>
                    <ListItemText primary={`${s2.admin_email ?? 'unknown'} → ${s2.tenant_name}`} secondary={`since ${new Date(s2.started_at).toLocaleString()}${s2.reason ? ` · ${s2.reason}` : ''}`} />
                  </ListItem>
                ))}
            </List>
          </Box>
        ))
      )}
    </Box>
  );
}

export default function OperatorDigestPanel({ canAct, blockedReason }: { canAct: boolean; blockedReason?: string | null }) {
  const [rows, setRows] = useState<DigestRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [running, setRunning] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [open, setOpen] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    const { data, error: e } = await supabase.rpc('list_platform_digests', { p_limit: 14 });
    if (e) setError(friendlyPlatformError(e.message));
    else {
      const list = (data ?? []) as unknown as DigestRow[];
      setRows(list);
      setOpen((prev) => prev ?? list[0]?.id ?? null);
    }
    setLoading(false);
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  const runNow = async () => {
    setRunning(true);
    setError(null);
    const { data, error: e } = await supabase.rpc('run_operator_digest_now');
    if (e) setError(friendlyPlatformError(e.message));
    else {
      const row = data as unknown as DigestRow;
      setRows((prev) => [row, ...prev]);
      setOpen(row.id);
    }
    setRunning(false);
  };

  return (
    <Paper variant="outlined" sx={{ p: 2, borderRadius: 2 }} data-testid="operator-digest">
      <Stack direction="row" justifyContent="space-between" alignItems="flex-start" flexWrap="wrap" gap={1} sx={{ mb: 1 }}>
        <Box>
          <Typography variant="subtitle2">Daily operator digest</Typography>
          <Typography variant="caption" color="text.secondary">
            Runs every day at 07:00 (Kampala). Arrives as an in-app notification for every platform admin, and by email to the
            alert recipients above.
          </Typography>
        </Box>
        <Tooltip title={blockedReason ?? 'Build a digest for the period since the last one'}>
          <span>
            <Button size="small" variant="outlined" onClick={runNow} disabled={!canAct || running}>
              {running ? 'Generating…' : 'Generate now'}
            </Button>
          </span>
        </Tooltip>
      </Stack>

      {error && (
        <Alert severity="error" sx={{ mb: 1 }} onClose={() => setError(null)}>
          {error}
        </Alert>
      )}

      {loading ? (
        <Box display="flex" justifyContent="center" py={3}>
          <CircularProgress size={22} />
        </Box>
      ) : rows.length === 0 ? (
        <Typography variant="body2" color="text.secondary" sx={{ py: 2 }}>
          No digest has run yet. The first scheduled one arrives tomorrow morning, or generate one now.
        </Typography>
      ) : (
        <List dense disablePadding>
          {rows.map((r, i) => {
            const d = deliveryLabel(r);
            const expanded = open === r.id;
            return (
              <Box key={r.id}>
                {i > 0 && <Divider />}
                <ListItem
                  disableGutters
                  component="div"
                  onClick={() => setOpen(expanded ? null : r.id)}
                  sx={{ cursor: 'pointer', alignItems: 'flex-start', flexWrap: 'wrap' }}
                  data-testid={`digest-row-${r.id}`}
                >
                  <ListItemText
                    primary={
                      <Stack direction="row" spacing={1} alignItems="center" flexWrap="wrap" useFlexGap>
                        <Typography variant="body2" sx={{ fontWeight: 600 }}>
                          {new Date(r.generated_at).toLocaleString()}
                        </Typography>
                        <Chip size="small" variant="outlined" label={periodLabel(r)} />
                        {r.trigger === 'manual' && <Chip size="small" label="manual" />}
                        <Chip size="small" color={r.attention_count > 0 ? 'warning' : 'success'} label={r.attention_count > 0 ? `${r.attention_count} need attention` : 'all clear'} />
                        <Chip size="small" variant="outlined" color={d.color} label={d.label} />
                      </Stack>
                    }
                    secondary={digestSummary(r.payload)}
                  />
                </ListItem>
                <Collapse in={expanded} unmountOnExit>
                  <DigestBody p={r.payload} />
                </Collapse>
              </Box>
            );
          })}
        </List>
      )}
    </Paper>
  );
}
