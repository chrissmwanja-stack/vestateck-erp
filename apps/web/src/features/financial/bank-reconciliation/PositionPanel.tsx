import {
  Alert,
  Paper,
  Table,
  TableBody,
  TableCell,
  TableRow,
  Typography,
} from '@mui/material';
import { fmt } from './utils';
import type { PositionRow } from './types';

export function PositionPanel({ position, positionError, dateTo }: {
  position: PositionRow[] | null;
  positionError: string | null;
  dateTo: string;
}) {
  const unexplained = position?.find((p) => p.component === 'unexplained_difference')?.amount ?? null;

  return (
    <Paper sx={{ p: 2, mb: 2 }} data-testid="position-panel">
      <Typography variant="subtitle1" sx={{ mb: 1 }}>
        Reconciliation Position — as of {dateTo}
      </Typography>
      {positionError ? (
        <Alert severity="warning">{positionError}</Alert>
      ) : position ? (
        <>
          <Table size="small">
            <TableBody>
              {position
                .filter((p) => p.component !== 'unexplained_difference')
                .map((p) => (
                  <TableRow key={p.component}>
                    <TableCell sx={{ fontWeight: p.component === 'expected_statement_balance' ? 600 : 400 }}>
                      {p.label}
                    </TableCell>
                    <TableCell align="right" sx={{ fontWeight: p.component === 'expected_statement_balance' ? 600 : 400 }}>
                      {fmt(p.amount)}
                    </TableCell>
                  </TableRow>
                ))}
            </TableBody>
          </Table>
          <Typography variant="caption" color="text.secondary" display="block" sx={{ mt: 1 }}>
            Statement lines carry no balance, so compare the expected closing balance with the closing balance
            printed on the bank statement.
          </Typography>
          {unexplained != null && (
            <Alert severity={Number(unexplained) === 0 ? 'success' : 'warning'} sx={{ mt: 1.5 }}>
              Unexplained difference: <strong>{fmt(unexplained)}</strong>. This is GL movement on the bank's
              ledger account that reconciliation cannot see (manual journals, opening balances, or bank
              transactions posted to a different GL account). It is not netted into the expected balance above.
            </Alert>
          )}
          {position.some((p) => p.component === 'gl_balance' && p.amount == null) && (
            <Alert severity="info" sx={{ mt: 1.5 }}>
              This bank account has no GL account linked, so the GL-based lines are blank.
            </Alert>
          )}
        </>
      ) : null}
    </Paper>
  );
}
