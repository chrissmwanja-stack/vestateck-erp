import { useCallback, useEffect, useState, SyntheticEvent } from 'react';
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
  Tab,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  Tabs,
  TextField,
  Typography,
} from '@mui/material';
import { Add as AddIcon } from '@mui/icons-material';
import { supabase } from '../../lib/supabaseClient';
import { useAuth } from '../../lib/authContext';
import { resolveTenantId } from '../../lib/ResolveTenantId';

interface LookupRow {
  id: string;
  code: string;
  name: string;
  is_active: boolean;
}

const emptyForm = { code: '', name: '', is_active: true };

// Backs the three dropdowns on the New Material Request form and the
// Material Request Report filters. Reads are open to every tenant member
// (the request form needs them); writes are gated to has_po_access() at
// the RLS level, matching every other Purchasing & Logistics admin screen.
function usePoAccess() {
  const [hasAccess, setHasAccess] = useState<boolean | null>(null);
  useEffect(() => {
    let cancelled = false;
    supabase.rpc('am_i_finance').then(({ data, error }) => {
      // am_i_finance() wraps has_po_access() -- same underlying check used
      // to gate every other Purchasing & Logistics admin action.
      if (cancelled) return;
      setHasAccess(error ? false : Boolean(data));
    });
    return () => {
      cancelled = true;
    };
  }, []);
  return hasAccess;
}

const TABLES = ['material_types', 'material_groups', 'external_material_groups'] as const;
type TableName = (typeof TABLES)[number];

const TAB_LABELS: Record<TableName, string> = {
  material_types: 'Material Types',
  material_groups: 'Goods Groups',
  external_material_groups: 'External Goods Groups',
};

function LookupTable({ table, canEdit }: { table: TableName; canEdit: boolean }) {
  const { session } = useAuth();
  const [rows, setRows] = useState<LookupRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [dialogOpen, setDialogOpen] = useState(false);
  const [editTarget, setEditTarget] = useState<LookupRow | null>(null);
  const [form, setForm] = useState(emptyForm);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const { data, error: err } = await supabase.from(table).select('id, code, name, is_active').order('code');
    if (err) setError(err.message);
    else setRows((data ?? []) as LookupRow[]);
    setLoading(false);
  }, [table]);

  useEffect(() => {
    load();
  }, [load]);

  const openNew = () => {
    setEditTarget(null);
    setForm(emptyForm);
    setSaveError(null);
    setDialogOpen(true);
  };

  const openEdit = (row: LookupRow) => {
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
    const payload = { code: form.code.trim(), name: form.name.trim(), is_active: form.is_active };
    // tenant_id is `uuid NOT NULL` with no column default on all three of
    // these tables. Each has a BEFORE INSERT trigger, but Postgres
    // coerces insert values to their column type before any row-level
    // trigger runs -- a placeholder '' fails outright regardless of the
    // trigger. Resolve the real tenant_id client-side instead, only on
    // create (edit never touches tenant_id, since a row's tenant never
    // changes after creation).
    let err;
    if (editTarget) {
      ({ error: err } = await supabase.from(table).update(payload).eq('id', editTarget.id));
    } else {
      const tenantResult = await resolveTenantId(session);
      if (tenantResult.error) {
        setSaving(false);
        setSaveError(tenantResult.error);
        return;
      }
      ({ error: err } = await supabase.from(table).insert({ ...payload, tenant_id: tenantResult.tenantId }));
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
    <Box sx={{ pt: 2 }}>
      <Stack direction="row" justifyContent="flex-end" sx={{ mb: 2 }}>
        {canEdit && (
          <Button variant="contained" size="small" startIcon={<AddIcon />} onClick={openNew}>
            New
          </Button>
        )}
      </Stack>

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
                  {canEdit && <TableCell align="right">Actions</TableCell>}
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
                    {canEdit && (
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
                    <TableCell colSpan={canEdit ? 4 : 3} align="center" sx={{ color: 'text.secondary', py: 3 }}>
                      Nothing here yet.
                    </TableCell>
                  </TableRow>
                )}
              </TableBody>
            </Table>
          </TableContainer>
        )}
      </Paper>

      <Dialog open={dialogOpen} onClose={close} maxWidth="sm" fullWidth>
        <DialogTitle>
          {editTarget ? 'Edit' : 'New'} {TAB_LABELS[table].replace(/s$/, '')}
        </DialogTitle>
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

export default function MaterialLookupsAdmin() {
  const hasAccess = usePoAccess();
  const [tab, setTab] = useState<TableName>('material_types');

  const handleTabChange = (_: SyntheticEvent, value: TableName) => setTab(value);

  return (
    <Box sx={{ maxWidth: 900 }}>
      <Typography variant="h5" sx={{ mb: 1 }}>
        Material Classification
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        Controlled lists used on the New Material Request form and the Material Request Report filters.
      </Typography>

      <Tabs value={tab} onChange={handleTabChange} sx={{ mb: 1 }}>
        {TABLES.map((t) => (
          <Tab key={t} value={t} label={TAB_LABELS[t]} />
        ))}
      </Tabs>

      <LookupTable table={tab} canEdit={!!hasAccess} />
    </Box>
  );
}