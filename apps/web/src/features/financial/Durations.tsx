import { useEffect, useState } from 'react';
import {
  Box,
  Chip,
  MenuItem,
  Paper,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  TextField,
  Typography,
} from '@mui/material';
import { supabase } from '../../lib/supabaseClient';

interface DurationRow {
  source_type: 'supplier_invoice' | 'receivable_invoice';
  source_id: string;
  invoice_number: string;
  invoice_date: string;
  outstanding_amount: number;
  currency: string;
  status: string;
  days_outstanding: number;
}

const SOURCE_LABELS: Record<DurationRow['source_type'], string> = {
  supplier_invoice: 'Supplier Invoice (Payable)',
  receivable_invoice: 'Receivable Invoice',
};

function bucketFor(days: number): { label: string; color: 'success' | 'warning' | 'error' } {
  if (days <= 30) return { label: '0–30 days', color: 'success' };
  if (days <= 60) return { label: '31–60 days', color: 'warning' };
  if (days <= 90) return { label: '61–90 days', color: 'warning' };
  return { label: '90+ days', color: 'error' };
}

export default function Durations() {
  const [sourceFilter, setSourceFilter] = useState<'' | DurationRow['source_type']>('');
  const [rows, setRows] = useState<DurationRow[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    setLoading(true);
    let query = supabase
      .from('v_durations')
      .select('*')
      .order('days_outstanding', { ascending: false });

    if (sourceFilter) query = query.eq('source_type', sourceFilter);

    query.then(({ data, error }) => {
      setRows(error ? [] : (data as DurationRow[]) ?? []);
      setLoading(false);
    });
  }, [sourceFilter]);

  return (
    <Box>
      <Typography variant="h5" gutterBottom>
        Durations (Aging)
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
        Supplier invoice outstanding amounts are derived by netting against matched payments — there is
        no stored paid/unpaid status on supplier invoices yet.
      </Typography>

      <Paper sx={{ p: 2, mb: 2 }}>
        <TextField
          select
          label="Type"
          value={sourceFilter}
          onChange={(e) => setSourceFilter(e.target.value as '' | DurationRow['source_type'])}
          sx={{ minWidth: 260 }}
          size="small"
        >
          <MenuItem value="">All types</MenuItem>
          <MenuItem value="supplier_invoice">Supplier Invoices (Payable)</MenuItem>
          <MenuItem value="receivable_invoice">Receivable Invoices</MenuItem>
        </TextField>
      </Paper>

      <TableContainer component={Paper}>
        <Table size="small">
          <TableHead>
            <TableRow>
              <TableCell>Type</TableCell>
              <TableCell>Invoice No</TableCell>
              <TableCell>Invoice Date</TableCell>
              <TableCell align="right">Outstanding</TableCell>
              <TableCell>Currency</TableCell>
              <TableCell align="right">Days Outstanding</TableCell>
              <TableCell>Bucket</TableCell>
            </TableRow>
          </TableHead>
          <TableBody>
            {rows.map((r) => {
              const bucket = bucketFor(r.days_outstanding);
              return (
                <TableRow key={`${r.source_type}-${r.source_id}`}>
                  <TableCell>{SOURCE_LABELS[r.source_type]}</TableCell>
                  <TableCell>{r.invoice_number}</TableCell>
                  <TableCell>{r.invoice_date}</TableCell>
                  <TableCell align="right">{Number(r.outstanding_amount).toLocaleString()}</TableCell>
                  <TableCell>{r.currency}</TableCell>
                  <TableCell align="right">{r.days_outstanding}</TableCell>
                  <TableCell>
                    <Chip size="small" label={bucket.label} color={bucket.color} />
                  </TableCell>
                </TableRow>
              );
            })}
            {rows.length === 0 && !loading && (
              <TableRow>
                <TableCell colSpan={7} align="center">
                  No outstanding invoices.
                </TableCell>
              </TableRow>
            )}
          </TableBody>
        </Table>
      </TableContainer>
    </Box>
  );
}