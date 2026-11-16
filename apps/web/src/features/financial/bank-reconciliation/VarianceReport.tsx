import {
  Button,
  Paper,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  Typography,
} from '@mui/material';
import { fmt } from './utils';
import type { VarianceRow } from './types';

export function VarianceReport({ variances, onUnmatch }: {
  variances: VarianceRow[];
  onUnmatch: (reconciliationId: string) => void;
}) {
  return (
    <>
      <Typography variant="subtitle1" sx={{ mb: 1 }}>
        Variance Report — Force-Matched Pairs ({variances.length})
      </Typography>
      <TableContainer component={Paper}>
        <Table size="small">
          <TableHead>
            <TableRow>
              <TableCell>Statement</TableCell>
              <TableCell align="right">Statement Amt</TableCell>
              <TableCell>Book entry</TableCell>
              <TableCell align="right">Book Amt</TableCell>
              <TableCell align="right">Variance</TableCell>
              <TableCell />
            </TableRow>
          </TableHead>
          <TableBody>
            {variances.map((v) => (
              <TableRow key={v.reconciliation_id}>
                <TableCell>
                  {v.statement_date} — {v.statement_description ?? '—'}
                </TableCell>
                <TableCell align="right">{fmt(v.statement_amount)}</TableCell>
                <TableCell>
                  {v.transaction_date} — {v.transaction_description ?? '—'}
                  <Typography variant="caption" color="text.secondary" display="block">
                    {v.source === 'settlement'
                      ? 'Settlement'
                      : v.source === 'commission_transfer'
                        ? 'Commission transfer'
                        : 'Cash/bank transaction'}
                  </Typography>
                </TableCell>
                <TableCell align="right">{fmt(v.transaction_amount)}</TableCell>
                <TableCell align="right">
                  <Typography color={Number(v.variance) === 0 ? 'text.primary' : 'error'} fontWeight={600}>
                    {fmt(v.variance)}
                  </Typography>
                </TableCell>
                <TableCell align="right">
                  <Button size="small" onClick={() => onUnmatch(v.reconciliation_id)}>
                    Undo
                  </Button>
                </TableCell>
              </TableRow>
            ))}
            {variances.length === 0 && (
              <TableRow>
                <TableCell colSpan={6} align="center" sx={{ color: 'text.secondary', py: 3 }}>
                  No force-matched pairs with a variance for this account.
                </TableCell>
              </TableRow>
            )}
          </TableBody>
        </Table>
      </TableContainer>
    </>
  );
}
