import { businessToday } from '../../../../../lib/businessDate';
import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Alert, Box, Button, Card, CardContent, CircularProgress, FormControlLabel, MenuItem, Stack, Switch, Table, TableBody, TableCell,
  TableHead, TableRow, TextField, Typography,
} from '@mui/material';
import { exportReportToExcel, exportReportToPdf } from '../../../../../lib/reportExport';
import { errorText, rpc } from '../../db';
import { formatMoney, formatMoneyByCurrency, sumByCurrency } from '../../logic';
import { CANCELLATION_GROUPS, cancellationColumns, cancellationGroupLabel, monthStartIso, type CancellationGroupBy, type CancellationLine } from '../../reportsSuite';
import { EmptyRow, ErrorBanner, PageHeader } from '../../shared';

// Posted cancellations in a period, from the cancellation records: return premium and commission clawed back,
// counted on the posting date. Read-only; the server does all the arithmetic.
export default function CancellationsReport() {
  const [from, setFrom] = useState(monthStartIso());
  const [to, setTo] = useState(businessToday());
  const [groupBy, setGroupBy] = useState<CancellationGroupBy>('product_line');
  const [imported, setImported] = useState(false);
  const [items, setItems] = useState<CancellationLine[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const data = await rpc<CancellationLine[]>('ins_report_cancellations', {
        p_from: from, p_to: to, p_group_by: groupBy, p_include_imported: imported,
      });
      setItems(data ?? []);
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

  const totals = useMemo(() => sumByCurrency(items, (r) => r.currency, (r) => r.return_premium, 'UGX'), [items]);
  const columns = cancellationColumns(cancellationGroupLabel(groupBy));
  const exportName = `cancellations-${from}-to-${to}`;
  const subtitle = `${from} to ${to}  |  By ${cancellationGroupLabel(groupBy).toLowerCase()}${imported ? '  |  Includes imported policies' : ''}`;

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <PageHeader
        title="Cancellations"
        subtitle="Business cancelled in the period: return premium and commission clawed back."
        actions={
          <Stack direction="row" spacing={1} alignItems="center" sx={{ flexWrap: 'wrap', gap: 1 }}>
            <TextField size="small" type="date" label="From" InputLabelProps={{ shrink: true }} value={from} onChange={(e) => setFrom(e.target.value)} />
            <TextField size="small" type="date" label="To" InputLabelProps={{ shrink: true }} value={to} onChange={(e) => setTo(e.target.value)} />
            <TextField select size="small" label="Group by" value={groupBy} onChange={(e) => setGroupBy(e.target.value as CancellationGroupBy)} sx={{ minWidth: 150 }}>
              {CANCELLATION_GROUPS.map((g) => <MenuItem key={g.value} value={g.value}>{g.label}</MenuItem>)}
            </TextField>
            {!loading && items.length > 0 && (
              <>
                <Button variant="outlined" onClick={() => exportReportToExcel(exportName, 'Cancellations', columns, items)}>Export Excel</Button>
                <Button variant="outlined" onClick={() => exportReportToPdf(exportName, 'Cancellations', columns, items, subtitle)}>Export PDF</Button>
              </>
            )}
          </Stack>
        }
      />
      <ErrorBanner message={error} />
      {from > to && <Alert severity="warning" sx={{ mb: 2 }}>The start date must not be after the end date.</Alert>}
      <Alert severity="info" sx={{ mb: 2 }}>
        Posted cancellations only, counted on the day they were posted. Return premium is the same figure production deducts. Currencies are never added together.
      </Alert>
      <FormControlLabel
        sx={{ mb: 1 }}
        control={<Switch checked={imported} onChange={(e) => setImported(e.target.checked)} />}
        label="Include policies imported as an opening book"
      />
      {loading ? (
        <Box sx={{ display: 'flex', justifyContent: 'center', py: 6 }}><CircularProgress /></Box>
      ) : (
        <>
          <Card>
            <CardContent sx={{ p: 0, overflowX: 'auto' }}>
              <Table size="small">
                <TableHead>
                  <TableRow>
                    <TableCell>{cancellationGroupLabel(groupBy)}</TableCell>
                    <TableCell>Currency</TableCell>
                    <TableCell align="right">Cancellations</TableCell>
                    <TableCell align="right">Return premium</TableCell>
                    <TableCell align="right">Commission clawed back</TableCell>
                    <TableCell align="right">Commission retained</TableCell>
                    <TableCell align="right">Insurer credit</TableCell>
                  </TableRow>
                </TableHead>
                <TableBody>
                  {items.length === 0 ? (
                    <EmptyRow colSpan={7} text="No business was cancelled in this period." />
                  ) : (
                    items.map((r) => (
                      <TableRow key={`${r.group_key}|${r.currency}`}>
                        <TableCell>{r.group_label}</TableCell>
                        <TableCell>{r.currency}</TableCell>
                        <TableCell align="right">{r.cancellation_count}</TableCell>
                        <TableCell align="right" sx={{ fontWeight: 600 }}>{formatMoney(Number(r.return_premium), r.currency)}</TableCell>
                        <TableCell align="right">{formatMoney(Number(r.commission_clawback), r.currency)}</TableCell>
                        <TableCell align="right">{formatMoney(Number(r.retained_commission), r.currency)}</TableCell>
                        <TableCell align="right">{formatMoney(Number(r.total_insurer_credit), r.currency)}</TableCell>
                      </TableRow>
                    ))
                  )}
                </TableBody>
              </Table>
            </CardContent>
          </Card>
          {items.length > 0 && (
            <Typography variant="body2" sx={{ mt: 2, whiteSpace: 'pre-line' }}>
              <strong>Return premium:</strong>{'\n'}{formatMoneyByCurrency(totals, 'UGX')}
            </Typography>
          )}
        </>
      )}
    </Box>
  );
}