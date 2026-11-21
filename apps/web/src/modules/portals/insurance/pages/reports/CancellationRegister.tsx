import { useCallback, useEffect, useState } from 'react';
import {
  Alert, Box, Button, Card, CardContent, CircularProgress, FormControlLabel, Stack, Switch, Table, TableBody, TableCell,
  TableHead, TableRow, TextField, Typography,
} from '@mui/material';
import { useNavigate } from 'react-router-dom';
import { exportReportToExcel, exportReportToPdf } from '../../../../../lib/reportExport';
import { errorText, rpc } from '../../db';
import { localIsoDate } from '../../fx';
import { formatMoney, formatMoneyByCurrency, sumByCurrency } from '../../logic';
import { CANCELLATION_REGISTER_COLUMNS, monthStartIso, type CancellationRegisterLine } from '../../reportsSuite';
import { EmptyRow, ErrorBanner, PageHeader } from '../../shared';

// One row per posted cancellation in the period, with the amounts the cancellation posted. Read-only; the summary
// report (Cancellations) is these rows grouped.
export default function CancellationRegister() {
  const navigate = useNavigate();
  const [from, setFrom] = useState(monthStartIso());
  const [to, setTo] = useState(localIsoDate());
  const [imported, setImported] = useState(false);
  const [items, setItems] = useState<CancellationRegisterLine[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      setItems((await rpc<CancellationRegisterLine[]>('ins_report_cancellation_register', {
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

  const returnTotals = sumByCurrency(items, (r) => r.currency, (r) => r.return_premium, 'UGX');
  const exportName = `cancellation-register-${from}-to-${to}`;
  const subtitle = `${from} to ${to}${imported ? '  |  Includes imported policies' : ''}`;

  return (
    <Box sx={{ p: 3, maxWidth: 1500 }}>
      <PageHeader
        title="Cancellation register"
        subtitle="Every cancellation posted in the period, one row each."
        actions={
          <Stack direction="row" spacing={1} alignItems="center" sx={{ flexWrap: 'wrap', gap: 1 }}>
            <TextField size="small" type="date" label="From" InputLabelProps={{ shrink: true }} value={from} onChange={(e) => setFrom(e.target.value)} />
            <TextField size="small" type="date" label="To" InputLabelProps={{ shrink: true }} value={to} onChange={(e) => setTo(e.target.value)} />
            {!loading && items.length > 0 && (
              <>
                <Button variant="outlined" onClick={() => exportReportToExcel(exportName, 'Cancellation register', CANCELLATION_REGISTER_COLUMNS, items)}>Export Excel</Button>
                <Button variant="outlined" onClick={() => exportReportToPdf(exportName, 'Cancellation register', CANCELLATION_REGISTER_COLUMNS, items, subtitle)}>Export PDF</Button>
              </>
            )}
          </Stack>
        }
      />
      <ErrorBanner message={error} />
      {from > to && <Alert severity="warning" sx={{ mb: 2 }}>The start date must not be after the end date.</Alert>}
      <Alert severity="info" sx={{ mb: 2 }}>
        Posted cancellations only, dated by the day they were posted. Proposed, rejected and withdrawn cancellations are not listed.
        Currencies are never added together.
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
                    <TableCell>Cancellation</TableCell>
                    <TableCell>Policy</TableCell>
                    <TableCell>Client</TableCell>
                    <TableCell>Insurer</TableCell>
                    <TableCell>Product line</TableCell>
                    <TableCell>Reason</TableCell>
                    <TableCell>Effective</TableCell>
                    <TableCell>Posted</TableCell>
                    <TableCell align="right">Return premium</TableCell>
                    <TableCell align="right">Clawed back</TableCell>
                    <TableCell align="right">Retained</TableCell>
                    <TableCell align="right">Insurer credit</TableCell>
                  </TableRow>
                </TableHead>
                <TableBody>
                  {items.length === 0 ? (
                    <EmptyRow colSpan={12} text="No business was cancelled in this period." />
                  ) : (
                    items.map((r) => (
                      <TableRow key={r.cancellation_id} hover sx={{ cursor: 'pointer' }} onClick={() => navigate(`/insurance/policies/${r.policy_id}`)}>
                        <TableCell sx={{ fontFamily: 'monospace', fontWeight: 600 }}>{r.cancellation_no}</TableCell>
                        <TableCell>{r.policy_no}</TableCell>
                        <TableCell>{r.client_name ?? '-'}</TableCell>
                        <TableCell>{r.insurer_name ?? '-'}</TableCell>
                        <TableCell>{r.product_line_name ?? '-'}</TableCell>
                        <TableCell>{r.reason ?? '-'}</TableCell>
                        <TableCell>{r.effective_date}</TableCell>
                        <TableCell>{r.posting_date}</TableCell>
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
              <strong>Return premium:</strong>{'\n'}{formatMoneyByCurrency(returnTotals, 'UGX')}
            </Typography>
          )}
        </>
      )}
    </Box>
  );
}
