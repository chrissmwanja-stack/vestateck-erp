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
import { useAuth } from '../../lib/authContext';

interface AccountCategory {
  id: string;
  code: string;
  name: string;
  is_active: boolean;
  tenant_id?: string;
}

const emptyForm = { code: '', name: '', is_active: true };

// Same shape as OrganizationsAdmin.tsx: read/write are Finance-only via RLS
// (account_categories_select / _insert / _update), this just keeps the
// form from being shown to people who'd fail every call on it.
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

export default function AccountCategoriesAdmin() {
  const isFinance = useFinanceAccess();
  const { session } = useAuth();
  const [rows, setRows] = useState<AccountCategory[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [dialogOpen, setDialogOpen] = useState(false);
  const [editTarget, setEditTarget] = useState<AccountCategory | null>(null);
  const [form, setForm] = useState(emptyForm);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const { data, error: err } = await supabase
      .from('account_categories')
      .select('id, code, name, is_active, tenant_id')
      .order('code');
    if (err) setError(err.message);
    else setRows((data ?? []) as AccountCategory[]);
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

  const openEdit = (row: AccountCategory) => {
    setEditTarget(row);
    setForm({ code: row.code, name: row.name, is_active: row.is_active });
    setSaveError(null);
    setDialogOpen(true);
  };

  const close = () => {
    if (!saving) setDialogOpen(false);
  };

  const save = async () => {
    setSaveError(null);
    if (!form.code.trim() || !form.name.trim()) {
      setSaveError('Code and name are required.');
      return;
    }
    setSaving(true);
    const payload: any = { code: form.code.trim(), name: form.name.trim(), is_active: form.is_active };
    let err;
    if (editTarget) {
      ({ error: err } = await supabase.from('account_categories').update(payload).eq('id', editTarget.id));
    } else {
      const tenant_id = (session?.user?.user_metadata as any)?.tenant_id || rows[0]?.tenant_id;
      if (tenant_id) payload.tenant_id = tenant_id;
      ({ error: err } = await supabase.from('account_categories').insert(payload));
    }
    setSaving(false);
    if (err) {
      setSaveError(err.message.includes('duplicate key') ? `Code "${form.code}" is already in use.` : err.message);
      return;
    }
    setDialogOpen(false);
    load();
  };

  if (isFinance === false) {
    return (
      <Alert severity="warning" sx={{ maxWidth: 600, mx: 'auto', mt: 4 }}>
        Account categories are managed by Finance.
      </Alert>
    );
  }

  return (
    <Box sx={{ maxWidth: 900 }}>
      <Stack direction="row" justifyContent="space-between" alignItems="center" sx={{ mb: 2 }}>
        <Typography variant="h5">Account Categories</Typography>
        <Button variant="contained" startIcon={<AddIcon />} onClick={openNew}>
          New Category
        </Button>
      </Stack>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        Groupings used to categorize vendor and client accounts.
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
                  <TableCell>Code</TableCell>
                  <TableCell>Name</TableCell>
                  <TableCell>Status</TableCell>
                  <TableCell align="right">Actions</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {rows.map((row) => (
                  <TableRow key={row.id} hover>
                    <TableCell>{row.code}</TableCell>
                    <TableCell>{row.name}</TableCell>
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
                      No account categories yet.
                    </TableCell>
                  </TableRow>
                )}
              </TableBody>
            </Table>
          </TableContainer>
        )}
      </Paper>

      <Dialog open={dialogOpen} onClose={close} maxWidth="sm" fullWidth>
        <DialogTitle>{editTarget ? 'Edit Category' : 'New Category'}</DialogTitle>
        <DialogContent>
          <Stack spacing={2} sx={{ mt: 1 }}>
            <TextField label="Code" fullWidth value={form.code} onChange={(e) => setForm((v) => ({ ...v, code: e.target.value }))} />
            <TextField label="Name" fullWidth value={form.name} onChange={(e) => setForm((v) => ({ ...v, name: e.target.value }))} />
            <FormControlLabel
              control={<Switch checked={form.is_active} onChange={(e) => setForm((v) => ({ ...v, is_active: e.target.checked }))} />}
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