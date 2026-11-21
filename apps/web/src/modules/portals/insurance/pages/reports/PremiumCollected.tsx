import { businessToday } from '../../../../../lib/businessDate';
import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Alert, Box, Button, Card, CardContent, CircularProgress, MenuItem, Stack, Table, TableBody, TableCell, TableHead, TableRow,
  TextField, Typography,
} from '@mui/material';
import { exportReportToExcel, exportReportToPdf } from '../../../../../lib/reportExport';
import { errorText, rpc } from '../../db';
import { formatMoney, formatMoneyByCurrency, sumByCurrency } from '../../logic';
import { REPORT_GROUPS, collectedColumns, groupLabel, monthStartIso, type CollectedLine, type ReportGroupBy } from '../../reportsSuite';
import { EmptyRow, ErrorBanner, PageHeader } from '../../shared';

// Cash received from clients against premium invoices in a period, from approved and posted receipts.
// A receipt that was voided on or before the end of the period is not counted. Read-only.
export default function PremiumCollected() {
  const [from, setFrom] = useState(monthStartIso());
  const [to, setTo] = useState(businessToday());
  const [groupBy, setGroupBy] = useState<ReportGroupBy>('month');
  const [items, setItems] = useState<CollectedLine[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const data = await rpc<CollectedLine[]>('ins_report_premium_collected', { p_from: from, p_to: to, p_group_by: groupBy });
      setItems(data ?? []);
      setError(null);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setLoading(false);
    }
  }, [from, to, groupBy]);

  useEffect(() => {
    if (!from || !to || from > to) { setLoading(false); return; }
    load();
  }, [from, to, load]);

  const totals = useMemo(() => sumByCurrency(items, (r) => r.currency, (r) => r.collected, 'UGX'), [items]);
  const columns = collectedColumns(groupLabel(groupBy));
  const exportName = `premium-collected-${from}-to-${to}`;
  const subtitle = `${from} to ${to}  |  By ${groupLabel(groupBy).toLowerCase()}`;

  return (
    <Box sx={{ p: 3, maxWidth: 1000 }}>
      <PageHeader
        title="Premium collected"
        subtitle="Money received from clients against premium invoices in the period."
        actions={
          <Stack direction="row" spacing={1} alignItems="center" sx={{ flexWrap: 'wrap', gap: 1 }}>
            <TextField size="small" type="date" label="From" InputLabelProps={{ shrink: true }} value={from} onChange={(e) => setFrom(e.target.value)} />
            <TextField size="small" type="date" label="To" InputLabelProps={{ shrink: true }} value={to} onChange={(e) => setTo(e.target.value)} />
            <TextField select size="small" label="Group by" value={groupBy} onChange={(e) => setGroupBy(e.target.value as ReportGroupBy)} sx={{ minWidth: 150 }}>
              {REPORT_GROUPS.map((g) => <MenuItem key={g.value} value={g.value}>{g.label}</MenuItem>)}
            </TextField>
            {!loading && items.length > 0 && (
              <>
                <Button variant="outlined" onClick={() => exportReportToExcel(exportName, 'Premium collected', columns, items)}>Export Excel</Button>
                <Button variant="outlined" onClick={() => exportReportToPdf(exportName, 'Premium collected', columns, items, subtitle)}>Export PDF</Button>
              </>
            )}
          </Stack>
        }
      />
      <ErrorBanner message={error} />
      {from > to && <Alert severity="warning" sx={{ mb: 2 }}>The start date must not be after the end date.</Alert>}
      <Alert severity="info" sx={{ mb: 2 }}>
        Counted by receipt date. A client invoice carries the premium together with any charges and VAT billed with it, so this figure
        includes them. A receipt still waiting for approval is not collected yet. Currencies are never added together.
      </Alert>
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
                    <TableCell align="right">Collected</TableCell>
                    <TableCell align="right">Receipts</TableCell>
                  </TableRow>
                </TableHead>
                <TableBody>
                  {items.length === 0 ? (
                    <EmptyRow colSpan={4} text="No premium was collected in this period." />
                  ) : (
                    items.map((r) => (
                      <TableRow key={`${r.group_key}|${r.currency}`}>
                        <TableCell>{r.group_label}</TableCell>
                        <TableCell>{r.currency}</TableCell>
                        <TableCell align="right" sx={{ fontWeight: 600 }}>{formatMoney(Number(r.collected), r.currency)}</TableCell>
                        <TableCell align="right">{r.receipt_count}</TableCell>
                      </TableRow>
                    ))
                  )}
                </TableBody>
              </Table>
            </CardContent>
          </Card>
          {items.length > 0 && (
            <Typography variant="body2" sx={{ mt: 2, whiteSpace: 'pre-line' }}>
              <strong>Total collected:</strong>{'\n'}{formatMoneyByCurrency(totals, 'UGX')}
            </Typography>
          )}
        </>
      )}
    </Box>
  );
}
