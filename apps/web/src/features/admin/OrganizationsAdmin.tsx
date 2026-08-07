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
  FormControlLabel,
  Paper,
  Stack,
  Switch,
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

interface Organization {
  id: string;
  company_code: string;
  site_name: string;
  is_active: boolean;
}

const emptyForm = { company_code: '', site_name: '', is_active: true };

// Read/write are both Finance-only server-side (organizations_select /
// organizations_insert / organizations_update all require
// is_finance_team_member(...)). This client check just keeps the screen
// itself from being shown to people who'd fail every call on it -- same
// pattern as ProcurementTrack.tsx / CostCodeListNew.tsx.
function useFinanceAccess() {
  const [isFinance, setIsFinance] = useState<boolean | null>(null);
  useEffect(() => {
    let cancelled = false;
    supabase.rpc('am_i_finance').then(({ data, error }) => {
      if (cancelled) return;
      setIsFinance(error ? false : Boolean(data));
    });
    return () => {
      cancelled = true;
    };
  }, []);
  return isFinance;
}

export default function OrganizationsAdmin() {
  const isFinance = useFinanceAccess();
  const [rows, setRows] = useState<Organization[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [dialogOpen, setDialogOpen] = useState(false);
  const [editTarget, setEditTarget] = useState<Organization | null>(null);
  const [form, setForm] = useState(emptyForm);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const { data, error: err } = await supabase
      .from('organizations')
      .select('id, company_code, site_name, is_active')
      .order('company_code');
    if (err) setError(err.message);
    else setRows((data ?? []) as Organization[]);
    setLoading(false);
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const openNew = () => {
    setEditTarget(null);
    setForm(emptyForm);
    setSaveError(null);
    setDialogOpen(true);
  };

  const openEdit = (row: Organization) => {
    setEditTarget(row);
    setForm({ company_code: row.company_code, site_name: row.site_name, is_active: row.is_active });
    setSaveError(null);
    setDialogOpen(true);
  };

  const close = () => {
    if (!saving) setDialogOpen(false);
  };

  const save = async () => {
    setSaveError(null);
    if (!form.company_code.trim() || !form.site_name.trim()) {
      setSaveError('Company code and site name are required.');
      return;
    }
    setSaving(true);
    const payload = {
      company_code: form.company_code.trim(),
      site_name: form.site_name.trim(),
      is_active: form.is_active,
    };
    const { error: err } = editTarget
      ? await supabase.from('organizations').update(payload).eq('id', editTarget.id)
      : await supabase.from('organizations').insert(payload);
    setSaving(false);
    if (err) {
      setSaveError(
        err.message.includes('duplicate key') ? `Company code "${form.company_code}" is already in use.` : err.message
      );
      return;
    }
    setDialogOpen(false);
    load();
  };

  if (isFinance === false) {
    return (
      <Alert severity="warning" sx={{ maxWidth: 600, mx: 'auto', mt: 4 }}>
        Organizations (company codes / sites) are managed by Finance.
      </Alert>
    );
  }

  return (
    <Box sx={{ maxWidth: 900 }}>
      <Stack direction="row" justifyContent="space-between" alignItems="center" sx={{ mb: 2 }}>
        <Typography variant="h5">Organizations</Typography>
        <Button variant="contained" startIcon={<AddIcon />} onClick={openNew}>
          New Organization
        </Button>
      </Stack>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        Company codes and sites used across invoices, expenditure slips, and OIF numbering.
      </Typography>

      {error && <Alert severity="error" sx={{ mb: 2 }}>{error}</Alert>}

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
                  <TableCell>Company Code</TableCell>
                  <TableCell>Site Name</TableCell>
                  <TableCell>Status</TableCell>
                  <TableCell align="right">Actions</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {rows.map((row) => (
                  <TableRow key={row.id} hover>
                    <TableCell>{row.company_code}</TableCell>
                    <TableCell>{row.site_name}</TableCell>
                    <TableCell>
                      <Chip size="small" label={row.is_active ? 'Active' : 'Inactive'} color={row.is_active ? 'success' : 'default'} />
                    </TableCell>
                    <TableCell align="right">
                      <Button size="small" onClick={() => openEdit(row)}>
                        Edit
                      </Button>
                    </TableCell>
                  </TableRow>
                ))}
                {rows.length === 0 && (
                  <TableRow>
                    <TableCell colSpan={4} align="center" sx={{ color: 'text.secondary', py: 3 }}>
                      No organizations yet.
                    </TableCell>
                  </TableRow>
                )}
              </TableBody>
            </Table>
          </TableContainer>
        )}
      </Paper>

      <Dialog open={dialogOpen} onClose={close} maxWidth="sm" fullWidth>
        <DialogTitle>{editTarget ? 'Edit Organization' : 'New Organization'}</DialogTitle>
        <DialogContent>
          <Stack spacing={2} sx={{ mt: 1 }}>
            <TextField
              label="Company Code"
              fullWidth
              value={form.company_code}
              onChange={(e) => setForm((v) => ({ ...v, company_code: e.target.value }))}
            />
            <TextField
              label="Site Name"
              fullWidth
              value={form.site_name}
              onChange={(e) => setForm((v) => ({ ...v, site_name: e.target.value }))}
            />
            <FormControlLabel
              control={
                <Switch checked={form.is_active} onChange={(e) => setForm((v) => ({ ...v, is_active: e.target.checked }))} />
              }
              label="Active"
            />
            {saveError && <Alert severity="error">{saveError}</Alert>}
          </Stack>
        </DialogContent>
        <DialogActions>
          <Button onClick={close} disabled={saving}>
            Cancel
          </Button>
          <Button onClick={save} variant="contained" disabled={saving}>
            {saving ? 'Saving…' : 'Save'}
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}