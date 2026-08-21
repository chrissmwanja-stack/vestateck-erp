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
import { supabase } from '../../lib/supabaseClient';
import { resendInvite, revokeInvite } from './inviteActions';
import { useTenantAdminAccess } from './useTenantAdminAccess';

const ALL_MODULES = ['hr', 'legal', 'bd', 'it', 'pmo', 'machine_operation', 'sustainability', 'procurement'] as const;
const MODULE_LABELS: Record<(typeof ALL_MODULES)[number], string> = {
  hr: 'HR',
  legal: 'Legal & Compliance',
  bd: 'Business Development',
  it: 'IT Support',
  pmo: 'Project Management Office',
  machine_operation: 'Machine Operation',
  sustainability: 'Sustainability & Business Excellence',
  procurement: 'Procurement & Purchasing',
};
const ROLES = ['admin', 'manager', 'member'] as const;

// Not a module -- finance access is a separate mechanism
// (finance_team_members / is_finance_team_member()), not staff_roles.
const FINANCE_ROLES = ['', 'cost_control', 'finance'] as const;
const FINANCE_ROLE_LABELS: Record<(typeof FINANCE_ROLES)[number], string> = {
  '': 'No finance access',
  cost_control: 'Cost Control (view only)',
  finance: 'Finance (view & edit)',
};

interface Invitation {
  id: string;
  email: string;
  role_bundle: 'company_admin' | 'member';
  modules_and_roles: { module: string; role: string }[] | null;
  finance_role: 'finance' | 'cost_control' | null;
  status: 'pending' | 'accepted' | 'expired' | 'revoked';
  created_at: string;
}

type ModuleSelection = Record<(typeof ALL_MODULES)[number], { checked: boolean; role: (typeof ROLES)[number] }>;

const emptyModuleSelection: ModuleSelection = {
  hr: { checked: false, role: 'member' },
  legal: { checked: false, role: 'member' },
  bd: { checked: false, role: 'member' },
  it: { checked: false, role: 'member' },
  pmo: { checked: false, role: 'member' },
  machine_operation: { checked: false, role: 'member' },
  sustainability: { checked: false, role: 'member' },
  procurement: { checked: false, role: 'member' },
};

const statusColor: Record<Invitation['status'], 'default' | 'success' | 'warning' | 'error'> = {
  pending: 'warning',
  accepted: 'success',
  expired: 'default',
  revoked: 'error',
};

export default function InviteMember() {
  const access = useTenantAdminAccess();

  const [email, setEmail] = useState('');
  const [modules, setModules] = useState<ModuleSelection>(emptyModuleSelection);
  const [financeRole, setFinanceRole] = useState<(typeof FINANCE_ROLES)[number]>('');
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [saveNotice, setSaveNotice] = useState<string | null>(null);

  const [invitations, setInvitations] = useState<Invitation[]>([]);
  const [loadingInvites, setLoadingInvites] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);

  const [actionError, setActionError] = useState<string | null>(null);
  const [actionNotice, setActionNotice] = useState<string | null>(null);
  const [rowActionId, setRowActionId] = useState<string | null>(null);
  const [revokeTarget, setRevokeTarget] = useState<Invitation | null>(null);

  const loadInvitations = useCallback(async () => {
    setLoadingInvites(true);
    setLoadError(null);
    const { data, error } = await supabase
      .from('invitations')
      .select('id, email, role_bundle, modules_and_roles, finance_role, status, created_at')
      .order('created_at', { ascending: false });
    if (error) setLoadError(error.message);
    else setInvitations((data ?? []) as Invitation[]);
    setLoadingInvites(false);
  }, []);

  useEffect(() => {
    if (access?.isAdmin) loadInvitations();
  }, [access?.isAdmin, loadInvitations]);

  const handleResend = async (invitation: Invitation) => {
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

  const toggleModule = (module: (typeof ALL_MODULES)[number]) => {
    setModules((v) => ({ ...v, [module]: { ...v[module], checked: !v[module].checked } }));
  };

  const setModuleRole = (module: (typeof ALL_MODULES)[number], role: (typeof ROLES)[number]) => {
    setModules((v) => ({ ...v, [module]: { ...v[module], role } }));
  };

  const send = async () => {
    setSaveError(null);
    setSaveNotice(null);

    const trimmedEmail = email.trim();
    if (!trimmedEmail) {
      setSaveError('Email is required.');
      return;
    }

    const modulesAndRoles = ALL_MODULES.filter((m) => modules[m].checked).map((m) => ({
      module: m,
      role: modules[m].role,
    }));
    if (modulesAndRoles.length === 0 && !financeRole) {
      setSaveError('Select at least one module, or grant finance access.');
      return;
    }
    if (!access?.tenantId) {
      setSaveError('Could not determine your tenant — try reloading the page.');
      return;
    }

    setSaving(true);
    const { error } = await supabase.functions.invoke('invite-user', {
      body: {
        email: trimmedEmail,
        tenant_id: access.tenantId,
        role_bundle: 'member',
        // invite-user requires a non-empty modules_and_roles array for
        // member invites, so a finance-only invite still needs to pass
        // something -- an empty array reads clearly as "no modules" once
        // the finance grant is the only access being given.
        modules_and_roles: modulesAndRoles.length > 0 ? modulesAndRoles : undefined,
        finance_role: financeRole || null,
      },
    });
    setSaving(false);

    if (error) {
      setSaveError(error.message);
      return;
    }

    setSaveNotice(`Invite sent to ${trimmedEmail}.`);
    setEmail('');
    setModules(emptyModuleSelection);
    setFinanceRole('');
    loadInvitations();
  };

  if (access?.isAdmin === false) {
    return (
      <Alert severity="warning" sx={{ maxWidth: 600, mx: 'auto', mt: 4 }}>
        Inviting teammates is only available to company admins.
      </Alert>
    );
  }

  return (
    <Box sx={{ maxWidth: 900 }}>
      <Typography variant="h5" sx={{ mb: 1 }}>
        Invite a teammate
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        They'll get an email invite. Pick which modules they get access to, and what role in
        each.
      </Typography>

      <Paper variant="outlined" sx={{ p: 3, mb: 4 }}>
        <Stack spacing={2.5}>
          <TextField
            label="Email"
            type="email"
            fullWidth
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            disabled={saving}
          />

          <Stack spacing={1.5}>
            {ALL_MODULES.map((module) => (
              <Stack key={module} direction="row" spacing={2} alignItems="center">
                <FormControlLabel
                  sx={{ minWidth: 220 }}
                  control={
                    <Checkbox
                      checked={modules[module].checked}
                      onChange={() => toggleModule(module)}
                      disabled={saving}
                    />
                  }
                  label={MODULE_LABELS[module]}
                />
                <TextField
                  select
                  size="small"
                  label="Role"
                  value={modules[module].role}
                  onChange={(e) => setModuleRole(module, e.target.value as (typeof ROLES)[number])}
                  disabled={!modules[module].checked || saving}
                  sx={{ width: 160 }}
                >
                  {ROLES.map((role) => (
                    <MenuItem key={role} value={role}>
                      {role}
                    </MenuItem>
                  ))}
                </TextField>
              </Stack>
            ))}
          </Stack>

          <TextField
            select
            size="small"
            label="Finance access"
            value={financeRole}
            onChange={(e) => setFinanceRole(e.target.value as (typeof FINANCE_ROLES)[number])}
            disabled={saving}
            helperText="Separate from the modules above — controls invoices, cash/bank, petty cash, and related admin screens."
            sx={{ width: 320 }}
          >
            {FINANCE_ROLES.map((role) => (
              <MenuItem key={role} value={role}>
                {FINANCE_ROLE_LABELS[role]}
              </MenuItem>
            ))}
          </TextField>

          {saveError && <Alert severity="error">{saveError}</Alert>}
          {saveNotice && <Alert severity="success">{saveNotice}</Alert>}

          <Box>
            <Button variant="contained" onClick={send} disabled={saving}>
              {saving ? 'Sending…' : 'Send invite'}
            </Button>
          </Box>
        </Stack>
      </Paper>

      <Typography variant="h6" sx={{ mb: 1 }}>
        Invitations for your company
      </Typography>

      {loadError && <Alert severity="error" sx={{ mb: 2 }}>{loadError}</Alert>}
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
                  <TableCell>Modules</TableCell>
                  <TableCell>Status</TableCell>
                  <TableCell>Sent</TableCell>
                  <TableCell align="right">Actions</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {invitations.map((inv) => (
                  <TableRow key={inv.id} hover>
                    <TableCell>{inv.email}</TableCell>
                    <TableCell>
                      {inv.role_bundle === 'company_admin'
                        ? 'All modules + Finance (admin)'
                        : [
                            ...(inv.modules_and_roles ?? []).map(
                              (mr) => `${MODULE_LABELS[mr.module as (typeof ALL_MODULES)[number]] ?? mr.module} (${mr.role})`
                            ),
                            ...(inv.finance_role ? [FINANCE_ROLE_LABELS[inv.finance_role]] : []),
                          ].join(', ') || '—'}
                    </TableCell>
                    <TableCell>
                      <Chip size="small" label={inv.status} color={statusColor[inv.status]} />
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
                ))}
                {invitations.length === 0 && (
                  <TableRow>
                    <TableCell colSpan={5} align="center" sx={{ color: 'text.secondary', py: 3 }}>
                      No invitations sent yet.
                    </TableCell>
                  </TableRow>
                )}
              </TableBody>
            </Table>
          </TableContainer>
        )}
      </Paper>

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