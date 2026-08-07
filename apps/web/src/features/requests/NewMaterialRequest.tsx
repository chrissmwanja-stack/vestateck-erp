import { useEffect, useState } from 'react';
import {
  Alert,
  Box,
  Button,
  IconButton,
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
import { Add as AddIcon, Delete as DeleteIcon, Save as SaveIcon } from '@mui/icons-material';
import { supabase } from '../../lib/supabaseClient';

interface LookupOption {
  id: string;
  code: string;
  name: string;
}

interface DraftRow {
  key: string;
  material_type_id: string;
  material_group_id: string;
  external_material_group_id: string;
  unit: string;
  name: string;
  description_tr: string;
  description_en: string;
  description_fr: string;
  old_material_code: string;
}

const emptyRow = (): DraftRow => ({
  key: crypto.randomUUID(),
  material_type_id: '',
  material_group_id: '',
  external_material_group_id: '',
  unit: '',
  name: '',
  description_tr: '',
  description_en: '',
  description_fr: '',
  old_material_code: '',
});

function useLookups() {
  const [types, setTypes] = useState<LookupOption[]>([]);
  const [groups, setGroups] = useState<LookupOption[]>([]);
  const [externalGroups, setExternalGroups] = useState<LookupOption[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    (async () => {
      const [t, g, e] = await Promise.all([
        supabase.from('material_types').select('id, code, name').eq('is_active', true).order('code'),
        supabase.from('material_groups').select('id, code, name').eq('is_active', true).order('code'),
        supabase.from('external_material_groups').select('id, code, name').eq('is_active', true).order('code'),
      ]);
      setTypes((t.data ?? []) as LookupOption[]);
      setGroups((g.data ?? []) as LookupOption[]);
      setExternalGroups((e.data ?? []) as LookupOption[]);
      setLoading(false);
    })();
  }, []);

  return { types, groups, externalGroups, loading };
}

export default function NewMaterialRequest() {
  const { types, groups, externalGroups, loading } = useLookups();
  const [rows, setRows] = useState<DraftRow[]>([emptyRow()]);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);

  const addRow = () => setRows((r) => [...r, emptyRow()]);

  const removeSelected = () => {
    setRows((r) => (r.length <= 1 ? r : r.filter((row) => !selected.has(row.key))));
    setSelected(new Set());
  };

  const toggleSelected = (key: string) => {
    setSelected((s) => {
      const next = new Set(s);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      return next;
    });
  };

  const updateRow = (key: string, field: keyof DraftRow, value: string) => {
    setRows((r) => r.map((row) => (row.key === key ? { ...row, [field]: value } : row)));
  };

  const save = async () => {
    setError(null);
    setSuccess(null);

    const usableRows = rows.filter((r) => r.name.trim());
    if (usableRows.length === 0) {
      setError('Add at least one material with a name before saving.');
      return;
    }

    setSaving(true);

    const { data: batch, error: batchErr } = await supabase
      .from('material_request_batches')
      .insert({})
      .select('id')
      .single();

    if (batchErr || !batch) {
      setSaving(false);
      setError(batchErr?.message ?? 'Could not create the request batch.');
      return;
    }

    const payload = usableRows.map((r) => ({
      batch_id: batch.id,
      material_type_id: r.material_type_id || null,
      material_group_id: r.material_group_id || null,
      external_material_group_id: r.external_material_group_id || null,
      unit: r.unit.trim() || null,
      name: r.name.trim(),
      description_tr: r.description_tr.trim() || null,
      description_en: r.description_en.trim() || null,
      description_fr: r.description_fr.trim() || null,
      old_material_code: r.old_material_code.trim() || null,
    }));

    const { error: itemsErr } = await supabase.from('material_request_items').insert(payload);
    setSaving(false);

    if (itemsErr) {
      setError(itemsErr.message);
      return;
    }

    setSuccess(`Submitted ${payload.length} material${payload.length > 1 ? 's' : ''} for approval.`);
    setRows([emptyRow()]);
    setSelected(new Set());
  };

  return (
    <Box>
      <Typography variant="h5" sx={{ mb: 1 }}>
        New Material Request
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        Propose new materials to add to the catalog. Requests are reviewed before they become usable catalog items.
      </Typography>

      {error && <Alert severity="error" sx={{ mb: 2 }}>{error}</Alert>}
      {success && <Alert severity="success" sx={{ mb: 2 }}>{success}</Alert>}

      <Stack direction="row" spacing={1} sx={{ mb: 2 }}>
        <Button variant="outlined" size="small" startIcon={<AddIcon />} onClick={addRow}>
          Add
        </Button>
        <Button
          variant="outlined"
          size="small"
          color="error"
          startIcon={<DeleteIcon />}
          onClick={removeSelected}
          disabled={selected.size === 0}
        >
          Remove
        </Button>
      </Stack>

      <Paper variant="outlined">
        <TableContainer>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell padding="checkbox" />
                <TableCell sx={{ minWidth: 160 }}>Material Type</TableCell>
                <TableCell sx={{ minWidth: 160 }}>Goods Group</TableCell>
                <TableCell sx={{ minWidth: 160 }}>External Goods Group</TableCell>
                <TableCell sx={{ minWidth: 100 }}>Unit</TableCell>
                <TableCell sx={{ minWidth: 180 }}>Material Name</TableCell>
                <TableCell sx={{ minWidth: 180 }}>Description (TR)</TableCell>
                <TableCell sx={{ minWidth: 180 }}>Description (EN)</TableCell>
                <TableCell sx={{ minWidth: 180 }}>Description (FR)</TableCell>
                <TableCell sx={{ minWidth: 140 }}>Old Material No</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {rows.map((row) => (
                <TableRow key={row.key} hover selected={selected.has(row.key)}>
                  <TableCell padding="checkbox">
                    <IconButton size="small" onClick={() => toggleSelected(row.key)}>
                      <Box
                        sx={{
                          width: 16,
                          height: 16,
                          border: 1,
                          borderColor: 'divider',
                          borderRadius: 0.5,
                          bgcolor: selected.has(row.key) ? 'primary.main' : 'transparent',
                        }}
                      />
                    </IconButton>
                  </TableCell>
                  <TableCell>
                    <TextField
                      select
                      size="small"
                      fullWidth
                      value={row.material_type_id}
                      disabled={loading}
                      onChange={(e) => updateRow(row.key, 'material_type_id', e.target.value)}
                    >
                      <MenuItem value="">—</MenuItem>
                      {types.map((t) => (
                        <MenuItem key={t.id} value={t.id}>
                          {t.code} · {t.name}
                        </MenuItem>
                      ))}
                    </TextField>
                  </TableCell>
                  <TableCell>
                    <TextField
                      select
                      size="small"
                      fullWidth
                      value={row.material_group_id}
                      disabled={loading}
                      onChange={(e) => updateRow(row.key, 'material_group_id', e.target.value)}
                    >
                      <MenuItem value="">—</MenuItem>
                      {groups.map((g) => (
                        <MenuItem key={g.id} value={g.id}>
                          {g.code} · {g.name}
                        </MenuItem>
                      ))}
                    </TextField>
                  </TableCell>
                  <TableCell>
                    <TextField
                      select
                      size="small"
                      fullWidth
                      value={row.external_material_group_id}
                      disabled={loading}
                      onChange={(e) => updateRow(row.key, 'external_material_group_id', e.target.value)}
                    >
                      <MenuItem value="">—</MenuItem>
                      {externalGroups.map((g) => (
                        <MenuItem key={g.id} value={g.id}>
                          {g.code} · {g.name}
                        </MenuItem>
                      ))}
                    </TextField>
                  </TableCell>
                  <TableCell>
                    <TextField
                      size="small"
                      fullWidth
                      value={row.unit}
                      onChange={(e) => updateRow(row.key, 'unit', e.target.value)}
                    />
                  </TableCell>
                  <TableCell>
                    <TextField
                      size="small"
                      fullWidth
                      value={row.name}
                      onChange={(e) => updateRow(row.key, 'name', e.target.value)}
                    />
                  </TableCell>
                  <TableCell>
                    <TextField
                      size="small"
                      fullWidth
                      value={row.description_tr}
                      onChange={(e) => updateRow(row.key, 'description_tr', e.target.value)}
                    />
                  </TableCell>
                  <TableCell>
                    <TextField
                      size="small"
                      fullWidth
                      value={row.description_en}
                      onChange={(e) => updateRow(row.key, 'description_en', e.target.value)}
                    />
                  </TableCell>
                  <TableCell>
                    <TextField
                      size="small"
                      fullWidth
                      value={row.description_fr}
                      onChange={(e) => updateRow(row.key, 'description_fr', e.target.value)}
                    />
                  </TableCell>
                  <TableCell>
                    <TextField
                      size="small"
                      fullWidth
                      value={row.old_material_code}
                      onChange={(e) => updateRow(row.key, 'old_material_code', e.target.value)}
                    />
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </TableContainer>
      </Paper>

      <Stack direction="row" justifyContent="flex-end" sx={{ mt: 2 }}>
        <Button variant="contained" startIcon={<SaveIcon />} onClick={save} disabled={saving}>
          {saving ? 'Saving…' : 'Save'}
        </Button>
      </Stack>
    </Box>
  );
}