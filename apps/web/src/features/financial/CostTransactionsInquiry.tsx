import { useEffect, useState } from 'react';
import {
  Box,
  Button,
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
import { useSearchParams } from 'react-router-dom';
import { supabase } from '../../lib/supabaseClient';

interface CostCenter {
  id: string;
  name: string;
  project_code: string | null;
  budget_amount: number | null;
}

interface TransactionRow {
  cost_center_id: string;
  source_type: 'supplier_invoice' | 'expenditure_slip' | 'purchase_order';
  source_id: string;
  reference_no: string;
  transaction_date: string;
  amount: number;
  currency: string;
}

const SOURCE_LABELS: Record<TransactionRow['source_type'], string> = {
  supplier_invoice: 'Supplier Invoice',
  expenditure_slip: 'Expenditure Slip',
  purchase_order: 'Purchase Order',
};

export default function CostTransactionsInquiry() {
  const [searchParams] = useSearchParams();
  const currency = searchParams.get('ccy') === 'USD' ? 'USD' : 'UGX';

  const [costCenters, setCostCenters] = useState<CostCenter[]>([]);
  const [costCenterId, setCostCenterId] = useState('');
  const [dateFrom, setDateFrom] = useState('');
  const [dateTo, setDateTo] = useState('');
  const [rows, setRows] = useState<TransactionRow[]>([]);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    supabase
      .from('cost_centers')
      .select('id, name, project_code, budget_amount')
      .order('name')
      .then(({ data }) => setCostCenters(data ?? []));
  }, []);

  const runSearch = async () => {
    setLoading(true);
    let query = supabase
      .from('v_cost_transactions_inquiry')
      .select('*')
      .eq('currency', currency)
      .order('transaction_date', { ascending: false });

    if (costCenterId) query = query.eq('cost_center_id', costCenterId);
    if (dateFrom) query = query.gte('transaction_date', dateFrom);
    if (dateTo) query = query.lte('transaction_date', dateTo);

    const { data, error } = await query;
    setRows(error ? [] : (data as TransactionRow[]) ?? []);
    setLoading(false);
  };

  useEffect(() => {
    runSearch();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [currency]);

  const selectedCostCenter = costCenters.find((c) => c.id === costCenterId);
  const total = rows.reduce((sum, r) => sum + Number(r.amount), 0);

  return (
    <Box>
      <Typography variant="h5" gutterBottom>
        Cost Transactions Inquiry {currency === 'USD' && '(USD)'}
      </Typography>

      <Paper sx={{ p: 2, mb: 2 }}>
        <Box sx={{ display: 'flex', gap: 2, flexWrap: 'wrap', alignItems: 'center' }}>
          <TextField
            select
            label="Cost Center"
            value={costCenterId}
            onChange={(e) => setCostCenterId(e.target.value)}
            sx={{ minWidth: 260 }}
            size="small"
          >
            <MenuItem value="">All cost centers</MenuItem>
            {costCenters.map((cc) => (
              <MenuItem key={cc.id} value={cc.id}>
                {cc.name} {cc.project_code ? `(${cc.project_code})` : ''}
              </MenuItem>
            ))}
          </TextField>
          <TextField
            label="From"
            type="date"
            size="small"
            InputLabelProps={{ shrink: true }}
            value={dateFrom}
            onChange={(e) => setDateFrom(e.target.value)}
          />
          <TextField
            label="To"
            type="date"
            size="small"
            InputLabelProps={{ shrink: true }}
            value={dateTo}
            onChange={(e) => setDateTo(e.target.value)}
          />
          <Button variant="contained" onClick={runSearch} disabled={loading}>
            Search
          </Button>
          <Button
            variant="outlined"
            onClick={() => {
              setCostCenterId('');
              setDateFrom('');
              setDateTo('');
            }}
          >
            Clear
          </Button>
        </Box>
      </Paper>

      {selectedCostCenter && selectedCostCenter.budget_amount != null && (
        <Typography variant="body2" sx={{ mb: 1 }} color="text.secondary">
          Budget: {selectedCostCenter.budget_amount.toLocaleString()} {currency} &nbsp;|&nbsp; Spent so
          far: {total.toLocaleString()} {currency} &nbsp;|&nbsp; Remaining:{' '}
          {(selectedCostCenter.budget_amount - total).toLocaleString()} {currency}
        </Typography>
      )}

      <TableContainer component={Paper}>
        <Table size="small">
          <TableHead>
            <TableRow>
              <TableCell>Source</TableCell>
              <TableCell>Reference No</TableCell>
              <TableCell>Date</TableCell>
              <TableCell align="right">Amount</TableCell>
              <TableCell>Currency</TableCell>
            </TableRow>
          </TableHead>
          <TableBody>
            {rows.map((r) => (
              <TableRow key={`${r.source_type}-${r.source_id}`}>
                <TableCell>{SOURCE_LABELS[r.source_type]}</TableCell>
                <TableCell>{r.reference_no}</TableCell>
                <TableCell>{r.transaction_date}</TableCell>
                <TableCell align="right">{Number(r.amount).toLocaleString()}</TableCell>
                <TableCell>{r.currency}</TableCell>
              </TableRow>
            ))}
            {rows.length === 0 && !loading && (
              <TableRow>
                <TableCell colSpan={5} align="center">
                  No transactions found for the selected filters.
                </TableCell>
              </TableRow>
            )}
          </TableBody>
        </Table>
      </TableContainer>
      <Typography variant="subtitle2" sx={{ mt: 1 }}>
        Total: {total.toLocaleString()} {currency} ({rows.length} transactions)
      </Typography>
    </Box>
  );
}