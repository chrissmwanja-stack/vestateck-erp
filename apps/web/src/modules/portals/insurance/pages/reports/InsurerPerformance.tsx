import { useCallback, useEffect, useState } from 'react';
import {
  Alert, Box, Button, Card, CardContent, CircularProgress, FormControlLabel, Stack, Switch, Table, TableBody, TableCell,
  TableHead, TableRow, TextField, Typography,
} from '@mui/material';
import { businessToday } from '../../../../../lib/businessDate';
import { exportReportToExcel, exportReportToPdf } from '../../../../../lib/reportExport';
import { errorText, rpc } from '../../db';
import { formatMoney } from '../../logic';
import { INSURER_PERFORMANCE_COLUMNS, formatPct, monthStartIso, type InsurerPerformanceLine } from '../../reportsSuite';
import { EmptyRow, ErrorBanner, PageHeader } from '../../shared';

type Totals = Record<string, { premium: number; commission: number; paid: number; outstanding: number; incurred: number }>;

// Totals are added per currency from the rows the server returned. Ratios are never recomputed here.
const totalsByCurrency = (rows: InsurerPerformanceLine[]): Totals => {
  const t: Totals = {};
  for (const r of rows) {
    const x = (t[r.currency] ??= { premium: 0, commission: 0, paid: 0, outstanding: 0, incurred: 0 });
    x.premium += Number(r.premium_placed);
    x.commission += Number(r.commission);
    x.paid += Number(r.claims_paid);
    x.outstanding += Number(r.claims_outstanding);
    x.incurred += Number(r.claims_incurred);
  }
  return t;
};

// Policies bound in the period, by insurer: each insurer's own premium and commission share, and the claims on those
// policies as at the end date, attributed to insurers pro rata by share. Read-only.
export default function InsurerPerformance() {
  const [from, setFrom] = useState(monthStartIso());
  const [to, setTo] = useState(businessToday());
  const [imported, setImported] = useState(false);
  const [items, setItems] = useState<InsurerPerformanceLine[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      setItems((await rpc<InsurerPerformanceLine[]>('ins_report_insurer_performance', {
        p_from: from, p_to: to, p_include_imported: imported,
      })) ?? []);
      setError(null);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setLoading(false);
    }
  }, [from, to, imported]);

  useEffect(() => {
    if (!from || !to || from > to) { setLoading(false); return; }
    load();
  }, [from, to, load]);

  const totals = totalsByCurrency(items);
  const exportName = `insurer-performance-${from}-to-${to}`;
  const subtitle = `Policies bound ${from} to ${to}  |  Claims as at ${to}${imported ? '  |  Includes imported policies' : ''}`;

  return (
    <Box sx={{ p: 3, maxWidth: 1500 }}>
      <PageHeader
        title="Insurer performance"
        subtitle="Premium placed, commission and claims by insurer for the policies bound in the period."
        actions={
          <Stack direction="row" spacing={1} alignItems="center" sx={{ flexWrap: 'wrap', gap: 1 }}>
            <TextField size="small" type="date" label="Bound from" InputLabelProps={{ shrink: true }} value={from} onChange={(e) => setFrom(e.target.value)} />
            <TextField size="small" type="date" label="Bound to / as at" InputLabelProps={{ shrink: true }} value={to} onChange={(e) => setTo(e.target.value)} />
            {!loading && items.length > 0 && (
              <>
                <Button variant="outlined" onClick={() => exportReportToExcel(exportName, 'Insurer performance', INSURER_PERFORMANCE_COLUMNS, items)}>Export Excel</Button>
                <Button variant="outlined" onClick={() => exportReportToPdf(exportName, 'Insurer performance', INSURER_PERFORMANCE_COLUMNS, items, subtitle)}>Export PDF</Button>
              </>
            )}
          </Stack>
        }
      />
      <ErrorBanner message={error} />
      {from > to && <Alert severity="warning" sx={{ mb: 2 }}>The start date must not be after the end date.</Alert>}
      <Alert severity="info" sx={{ mb: 2 }}>
        Premium placed and commission are each insurer's own recorded share, so a co-insured policy counts once for every insurer that carries part
        of it. Claims are every claim notified on these policies up to the end date, split between the insurers pro rata by share to the cent.
        The loss ratio is claims incurred (paid plus outstanding) over premium placed. Premium is gross of later cancellations, which are counted
        separately. Currencies are never added together.
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
                    <TableCell>Insurer</TableCell>
                    <TableCell>Currency</TableCell>
                    <TableCell align="right">Policies</TableCell>
                    <TableCell align="right">Premium placed</TableCell>
                    <TableCell align="right">Commission</TableCell>
                    <TableCell align="right">Claims (open)</TableCell>
                    <TableCell align="right">Paid</TableCell>
                    <TableCell align="right">Outstanding</TableCell>
                    <TableCell align="right">Incurred</TableCell>
                    <TableCell align="right">Loss ratio</TableCell>
                  </TableRow>
                </TableHead>
                <TableBody>
                  {items.length === 0 ? (
                    <EmptyRow colSpan={10} text="No policies were bound in this period." />
                  ) : (
                    items.map((r) => (
                      <TableRow key={`${r.insurer_id}|${r.currency}`}>
                        <TableCell>{r.insurer_name ?? '-'}</TableCell>
                        <TableCell>{r.currency}</TableCell>
                        <TableCell align="right">
                          {r.policy_count}
                          {r.cancelled_policy_count > 0 && (
                            <Typography component="span" variant="caption" sx={{ display: 'block' }}>{r.cancelled_policy_count} cancelled</Typography>
                          )}
                        </TableCell>
                        <TableCell align="right" sx={{ fontWeight: 600 }}>{formatMoney(Number(r.premium_placed), r.currency)}</TableCell>
                        <TableCell align="right">
                          {formatMoney(Number(r.commission), r.currency)}
                          <Typography component="span" variant="caption" sx={{ display: 'block' }}>{formatPct(r.commission_pct)}</Typography>
                        </TableCell>
                        <TableCell align="right">{r.claim_count} ({r.open_claim_count})</TableCell>
                        <TableCell align="right">{formatMoney(Number(r.claims_paid), r.currency)}</TableCell>
                        <TableCell align="right">{formatMoney(Number(r.claims_outstanding), r.currency)}</TableCell>
                        <TableCell align="right">{formatMoney(Number(r.claims_incurred), r.currency)}</TableCell>
                        <TableCell align="right" sx={{ fontWeight: 600 }}>{formatPct(r.loss_ratio_pct)}</TableCell>
                      </TableRow>
                    ))
                  )}
                </TableBody>
              </Table>
            </CardContent>
          </Card>
          {items.length > 0 && (
            <Typography variant="body2" component="div" sx={{ mt: 2 }}>
              <strong>Totals:</strong>
              {Object.entries(totals).map(([ccy, t]) => (
                <Box key={ccy} sx={{ mt: 0.5 }}>
                  {ccy}: premium placed {formatMoney(t.premium, ccy)}, commission {formatMoney(t.commission, ccy)}, claims paid{' '}
                  {formatMoney(t.paid, ccy)}, outstanding {formatMoney(t.outstanding, ccy)}, incurred {formatMoney(t.incurred, ccy)}
                </Box>
              ))}
            </Typography>
          )}
        </>
      )}
    </Box>
  );
}
