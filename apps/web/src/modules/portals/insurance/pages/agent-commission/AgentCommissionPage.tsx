import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Box, Card, CardContent, Chip, CircularProgress, Grid, Tab, Tabs, Table, TableBody, TableCell,
  TableHead, TableRow, Typography,
} from '@mui/material';
import { allRows, errorText, table } from '../../db';
import { formatMoney } from '../../logic';
import { EmptyRow, ErrorBanner, PageHeader } from '../../shared';
import AgentCommissionTerms from './AgentCommissionTerms';
import AgentCommissionAccruals from './AgentCommissionAccruals';
import AgentCommissionPayments from './AgentCommissionPayments';
import AgentCommissionWht from './AgentCommissionWht';
import AgentCommissionStatements from './AgentCommissionStatements';
import {
  AGENT_ACCRUAL_STATUS_LABEL, recentAccruals, summariseAccruals, whtStillHeld,
  type AgentAccrual, type CurrencyTotals, type WhtLineRef, type WhtRemittance,
} from '../../agentCommission';

type TabKey = 'overview' | 'terms' | 'accruals' | 'payments' | 'statements' | 'wht';

const TABS: { key: TabKey; label: string }[] = [
  { key: 'overview', label: 'Overview' },
  { key: 'terms', label: 'Commission Terms' },
  { key: 'accruals', label: 'Accruals' },
  { key: 'payments', label: 'Payments' },
  { key: 'statements', label: 'Statements' },
  { key: 'wht', label: 'WHT Remittances' },
];



/** One line per currency; currencies are never added together. */
const money = (totals: CurrencyTotals): string => {
  const entries = Object.entries(totals);
  return entries.length === 0 ? formatMoney(0) : entries.map(([c, v]) => formatMoney(v, c)).join(' · ');
};

function Kpi({ label, value, hint }: { label: string; value: string; hint: string }) {
  return (
    <Card variant="outlined" sx={{ height: '100%' }}>
      <CardContent>
        <Typography variant="body2" color="text.secondary">{label}</Typography>
        <Typography variant="h5" fontWeight={700}>{value}</Typography>
        <Typography variant="caption" color="text.secondary">{hint}</Typography>
      </CardContent>
    </Card>
  );
}

const AgentCommissionPage = () => {
  const [tab, setTab] = useState<TabKey>('overview');
  const [accruals, setAccruals] = useState<AgentAccrual[]>([]);
  // Withholding is a liability only until it is paid over, so the tile needs to
  // know which returns have actually been settled.
  const [whtLines, setWhtLines] = useState<WhtLineRef[]>([]);
  const [whtRemittances, setWhtRemittances] = useState<Pick<WhtRemittance, 'id' | 'status'>[]>([]);
  const [agents, setAgents] = useState<Record<string, string>>({});
  const [policies, setPolicies] = useState<Record<string, string>>({});
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const [acc, ints, pols, lines, rems] = await Promise.all([
        allRows<AgentAccrual>(() => table('ins_agent_commission_accruals').select('*').order('updated_at', { ascending: false }).order('id')),
        allRows<{ id: string; name: string }>(() => table('ins_intermediaries').select('id, name').order('id')),
        allRows<{ id: string; policy_no: string | null }>(() => table('ins_policies').select('id, policy_no').order('id')),
        allRows<WhtLineRef>(() => table('ins_wht_remittance_lines').select('accrual_id, amount, remittance_id').order('id')),
        allRows<Pick<WhtRemittance, 'id' | 'status'>>(() => table('ins_wht_remittances').select('id, status').order('id')),
      ]);
      setAccruals(acc);
      setWhtLines(lines);
      setWhtRemittances(rems);
      setAgents(Object.fromEntries(ints.map((i) => [i.id, i.name])));
      setPolicies(Object.fromEntries(pols.map((p) => [p.id, p.policy_no ?? '-'])));
      setError(null);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { void load(); }, [load]);

  const summary = useMemo(() => summariseAccruals(accruals), [accruals]);
  const held = useMemo(() => whtStillHeld(accruals, whtLines, whtRemittances), [accruals, whtLines, whtRemittances]);
  const recent = useMemo(() => recentAccruals(accruals), [accruals]);

  return (
    <Box>
      <PageHeader
        title="Agent Commission"
        subtitle="What the brokerage owes its sub-agents and referral partners. The brokerage's own commission from insurers is under Commission."
      />
      <ErrorBanner message={error} />
      <Tabs value={tab} onChange={(_, v: TabKey) => setTab(v)} sx={{ mb: 2 }}>
        {TABS.map((t) => <Tab key={t.key} value={t.key} label={t.label} />)}
      </Tabs>

      {tab === 'terms' && <AgentCommissionTerms />}
      {tab === 'accruals' && <AgentCommissionAccruals />}
      {tab === 'payments' && <AgentCommissionPayments />}
      {tab === 'statements' && <AgentCommissionStatements />}
      {tab === 'wht' && <AgentCommissionWht />}

      {tab === 'overview' && (loading ? <CircularProgress /> : (
        <>
          <Grid container spacing={2} sx={{ mb: 3 }}>
            <Grid item xs={12} sm={6} md={3}><Kpi label="Accrued" value={money(summary.accrued)} hint="Earned by agents, not yet eligible" /></Grid>
            <Grid item xs={12} sm={6} md={3}><Kpi label="Eligible for payment" value={money(summary.eligible)} hint="Settlement conditions met" /></Grid>
            <Grid item xs={12} sm={6} md={3}><Kpi label="Paid" value={money(summary.paid)} hint="Gross, already paid out" /></Grid>
            <Grid item xs={12} sm={6} md={3}>
              <Kpi label="Withholding still held" value={money(held)}
                hint="Withheld and not yet paid to URA" />
            </Grid>
            <Grid item xs={12}><Kpi label="Outstanding agent liability" value={money(summary.outstanding)} hint="Net still owed (accrued + eligible)" /></Grid>
          </Grid>
          <Typography variant="h6" sx={{ mb: 1 }}>Recent commission activity</Typography>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>Agent</TableCell><TableCell>Policy</TableCell>
                <TableCell align="right">Gross</TableCell><TableCell>Status</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {recent.length === 0 && <EmptyRow colSpan={4} text="No agent commission has accrued yet." />}
              {recent.map((a) => (
                <TableRow key={a.id}>
                  <TableCell>{agents[a.intermediary_id] ?? '-'}</TableCell>
                  <TableCell>{policies[a.policy_id] ?? '-'}</TableCell>
                  <TableCell align="right">{formatMoney(a.gross_amount, a.currency)}</TableCell>
                  <TableCell><Chip size="small" label={AGENT_ACCRUAL_STATUS_LABEL[a.status]} /></TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </>
      ))}
    </Box>
  );
};

export default AgentCommissionPage;
