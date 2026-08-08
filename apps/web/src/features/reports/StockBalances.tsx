import { useCallback, useEffect, useState } from 'react';
import {
  Alert,
  Box,
  Chip,
  CircularProgress,
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
import { Inventory2 as Inventory2Icon } from '@mui/icons-material';
import { supabase } from '../../lib/supabaseClient';

// Reads stock_balances directly -- a maintained running total kept
// current by triggers on every stock_movements insert (both goods
// receipts and goods issues post there), rather than aggregated on
// read. See 20260808140100_stock_ledger_and_goods_movements.sql.

interface WarehouseOption {
  id: string;
  name: string;
}

interface BalanceRow {
  id: string;
  warehouse_id: string;
  warehouse_name: string | null;
  material_name: string;
  unit: string | null;
  quantity_on_hand: number;
  updated_at: string;
}

export default function StockBalances() {
  const [warehouses, setWarehouses] = useState<WarehouseOption[]>([]);
  const [warehouseId, setWarehouseId] = useState('');
  const [query, setQuery] = useState('');
  const [rows, setRows] = useState<BalanceRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    supabase.from('warehouses').select('id, name').eq('is_active', true).order('name')
      .then(({ data }) => setWarehouses((data ?? []) as WarehouseOption[]));
  }, []);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    let q = supabase
      .from('stock_balances')
      .select('id, warehouse_id, material_name, unit, quantity_on_hand, updated_at, warehouse:warehouse_id(name)')
      .order('material_name');

    if (warehouseId) q = q.eq('warehouse_id', warehouseId);
    if (query.trim()) q = q.ilike('material_name', `%${query.trim()}%`);

    const { data, error: err } = await q;
    setLoading(false);
    if (err) {
      setError(err.message);
      return;
    }
    setRows(
      ((data ?? []) as any[]).map((r) => ({
        id: r.id,
        warehouse_id: r.warehouse_id,
        warehouse_name: r.warehouse?.name ?? null,
        material_name: r.material_name,
        unit: r.unit,
        quantity_on_hand: r.quantity_on_hand,
        updated_at: r.updated_at,
      }))
    );
  }, [warehouseId, query]);

  useEffect(() => {
    load();
  }, [load]);

  return (
    <Box sx={{ maxWidth: 1000 }}>
      <Typography variant="h5" sx={{ display: 'flex', alignItems: 'center', gap: 1, mb: 1 }}>
        <Inventory2Icon /> Stock Balances
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        Quantity on hand per warehouse, updated automatically from every goods receipt (in) and goods issue (out).
      </Typography>

      <Paper variant="outlined" sx={{ p: 2, mb: 2 }}>
        <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2}>
          <TextField
            select
            label="Warehouse"
            size="small"
            sx={{ minWidth: 220 }}
            value={warehouseId}
            onChange={(e) => setWarehouseId(e.target.value)}
            SelectProps={{ native: true }}
          >
            <option value="">All warehouses</option>
            {warehouses.map((w) => (
              <option key={w.id} value={w.id}>
                {w.name}
              </option>
            ))}
          </TextField>
          <TextField
            label="Search material"
            size="small"
            sx={{ flex: 1 }}
            value={query}
            onChange={(e) => setQuery(e.target.value)}
          />
        </Stack>
      </Paper>

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
                  <TableCell>Material</TableCell>
                  <TableCell>Warehouse</TableCell>
                  <TableCell align="right">On hand</TableCell>
                  <TableCell>Unit</TableCell>
                  <TableCell>Last movement</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {rows.map((r) => (
                  <TableRow key={r.id} hover>
                    <TableCell>{r.material_name}</TableCell>
                    <TableCell>{r.warehouse_name ?? '—'}</TableCell>
                    <TableCell align="right">
                      <Chip
                        size="small"
                        label={r.quantity_on_hand}
                        color={r.quantity_on_hand <= 0 ? 'error' : 'default'}
                        variant={r.quantity_on_hand <= 0 ? 'filled' : 'outlined'}
                      />
                    </TableCell>
                    <TableCell>{r.unit ?? '—'}</TableCell>
                    <TableCell>{new Date(r.updated_at).toLocaleString()}</TableCell>
                  </TableRow>
                ))}
                {rows.length === 0 && (
                  <TableRow>
                    <TableCell colSpan={5} align="center" sx={{ color: 'text.secondary', py: 3 }}>
                      No stock movements recorded yet.
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