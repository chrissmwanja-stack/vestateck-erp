import {
  Box,
  Chip,
  Paper,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  Typography,
} from '@mui/material';
import type { BookSource, CashBankTxn } from './types';

export function CashTransactionsTable({ cashTxns, isSelected, toggleBook, amountMatchesLine }: {
  cashTxns: CashBankTxn[];
  isSelected: (source: BookSource, id: string) => boolean;
  toggleBook: (source: BookSource, id: string) => void;
  amountMatchesLine: (signed: number) => boolean;
}) {
  return (
    <TableContainer component={Paper}>
      <Box sx={{ p: 1.5, pb: 0 }}>
        <Typography variant="subtitle2">Book — Cash/Bank Transactions ({cashTxns.length})</Typography>
      </Box>
      <Table size="small">
        <TableHead>
          <TableRow>
            <TableCell />
            <TableCell>Date</TableCell>
            <TableCell>Description</TableCell>
            <TableCell align="right">Amount</TableCell>
          </TableRow>
        </TableHead>
        <TableBody>
          {cashTxns.map((t) => {
            const signed = t.transaction_type === 'receipt' ? Number(t.amount) : -Number(t.amount);
            return (
              <TableRow
                key={t.id}
                hover
                selected={isSelected('cash', t.id)}
                onClick={() => toggleBook('cash', t.id)}
                sx={{ cursor: 'pointer' }}
              >
                <TableCell padding="checkbox">
                  <Chip size="small" label={isSelected('cash', t.id) ? 'Selected' : ''} sx={{ visibility: isSelected('cash', t.id) ? 'visible' : 'hidden' }} color="primary" />
                </TableCell>
                <TableCell>{t.transaction_date}</TableCell>
                <TableCell>
                  {t.description ?? '—'}
                  <Typography variant="caption" color="text.secondary" display="block">
                    {t.reference_type.replace('_', ' ')}
                  </Typography>
                  {amountMatchesLine(signed) && (
                    <Chip size="small" variant="outlined" color="success" label="Amount matches" sx={{ mt: 0.5 }} />
                  )}
                </TableCell>
                <TableCell align="right">{signed.toLocaleString()}</TableCell>
              </TableRow>
            );
          })}
          {cashTxns.length === 0 && (
            <TableRow>
              <TableCell colSpan={4} align="center" sx={{ color: 'text.secondary', py: 3 }}>
                Nothing unmatched in this window.
              </TableCell>
            </TableRow>
          )}
        </TableBody>
      </Table>
    </TableContainer>
  );
}
