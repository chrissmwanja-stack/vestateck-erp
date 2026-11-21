import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Alert, Box, Button, Card, CardContent, Chip, CircularProgress, Stack, Table, TableBody, TableCell, TableHead, TableRow, TextField,
  Typography,
} from '@mui/material';
import { useNavigate } from 'react-router-dom';
import { exportReportToExcel, exportReportToPdf } from '../../../../../lib/reportExport';
import { errorText, rpc } from '../../db';
import { localIsoDate } from '../../fx';
import { formatMoney, formatMoneyByCurrency, sumByCurrency } from '../../logic';
import {
  AGE_BUCKETS, AGE_BUCKET_LABEL, COMMISSION_RECEIVABLE_COLUMNS, type AgeBucket, type CommissionReceivableLine,
} from '../../reportsSuite';
import { EmptyRow, ErrorBanner, PageHeader } from '../../shared';

// Commission the insurers owe the brokerage as at a date: billed, less received, less credited, from the commission
// receivable open items. Only insurers settled on the gross basis appear here. Read-only; reproducible for any past date.
export default function CommissionReceivable() {
  const navigate = useNavigate();
  const [asOf, setAsOf] = useState(localIsoDate());
  const [items, setItems] = useState<CommissionReceivableLine[]>([]);
  const [bucket, setBucket] = useState<'all' | AgeBucket>('all');
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      setItems((await rpc<CommissionReceivableLine[]>('ins_report_commission_receivable', { p_as_of: asOf })) ?? []);
      setError(null);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setLoading(false);
    }
  }, [asOf]);

  useEffect(() => {
    if (!asOf) return;
    load();
  }, [asOf, load]);

  const counts = useMemo(() => {
    const c = Object.fromEntries(AGE_BUCKETS.map((b) => [b, 0])) as Record<AgeBucket, number>;
    for (const r of items) if (r.age_bucket in c) c[r.age_bucket] += 1;
    return c;
  }, [items]);
  const visible = useMemo(() => items.filter((r) => bucket === 'all' || r.age_bucket === bucket), [items, bucket]);
  const total = sumByCurrency(visible, (r) => r.currency, (r) => r.outstanding, 'UGX');

  // Exports exactly what the screen shows, filter included.
  const exportName = `commission-receivable-${asOf}`;
  const subtitle = [
    `As at ${asOf}`,
    bucket === 'all' ? null : `Age: ${AGE_BUCKET_LABEL[bucket]}`,
    `Receivable: ${formatMoneyByCurrency(total, 'UGX').split('\n').join('; ')}`,
  ].filter(Boolean).join('  |  ');

  return (
    <Box sx={{ p: 3, maxWidth: 1300 }}>
      <PageHeader
        title="Commission receivable"
        subtitle="Commission the insurers owe the brokerage, and for how long."
        actions={
          <Stack direction="row" spacing={1} alignItems="center">
            <TextField size="small" type="date" label="As at" InputLabelProps={{ shrink: true }} value={asOf} onChange={(e) => setAsOf(e.target.value)} />
            {!loading && visible.length > 0 && (
              <>
                <Button variant="outlined" onClick={() => exportReportToExcel(exportName, 'Commission receivable', COMMISSION_RECEIVABLE_COLUMNS, visible)}>Export Excel</Button>
                <Button variant="outlined" onClick={() => exportReportToPdf(exportName, 'Commission receivable', COMMISSION_RECEIVABLE_COLUMNS, visible, subtitle)}>Export PDF</Button>
              </>
            )}
          </Stack>
        }
      />
      <ErrorBanner message={error} />
      <Alert severity="info" sx={{ mb: 2 }}>
        Taken from the commission receivables in the ledger. Insurers that are settled net of commission never owe the brokerage
        anything here, because the brokerage keeps its commission when it remits. Choosing an earlier date shows what was owed then:
        later receipts and credits are ignored, and a receipt voided after that date still counts. Currencies are never added together.
      </Alert>
      {loading ? (
        <Box sx={{ display: 'flex', justifyContent: 'center', py: 6 }}><CircularProgress /></Box>
      ) : (
        <>
          <Stack direction="row" spacing={1} sx={{ mb: 2, flexWrap: 'wrap', gap: 1 }} alignItems="center">
            <Chip label={`All (${items.length})`} color={bucket === 'all' ? 'primary' : 'default'} onClick={() => setBucket('all')} />
            {AGE_BUCKETS.map((b) => (
              <Chip key={b} label={`${AGE_BUCKET_LABEL[b]} (${counts[b]})`} color={bucket === b ? 'primary' : 'default'}
                variant={counts[b] ? 'filled' : 'outlined'} onClick={() => setBucket(b)} />
            ))}
          </Stack>
          <Card>
            <CardContent sx={{ p: 0, overflowX: 'auto' }}>
              <Table size="small">
                <TableHead>
                  <TableRow>
                    <TableCell>Insurer</TableCell>
                    <TableCell>Policy</TableCell>
                    <TableCell>Document</TableCell>
                    <TableCell align="right">Billed</TableCell>
                    <TableCell align="right">Received</TableCell>
                    <TableCell align="right">Credited</TableCell>
                    <TableCell align="right">Outstanding</TableCell>
                    <TableCell>Due</TableCell>
                    <TableCell>Age</TableCell>
                  </TableRow>
                </TableHead>
                <TableBody>
                  {visible.length === 0 ? (
                    <EmptyRow colSpan={9} text={items.length === 0 ? 'No insurer owes commission on this date.' : 'Nothing matches this filter.'} />
                  ) : (
                    visible.map((r) => (
                      <TableRow key={r.open_item_id} hover sx={{ cursor: 'pointer' }} onClick={() => navigate(`/insurance/policies/${r.policy_id}`)}>
                        <TableCell>{r.insurer_name ?? '-'}</TableCell>
                        <TableCell sx={{ fontFamily: 'monospace', fontWeight: 600 }}>{r.policy_no}</TableCell>
                        <TableCell>{r.document_no}</TableCell>
                        <TableCell align="right">{formatMoney(Number(r.billed), r.currency)}</TableCell>
                        <TableCell align="right">{formatMoney(Number(r.received), r.currency)}</TableCell>
                        <TableCell align="right">{formatMoney(Number(r.credited), r.currency)}</TableCell>
                        <TableCell align="right" sx={{ fontWeight: 600 }}>{formatMoney(Number(r.outstanding), r.currency)}</TableCell>
                        <TableCell>{r.due_date ?? r.document_date}</TableCell>
                        <TableCell>
                          <Chip size="small" color={r.age_bucket === 'current' ? 'default' : r.age_bucket === '90+' ? 'error' : 'warning'}
                            variant={r.age_bucket === 'current' ? 'outlined' : 'filled'} label={AGE_BUCKET_LABEL[r.age_bucket] ?? r.age_bucket} />
                          {r.days_overdue > 0 && (
                            <Typography variant="caption" sx={{ display: 'block' }}>{r.days_overdue} {r.days_overdue === 1 ? 'day' : 'days'} overdue</Typography>
                          )}
                        </TableCell>
                      </TableRow>
                    ))
                  )}
                </TableBody>
              </Table>
            </CardContent>
          </Card>
          {visible.length > 0 && (
            <Typography variant="body2" sx={{ mt: 2, whiteSpace: 'pre-line' }}>
              <strong>{visible.length === items.length ? 'Total receivable:' : 'Total receivable, for the rows shown:'}</strong>{'\n'}
              {formatMoneyByCurrency(total, 'UGX')}
            </Typography>
          )}
        </>
      )}
    </Box>
  );
}
