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

interface PlanRow {
  source_type: 'supplier_invoice' | 'receivable_invoice';
  source_id: string;
  invoice_number: string;
  invoice_date: string;
  due_date: string;
  currency: string;
  outstanding_amount: number;
}

const SOURCE_LABELS: Record<PlanRow['source_type'], string> = {
  supplier_invoice: 'Payable (to vendor)',
  receivable_invoice: 'Receivable (from client)',
};

function dueStatus(dueDate: string): { label: string; color: 'success' | 'warning' | 'error' } {
  const days = Math.ceil((new Date(dueDate).getTime() - Date.now()) / (1000 * 60 * 60 * 24));
  if (days < 0) return { label: `${Math.abs(days)}d overdue`, color: 'error' };
  if (days <= 7) return { label: `Due in ${days}d`, color: 'warning' };
  return { label: `Due in ${days}d`, color: 'success' };
}

export default function PaymentPlanReport() {
  const [sourceFilter, setSourceFilter] = useState<'' | PlanRow['source_type']>('');
  const [rows, setRows] = useState<PlanRow[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    setLoading(true);
    let query = supabase.from('v_payment_plan').select('*').order('due_date', { ascending: true });
    if (sourceFilter) query = query.eq('source_type', sourceFilter);

    query.then(({ data, error }) => {
      setRows(error ? [] : (data as PlanRow[]) ?? []);
      setLoading(false);
    });
  }, [sourceFilter]);

  return (
    <Box>
      <Typography variant="h5" gutterBottom>
        Payment Plan Report
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
        Only invoices with a due date set are shown. Existing invoices recorded before due dates were
        added won't appear here until they're edited to include one.
      </Typography>

      <Paper sx={{ p: 2, mb: 2 }}>
        <TextField
          select
          label="Type"
          value={sourceFilter}
          onChange={(e) => setSourceFilter(e.target.value as '' | PlanRow['source_type'])}
          sx={{ minWidth: 260 }}
          size="small"
        >
          <MenuItem value="">All types</MenuItem>
          <MenuItem value="supplier_invoice">Payables (to vendors)</MenuItem>
          <MenuItem value="receivable_invoice">Receivables (from clients)</MenuItem>
        </TextField>
      </Paper>

      <TableContainer component={Paper}>
        <Table size="small">
          <TableHead>
            <TableRow>
              <TableCell>Type</TableCell>
              <TableCell>Invoice No</TableCell>
              <TableCell>Invoice Date</TableCell>
              <TableCell>Due Date</TableCell>
              <TableCell align="right">Outstanding</TableCell>
              <TableCell>Currency</TableCell>
              <TableCell>Status</TableCell>
            </TableRow>
          </TableHead>
          <TableBody>
            {rows.map((r) => {
              const status = dueStatus(r.due_date);
              return (
                <TableRow key={`${r.source_type}-${r.source_id}`}>
                  <TableCell>{SOURCE_LABELS[r.source_type]}</TableCell>
                  <TableCell>{r.invoice_number}</TableCell>
                  <TableCell>{r.invoice_date}</TableCell>
                  <TableCell>{r.due_date}</TableCell>
                  <TableCell align="right">{Number(r.outstanding_amount).toLocaleString()}</TableCell>
                  <TableCell>{r.currency}</TableCell>
                  <TableCell>
                    <Chip size="small" label={status.label} color={status.color} />
                  </TableCell>
                </TableRow>
              );
            })}
            {rows.length === 0 && !loading && (
              <TableRow>
                <TableCell colSpan={7} align="center">
                  No invoices with a due date set.
                </TableCell>
              </TableRow>
            )}
          </TableBody>
        </Table>
      </TableContainer>
    </Box>
  );
}