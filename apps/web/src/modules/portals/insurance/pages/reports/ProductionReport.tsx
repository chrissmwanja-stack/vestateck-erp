import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Alert, Box, Button, Card, CardContent, CircularProgress, FormControlLabel, MenuItem, Stack, Switch, Table, TableBody, TableCell,
  TableHead, TableRow, TextField, Typography,
} from '@mui/material';
import { exportReportToExcel, exportReportToPdf } from '../../../../../lib/reportExport';
import { errorText, rpc } from '../../db';
import { localIsoDate } from '../../fx';
import { formatMoney, formatMoneyByCurrency, sumByCurrency } from '../../logic';
import { REPORT_GROUPS, groupLabel, monthStartIso, productionColumns, type ProductionLine, type ReportGroupBy } from '../../reportsSuite';
import { EmptyRow, ErrorBanner, PageHeader } from '../../shared';

// Net written premium for a period, from posted records: premium bound, endorsements, cancellations and
// reversals each counted on the day they took effect. Read-only; the server does all the arithmetic.
export default function ProductionReport() {
  const [from, setFrom] = useState(monthStartIso());
  const [to, setTo] = useState(localIsoDate());
  const [groupBy, setGroupBy] = useState<ReportGroupBy>('product_line');
  const [imported, setImported] = useState(false);
  const [items, setItems] = useState<ProductionLine[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const data = await rpc<ProductionLine[]>('ins_report_production', {
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

  const totals = useMemo(() => sumByCurrency(items, (r) => r.currency, (r) => r.net_written, 'UGX'), [items]);
  const columns = productionColumns(groupLabel(groupBy));
  const exportName = `production-${from}-to-${to}`;
  const subtitle = `${from} to ${to}  |  By ${groupLabel(groupBy).toLowerCase()}${imported ? '  |  Includes imported policies' : ''}`;

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <PageHeader
        title="Production"
        subtitle="Net premium written in the period, after endorsements, cancellations and reversals."
        actions={
          <Stack direction="row" spacing={1} alignItems="center" sx={{ flexWrap: 'wrap', gap: 1 }}>
            <TextField size="small" type="date" label="From" InputLabelProps={{ shrink: true }} value={from} onChange={(e) => setFrom(e.target.value)} />
            <TextField size="small" type="date" label="To" InputLabelProps={{ shrink: true }} value={to} onChange={(e) => setTo(e.target.value)} />
            <TextField select size="small" label="Group by" value={groupBy} onChange={(e) => setGroupBy(e.target.value as ReportGroupBy)} sx={{ minWidth: 150 }}>
              {REPORT_GROUPS.map((g) => <MenuItem key={g.value} value={g.value}>{g.label}</MenuItem>)}
            </TextField>
            {!loading && items.length > 0 && (
              <>
                <Button variant="outlined" onClick={() => exportReportToExcel(exportName, 'Production', columns, items)}>Export Excel</Button>
                <Button variant="outlined" onClick={() => exportReportToPdf(exportName, 'Production', columns, items, subtitle)}>Export PDF</Button>
              </>
            )}
          </Stack>
        }
      />
      <ErrorBanner message={error} />
      {from > to && <Alert severity="warning" sx={{ mb: 2 }}>The start date must not be after the end date.</Alert>}
      <Alert severity="info" sx={{ mb: 2 }}>
        Premium only: broker fees, charges and VAT are not production. Each movement counts on the day it took effect, so a cancellation
        reduces the period it was posted in, not the period of the original sale. Currencies are never added together.
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
                    <TableCell>{groupLabel(groupBy)}</TableCell>
                    <TableCell>Currency</TableCell>
                    <TableCell align="right">New business</TableCell>
                    <TableCell align="right">Endorsements</TableCell>
                    <TableCell align="right">Cancellations</TableCell>
                    <TableCell align="right">Reversals</TableCell>
                    <TableCell align="right">Net written</TableCell>
                    <TableCell align="right">Policies</TableCell>
                  </TableRow>
                </TableHead>
                <TableBody>
                  {items.length === 0 ? (
                    <EmptyRow colSpan={8} text="No premium was written in this period." />
                  ) : (
                    items.map((r) => (
                      <TableRow key={`${r.group_key}|${r.currency}`}>
                        <TableCell>{r.group_label}</TableCell>
                        <TableCell>{r.currency}</TableCell>
                        <TableCell align="right">{formatMoney(Number(r.new_business), r.currency)}</TableCell>
                        <TableCell align="right">{formatMoney(Number(r.endorsements), r.currency)}</TableCell>
                        <TableCell align="right">{formatMoney(Number(r.cancellations), r.currency)}</TableCell>
                        <TableCell align="right">{formatMoney(Number(r.reversals), r.currency)}</TableCell>
                        <TableCell align="right" sx={{ fontWeight: 600 }}>{formatMoney(Number(r.net_written), r.currency)}</TableCell>
                        <TableCell align="right">{r.policy_count}</TableCell>
                      </TableRow>
                    ))
                  )}
                </TableBody>
              </Table>
            </CardContent>
          </Card>
          {items.length > 0 && (
            <Typography variant="body2" sx={{ mt: 2, whiteSpace: 'pre-line' }}>
              <strong>Net written premium:</strong>{'\n'}{formatMoneyByCurrency(totals, 'UGX')}
            </Typography>
          )}
        </>
      )}
    </Box>
  );
}
