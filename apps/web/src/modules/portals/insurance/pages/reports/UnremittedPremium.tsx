import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Alert, Box, Button, Card, CardContent, Chip, CircularProgress, Stack, Table, TableBody, TableCell, TableHead, TableRow, TextField, Typography,
} from '@mui/material';
import { useNavigate } from 'react-router-dom';
import { allRows, errorText, rows, rpc, table } from '../../db';
import { localIsoDate } from '../../fx';
import { formatMoney, formatMoneyByCurrency, sumByCurrency } from '../../logic';
import {
  REMITTANCE_STATUS_LABEL, REMITTANCE_STATUS_ORDER, daysPastDeadline, remittanceFacts, sortRemittanceRows, type RemittanceRow, type RemittanceStatus,
} from '../../remittance';
import { EmptyRow, ErrorBanner, PageHeader } from '../../shared';

export const REGULATORY_PATH = '/insurance/regulatory';

const STATUS_COLOR: Record<RemittanceStatus, 'error' | 'warning' | 'success' | 'default'> = {
  overdue: 'error',
  due_today: 'warning',
  within_deadline: 'success',
  deadline_not_set: 'default',
  receipt_date_missing: 'default',
};

// Premium the brokerage has received and not yet remitted to the insurer, with the
// remittance deadline taken from the approved regulatory rule. The report is read-only.
export default function UnremittedPremium() {
  const navigate = useNavigate();
  const [asOf, setAsOf] = useState(localIsoDate());
  const [items, setItems] = useState<RemittanceRow[]>([]);
  const [insurers, setInsurers] = useState<Map<string, string>>(new Map());
  const [currencies, setCurrencies] = useState<Map<string, string>>(new Map());
  const [functional, setFunctional] = useState('UGX');
  const [filter, setFilter] = useState<'all' | RemittanceStatus>('all');
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const [report, ins, pol, settings] = await Promise.all([
        rpc<RemittanceRow[]>('ins_unremitted_premium_report', { p_as_of: asOf }),
        rows<{ id: string; name: string }>(table('ins_insurers').select('id, name')),
        allRows<{ id: string; currency: string }>(() => table('ins_policies').select('id, currency').in('status', ['active', 'renewed']).order('id')),
        rows<{ functional_currency: string }>(table('tenant_ledger_settings').select('functional_currency')),
      ]);
      setItems(report ?? []);
      setInsurers(new Map(ins.map((i) => [i.id, i.name])));
      setCurrencies(new Map(pol.map((p) => [p.id, p.currency])));
      setFunctional(settings[0]?.functional_currency ?? 'UGX');
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

  const currencyOf = (r: RemittanceRow) => currencies.get(r.policy_id) ?? functional;
  const facts = useMemo(() => remittanceFacts(items), [items]);
  const counts = useMemo(() => {
    const c = Object.fromEntries(REMITTANCE_STATUS_ORDER.map((s) => [s, 0])) as Record<RemittanceStatus, number>;
    for (const r of items) c[r.status] += 1;
    return c;
  }, [items]);
  const visible = useMemo(() => sortRemittanceRows(items.filter((r) => filter === 'all' || r.status === filter)), [items, filter]);
  const total = sumByCurrency(items, currencyOf, (r) => r.unremitted_amount, functional);

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <PageHeader
        title="Unremitted premium"
        subtitle="Premium received from clients and not yet paid on to the insurer, against the remittance deadline."
        actions={
          <TextField size="small" type="date" label="As of" InputLabelProps={{ shrink: true }} value={asOf} onChange={(e) => setAsOf(e.target.value)} />
        }
      />
      <ErrorBanner message={error} />
      {facts.deadlineNotSet > 0 && (
        <Alert
          severity="warning"
          sx={{ mb: 2 }}
          action={<Button color="inherit" size="small" onClick={() => navigate(REGULATORY_PATH)}>Regulatory rules</Button>}
        >
          No remittance deadline is approved, so {facts.deadlineNotSet} {facts.deadlineNotSet === 1 ? 'policy has' : 'policies have'} no deadline to check. Propose
          the value for remittance.deadline_working_days and have an assigned approver approve it. No default is assumed.
        </Alert>
      )}
      <Alert severity="info" sx={{ mb: 2 }}>
        Deadlines count Monday to Friday only, because public holidays are not modelled yet. The receipt date is the earliest posted receipt for the policy, so a
        deadline can come out earlier than the true one. Both err towards an alert, not away from one.
      </Alert>

      {loading ? (
        <Box sx={{ display: 'flex', justifyContent: 'center', py: 6 }}><CircularProgress /></Box>
      ) : (
        <>
          <Stack direction="row" spacing={1} sx={{ mb: 2, flexWrap: 'wrap', gap: 1 }} alignItems="center">
            <Chip label={`All (${items.length})`} color={filter === 'all' ? 'primary' : 'default'} onClick={() => setFilter('all')} />
            {REMITTANCE_STATUS_ORDER.map((s) => (
              <Chip key={s} label={`${REMITTANCE_STATUS_LABEL[s]} (${counts[s]})`} color={filter === s ? 'primary' : 'default'}
                variant={counts[s] ? 'filled' : 'outlined'} onClick={() => setFilter(s)} />
            ))}
          </Stack>
          <Card>
            <CardContent sx={{ p: 0, overflowX: 'auto' }}>
              <Table size="small">
                <TableHead>
                  <TableRow>
                    <TableCell>Policy</TableCell>
                    <TableCell>Insurer</TableCell>
                    <TableCell align="right">Held, not remitted</TableCell>
                    <TableCell>Received</TableCell>
                    <TableCell>Deadline</TableCell>
                    <TableCell>Status</TableCell>
                  </TableRow>
                </TableHead>
                <TableBody>
                  {visible.length === 0 ? (
                    <EmptyRow colSpan={6} text={items.length === 0 ? 'No premium is being held for remittance.' : 'Nothing matches this filter.'} />
                  ) : (
                    visible.map((r) => {
                      const late = daysPastDeadline(r.deadline_date, asOf);
                      return (
                        <TableRow key={r.policy_id} hover sx={{ cursor: 'pointer' }} onClick={() => navigate(`/insurance/policies/${r.policy_id}`)}>
                          <TableCell sx={{ fontFamily: 'monospace', fontWeight: 600 }}>{r.policy_no}</TableCell>
                          <TableCell>{insurers.get(r.insurer_id) ?? '-'}</TableCell>
                          <TableCell align="right">{formatMoney(Number(r.unremitted_amount), currencyOf(r))}</TableCell>
                          <TableCell>{r.receipt_date ?? '-'}</TableCell>
                          <TableCell>{r.deadline_date ?? '-'}</TableCell>
                          <TableCell>
                            <Chip size="small" color={STATUS_COLOR[r.status]} variant={r.status === 'overdue' || r.status === 'due_today' ? 'filled' : 'outlined'}
                              label={REMITTANCE_STATUS_LABEL[r.status]} />
                            {r.status === 'overdue' && late > 0 && (
                              <Typography variant="caption" color="error" sx={{ display: 'block' }}>{late} {late === 1 ? 'day' : 'days'} late</Typography>
                            )}
                          </TableCell>
                        </TableRow>
                      );
                    })
                  )}
                </TableBody>
              </Table>
            </CardContent>
          </Card>
          {items.length > 0 && (
            <Typography variant="body2" sx={{ mt: 2, whiteSpace: 'pre-line' }}>
              <strong>Total held, not remitted:</strong>{'\n'}{formatMoneyByCurrency(total, functional)}
            </Typography>
          )}
        </>
      )}
    </Box>
  );
}
