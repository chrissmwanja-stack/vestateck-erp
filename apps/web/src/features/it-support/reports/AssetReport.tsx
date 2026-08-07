import { useEffect, useState, useCallback, useMemo } from 'react';
import {
  Box,
  Typography,
  Paper,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  Chip,
  Alert,
  CircularProgress,
  Grid,
  MenuItem,
  TextField,
} from '@mui/material';
import { supabase } from '../../../lib/supabaseClient';

interface Asset {
  id: string;
  asset_tag: string | null;
  type: 'hardware' | 'software';
  name: string;
  category: string | null;
  vendor: string | null;
  purchase_date: string | null;
  purchase_cost: number | null;
  status: 'in_stock' | 'assigned' | 'maintenance' | 'retired';
}

const statusColor: Record<string, 'default' | 'info' | 'success' | 'warning' | 'error'> = {
  in_stock: 'info',
  assigned: 'success',
  maintenance: 'warning',
  retired: 'default',
};

function formatCurrency(n: number): string {
  return new Intl.NumberFormat('en-UG', { style: 'currency', currency: 'UGX', maximumFractionDigits: 0 }).format(n);
}

export default function AssetReport() {
  const [isItSupport, setIsItSupport] = useState(false);
  const [assets, setAssets] = useState<Asset[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [typeFilter, setTypeFilter] = useState('all');
  const [statusFilter, setStatusFilter] = useState('all');

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const [supportRes, assetsRes] = await Promise.all([
      supabase.rpc('is_it_support'),
      supabase.rpc('get_assets'),
    ]);
    setIsItSupport(Boolean(supportRes.data));
    if (assetsRes.error) setError(assetsRes.error.message);
    else setAssets((assetsRes.data as Asset[]) ?? []);
    setLoading(false);
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const filtered = useMemo(
    () =>
      assets.filter(
        (a) => (typeFilter === 'all' || a.type === typeFilter) && (statusFilter === 'all' || a.status === statusFilter)
      ),
    [assets, typeFilter, statusFilter]
  );

  const summary = useMemo(() => {
    const byStatus: Record<string, number> = { in_stock: 0, assigned: 0, maintenance: 0, retired: 0 };
    let totalCost = 0;
    let hardwareCount = 0;
    let softwareCount = 0;
    assets.forEach((a) => {
      byStatus[a.status] = (byStatus[a.status] ?? 0) + 1;
      totalCost += a.purchase_cost ?? 0;
      if (a.type === 'hardware') hardwareCount += 1;
      else softwareCount += 1;
    });
    return { byStatus, totalCost, hardwareCount, softwareCount };
  }, [assets]);

  const byCategory = useMemo(() => {
    const map = new Map<string, { count: number; cost: number }>();
    assets.forEach((a) => {
      const key = a.category ?? 'Uncategorized';
      const entry = map.get(key) ?? { count: 0, cost: 0 };
      entry.count += 1;
      entry.cost += a.purchase_cost ?? 0;
      map.set(key, entry);
    });
    return Array.from(map.entries()).sort((a, b) => b[1].count - a[1].count);
  }, [assets]);

  if (!isItSupport && !loading) {
    return (
      <Paper sx={{ p: 4, textAlign: 'center' }}>
        <Typography color="text.secondary">This report is only available to IT Support.</Typography>
      </Paper>
    );
  }

  if (loading) {
    return (
      <Box sx={{ display: 'flex', justifyContent: 'center', py: 6 }}>
        <CircularProgress />
      </Box>
    );
  }

  return (
    <Box>
      <Typography variant="h5" sx={{ mb: 0.5 }}>
        Asset Report
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
        Inventory summary across hardware and software assets.
      </Typography>

      {error && (
        <Alert severity="error" sx={{ mb: 2 }} onClose={() => setError(null)}>
          {error}
        </Alert>
      )}

      <Grid container spacing={2} sx={{ mb: 2 }}>
        <Grid item xs={6} sm={3}>
          <Paper sx={{ p: 2, textAlign: 'center' }}>
            <Typography variant="h5">{assets.length}</Typography>
            <Typography variant="caption" color="text.secondary">
              Total assets ({summary.hardwareCount} hw / {summary.softwareCount} sw)
            </Typography>
          </Paper>
        </Grid>
        <Grid item xs={6} sm={3}>
          <Paper sx={{ p: 2, textAlign: 'center' }}>
            <Typography variant="h5">{summary.byStatus.assigned}</Typography>
            <Typography variant="caption" color="text.secondary">
              Assigned
            </Typography>
          </Paper>
        </Grid>
        <Grid item xs={6} sm={3}>
          <Paper sx={{ p: 2, textAlign: 'center' }}>
            <Typography variant="h5">{summary.byStatus.in_stock}</Typography>
            <Typography variant="caption" color="text.secondary">
              In stock
            </Typography>
          </Paper>
        </Grid>
        <Grid item xs={6} sm={3}>
          <Paper sx={{ p: 2, textAlign: 'center' }}>
            <Typography variant="h6">{formatCurrency(summary.totalCost)}</Typography>
            <Typography variant="caption" color="text.secondary">
              Total purchase cost
            </Typography>
          </Paper>
        </Grid>
      </Grid>

      {byCategory.length > 0 && (
        <TableContainer component={Paper} sx={{ mb: 3 }}>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>Category</TableCell>
                <TableCell align="right">Count</TableCell>
                <TableCell align="right">Total cost</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {byCategory.map(([category, { count, cost }]) => (
                <TableRow key={category} hover>
                  <TableCell>{category}</TableCell>
                  <TableCell align="right">{count}</TableCell>
                  <TableCell align="right">{formatCurrency(cost)}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </TableContainer>
      )}

      <Box sx={{ display: 'flex', gap: 2, mb: 2, flexWrap: 'wrap' }}>
        <TextField select size="small" label="Type" value={typeFilter} onChange={(e) => setTypeFilter(e.target.value)} sx={{ width: 160 }}>
          <MenuItem value="all">All</MenuItem>
          <MenuItem value="hardware">Hardware</MenuItem>
          <MenuItem value="software">Software</MenuItem>
        </TextField>
        <TextField select size="small" label="Status" value={statusFilter} onChange={(e) => setStatusFilter(e.target.value)} sx={{ width: 180 }}>
          <MenuItem value="all">All</MenuItem>
          <MenuItem value="in_stock">In stock</MenuItem>
          <MenuItem value="assigned">Assigned</MenuItem>
          <MenuItem value="maintenance">Maintenance</MenuItem>
          <MenuItem value="retired">Retired</MenuItem>
        </TextField>
      </Box>

      {filtered.length === 0 ? (
        <Paper sx={{ p: 4, textAlign: 'center' }}>
          <Typography color="text.secondary">No assets match these filters.</Typography>
        </Paper>
      ) : (
        <TableContainer component={Paper}>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>Asset tag</TableCell>
                <TableCell>Name</TableCell>
                <TableCell>Type</TableCell>
                <TableCell>Category</TableCell>
                <TableCell>Vendor</TableCell>
                <TableCell>Purchased</TableCell>
                <TableCell align="right">Cost</TableCell>
                <TableCell>Status</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {filtered.map((a) => (
                <TableRow key={a.id} hover>
                  <TableCell>{a.asset_tag ?? '—'}</TableCell>
                  <TableCell>{a.name}</TableCell>
                  <TableCell sx={{ textTransform: 'capitalize' }}>{a.type}</TableCell>
                  <TableCell>{a.category ?? '—'}</TableCell>
                  <TableCell>{a.vendor ?? '—'}</TableCell>
                  <TableCell>{a.purchase_date ? new Date(a.purchase_date).toLocaleDateString() : '—'}</TableCell>
                  <TableCell align="right">{a.purchase_cost ? formatCurrency(a.purchase_cost) : '—'}</TableCell>
                  <TableCell>
                    <Chip size="small" label={a.status.replace('_', ' ')} color={statusColor[a.status]} />
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </TableContainer>
      )}
    </Box>
  );
}