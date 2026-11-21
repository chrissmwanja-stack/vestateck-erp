import { businessToday } from '../../../../../lib/businessDate';
import { useCallback, useEffect, useState } from 'react';
import {
  Alert, Box, Button, Card, CardContent, CircularProgress, MenuItem, Stack, Table, TableBody, TableCell, TableHead, TableRow, TextField,
  Typography,
} from '@mui/material';
import { exportReportToExcel, exportReportToPdf } from '../../../../../lib/reportExport';
import { errorText, rpc } from '../../db';
import { formatMoney, formatMoneyByCurrency, sumByCurrency } from '../../logic';
import {
  CLAIMS_GROUPS, CLAIM_AGE_BUCKET_LABEL, claimsAgeingColumns, type ClaimAgeingLine, type ClaimsGroupBy,
} from '../../reportsSuite';
import { EmptyRow, ErrorBanner, PageHeader } from '../../shared';

// How long open claims have been unresolved, as at a date. Built on the claims register on the server, so the totals
// here are the register's totals, grouped by age (days since the claim was notified).
export default function ClaimsAgeing() {
  const [asOf, setAsOf] = useState(businessToday());
  const [groupBy, setGroupBy] = useState<ClaimsGroupBy>('none');
  const [rows, setRows] = useState<ClaimAgeingLine[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      setRows((await rpc<ClaimAgeingLine[]>('ins_report_claims_ageing', { p_as_of: asOf, p_group_by: groupBy })) ?? []);
      setError(null);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setLoading(false);
    }
  }, [asOf, groupBy]);

  useEffect(() => {
    if (!asOf) return;
    load();
  }, [asOf, load]);

  const total = sumByCurrency(rows, (r) => r.currency, (r) => r.outstanding_total, 'UGX');
  const groupHeader = CLAIMS_GROUPS.find((g) => g.value === groupBy)?.label ?? 'Group';
  const columns = claimsAgeingColumns(groupHeader);
  const exportName = `claims-ageing-${asOf}`;
  const subtitle = [
    `As at ${asOf}`,
    groupBy === 'none' ? null : `By ${groupHeader.toLowerCase()}`,
    `Outstanding: ${formatMoneyByCurrency(total, 'UGX').split('\n').join('; ')}`,
  ].filter(Boolean).join('  |  ');

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <PageHeader
        title="Claims ageing"
        subtitle="How long claims have remained unresolved."
        actions={
          <Stack direction="row" spacing={1} alignItems="center">
            <TextField size="small" type="date" label="As at" InputLabelProps={{ shrink: true }} value={asOf} onChange={(e) => setAsOf(e.target.value)} />
            <TextField size="small" select label="Group by" value={groupBy} onChange={(e) => setGroupBy(e.target.value as ClaimsGroupBy)} sx={{ minWidth: 150 }}>
              {CLAIMS_GROUPS.map((g) => <MenuItem key={g.value} value={g.value}>{g.label}</MenuItem>)}
            </TextField>
            {!loading && rows.length > 0 && (
              <>
                <Button variant="outlined" onClick={() => exportReportToExcel(exportName, 'Claims ageing', columns, rows)}>Export Excel</Button>
                <Button variant="outlined" onClick={() => exportReportToPdf(exportName, 'Claims ageing', columns, rows, subtitle)}>Export PDF</Button>
              </>
            )}
          </Stack>
        }
      />
      <ErrorBanner message={error} />
      <Alert severity="info" sx={{ mb: 2 }}>
        Open claims only, aged from the day the claim was notified. Outstanding is the reserve for claims still being assessed and the
        unpaid approved amount for approved claims, exactly as in the claims register. Currencies are never added together.
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
                    <TableCell>{groupHeader === 'None' ? 'Claims' : groupHeader}</TableCell>
                    <TableCell>Currency</TableCell>
                    <TableCell>Age</TableCell>
                    <TableCell align="right">Claims</TableCell>
                    <TableCell align="right">Reserve</TableCell>
                    <TableCell align="right">Outstanding</TableCell>
                    <TableCell align="right">Oldest (days)</TableCell>
                  </TableRow>
                </TableHead>
                <TableBody>
                  {rows.length === 0 ? (
                    <EmptyRow colSpan={7} text="No claims were open on this date." />
                  ) : (
                    rows.map((r) => (
                      <TableRow key={`${r.group_key}|${r.currency}|${r.age_bucket}`}>
                        <TableCell>{r.group_label}</TableCell>
                        <TableCell>{r.currency}</TableCell>
                        <TableCell>{CLAIM_AGE_BUCKET_LABEL[r.age_bucket] ?? r.age_bucket}</TableCell>
                        <TableCell align="right">{Number(r.claim_count)}</TableCell>
                        <TableCell align="right">{formatMoney(Number(r.reserve_total), r.currency)}</TableCell>
                        <TableCell align="right" sx={{ fontWeight: 600 }}>{formatMoney(Number(r.outstanding_total), r.currency)}</TableCell>
                        <TableCell align="right">{Number(r.oldest_age_days)}</TableCell>
                      </TableRow>
                    ))
                  )}
                </TableBody>
              </Table>
            </CardContent>
          </Card>
          {rows.length > 0 && (
            <Typography variant="body2" sx={{ mt: 2, whiteSpace: 'pre-line' }}>
              <strong>Total outstanding:</strong>{'\n'}
              {formatMoneyByCurrency(total, 'UGX')}
            </Typography>
          )}
        </>
      )}
    </Box>
  );
}
