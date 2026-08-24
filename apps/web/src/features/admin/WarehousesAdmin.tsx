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
import { resolveTenantId } from '../../lib/ResolveTenantId';

interface DepartmentOption {
  id: string;
  name: string;
}

interface WarehouseRow {
  id: string;
  name: string;
  code: string | null;
  project_label: string | null;
  department_id: string | null;
  department_name: string | null;
  is_active: boolean;
  created_at: string;
}

const emptyForm = { name: '', code: '', project_label: '', department_id: '', is_active: true };

// Same authority as MaterialLookupsAdmin.tsx / cost codes: reads are open
// to every tenant member (Material Quantity and Goods Issue both need the
// warehouse list), writes gated to Finance -- warehouses are created
// deliberately (one per project/site), not self-service.
function useFinanceAccess() {
  const [isFinance, setIsFinance] = useState<boolean | null>(null);
  useEffect(() => {
    supabase.rpc('am_i_finance').then(({ data, error }) => setIsFinance(error ? false : Boolean(data)));
  }, []);
  return isFinance;
}

export default function WarehousesAdmin() {
  const isFinance = useFinanceAccess();
  const { session } = useAuth();
  const [rows, setRows] = useState<WarehouseRow[]>([]);
  const [departments, setDepartments] = useState<DepartmentOption[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [dialogOpen, setDialogOpen] = useState(false);
  const [editTarget, setEditTarget] = useState<WarehouseRow | null>(null);
  const [form, setForm] = useState(emptyForm);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const { data, error: err } = await supabase
      .from('warehouses')
      .select('id, name, code, project_label, department_id, is_active, created_at, department:department_id(name)')
      .order('created_at', { ascending: false });
    if (err) {
      setError(err.message);
    } else {
      setRows(
        ((data ?? []) as any[]).map((r) => ({
          id: r.id,
          name: r.name,
          code: r.code,
          project_label: r.project_label,
          department_id: r.department_id,
          department_name: r.department?.name ?? null,
          is_active: r.is_active,
          created_at: r.created_at,
        }))
      );
    }
    setLoading(false);
  }, []);

  useEffect(() => {
    load();
    supabase
      .from('departments')
      .select('id, name')
      .eq('is_active', true)
      .order('name')
      .then(({ data }) => setDepartments((data ?? []) as DepartmentOption[]));
  }, [load]);

  const openNew = () => {
    setEditTarget(null);
    setForm(emptyForm);
    setSaveError(null);
    setDialogOpen(true);
  };

  const openEdit = (row: WarehouseRow) => {
    setEditTarget(row);
    setForm({
      name: row.name,
      code: row.code ?? '',
      project_label: row.project_label ?? '',
      department_id: row.department_id ?? '',
      is_active: row.is_active,
    });
    setSaveError(null);
    setDialogOpen(true);
  };

  const close = () => {
    if (!saving) setDialogOpen(false);
  };

  const save = async () => {
    if (!form.name.trim()) {
      setSaveError('Name is required.');
      return;
    }
    setSaveError(null);
    setSaving(true);
    const payload = {
      name: form.name.trim(),
      code: form.code.trim() || null,
      project_label: form.project_label.trim() || null,
      department_id: form.department_id || null,
      is_active: form.is_active,
    };
    let err;
    if (editTarget) {
      ({ error: err } = await supabase.from('warehouses').update(payload).eq('id', editTarget.id));
    } else {
      // tenant_id is `uuid NOT NULL` with no column default. A BEFORE
      // INSERT trigger exists, but Postgres coerces insert values to
      // their column type before any row-level trigger runs -- resolve
      // the real tenant_id client-side instead of sending a placeholder.
      const tenantResult = await resolveTenantId(session);
      if (!tenantResult.ok) {
        setSaving(false);
        setSaveError(tenantResult.error);
        return;
      }
      ({ error: err } = await supabase.from('warehouses').insert({ ...payload, tenant_id: tenantResult.tenantId }));
    }
    setSaving(false);
    if (err) {
      setSaveError(err.message.includes('duplicate key') ? `Code "${form.code}" is already in use.` : err.message);
      return;
    }
    setDialogOpen(false);
    load();
  };

  return (
    <Box sx={{ maxWidth: 900 }}>
      <Stack direction="row" justifyContent="space-between" alignItems="center" sx={{ mb: 1 }}>
        <Typography variant="h5">Warehouses</Typography>
        {isFinance && (
          <Button variant="contained" size="small" startIcon={<AddIcon />} onClick={openNew}>
            New warehouse
          </Button>
        )}
      </Stack>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        One warehouse per project/site. Used by both the goods-receipt (Material Quantity) and goods-issue screens,
        and everything stock-related is tracked per warehouse.
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
                  <TableCell>Code</TableCell>
                  <TableCell>Project / Site</TableCell>
                  <TableCell>Department</TableCell>
                  <TableCell>Status</TableCell>
                  {isFinance && <TableCell align="right">Actions</TableCell>}
                </TableRow>
              </TableHead>
              <TableBody>
                {rows.map((row) => (
                  <TableRow key={row.id} hover>
                    <TableCell>{row.name}</TableCell>
                    <TableCell>{row.code ?? '—'}</TableCell>
                    <TableCell>{row.project_label ?? '—'}</TableCell>
                    <TableCell>{row.department_name ?? '—'}</TableCell>
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
                    <TableCell colSpan={isFinance ? 6 : 5} align="center" sx={{ color: 'text.secondary', py: 3 }}>
                      No warehouses yet.
                    </TableCell>
                  </TableRow>
                )}
              </TableBody>
            </Table>
          </TableContainer>
        )}
      </Paper>

      <Dialog open={dialogOpen} onClose={close} maxWidth="sm" fullWidth>
        <DialogTitle>{editTarget ? 'Edit' : 'New'} Warehouse</DialogTitle>
        <DialogContent>
          <Stack spacing={2} sx={{ mt: 1 }}>
            <TextField label="Name" fullWidth value={form.name} onChange={(e) => setForm((v) => ({ ...v, name: e.target.value }))} />
            <TextField label="Code (optional)" fullWidth value={form.code} onChange={(e) => setForm((v) => ({ ...v, code: e.target.value }))} />
            <TextField
              label="Project / Site (optional)"
              fullWidth
              value={form.project_label}
              onChange={(e) => setForm((v) => ({ ...v, project_label: e.target.value }))}
            />
            <TextField
              select
              label="Department (optional)"
              fullWidth
              value={form.department_id}
              onChange={(e) => setForm((v) => ({ ...v, department_id: e.target.value }))}
              SelectProps={{ native: true }}
            >
              <option value="" />
              {departments.map((d) => (
                <option key={d.id} value={d.id}>
                  {d.name}
                </option>
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