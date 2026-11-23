import { useCallback, useEffect, useState } from 'react';
import {
  Alert, Box, Button, Card, CardContent, Chip, CircularProgress, FormControlLabel, MenuItem, Stack, Switch, Table, TableBody,
  TableCell, TableHead, TableRow, TextField, Typography,
} from '@mui/material';
import { businessToday } from '../../../../../lib/businessDate';
import { exportReportToExcel, exportReportToPdf } from '../../../../../lib/reportExport';
import { errorText, rpc } from '../../db';
import { formatMoney } from '../../logic';
import {
  REMITTER_LABEL, STATUTORY_EXCEPTION_LABEL, STATUTORY_GROUPS, STATUTORY_STAGE_LABEL, STATUTORY_TRACE_COLUMNS, monthStartIso,
  statutoryChargeColumns, statutoryGroupLabel,
  type StatutoryChargeLine, type StatutoryExceptionLine, type StatutoryGroupBy, type StatutoryTraceLine,
} from '../../reportsSuite';
import { EmptyRow, ErrorBanner, PageHeader } from '../../shared';

type Totals = Record<string, { assessed: number; collected: number; uncollected: number; remitted: number; held: number }>;

// Totals are added per currency from the rows the server returned; currencies are never added together.
const totalsByCurrency = (rows: StatutoryChargeLine[]): Totals => {
  const t: Totals = {};
  for (const r of rows) {
    const x = (t[r.currency] ??= { assessed: 0, collected: 0, uncollected: 0, remitted: 0, held: 0 });
    x.assessed += Number(r.assessed);
    x.collected += Number(r.collected);
    x.uncollected += Number(r.uncollected);
    x.remitted += Number(r.remitted);
    x.held += Number(r.held_unremitted);
  }
  return t;
};

// Statutory charges assessed on policies bound in the period, followed through the client's receipts and the
// remittances to the insurer, with a reconciliation against the booked pass-through and the bind journal.
// Collections and remittances are derived pro rata from the real settlements and are written out in the trace.
export default function StatutoryChargesReport() {
  const [from, setFrom] = useState(monthStartIso());
  const [to, setTo] = useState(businessToday());
  const [groupBy, setGroupBy] = useState<StatutoryGroupBy>('charge');
  const [imported, setImported] = useState(false);
  const [manual, setManual] = useState(false);
  const [items, setItems] = useState<StatutoryChargeLine[]>([]);
  const [exceptions, setExceptions] = useState<StatutoryExceptionLine[]>([]);
  const [trace, setTrace] = useState<StatutoryTraceLine[] | null>(null);
  const [showTrace, setShowTrace] = useState(false);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const [summary, exc] = await Promise.all([
        rpc<StatutoryChargeLine[]>('ins_report_statutory_charges', {
          p_from: from, p_to: to, p_group_by: groupBy, p_include_imported: imported, p_include_manual: manual,
        }),
        rpc<StatutoryExceptionLine[]>('ins_report_statutory_charge_exceptions', {
          p_from: from, p_to: to, p_include_imported: imported,
        }),
      ]);
      setItems(summary ?? []);
      setExceptions(exc ?? []);
      setTrace(null);
      setError(null);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setLoading(false);
    }
  }, [from, to, groupBy, imported, manual]);

  useEffect(() => {
    if (!from || !to || from > to) { setLoading(false); return; }
    load();
  }, [from, to, load]);

  const loadTrace = useCallback(async () => {
    try {
      setTrace((await rpc<StatutoryTraceLine[]>('ins_report_statutory_charge_trace', {
        p_from: from, p_to: to, p_include_imported: imported, p_include_manual: manual,
      })) ?? []);
      setError(null);
    } catch (e) {
      setError(errorText(e));
    }
  }, [from, to, imported, manual]);

  useEffect(() => {
    if (showTrace && trace === null && !loading) loadTrace();
  }, [showTrace, trace, loading, loadTrace]);

  const columns = statutoryChargeColumns(statutoryGroupLabel(groupBy));
  const totals = totalsByCurrency(items);
  const exportName = `statutory-charges-${from}-to-${to}`;
  const subtitle = `Policies bound ${from} to ${to}  |  Collections and remittances as at ${to}  |  By ${statutoryGroupLabel(groupBy).toLowerCase()}${imported ? '  |  Includes imported policies' : ''}`;

  return (
    <Box sx={{ p: 3, maxWidth: 1500 }}>
      <PageHeader
        title="Statutory charges"
        subtitle="Levies and duties assessed on bound policies, followed from the client's receipts to the insurer."
        actions={
          <Stack direction="row" spacing={1} alignItems="center" sx={{ flexWrap: 'wrap', gap: 1 }}>
            <TextField size="small" type="date" label="Bound from" InputLabelProps={{ shrink: true }} value={from} onChange={(e) => setFrom(e.target.value)} />
            <TextField size="small" type="date" label="Bound to / as at" InputLabelProps={{ shrink: true }} value={to} onChange={(e) => setTo(e.target.value)} />
            <TextField select size="small" label="Group by" value={groupBy} onChange={(e) => setGroupBy(e.target.value as StatutoryGroupBy)} sx={{ minWidth: 150 }}>
              {STATUTORY_GROUPS.map((g) => <MenuItem key={g.value} value={g.value}>{g.label}</MenuItem>)}
            </TextField>
            {!loading && items.length > 0 && (
              <>
                <Button variant="outlined" onClick={() => exportReportToExcel(exportName, 'Statutory charges', columns, items)}>Export Excel</Button>
                <Button variant="outlined" onClick={() => exportReportToPdf(exportName, 'Statutory charges', columns, items, subtitle)}>Export PDF</Button>
              </>
            )}
          </Stack>
        }
      />
      <ErrorBanner message={error} />
      {from > to && <Alert severity="warning" sx={{ mb: 2 }}>The start date must not be after the end date.</Alert>}
      <Alert severity="info" sx={{ mb: 2 }}>
        Assessed is the charge on each policy bound in the period, split across the insurer shares. Collected and Remitted are the
        statutory share of each real receipt and each insurer remittance, derived pro rata and rounded to the cent so the parts add up to
        the whole; the Trace shows every split and its working. Both are counted as at the end date. Where the insurer collects a charge,
        the insurer remits it to the authority and that step is outside these books. Currencies are never added together.
      </Alert>
      <Stack direction="row" spacing={2} sx={{ mb: 1, flexWrap: 'wrap' }}>
        <FormControlLabel control={<Switch checked={imported} onChange={(e) => setImported(e.target.checked)} />} label="Include policies imported as an opening book" />
        <FormControlLabel control={<Switch checked={manual} onChange={(e) => setManual(e.target.checked)} />} label="Include manual pass-through charges" />
      </Stack>
      {loading ? (
        <Box sx={{ display: 'flex', justifyContent: 'center', py: 6 }}><CircularProgress /></Box>
      ) : (
        <>
          <Card sx={{ mb: 2 }}>
            <CardContent sx={{ p: 0, overflowX: 'auto' }}>
              <Table size="small">
                <TableHead>
                  <TableRow>
                    <TableCell>{statutoryGroupLabel(groupBy)}</TableCell>
                    <TableCell>Currency</TableCell>
                    <TableCell align="right">Policies</TableCell>
                    <TableCell align="right">Assessed</TableCell>
                    <TableCell align="right">Collected</TableCell>
                    <TableCell align="right">Not yet collected</TableCell>
                    <TableCell align="right">Remitted to insurer</TableCell>
                    <TableCell align="right">Collected, not yet remitted</TableCell>
                    <TableCell>Authority remitted by</TableCell>
                  </TableRow>
                </TableHead>
                <TableBody>
                  {items.length === 0 ? (
                    <EmptyRow colSpan={9} text="No statutory charges were assessed on policies bound in this period." />
                  ) : (
                    items.map((r) => (
                      <TableRow key={`${r.group_key}|${r.currency}`}>
                        <TableCell>{r.group_label}</TableCell>
                        <TableCell>{r.currency}</TableCell>
                        <TableCell align="right">{r.policy_count}</TableCell>
                        <TableCell align="right" sx={{ fontWeight: 600 }}>{formatMoney(Number(r.assessed), r.currency)}</TableCell>
                        <TableCell align="right">{formatMoney(Number(r.collected), r.currency)}</TableCell>
                        <TableCell align="right">{formatMoney(Number(r.uncollected), r.currency)}</TableCell>
                        <TableCell align="right">{formatMoney(Number(r.remitted), r.currency)}</TableCell>
                        <TableCell align="right">{formatMoney(Number(r.held_unremitted), r.currency)}</TableCell>
                        <TableCell>{REMITTER_LABEL[r.remitter] ?? r.remitter}</TableCell>
                      </TableRow>
                    ))
                  )}
                </TableBody>
              </Table>
            </CardContent>
          </Card>
          {items.length > 0 && (
            <Typography variant="body2" component="div" sx={{ mb: 2 }}>
              <strong>Totals:</strong>
              {Object.entries(totals).map(([ccy, t]) => (
                <Box key={ccy} sx={{ mt: 0.5 }}>
                  {ccy}: assessed {formatMoney(t.assessed, ccy)}, collected {formatMoney(t.collected, ccy)}, not yet collected{' '}
                  {formatMoney(t.uncollected, ccy)}, remitted {formatMoney(t.remitted, ccy)}, collected and not yet remitted {formatMoney(t.held, ccy)}
                </Box>
              ))}
            </Typography>
          )}

          <Card sx={{ mb: 2 }}>
            <CardContent>
              <Typography variant="subtitle1" sx={{ fontWeight: 600, mb: 1 }}>Reconciliation</Typography>
              {exceptions.length === 0 ? (
                <Alert severity="success">
                  For every policy bound in this period, the charge allocations equal the pass-through booked on the insurer shares, and the bind
                  journal's credit to insurer payable equals the shares' payable amounts.
                </Alert>
              ) : (
                <>
                  <Alert severity="error" sx={{ mb: 1 }}>
                    {exceptions.length} item{exceptions.length === 1 ? '' : 's'} do not reconcile. Each is listed with the amount recorded and the amount booked.
                  </Alert>
                  <Box sx={{ overflowX: 'auto' }}>
                    <Table size="small">
                      <TableHead>
                        <TableRow>
                          <TableCell>Check</TableCell>
                          <TableCell>Policy</TableCell>
                          <TableCell>Insurer</TableCell>
                          <TableCell align="right">Recorded</TableCell>
                          <TableCell align="right">Booked</TableCell>
                          <TableCell align="right">Difference</TableCell>
                        </TableRow>
                      </TableHead>
                      <TableBody>
                        {exceptions.map((e, i) => (
                          <TableRow key={`${e.check_name}|${e.policy_id}|${e.insurer_name ?? ''}|${i}`}>
                            <TableCell>{STATUTORY_EXCEPTION_LABEL[e.check_name] ?? e.check_name}</TableCell>
                            <TableCell sx={{ fontFamily: 'monospace' }}>{e.policy_no}</TableCell>
                            <TableCell>{e.insurer_name ?? '-'}</TableCell>
                            <TableCell align="right">{Number(e.recorded_amount).toLocaleString()}</TableCell>
                            <TableCell align="right">{Number(e.booked_amount).toLocaleString()}</TableCell>
                            <TableCell align="right" sx={{ fontWeight: 600 }}>{Number(e.difference).toLocaleString()}</TableCell>
                          </TableRow>
                        ))}
                      </TableBody>
                    </Table>
                  </Box>
                </>
              )}
            </CardContent>
          </Card>

          <FormControlLabel
            control={<Switch checked={showTrace} onChange={(e) => setShowTrace(e.target.checked)} />}
            label="Show the trace: every allocation, receipt and remittance behind these figures"
          />
          {showTrace && (
            <Card sx={{ mt: 1 }}>
              <CardContent sx={{ p: 0, overflowX: 'auto' }}>
                {trace === null ? (
                  <Box sx={{ display: 'flex', justifyContent: 'center', py: 4 }}><CircularProgress /></Box>
                ) : (
                  <>
                    {trace.length > 0 && (
                      <Stack direction="row" spacing={1} sx={{ p: 1.5 }}>
                        <Button size="small" variant="outlined" onClick={() => exportReportToExcel(`${exportName}-trace`, 'Statutory charge trace', STATUTORY_TRACE_COLUMNS, trace)}>Export trace Excel</Button>
                        <Button size="small" variant="outlined" onClick={() => exportReportToPdf(`${exportName}-trace`, 'Statutory charge trace', STATUTORY_TRACE_COLUMNS, trace, subtitle)}>Export trace PDF</Button>
                      </Stack>
                    )}
                    <Table size="small">
                      <TableHead>
                        <TableRow>
                          <TableCell>Stage</TableCell>
                          <TableCell>Policy</TableCell>
                          <TableCell>Insurer</TableCell>
                          <TableCell>Charge</TableCell>
                          <TableCell>Date</TableCell>
                          <TableCell>Settlement</TableCell>
                          <TableCell align="right">Amount</TableCell>
                          <TableCell>Basis</TableCell>
                        </TableRow>
                      </TableHead>
                      <TableBody>
                        {trace.length === 0 ? (
                          <EmptyRow colSpan={8} text="Nothing to trace for this period." />
                        ) : (
                          trace.map((r, i) => (
                            <TableRow key={`${r.stage}|${r.charge_id}|${r.insurer_id}|${r.settlement_id ?? 'x'}|${i}`}>
                              <TableCell><Chip size="small" label={STATUTORY_STAGE_LABEL[r.stage] ?? r.stage} variant={r.stage === 'assessed' ? 'outlined' : 'filled'} /></TableCell>
                              <TableCell sx={{ fontFamily: 'monospace' }}>
                                {r.policy_no}
                                {r.policy_status === 'cancelled' && <Chip size="small" color="warning" label="Cancelled" sx={{ ml: 1 }} />}
                              </TableCell>
                              <TableCell>{r.insurer_name ?? '-'}</TableCell>
                              <TableCell>{r.charge_code}</TableCell>
                              <TableCell>{r.event_date}</TableCell>
                              <TableCell>{r.settlement_no ?? '-'}</TableCell>
                              <TableCell align="right">{formatMoney(Number(r.amount), r.currency)}</TableCell>
                              <TableCell sx={{ color: 'text.secondary' }}>{r.basis}</TableCell>
                            </TableRow>
                          ))
                        )}
                      </TableBody>
                    </Table>
                  </>
                )}
              </CardContent>
            </Card>
          )}
        </>
      )}
    </Box>
  );
}
