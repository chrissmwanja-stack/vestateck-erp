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

interface Tenant {
  id: string;
  name: string;
  status: 'pending' | 'active' | 'suspended';
  created_at: string;
}

const statusColor: Record<Tenant['status'], 'default' | 'success' | 'warning'> = {
  pending: 'warning',
  active: 'success',
  suspended: 'default',
};

const emptyForm = { name: '', adminEmail: '' };

// Gate: only platform admins should see this screen at all. The real
// enforcement lives server-side (create-tenant / invite-user both check
// is_platform_admin), same pattern as useFinanceAccess in
// OrganizationsAdmin.tsx -- this is just so the screen doesn't render
// for people every call on it would fail for.
function usePlatformAdminAccess() {
  const [isPlatformAdmin, setIsPlatformAdmin] = useState<boolean | null>(null);
  useEffect(() => {
    let cancelled = false;
    supabase
      .from('app_users')
      .select('is_platform_admin')
      .single()
      .then(({ data, error }) => {
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

  useEffect(() => {
    load();
  }, [load]);

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
      // Don't lose that: close the form but surface it clearly, since
      // there's no "resend invite" action yet (see session notes,
      // section 5, "known gaps").
      setDialogOpen(false);
      setError(
        `"${name}" was created, but inviting ${adminEmail} failed: ${inviteError.message}. ` +
          'There is no resend-invite screen yet — retry via the invite-user edge function directly.'
      );
      load();
      return;
    }

    setDialogOpen(false);
    setSaveNotice(`"${name}" created and an invite sent to ${adminEmail}.`);
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
    </Box>
  );
}