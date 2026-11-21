import { businessTodayDate } from '../../../../../lib/businessDate';
import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Alert, Box, Button, Card, CardContent, CircularProgress, MenuItem, Stack, Table, TableBody, TableCell,
  TableHead, TableRow, TextField, ToggleButton, ToggleButtonGroup, Typography,
} from '@mui/material';
import { allRows, errorText, rpc, table } from '../../db';
import { friendlyError, formatMoney } from '../../logic';
import { useInsuranceAccess } from '../../access';
import { ErrorBanner } from '../../shared';
import {
  STATEMENT_PERIOD_LABEL, statementCurrencies, statementLineNet, statementPeriodBounds, statementPeriodLabel,
  statementWithholdingSentence,
  type AgentStatement, type AgentStatementLine, type StatementPeriod,
} from '../../agentStatements';
import { buildAgentStatementPdf } from '../../agentStatementPdf';
import { downloadTextFile } from './download';

interface Intermediary { id: string; name: string; category: string }

const statusOf = (l: AgentStatementLine) => (l.status === 'paid' ? 'Paid' : l.status === 'eligible' ? 'Eligible' : 'Accrued');

/**
 * Statements of account for one intermediary.
 *
 * The tab answers the question an agent actually asks -- "what do you owe me, and
 * what did you do with the tax?" -- and it answers it per currency, because an
 * agent paid in shillings on one policy and dollars on another has two answers.
 * Every figure comes from ins_agent_commission_statement(); nothing is added up
 * in the browser.
 */
const AgentCommissionStatements = () => {
  const { canManage } = useInsuranceAccess();

  const [agents, setAgents] = useState<Intermediary[]>([]);
  const [agentId, setAgentId] = useState<string>('');
  const [period, setPeriod] = useState<StatementPeriod>('this_month');
  const [statement, setStatement] = useState<AgentStatement | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const rows = await allRows<Intermediary>(() =>
          table('ins_intermediaries').select('id, name, category').order('name'));
        if (cancelled) return;
        setAgents(rows);
        if (rows.length > 0 && !agentId) setAgentId(rows[0].id);
      } catch (e) {
        if (!cancelled) setError(friendlyError(errorText(e)));
      }
    })();
    return () => { cancelled = true; };
    // Agent list is loaded once; selection changes should not refetch it.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const load = useCallback(async (id: string, p: StatementPeriod) => {
    if (!id) return;
    setLoading(true);
    try {
      const bounds = statementPeriodBounds(p, businessTodayDate());
      const data = await rpc<AgentStatement>('ins_agent_commission_statement', {
        p_intermediary_id: id,
        p_from: bounds.from,
        p_to: bounds.to,
      });
      setStatement(data);
      setError(null);
    } catch (e) {
      setError(friendlyError(errorText(e)));
      setStatement(null);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { void load(agentId, period); }, [agentId, period, load]);

  const currencies = useMemo(() => (statement ? statementCurrencies(statement) : []), [statement]);
  const sortedLines = useMemo(
    () => (statement ? [...statement.lines].sort((a, b) => a.statement_date.localeCompare(b.statement_date)) : []),
    [statement],
  );

  const download = () => {
    if (!statement) return;
    const today = businessTodayDate().toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' });
    const pdf = buildAgentStatementPdf(statement, today);
    const safe = statement.name.replace(/[^A-Za-z0-9]+/g, '-').replace(/^-|-$/g, '');
    downloadTextFile(`${safe}-statement-${statement.from ?? 'all'}-${statement.to ?? 'all'}.pdf`, pdf);
  };

  return (
    <Box>
      <Typography variant="body2" color="text.secondary" sx={{ maxWidth: 780, mb: 2 }}>
        What one intermediary earned, what was withheld and what has been paid. The period runs on the
        <strong> payment date</strong>, not the date the paperwork was entered: a share earned in November and paid
        in December belongs on December&apos;s statement.
      </Typography>
      <ErrorBanner message={error} />

      <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2} sx={{ mb: 3 }} alignItems={{ sm: 'center' }}>
        <TextField select size="small" label="Intermediary" value={agentId} sx={{ minWidth: 260 }}
          onChange={(e) => setAgentId(e.target.value)}>
          {agents.map((a) => <MenuItem key={a.id} value={a.id}>{a.name}</MenuItem>)}
        </TextField>
        <ToggleButtonGroup size="small" exclusive value={period}
          onChange={(_, v: StatementPeriod | null) => { if (v) setPeriod(v); }}>
          {(Object.keys(STATEMENT_PERIOD_LABEL) as StatementPeriod[]).map((p) => (
            <ToggleButton key={p} value={p}>{STATEMENT_PERIOD_LABEL[p]}</ToggleButton>
          ))}
        </ToggleButtonGroup>
        <Box sx={{ flexGrow: 1 }} />
        <Button variant="contained" onClick={download} disabled={!statement || loading || statement.lines.length === 0}>
          Download PDF
        </Button>
      </Stack>

      {loading && <CircularProgress />}

      {!loading && statement && (
        <>
          <Typography variant="h6">{statement.name}</Typography>
          <Typography variant="caption" color="text.secondary" display="block" sx={{ mb: 2 }}>
            {statementPeriodLabel(statement)}
            {statement.category === 'insurer_appointed' && ' · insurer-appointed: this agent is not paid from the brokerage\'s books'}
          </Typography>

          {/* Driven by the LINES, not by the currency cards. An empty statement
              still has books to report on, so the fallback would otherwise invent
              a currency card of zeros and the reader would conclude the agent
              earned nothing rather than that nothing has happened yet. */}
          {statement.lines.length === 0 && (
            <Alert severity="info" sx={{ mb: 2 }}>
              Nothing has been earned by this intermediary in the selected period.
            </Alert>
          )}

          <Stack direction={{ xs: 'column', md: 'row' }} spacing={2} sx={{ mb: 3 }}>
            {statement.lines.length > 0 && currencies.map((c) => (
              <Card variant="outlined" key={c.currency} sx={{ flex: 1 }}>
                <CardContent>
                  <Typography variant="overline" color="text.secondary">{c.currency}</Typography>
                  <Stack spacing={1} sx={{ mt: 0.5 }}>
                    <Row label="Gross commission" value={formatMoney(c.gross_commission, c.currency)} />
                    <Row label="Tax withheld" value={formatMoney(c.wht_withheld, c.currency)} />
                    <Row label="Net commission" value={formatMoney(c.net_commission, c.currency)} strong />
                    <Row label="Paid to agent" value={formatMoney(c.paid, c.currency)} />
                    <Row label="Outstanding" value={formatMoney(c.outstanding, c.currency)} strong />
                  </Stack>
                </CardContent>
              </Card>
            ))}
          </Stack>

          {statement.lines.length > 0 && (
            <>
              <Typography variant="body2" sx={{ mb: 2, maxWidth: 820 }}>
                {statementWithholdingSentence(statement)}
              </Typography>
              <Card>
                <CardContent sx={{ p: 0, overflowX: 'auto' }}>
                  <Table size="small">
                    <TableHead>
                      <TableRow>
                        <TableCell>Date</TableCell><TableCell>Policy</TableCell><TableCell>Status</TableCell>
                        <TableCell align="right">Gross</TableCell>
                        <TableCell align="right">Tax</TableCell>
                        <TableCell align="right">Net</TableCell>
                        <TableCell>Withholding</TableCell>
                      </TableRow>
                    </TableHead>
                    <TableBody>
                      {sortedLines.map((l) => (
                        <TableRow key={l.accrual_id} hover>
                          <TableCell>{l.statement_date}</TableCell>
                          <TableCell>{l.policy_no ?? '-'}</TableCell>
                          <TableCell>{statusOf(l)}</TableCell>
                          <TableCell align="right">{formatMoney(l.gross_amount, l.currency)}</TableCell>
                          <TableCell align="right">{formatMoney(l.wht_amount, l.currency)}</TableCell>
                          <TableCell align="right">{formatMoney(statementLineNet(l), l.currency)}</TableCell>
                          <TableCell>
                            {l.wht_amount > 0
                              ? `${l.wht_rate_pct ?? '-'}% ${l.wht_is_final === true ? 'final' : l.wht_is_final === false ? 'on account' : ''}`.trim()
                              : l.status === 'paid' ? 'none withheld' : 'determined when paid'}
                          </TableCell>
                        </TableRow>
                      ))}
                    </TableBody>
                  </Table>
                </CardContent>
              </Card>
            </>
          )}

          {!canManage && (
            <Typography variant="caption" color="text.secondary" display="block" sx={{ mt: 2 }}>
              You can read this statement; paying an agent is a manager action.
            </Typography>
          )}
        </>
      )}
    </Box>
  );
};

function Row({ label, value, strong }: { label: string; value: string; strong?: boolean }) {
  return (
    <Stack direction="row" justifyContent="space-between" spacing={2}>
      <Typography variant="body2" color="text.secondary">{label}</Typography>
      <Typography variant="body2" fontWeight={strong ? 700 : 400}>{value}</Typography>
    </Stack>
  );
}

export default AgentCommissionStatements;
