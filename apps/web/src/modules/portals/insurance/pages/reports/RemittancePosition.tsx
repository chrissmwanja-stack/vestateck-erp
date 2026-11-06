import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Box, Card, CardContent, Chip, CircularProgress, MenuItem, Stack, Table, TableBody,
  TableCell, TableHead, TableRow, TextField,
} from '@mui/material';
import { errorText, rpc } from '../../db';
import { localIsoDate } from '../../fx';
import { formatMoney } from '../../logic';
import { EmptyRow, ErrorBanner, PageHeader } from '../../shared';

// Per-insurer remittance position (slice R1): what the brokerage has
// collected and not yet remitted to each insurer, per currency, with the
// earliest remittance deadline and overdue flag. Read-only; remittances
// themselves are recorded through the policy cash pages.

type PositionStatus = 'overdue' | 'due_today' | 'within_deadline' | 'deadline_not_set' | 'receipt_date_missing';

interface PositionRow {
  insurer_id: string;
  insurer_name: string;
  currency: string;
  unremitted_amount: number;
  earliest_receipt: string | null;
  earliest_deadline: string | null;
  status: PositionStatus;
}

const STATUS_COLOR: Record<PositionStatus, 'error' | 'warning' | 'success' | 'default'> = {
  overdue: 'error',
  due_today: 'warning',
  within_deadline: 'success',
  deadline_not_set: 'default',
  receipt_date_missing: 'default',
};

const STATUS_LABEL: Record<PositionStatus, string> = {
  overdue: 'Overdue',
  due_today: 'Due today',
  within_deadline: 'Within deadline',
  deadline_not_set: 'Deadline not set',
  receipt_date_missing: 'Receipt date missing',
};

export default function RemittancePosition() {
  const [asOf, setAsOf] = useState(localIsoDate());
  const [items, setItems] = useState<PositionRow[]>([]);
  const [filter, setFilter] = useState<'all' | PositionStatus>('all');
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const rows = (await rpc<PositionRow[]>('ins_insurer_remittance_position', { p_as_of: asOf })) ?? [];
      setItems(rows);
      setError(null);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setLoading(false);
    }
  }, [asOf]);

  useEffect(() => { load(); }, [load]);

  const visible = useMemo(
    () => items.filter((r) => filter === 'all' || r.status === filter),
    [items, filter],
  );

  return (
    <Box>
      <PageHeader
        title="Remittance position by insurer"
        subtitle="Collected premium not yet remitted, per insurer and currency, with the earliest remittance deadline."
      />
      <ErrorBanner message={error} />
      <Stack direction="row" spacing={2} sx={{ mb: 2 }}>
        <TextField label="As of" type="date" size="small" InputLabelProps={{ shrink: true }}
          value={asOf} onChange={(e) => setAsOf(e.target.value)} />
        <TextField select label="Status" size="small" value={filter} sx={{ minWidth: 180 }}
          onChange={(e) => setFilter(e.target.value as 'all' | PositionStatus)}>
          <MenuItem value="all">All</MenuItem>
          {Object.keys(STATUS_LABEL).map((s) => (
            <MenuItem key={s} value={s}>{STATUS_LABEL[s as PositionStatus]}</MenuItem>
          ))}
        </TextField>
      </Stack>
      {loading ? (
        <CircularProgress />
      ) : (
        <Card><CardContent>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>Insurer</TableCell>
                <TableCell>Currency</TableCell>
                <TableCell align="right">Unremitted</TableCell>
                <TableCell>Earliest receipt</TableCell>
                <TableCell>Earliest deadline</TableCell>
                <TableCell>Status</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {visible.length === 0 && <EmptyRow colSpan={6} text="Nothing unremitted." />}
              {visible.map((r) => (
                <TableRow key={`${r.insurer_id}-${r.currency}`}>
                  <TableCell>{r.insurer_name}</TableCell>
                  <TableCell>{r.currency}</TableCell>
                  <TableCell align="right">{formatMoney(r.unremitted_amount, r.currency)}</TableCell>
                  <TableCell>{r.earliest_receipt ?? '—'}</TableCell>
                  <TableCell>{r.earliest_deadline ?? '—'}</TableCell>
                  <TableCell>
                    <Chip size="small" label={STATUS_LABEL[r.status]} color={STATUS_COLOR[r.status]} />
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </CardContent></Card>
      )}
    </Box>
  );
}
