import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Box, Button, Card, CardContent, CircularProgress, Grid, MenuItem, Stack, Table, TableBody, TableCell,
  TableHead, TableRow, TextField, Typography,
} from '@mui/material';
import { exportReportToExcel, exportReportToPdf, type ReportExportColumn } from '../../../../../lib/reportExport';
import { allRows, errorText, table } from '../../db';
import { formatMoney, formatMoneyByCurrency } from '../../logic';
import { agedBalances, AGING_BUCKETS, AGING_LABEL, type AgingBucket, type StatementRow } from '../../reports';
import { EmptyRow, ErrorBanner, PageHeader } from '../../shared';

const today = () => new Date().toISOString().slice(0, 10);

// Statement of account and aged balances, both from ins_client_statement (one
// row per written policy: billed on bind, cash actually received -- posted
// receipts only -- and the balance). Pick a client for their statement; leave
// it on "All clients" for the aged subsidiary balances.
export default function ClientStatements() {
  const [asOf, setAsOf] = useState(today());
  const [clientId, setClientId] = useState('all');
  const [rows, setRows] = useState<StatementRow[]>([]);
  const [functional, setFunctional] = useState('UGX');
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const [stmt, settings] = await Promise.all([
        allRows<StatementRow>(() => table('ins_client_statement').select('*').order('policy_no')),
        allRows<{ functional_currency: string }>(() => table('tenant_ledger_settings').select('functional_currency')),
      ]);
      setRows(stmt);
      setFunctional(settings[0]?.functional_currency ?? 'UGX');
      setError(null);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { void load(); }, [load]);

  const clients = useMemo(() => {
    const map = new Map<string, string>();
    for (const r of rows) if (r.client_id) map.set(r.client_id, r.client_name ?? r.client_id);
    return Array.from(map.entries()).sort((a, b) => a[1].localeCompare(b[1]));
  }, [rows]);

  const visible = useMemo(() => (clientId === 'all' ? rows : rows.filter((r) => r.client_id === clientId)), [rows, clientId]);
  const statement = useMemo(() =>
    visible.map((r) => ({ ...r, balance_amount: Number(r.balance_amount ?? 0) })), [visible]);

  const totals = useMemo(() => ({
    billed: totalByCurrency(statement, 'billed_amount'),
    received: totalByCurrency(statement, 'received_amount'),
    balance: totalByCurrency(statement, 'balance_amount'),
  }), [statement]);

  const aging = useMemo(() => agedBalances(statement, asOf), [statement, asOf]);
  const agingTotal = useMemo(() => {
    const t: Record<string, number> = {};
    for (const a of aging) t[a.currency] = (t[a.currency] ?? 0) + a.total;
    return t;
  }, [aging]);

  const oneClient = clientId !== 'all';

  // Two export shapes: a client statement (one row per policy) or the aged
  // balances across clients (one row per client and currency). Money is
  // formatted per currency, exactly as the screen shows it.
  const statementRows = () => statement.map((r) => ({
    policy_no: r.policy_no ?? '-',
    bound: r.bound_date ?? '-',
    expiry: r.expiry_date ?? '-',
    currency: r.currency ?? 'UGX',
    billed: formatMoney(Number(r.billed_amount ?? 0), r.currency || functional),
    received: formatMoney(Number(r.received_amount ?? 0), r.currency || functional),
    balance: formatMoney(Number(r.balance_amount ?? 0), r.currency || functional),
    status: r.status ?? '-',
  }));
  const statementColumns: ReportExportColumn<ReturnType<typeof statementRows>[number]>[] = [
    { header: 'Policy', accessor: (r) => r.policy_no },
    { header: 'Bound', accessor: (r) => r.bound },
    { header: 'Expiry', accessor: (r) => r.expiry },
    { header: 'Currency', accessor: (r) => r.currency },
    { header: 'Billed', align: 'right', accessor: (r) => r.billed },
    { header: 'Received', align: 'right', accessor: (r) => r.received },
    { header: 'Balance', align: 'right', accessor: (r) => r.balance },
    { header: 'Status', accessor: (r) => r.status },
  ];
  const agingRows = () => aging.map((a) => ({
    client: a.client,
    currency: a.currency,
    current: formatMoney(a.buckets.current, a.currency),
    d30: formatMoney(a.buckets.d30, a.currency),
    d60: formatMoney(a.buckets.d60, a.currency),
    d90: formatMoney(a.buckets.d90, a.currency),
    over90: formatMoney(a.buckets.over90, a.currency),
    total: formatMoney(a.total, a.currency),
  }));
  const agingColumns: ReportExportColumn<ReturnType<typeof agingRows>[number]>[] = [
    { header: 'Client', accessor: (r) => r.client },
    { header: 'Currency', accessor: (r) => r.currency },
    { header: AGING_LABEL.current, align: 'right', accessor: (r) => r.current },
    { header: AGING_LABEL.d30, align: 'right', accessor: (r) => r.d30 },
    { header: AGING_LABEL.d60, align: 'right', accessor: (r) => r.d60 },
    { header: AGING_LABEL.d90, align: 'right', accessor: (r) => r.d90 },
    { header: AGING_LABEL.over90, align: 'right', accessor: (r) => r.over90 },
    { header: 'Total outstanding', align: 'right', accessor: (r) => r.total },
  ];
  const clientName = clients.find(([id]) => id === clientId)?.[1] ?? clientId;
  const exportExcel = () => oneClient
    ? exportReportToExcel(`statement-${clientName}-${asOf}`, 'Statement', statementColumns, statementRows())
    : exportReportToExcel(`aged-balances-${asOf}`, 'Aged balances', agingColumns, agingRows());
  const exportPdf = () => oneClient
    ? exportReportToPdf(`statement-${clientName}-${asOf}`, 'Statement of account', statementColumns, statementRows(), `As at ${asOf}`)
    : exportReportToPdf(`aged-balances-${asOf}`, 'Aged balances', agingColumns, agingRows(), `As at ${asOf}`);

  return (
    <Box sx={{ p: 3 }}>
      <PageHeader
        title={oneClient ? 'Statement of account' : 'Aged balances'}
        subtitle="Billed premium on bound policies, cash actually received (posted receipts), and what is still owed. Cancellation credits are not on this statement yet."
      />
      <ErrorBanner message={error} />
      <Card>
        <CardContent>
          <Grid container spacing={2} alignItems="center" sx={{ mb: 2 }}>
            <Grid item xs={12} md={5}>
              <TextField select fullWidth label="Client" value={clientId} onChange={(e) => setClientId(e.target.value)}>
                <MenuItem value="all">All clients (aged balances)</MenuItem>
                {clients.map(([id, name]) => (
                  <MenuItem key={id} value={id}>{name}</MenuItem>
                ))}
              </TextField>
            </Grid>
            <Grid item xs={6} md={3}>
              <TextField fullWidth type="date" label="Ages as at" InputLabelProps={{ shrink: true }} value={asOf} onChange={(e) => setAsOf(e.target.value)} />
            </Grid>
            <Grid item xs={6} md={4}>
              <Stack direction="row" spacing={1} justifyContent="flex-end">
                <Button variant="outlined" onClick={() => exportExcel()}>Excel</Button>
                <Button variant="outlined" onClick={() => exportPdf()}>PDF</Button>
              </Stack>
            </Grid>
          </Grid>

          {loading ? (
            <Box sx={{ display: 'flex', justifyContent: 'center', py: 4 }}><CircularProgress /></Box>
          ) : oneClient ? (
            <>
              <Table size="small">
                <TableHead>
                  <TableRow>
                    <TableCell>Policy</TableCell>
                    <TableCell>Bound</TableCell>
                    <TableCell>Expiry</TableCell>
                    <TableCell align="right">Billed</TableCell>
                    <TableCell align="right">Received</TableCell>
                    <TableCell align="right">Balance</TableCell>
                  </TableRow>
                </TableHead>
                <TableBody>
                  {statement.length === 0 ? (
                    <EmptyRow colSpan={6} text="No written policies for this client yet." />
                  ) : (
                    <>
                      {statement.map((r) => (
                        <TableRow key={r.policy_id}>
                          <TableCell>{r.policy_no}</TableCell>
                          <TableCell>{r.bound_date}</TableCell>
                          <TableCell>{r.expiry_date}</TableCell>
                          <TableCell align="right">{formatMoney(Number(r.billed_amount ?? 0), r.currency || functional)}</TableCell>
                          <TableCell align="right">{formatMoney(Number(r.received_amount ?? 0), r.currency || functional)}</TableCell>
                          <TableCell align="right">{formatMoney(Number(r.balance_amount ?? 0), r.currency || functional)}</TableCell>
                        </TableRow>
                      ))}
                      <TableRow>
                        <TableCell colSpan={3}><strong>Total</strong></TableCell>
                        <TableCell align="right"><strong>{formatMoneyByCurrency(totals.billed, functional)}</strong></TableCell>
                        <TableCell align="right"><strong>{formatMoneyByCurrency(totals.received, functional)}</strong></TableCell>
                        <TableCell align="right"><strong>{formatMoneyByCurrency(totals.balance, functional)}</strong></TableCell>
                      </TableRow>
                    </>
                  )}
                </TableBody>
              </Table>
              <Typography variant="subtitle2" sx={{ mt: 3, mb: 1 }}>Age of the outstanding balance</Typography>
              <AgingStrip aging={aging} />
            </>
          ) : (
            <Table size="small">
              <TableHead>
                <TableRow>
                  <TableCell>Client</TableCell>
                  <TableCell>Currency</TableCell>
                  {AGING_BUCKETS.map((b) => <TableCell key={b} align="right">{AGING_LABEL[b]}</TableCell>)}
                  <TableCell align="right">Total outstanding</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {aging.length === 0 ? (
                  <EmptyRow colSpan={7} text="Nothing outstanding -- every policy is fully paid." />
                ) : (
                  <>
                    {aging.map((a) => (
                      <TableRow key={`${a.client}|${a.currency}`}>
                        <TableCell>{a.client}</TableCell>
                        <TableCell>{a.currency}</TableCell>
                        {AGING_BUCKETS.map((b) => (
                          <TableCell key={b} align="right">{formatMoney(a.buckets[b], a.currency)}</TableCell>
                        ))}
                        <TableCell align="right"><strong>{formatMoney(a.total, a.currency)}</strong></TableCell>
                      </TableRow>
                    ))}
                    <TableRow>
                      <TableCell colSpan={2}><strong>Total outstanding</strong></TableCell>
                      <TableCell colSpan={5} align="right"><strong>{formatMoneyByCurrency(agingTotal, functional)}</strong></TableCell>
                    </TableRow>
                  </>
                )}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>
    </Box>
  );
}

function AgingStrip({ aging }: { aging: ReturnType<typeof agedBalances> }) {
  if (aging.length === 0) {
    return <Typography variant="body2" color="text.secondary">Nothing outstanding.</Typography>;
  }
  const byCurrency = new Map<string, Record<AgingBucket, number>>();
  for (const a of aging) {
    const t = byCurrency.get(a.currency) ?? { current: 0, d30: 0, d60: 0, d90: 0, over90: 0 };
    for (const b of AGING_BUCKETS) t[b] += a.buckets[b];
    byCurrency.set(a.currency, t);
  }
  return (
    <Stack direction="row" spacing={3} flexWrap="wrap" useFlexGap>
      {Array.from(byCurrency.entries()).map(([cur, buckets]) => (
        <Box key={cur} sx={{ p: 1.5, borderRadius: 1, bgcolor: 'action.hover' }}>
          <Typography variant="caption" color="text.secondary">{cur}</Typography>
          <Typography variant="body2">
            {AGING_BUCKETS.map((b) => `${AGING_LABEL[b]}: ${formatMoney(buckets[b], cur)}`).join('  ·  ')}
          </Typography>
        </Box>
      ))}
    </Stack>
  );
}

function totalByCurrency(rows: StatementRow[], key: 'billed_amount' | 'received_amount' | 'balance_amount'): Record<string, number> {
  const totals: Record<string, number> = {};
  for (const r of rows) {
    const cur = r.currency || 'UGX';
    totals[cur] = (totals[cur] ?? 0) + Number(r[key] ?? 0);
  }
  return totals;
}
