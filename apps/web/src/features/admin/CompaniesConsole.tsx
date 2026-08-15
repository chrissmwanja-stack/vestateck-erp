import { useCallback, useEffect, useState } from 'react';
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
  Link,
  MenuItem,
  Paper,
  Stack,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  TextField,
  Typography,
} from '@mui/material';
import { Add as AddIcon } from '@mui/icons-material';
import { Link as RouterLink, useNavigate } from 'react-router-dom';
import { supabase } from '../../lib/supabaseClient';
import { resendInvite, revokeInvite } from '../team/inviteActions';

interface Tenant {
  id: string;
  name: string;
  status: 'pending' | 'active' | 'suspended';
  created_at: string;
  // Populated from get_companies_overview() (platform-admin-gated RPC).
  // Optional so the type still fits results from a plain `tenants`
  // select if that ever needs to be used as a fallback.
  member_count?: number;
  module_count?: number;
  request_count_30d?: number;
  pending_request_count?: number;
}

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

type IndustryTemplate = 'general' | 'construction';

const emptyForm: { name: string; adminEmail: string; industryTemplate: IndustryTemplate } = {
  name: '',
  adminEmail: '',
  industryTemplate: 'general',
};

// Every tenant gets the same 7-stage approval pipeline seeded at creation
// (seed_tenant_defaults). There's no per-tenant workflow customization
// yet -- that's a deliberately deferred feature -- so this is shown to
// the platform admin as an explanation of what they're about to create,
// not a set of choices.
const APPROVAL_PIPELINE_STAGES = [
  'Cost Control Engineer',
  'Cost Control Manager',
  'Procurement: Offer Entry',
  'Control Chief/Manager (splits by amount)',
  'Finance (if under 5,000,000) or Project Manager \u2192 Deputy GM \u2192 Finance (if over)',
];

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

const INDUSTRY_TEMPLATES: { value: IndustryTemplate; label: string; description: string }[] = [
  {
    value: 'general',
    label: 'General',
    description:
      '8 departments: IT Support, Finance, Procurement & Logistics, HR, Law & Compliance, BD, PMO, Admin/System Config.',
  },
  {
    value: 'construction',
    label: 'Construction',
    description: 'The same 8, plus Machine Operations and Sustainability & Business Excellence.',
  },
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
    supabase.auth.getSession().then(async ({ data: sessionData }) => {
      const userId = sessionData.session?.user.id;
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
    });
    return () => {
      cancelled = true;
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

  const [dialogOpen, setDialogOpen] = useState(false);
  const [form, setForm] = useState(emptyForm);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [saveNotice, setSaveNotice] = useState<string | null>(null);

  const [invitations, setInvitations] = useState<CompanyAdminInvitation[]>([]);
  const [loadingInvites, setLoadingInvites] = useState(true);
  const [actionError, setActionError] = useState<string | null>(null);
  const [actionNotice, setActionNotice] = useState<string | null>(null);
  const [rowActionId, setRowActionId] = useState<string | null>(null);
  const [revokeTarget, setRevokeTarget] = useState<CompanyAdminInvitation | null>(null);
  const [impersonatingId, setImpersonatingId] = useState<string | null>(null);

  const [modulesTarget, setModulesTarget] = useState<Tenant | null>(null);
  const [moduleSelection, setModuleSelection] = useState<Set<string>>(new Set());
  const [modulesLoading, setModulesLoading] = useState(false);
  const [modulesSaving, setModulesSaving] = useState(false);
  const [modulesError, setModulesError] = useState<string | null>(null);

  const [statusTarget, setStatusTarget] = useState<{ tenant: Tenant; next: 'active' | 'suspended' } | null>(
    null
  );
  const [statusSaving, setStatusSaving] = useState(false);

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

  const openNew = () => {
    setForm(emptyForm);
    setSaveError(null);
    setSaveNotice(null);
    setDialogOpen(true);
  };

  const close = () => {
    if (!saving) setDialogOpen(false);
  };

  const save = async () => {
    setSaveError(null);
    setSaveNotice(null);
    const name = form.name.trim();
    const adminEmail = form.adminEmail.trim();
    if (!name || !adminEmail) {
      setSaveError('Company name and first admin email are required.');
      return;
    }
    setSaving(true);

    const { data: tenantResult, error: tenantError } = await supabase.functions.invoke(
      'create-tenant',
      { body: { name, industry_template: form.industryTemplate } }
    );
    if (tenantError) {
      setSaving(false);
      setSaveError(tenantError.message);
      return;
    }

    const tenantId = tenantResult?.tenant?.id;
    if (!tenantId) {
      setSaving(false);
      setSaveError('Tenant was created but no id was returned — check the edge function logs.');
      load();
      return;
    }

    // Tenant creation succeeded but seeding departments/workflow_stages
    // may not have -- surface that distinctly rather than silently
    // proceeding to invite an admin into a still-empty company.
    if (tenantResult?.seed_warning) {
      setSaving(false);
      setDialogOpen(false);
      setError(`"${name}" was created, but: ${tenantResult.seed_warning}`);
      load();
      return;
    }

    const { error: inviteError } = await supabase.functions.invoke('invite-user', {
      body: { email: adminEmail, tenant_id: tenantId, role_bundle: 'company_admin' },
    });

    setSaving(false);

    if (inviteError) {
      // The tenant does exist at this point -- just the invite failed.
      // Don't lose that: close the form but surface it clearly. There's
      // now a resend action in the invitations table below, so this
      // isn't a dead end anymore.
      setDialogOpen(false);
      setError(`"${name}" was created, but inviting ${adminEmail} failed: ${inviteError.message}`);
      load();
      loadInvitations();
      return;
    }

    setDialogOpen(false);
    setSaveNotice(`"${name}" created and an invite sent to ${adminEmail}.`);
    load();
    loadInvitations();
  };

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
  const handleImpersonate = async (tenant: Tenant) => {
    setActionError(null);
    setImpersonatingId(tenant.id);
    const { error } = await supabase.rpc('start_impersonation', { p_tenant_id: tenant.id });
    setImpersonatingId(null);
    if (error) {
      setActionError(error.message);
      return;
    }
    navigate('/requests/new');
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
    });
    setStatusSaving(false);
    if (error) {
      setActionError(error.message);
      return;
    }
    setActionNotice(
      `${statusTarget.tenant.name} ${statusTarget.next === 'suspended' ? 'suspended' : 'reactivated'}.`
    );
    setStatusTarget(null);
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
    <Box sx={{ maxWidth: 900 }}>
      <Stack direction="row" justifyContent="space-between" alignItems="center" sx={{ mb: 2 }}>
        <Typography variant="h5">Companies</Typography>
        <Button variant="contained" startIcon={<AddIcon />} onClick={openNew}>
          New Company
        </Button>
      </Stack>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        Every tenant on the platform. Creating a company here seeds its departments and standard
        approval workflow, then sends the first admin an invite — they land as admin on all four
        modules once they accept. Use "View as" to step into a company's data directly.
      </Typography>

      {saveNotice && (
        <Alert severity="success" sx={{ mb: 2 }} onClose={() => setSaveNotice(null)}>
          {saveNotice}
        </Alert>
      )}
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
        <Stack direction="row" spacing={2} flexWrap="wrap" sx={{ mb: 2 }}>
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
            <Paper key={stat.label} variant="outlined" sx={{ px: 2, py: 1, minWidth: 140 }}>
              <Typography variant="h6">{stat.value}</Typography>
              <Typography variant="caption" color="text.secondary">
                {stat.label}
              </Typography>
            </Paper>
          ))}
        </Stack>
      )}

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
                  <TableCell>Company</TableCell>
                  <TableCell>Status</TableCell>
                  <TableCell>Created</TableCell>
                  <TableCell align="right">Members</TableCell>
                  <TableCell align="right">Modules</TableCell>
                  <TableCell align="right">Requests (30d)</TableCell>
                  <TableCell align="right">Actions</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {rows.map((row) => (
                  <TableRow key={row.id} hover>
                    <TableCell>
                      <Link component={RouterLink} to={`/admin/companies/${row.id}`}>
                        {row.name}
                      </Link>
                    </TableCell>
                    <TableCell>
                      <Chip size="small" label={row.status} color={statusColor[row.status]} />
                    </TableCell>
                    <TableCell>{new Date(row.created_at).toLocaleDateString()}</TableCell>
                    <TableCell align="right">{row.member_count ?? '—'}</TableCell>
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
                          <Button
                            size="small"
                            color={row.status === 'suspended' ? 'success' : 'warning'}
                            onClick={() =>
                              setStatusTarget({
                                tenant: row,
                                next: row.status === 'suspended' ? 'active' : 'suspended',
                              })
                            }
                          >
                            {row.status === 'suspended' ? 'Activate' : 'Suspend'}
                          </Button>
                        )}
                        <Button
                          size="small"
                          onClick={() => handleImpersonate(row)}
                          disabled={impersonatingId === row.id}
                        >
                          {impersonatingId === row.id ? 'Starting…' : 'View as'}
                        </Button>
                      </Stack>
                    </TableCell>
                  </TableRow>
                ))}
                {rows.length === 0 && (
                  <TableRow>
                    <TableCell colSpan={7} align="center" sx={{ color: 'text.secondary', py: 3 }}>
                      No companies yet.
                    </TableCell>
                  </TableRow>
                )}
              </TableBody>
            </Table>
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

      <Dialog open={dialogOpen} onClose={close} maxWidth="sm" fullWidth>
        <DialogTitle>New Company</DialogTitle>
        <DialogContent>
          <Stack spacing={2} sx={{ mt: 1 }}>
            <TextField
              label="Company name"
              fullWidth
              value={form.name}
              onChange={(e) => setForm((v) => ({ ...v, name: e.target.value }))}
              disabled={saving}
            />
            <TextField
              label="First admin email"
              type="email"
              fullWidth
              value={form.adminEmail}
              onChange={(e) => setForm((v) => ({ ...v, adminEmail: e.target.value }))}
              disabled={saving}
              helperText="They'll be invited as admin on HR, Legal, BD, and IT."
            />
            <TextField
              select
              label="Industry template"
              fullWidth
              value={form.industryTemplate}
              onChange={(e) =>
                setForm((v) => ({
                  ...v,
                  industryTemplate: e.target.value as IndustryTemplate,
                }))
              }
              disabled={saving}
              helperText={
                INDUSTRY_TEMPLATES.find((t) => t.value === form.industryTemplate)?.description
              }
            >
              {INDUSTRY_TEMPLATES.map((t) => (
                <MenuItem key={t.value} value={t.value}>
                  {t.label}
                </MenuItem>
              ))}
            </TextField>

            <Box sx={{ bgcolor: 'action.hover', borderRadius: 1, p: 1.5 }}>
              <Typography variant="subtitle2" sx={{ mb: 0.5 }}>
                Every company gets the same approval pipeline
              </Typography>
              <Typography variant="body2" color="text.secondary" sx={{ mb: 1 }}>
                This isn't customizable per company yet — every request routes through the same
                7-stage chain, with a 5,000,000 threshold deciding the branch:
              </Typography>
              <Stack component="ol" sx={{ pl: 2.5, m: 0 }} spacing={0.25}>
                {APPROVAL_PIPELINE_STAGES.map((stage) => (
                  <Typography key={stage} component="li" variant="body2" color="text.secondary">
                    {stage}
                  </Typography>
                ))}
              </Stack>
            </Box>

            {saveError && <Alert severity="error">{saveError}</Alert>}
          </Stack>
        </DialogContent>
        <DialogActions>
          <Button onClick={close} disabled={saving}>
            Cancel
          </Button>
          <Button onClick={save} variant="contained" disabled={saving}>
            {saving ? 'Creating…' : 'Create & invite'}
          </Button>
        </DialogActions>
      </Dialog>

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
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setStatusTarget(null)} disabled={statusSaving}>
            Cancel
          </Button>
          <Button
            color={statusTarget?.next === 'suspended' ? 'warning' : 'success'}
            onClick={confirmStatusChange}
            disabled={statusSaving}
          >
            {statusSaving ? 'Saving…' : statusTarget?.next === 'suspended' ? 'Suspend' : 'Activate'}
          </Button>
        </DialogActions>
      </Dialog>

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