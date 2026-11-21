import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Alert, Box, Button, Card, CardContent, CircularProgress, FormControlLabel, MenuItem, Stack, Switch, Table, TableBody, TableCell,
  TableHead, TableRow, TextField, Typography,
} from '@mui/material';
import { exportReportToExcel, exportReportToPdf } from '../../../../../lib/reportExport';
import { errorText, rpc } from '../../db';
import { localIsoDate } from '../../fx';
import { formatMoney, formatMoneyByCurrency, sumByCurrency } from '../../logic';
import {
  REPORT_GROUPS, commissionEarnedColumns, groupLabel, monthStartIso, type CommissionEarnedLine, type ReportGroupBy,
} from '../../reportsSuite';
import { EmptyRow, ErrorBanner, PageHeader } from '../../shared';

// Commission recognised as income in a period, read from the commission income account in the ledger.
// Commission still deferred is not income and is not shown. Read-only.
export default function CommissionEarned() {
  const [from, setFrom] = useState(monthStartIso());
  const [to, setTo] = useState(localIsoDate());
  const [groupBy, setGroupBy] = useState<ReportGroupBy>('month');
  const [includeImported, setIncludeImported] = useState(false);
  const [items, setItems] = useState<CommissionEarnedLine[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const data = await rpc<CommissionEarnedLine[]>('ins_report_commission_earned', {
        p_from: from, p_to: to, p_group_by: groupBy, p_include_imported: includeImported,
      });
      setItems(data ?? []);
      setError(null);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setLoading(false);
    }
  }, [from, to, groupBy, includeImported]);

  useEffect(() => {
    if (!from || !to || from > to) { setLoading(false); return; }
    load();
  }, [from, to, load]);

  const totals = useMemo(() => sumByCurrency(items, (r) => r.currency, (r) => r.net_earned, 'UGX'), [items]);
  const columns = commissionEarnedColumns(groupLabel(groupBy));
  const exportName = `commission-earned-${from}-to-${to}`;
  const subtitle = [
    `${from} to ${to}`,
    `By ${groupLabel(groupBy).toLowerCase()}`,
    includeImported ? 'Includes imported policies' : null,
  ].filter(Boolean).join('  |  ');

  return (
    <Box sx={{ p: 3, maxWidth: 1300 }}>
      <PageHeader
        title="Commission earned"
        subtitle="Commission recognised as income in the period."
        actions={
          <Stack direction="row" spacing={1} alignItems="center" sx={{ flexWrap: 'wrap', gap: 1 }}>
            <TextField size="small" type="date" label="From" InputLabelProps={{ shrink: true }} value={from} onChange={(e) => setFrom(e.target.value)} />
            <TextField size="small" type="date" label="To" InputLabelProps={{ shrink: true }} value={to} onChange={(e) => setTo(e.target.value)} />
            <TextField select size="small" label="Group by" value={groupBy} onChange={(e) => setGroupBy(e.target.value as ReportGroupBy)} sx={{ minWidth: 150 }}>
              {REPORT_GROUPS.map((g) => <MenuItem key={g.value} value={g.value}>{g.label}</MenuItem>)}
            </TextField>
            <FormControlLabel
              control={<Switch size="small" checked={includeImported} onChange={(e) => setIncludeImported(e.target.checked)} />}
              label="Include imported policies"
            />
            {!loading && items.length > 0 && (
              <>
                <Button variant="outlined" onClick={() => exportReportToExcel(exportName, 'Commission earned', columns, items)}>Export Excel</Button>
                <Button variant="outlined" onClick={() => exportReportToPdf(exportName, 'Commission earned', columns, items, subtitle)}>Export PDF</Button>
              </>
            )}
          </Stack>
        }
      />
      <ErrorBanner message={error} />
      {from > to && <Alert severity="warning" sx={{ mb: 2 }}>The start date must not be after the end date.</Alert>}
      <Alert severity="info" sx={{ mb: 2 }}>
        Read from the commission income account. With imported policies included, the total equals the ledger movement for the period;
        by default imported policies and opening-balance journals are left out, because opening a book is not earning it. Commission
        deferred until the insurer or the client pays is not income yet and is not shown. A voided entry and its reversal both appear,
        so a void nets to zero. Currencies are never added together.
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
                    <TableCell align="right">At placement</TableCell>
                    <TableCell align="right">On settlement or collection</TableCell>
                    <TableCell align="right">Reversed</TableCell>
                    <TableCell align="right">Cancellations</TableCell>
                    <TableCell align="right">Endorsements</TableCell>
                    <TableCell align="right">Other</TableCell>
                    <TableCell align="right">Net earned</TableCell>
                    <TableCell align="right">Policies</TableCell>
                  </TableRow>
                </TableHead>
                <TableBody>
                  {items.length === 0 ? (
                    <EmptyRow colSpan={10} text="No commission was earned in this period." />
                  ) : (
                    items.map((r) => (
                      <TableRow key={`${r.group_key}|${r.currency}`}>
                        <TableCell>{r.group_label}</TableCell>
                        <TableCell>{r.currency}</TableCell>
                        <TableCell align="right">{formatMoney(Number(r.placement), r.currency)}</TableCell>
                        <TableCell align="right">{formatMoney(Number(r.recognised), r.currency)}</TableCell>
                        <TableCell align="right">{formatMoney(Number(r.reversed), r.currency)}</TableCell>
                        <TableCell align="right">{formatMoney(Number(r.cancellations), r.currency)}</TableCell>
                        <TableCell align="right">{formatMoney(Number(r.endorsements), r.currency)}</TableCell>
                        <TableCell align="right">{formatMoney(Number(r.other), r.currency)}</TableCell>
                        <TableCell align="right" sx={{ fontWeight: 600 }}>{formatMoney(Number(r.net_earned), r.currency)}</TableCell>
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
              <strong>Total commission earned:</strong>{'\n'}{formatMoneyByCurrency(totals, 'UGX')}
            </Typography>
          )}
        </>
      )}
    </Box>
  );
}
