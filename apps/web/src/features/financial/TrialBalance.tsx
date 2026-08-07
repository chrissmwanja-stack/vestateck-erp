import { useEffect, useState } from 'react';
import {
  Box,
  Paper,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  Typography,
} from '@mui/material';
import { useSearchParams } from 'react-router-dom';
import { supabase } from '../../lib/supabaseClient';

interface TrialBalanceRow {
  account_id: string;
  account_code: string;
  account_name: string;
  category_name: string | null;
  currency: string | null;
  total_debit: number | null;
  total_credit: number | null;
  balance: number | null;
}

export default function TrialBalance() {
  const [searchParams] = useSearchParams();
  const currency = searchParams.get('ccy') === 'USD' ? 'USD' : 'UGX';

  const [rows, setRows] = useState<TrialBalanceRow[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    setLoading(true);
    supabase
      .from('v_trial_balance')
      .select('*')
      .eq('currency', currency)
      .order('category_name')
      .then(({ data, error }) => {
        setRows(error ? [] : (data as TrialBalanceRow[]) ?? []);
        setLoading(false);
      });
  }, [currency]);

  const totalDebit = rows.reduce((sum, r) => sum + Number(r.total_debit ?? 0), 0);
  const totalCredit = rows.reduce((sum, r) => sum + Number(r.total_credit ?? 0), 0);
  const totalBalance = rows.reduce((sum, r) => sum + Number(r.balance ?? 0), 0);

  return (
    <Box>
      <Typography variant="h5" gutterBottom>
        Trial Balance {currency === 'USD' && '(USD)'}
      </Typography>

      <TableContainer component={Paper}>
        <Table size="small">
          <TableHead>
            <TableRow>
              <TableCell>Account Code</TableCell>
              <TableCell>Account Name</TableCell>
              <TableCell>Category</TableCell>
              <TableCell align="right">Total Debit</TableCell>
              <TableCell align="right">Total Credit</TableCell>
              <TableCell align="right">Balance</TableCell>
            </TableRow>
          </TableHead>
          <TableBody>
            {rows.map((r) => (
              <TableRow key={r.account_id}>
                <TableCell>{r.account_code}</TableCell>
                <TableCell>{r.account_name}</TableCell>
                <TableCell>{r.category_name ?? '—'}</TableCell>
                <TableCell align="right">{Number(r.total_debit ?? 0).toLocaleString()}</TableCell>
                <TableCell align="right">{Number(r.total_credit ?? 0).toLocaleString()}</TableCell>
                <TableCell align="right">{Number(r.balance ?? 0).toLocaleString()}</TableCell>
              </TableRow>
            ))}
            {rows.length === 0 && !loading && (
              <TableRow>
                <TableCell colSpan={6} align="center">
                  No accounts with activity in {currency}.
                </TableCell>
              </TableRow>
            )}
          </TableBody>
          {rows.length > 0 && (
            <TableBody>
              <TableRow>
                <TableCell colSpan={3}>
                  <strong>Total</strong>
                </TableCell>
                <TableCell align="right">
                  <strong>{totalDebit.toLocaleString()}</strong>
                </TableCell>
                <TableCell align="right">
                  <strong>{totalCredit.toLocaleString()}</strong>
                </TableCell>
                <TableCell align="right">
                  <strong>{totalBalance.toLocaleString()}</strong>
                </TableCell>
              </TableRow>
            </TableBody>
          )}
        </Table>
      </TableContainer>
    </Box>
  );
}