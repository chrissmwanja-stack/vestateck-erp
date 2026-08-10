import { useCallback, useEffect, useState } from 'react';
import {
  Alert,
  Box,
  Button,
  Chip,
  CircularProgress,
  Dialog,
  DialogActions,
  DialogContent,
  DialogContentText,
  DialogTitle,
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
import { supabase } from '../../lib/supabaseClient';
import { resendInvite, revokeInvite } from '../team/inviteActions';

interface Tenant {
  id: string;
  name: string;
  status: 'pending' | 'active' | 'suspended';
  created_at: string;
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

const emptyForm = { name: '', adminEmail: '' };

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

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const { data, error: err } = await supabase
      .from('tenants')
      .select('id, name, status, created_at')
      .order('created_at', { ascending: false });
    if (err) setError(err.message);
    else setRows((data ?? []) as Tenant[]);
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
      { body: { name } }
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
        Every tenant on the platform. Creating a company here also sends the first admin an
        invite — they land as admin on all four modules once they accept.
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
                </TableRow>
              </TableHead>
              <TableBody>
                {rows.map((row) => (
                  <TableRow key={row.id} hover>
                    <TableCell>{row.name}</TableCell>
                    <TableCell>
                      <Chip size="small" label={row.status} color={statusColor[row.status]} />
                    </TableCell>
                    <TableCell>{new Date(row.created_at).toLocaleDateString()}</TableCell>
                  </TableRow>
                ))}
                {rows.length === 0 && (
                  <TableRow>
                    <TableCell colSpan={3} align="center" sx={{ color: 'text.secondary', py: 3 }}>
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

      {actionError && (
        <Alert severity="error" sx={{ mb: 2 }} onClose={() => setActionError(null)}>
          {actionError}
        </Alert>
      )}
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
    </Box>
  );
}