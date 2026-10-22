import { useEffect, useState } from 'react';
import { Alert, Box, Card, CardContent, CircularProgress, Grid, Stack, Typography } from '@mui/material';
import { useNavigate } from 'react-router-dom';
import { useMyModuleAccess } from '../../../../features/navigation/useMyModuleAccess';
import { allRows, rpc, table } from '../db';
import { remittanceFacts, type RemittanceRow } from '../remittance';
import { localIsoDate } from '../fx';
import { formatMoney, formatMoneyByCurrency, isClaimOpen, isInForce, renewalBucket, sumByCurrency } from '../logic';
import { dashboardAlerts, FINANCE_CASH_PATH, REGULATORY_RULES_PATH, REMITTANCE_REPORT_PATH, type DashboardAlert } from '../dashboardAlerts';
import type { Claim, Policy, RenewalRow } from '../types';

type ClaimRow = Pick<Claim, 'status' | 'reserve_amount'> & { ins_policies: { currency: string } | null };
import { PageHeader, ErrorBanner } from '../shared';
import { useRenewalNotificationSweep } from '../renewalNotificationSweep';

interface Kpi {
  label: string;
  /** One line per currency for money figures; counts are a single line. */
  value: string;
  hint?: string;
  to?: string;
}

// KPIs and alerts are computed from the RLS-scoped rows the user can already read.
// Money is totalled per currency and shown one currency per line: amounts in different
// currencies are never added together.
// There is no separate summary RPC yet; that is a roadmap item once volumes justify it.
export default function InsuranceDashboard() {
  const navigate = useNavigate();
  useRenewalNotificationSweep();
  // Premium cash requests are approved in the Finance workbench, which only Finance users can open.
  const canOpenFinanceCash = Boolean(useMyModuleAccess()?.canAccessFinance);
  const [kpis, setKpis] = useState<Kpi[] | null>(null);
  const [alerts, setAlerts] = useState<DashboardAlert[]>([]);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    (async () => {
      try {
        // allRows pages through every row: a plain select stops at the API row cap and would
        // understate every figure below once a company grows past it.
        const today = localIsoDate();
        const [policies, claims, renewals, pendingCash, commission, settings, remittance] = await Promise.all([
          allRows<Pick<Policy, 'status' | 'gross_premium' | 'commission_amount' | 'currency' | 'expiry_date'>>(
            () => table('ins_policies').select('status, gross_premium, commission_amount, currency, expiry_date').in('status', ['active', 'renewed']).order('id'),
          ),
          // A claim is in its policy's currency.
          allRows<ClaimRow>(() => table('ins_claims').select('status, reserve_amount, ins_policies(currency)').order('id')),
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
        const premium = sumByCurrency(inForce, (p) => p.currency, (p) => p.gross_premium, functional);
        const commissionInForce = sumByCurrency(inForce, (p) => p.currency, (p) => p.commission_amount, functional);
        const openClaims = claims.filter((c) => isClaimOpen(c.status));
        const reserves = sumByCurrency(openClaims, (c) => c.ins_policies?.currency, (c) => c.reserve_amount, functional);
        const toAssess = claims.filter((c) => c.status === 'notified' || c.status === 'assessing').length;
        const approvedUnsettled = claims.filter((c) => c.status === 'approved').length;
        const due30 = renewals.filter((r) => renewalBucket(r.days_to_expiry) === 'overdue' || renewalBucket(r.days_to_expiry) === 'd0_30').length;
        const overdue = renewals.filter((r) => renewalBucket(r.days_to_expiry) === 'overdue').length;
        const earnedNotTransferred = commission.reduce((s, c) => s + Number(c.earned_in_client_money ?? 0), 0);

        const held = remittance ? remittanceFacts(remittance) : null;

        setKpis([
          { label: 'Policies in force', value: String(inForce.length), to: '/insurance/policies' },
          { label: 'Gross premium in force', value: formatMoneyByCurrency(premium, functional), hint: 'Active policies, billed to clients' },
          { label: 'Commission in force', value: formatMoneyByCurrency(commissionInForce, functional), hint: 'Earned on bind, from insurers' },
          { label: 'Renewals due (120 days)', value: String(renewals.length), hint: `${due30} within 30 days or overdue`, to: '/insurance/renewals' },
          { label: 'Open claims', value: String(openClaims.length), to: '/insurance/claims' },
          { label: 'Open claim reserves', value: formatMoneyByCurrency(reserves, functional) },
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
