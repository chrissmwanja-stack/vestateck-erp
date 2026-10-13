import { useEffect, useMemo, useState } from 'react';
import {
  Alert, Box, Button, Card, CardContent, CircularProgress, Grid, MenuItem, Stack, Table, TableBody, TableCell,
  TableHead, TableRow, TextField, Typography,
} from '@mui/material';
import { exportReportToExcel, exportReportToPdf, type ReportExportColumn } from '../../../../../lib/reportExport';
import { errorText, rows, table } from '../../db';
import {
  buildCommissionStatement, formatMoney, STATEMENT_STATUS_LABEL, validateStatementPeriod,
} from '../../logic';
import { EmptyRow, ErrorBanner, PageHeader } from '../../shared';
import type { CommissionEntry, CommissionStatement, CommissionStatementRow, Policy } from '../../types';

const todayIso = () => new Date().toISOString().slice(0, 10);
const monthStartIso = () => `${todayIso().slice(0, 8)}01`;

function Kpi({ label, value, hint }: { label: string; value: string; hint?: string }) {
  return (
    <Card variant="outlined" sx={{ height: '100%' }}>
      <CardContent>
        <Typography variant="body2" color="text.secondary">{label}</Typography>
        <Typography variant="h6" fontWeight={700}>{value}</Typography>
        {hint && <Typography variant="caption" color="text.secondary">{hint}</Typography>}
      </CardContent>
    </Card>
  );
}

const CommissionStatements = () => {
  const [insurers, setInsurers] = useState<{ id: string; name: string }[]>([]);
  const [insurerId, setInsurerId] = useState('');
  const [from, setFrom] = useState(monthStartIso());
  const [to, setTo] = useState(todayIso());
  const [statement, setStatement] = useState<CommissionStatement | null>(null);
  const [generated, setGenerated] = useState<{ insurer: string; from: string; to: string } | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const list = await rows<{ id: string; name: string }>(table('ins_insurers').select('id, name').order('name', { ascending: true }));
        if (!cancelled) setInsurers(list);
      } catch (e) {
        if (!cancelled) setError(errorText(e));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  const periodProblem = validateStatementPeriod(from, to);
  const insurerName = useMemo(() => insurers.find((i) => i.id === insurerId)?.name ?? '', [insurers, insurerId]);

  const generate = async () => {
    if (!insurerId || periodProblem) return;
    setLoading(true);
    setError(null);
    setStatement(null);
    try {
      const [policies, ledger] = await Promise.all([
        rows<Policy>(table('ins_policies').select('*, ins_clients(bd_clients(name))').eq('insurer_id', insurerId).neq('status', 'draft')),
        rows<CommissionEntry>(table('ins_commission_ledger').select('*').eq('insurer_id', insurerId)),
      ]);
      setStatement(buildCommissionStatement(policies, ledger, { from, to }));
      setGenerated({ insurer: insurerName, from, to });
    } catch (e) {
      setError(errorText(e));
    } finally {
      setLoading(false);
    }
  };

  const currency = statement?.rows[0]?.currency ?? 'UGX';
  const money = (n: number) => formatMoney(n, currency);

  const columns: ReportExportColumn<CommissionStatementRow>[] = [
    { header: 'Policy', accessor: (r) => r.policy_no },
    { header: 'Client', accessor: (r) => r.client_name },
    { header: 'Bound', accessor: (r) => r.bound_on },
    { header: 'Gross premium', accessor: (r) => r.gross_premium, align: 'right' },
    { header: 'Net to insurer', accessor: (r) => r.net_premium, align: 'right' },
    { header: 'Commission', accessor: (r) => r.commission, align: 'right' },
    { header: 'Status', accessor: (r) => STATEMENT_STATUS_LABEL[r.status] },
    { header: 'Earned on', accessor: (r) => r.earned_on ?? '' },
    { header: 'Transfer', accessor: (r) => (r.transfer_no ? `${r.transfer_no} (${r.transfer_date ?? ''})` : '') },
  ];

  const baseName = generated ? `commission-statement-${generated.insurer.replace(/[^A-Za-z0-9]+/g, '-')}-${generated.from}-to-${generated.to}` : '';
  const exportRows: CommissionStatementRow[] = statement
    ? [
        ...statement.rows,
        {
          policy_id: 'total', policy_no: 'TOTAL', client_name: `${statement.totals.policies} policies`, bound_on: '', currency,
          gross_premium: statement.totals.gross_premium, net_premium: statement.totals.net_premium,
          commission: statement.totals.commission, status: 'deferred', earned_on: null, transfer_no: null, transfer_date: null,
        },
      ]
    : [];
  // The synthetic total row must not claim a commission status.
  const exportColumns = columns.map((c) => (c.header === 'Status' ? { ...c, accessor: (r: CommissionStatementRow) => (r.policy_id === 'total' ? '' : c.accessor(r)) } : c));
  const subtitle = generated
    ? `${generated.insurer} | policies bound ${generated.from} to ${generated.to} | ${currency}`
    : undefined;

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <PageHeader
        title="Commission statement"
        subtitle="Commission on the policies placed with one insurer in a period, by status. Policies bound before commission deferral show as legacy."
        actions={
          statement && statement.rows.length > 0 && (
            <Stack direction="row" spacing={1}>
              <Button variant="outlined" onClick={() => exportReportToExcel(baseName, 'Statement', exportColumns, exportRows)}>Export Excel</Button>
              <Button variant="outlined" onClick={() => exportReportToPdf(baseName, 'Commission statement', exportColumns, exportRows, subtitle)}>Export PDF</Button>
            </Stack>
          )
        }
      />
      <ErrorBanner message={error} />

      <Stack direction={{ xs: 'column', md: 'row' }} spacing={2} sx={{ mb: 3 }} alignItems={{ md: 'center' }}>
        <TextField select size="small" label="Insurer" value={insurerId} onChange={(e) => setInsurerId(e.target.value)} sx={{ minWidth: 260 }}>
          {insurers.map((i) => <MenuItem key={i.id} value={i.id}>{i.name}</MenuItem>)}
        </TextField>
        <TextField size="small" type="date" label="Bound from" value={from} onChange={(e) => setFrom(e.target.value)} InputLabelProps={{ shrink: true }} />
        <TextField size="small" type="date" label="Bound to" value={to} onChange={(e) => setTo(e.target.value)} InputLabelProps={{ shrink: true }} />
        <Button variant="contained" onClick={generate} disabled={!insurerId || !!periodProblem || loading}>Generate</Button>
      </Stack>
      {periodProblem && <Alert severity="warning" sx={{ mb: 2 }}>{periodProblem}</Alert>}

      {loading && <Box sx={{ display: 'flex', justifyContent: 'center', py: 6 }}><CircularProgress /></Box>}

      {statement && !loading && (
        <>
          <Grid container spacing={2} sx={{ mb: 3 }}>
            <Grid item xs={12} sm={6} md={3}><Kpi label="Gross premium" value={money(statement.totals.gross_premium)} hint={`${statement.totals.policies} policies`} /></Grid>
            <Grid item xs={12} sm={6} md={3}><Kpi label="Net to insurer" value={money(statement.totals.net_premium)} /></Grid>
            <Grid item xs={12} sm={6} md={3}><Kpi label="Commission" value={money(statement.totals.commission)} /></Grid>
            <Grid item xs={12} sm={6} md={3}>
              <Kpi
                label="By status"
                value={`${money(statement.totals.earned + statement.totals.transferred)} earned`}
                hint={`Deferred ${money(statement.totals.deferred)} | Transferred ${money(statement.totals.transferred)} | Legacy ${money(statement.totals.legacy)}`}
              />
            </Grid>
          </Grid>

          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>Policy</TableCell>
                <TableCell>Client</TableCell>
                <TableCell>Bound</TableCell>
                <TableCell align="right">Gross premium</TableCell>
                <TableCell align="right">Net to insurer</TableCell>
                <TableCell align="right">Commission</TableCell>
                <TableCell>Status</TableCell>
                <TableCell>Earned on</TableCell>
                <TableCell>Transfer</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {statement.rows.length === 0 ? (
                <EmptyRow colSpan={9} text="No policies were bound with this insurer in this period." />
              ) : (
                statement.rows.map((r) => (
                  <TableRow key={r.policy_id}>
                    <TableCell>{r.policy_no}</TableCell>
                    <TableCell>{r.client_name}</TableCell>
                    <TableCell>{r.bound_on}</TableCell>
                    <TableCell align="right">{money(r.gross_premium)}</TableCell>
                    <TableCell align="right">{money(r.net_premium)}</TableCell>
                    <TableCell align="right">{money(r.commission)}</TableCell>
                    <TableCell>{STATEMENT_STATUS_LABEL[r.status]}</TableCell>
                    <TableCell>{r.earned_on ?? '-'}</TableCell>
                    <TableCell>{r.transfer_no ? `${r.transfer_no} (${r.transfer_date ?? '-'})` : '-'}</TableCell>
                  </TableRow>
                ))
              )}
            </TableBody>
          </Table>
        </>
      )}
    </Box>
  );
};

export default CommissionStatements;
