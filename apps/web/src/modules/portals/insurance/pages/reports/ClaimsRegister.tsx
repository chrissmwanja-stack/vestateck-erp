import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Alert, Box, Button, Card, CardContent, Chip, CircularProgress, MenuItem, Stack, Table, TableBody, TableCell, TableHead, TableRow,
  TextField, Typography,
} from '@mui/material';
import { useNavigate } from 'react-router-dom';
import { exportReportToExcel, exportReportToPdf } from '../../../../../lib/reportExport';
import { errorText, rpc } from '../../db';
import { localIsoDate } from '../../fx';
import { formatMoney, formatMoneyByCurrency, sumByCurrency } from '../../logic';
import {
  CLAIMS_REGISTER_COLUMNS, CLAIM_AGE_BUCKET_LABEL, CLAIM_STATUS_LABEL, type ClaimRegisterLine, type ClaimsScope,
} from '../../reportsSuite';
import { EmptyRow, ErrorBanner, PageHeader } from '../../shared';

// Claims register as at a date: every claim with its status, reserve, amount approved, amount paid and what is still
// outstanding on that date. Read-only; status, reserve and payments are reproducible for any past date.
export default function ClaimsRegister() {
  const navigate = useNavigate();
  const [asOf, setAsOf] = useState(localIsoDate());
  const [scope, setScope] = useState<ClaimsScope>('open');
  const [items, setItems] = useState<ClaimRegisterLine[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      setItems((await rpc<ClaimRegisterLine[]>('ins_report_claims_register', { p_as_of: asOf, p_scope: scope })) ?? []);
      setError(null);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setLoading(false);
    }
  }, [asOf, scope]);

  useEffect(() => {
    if (!asOf) return;
    load();
  }, [asOf, load]);

  const total = sumByCurrency(items, (r) => r.currency, (r) => r.outstanding_amount, 'UGX');
  const reserveTotal = sumByCurrency(items, (r) => r.currency, (r) => r.reserve_as_at, 'UGX');
  const openCount = useMemo(() => items.filter((r) => r.is_open).length, [items]);

  const exportName = `claims-register-${asOf}`;
  const subtitle = [
    `As at ${asOf}`,
    scope === 'open' ? 'Open claims' : 'All claims',
    `Outstanding: ${formatMoneyByCurrency(total, 'UGX').split('\n').join('; ')}`,
  ].join('  |  ');

  return (
    <Box sx={{ p: 3, maxWidth: 1500 }}>
      <PageHeader
        title="Claims register"
        subtitle="Which claims are outstanding, and for how much."
        actions={
          <Stack direction="row" spacing={1} alignItems="center">
            <TextField size="small" type="date" label="As at" InputLabelProps={{ shrink: true }} value={asOf} onChange={(e) => setAsOf(e.target.value)} />
            <TextField size="small" select label="Show" value={scope} onChange={(e) => setScope(e.target.value as ClaimsScope)} sx={{ minWidth: 150 }}>
              <MenuItem value="open">Open claims</MenuItem>
              <MenuItem value="all">All claims</MenuItem>
            </TextField>
            {!loading && items.length > 0 && (
              <>
                <Button variant="outlined" onClick={() => exportReportToExcel(exportName, 'Claims register', CLAIMS_REGISTER_COLUMNS, items)}>Export Excel</Button>
                <Button variant="outlined" onClick={() => exportReportToPdf(exportName, 'Claims register', CLAIMS_REGISTER_COLUMNS, items, subtitle)}>Export PDF</Button>
              </>
            )}
          </Stack>
        }
      />
      <ErrorBanner message={error} />
      <Alert severity="info" sx={{ mb: 2 }}>
        Taken from the claim records. A claim is open while it is notified, being assessed, or approved and not yet fully paid.
        Outstanding is the reserve for a claim still being assessed, and the approved amount less payments for an approved claim.
        Choosing an earlier date shows status, reserve and payments as they stood then; the approved amount is the current one.
        The insurer shown is the policy&apos;s lead insurer. Currencies are never added together.
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
                    <TableCell>Claim</TableCell>
                    <TableCell>Policy</TableCell>
                    <TableCell>Client</TableCell>
                    <TableCell>Insurer</TableCell>
                    <TableCell>Product line</TableCell>
                    <TableCell>Notified</TableCell>
                    <TableCell>Status</TableCell>
                    <TableCell align="right">Reserve</TableCell>
                    <TableCell align="right">Approved</TableCell>
                    <TableCell align="right">Paid</TableCell>
                    <TableCell align="right">Outstanding</TableCell>
                    <TableCell>Age</TableCell>
                  </TableRow>
                </TableHead>
                <TableBody>
                  {items.length === 0 ? (
                    <EmptyRow colSpan={12} text={scope === 'open' ? 'No claims were open on this date.' : 'No claims had been notified on this date.'} />
                  ) : (
                    items.map((r) => (
                      <TableRow key={r.claim_id} hover sx={{ cursor: 'pointer' }} onClick={() => navigate(`/insurance/claims/${r.claim_id}`)}>
                        <TableCell sx={{ fontFamily: 'monospace', fontWeight: 600 }}>{r.claim_no}</TableCell>
                        <TableCell>{r.policy_no}</TableCell>
                        <TableCell>{r.client_name ?? '-'}</TableCell>
                        <TableCell>{r.insurer_name ?? '-'}</TableCell>
                        <TableCell>{r.product_line_name ?? '-'}</TableCell>
                        <TableCell>{r.notified_date}</TableCell>
                        <TableCell>
                          <Chip size="small" variant={r.is_open ? 'filled' : 'outlined'} color={r.is_open ? 'primary' : 'default'}
                            label={CLAIM_STATUS_LABEL[r.status_as_at] ?? r.status_as_at} />
                        </TableCell>
                        <TableCell align="right">{formatMoney(Number(r.reserve_as_at), r.currency)}</TableCell>
                        <TableCell align="right">{r.approved_amount == null ? '-' : formatMoney(Number(r.approved_amount), r.currency)}</TableCell>
                        <TableCell align="right">{formatMoney(Number(r.paid_as_at), r.currency)}</TableCell>
                        <TableCell align="right" sx={{ fontWeight: 600 }}>{formatMoney(Number(r.outstanding_amount), r.currency)}</TableCell>
                        <TableCell>
                          {r.is_open ? (
                            <>
                              <Chip size="small" variant={r.age_bucket === '0-30' ? 'outlined' : 'filled'}
                                color={r.age_bucket === '180+' ? 'error' : r.age_bucket === '0-30' ? 'default' : 'warning'}
                                label={CLAIM_AGE_BUCKET_LABEL[r.age_bucket] ?? r.age_bucket} />
                              <Typography variant="caption" sx={{ display: 'block' }}>{r.days_since_activity} days since last activity</Typography>
                            </>
                          ) : (
                            <Typography variant="caption">Closed</Typography>
                          )}
                        </TableCell>
                      </TableRow>
                    ))
                  )}
                </TableBody>
              </Table>
            </CardContent>
          </Card>
          {items.length > 0 && (
            <Typography variant="body2" sx={{ mt: 2, whiteSpace: 'pre-line' }}>
              <strong>{`Open claims: ${openCount}. Reserve:`}</strong>{'\n'}
              {formatMoneyByCurrency(reserveTotal, 'UGX')}{'\n'}
              <strong>Total outstanding:</strong>{'\n'}
              {formatMoneyByCurrency(total, 'UGX')}
            </Typography>
          )}
        </>
      )}
    </Box>
  );
}
