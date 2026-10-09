import { useEffect, useState } from 'react';
import { Box, Card, CardContent, CircularProgress, Grid, Typography } from '@mui/material';
import { useNavigate } from 'react-router-dom';
import { rows, table } from '../db';
import { formatMoney, isClaimOpen, renewalBucket } from '../logic';
import type { Claim, Policy, RenewalRow } from '../types';
import { PageHeader, ErrorBanner } from '../shared';

interface Kpi {
  label: string;
  value: string;
  hint?: string;
  to?: string;
}

// KPIs are computed from the RLS-scoped rows the user can already read. There is
// no separate summary RPC yet; that is a roadmap item once volumes justify it.
export default function InsuranceDashboard() {
  const navigate = useNavigate();
  const [kpis, setKpis] = useState<Kpi[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    (async () => {
      try {
        const [policies, claims, renewals] = await Promise.all([
          rows<Pick<Policy, 'status' | 'gross_premium' | 'commission_amount' | 'currency'>>(
            table('ins_policies').select('status, gross_premium, commission_amount, currency').in('status', ['active', 'renewed']),
          ),
          rows<Pick<Claim, 'status' | 'reserve_amount'>>(table('ins_claims').select('status, reserve_amount')),
          rows<RenewalRow>(table('ins_renewal_pipeline').select('*').order('expiry_date', { ascending: true })),
        ]);

        const inForce = policies.filter((p) => p.status === 'active');
        const premium = inForce.reduce((s, p) => s + Number(p.gross_premium), 0);
        const commission = inForce.reduce((s, p) => s + Number(p.commission_amount ?? 0), 0);
        const openClaims = claims.filter((c) => isClaimOpen(c.status));
        const reserves = openClaims.reduce((s, c) => s + Number(c.reserve_amount), 0);
        const due30 = renewals.filter((r) => renewalBucket(r.days_to_expiry) === 'overdue' || renewalBucket(r.days_to_expiry) === 'd0_30').length;

        setKpis([
          { label: 'Policies in force', value: String(inForce.length), to: '/insurance/policies' },
          { label: 'Gross premium in force', value: formatMoney(premium), hint: 'Active policies, billed to clients' },
          { label: 'Commission in force', value: formatMoney(commission), hint: 'Earned on bind, from insurers' },
          { label: 'Renewals due (120 days)', value: String(renewals.length), hint: `${due30} within 30 days or overdue`, to: '/insurance/renewals' },
          { label: 'Open claims', value: String(openClaims.length), to: '/insurance/claims' },
          { label: 'Open claim reserves', value: formatMoney(reserves) },
        ]);
      } catch (e) {
        setError(e instanceof Error ? e.message : 'Could not load the dashboard');
      }
    })();
  }, []);

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
      )}
    </Box>
  );
}
