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

interface LookupOption {
  id: string;
  code: string;
  name: string;
}

interface MaterialCatalogRow {
  id: string;
  code: string | null;
  name: string;
  unit: string | null;
  old_material_code: string | null;
  material_type_id: string | null;
  material_type_name: string | null;
  material_group_id: string | null;
  material_group_name: string | null;
  is_active: boolean;
  created_at: string;
}

const emptyForm = {
  code: '',
  name: '',
  unit: '',
  old_material_code: '',
  material_type_id: '',
  material_group_id: '',
  is_active: true,
};

// Same authority as WarehousesAdmin / MaterialLookupsAdmin: reads are open
// to every tenant member (the New Material Request form and the Request
// Tracking / Report screens both need the catalog), writes gated to
// has_po_access() at the RLS level -- see
// 20260822120000_material_catalog_insert_policy.sql for INSERT and the
// squashed baseline's material_catalog_update for UPDATE.
function usePoAccess() {
  const [hasAccess, setHasAccess] = useState<boolean | null>(null);
  useEffect(() => {
    let cancelled = false;
    supabase.rpc('am_i_finance').then(({ data, error }) => {
      if (cancelled) return;
      setHasAccess(error ? false : Boolean(data));
    });
    return () => {
      cancelled = true;
    };
  }, []);
  return hasAccess;
}

export default function MaterialCatalogAdmin() {
  const hasAccess = usePoAccess();
  const { session } = useAuth();
  const [rows, setRows] = useState<MaterialCatalogRow[]>([]);
  const [types, setTypes] = useState<LookupOption[]>([]);
  const [groups, setGroups] = useState<LookupOption[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [dialogOpen, setDialogOpen] = useState(false);
  const [editTarget, setEditTarget] = useState<MaterialCatalogRow | null>(null);
  const [form, setForm] = useState(emptyForm);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const { data, error: err } = await supabase
      .from('material_catalog')
      .select(
        'id, code, name, unit, old_material_code, is_active, created_at, material_type_id, material_group_id, material_type:material_type_id(name), material_group:material_group_id(name)'
      )
      .order('created_at', { ascending: false });
    if (err) {
      setError(err.message);
    } else {
      setRows(
        ((data ?? []) as any[]).map((r) => ({
          id: r.id,
          code: r.code,
          name: r.name,
          unit: r.unit,
          old_material_code: r.old_material_code,
          material_type_id: r.material_type_id,
          material_type_name: r.material_type?.name ?? null,
          material_group_id: r.material_group_id,
          material_group_name: r.material_group?.name ?? null,
          is_active: r.is_active,
          created_at: r.created_at,
        }))
      );
    }
    setLoading(false);
  }, []);

  useEffect(() => {
    load();
    Promise.all([
      supabase.from('material_types').select('id, code, name').eq('is_active', true).order('code'),
      supabase.from('material_groups').select('id, code, name').eq('is_active', true).order('code'),
    ]).then(([t, g]) => {
      setTypes((t.data ?? []) as LookupOption[]);
      setGroups((g.data ?? []) as LookupOption[]);
    });
  }, [load]);

  const openNew = () => {
    setEditTarget(null);
    setForm(emptyForm);
    setSaveError(null);
    setDialogOpen(true);
  };

  const openEdit = (row: MaterialCatalogRow) => {
    setEditTarget(row);
    setForm({
      code: row.code ?? '',
      name: row.name,
      unit: row.unit ?? '',
      old_material_code: row.old_material_code ?? '',
      material_type_id: row.material_type_id ?? '',
      material_group_id: row.material_group_id ?? '',
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

    // tenant_id is required by the generated Insert type, has no default,
    // and -- as of the 2026-08-19 migration squash -- no trigger fills it
    // either (see 20260822120000_material_catalog_insert_policy.sql for the
    // history). Resolve it client-side on create, same pattern as
    // AccountsAdmin.tsx / EmployeesList.tsx use for their own no-default
    // tenant_id columns, rather than relying on server-side infrastructure
    // that isn't actually there right now.
    let tenant_id: string | undefined;
    if (!editTarget) {
      const userId = session?.user?.id;
      if (!userId) {
        setSaveError('Could not determine your session. Please refresh and try again.');
        setSaving(false);
        return;
      }
      const { data: appUser, error: appUserErr } = await supabase
        .from('app_users')
        .select('tenant_id')
        .eq('id', userId)
        .single();
      if (appUserErr || !appUser?.tenant_id) {
        setSaveError('Could not determine your organization. Please refresh and try again.');
        setSaving(false);
        return;
      }
      tenant_id = appUser.tenant_id;
    }

    const payload = {
      code: form.code.trim() || null,
      name: form.name.trim(),
      unit: form.unit.trim() || null,
      old_material_code: form.old_material_code.trim() || null,
      material_type_id: form.material_type_id || null,
      material_group_id: form.material_group_id || null,
      is_active: form.is_active,
    };
    const { error: err } = editTarget
      ? await supabase.from('material_catalog').update(payload).eq('id', editTarget.id)
      : await supabase.from('material_catalog').insert({ ...payload, tenant_id: tenant_id! });
    setSaving(false);
    if (err) {
      setSaveError(err.message.includes('duplicate key') ? `Code "${form.code}" is already in use.` : err.message);
      return;
    }
    setDialogOpen(false);
    load();
  };

  return (
    <Box sx={{ maxWidth: 1000 }}>
      <Stack direction="row" justifyContent="space-between" alignItems="center" sx={{ mb: 1 }}>
        <Typography variant="h5">Material Catalog</Typography>
        {hasAccess && (
          <Button variant="contained" size="small" startIcon={<AddIcon />} onClick={openNew}>
            New material
          </Button>
        )}
      </Stack>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        Standard materials referenced by request line items, goods issue, and stock balances. Deactivate rather than
        delete to keep historical stock and request records intact.
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
                  <TableCell>Unit</TableCell>
                  <TableCell>Type</TableCell>
                  <TableCell>Group</TableCell>
                  <TableCell>Status</TableCell>
                  {hasAccess && <TableCell align="right">Actions</TableCell>}
                </TableRow>
              </TableHead>
              <TableBody>
                {rows.map((row) => (
                  <TableRow key={row.id} hover>
                    <TableCell>{row.code ?? '—'}</TableCell>
                    <TableCell>{row.name}</TableCell>
                    <TableCell>{row.unit ?? '—'}</TableCell>
                    <TableCell>{row.material_type_name ?? '—'}</TableCell>
                    <TableCell>{row.material_group_name ?? '—'}</TableCell>
                    <TableCell>
                      <Chip size="small" label={row.is_active ? 'Active' : 'Inactive'} color={row.is_active ? 'success' : 'default'} />
                    </TableCell>
                    {hasAccess && (
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
                    <TableCell colSpan={hasAccess ? 7 : 6} align="center" sx={{ color: 'text.secondary', py: 3 }}>
                      No materials yet.
                    </TableCell>
                  </TableRow>
                )}
              </TableBody>
            </Table>
          </TableContainer>
        )}
      </Paper>

      <Dialog open={dialogOpen} onClose={close} maxWidth="sm" fullWidth>
        <DialogTitle>{editTarget ? 'Edit' : 'New'} Material</DialogTitle>
        <DialogContent>
          <Stack spacing={2} sx={{ mt: 1 }}>
            <TextField label="Name" fullWidth value={form.name} onChange={(e) => setForm((v) => ({ ...v, name: e.target.value }))} />
            <TextField label="Code (optional)" fullWidth value={form.code} onChange={(e) => setForm((v) => ({ ...v, code: e.target.value }))} />
            <TextField label="Unit (optional)" fullWidth value={form.unit} onChange={(e) => setForm((v) => ({ ...v, unit: e.target.value }))} />
            <TextField
              select
              label="Type (optional)"
              fullWidth
              value={form.material_type_id}
              onChange={(e) => setForm((v) => ({ ...v, material_type_id: e.target.value }))}
              SelectProps={{ native: true }}
            >
              <option value="" />
              {types.map((t) => (
                <option key={t.id} value={t.id}>
                  {t.code} — {t.name}
                </option>
              ))}
            </TextField>
            <TextField
              select
              label="Group (optional)"
              fullWidth
              value={form.material_group_id}
              onChange={(e) => setForm((v) => ({ ...v, material_group_id: e.target.value }))}
              SelectProps={{ native: true }}
            >
              <option value="" />
              {groups.map((g) => (
                <option key={g.id} value={g.id}>
                  {g.code} — {g.name}
                </option>
              ))}
            </TextField>
            <TextField
              label="Old material code (optional)"
              fullWidth
              value={form.old_material_code}
              onChange={(e) => setForm((v) => ({ ...v, old_material_code: e.target.value }))}
            />
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