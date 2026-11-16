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
import type { BookSource, TransferSideRow } from './types';

export function TransferSidesTable({ transferSides, isSelected, toggleBook, amountMatchesLine }: {
  transferSides: TransferSideRow[];
  isSelected: (source: BookSource, id: string) => boolean;
  toggleBook: (source: BookSource, id: string) => void;
  amountMatchesLine: (signed: number) => boolean;
}) {
  return (
    <TableContainer component={Paper} data-testid="transfer-sides-table">
      <Box sx={{ p: 1.5, pb: 0 }}>
        <Typography variant="subtitle2">Book — Open Commission Transfers ({transferSides.length})</Typography>
      </Box>
      <Table size="small">
        <TableHead>
          <TableRow>
            <TableCell />
            <TableCell>Date</TableCell>
            <TableCell>Transfer</TableCell>
            <TableCell align="right">Amount</TableCell>
          </TableRow>
        </TableHead>
        <TableBody>
          {transferSides.map((t) => (
            <TableRow
              key={`${t.id}:${t.side}`}
              hover
              selected={isSelected('transfer', t.id)}
              onClick={() => toggleBook('transfer', t.id)}
              sx={{ cursor: 'pointer' }}
            >
              <TableCell padding="checkbox">
                <Chip size="small" label={isSelected('transfer', t.id) ? 'Selected' : ''} sx={{ visibility: isSelected('transfer', t.id) ? 'visible' : 'hidden' }} color="primary" />
              </TableCell>
              <TableCell>{t.transfer_date}</TableCell>
              <TableCell>
                {t.transfer_no}
                <Typography variant="caption" color="text.secondary" display="block">
                  {t.side === 'from' ? 'Out of this account' : 'Into this account'}
                  {t.notes ? ` · ${t.notes}` : ''}
                </Typography>
                {amountMatchesLine(t.signed) && (
                  <Chip size="small" variant="outlined" color="success" label="Amount matches" sx={{ mt: 0.5 }} />
                )}
              </TableCell>
              <TableCell align="right">
                {t.signed.toLocaleString()}
                <Typography variant="caption" color="text.secondary" display="block">
                  {t.currency}
                </Typography>
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
    </TableContainer>
  );
}
