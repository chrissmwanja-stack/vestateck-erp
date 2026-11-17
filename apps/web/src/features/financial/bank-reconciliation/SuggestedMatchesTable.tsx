import {
  Alert,
  Box,
  Button,
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
import type { SuggestedMatch } from './types';

// The suggest-and-confirm queue (migration 20261117170000).
//
// Suggestions are questions, not decisions: the RPC behind this table writes
// nothing. Confirming one calls fin_bank_confirm_match, which routes to the
// existing match RPC and so keeps every validation, the insurance third-user
// rule and the audit trail intact.
//
// `needs_third_user` is shown before the attempt rather than only surfacing as
// an error afterwards -- but it is a hint, not the enforcement. The database
// refuses the match either way.

export function SuggestedMatchesTable({
  suggestions,
  loading,
  error,
  busyId,
  onConfirm,
  onSelectLine,
}: {
  suggestions: SuggestedMatch[];
  loading: boolean;
  error: string | null;
  busyId: string | null;
  onConfirm: (s: SuggestedMatch) => void;
  onSelectLine: (statementLineId: string) => void;
}) {
  // Group by statement line so one line's alternatives read together.
  const byLine = new Map<string, SuggestedMatch[]>();
  for (const s of suggestions) {
    const list = byLine.get(s.statement_line_id) ?? [];
    list.push(s);
    byLine.set(s.statement_line_id, list);
  }
  const lines = [...byLine.entries()];

  if (error) {
    return (
      <Alert severity="warning" sx={{ mb: 2 }}>
        Suggested matches could not be loaded ({error}). You can still match by hand.
      </Alert>
    );
  }

  if (loading) {
    return (
      <Paper sx={{ p: 2, mb: 2 }}>
        <Typography variant="body2" color="text.secondary">
          Looking for possible matches…
        </Typography>
      </Paper>
    );
  }

  if (lines.length === 0) {
    return null;
  }

  return (
    <TableContainer component={Paper} sx={{ mb: 2 }}>
      <Box sx={{ p: 1.5, pb: 0 }}>
        <Typography variant="subtitle2">
          Suggested matches ({lines.length} line{lines.length === 1 ? '' : 's'})
        </Typography>
        <Typography variant="caption" color="text.secondary">
          Nothing has been matched yet — confirming records your decision as a reviewed match.
        </Typography>
      </Box>
      <Table size="small">
        <TableHead>
          <TableRow>
            <TableCell>Statement line</TableCell>
            <TableCell>Suggested book entry</TableCell>
            <TableCell align="right">Amount</TableCell>
            <TableCell align="right">Days apart</TableCell>
            <TableCell align="right">Action</TableCell>
          </TableRow>
        </TableHead>
        <TableBody>
          {lines.map(([lineId, group]) =>
            group.map((s, idx) => (
              <TableRow key={`${s.statement_line_id}-${s.source}-${s.candidate_id}`} hover>
                {idx === 0 && (
                  <TableCell rowSpan={group.length}>
                    <Typography variant="body2">{s.statement_date}</Typography>
                    <Typography variant="caption" color="text.secondary" display="block">
                      {s.reference ?? 'no reference'}
                    </Typography>
                    <Typography variant="caption" display="block">
                      {Number(s.line_amount).toLocaleString()} {s.currency}
                    </Typography>
                    <Button size="small" onClick={() => onSelectLine(lineId)}>
                      Pick by hand
                    </Button>
                  </TableCell>
                )}
                <TableCell>
                  <Typography variant="body2">{s.candidate_ref ?? s.candidate_id}</Typography>
                  <Typography variant="caption" color="text.secondary" display="block">
                    {s.source.replace('_', ' ')}
                    {s.candidate_date ? ` · ${s.candidate_date}` : ''}
                  </Typography>
                  {s.needs_third_user && (
                    <Chip
                      size="small"
                      variant="outlined"
                      color="warning"
                      label="Needs a third Finance user"
                      sx={{ mt: 0.5 }}
                    />
                  )}
                </TableCell>
                <TableCell align="right">
                  {s.candidate_amount === null ? '—' : Number(s.candidate_amount).toLocaleString()}
                </TableCell>
                <TableCell align="right">{s.day_gap ?? '—'}</TableCell>
                <TableCell align="right">
                  <Button
                    size="small"
                    variant={idx === 0 ? 'contained' : 'outlined'}
                    disabled={busyId === s.candidate_id}
                    onClick={() => onConfirm(s)}
                  >
                    {busyId === s.candidate_id ? 'Confirming…' : 'Confirm'}
                  </Button>
                </TableCell>
              </TableRow>
            )),
          )}
        </TableBody>
      </Table>
    </TableContainer>
  );
}
