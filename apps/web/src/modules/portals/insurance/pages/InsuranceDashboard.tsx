import { useEffect, useState } from 'react';
import { Alert, Box, Card, CardContent, CircularProgress, Grid, Stack, Typography } from '@mui/material';
import { useNavigate } from 'react-router-dom';
import { useMyModuleAccess } from '../../../../features/navigation/useMyModuleAccess';
import { allRows, table } from '../db';
import { localIsoDate } from '../fx';
import { formatMoney, isClaimOpen, isInForce, renewalBucket } from '../logic';
import { dashboardAlerts, FINANCE_CASH_PATH, type DashboardAlert } from '../dashboardAlerts';
import type { Claim, Policy, RenewalRow } from '../types';
import { PageHeader, ErrorBanner } from '../shared';

interface Kpi {
  label: string;
  value: string;
  hint?: string;
  to?: string;
}

// KPIs and alerts are computed from the RLS-scoped rows the user can already read.
// There is no separate summary RPC yet; that is a roadmap item once volumes justify it.
export default function InsuranceDashboard() {
  const navigate = useNavigate();
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
        const [policies, claims, renewals, pendingCash, commission] = await Promise.all([
          allRows<Pick<Policy, 'status' | 'gross_premium' | 'commission_amount' | 'currency' | 'expiry_date'>>(
            () => table('ins_policies').select('status, gross_premium, commission_amount, currency, expiry_date').in('status', ['active', 'renewed']).order('id'),
          ),
          allRows<Pick<Claim, 'status' | 'reserve_amount'>>(() => table('ins_claims').select('status, reserve_amount').order('id')),
          allRows<RenewalRow>(() => table('ins_renewal_pipeline').select('*').order('expiry_date', { ascending: true }).order('policy_id')),
          allRows<{ id: string }>(() => table('ins_policy_cash_requests').select('id').eq('status', 'pending').order('id')),
          allRows<{ earned_in_client_money: number | string | null }>(
            () => table('ins_commission_position').select('earned_in_client_money').order('tenant_id'),
          ),
        ]);

        const today = localIsoDate();
        // Active policies past their expiry date stay 'active' until renewed, so they are
        // counted under renewals (overdue) and not as cover in force.
        const inForce = policies.filter((p) => isInForce(p, today));
        const premium = inForce.reduce((s, p) => s + Number(p.gross_premium), 0);
        const commissionInForce = inForce.reduce((s, p) => s + Number(p.commission_amount ?? 0), 0);
        const openClaims = claims.filter((c) => isClaimOpen(c.status));
        const reserves = openClaims.reduce((s, c) => s + Number(c.reserve_amount), 0);
        const toAssess = claims.filter((c) => c.status === 'notified' || c.status === 'assessing').length;
        const approvedUnsettled = claims.filter((c) => c.status === 'approved').length;
        const due30 = renewals.filter((r) => renewalBucket(r.days_to_expiry) === 'overdue' || renewalBucket(r.days_to_expiry) === 'd0_30').length;
        const overdue = renewals.filter((r) => renewalBucket(r.days_to_expiry) === 'overdue').length;
        const earnedNotTransferred = commission.reduce((s, c) => s + Number(c.earned_in_client_money ?? 0), 0);

        setKpis([
          { label: 'Policies in force', value: String(inForce.length), to: '/insurance/policies' },
          { label: 'Gross premium in force', value: formatMoney(premium), hint: 'Active policies, billed to clients' },
          { label: 'Commission in force', value: formatMoney(commissionInForce), hint: 'Earned on bind, from insurers' },
          { label: 'Renewals due (120 days)', value: String(renewals.length), hint: `${due30} within 30 days or overdue`, to: '/insurance/renewals' },
          { label: 'Open claims', value: String(openClaims.length), to: '/insurance/claims' },
          { label: 'Open claim reserves', value: formatMoney(reserves) },
          { label: 'Premium cash awaiting approval', value: String(pendingCash.length), to: canOpenFinanceCash ? FINANCE_CASH_PATH : '/insurance/policies' },
          { label: 'Commission earned, not transferred', value: formatMoney(earnedNotTransferred), hint: 'In client money, awaiting transfer', to: '/insurance/commission' },
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
          }),
        );
      } catch (e) {
        setError(e instanceof Error ? e.message : 'Could not load the dashboard');
      }
    })();
  }, [canOpenFinanceCash]);

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <PageHeader title="Insurance Brokerage" subtitle="Premiums and commission are in UGX unless a policy says otherwise." />
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
                    <Typography variant="h5" fontWeight={700}>
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
