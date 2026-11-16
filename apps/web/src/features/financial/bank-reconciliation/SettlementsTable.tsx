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
import type { BookSource, SettlementRow } from './types';

export function SettlementsTable({ settlements, isSelected, toggleBook, amountMatchesLine }: {
  settlements: SettlementRow[];
  isSelected: (source: BookSource, id: string) => boolean;
  toggleBook: (source: BookSource, id: string) => void;
  amountMatchesLine: (signed: number) => boolean;
}) {
  return (
    <TableContainer component={Paper}>
      <Box sx={{ p: 1.5, pb: 0 }}>
        <Typography variant="subtitle2">Book — Open Settlements ({settlements.length})</Typography>
      </Box>
      <Table size="small">
        <TableHead>
          <TableRow>
            <TableCell />
            <TableCell>Date</TableCell>
            <TableCell>Settlement</TableCell>
            <TableCell align="right">Amount</TableCell>
          </TableRow>
        </TableHead>
        <TableBody>
          {settlements.map((s) => {
            const signed = s.direction === 'in' ? Number(s.amount) : -Number(s.amount);
            return (
              <TableRow
                key={s.id}
                hover
                selected={isSelected('settlement', s.id)}
                onClick={() => toggleBook('settlement', s.id)}
                sx={{ cursor: 'pointer' }}
              >
                <TableCell padding="checkbox">
                  <Chip size="small" label={isSelected('settlement', s.id) ? 'Selected' : ''} sx={{ visibility: isSelected('settlement', s.id) ? 'visible' : 'hidden' }} color="primary" />
                </TableCell>
                <TableCell>{s.settlement_date}</TableCell>
                <TableCell>
                  {s.settlement_no ?? '—'}
                  <Typography variant="caption" color="text.secondary" display="block">
                    {s.direction === 'in' ? 'Money in' : 'Money out'}
                    {s.reference ? ` · Ref: ${s.reference}` : ''}
                  </Typography>
                  {amountMatchesLine(signed) && (
                    <Chip size="small" variant="outlined" color="success" label="Amount matches" sx={{ mt: 0.5 }} />
                  )}
                </TableCell>
                <TableCell align="right">
                  {signed.toLocaleString()}
                  <Typography variant="caption" color="text.secondary" display="block">
                    {s.currency}
                  </Typography>
                </TableCell>
              </TableRow>
            );
          })}
          {settlements.length === 0 && (
            <TableRow>
              <TableCell colSpan={4} align="center" sx={{ color: 'text.secondary', py: 3 }}>
                No open settlements near this window.
              </TableCell>
            </TableRow>
          )}
        </TableBody>
      </Table>
    </TableContainer>
  );
}
