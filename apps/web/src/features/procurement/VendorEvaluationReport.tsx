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
  Tooltip,
  Typography,
} from '@mui/material';
import { BarChart as BarChartIcon, InfoOutlined } from '@mui/icons-material';
import { supabase } from '../../lib/supabaseClient';

interface VendorEvalRow {
  vendor_account_id: string;
  account_code: string;
  vendor_name: string;
  contact_name: string | null;
  contact_phone: string | null;
  contact_email: string | null;
  is_active: boolean;
  total_pos: number;
  total_po_value: number;
  delivered_pos: number;
  avg_days_to_deliver: number | null;
  on_time_delivery_pct: number | null;
  fulfillment_accuracy_pct: number | null;
  over_delivery_pct: number | null;
  under_delivery_pct: number | null;
}

function ratePillColor(pct: number | null): 'default' | 'success' | 'warning' | 'error' {
  if (pct === null) return 'default';
  if (pct >= 90) return 'success';
  if (pct >= 70) return 'warning';
  return 'error';
}

function formatUgx(amount: number): string {
  return new Intl.NumberFormat('en-UG', { style: 'currency', currency: 'UGX', maximumFractionDigits: 0 }).format(
    amount
  );
}

function RatePill({ pct, label }: { pct: number | null; label: string }) {
  if (pct === null) {
    return (
      <Typography variant="caption" color="text.secondary">
        {label}: —
      </Typography>
    );
  }
  return <Chip size="small" label={`${label} ${pct}%`} color={ratePillColor(pct)} sx={{ mr: 0.5, mb: 0.5 }} />;
}

export default function VendorEvaluationReport() {
  const [rows, setRows] = useState<VendorEvalRow[]>([]);
  const [query, setQuery] = useState('');
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const { data, error: rpcError } = await supabase.rpc('get_vendor_evaluation');
    setLoading(false);

    if (rpcError) {
      setError(rpcError.message ?? 'Failed to load vendor evaluation data.');
      return;
    }
    setRows((data ?? []) as VendorEvalRow[]);
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const filtered = rows.filter((r) => r.vendor_name.toLowerCase().includes(query.trim().toLowerCase()));

  return (
    <Box>
      <Stack direction="row" justifyContent="space-between" alignItems="center" sx={{ mb: 2 }}>
        <Typography variant="h5" sx={{ display: 'flex', alignItems: 'center', gap: 1 }}>
          <BarChartIcon /> Vendor Evaluation Report
        </Typography>
      </Stack>

      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        Performance is computed automatically from purchase order delivery confirmations and Material Quantity
        line-item receipts — there is nothing to fill in manually here.
      </Typography>

      <TextField
        label="Search vendor"
        size="small"
        sx={{ mb: 2, width: 320 }}
        value={query}
        onChange={(e) => setQuery(e.target.value)}
      />

      {error && <Alert severity="error" sx={{ mb: 2 }}>{error}</Alert>}

      {loading ? (
        <Box sx={{ display: 'flex', justifyContent: 'center', py: 4 }}>
          <CircularProgress size={24} />
        </Box>
      ) : filtered.length === 0 ? (
        <Paper variant="outlined" sx={{ p: 4, textAlign: 'center', color: 'text.secondary' }}>
          No vendors found.
        </Paper>
      ) : (
        <TableContainer component={Paper} variant="outlined">
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>Vendor</TableCell>
                <TableCell align="right">POs</TableCell>
                <TableCell align="right">Total value</TableCell>
                <TableCell align="right">
                  Avg. days to deliver
                  <Tooltip title="Average time from PO generation to delivery confirmation">
                    <InfoOutlined fontSize="inherit" sx={{ ml: 0.5, verticalAlign: 'middle' }} />
                  </Tooltip>
                </TableCell>
                <TableCell>Delivery performance</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {filtered.map((row) => (
                <TableRow key={row.vendor_account_id} hover>
                  <TableCell>
                    <Typography variant="body2" fontWeight={600}>
                      {row.vendor_name}
                    </Typography>
                    <Typography variant="caption" color="text.secondary">
                      {row.account_code}
                      {!row.is_active ? ' • Inactive' : ''}
                    </Typography>
                  </TableCell>
                  <TableCell align="right">{row.total_pos}</TableCell>
                  <TableCell align="right">{formatUgx(row.total_po_value)}</TableCell>
                  <TableCell align="right">
                    {row.avg_days_to_deliver !== null ? `${row.avg_days_to_deliver}d` : '—'}
                  </TableCell>
                  <TableCell>
                    <RatePill pct={row.on_time_delivery_pct} label="On-time" />
                    <RatePill pct={row.fulfillment_accuracy_pct} label="Accurate" />
                    {row.over_delivery_pct !== null && row.over_delivery_pct > 0 && (
                      <Chip size="small" label={`Over ${row.over_delivery_pct}%`} color="warning" sx={{ mr: 0.5, mb: 0.5 }} />
                    )}
                    {row.under_delivery_pct !== null && row.under_delivery_pct > 0 && (
                      <Chip size="small" label={`Under ${row.under_delivery_pct}%`} color="warning" sx={{ mr: 0.5, mb: 0.5 }} />
                    )}
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