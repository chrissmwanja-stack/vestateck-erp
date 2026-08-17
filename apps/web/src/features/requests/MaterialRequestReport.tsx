import { useEffect, useState } from 'react';
import {
  Alert,
  Box,
  Button,
  Chip,
  CircularProgress,
  Grid,
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
import { Search as SearchIcon, Clear as ClearIcon } from '@mui/icons-material';
import { supabase } from '../../lib/supabaseClient';

interface LookupOption {
  id: string;
  code: string;
  name: string;
}

interface ReportRow {
  id: string;
  name: string;
  unit: string | null;
  description_tr: string | null;
  description_en: string | null;
  description_fr: string | null;
  old_material_code: string | null;
  status: 'pending' | 'approved' | 'rejected';
  rejection_message: string | null;
  created_at: string;
  material_types: { code: string; name: string } | null;
  material_groups: { code: string; name: string } | null;
  external_material_groups: { code: string; name: string } | null;
  material_catalog: { code: string } | null;
  material_request_batches: { requester_id: string; created_at: string; app_users: { name: string } | null } | null;
}

const ROW_SELECT = `
  id, name, unit, description_tr, description_en, description_fr, old_material_code,
  status, rejection_message, created_at,
  material_types ( code, name ),
  material_groups ( code, name ),
  external_material_groups ( code, name ),
  material_catalog ( code ),
  material_request_batches ( requester_id, created_at, app_users ( name ) )
`;

const emptyFilters = {
  material_type_id: '',
  material_group_id: '',
  external_material_group_id: '',
  unit: '',
  name: '',
  description_tr: '',
  description_en: '',
  description_fr: '',
  old_material_code: '',
};

const STATUS_COLOR: Record<ReportRow['status'], 'default' | 'success' | 'error'> = {
  pending: 'default',
  approved: 'success',
  rejected: 'error',
};

export default function MaterialRequestReport() {
  const [types, setTypes] = useState<LookupOption[]>([]);
  const [groups, setGroups] = useState<LookupOption[]>([]);
  const [externalGroups, setExternalGroups] = useState<LookupOption[]>([]);
  const [units, setUnits] = useState<string[]>([]);

  const [filters, setFilters] = useState(emptyFilters);
  const [rows, setRows] = useState<ReportRow[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [searched, setSearched] = useState(false);

  useEffect(() => {
    (async () => {
      const [t, g, e, u] = await Promise.all([
        supabase.from('material_types').select('id, code, name').order('code'),
        supabase.from('material_groups').select('id, code, name').order('code'),
        supabase.from('external_material_groups').select('id, code, name').order('code'),
        supabase.from('material_request_items').select('unit').not('unit', 'is', null),
      ]);
      setTypes((t.data ?? []) as LookupOption[]);
      setGroups((g.data ?? []) as LookupOption[]);
      setExternalGroups((e.data ?? []) as LookupOption[]);
      const distinctUnits = Array.from(new Set((u.data ?? []).map((r: { unit: string | null }) => r.unit).filter((v): v is string => !!v))).sort();
      setUnits(distinctUnits);
    })();
  }, []);

  const setFilter = (field: keyof typeof emptyFilters, value: string) =>
    setFilters((f) => ({ ...f, [field]: value }));

  const search = async () => {
    setLoading(true);
    setError(null);
    setSearched(true);

    let query = supabase.from('material_request_items').select(ROW_SELECT).order('created_at', { ascending: false });

    if (filters.material_type_id) query = query.eq('material_type_id', filters.material_type_id);
    if (filters.material_group_id) query = query.eq('material_group_id', filters.material_group_id);
    if (filters.external_material_group_id)
      query = query.eq('external_material_group_id', filters.external_material_group_id);
    if (filters.unit) query = query.eq('unit', filters.unit);
    if (filters.name.trim()) query = query.ilike('name', `%${filters.name.trim()}%`);
    if (filters.description_tr.trim()) query = query.ilike('description_tr', `%${filters.description_tr.trim()}%`);
    if (filters.description_en.trim()) query = query.ilike('description_en', `%${filters.description_en.trim()}%`);
    if (filters.description_fr.trim()) query = query.ilike('description_fr', `%${filters.description_fr.trim()}%`);
    if (filters.old_material_code.trim())
      query = query.ilike('old_material_code', `%${filters.old_material_code.trim()}%`);

    const { data, error: err } = await query;
    setLoading(false);

    if (err) setError(err.message);
    else setRows((data ?? []) as unknown as ReportRow[]);
  };

  const clear = () => {
    setFilters(emptyFilters);
    setRows([]);
    setSearched(false);
  };

  return (
    <Box>
      <Typography variant="h5" sx={{ mb: 1 }}>
        Material Request Report
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        Search material catalog proposals across every requester, by classification or description.
      </Typography>

      {error && <Alert severity="error" sx={{ mb: 2 }}>{error}</Alert>}

      <Paper variant="outlined" sx={{ p: 2, mb: 3 }}>
        <Grid container spacing={2}>
          <Grid item xs={12} sm={6} md={3}>
            <TextField
              select
              fullWidth
              size="small"
              label="Material Type"
              value={filters.material_type_id}
              onChange={(e) => setFilter('material_type_id', e.target.value)}
            >
              <MenuItem value="">All</MenuItem>
              {types.map((t) => (
                <MenuItem key={t.id} value={t.id}>
                  {t.code} · {t.name}
                </MenuItem>
              ))}
            </TextField>
          </Grid>
          <Grid item xs={12} sm={6} md={3}>
            <TextField
              select
              fullWidth
              size="small"
              label="Goods Group"
              value={filters.material_group_id}
              onChange={(e) => setFilter('material_group_id', e.target.value)}
            >
              <MenuItem value="">All</MenuItem>
              {groups.map((g) => (
                <MenuItem key={g.id} value={g.id}>
                  {g.code} · {g.name}
                </MenuItem>
              ))}
            </TextField>
          </Grid>
          <Grid item xs={12} sm={6} md={3}>
            <TextField
              select
              fullWidth
              size="small"
              label="External Goods Group"
              value={filters.external_material_group_id}
              onChange={(e) => setFilter('external_material_group_id', e.target.value)}
            >
              <MenuItem value="">All</MenuItem>
              {externalGroups.map((g) => (
                <MenuItem key={g.id} value={g.id}>
                  {g.code} · {g.name}
                </MenuItem>
              ))}
            </TextField>
          </Grid>
          <Grid item xs={12} sm={6} md={3}>
            <TextField
              select
              fullWidth
              size="small"
              label="Unit"
              value={filters.unit}
              onChange={(e) => setFilter('unit', e.target.value)}
            >
              <MenuItem value="">All</MenuItem>
              {units.map((u) => (
                <MenuItem key={u} value={u}>
                  {u}
                </MenuItem>
              ))}
            </TextField>
          </Grid>

          <Grid item xs={12} sm={6} md={3}>
            <TextField
              fullWidth
              size="small"
              label="Material Name"
              value={filters.name}
              onChange={(e) => setFilter('name', e.target.value)}
            />
          </Grid>
          <Grid item xs={12} sm={6} md={3}>
            <TextField
              fullWidth
              size="small"
              label="Description (TR)"
              value={filters.description_tr}
              onChange={(e) => setFilter('description_tr', e.target.value)}
            />
          </Grid>
          <Grid item xs={12} sm={6} md={3}>
            <TextField
              fullWidth
              size="small"
              label="Description (EN)"
              value={filters.description_en}
              onChange={(e) => setFilter('description_en', e.target.value)}
            />
          </Grid>
          <Grid item xs={12} sm={6} md={3}>
            <TextField
              fullWidth
              size="small"
              label="Description (FR)"
              value={filters.description_fr}
              onChange={(e) => setFilter('description_fr', e.target.value)}
            />
          </Grid>

          <Grid item xs={12} sm={6} md={3}>
            <TextField
              fullWidth
              size="small"
              label="Old Material No"
              value={filters.old_material_code}
              onChange={(e) => setFilter('old_material_code', e.target.value)}
            />
          </Grid>
        </Grid>

        <Stack direction="row" spacing={1} sx={{ mt: 2 }}>
          <Button variant="contained" startIcon={<SearchIcon />} onClick={search} disabled={loading}>
            Search
          </Button>
          <Button variant="text" startIcon={<ClearIcon />} onClick={clear} disabled={loading}>
            Clear
          </Button>
        </Stack>
      </Paper>

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
                  <TableCell>Requested By</TableCell>
                  <TableCell>Date</TableCell>
                  <TableCell>Material No</TableCell>
                  <TableCell>Material</TableCell>
                  <TableCell>Type</TableCell>
                  <TableCell>Goods Group</TableCell>
                  <TableCell>Ext. Group</TableCell>
                  <TableCell>Unit</TableCell>
                  <TableCell>Old No</TableCell>
                  <TableCell>Status</TableCell>
                  <TableCell>Message</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {rows.map((row) => (
                  <TableRow key={row.id} hover>
                    <TableCell>{row.material_request_batches?.app_users?.name ?? '—'}</TableCell>
                    <TableCell>{new Date(row.created_at).toLocaleDateString()}</TableCell>
                    <TableCell>{row.material_catalog?.code ?? '—'}</TableCell>
                    <TableCell>{row.name}</TableCell>
                    <TableCell>{row.material_types?.code ?? '—'}</TableCell>
                    <TableCell>{row.material_groups?.code ?? '—'}</TableCell>
                    <TableCell>{row.external_material_groups?.code ?? '—'}</TableCell>
                    <TableCell>{row.unit ?? '—'}</TableCell>
                    <TableCell>{row.old_material_code ?? '—'}</TableCell>
                    <TableCell>
                      <Chip size="small" label={row.status} color={STATUS_COLOR[row.status]} />
                    </TableCell>
                    <TableCell>{row.rejection_message ?? '—'}</TableCell>
                  </TableRow>
                ))}
                {rows.length === 0 && (
                  <TableRow>
                    <TableCell colSpan={11} align="center" sx={{ color: 'text.secondary', py: 3 }}>
                      {searched ? 'No matching requests.' : 'Run a search to see results.'}
                    </TableCell>
                  </TableRow>
                )}
              </TableBody>
            </Table>
          </TableContainer>
        )}
      </Paper>
    </Box>
  );
}