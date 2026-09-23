import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Alert,
  Box,
  Button,
  Chip,
  CircularProgress,
  FormControl,
  FormControlLabel,
  InputAdornment,
  InputLabel,
  MenuItem,
  Paper,
  Select,
  Stack,
  Switch,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TablePagination,
  TableRow,
  TextField,
  Tooltip,
  Typography,
} from '@mui/material';
import { Download as DownloadIcon, Search as SearchIcon, VerifiedUser, Visibility } from '@mui/icons-material';
import { Link as RouterLink, useSearchParams } from 'react-router-dom';
import { supabase } from '../../lib/supabaseClient';
import ImpersonationReasonDialog from './ImpersonationReasonDialog';
import { describeBlockedReason, friendlyPlatformError, usePlatformAdminSession } from './usePlatformAdminSession';
import { downloadCsv } from './companiesList';
import {
  MODULE_KEYS,
  MODULE_LABELS,
  USER_KIND_LABELS,
  lastSeenLabel,
  parseModules,
  summariseAccess,
  usersToCsv,
  type DirectoryUser,
  type UserKind,
} from './usersDirectory';

// /admin/users -- every person on the platform, across every company.
//
// Answers the support questions the per-company screens cannot: "who is
// this email?", "which company admins still have no authenticator?",
// "who hasn't signed in for 60 days?", "who holds HR admin anywhere?".
// Data comes from platform_users_directory() (SECURITY DEFINER; refuses
// non-operators) so nothing here depends on app_users RLS.
//
// The row action is "View as" -- a user-level impersonation session: the
// operator sees that company exactly as this person does (their modules,
// roles, finance/approval rights), which is how "why can't I see X?"
// tickets get reproduced instead of guessed at.

interface TenantOption {
  id: string;
  name: string;
}

const QUIET_DAYS = 60;

export default function PlatformUsersDirectory() {
  const [searchParams, setSearchParams] = useSearchParams();
  const { session: adminSession } = usePlatformAdminSession();
  const blockedReason = describeBlockedReason(adminSession);

  const [rows, setRows] = useState<DirectoryUser[]>([]);
  const [total, setTotal] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [tenants, setTenants] = useState<TenantOption[]>([]);

  const [search, setSearch] = useState(searchParams.get('q') ?? '');
  const [debounced, setDebounced] = useState(search);
  const [tenantId, setTenantId] = useState(searchParams.get('tenant') ?? '');
  const [kind, setKind] = useState<UserKind>((searchParams.get('kind') as UserKind) ?? '');
  const [moduleKey, setModuleKey] = useState(searchParams.get('module') ?? '');
  const [quietOnly, setQuietOnly] = useState(searchParams.get('quiet') === '1');
  const [page, setPage] = useState(0);
  const [rowsPerPage, setRowsPerPage] = useState(50);

  const [impersonateTarget, setImpersonateTarget] = useState<DirectoryUser | null>(null);

  useEffect(() => {
    const id = window.setTimeout(() => setDebounced(search), 300);
    return () => window.clearTimeout(id);
  }, [search]);

  useEffect(() => {
    supabase
      .from('tenants')
      .select('id, name')
      .order('name')
      .then(({ data }) => setTenants((data ?? []) as TenantOption[]));
  }, []);

  // Keep the URL in step so a filtered view can be shared / bookmarked
  // (e.g. from Company Detail: /admin/users?tenant=<id>).
  useEffect(() => {
    const next = new URLSearchParams();
    if (debounced) next.set('q', debounced);
    if (tenantId) next.set('tenant', tenantId);
    if (kind) next.set('kind', kind);
    if (moduleKey) next.set('module', moduleKey);
    if (quietOnly) next.set('quiet', '1');
    setSearchParams(next, { replace: true });
  }, [debounced, tenantId, kind, moduleKey, quietOnly, setSearchParams]);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const { data, error: err } = await supabase.rpc('platform_users_directory', {
      p_search: debounced || null,
      p_tenant_id: tenantId || null,
      p_kind: kind || null,
      p_module: moduleKey || null,
      p_quiet_days: quietOnly ? QUIET_DAYS : null,
      p_limit: rowsPerPage,
      p_offset: page * rowsPerPage,
    });
    setLoading(false);
    if (err) {
      setError(friendlyPlatformError(err.message));
      setRows([]);
      setTotal(0);
      return;
    }
    const list = (data ?? []) as DirectoryUser[];
    setRows(list);
    setTotal(list[0]?.total_count ?? 0);
  }, [debounced, tenantId, kind, moduleKey, quietOnly, page, rowsPerPage]);

  useEffect(() => {
    load();
  }, [load]);

  useEffect(() => {
    setPage(0);
  }, [debounced, tenantId, kind, moduleKey, quietOnly]);

  const now = useMemo(() => Date.now(), [rows]); // eslint-disable-line react-hooks/exhaustive-deps

  const clearFilters = () => {
    setSearch('');
    setTenantId('');
    setKind('');
    setModuleKey('');
    setQuietOnly(false);
  };
  const anyFilter = !!(debounced || tenantId || kind || moduleKey || quietOnly);

  return (
    <Box sx={{ maxWidth: 1400 }}>
      <Stack direction="row" alignItems="flex-start" justifyContent="space-between" flexWrap="wrap" gap={2} mb={2}>
        <Box>
          <Typography variant="h4" gutterBottom>
            Users
          </Typography>
          <Typography variant="body2" color="text.secondary" sx={{ maxWidth: 760 }}>
            Everyone with an account, across every company. Search by name, email or company; narrow by
            role or module; or show only people who have gone quiet. &ldquo;View as&rdquo; opens the company
            exactly as that person sees it.
          </Typography>
        </Box>
        <Button
          variant="outlined"
          startIcon={<DownloadIcon />}
          disabled={rows.length === 0}
          onClick={() => downloadCsv(`users-${new Date().toISOString().slice(0, 10)}.csv`, usersToCsv(rows))}
        >
          Export page (CSV)
        </Button>
      </Stack>

      {blockedReason && (
        <Alert severity="warning" sx={{ mb: 2 }}>
          {blockedReason}
        </Alert>
      )}
      {error && (
        <Alert severity="error" sx={{ mb: 2 }} onClose={() => setError(null)}>
          {error}
        </Alert>
      )}

      <Paper variant="outlined" sx={{ p: 2, mb: 2 }}>
        <Stack direction="row" flexWrap="wrap" gap={2} alignItems="center">
          <TextField
            size="small"
            placeholder="Name, email or company"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            sx={{ minWidth: 280, flex: '1 1 280px' }}
            InputProps={{
              startAdornment: (
                <InputAdornment position="start">
                  <SearchIcon fontSize="small" />
                </InputAdornment>
              ),
            }}
          />
          <FormControl size="small" sx={{ minWidth: 220 }}>
            <InputLabel>Company</InputLabel>
            <Select label="Company" value={tenantId} onChange={(e) => setTenantId(e.target.value)}>
              <MenuItem value="">All companies</MenuItem>
              {tenants.map((t) => (
                <MenuItem key={t.id} value={t.id}>
                  {t.name}
                </MenuItem>
              ))}
            </Select>
          </FormControl>
          <FormControl size="small" sx={{ minWidth: 170 }}>
            <InputLabel>Kind</InputLabel>
            <Select label="Kind" value={kind} onChange={(e) => setKind(e.target.value as UserKind)}>
              <MenuItem value="">Everyone</MenuItem>
              {(Object.keys(USER_KIND_LABELS) as Exclude<UserKind, ''>[]).map((k) => (
                <MenuItem key={k} value={k}>
                  {USER_KIND_LABELS[k]}
                </MenuItem>
              ))}
            </Select>
          </FormControl>
          <FormControl size="small" sx={{ minWidth: 170 }}>
            <InputLabel>Module</InputLabel>
            <Select label="Module" value={moduleKey} onChange={(e) => setModuleKey(e.target.value)}>
              <MenuItem value="">Any module</MenuItem>
              {MODULE_KEYS.map((m) => (
                <MenuItem key={m} value={m}>
                  {MODULE_LABELS[m]}
                </MenuItem>
              ))}
            </Select>
          </FormControl>
          <FormControlLabel
            control={<Switch size="small" checked={quietOnly} onChange={(e) => setQuietOnly(e.target.checked)} />}
            label={`Quiet ${QUIET_DAYS}+ days`}
          />
          {anyFilter && (
            <Button size="small" onClick={clearFilters}>
              Clear
            </Button>
          )}
        </Stack>
      </Paper>

      <TableContainer component={Paper} variant="outlined">
        <Table size="small">
          <TableHead>
            <TableRow>
              <TableCell>Person</TableCell>
              <TableCell>Company</TableCell>
              <TableCell>Access</TableCell>
              <TableCell align="center">MFA</TableCell>
              <TableCell>Last sign-in</TableCell>
              <TableCell>Joined</TableCell>
              <TableCell align="right">Actions</TableCell>
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
                  {anyFilter ? 'No users match these filters.' : 'No users yet.'}
                </TableCell>
              </TableRow>
            ) : (
              rows.map((u) => {
                const quiet = !u.last_sign_in_at || Date.parse(u.last_sign_in_at) < now - QUIET_DAYS * 86_400_000;
                const mods = parseModules(u.modules);
                return (
                  <TableRow key={u.user_id} hover>
                    <TableCell>
                      <Typography variant="body2" fontWeight={600}>
                        {u.name}
                      </Typography>
                      <Typography variant="caption" color="text.secondary" display="block">
                        {u.email}
                        {u.role_title ? ` · ${u.role_title}` : ''}
                      </Typography>
                    </TableCell>
                    <TableCell>
                      <Typography
                        component={RouterLink}
                        to={`/admin/companies/${u.tenant_id}`}
                        variant="body2"
                        sx={{ textDecoration: 'none' }}
                      >
                        {u.tenant_name}
                      </Typography>
                      {u.tenant_status !== 'active' && (
                        <Chip size="small" label={u.tenant_status} color="warning" variant="outlined" sx={{ ml: 1 }} />
                      )}
                    </TableCell>
                    <TableCell sx={{ maxWidth: 380 }}>
                      <Tooltip title={summariseAccess(u)}>
                        <Stack direction="row" flexWrap="wrap" gap={0.5}>
                          {u.is_platform_admin && <Chip size="small" label="Platform admin" color="secondary" />}
                          {u.is_company_admin && <Chip size="small" label="Company admin" color="primary" />}
                          {u.finance_role && (
                            <Chip size="small" label={u.finance_role === 'finance' ? 'Finance' : 'Cost control'} variant="outlined" />
                          )}
                          {mods.slice(0, 4).map((m) => (
                            <Chip
                              key={m.module}
                              size="small"
                              variant="outlined"
                              label={`${MODULE_LABELS[m.module] ?? m.module} ${m.role}`}
                            />
                          ))}
                          {mods.length > 4 && <Chip size="small" variant="outlined" label={`+${mods.length - 4}`} />}
                          {!u.is_platform_admin && !u.is_company_admin && !u.finance_role && mods.length === 0 && (
                            <Typography variant="caption" color="text.secondary">
                              No access granted
                            </Typography>
                          )}
                        </Stack>
                      </Tooltip>
                    </TableCell>
                    <TableCell align="center">
                      {u.mfa_enrolled ? (
                        <Tooltip title="Authenticator enrolled">
                          <VerifiedUser fontSize="small" color="success" />
                        </Tooltip>
                      ) : (
                        <Tooltip title="No authenticator enrolled">
                          <Typography variant="caption" color="text.secondary">
                            —
                          </Typography>
                        </Tooltip>
                      )}
                    </TableCell>
                    <TableCell>
                      <Typography variant="body2" color={quiet ? 'warning.main' : 'text.primary'}>
                        {lastSeenLabel(u.last_sign_in_at, now)}
                      </Typography>
                    </TableCell>
                    <TableCell>
                      <Typography variant="body2">{new Date(u.created_at).toLocaleDateString()}</Typography>
                    </TableCell>
                    <TableCell align="right">
                      {u.is_platform_admin ? (
                        <Tooltip title="Platform admins are managed under Platform team">
                          <span>
                            <Button size="small" component={RouterLink} to="/admin/team">
                              Team
                            </Button>
                          </span>
                        </Tooltip>
                      ) : (
                        <Tooltip title={blockedReason ?? 'Open this company exactly as this person sees it'}>
                          <span>
                            <Button
                              size="small"
                              startIcon={<Visibility fontSize="small" />}
                              disabled={!!blockedReason}
                              onClick={() => setImpersonateTarget(u)}
                            >
                              View as
                            </Button>
                          </span>
                        </Tooltip>
                      )}
                    </TableCell>
                  </TableRow>
                );
              })
            )}
          </TableBody>
        </Table>
        <TablePagination
          component="div"
          count={total}
          page={page}
          onPageChange={(_, p) => setPage(p)}
          rowsPerPage={rowsPerPage}
          onRowsPerPageChange={(e) => {
            setRowsPerPage(parseInt(e.target.value, 10));
            setPage(0);
          }}
          rowsPerPageOptions={[25, 50, 100, 200]}
        />
      </TableContainer>

      <ImpersonationReasonDialog
        open={!!impersonateTarget}
        tenant={impersonateTarget ? { id: impersonateTarget.tenant_id, name: impersonateTarget.tenant_name } : null}
        user={
          impersonateTarget
            ? { id: impersonateTarget.user_id, name: impersonateTarget.name, email: impersonateTarget.email }
            : null
        }
        onClose={() => setImpersonateTarget(null)}
        onStarted={() => {
          setImpersonateTarget(null);
          // Full navigation (not a client-side route change): ModuleTree
          // and the banner read the session on mount, and the point of a
          // user-level View-as is that the nav shows exactly this
          // person's portals -- so everything must re-mount.
          window.location.assign('/requests/new');
        }}
      />
    </Box>
  );
}
