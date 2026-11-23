import { businessToday } from '../../../../lib/businessDate';
import { useEffect, useState } from 'react';
import { Alert, Box, Card, CardContent, CircularProgress, Grid, Stack, TextField, Typography } from '@mui/material';
import { useNavigate } from 'react-router-dom';
import { useMyModuleAccess } from '../../../../features/navigation/useMyModuleAccess';
import { allRows, errorText, rpc, table } from '../db';
import { remittanceFacts, type RemittanceRow } from '../remittance';
import { formatMoney, isClaimOpen, isInForce, renewalBucket } from '../logic';
import { dashboardAlerts, FINANCE_CASH_PATH, REGULATORY_RULES_PATH, REMITTANCE_REPORT_PATH, type DashboardAlert } from '../dashboardAlerts';
import { monthStartIso, type DashboardSummaryLine } from '../reportsSuite';
import type { Claim, Policy, RenewalRow } from '../types';
import { PageHeader, ErrorBanner } from '../shared';
import { useRenewalNotificationSweep } from '../renewalNotificationSweep';

interface Kpi {
  label: string;
  /** One line per currency for money figures; counts are a single line. */
  value: string;
  hint?: string;
  to?: string;
}

// The financial figures come from one server function, ins_dashboard_summary, which calls the same report
// functions as the reports screens, so the dashboard cannot disagree with them and nothing is totalled here.
// Money is shown per currency: amounts in different currencies are never added together.
// The counts and alerts below are computed from the RLS-scoped rows the user can already read.
function FinanceRow({ label, value, hint, strong, to }: { label: string; value: string; hint?: string; strong?: boolean; to?: string }) {
  const navigate = useNavigate();
  return (
    <Box
      onClick={to ? () => navigate(to) : undefined}
      sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline', gap: 2, cursor: to ? 'pointer' : 'default' }}
    >
      <Box>
        <Typography variant="body2">{label}</Typography>
        {hint && <Typography variant="caption" color="text.secondary">{hint}</Typography>}
      </Box>
      <Typography variant="body1" fontWeight={strong ? 700 : 400} sx={{ whiteSpace: 'nowrap' }}>{value}</Typography>
    </Box>
  );
}

export default function InsuranceDashboard() {
  const navigate = useNavigate();
  useRenewalNotificationSweep();
  // Premium cash requests are approved in the Finance workbench, which only Finance users can open.
  const canOpenFinanceCash = Boolean(useMyModuleAccess()?.canAccessFinance);
  const [kpis, setKpis] = useState<Kpi[] | null>(null);
  const [alerts, setAlerts] = useState<DashboardAlert[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [from, setFrom] = useState(monthStartIso());
  const [to, setTo] = useState(businessToday());
  const [summary, setSummary] = useState<DashboardSummaryLine[] | null>(null);
  const [summaryError, setSummaryError] = useState<string | null>(null);

  // A failure here must not hide the rest of the dashboard.
  useEffect(() => {
    if (!from || !to || from > to) return;
    let live = true;
    setSummary(null);
    rpc<DashboardSummaryLine[]>('ins_dashboard_summary', { p_from: from, p_to: to })
      .then((rows) => { if (live) { setSummary(rows ?? []); setSummaryError(null); } })
      .catch((e) => { if (live) { setSummary([]); setSummaryError(errorText(e)); } });
    return () => { live = false; };
  }, [from, to]);

  useEffect(() => {
    (async () => {
      try {
        // allRows pages through every row: a plain select stops at the API row cap and would
        // understate every figure below once a company grows past it.
        const today = businessToday();
        const [policies, claims, renewals, pendingCash, commission, settings, remittance] = await Promise.all([
          allRows<Pick<Policy, 'status' | 'expiry_date'>>(
            () => table('ins_policies').select('status, expiry_date').in('status', ['active', 'renewed']).order('id'),
          ),
          allRows<Pick<Claim, 'status'>>(() => table('ins_claims').select('status').order('id')),
          allRows<RenewalRow>(() => table('ins_renewal_pipeline').select('*').order('expiry_date', { ascending: true }).order('policy_id')),
          allRows<{ id: string }>(() => table('ins_policy_cash_requests').select('id').eq('status', 'pending').order('id')),
          allRows<{ earned_in_client_money: number | string | null }>(
            () => table('ins_commission_position').select('earned_in_client_money').order('tenant_id'),
          ),
          allRows<{ functional_currency: string }>(() => table('tenant_ledger_settings').select('functional_currency').order('tenant_id')),
          // Held premium against the remittance deadline. A failure here must not hide the rest of the dashboard.
          rpc<RemittanceRow[]>('ins_unremitted_premium_report', { p_as_of: today }).catch(() => null),
        ]);
        const functional = settings[0]?.functional_currency ?? 'UGX';

        // Active policies past their expiry date stay 'active' until renewed, so they are
        // counted under renewals (overdue) and not as cover in force.
        const inForce = policies.filter((p) => isInForce(p, today));
        const openClaims = claims.filter((c) => isClaimOpen(c.status));
        const toAssess = claims.filter((c) => c.status === 'notified' || c.status === 'assessing').length;
        const approvedUnsettled = claims.filter((c) => c.status === 'approved').length;
        const due30 = renewals.filter((r) => renewalBucket(r.days_to_expiry) === 'overdue' || renewalBucket(r.days_to_expiry) === 'd0_30').length;
        const overdue = renewals.filter((r) => renewalBucket(r.days_to_expiry) === 'overdue').length;
        const earnedNotTransferred = commission.reduce((s, c) => s + Number(c.earned_in_client_money ?? 0), 0);

        const held = remittance ? remittanceFacts(remittance) : null;

        setKpis([
          { label: 'Policies in force', value: String(inForce.length), to: '/insurance/policies' },
          { label: 'Renewals due (120 days)', value: String(renewals.length), hint: `${due30} within 30 days or overdue`, to: '/insurance/renewals' },
          { label: 'Open claims', value: String(openClaims.length), to: '/insurance/claims' },
          { label: 'Premium cash awaiting approval', value: String(pendingCash.length), to: canOpenFinanceCash ? FINANCE_CASH_PATH : '/insurance/policies' },
          // The commission position is one figure per company, in its own currency: only
          // policies in that currency can be bound today.
          { label: 'Commission earned, not transferred', value: formatMoney(earnedNotTransferred, functional), hint: 'In client money, awaiting transfer', to: '/insurance/commission' },
          ...(held
            ? [{
                label: 'Premium past remittance deadline',
                value: String(held.overdue),
                hint: held.deadlineNotSet > 0 ? 'No remittance deadline is approved yet' : `${held.dueToday} due today`,
                to: held.deadlineNotSet > 0 && held.overdue === 0 ? REGULATORY_RULES_PATH : REMITTANCE_REPORT_PATH,
              }]
            : []),
          { label: 'Claims to assess', value: String(toAssess), hint: `${approvedUnsettled} approved, not yet settled`, to: '/insurance/claims' },
        ]);
        setAlerts(
          dashboardAlerts({
            overdueRenewals: overdue,
            pendingCashRequests: pendingCash.length,
            claimsToAssess: toAssess,
            approvedClaimsUnsettled: approvedUnsettled,
            commissionEarnedNotTransferred: earnedNotTransferred,
            canOpenFinanceCash,
            remittanceOverdue: held?.overdue,
            remittanceDueToday: held?.dueToday,
            remittanceDeadlineNotSet: held?.deadlineNotSet,
          }),
        );
      } catch (e) {
        setError(e instanceof Error ? e.message : 'Could not load the dashboard');
      }
    })();
  }, [canOpenFinanceCash]);

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <PageHeader title="Insurance Brokerage" subtitle="Money is shown per currency. Amounts in different currencies are never added together." />
      <ErrorBanner message={error} />
      {!kpis && !error && (
        <Box sx={{ display: 'flex', justifyContent: 'center', py: 6 }}>
          <CircularProgress />
        </Box>
      )}
      {kpis && (
        <Stack spacing={2}>
          <Box>
            <Typography variant="subtitle1" fontWeight={700} gutterBottom>
              Needs attention
            </Typography>
            {alerts.length === 0 ? (
              <Typography variant="body2" color="text.secondary">Nothing needs attention right now.</Typography>
            ) : (
              <Stack spacing={1}>
                {alerts.map((a) => (
                  <Alert
                    key={a.id}
                    severity="warning"
                    variant="outlined"
                    onClick={() => navigate(a.to)}
                    sx={{ cursor: 'pointer' }}
                  >
                    {a.text}
                  </Alert>
                ))}
              </Stack>
            )}
          </Box>
          <Box>
            <Stack direction="row" spacing={2} alignItems="center" justifyContent="space-between" sx={{ flexWrap: 'wrap', gap: 1, mb: 1 }}>
              <Typography variant="subtitle1" fontWeight={700}>Financial position</Typography>
              <Stack direction="row" spacing={1}>
                <TextField size="small" type="date" label="From" InputLabelProps={{ shrink: true }} value={from} onChange={(e) => setFrom(e.target.value)} />
                <TextField size="small" type="date" label="To / as at" InputLabelProps={{ shrink: true }} value={to} onChange={(e) => setTo(e.target.value)} />
              </Stack>
            </Stack>
            {from > to && <Alert severity="warning" sx={{ mb: 1 }}>The start date must not be after the end date.</Alert>}
            {summaryError && <Alert severity="error" sx={{ mb: 1 }}>{summaryError}</Alert>}
            {summary === null && !summaryError && (
              <Box sx={{ display: 'flex', justifyContent: 'center', py: 3 }}><CircularProgress size={24} /></Box>
            )}
            {summary && summary.length === 0 && !summaryError && (
              <Typography variant="body2" color="text.secondary">No premium was written and nothing is outstanding for this period.</Typography>
            )}
            {summary && summary.length > 0 && (
              <Grid container spacing={2}>
                {summary.map((r) => (
                  <Grid item xs={12} md={6} key={r.currency}>
                    <Card variant="outlined" sx={{ height: '100%' }}>
                      <CardContent>
                        <Typography variant="subtitle2" color="text.secondary" gutterBottom>{r.currency}</Typography>
                        <Stack spacing={0.5}>
                          <FinanceRow label="Gross premium written" value={formatMoney(Number(r.gross_written), r.currency)} hint={`${r.policy_count} ${r.policy_count === 1 ? 'policy' : 'policies'} bound`} strong />
                          <FinanceRow label="Endorsements" value={formatMoney(Number(r.endorsements), r.currency)} />
                          <FinanceRow label="Cancellations and reversals" value={formatMoney(Number(r.cancellations) + Number(r.reversals), r.currency)} />
                          <FinanceRow label="Net premium written" value={formatMoney(Number(r.net_written), r.currency)} strong />
                          <FinanceRow
                            label="Commission earned"
                            value={r.commission_earned === null ? 'Not available' : formatMoney(Number(r.commission_earned), r.currency)}
                            hint={r.commission_earned === null ? 'No commission income posting rule is set up yet' : undefined}
                            strong
                          />
                          <FinanceRow label="Premium collected" value={formatMoney(Number(r.premium_collected), r.currency)} />
                          <FinanceRow
                            label="Outstanding premium"
                            value={formatMoney(Number(r.outstanding_premium), r.currency)}
                            hint={`${formatMoney(Number(r.overdue_premium), r.currency)} past due, as at ${to}`}
                            to="/insurance/reports/outstanding-premium"
                            strong
                          />
                          <FinanceRow
                            label="Claims outstanding"
                            value={formatMoney(Number(r.claims_outstanding), r.currency)}
                            hint={`${r.open_claim_count} open ${r.open_claim_count === 1 ? 'claim' : 'claims'}, as at ${to}`}
                            to="/insurance/reports/claims-register"
                            strong
                          />
                        </Stack>
                      </CardContent>
                    </Card>
                  </Grid>
                ))}
              </Grid>
            )}
            <Typography variant="caption" color="text.secondary" sx={{ display: 'block', mt: 1 }}>
              Written, commission and collected are movements in the period; outstanding premium and claims are positions as at the end date. Every
              figure is recomputed from posted transactions and equals the matching report.
            </Typography>
          </Box>
          <Grid container spacing={2}>
            {kpis.map((k) => (
              <Grid item xs={12} sm={6} md={4} key={k.label}>
                <Card
                  variant="outlined"
                  onClick={k.to ? () => navigate(k.to as string) : undefined}
                  sx={{ cursor: k.to ? 'pointer' : 'default', height: '100%' }}
                >
                  <CardContent>
                    <Typography variant="body2" color="text.secondary">
                      {k.label}
                    </Typography>
                    <Typography variant="h5" fontWeight={700} sx={{ whiteSpace: 'pre-line' }}>
                      {k.value}
                    </Typography>
                    {k.hint && (
                      <Typography variant="caption" color="text.secondary">
                        {k.hint}
                      </Typography>
                    )}
                  </CardContent>
                </Card>
              </Grid>
            ))}
          </Grid>
        </Stack>
      )}
    </Box>
  );
}
