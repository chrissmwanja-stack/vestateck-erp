import { useCallback, useEffect, useMemo, useState } from 'react';
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
  MenuItem,
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

interface Department {
  id: string;
  name: string;
  parent_department_id: string | null;
  is_active: boolean;
}

const emptyForm = { name: '', parent_department_id: '', is_active: true };

// Unlike organizations/account_categories, departments_select_tenant is
// open to every tenant member (any requester needs to see the list to pick
// their department) -- only insert/update/delete are Finance-gated. So
// this screen shows the read-only table to everyone, and only hides the
// New/Edit actions from non-Finance users.
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

export default function DepartmentsAdmin() {
  const isFinance = useFinanceAccess();
  const [rows, setRows] = useState<Department[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [dialogOpen, setDialogOpen] = useState(false);
  const [editTarget, setEditTarget] = useState<Department | null>(null);
  const [form, setForm] = useState(emptyForm);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const { data, error: err } = await supabase
      .from('departments')
      .select('id, name, parent_department_id, is_active')
      .order('name');
    if (err) setError(err.message);
    else setRows((data ?? []) as Department[]);
    setLoading(false);
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const nameById = useMemo(() => new Map(rows.map((r) => [r.id, r.name])), [rows]);

  const openNew = () => {
    setEditTarget(null);
    setForm(emptyForm);
    setSaveError(null);
    setDialogOpen(true);
  };

  const openEdit = (row: Department) => {
    setEditTarget(row);
    setForm({ name: row.name, parent_department_id: row.parent_department_id ?? '', is_active: row.is_active });
    setSaveError(null);
    setDialogOpen(true);
  };

  const close = () => {
    if (!saving) setDialogOpen(false);
  };

  const save = async () => {
    setSaveError(null);
    if (!form.name.trim()) {
      setSaveError('Name is required.');
      return;
    }
    if (editTarget && form.parent_department_id === editTarget.id) {
      setSaveError('A department cannot be its own parent.');
      return;
    }
    setSaving(true);
    const payload = {
      name: form.name.trim(),
      parent_department_id: form.parent_department_id || null,
      is_active: form.is_active,
    };
    const { error: err } = editTarget
      ? await supabase.from('departments').update(payload).eq('id', editTarget.id)
      : await supabase.from('departments').insert(payload);
    setSaving(false);
    if (err) {
      setSaveError(err.message);
      return;
    }
    setDialogOpen(false);
    load();
  };

  return (
    <Box sx={{ maxWidth: 900 }}>
      <Stack direction="row" justifyContent="space-between" alignItems="center" sx={{ mb: 2 }}>
        <Typography variant="h5">Departments</Typography>
        {isFinance && (
          <Button variant="contained" startIcon={<AddIcon />} onClick={openNew}>
            New Department
          </Button>
        )}
      </Stack>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        Departments used for request routing and approvals. Everyone in the tenant can see this list; only
        Finance can add or edit.
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
                  <TableCell>Name</TableCell>
                  <TableCell>Parent Department</TableCell>
                  <TableCell>Status</TableCell>
                  {isFinance && <TableCell align="right">Actions</TableCell>}
                </TableRow>
              </TableHead>
              <TableBody>
                {rows.map((row) => (
                  <TableRow key={row.id} hover>
                    <TableCell>{row.name}</TableCell>
                    <TableCell>
                      {row.parent_department_id ? nameById.get(row.parent_department_id) ?? '—' : '—'}
                    </TableCell>
                    <TableCell>
                      <Chip size="small" label={row.is_active ? 'Active' : 'Inactive'} color={row.is_active ? 'success' : 'default'} />
                    </TableCell>
                    {isFinance && (
                      <TableCell align="right">
                        <Button size="small" onClick={() => openEdit(row)}>
                          Edit
                        </Button>
                      </TableCell>
                    )}
                  </TableRow>
                ))}
                {rows.length === 0 && (
                  <TableRow>
                    <TableCell colSpan={isFinance ? 4 : 3} align="center" sx={{ color: 'text.secondary', py: 3 }}>
                      No departments yet.
                    </TableCell>
                  </TableRow>
                )}
              </TableBody>
            </Table>
          </TableContainer>
        )}
      </Paper>

      <Dialog open={dialogOpen} onClose={close} maxWidth="sm" fullWidth>
        <DialogTitle>{editTarget ? 'Edit Department' : 'New Department'}</DialogTitle>
        <DialogContent>
          <Stack spacing={2} sx={{ mt: 1 }}>
            <TextField label="Name" fullWidth value={form.name} onChange={(e) => setForm((v) => ({ ...v, name: e.target.value }))} />
            <TextField
              select
              label="Parent Department"
              fullWidth
              value={form.parent_department_id}
              onChange={(e) => setForm((v) => ({ ...v, parent_department_id: e.target.value }))}
            >
              <MenuItem value="">None (top-level)</MenuItem>
              {rows
                .filter((r) => !editTarget || r.id !== editTarget.id)
                .map((r) => (
                  <MenuItem key={r.id} value={r.id}>
                    {r.name}
                  </MenuItem>
                ))}
            </TextField>
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