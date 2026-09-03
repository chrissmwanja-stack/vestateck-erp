import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Alert,
  Box,
  CircularProgress,
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
import { supabase } from '../../lib/supabaseClient';

interface GlAccountOption {
  id: string;
  account_code: string;
  name: string;
}

interface LedgerRow {
  account_id: string;
  source_type: string;
  source_id: string | null;
  reference_no: string | null;
  transaction_date: string;
  debit: number;
  credit: number;
  currency: string;
}

const SOURCE_LABELS: Record<string, string> = {
  supplier_invoice: 'Supplier Invoice',
  receivable_invoice: 'Receivable Invoice',
  cash_bank_transaction: 'Cash/Bank Transaction',
  opening_balance: 'Opening Balance',
  manual: 'Manual Entry',
};

export default function GeneralLedger() {
  const [accounts, setAccounts] = useState<GlAccountOption[]>([]);
  const [accountId, setAccountId] = useState('');
  const [dateFrom, setDateFrom] = useState('');
  const [dateTo, setDateTo] = useState('');
  const [rows, setRows] = useState<LedgerRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const loadAccounts = useCallback(async () => {
    const { data } = await supabase.from('gl_accounts').select('id, account_code, name').order('account_code');
    setAccounts((data ?? []) as GlAccountOption[]);
  }, []);

  const loadLedger = useCallback(async () => {
    setLoading(true);
    setError(null);
    let query = supabase
      .from('v_account_ledger')
      .select('account_id, source_type, source_id, reference_no, transaction_date, debit, credit, currency')
      .order('transaction_date', { ascending: false });

    if (accountId) query = query.eq('account_id', accountId);
    if (dateFrom) query = query.gte('transaction_date', dateFrom);
    if (dateTo) query = query.lte('transaction_date', dateTo);

    const { data, error: err } = await query;
    if (err) {
      setError(err.message);
    } else {
      setRows((data ?? []) as LedgerRow[]);
    }
    setLoading(false);
  }, [accountId, dateFrom, dateTo]);

  useEffect(() => {
    loadAccounts();
  }, [loadAccounts]);

  useEffect(() => {
    loadLedger();
  }, [loadLedger]);

  const accountLookup = useMemo(
    () => new Map(accounts.map((a) => [a.id, `${a.account_code} — ${a.name}`])),
    [accounts]
  );

  const totalDebit = rows.reduce((sum, r) => sum + Number(r.debit ?? 0), 0);
  const totalCredit = rows.reduce((sum, r) => sum + Number(r.credit ?? 0), 0);

  return (
    <Box>
      <Typography variant="h5" gutterBottom>
        General Ledger
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
        Every posted journal line, in one place. Filter by account or date to trace where a balance
        came from.
      </Typography>

      <Paper sx={{ p: 2, mb: 2 }} variant="outlined">
        <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2}>
          <TextField
            select
            label="Account"
            size="small"
            sx={{ flex: 1, minWidth: 220 }}
            value={accountId}
            onChange={(e) => setAccountId(e.target.value)}
          >
            <MenuItem value="">All accounts</MenuItem>
            {accounts.map((a) => (
              <MenuItem key={a.id} value={a.id}>
                {a.account_code} — {a.name}
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
        </Stack>
      </Paper>

      <Paper variant="outlined">
        {error && (
          <Alert severity="error" sx={{ m: 2 }}>
            {error}
          </Alert>
        )}
        {loading ? (
          <Box sx={{ display: 'flex', justifyContent: 'center', py: 4 }}>
            <CircularProgress size={24} />
          </Box>
        ) : (
          <TableContainer>
            <Table size="small">
              <TableHead>
                <TableRow>
                  <TableCell>Date</TableCell>
                  <TableCell>Account</TableCell>
                  <TableCell>Source</TableCell>
                  <TableCell>Reference</TableCell>
                  <TableCell align="right">Debit</TableCell>
                  <TableCell align="right">Credit</TableCell>
                  <TableCell>Currency</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {rows.map((r, i) => (
                  <TableRow key={`${r.source_type}-${r.source_id}-${r.account_id}-${i}`} hover>
                    <TableCell>{r.transaction_date}</TableCell>
                    <TableCell>{accountLookup.get(r.account_id) ?? r.account_id}</TableCell>
                    <TableCell>{SOURCE_LABELS[r.source_type] ?? r.source_type}</TableCell>
                    <TableCell>{r.reference_no ?? '—'}</TableCell>
                    <TableCell align="right">{Number(r.debit ?? 0).toLocaleString()}</TableCell>
                    <TableCell align="right">{Number(r.credit ?? 0).toLocaleString()}</TableCell>
                    <TableCell>{r.currency}</TableCell>
                  </TableRow>
                ))}
                {rows.length === 0 && !loading && (
                  <TableRow>
                    <TableCell colSpan={7} align="center" sx={{ color: 'text.secondary', py: 3 }}>
                      No journal activity for this filter.
                    </TableCell>
                  </TableRow>
                )}
              </TableBody>
              {rows.length > 0 && (
                <TableBody>
                  <TableRow>
                    <TableCell colSpan={4}>
                      <strong>Total</strong>
                    </TableCell>
                    <TableCell align="right">
                      <strong>{totalDebit.toLocaleString()}</strong>
                    </TableCell>
                    <TableCell align="right">
                      <strong>{totalCredit.toLocaleString()}</strong>
                    </TableCell>
                    <TableCell />
                  </TableRow>
                </TableBody>
              )}
            </Table>
          </TableContainer>
        )}
      </Paper>
    </Box>
  );
}