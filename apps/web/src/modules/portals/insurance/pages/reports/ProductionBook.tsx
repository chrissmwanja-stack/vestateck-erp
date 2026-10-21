import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Alert, Box, Button, Card, CardContent, CircularProgress, Grid, MenuItem, Stack, Table, TableBody, TableCell,
  TableHead, TableRow, TextField, Typography,
} from '@mui/material';
import { exportReportToExcel, exportReportToPdf, type ReportExportColumn } from '../../../../../lib/reportExport';
import { allRows, errorText, rows, table } from '../../db';
import { formatMoneyByCurrency } from '../../logic';
import { groupProduction, PRODUCTION_GROUPERS, type ProductionGroupBy, type ProductionRow } from '../../reports';
import { EmptyRow, ErrorBanner, PageHeader } from '../../shared';

const firstOfYear = () => `${new Date().getFullYear()}-01-01`;
const today = () => new Date().toISOString().slice(0, 10);

// The production book: business written in a period (bound policies, reversed
// ones excluded by the view), grouped by any reporting dimension -- client,
// insurer, branch, agent, product line, transaction type or status. Money is
// totalled per currency; the read is server-gated (the view re-checks tenant
// and insurance access on every query).
export default function ProductionBook() {
  const [from, setFrom] = useState(firstOfYear());
  const [to, setTo] = useState(today());
  const [groupBy, setGroupBy] = useState<ProductionGroupBy>('client');
  const [bookRows, setBookRows] = useState<ProductionRow[]>([]);
  const [functional, setFunctional] = useState('UGX');
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    if (!from || !to) return;
    setLoading(true);
    try {
      const [book, settings] = await Promise.all([
        allRows<ProductionRow>(() =>
          table('ins_production_book').select('*').gte('bound_date', from).lte('bound_date', to).order('policy_no')),
        rows<{ functional_currency: string }>(table('tenant_ledger_settings').select('functional_currency')),
      ]);
      setBookRows(book);
      setFunctional(settings[0]?.functional_currency ?? 'UGX');
      setError(null);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setLoading(false);
    }
  }, [from, to]);

  useEffect(() => { void load(); }, [load]);

  const groups = useMemo(() => groupProduction(bookRows, groupBy), [bookRows, groupBy]);
  const grouper = PRODUCTION_GROUPERS[groupBy];

  const totals = useMemo(() => ({
    count: bookRows.length,
    gross: sumCurrency(bookRows, (r) => r.currency, (r) => r.gross_premium),
    commission: sumCurrency(bookRows, (r) => r.currency, (r) => r.commission_amount),
    net: sumCurrency(bookRows, (r) => r.currency, (r) => r.net_premium_to_insurer),
  }), [bookRows]);

  // One flat row per group; money already formatted per currency (Excel/PDF
  // show what the screen shows -- currencies are never merged).
  const exportRows = () => groups.map((g) => ({
    group: g.key,
    policies: g.count,
    gross: formatMoneyByCurrency(g.gross, functional).replace(/\n/g, ' | '),
    commission: formatMoneyByCurrency(g.commission, functional).replace(/\n/g, ' | '),
    net: formatMoneyByCurrency(g.net, functional).replace(/\n/g, ' | '),
  }));
  const exportColumns: ReportExportColumn<ReturnType<typeof exportRows>[number]>[] = [
    { header: grouper.label, accessor: (r) => r.group },
    { header: 'Policies', align: 'right', accessor: (r) => r.policies },
    { header: 'Gross premium', align: 'right', accessor: (r) => r.gross },
    { header: 'Commission', align: 'right', accessor: (r) => r.commission },
    { header: 'Net to insurers', align: 'right', accessor: (r) => r.net },
  ];
  const exportName = `production-book-${from}-to-${to}`;

  return (
    <Box sx={{ p: 3 }}>
      <PageHeader
        title="Production book"
        subtitle="Business written in the period, by client, insurer, branch, agent, product line, transaction type or status. Reversed policies are not production."
      />
      <ErrorBanner message={error} />
      <Card>
        <CardContent>
          <Grid container spacing={2} alignItems="center" sx={{ mb: 2 }}>
            <Grid item xs={6} md={3}>
              <TextField fullWidth type="date" label="Written from" InputLabelProps={{ shrink: true }} value={from} onChange={(e) => setFrom(e.target.value)} />
            </Grid>
            <Grid item xs={6} md={3}>
              <TextField fullWidth type="date" label="Written to" InputLabelProps={{ shrink: true }} value={to} onChange={(e) => setTo(e.target.value)} />
            </Grid>
            <Grid item xs={12} md={4}>
              <TextField select fullWidth label="Group by" value={groupBy} onChange={(e) => setGroupBy(e.target.value as ProductionGroupBy)}>
                {(Object.keys(PRODUCTION_GROUPERS) as ProductionGroupBy[]).map((k) => (
                  <MenuItem key={k} value={k}>{PRODUCTION_GROUPERS[k].label}</MenuItem>
                ))}
              </TextField>
            </Grid>
            <Grid item xs={12} md={2}>
              <Stack spacing={1}>
                <Button variant="outlined" onClick={() => void load()}>Refresh</Button>
                <Button variant="outlined" onClick={() => exportReportToExcel(exportName, 'Production book', exportColumns, exportRows())}>Excel</Button>
                <Button variant="outlined" onClick={() => exportReportToPdf(exportName, 'Production book', exportColumns, exportRows(), `Written ${from} to ${to} - grouped by ${grouper.label.toLowerCase()}`)}>PDF</Button>
              </Stack>
            </Grid>
          </Grid>

          {loading ? (
            <Box sx={{ display: 'flex', justifyContent: 'center', py: 4 }}><CircularProgress /></Box>
          ) : (
            <Table size="small">
              <TableHead>
                <TableRow>
                  <TableCell>{grouper.label}</TableCell>
                  <TableCell align="right">Policies</TableCell>
                  <TableCell align="right">Gross premium</TableCell>
                  <TableCell align="right">Commission</TableCell>
                  <TableCell align="right">Net to insurers</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {groups.length === 0 ? (
                  <EmptyRow colSpan={5} text="No business was written in this period." />
                ) : (
                  <>
                    {groups.map((g) => (
                      <TableRow key={g.key}>
                        <TableCell>{g.key}</TableCell>
                        <TableCell align="right">{g.count}</TableCell>
                        <TableCell align="right" sx={{ whiteSpace: 'pre-line' }}>{formatMoneyByCurrency(g.gross, functional)}</TableCell>
                        <TableCell align="right" sx={{ whiteSpace: 'pre-line' }}>{formatMoneyByCurrency(g.commission, functional)}</TableCell>
                        <TableCell align="right" sx={{ whiteSpace: 'pre-line' }}>{formatMoneyByCurrency(g.net, functional)}</TableCell>
                      </TableRow>
                    ))}
                    <TableRow>
                      <TableCell><strong>Total ({totals.count} policies)</strong></TableCell>
                      <TableCell />
                      <TableCell align="right" sx={{ whiteSpace: 'pre-line' }}><strong>{formatMoneyByCurrency(totals.gross, functional)}</strong></TableCell>
                      <TableCell align="right" sx={{ whiteSpace: 'pre-line' }}><strong>{formatMoneyByCurrency(totals.commission, functional)}</strong></TableCell>
                      <TableCell align="right" sx={{ whiteSpace: 'pre-line' }}><strong>{formatMoneyByCurrency(totals.net, functional)}</strong></TableCell>
                    </TableRow>
                  </>
                )}
              </TableBody>
            </Table>
          )}
          {!loading && groups.length === 0 && !error && (
            <Alert severity="info" sx={{ mt: 2 }}>
              A policy appears here once it is bound. New drafts and reversed policies are not production.
            </Alert>
          )}
        </CardContent>
      </Card>
    </Box>
  );
}

function sumCurrency<T>(items: T[], currencyOf: (t: T) => string | null | undefined, amountOf: (t: T) => number | null | undefined): Record<string, number> {
  const totals: Record<string, number> = {};
  for (const item of items) {
    const cur = currencyOf(item) || 'UGX';
    totals[cur] = (totals[cur] ?? 0) + Number(amountOf(item) ?? 0);
  }
  return totals;
}
