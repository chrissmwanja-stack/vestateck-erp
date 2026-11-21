import { useCallback, useEffect, useState } from 'react';
import {
  Alert, Box, Button, Card, CardContent, CircularProgress, FormControlLabel, MenuItem, Stack, Switch, Table, TableBody, TableCell,
  TableHead, TableRow, TextField,
} from '@mui/material';
import { exportReportToExcel, exportReportToPdf } from '../../../../../lib/reportExport';
import { errorText, rpc } from '../../db';
import { localIsoDate } from '../../fx';
import { formatMoney } from '../../logic';
import {
  CANCELLATION_GROUPS, cancellationGroupLabel, formatPct, renewalRetentionColumns, type CancellationGroupBy, type RenewalRetentionLine,
} from '../../reportsSuite';
import { EmptyRow, ErrorBanner, PageHeader } from '../../shared';

// Renewal retention for policies that expired in the period, grouped. The server computes the percentages from the
// same rows the Renewals report lists. Read-only.
export default function RenewalRetention() {
  const [from, setFrom] = useState(`${new Date().getFullYear()}-01-01`);
  const [to, setTo] = useState(localIsoDate());
  const [groupBy, setGroupBy] = useState<CancellationGroupBy>('month');
  const [imported, setImported] = useState(true);
  const [items, setItems] = useState<RenewalRetentionLine[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      setItems((await rpc<RenewalRetentionLine[]>('ins_report_renewal_retention', {
        p_from: from, p_to: to, p_group_by: groupBy, p_include_imported: imported,
      })) ?? []);
      setError(null);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setLoading(false);
    }
  }, [from, to, groupBy, imported]);

  useEffect(() => {
    if (!from || !to || from > to) { setLoading(false); return; }
    load();
  }, [from, to, load]);

  const columns = renewalRetentionColumns(cancellationGroupLabel(groupBy));
  const exportName = `renewal-retention-${from}-to-${to}`;
  const subtitle = `Expiring ${from} to ${to}  |  By ${cancellationGroupLabel(groupBy).toLowerCase()}${imported ? '' : '  |  Excludes imported policies'}`;

  return (
    <Box sx={{ p: 3, maxWidth: 1500 }}>
      <PageHeader
        title="Renewal retention"
        subtitle="How much of the business that fell due was renewed."
        actions={
          <Stack direction="row" spacing={1} alignItems="center" sx={{ flexWrap: 'wrap', gap: 1 }}>
            <TextField size="small" type="date" label="Expiring from" InputLabelProps={{ shrink: true }} value={from} onChange={(e) => setFrom(e.target.value)} />
            <TextField size="small" type="date" label="Expiring to" InputLabelProps={{ shrink: true }} value={to} onChange={(e) => setTo(e.target.value)} />
            <TextField select size="small" label="Group by" value={groupBy} onChange={(e) => setGroupBy(e.target.value as CancellationGroupBy)} sx={{ minWidth: 150 }}>
              {CANCELLATION_GROUPS.map((g) => <MenuItem key={g.value} value={g.value}>{g.label}</MenuItem>)}
            </TextField>
            {!loading && items.length > 0 && (
              <>
                <Button variant="outlined" onClick={() => exportReportToExcel(exportName, 'Renewal retention', columns, items)}>Export Excel</Button>
                <Button variant="outlined" onClick={() => exportReportToPdf(exportName, 'Renewal retention', columns, items, subtitle)}>Export PDF</Button>
              </>
            )}
          </Stack>
        }
      />
      <ErrorBanner message={error} />
      {from > to && <Alert severity="warning" sx={{ mb: 2 }}>The start date must not be after the end date.</Alert>}
      <Alert severity="info" sx={{ mb: 2 }}>
        Retention by count is renewed divided by policies due, leaving out policies that have not expired yet. Retention by premium is the
        renewal premium divided by the expiring premium of the same policies, so it can pass 100% when renewal premiums are higher.
        A dash means nothing in the group has expired yet. This is the position today. Percentages are never averaged across currencies.
      </Alert>
      <FormControlLabel
        sx={{ mb: 1 }}
        control={<Switch checked={imported} onChange={(e) => setImported(e.target.checked)} />}
        label="Include policies imported as an opening book"
      />
      {loading ? (
        <Box sx={{ display: 'flex', justifyContent: 'center', py: 6 }}><CircularProgress /></Box>
      ) : (
        <Card>
          <CardContent sx={{ p: 0, overflowX: 'auto' }}>
            <Table size="small">
              <TableHead>
                <TableRow>
                  <TableCell>{cancellationGroupLabel(groupBy)}</TableCell>
                  <TableCell>Currency</TableCell>
                  <TableCell align="right">Due</TableCell>
                  <TableCell align="right">Renewed</TableCell>
                  <TableCell align="right">Lost</TableCell>
                  <TableCell align="right">Not resolved</TableCell>
                  <TableCell align="right">Upcoming</TableCell>
                  <TableCell align="right">Expiring premium</TableCell>
                  <TableCell align="right">Renewed premium</TableCell>
                  <TableCell align="right">Retention (count)</TableCell>
                  <TableCell align="right">Retention (premium)</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {items.length === 0 ? (
                  <EmptyRow colSpan={11} text="No policies fall due in this period." />
                ) : (
                  items.map((r) => (
                    <TableRow key={`${r.group_key}|${r.currency}`}>
                      <TableCell>{r.group_label}</TableCell>
                      <TableCell>{r.currency}</TableCell>
                      <TableCell align="right">{r.due_count}</TableCell>
                      <TableCell align="right">{r.renewed_count}</TableCell>
                      <TableCell align="right">{r.lost_count}</TableCell>
                      <TableCell align="right">{r.unresolved_count}</TableCell>
                      <TableCell align="right">{r.upcoming_count}</TableCell>
                      <TableCell align="right">{formatMoney(Number(r.expiring_premium), r.currency)}</TableCell>
                      <TableCell align="right">{formatMoney(Number(r.renewed_premium), r.currency)}</TableCell>
                      <TableCell align="right" sx={{ fontWeight: 600 }}>{formatPct(r.retention_count_pct)}</TableCell>
                      <TableCell align="right" sx={{ fontWeight: 600 }}>{formatPct(r.retention_premium_pct)}</TableCell>
                    </TableRow>
                  ))
                )}
              </TableBody>
            </Table>
          </CardContent>
        </Card>
      )}
    </Box>
  );
}
