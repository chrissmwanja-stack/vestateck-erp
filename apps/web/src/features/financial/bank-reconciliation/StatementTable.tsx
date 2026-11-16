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
import { fmt } from './utils';
import type { StatementLine } from './types';

export function StatementTable({ statementLines, selectedStatementLine, setSelectedStatementLine, doubleEntryLineIds }: {
  statementLines: StatementLine[];
  selectedStatementLine: string | null;
  setSelectedStatementLine: (id: string | null) => void;
  doubleEntryLineIds: Set<string>;
}) {
  return (
    <TableContainer component={Paper} sx={{ flex: 1 }}>
      <Box sx={{ p: 1.5, pb: 0 }}>
        <Typography variant="subtitle2">Statement — Unmatched ({statementLines.length})</Typography>
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
          {statementLines.map((l) => (
            <TableRow
              key={l.id}
              hover
              selected={selectedStatementLine === l.id}
              onClick={() => setSelectedStatementLine(l.id === selectedStatementLine ? null : l.id)}
              sx={{ cursor: 'pointer' }}
            >
              <TableCell padding="checkbox">
                <Chip size="small" label={selectedStatementLine === l.id ? 'Selected' : ''} sx={{ visibility: selectedStatementLine === l.id ? 'visible' : 'hidden' }} color="primary" />
              </TableCell>
              <TableCell>{l.statement_date}</TableCell>
              <TableCell>
                {l.description ?? '—'}
                {l.reference && (
                  <Typography variant="caption" color="text.secondary" display="block">
                    Ref: {l.reference}
                  </Typography>
                )}
                {doubleEntryLineIds.has(l.id) && (
                  <Chip size="small" color="warning" label="Possible double entry" sx={{ mt: 0.5 }} />
                )}
              </TableCell>
              <TableCell align="right">{fmt(l.amount)}</TableCell>
            </TableRow>
          ))}
          {statementLines.length === 0 && (
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
