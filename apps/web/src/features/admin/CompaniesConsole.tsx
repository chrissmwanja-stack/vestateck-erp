import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Alert,
  Box,
  Button,
  Checkbox,
  Chip,
  CircularProgress,
  Dialog,
  DialogActions,
  DialogContent,
  DialogContentText,
  DialogTitle,
  FormControlLabel,
  FormGroup,
  InputAdornment,
  Link,
  MenuItem,
  Paper,
  Stack,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TablePagination,
  TableRow,
  TableSortLabel,
  TextField,
  Tooltip,
  Typography,
} from '@mui/material';
import { Add as AddIcon, Download as DownloadIcon, Search as SearchIcon } from '@mui/icons-material';
import CompanyCreateWizard from './CompanyCreateWizard';
import {
  applyCompanyFilters,
  companiesToCsv,
  downloadCsv,
  EMPTY_FILTERS,
  filtersFromSearch,
  filtersToSearch,
  PLAN_LABELS,
  sortCompanies,
  type CompanyFilters,
  type SortKey,
  type Tenant,
} from './companiesList';
import { Link as RouterLink, useNavigate, useSearchParams } from 'react-router-dom';
import { STAGE_HINTS, STAGE_LABELS, STAGE_ORDER, type StageKey } from './platformHealth';
import { supabase } from '../../lib/supabaseClient';
import { resendInvite, revokeInvite } from '../team/inviteActions';
import ImpersonationReasonDialog from './ImpersonationReasonDialog';
import { describeBlockedReason, friendlyPlatformError, usePlatformAdminSession } from './usePlatformAdminSession';


const subscriptionColor: Record<string, 'default' | 'success' | 'warning' | 'error' | 'info'> = {
  trialing: 'info',
  active: 'success',
  past_due: 'warning',
  cancelled: 'error',
};

interface CompanyAdminInvitation {
  id: string;
  tenant_id: string;
  email: string;
  status: 'pending' | 'accepted' | 'expired' | 'revoked';
  created_at: string;
}

const statusColor: Record<Tenant['status'], 'default' | 'success' | 'warning'> = {
  pending: 'warning',
  active: 'success',
  suspended: 'default',
};

const invitationStatusColor: Record<
  CompanyAdminInvitation['status'],
  'default' | 'success' | 'warning' | 'error'
> = {
  pending: 'warning',
  accepted: 'success',
  expired: 'default',
  revoked: 'error',
};

// Keep in sync with the tenant_modules CHECK constraint and
// apps/web/src/components/RequireModule.tsx's ModuleKey. Finance and
// core Procurement aren't here -- they're baseline functionality every
// tenant gets, gated by finance_team_members/approval_assignments
// rather than staff_roles, so there's nothing to toggle for them.
const MODULE_OPTIONS: { value: string; label: string }[] = [
  { value: 'hr', label: 'HR' },
  { value: 'legal', label: 'Law & Compliance' },
  { value: 'bd', label: 'Business Development' },
  { value: 'it', label: 'IT Support' },
  { value: 'pmo', label: 'PMO' },
  { value: 'procurement', label: 'Purchasing & Logistics extras' },
  { value: 'machine_operation', label: 'Machine Operation' },
  { value: 'sustainability', label: 'Sustainability' },
];


// Gate: only platform admins should see this screen at all. The real
// enforcement lives server-side (create-tenant / invite-user both check
// is_platform_admin) -- this just keeps the screen from rendering for
// people every call on it would fail for.
//
// app_users' only SELECT policy scopes by tenant_id, not by your own id
// (tenant_id = get_my_tenant_id()), so querying without an explicit
// .eq('id', ...) filter can return every user in your tenant, not just
// you -- and .single() throws on more than one row. Get the caller's own
// id from the session first, then filter on it.
function usePlatformAdminAccess() {
  const [isPlatformAdmin, setIsPlatformAdmin] = useState<boolean | null>(null);
  useEffect(() => {
    let cancelled = false;

    const fetchAccess = async (userId: string | undefined) => {
      if (!userId) {
        if (!cancelled) setIsPlatformAdmin(false);
        return;
      }
      const { data, error } = await supabase
        .from('app_users')
        .select('is_platform_admin')
        .eq('id', userId)
        .maybeSingle();
      if (cancelled) return;
      setIsPlatformAdmin(error ? false : Boolean(data?.is_platform_admin));
    };

    // Fetch once on mount for the fast path, but also re-fetch on any auth
    // state change. A session can swap within the same tab without a full
    // page reload, and a mount-only effect would keep showing the previous
    // session's access after the underlying user has changed.
    supabase.auth.getSession().then(({ data: sessionData }) => {
      if (!cancelled) fetchAccess(sessionData.session?.user.id);
    });

    const { data: subscription } = supabase.auth.onAuthStateChange((_event, session) => {
      if (cancelled) return;
      setIsPlatformAdmin(null);
      fetchAccess(session?.user.id);
    });

    return () => {
      cancelled = true;
      subscription.subscription.unsubscribe();
    };
  }, []);
  return isPlatformAdmin;
}

export default function CompaniesConsole() {
  const isPlatformAdmin = usePlatformAdminAccess();
  const navigate = useNavigate();
  const [rows, setRows] = useState<Tenant[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [wizardOpen, setWizardOpen] = useState(false);

  const [invitations, setInvitations] = useState<CompanyAdminInvitation[]>([]);
  const [loadingInvites, setLoadingInvites] = useState(true);
  const [actionError, setActionError] = useState<string | null>(null);
  const [actionNotice, setActionNotice] = useState<string | null>(null);
  const [rowActionId, setRowActionId] = useState<string | null>(null);
  const [revokeTarget, setRevokeTarget] = useState<CompanyAdminInvitation | null>(null);
  const [impersonateTarget, setImpersonateTarget] = useState<Tenant | null>(null);
  const { session: adminSession } = usePlatformAdminSession();
  const blockedReason = describeBlockedReason(adminSession);

  const [searchParams, setSearchParams] = useSearchParams();
  // Filters live in the URL so the Overview funnel / stalled / quiet links
  // land on the right slice and the view survives a refresh.
  const filters = useMemo(() => filtersFromSearch(searchParams), [searchParams]);
  const setFilters = useCallback(
    (next: CompanyFilters | ((f: CompanyFilters) => CompanyFilters)) => {
      const value = typeof next === 'function' ? next(filtersFromSearch(searchParams)) : next;
      setSearchParams(filtersToSearch(value), { replace: true });
    },
    [searchParams, setSearchParams]
  );
  const [sortKey, setSortKey] = useState<SortKey>('created_at');
  const [sortDir, setSortDir] = useState<'asc' | 'desc'>('desc');
  const [page, setPage] = useState(0);
  const [rowsPerPage, setRowsPerPage] = useState(25);

  const filteredRows = useMemo(() => sortCompanies(applyCompanyFilters(rows, filters), sortKey, sortDir), [rows, filters, sortKey, sortDir]);
  const pagedRows = useMemo(
    () => filteredRows.slice(page * rowsPerPage, page * rowsPerPage + rowsPerPage),
    [filteredRows, page, rowsPerPage]
  );
  useEffect(() => setPage(0), [filters, sortKey, sortDir, rowsPerPage]);

  const toggleSort = (key: SortKey) => {
    if (sortKey === key) setSortDir((d) => (d === 'asc' ? 'desc' : 'asc'));
    else {
      setSortKey(key);
      setSortDir(key === 'name' || key === 'status' || key === 'plan' ? 'asc' : 'desc');
    }
  };

  const [modulesTarget, setModulesTarget] = useState<Tenant | null>(null);
  const [moduleSelection, setModuleSelection] = useState<Set<string>>(new Set());
  const [modulesLoading, setModulesLoading] = useState(false);
  const [modulesSaving, setModulesSaving] = useState(false);
  const [modulesError, setModulesError] = useState<string | null>(null);

  const [statusTarget, setStatusTarget] = useState<{ tenant: Tenant; next: 'active' | 'suspended' } | null>(
    null
  );
  const [statusSaving, setStatusSaving] = useState(false);
  const [statusReason, setStatusReason] = useState('');

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    // get_companies_overview() carries the same columns as the old
    // `tenants` select plus per-tenant activity counts (members,
    // modules enabled, requests), so the table and the summary stats
    // bar below both come from one round trip.
    const { data, error: err } = await supabase.rpc('get_companies_overview');
    if (err) setError(err.message);
    else
      setRows(
        ((data ?? []) as any[]).map((r) => ({
          id: r.tenant_id,
          name: r.name,
          status: r.status,
          created_at: r.created_at,
          member_count: r.member_count,
          module_count: r.module_count,
          request_count_30d: r.request_count_30d,
          pending_request_count: r.pending_request_count,
          plan: r.plan,
          subscription_status: r.subscription_status,
          seat_limit: r.seat_limit,
          trial_ends_at: r.trial_ends_at,
          read_only: r.read_only,
          contact_email: r.contact_email,
          last_activity_at: r.last_activity_at,
        })) as Tenant[]
      );
    setLoading(false);
  }, []);

  const loadInvitations = useCallback(async () => {
    setLoadingInvites(true);
    const { data, error: err } = await supabase
      .from('invitations')
      .select('id, tenant_id, email, status, created_at')
      .eq('role_bundle', 'company_admin')
      .order('created_at', { ascending: false });
    if (err) setActionError(err.message);
    else setInvitations((data ?? []) as CompanyAdminInvitation[]);
    setLoadingInvites(false);
  }, []);

  useEffect(() => {
    load();
    loadInvitations();
  }, [load, loadInvitations]);

  const handleResend = async (invitation: CompanyAdminInvitation) => {
    setActionError(null);
    setActionNotice(null);
    setRowActionId(invitation.id);
    const { error } = await resendInvite(invitation.id);
    setRowActionId(null);
    if (error) {
      setActionError(error);
      return;
    }
    setActionNotice(`Invite resent to ${invitation.email}.`);
    loadInvitations();
  };

  const confirmRevoke = async () => {
    if (!revokeTarget) return;
    setActionError(null);
    setActionNotice(null);
    setRowActionId(revokeTarget.id);
    const { error } = await revokeInvite(revokeTarget.id);
    setRowActionId(null);
    const email = revokeTarget.email;
    setRevokeTarget(null);
    if (error) {
      setActionError(error);
      return;
    }
    setActionNotice(`Invite for ${email} revoked.`);
    loadInvitations();
  };

  // Starts a tenant-scoped impersonation session (get_my_tenant_id()
  // resolves to this tenant for every RLS check from here on) and drops
  // into the normal app shell as if you belonged to it. The persistent
  // ImpersonationBanner (mounted in TopNav) is the way back out.
  // start_impersonation(uuid, text) now requires a reason (audited), so
  // the click opens ImpersonationReasonDialog and the RPC runs from there.
  const handleImpersonate = (tenant: Tenant) => {
    setActionError(null);
    setImpersonateTarget(tenant);
  };

  // Opens the modules dialog and loads this tenant's current
  // entitlements via get_tenant_modules (platform-admin-gated RPC, so
  // no separate client-side permission check needed here).
  const openModules = async (tenant: Tenant) => {
    setModulesError(null);
    setModulesTarget(tenant);
    setModulesLoading(true);
    const { data, error } = await supabase.rpc('get_tenant_modules', { p_tenant_id: tenant.id });
    setModulesLoading(false);
    if (error) {
      setModulesError(error.message);
      setModuleSelection(new Set());
      return;
    }
    setModuleSelection(new Set((data ?? []) as string[]));
  };

  const closeModules = () => {
    if (!modulesSaving) setModulesTarget(null);
  };

  const toggleModule = (module: string) => {
    setModuleSelection((prev) => {
      const next = new Set(prev);
      if (next.has(module)) next.delete(module);
      else next.add(module);
      return next;
    });
  };

  // Replace-all: set_tenant_modules takes the full desired set, so
  // there's no risk of a partial update leaving stale entitlements
  // behind if a toggle gets missed.
  const saveModules = async () => {
    if (!modulesTarget) return;
    setModulesError(null);
    setModulesSaving(true);
    const { error } = await supabase.rpc('set_tenant_modules', {
      p_tenant_id: modulesTarget.id,
      p_modules: Array.from(moduleSelection),
    });
    setModulesSaving(false);
    if (error) {
      setModulesError(error.message);
      return;
    }
    setActionNotice(`Modules updated for ${modulesTarget.name}.`);
    setModulesTarget(null);
  };

  // Suspend/activate go through confirmation (same pattern as revoke
  // invite) since suspending a company is consequential and shouldn't
  // be one accidental click. 'pending' is deliberately not offered
  // here -- it's a bootstrap-only state set by create-tenant /
  // accept-invite, not something to hand-set on an already-running
  // company.
  const confirmStatusChange = async () => {
    if (!statusTarget) return;
    setActionError(null);
    setActionNotice(null);
    setStatusSaving(true);
    const { error } = await supabase.rpc('set_tenant_status', {
      p_tenant_id: statusTarget.tenant.id,
      p_status: statusTarget.next,
      p_reason: statusReason.trim() || null,
    });
    setStatusSaving(false);
    if (error) {
      setActionError(friendlyPlatformError(error.message));
      return;
    }
    setActionNotice(
      `${statusTarget.tenant.name} ${statusTarget.next === 'suspended' ? 'suspended' : 'reactivated'}.`
    );
    setStatusTarget(null);
    setStatusReason('');
    load();
  };

  if (isPlatformAdmin === false) {
    return (
      <Alert severity="warning" sx={{ maxWidth: 600, mx: 'auto', mt: 4 }}>
        The Companies console is only available to platform admins.
      </Alert>
    );
  }

  return (
    <Box sx={{ maxWidth: 1100 }}>
      <Stack
        direction={{ xs: 'column', sm: 'row' }}
        justifyContent="space-between"
        alignItems={{ xs: 'flex-start', sm: 'flex-end' }}
        spacing={2}
        sx={{ mb: 3 }}
      >
        <Box>
          <Typography variant="h4">Companies</Typography>
          <Typography variant="body2" color="text.secondary" sx={{ mt: 0.5, maxWidth: 560 }}>
            Every customer company on the platform. Click a name for its profile, plan, seats
            and lifecycle controls; use "View as" to step into its workspace for support.
          </Typography>
        </Box>
        <Button variant="contained" startIcon={<AddIcon />} onClick={() => setWizardOpen(true)} sx={{ flexShrink: 0 }}>
          New company
        </Button>
      </Stack>

      {error && (
        <Alert severity="error" sx={{ mb: 2 }} onClose={() => setError(null)}>
          {error}
        </Alert>
      )}
      {actionError && (
        <Alert severity="error" sx={{ mb: 2 }} onClose={() => setActionError(null)}>
          {actionError}
        </Alert>
      )}

      {!loading && rows.length > 0 && (
        <Stack direction="row" spacing={2} flexWrap="wrap" sx={{ mb: 4 }}>
          {[
            { label: 'Companies onboarded', value: rows.length },
            { label: 'Active', value: rows.filter((r) => r.status === 'active').length },
            { label: 'Pending', value: rows.filter((r) => r.status === 'pending').length },
            {
              label: 'Total members',
              value: rows.reduce((sum, r) => sum + (r.member_count ?? 0), 0),
            },
            {
              label: 'Requests (30d)',
              value: rows.reduce((sum, r) => sum + (r.request_count_30d ?? 0), 0),
            },
          ].map((stat) => (
            <Paper
              key={stat.label}
              variant="outlined"
              sx={{ px: 2.5, py: 1.75, minWidth: 150, borderTop: (theme) => `3px solid ${theme.palette.secondary.main}` }}
            >
              <Typography variant="h4" sx={{ color: 'secondary.main', lineHeight: 1.1 }}>
                {stat.value}
              </Typography>
              <Typography variant="caption" color="text.secondary">
                {stat.label}
              </Typography>
            </Paper>
          ))}
        </Stack>
      )}

      <Stack
        direction={{ xs: 'column', md: 'row' }}
        spacing={1.5}
        alignItems={{ md: 'center' }}
        sx={{ mb: 1.5 }}
        useFlexGap
        flexWrap="wrap"
      >
        <TextField
          size="small"
          placeholder="Search name or contact email"
          value={filters.q}
          onChange={(e) => setFilters((f) => ({ ...f, q: e.target.value }))}
          InputProps={{ startAdornment: <InputAdornment position="start"><SearchIcon fontSize="small" /></InputAdornment> }}
          sx={{ minWidth: 260 }}
          inputProps={{ 'aria-label': 'Search companies' }}
        />
        <TextField select size="small" label="Status" value={filters.status} onChange={(e) => setFilters((f) => ({ ...f, status: e.target.value as CompanyFilters['status'] }))} sx={{ minWidth: 130 }}>
          <MenuItem value="">Any status</MenuItem>
          <MenuItem value="active">Active</MenuItem>
          <MenuItem value="pending">Pending</MenuItem>
          <MenuItem value="suspended">Suspended</MenuItem>
        </TextField>
        <TextField select size="small" label="Plan" value={filters.plan} onChange={(e) => setFilters((f) => ({ ...f, plan: e.target.value }))} sx={{ minWidth: 130 }}>
          <MenuItem value="">Any plan</MenuItem>
          {Object.entries(PLAN_LABELS).map(([v, l]) => (
            <MenuItem key={v} value={v}>{l}</MenuItem>
          ))}
        </TextField>
        <TextField select size="small" label="Subscription" value={filters.subscription} onChange={(e) => setFilters((f) => ({ ...f, subscription: e.target.value }))} sx={{ minWidth: 150 }}>
          <MenuItem value="">Any</MenuItem>
          <MenuItem value="trialing">Trialing</MenuItem>
          <MenuItem value="active">Active (paid)</MenuItem>
          <MenuItem value="past_due">Past due</MenuItem>
          <MenuItem value="cancelled">Cancelled</MenuItem>
        </TextField>
        <TextField select size="small" label="Needs attention" value={filters.flag} onChange={(e) => setFilters((f) => ({ ...f, flag: e.target.value as CompanyFilters['flag'] }))} sx={{ minWidth: 190 }}>
          <MenuItem value="">Everything</MenuItem>
          <MenuItem value="trial_ending">Trial ending ≤ 14 days</MenuItem>
          <MenuItem value="quiet">Quiet 30+ days</MenuItem>
          <MenuItem value="stalled">Stalled in setup 7+ days</MenuItem>
          <MenuItem value="read_only">In read-only mode</MenuItem>
          <MenuItem value="seats_full">Seats full</MenuItem>
        </TextField>
        <TextField select size="small" label="Onboarding" value={filters.stage} onChange={(e) => setFilters((f) => ({ ...f, stage: e.target.value }))} sx={{ minWidth: 170 }}>
          <MenuItem value="">Any stage</MenuItem>
          {STAGE_ORDER.map((k) => (
            <MenuItem key={k} value={k}>
              {STAGE_LABELS[k]}
            </MenuItem>
          ))}
        </TextField>
        <Box sx={{ flex: 1 }} />
        <Typography variant="body2" color="text.secondary">
          {filteredRows.length === rows.length ? `${rows.length} companies` : `${filteredRows.length} of ${rows.length}`}
        </Typography>
        {(filters.q || filters.status || filters.plan || filters.subscription || filters.flag || filters.stage) && (
          <Button size="small" onClick={() => setFilters(EMPTY_FILTERS)}>
            Clear
          </Button>
        )}
        <Button
          size="small"
          startIcon={<DownloadIcon />}
          disabled={filteredRows.length === 0}
          onClick={() => downloadCsv(`companies-${new Date().toISOString().slice(0, 10)}.csv`, companiesToCsv(filteredRows))}
        >
          Export CSV
        </Button>
      </Stack>

      <Paper variant="outlined">
        {loading ? (
          <Box display="flex" justifyContent="center" py={4}>
            <CircularProgress size={24} />
          </Box>
        ) : (
          <TableContainer>
            <Table size="small">
              <TableHead>
                <TableRow>
                  {(
                    [
                      ['name', 'Company', 'left'],
                      ['status', 'Status', 'left'],
                      ['plan', 'Plan', 'left'],
                      ['created_at', 'Created', 'left'],
                      ['last_activity_at', 'Last activity', 'left'],
                      ['onboarding_stage', 'Onboarding', 'left'],
                      ['member_count', 'Members', 'right'],
                    ] as [SortKey, string, 'left' | 'right'][]
                  ).map(([key, label, align]) => (
                    <TableCell key={key} align={align} sortDirection={sortKey === key ? sortDir : false}>
                      <TableSortLabel active={sortKey === key} direction={sortKey === key ? sortDir : 'asc'} onClick={() => toggleSort(key)}>
                        {label}
                      </TableSortLabel>
                    </TableCell>
                  ))}
                  <TableCell align="right">Modules</TableCell>
                  <TableCell align="right" sortDirection={sortKey === 'request_count_30d' ? sortDir : false}>
                    <TableSortLabel active={sortKey === 'request_count_30d'} direction={sortKey === 'request_count_30d' ? sortDir : 'asc'} onClick={() => toggleSort('request_count_30d')}>
                      Requests (30d)
                    </TableSortLabel>
                  </TableCell>
                  <TableCell align="right">Actions</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {pagedRows.map((row) => (
                  <TableRow key={row.id} hover>
                    <TableCell>
                      <Link component={RouterLink} to={`/admin/companies/${row.id}`}>
                        {row.name}
                      </Link>
                    </TableCell>
                    <TableCell>
                      <Stack direction="row" spacing={0.5}>
                        <Chip size="small" label={row.status} color={statusColor[row.status]} />
                        {row.read_only && (
                          <Tooltip title="Read-only: users can view but not change anything">
                            <Chip size="small" label="read-only" color="warning" variant="outlined" />
                          </Tooltip>
                        )}
                      </Stack>
                    </TableCell>
                    <TableCell>
                      {row.plan ? (
                        <Stack direction="row" spacing={0.5} alignItems="center">
                          <Typography variant="body2">{row.plan}</Typography>
                          {row.subscription_status && row.subscription_status !== 'active' && (
                            <Chip
                              size="small"
                              variant="outlined"
                              label={row.subscription_status.replace('_', ' ')}
                              color={subscriptionColor[row.subscription_status] ?? 'default'}
                            />
                          )}
                        </Stack>
                      ) : (
                        '—'
                      )}
                    </TableCell>
                    <TableCell>{new Date(row.created_at).toLocaleDateString()}</TableCell>
                    <TableCell>{row.last_activity_at ? new Date(row.last_activity_at).toLocaleDateString() : '—'}</TableCell>
                    <TableCell>
                      {row.onboarding_stage ? (
                        <Tooltip title={row.onboarding_next_step ?? STAGE_HINTS[row.onboarding_stage as StageKey] ?? ''}>
                          <Chip
                            size="small"
                            variant={row.onboarding_stage === 'live' ? 'filled' : 'outlined'}
                            color={row.onboarding_stalled ? 'error' : row.onboarding_stage === 'live' ? 'success' : 'default'}
                            label={`${STAGE_LABELS[row.onboarding_stage as StageKey] ?? row.onboarding_stage}${row.onboarding_stalled ? ' · stalled' : ''}`}
                          />
                        </Tooltip>
                      ) : (
                        '—'
                      )}
                    </TableCell>
                    <TableCell align="right">
                      {row.member_count ?? '—'}
                      {row.seat_limit != null && (
                        <Typography component="span" variant="caption" color="text.secondary">
                          {' '}/ {row.seat_limit}
                        </Typography>
                      )}
                    </TableCell>
                    <TableCell align="right">
                      {row.module_count ?? '—'} / {MODULE_OPTIONS.length}
                    </TableCell>
                    <TableCell align="right">{row.request_count_30d ?? '—'}</TableCell>
                    <TableCell align="right">
                      <Stack direction="row" spacing={1} justifyContent="flex-end">
                        <Button size="small" onClick={() => openModules(row)}>
                          Modules
                        </Button>
                        {row.status !== 'pending' && (
                          <Tooltip title={blockedReason ?? ''}>
                            <span>
                              <Button
                                size="small"
                                color={row.status === 'suspended' ? 'success' : 'warning'}
                                disabled={!!blockedReason}
                                onClick={() => {
                                  setStatusReason('');
                                  setStatusTarget({
                                    tenant: row,
                                    next: row.status === 'suspended' ? 'active' : 'suspended',
                                  });
                                }}
                              >
                                {row.status === 'suspended' ? 'Activate' : 'Suspend'}
                              </Button>
                            </span>
                          </Tooltip>
                        )}
                        <Tooltip title={blockedReason ?? ''}>
                          <span>
                            <Button size="small" onClick={() => handleImpersonate(row)} disabled={!!blockedReason}>
                              View as
                            </Button>
                          </span>
                        </Tooltip>
                      </Stack>
                    </TableCell>
                  </TableRow>
                ))}
                {filteredRows.length === 0 && (
                  <TableRow>
                    <TableCell colSpan={9} align="center" sx={{ color: 'text.secondary', py: 3 }}>
                      {rows.length === 0 ? 'No companies yet.' : 'No companies match these filters.'}
                    </TableCell>
                  </TableRow>
                )}
              </TableBody>
            </Table>
            <TablePagination
              component="div"
              count={filteredRows.length}
              page={page}
              onPageChange={(_, p) => setPage(p)}
              rowsPerPage={rowsPerPage}
              onRowsPerPageChange={(e) => setRowsPerPage(Number(e.target.value))}
              rowsPerPageOptions={[10, 25, 50, 100]}
            />
          </TableContainer>
        )}
      </Paper>

      <Typography variant="h6" sx={{ mt: 4, mb: 1 }}>
        First-admin invites
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
        Company admin invites sent from this console, across every tenant.
      </Typography>

      {actionNotice && (
        <Alert severity="success" sx={{ mb: 2 }} onClose={() => setActionNotice(null)}>
          {actionNotice}
        </Alert>
      )}

      <Paper variant="outlined">
        {loadingInvites ? (
          <Box display="flex" justifyContent="center" py={4}>
            <CircularProgress size={24} />
          </Box>
        ) : (
          <TableContainer>
            <Table size="small">
              <TableHead>
                <TableRow>
                  <TableCell>Email</TableCell>
                  <TableCell>Company</TableCell>
                  <TableCell>Status</TableCell>
                  <TableCell>Sent</TableCell>
                  <TableCell align="right">Actions</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {invitations.map((inv) => {
                  const tenantName = rows.find((t) => t.id === inv.tenant_id)?.name ?? '—';
                  return (
                    <TableRow key={inv.id} hover>
                      <TableCell>{inv.email}</TableCell>
                      <TableCell>{tenantName}</TableCell>
                      <TableCell>
                        <Chip size="small" label={inv.status} color={invitationStatusColor[inv.status]} />
                      </TableCell>
                      <TableCell>{new Date(inv.created_at).toLocaleDateString()}</TableCell>
                      <TableCell align="right">
                        {(inv.status === 'pending' || inv.status === 'expired') && (
                          <Stack direction="row" spacing={1} justifyContent="flex-end">
                            <Button
                              size="small"
                              onClick={() => handleResend(inv)}
                              disabled={rowActionId === inv.id}
                            >
                              Resend
                            </Button>
                            {inv.status === 'pending' && (
                              <Button
                                size="small"
                                color="error"
                                onClick={() => setRevokeTarget(inv)}
                                disabled={rowActionId === inv.id}
                              >
                                Revoke
                              </Button>
                            )}
                          </Stack>
                        )}
                      </TableCell>
                    </TableRow>
                  );
                })}
                {invitations.length === 0 && (
                  <TableRow>
                    <TableCell colSpan={5} align="center" sx={{ color: 'text.secondary', py: 3 }}>
                      No company admin invites sent yet.
                    </TableCell>
                  </TableRow>
                )}
              </TableBody>
            </Table>
          </TableContainer>
        )}
      </Paper>

      <CompanyCreateWizard
        open={wizardOpen}
        onClose={() => setWizardOpen(false)}
        onCreated={() => {
          load();
          loadInvitations();
        }}
      />

      <Dialog open={!!revokeTarget} onClose={() => setRevokeTarget(null)}>
        <DialogTitle>Revoke invite?</DialogTitle>
        <DialogContent>
          <DialogContentText>
            {revokeTarget?.email} won't be able to use this invite link anymore. This can't be
            undone — you'd need to send a new invite.
          </DialogContentText>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setRevokeTarget(null)}>Cancel</Button>
          <Button color="error" onClick={confirmRevoke} disabled={rowActionId === revokeTarget?.id}>
            Revoke invite
          </Button>
        </DialogActions>
      </Dialog>

      <Dialog open={!!statusTarget} onClose={() => !statusSaving && setStatusTarget(null)}>
        <DialogTitle>{statusTarget?.next === 'suspended' ? 'Suspend company?' : 'Reactivate company?'}</DialogTitle>
        <DialogContent>
          <DialogContentText>
            {statusTarget?.next === 'suspended' ? (
              <>
                {statusTarget?.tenant.name} will be marked suspended. Their users will immediately
                lose access to the platform (they'll see a "your company's access has been
                suspended" message) — you'll still be able to "View as" them for support purposes.
              </>
            ) : (
              <>{statusTarget?.tenant.name} will be marked active again.</>
            )}
          </DialogContentText>
          <TextField
            fullWidth
            multiline
            minRows={2}
            sx={{ mt: 2 }}
            label={statusTarget?.next === 'suspended' ? 'Reason (required)' : 'Reason (optional)'}
            placeholder={
              statusTarget?.next === 'suspended'
                ? 'e.g. Invoice INV-0231 unpaid 60 days past due'
                : 'e.g. Payment received 22 Sep'
            }
            value={statusReason}
            onChange={(e) => setStatusReason(e.target.value)}
            disabled={statusSaving}
            helperText="Recorded in the platform audit log."
          />
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setStatusTarget(null)} disabled={statusSaving}>
            Cancel
          </Button>
          <Button
            color={statusTarget?.next === 'suspended' ? 'warning' : 'success'}
            onClick={confirmStatusChange}
            disabled={statusSaving || (statusTarget?.next === 'suspended' && statusReason.trim().length === 0)}
          >
            {statusSaving ? 'Saving…' : statusTarget?.next === 'suspended' ? 'Suspend' : 'Activate'}
          </Button>
        </DialogActions>
      </Dialog>

      <ImpersonationReasonDialog
        open={!!impersonateTarget}
        tenant={impersonateTarget}
        onClose={() => setImpersonateTarget(null)}
        onStarted={() => {
          setImpersonateTarget(null);
          navigate('/requests/new');
        }}
      />

      <Dialog open={!!modulesTarget} onClose={closeModules} maxWidth="xs" fullWidth>
        <DialogTitle>Modules — {modulesTarget?.name}</DialogTitle>
        <DialogContent>
          {modulesLoading ? (
            <Box display="flex" justifyContent="center" py={3}>
              <CircularProgress size={24} />
            </Box>
          ) : (
            <Stack spacing={1} sx={{ mt: 1 }}>
              <Typography variant="body2" color="text.secondary">
                Modules this company can access. Finance and core Purchasing & Logistics aren't
                listed — every tenant has those by default.
              </Typography>
              <FormGroup>
                {MODULE_OPTIONS.map((opt) => (
                  <FormControlLabel
                    key={opt.value}
                    control={
                      <Checkbox
                        checked={moduleSelection.has(opt.value)}
                        onChange={() => toggleModule(opt.value)}
                        disabled={modulesSaving}
                      />
                    }
                    label={opt.label}
                  />
                ))}
              </FormGroup>
              {modulesError && <Alert severity="error">{modulesError}</Alert>}
            </Stack>
          )}
        </DialogContent>
        <DialogActions>
          <Button onClick={closeModules} disabled={modulesSaving}>
            Cancel
          </Button>
          <Button onClick={saveModules} variant="contained" disabled={modulesSaving || modulesLoading}>
            {modulesSaving ? 'Saving…' : 'Save'}
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}