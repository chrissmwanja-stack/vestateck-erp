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

interface Account {
  id: string;
  account_code: string;
  name: string;
  account_type: 'vendor' | 'client' | 'both';
}

interface LedgerRow {
  account_id: string;
  source_type: 'supplier_invoice' | 'receivable_invoice' | 'cash_bank_transaction';
  source_id: string;
  reference_no: string | null;
  transaction_date: string;
  debit: number;
  credit: number;
  currency: string;
}

const SOURCE_LABELS: Record<LedgerRow['source_type'], string> = {
  supplier_invoice: 'Supplier Invoice',
  receivable_invoice: 'Receivable Invoice',
  cash_bank_transaction: 'Cash/Bank Transaction',
};

export default function CurrentAccountExtract() {
  const [searchParams] = useSearchParams();
  const currency = searchParams.get('ccy') === 'USD' ? 'USD' : 'UGX';

  const [accounts, setAccounts] = useState<Account[]>([]);
  const [accountId, setAccountId] = useState('');
  const [dateFrom, setDateFrom] = useState('');
  const [dateTo, setDateTo] = useState('');
  const [rows, setRows] = useState<LedgerRow[]>([]);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    supabase
      .from('accounts')
      .select('id, account_code, name, account_type')
      .eq('is_active', true)
      .order('name')
      .then(({ data }) => setAccounts(data ?? []));
  }, []);

  const runSearch = async () => {
    if (!accountId) {
      setRows([]);
      return;
    }
    setLoading(true);
    let query = supabase
      .from('v_account_ledger')
      .select('*')
      .eq('account_id', accountId)
      .eq('currency', currency)
      .order('transaction_date', { ascending: true });

    if (dateFrom) query = query.gte('transaction_date', dateFrom);
    if (dateTo) query = query.lte('transaction_date', dateTo);

    const { data, error } = await query;
    setRows(error ? [] : (data as LedgerRow[]) ?? []);
    setLoading(false);
  };

  useEffect(() => {
    runSearch();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [currency, accountId]);

  let running = 0;
  const withBalance = rows.map((r) => {
    running += Number(r.debit) - Number(r.credit);
    return { ...r, balance: running };
  });

  const selectedAccount = accounts.find((a) => a.id === accountId);

  return (
    <Box>
      <Typography variant="h5" gutterBottom>
        Current Account Extract {currency === 'USD' && '(USD)'}
      </Typography>

      <Paper sx={{ p: 2, mb: 2 }}>
        <Box sx={{ display: 'flex', gap: 2, flexWrap: 'wrap', alignItems: 'center' }}>
          <TextField
            select
            label="Account"
            value={accountId}
            onChange={(e) => setAccountId(e.target.value)}
            sx={{ minWidth: 300 }}
            size="small"
          >
            <MenuItem value="">Select an account</MenuItem>
            {accounts.map((a) => (
              <MenuItem key={a.id} value={a.id}>
                {a.account_code} — {a.name} ({a.account_type})
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
          <Button variant="contained" onClick={runSearch} disabled={loading || !accountId}>
            Search
          </Button>
          <Button
            variant="outlined"
            onClick={() => {
              setDateFrom('');
              setDateTo('');
            }}
          >
            Clear dates
          </Button>
        </Box>
      </Paper>

      {!accountId && (
        <Typography color="text.secondary">Select an account to view its statement.</Typography>
      )}

      {accountId && (
        <TableContainer component={Paper}>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>Source</TableCell>
                <TableCell>Reference</TableCell>
                <TableCell>Date</TableCell>
                <TableCell align="right">Debit</TableCell>
                <TableCell align="right">Credit</TableCell>
                <TableCell align="right">Balance</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {withBalance.map((r) => (
                <TableRow key={`${r.source_type}-${r.source_id}`}>
                  <TableCell>{SOURCE_LABELS[r.source_type]}</TableCell>
                  <TableCell>{r.reference_no ?? '—'}</TableCell>
                  <TableCell>{r.transaction_date}</TableCell>
                  <TableCell align="right">
                    {Number(r.debit) > 0 ? Number(r.debit).toLocaleString() : ''}
                  </TableCell>
                  <TableCell align="right">
                    {Number(r.credit) > 0 ? Number(r.credit).toLocaleString() : ''}
                  </TableCell>
                  <TableCell align="right">{r.balance.toLocaleString()}</TableCell>
                </TableRow>
              ))}
              {withBalance.length === 0 && !loading && (
                <TableRow>
                  <TableCell colSpan={6} align="center">
                    No transactions on this account for the selected filters.
                  </TableCell>
                </TableRow>
              )}
            </TableBody>
          </Table>
        </TableContainer>
      )}

      {selectedAccount && withBalance.length > 0 && (
        <Typography variant="subtitle2" sx={{ mt: 1 }}>
          Closing balance: {running.toLocaleString()} {currency}
        </Typography>
      )}
    </Box>
  );
}