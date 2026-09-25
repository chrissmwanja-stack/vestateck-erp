import { Fragment, useCallback, useEffect, useMemo, useState } from 'react';
import {
  Alert,
  Box,
  Button,
  Chip,
  CircularProgress,
  Collapse,
  IconButton,
  MenuItem,
  Paper,
  Stack,
  Tab,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TablePagination,
  TableRow,
  Tabs,
  TextField,
  Tooltip,
  Typography,
} from '@mui/material';
import { ExpandLess, ExpandMore, Refresh, VerifiedUser, Download } from '@mui/icons-material';
import { Link as RouterLink } from 'react-router-dom';
import { supabase } from '../../lib/supabaseClient';
import type { Json } from '@erp-platform/shared';

// /admin/audit -- every privileged platform action, plus impersonation
// history. Reads two platform-admin-gated RPCs added in
// 20260922160000_platform_audit_and_impersonation_hardening.sql; both
// return total_count on every row so paging is server-side.

interface AuditRow {
  id: string;
  created_at: string;
  actor_id: string | null;
  actor_email: string | null;
  tenant_id: string | null;
  tenant_name: string | null;
  action: string;
  target_type: string | null;
  target_id: string | null;
  reason: string | null;
  before: Json | null;
  after: Json | null;
  mfa_verified: boolean;
  total_count: number;
}

interface ImpersonationRow {
  id: string;
  platform_admin_id: string;
  platform_admin_email: string | null;
  tenant_id: string;
  tenant_name: string;
  reason: string | null;
  started_at: string;
  ended_at: string | null;
  expires_at: string | null;
  is_active: boolean;
  total_count: number;
}

interface TenantOption {
  id: string;
  name: string;
}

const ACTION_FILTERS: { value: string; label: string }[] = [
  { value: '', label: 'All actions' },
  { value: 'tenant.%', label: 'Company status & modules' },
  { value: 'tenant.suspend', label: '— Suspensions only' },
  { value: 'impersonation.%', label: 'Impersonation' },
  { value: 'workflow.%', label: 'Workflow thresholds' },
  { value: 'invitation.%', label: 'Invitations' },
  { value: 'platform_settings.%', label: 'Platform settings' },
];

const ACTION_COLOR: Record<string, 'default' | 'warning' | 'success' | 'info' | 'error'> = {
  'tenant.suspend': 'error',
  'tenant.activate': 'success',
  'tenant.modules.set': 'info',
  'impersonation.start': 'warning',
  'impersonation.end': 'default',
  'workflow.threshold.update': 'info',
  'workflow.approver_role.update': 'info',
  'invitation.revoke': 'warning',
  'platform_settings.update': 'info',
};

const fmt = (iso: string | null | undefined) => (iso ? new Date(iso).toLocaleString() : '—');

function JsonBlock({ label, value }: { label: string; value: Json | null }) {
  if (value === null || value === undefined) return null;
  return (
    <Box sx={{ flex: '1 1 280px', minWidth: 0 }}>
      <Typography variant="caption" color="text.secondary" sx={{ textTransform: 'uppercase', letterSpacing: 0.6 }}>
        {label}
      </Typography>
      <Box
        component="pre"
        sx={{
          m: 0,
          mt: 0.5,
          p: 1,
          bgcolor: 'action.hover',
          borderRadius: 1,
          fontSize: 12,
          overflowX: 'auto',
          whiteSpace: 'pre-wrap',
          wordBreak: 'break-word',
        }}
      >
        {JSON.stringify(value, null, 2)}
      </Box>
    </Box>
  );
}

function toCsv(rows: Record<string, unknown>[], columns: string[]): string {
  const esc = (v: unknown) => {
    const s = v === null || v === undefined ? '' : typeof v === 'object' ? JSON.stringify(v) : String(v);
    return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  return [columns.join(','), ...rows.map((r) => columns.map((c) => esc(r[c])).join(','))].join('\n');
}

function download(filename: string, text: string) {
  const blob = new Blob([text], { type: 'text/csv;charset=utf-8' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
}

// ---------------------------------------------------------------------
// Tab 1: platform actions
// ---------------------------------------------------------------------
function ActionsTab({ tenants }: { tenants: TenantOption[] }) {
  const [rows, setRows] = useState<AuditRow[]>([]);
  const [total, setTotal] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [expanded, setExpanded] = useState<string | null>(null);

  const [tenantId, setTenantId] = useState('');
  const [action, setAction] = useState('');
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const [page, setPage] = useState(0);
  const [rowsPerPage, setRowsPerPage] = useState(50);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const { data, error: err } = await supabase.rpc('list_platform_audit_events', {
      p_tenant_id: tenantId || undefined,
      p_action: action || undefined,
      p_from: from ? new Date(from).toISOString() : undefined,
      // "to" is a date input; include the whole day.
      p_to: to ? new Date(new Date(to).getTime() + 24 * 60 * 60 * 1000).toISOString() : undefined,
      p_limit: rowsPerPage,
      p_offset: page * rowsPerPage,
    });
    if (err) {
      setError(err.message);
      setRows([]);
      setTotal(0);
    } else {
      const list = (data ?? []) as AuditRow[];
      setRows(list);
      setTotal(list[0]?.total_count ?? 0);
    }
    setLoading(false);
  }, [tenantId, action, from, to, page, rowsPerPage]);

  useEffect(() => {
    load();
  }, [load]);

  const exportCsv = () => {
    download(
      `platform-audit-${new Date().toISOString().slice(0, 10)}.csv`,
      toCsv(rows as unknown as Record<string, unknown>[], [
        'created_at',
        'actor_email',
        'action',
        'tenant_name',
        'target_type',
        'target_id',
        'reason',
        'mfa_verified',
        'before',
        'after',
      ])
    );
  };

  return (
    <Box>
      <Stack direction={{ xs: 'column', md: 'row' }} spacing={1.5} sx={{ mb: 2 }} alignItems={{ md: 'center' }}>
        <TextField
          select
          size="small"
          label="Company"
          value={tenantId}
          onChange={(e) => {
            setTenantId(e.target.value);
            setPage(0);
          }}
          sx={{ minWidth: 220 }}
        >
          <MenuItem value="">All companies</MenuItem>
          {tenants.map((t) => (
            <MenuItem key={t.id} value={t.id}>
              {t.name}
            </MenuItem>
          ))}
        </TextField>
        <TextField
          select
          size="small"
          label="Action"
          value={action}
          onChange={(e) => {
            setAction(e.target.value);
            setPage(0);
          }}
          sx={{ minWidth: 220 }}
        >
          {ACTION_FILTERS.map((a) => (
            <MenuItem key={a.value} value={a.value}>
              {a.label}
            </MenuItem>
          ))}
        </TextField>
        <TextField
          size="small"
          type="date"
          label="From"
          value={from}
          onChange={(e) => {
            setFrom(e.target.value);
            setPage(0);
          }}
          InputLabelProps={{ shrink: true }}
        />
        <TextField
          size="small"
          type="date"
          label="To"
          value={to}
          onChange={(e) => {
            setTo(e.target.value);
            setPage(0);
          }}
          InputLabelProps={{ shrink: true }}
        />
        <Box sx={{ flex: 1 }} />
        <Tooltip title="Refresh">
          <IconButton aria-label="Refresh" onClick={load} size="small">
            <Refresh fontSize="small" />
          </IconButton>
        </Tooltip>
        <Button size="small" startIcon={<Download />} onClick={exportCsv} disabled={rows.length === 0}>
          Export page (CSV)
        </Button>
      </Stack>

      {error && (
        <Alert severity="error" sx={{ mb: 2 }}>
          {error}
        </Alert>
      )}

      <Paper variant="outlined">
        <TableContainer>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell width={36} />
                <TableCell>When</TableCell>
                <TableCell>Who</TableCell>
                <TableCell>Action</TableCell>
                <TableCell>Company</TableCell>
                <TableCell>Reason</TableCell>
                <TableCell align="center">MFA</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {loading ? (
                <TableRow>
                  <TableCell colSpan={7} align="center" sx={{ py: 4 }}>
                    <CircularProgress size={22} />
                  </TableCell>
                </TableRow>
              ) : rows.length === 0 ? (
                <TableRow>
                  <TableCell colSpan={7} align="center" sx={{ py: 4, color: 'text.secondary' }}>
                    No platform actions recorded for this filter.
                  </TableCell>
                </TableRow>
              ) : (
                rows.map((r) => {
                  const open = expanded === r.id;
                  const hasDetail = r.before !== null || r.after !== null || r.target_id;
                  return (
                    <Fragment key={r.id}>
                      <TableRow hover sx={{ '& > td': { borderBottom: open ? 'none' : undefined } }}>
                        <TableCell>
                          {hasDetail && (
                            <IconButton
                              size="small"
                              aria-label={open ? 'Hide details' : 'Show details'}
                              onClick={() => setExpanded(open ? null : r.id)}
                            >
                              {open ? <ExpandLess fontSize="small" /> : <ExpandMore fontSize="small" />}
                            </IconButton>
                          )}
                        </TableCell>
                        <TableCell sx={{ whiteSpace: 'nowrap' }}>{fmt(r.created_at)}</TableCell>
                        <TableCell>{r.actor_email ?? (r.actor_id ? r.actor_id.slice(0, 8) : 'system')}</TableCell>
                        <TableCell>
                          <Chip size="small" label={r.action} color={ACTION_COLOR[r.action] ?? 'default'} variant="outlined" />
                        </TableCell>
                        <TableCell>
                          {r.tenant_id ? (
                            <Typography
                              component={RouterLink}
                              to={`/admin/companies/${r.tenant_id}`}
                              variant="body2"
                              sx={{ textDecoration: 'none' }}
                            >
                              {r.tenant_name ?? r.tenant_id.slice(0, 8)}
                            </Typography>
                          ) : (
                            <Typography variant="body2" color="text.secondary">
                              Platform
                            </Typography>
                          )}
                        </TableCell>
                        <TableCell sx={{ maxWidth: 320 }}>
                          <Typography variant="body2" noWrap title={r.reason ?? ''}>
                            {r.reason ?? '—'}
                          </Typography>
                        </TableCell>
                        <TableCell align="center">
                          {r.mfa_verified ? (
                            <Tooltip title="Session verified with authenticator">
                              <VerifiedUser fontSize="small" color="success" />
                            </Tooltip>
                          ) : (
                            <Tooltip title="Password-only session">
                              <Typography variant="caption" color="text.secondary">
                                —
                              </Typography>
                            </Tooltip>
                          )}
                        </TableCell>
                      </TableRow>
                      {hasDetail && (
                        <TableRow>
                          <TableCell colSpan={7} sx={{ py: 0 }}>
                            <Collapse in={open} unmountOnExit>
                              <Box sx={{ py: 1.5, pl: 5 }}>
                                <Typography variant="caption" color="text.secondary">
                                  Target: {r.target_type ?? '—'} {r.target_id ? `· ${r.target_id}` : ''}
                                </Typography>
                                <Stack direction="row" spacing={2} flexWrap="wrap" sx={{ mt: 1 }}>
                                  <JsonBlock label="Before" value={r.before} />
                                  <JsonBlock label="After" value={r.after} />
                                </Stack>
                              </Box>
                            </Collapse>
                          </TableCell>
                        </TableRow>
                      )}
                    </Fragment>
                  );
                })
              )}
            </TableBody>
          </Table>
        </TableContainer>
        <TablePagination
          component="div"
          count={total}
          page={page}
          onPageChange={(_, p) => setPage(p)}
          rowsPerPage={rowsPerPage}
          onRowsPerPageChange={(e) => {
            setRowsPerPage(Number(e.target.value));
            setPage(0);
          }}
          rowsPerPageOptions={[25, 50, 100, 200]}
        />
      </Paper>
    </Box>
  );
}

// ---------------------------------------------------------------------
// Tab 2: impersonation sessions
// ---------------------------------------------------------------------
function ImpersonationTab({ tenants }: { tenants: TenantOption[] }) {
  const [rows, setRows] = useState<ImpersonationRow[]>([]);
  const [total, setTotal] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [tenantId, setTenantId] = useState('');
  const [page, setPage] = useState(0);
  const [rowsPerPage, setRowsPerPage] = useState(50);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const { data, error: err } = await supabase.rpc('list_impersonation_history', {
      p_tenant_id: tenantId || undefined,
      p_limit: rowsPerPage,
      p_offset: page * rowsPerPage,
    });
    if (err) {
      setError(err.message);
      setRows([]);
      setTotal(0);
    } else {
      const list = (data ?? []) as ImpersonationRow[];
      setRows(list);
      setTotal(list[0]?.total_count ?? 0);
    }
    setLoading(false);
  }, [tenantId, page, rowsPerPage]);

  useEffect(() => {
    load();
  }, [load]);

  const durationLabel = (r: ImpersonationRow) => {
    const end = r.ended_at ? Date.parse(r.ended_at) : r.is_active ? Date.now() : r.expires_at ? Date.parse(r.expires_at) : null;
    if (!end) return '—';
    const mins = Math.max(0, Math.round((end - Date.parse(r.started_at)) / 60_000));
    return mins >= 60 ? `${Math.floor(mins / 60)}h ${mins % 60}m` : `${mins}m`;
  };

  return (
    <Box>
      <Stack direction={{ xs: 'column', md: 'row' }} spacing={1.5} sx={{ mb: 2 }} alignItems={{ md: 'center' }}>
        <TextField
          select
          size="small"
          label="Company"
          value={tenantId}
          onChange={(e) => {
            setTenantId(e.target.value);
            setPage(0);
          }}
          sx={{ minWidth: 220 }}
        >
          <MenuItem value="">All companies</MenuItem>
          {tenants.map((t) => (
            <MenuItem key={t.id} value={t.id}>
              {t.name}
            </MenuItem>
          ))}
        </TextField>
        <Box sx={{ flex: 1 }} />
        <Tooltip title="Refresh">
          <IconButton aria-label="Refresh" onClick={load} size="small">
            <Refresh fontSize="small" />
          </IconButton>
        </Tooltip>
        <Button
          size="small"
          startIcon={<Download />}
          disabled={rows.length === 0}
          onClick={() =>
            download(
              `impersonation-history-${new Date().toISOString().slice(0, 10)}.csv`,
              toCsv(rows as unknown as Record<string, unknown>[], [
                'started_at',
                'ended_at',
                'expires_at',
                'platform_admin_email',
                'tenant_name',
                'reason',
              ])
            )
          }
        >
          Export page (CSV)
        </Button>
      </Stack>

      {error && (
        <Alert severity="error" sx={{ mb: 2 }}>
          {error}
        </Alert>
      )}

      <Paper variant="outlined">
        <TableContainer>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>Started</TableCell>
                <TableCell>Operator</TableCell>
                <TableCell>Company</TableCell>
                <TableCell>Reason</TableCell>
                <TableCell>Duration</TableCell>
                <TableCell>Status</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {loading ? (
                <TableRow>
                  <TableCell colSpan={6} align="center" sx={{ py: 4 }}>
                    <CircularProgress size={22} />
                  </TableCell>
                </TableRow>
              ) : rows.length === 0 ? (
                <TableRow>
                  <TableCell colSpan={6} align="center" sx={{ py: 4, color: 'text.secondary' }}>
                    No impersonation sessions recorded.
                  </TableCell>
                </TableRow>
              ) : (
                rows.map((r) => (
                  <TableRow key={r.id} hover>
                    <TableCell sx={{ whiteSpace: 'nowrap' }}>{fmt(r.started_at)}</TableCell>
                    <TableCell>{r.platform_admin_email ?? r.platform_admin_id.slice(0, 8)}</TableCell>
                    <TableCell>
                      <Typography
                        component={RouterLink}
                        to={`/admin/companies/${r.tenant_id}`}
                        variant="body2"
                        sx={{ textDecoration: 'none' }}
                      >
                        {r.tenant_name}
                      </Typography>
                    </TableCell>
                    <TableCell sx={{ maxWidth: 360 }}>
                      <Typography variant="body2" title={r.reason ?? ''}>
                        {r.reason ?? (
                          <Typography component="span" variant="caption" color="text.secondary">
                            (before reasons were required)
                          </Typography>
                        )}
                      </Typography>
                    </TableCell>
                    <TableCell>{durationLabel(r)}</TableCell>
                    <TableCell>
                      {r.is_active ? (
                        <Chip size="small" color="warning" label="Active" />
                      ) : r.ended_at ? (
                        <Chip size="small" variant="outlined" label="Ended" />
                      ) : (
                        <Chip size="small" variant="outlined" label="Expired" />
                      )}
                    </TableCell>
                  </TableRow>
                ))
              )}
            </TableBody>
          </Table>
        </TableContainer>
        <TablePagination
          component="div"
          count={total}
          page={page}
          onPageChange={(_, p) => setPage(p)}
          rowsPerPage={rowsPerPage}
          onRowsPerPageChange={(e) => {
            setRowsPerPage(Number(e.target.value));
            setPage(0);
          }}
          rowsPerPageOptions={[25, 50, 100, 200]}
        />
      </Paper>
    </Box>
  );
}

// ---------------------------------------------------------------------
export default function PlatformAuditLog() {
  const [tab, setTab] = useState(0);
  const [tenants, setTenants] = useState<TenantOption[]>([]);

  useEffect(() => {
    supabase
      .from('tenants')
      .select('id, name')
      .order('name')
      .then(({ data }) => setTenants((data ?? []) as TenantOption[]));
  }, []);

  const description = useMemo(
    () =>
      tab === 0
        ? 'Every privileged action taken from the platform console: company suspensions and reactivations, module changes, workflow threshold edits, invitation revokes and platform-setting saves. Rows are written server-side and cannot be edited or deleted.'
        : 'Every time a platform admin has stepped into a company as its users, with the reason given, how long the session lasted and whether it is still open.',
    [tab]
  );

  return (
    <Box sx={{ maxWidth: 1280 }}>
      <Typography variant="h4" gutterBottom>
        Audit log
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2, maxWidth: 760 }}>
        {description}
      </Typography>
      <Tabs value={tab} onChange={(_, v) => setTab(v)} sx={{ mb: 2, borderBottom: 1, borderColor: 'divider' }}>
        <Tab label="Platform actions" />
        <Tab label="Impersonation sessions" />
      </Tabs>
      {tab === 0 ? <ActionsTab tenants={tenants} /> : <ImpersonationTab tenants={tenants} />}
    </Box>
  );
}