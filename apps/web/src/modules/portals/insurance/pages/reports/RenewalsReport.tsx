import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Alert, Box, Button, Card, CardContent, Chip, CircularProgress, FormControlLabel, MenuItem, Stack, Switch, Table, TableBody,
  TableCell, TableHead, TableRow, TextField, Typography,
} from '@mui/material';
import { useNavigate } from 'react-router-dom';
import { exportReportToExcel, exportReportToPdf } from '../../../../../lib/reportExport';
import { errorText, rpc } from '../../db';
import { localIsoDate } from '../../fx';
import { formatMoney, formatMoneyByCurrency, sumByCurrency } from '../../logic';
import {
  RENEWALS_COLUMNS, RENEWAL_OUTCOMES, RENEWAL_OUTCOME_LABEL, type RenewalLine, type RenewalOutcome,
} from '../../reportsSuite';
import { EmptyRow, ErrorBanner, PageHeader } from '../../shared';

function addDaysIso(days: number): string {
  const d = new Date();
  d.setDate(d.getDate() + days);
  return localIsoDate(d);
}

const outcomeColor = (o: RenewalOutcome): 'success' | 'default' | 'warning' | 'error' =>
  o === 'renewed' ? 'success' : o === 'upcoming' ? 'default' : o === 'unresolved' ? 'warning' : 'error';

// Policies whose expiry falls in the period, and what happened to each. Read-only. This shows today's position:
// a renewal bound later changes the result for an earlier period.
export default function RenewalsReport() {
  const navigate = useNavigate();
  const [from, setFrom] = useState(localIsoDate());
  const [to, setTo] = useState(addDaysIso(60));
  const [imported, setImported] = useState(true);
  const [outcome, setOutcome] = useState<'all' | RenewalOutcome>('all');
  const [items, setItems] = useState<RenewalLine[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      setItems((await rpc<RenewalLine[]>('ins_report_renewals', { p_from: from, p_to: to, p_include_imported: imported })) ?? []);
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

  // The outcome filter only narrows the rows on screen and in the export; it never changes what the server returned.
  const shown = useMemo(() => (outcome === 'all' ? items : items.filter((r) => r.outcome === outcome)), [items, outcome]);
  const expiringTotals = sumByCurrency(shown, (r) => r.currency, (r) => r.expiring_premium, 'UGX');
  const exportName = `renewals-${from}-to-${to}`;
  const subtitle = `Expiring ${from} to ${to}${outcome === 'all' ? '' : `  |  ${RENEWAL_OUTCOME_LABEL[outcome]} only`}${imported ? '' : '  |  Excludes imported policies'}`;

  return (
    <Box sx={{ p: 3, maxWidth: 1500 }}>
      <PageHeader
        title="Renewals"
        subtitle="Policies due to expire in the period, and what happened to each."
        actions={
          <Stack direction="row" spacing={1} alignItems="center" sx={{ flexWrap: 'wrap', gap: 1 }}>
            <TextField size="small" type="date" label="Expiring from" InputLabelProps={{ shrink: true }} value={from} onChange={(e) => setFrom(e.target.value)} />
            <TextField size="small" type="date" label="Expiring to" InputLabelProps={{ shrink: true }} value={to} onChange={(e) => setTo(e.target.value)} />
            <TextField select size="small" label="Outcome" value={outcome} onChange={(e) => setOutcome(e.target.value as 'all' | RenewalOutcome)} sx={{ minWidth: 150 }}>
              <MenuItem value="all">All</MenuItem>
              {RENEWAL_OUTCOMES.map((o) => <MenuItem key={o} value={o}>{RENEWAL_OUTCOME_LABEL[o]}</MenuItem>)}
            </TextField>
            {!loading && shown.length > 0 && (
              <>
                <Button variant="outlined" onClick={() => exportReportToExcel(exportName, 'Renewals', RENEWALS_COLUMNS, shown)}>Export Excel</Button>
                <Button variant="outlined" onClick={() => exportReportToPdf(exportName, 'Renewals', RENEWALS_COLUMNS, shown, subtitle)}>Export PDF</Button>
              </>
            )}
          </Stack>
        }
      />
      <ErrorBanner message={error} />
      {from > to && <Alert severity="warning" sx={{ mb: 2 }}>The start date must not be after the end date.</Alert>}
      <Alert severity="info" sx={{ mb: 2 }}>
        Active or renewed policies expiring in the period. Renewed means a policy that renews this one has been bound; otherwise the outcome
        recorded (lost, declined or lapsed) is shown. A policy not yet expired is Upcoming, and one that has expired with nothing recorded is
        Not resolved. This is the position today. Currencies are never added together.
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
                    <TableCell>Policy</TableCell>
                    <TableCell>Client</TableCell>
                    <TableCell>Insurer</TableCell>
                    <TableCell>Product line</TableCell>
                    <TableCell>Agent</TableCell>
                    <TableCell>Expiry</TableCell>
                    <TableCell align="right">Expiring premium</TableCell>
                    <TableCell>Outcome</TableCell>
                    <TableCell>Renewal policy</TableCell>
                    <TableCell align="right">Renewal premium</TableCell>
                  </TableRow>
                </TableHead>
                <TableBody>
                  {shown.length === 0 ? (
                    <EmptyRow colSpan={10} text="No policies fall due in this period." />
                  ) : (
                    shown.map((r) => (
                      <TableRow key={r.policy_id} hover sx={{ cursor: 'pointer' }} onClick={() => navigate(`/insurance/policies/${r.policy_id}`)}>
                        <TableCell sx={{ fontFamily: 'monospace', fontWeight: 600 }}>{r.policy_no}</TableCell>
                        <TableCell>{r.client_name ?? '-'}</TableCell>
                        <TableCell>{r.insurer_name ?? '-'}</TableCell>
                        <TableCell>{r.product_line_name ?? '-'}</TableCell>
                        <TableCell>{r.agent_name ?? '-'}</TableCell>
                        <TableCell>
                          {r.expiry_date}
                          <Typography variant="caption" sx={{ display: 'block' }}>
                            {r.days_to_expiry >= 0 ? `in ${r.days_to_expiry} days` : `${-r.days_to_expiry} days ago`}
                          </Typography>
                        </TableCell>
                        <TableCell align="right">{formatMoney(Number(r.expiring_premium), r.currency)}</TableCell>
                        <TableCell>
                          <Chip size="small" color={outcomeColor(r.outcome)} variant={r.outcome === 'upcoming' ? 'outlined' : 'filled'}
                            label={RENEWAL_OUTCOME_LABEL[r.outcome] ?? r.outcome} />
                          {r.outcome_reason && <Typography variant="caption" sx={{ display: 'block' }}>{r.outcome_reason}</Typography>}
                        </TableCell>
                        <TableCell>{r.renewal_policy_no ?? '-'}</TableCell>
                        <TableCell align="right">{r.renewal_premium == null ? '-' : formatMoney(Number(r.renewal_premium), r.currency)}</TableCell>
                      </TableRow>
                    ))
                  )}
                </TableBody>
              </Table>
            </CardContent>
          </Card>
          {shown.length > 0 && (
            <Typography variant="body2" sx={{ mt: 2, whiteSpace: 'pre-line' }}>
              <strong>Expiring premium:</strong>{'\n'}{formatMoneyByCurrency(expiringTotals, 'UGX')}
            </Typography>
          )}
        </>
      )}
    </Box>
  );
}
