import { useCallback, useEffect, useState } from 'react';
import {
  Alert,
  Box,
  Chip,
  CircularProgress,
  Link,
  Paper,
  Stack,
  Table,
  TableBody,
  TableCell,
  TableRow,
  Typography,
} from '@mui/material';
import { ArrowBack as ArrowBackIcon } from '@mui/icons-material';
import { Link as RouterLink, useParams } from 'react-router-dom';
import { supabase } from '../../lib/supabaseClient';

// Single-tenant drill-down for the Companies Console. Pulls everything
// from get_company_analytics() (one jsonb blob, one round trip) rather
// than several separate queries -- keeps this screen to a single
// platform-admin-gated RPC call instead of new per-table RLS carve-outs.
//
// No charting library in this app yet, so the bar visuals here are
// plain CSS width bars rather than reaching for a new dependency for
// what's currently five small breakdowns.

interface Tenant {
  id: string;
  name: string;
  status: string;
  created_at: string;
}

interface CountRow {
  count: number;
  [key: string]: string | number;
}

interface Analytics {
  requests_by_status: CountRow[];
  requests_by_month: CountRow[];
  purchase_orders: { count: number; total_value: number };
  members_by_department: CountRow[];
  top_requesters: CountRow[];
}

const tenantStatusColor: Record<string, 'default' | 'success' | 'warning'> = {
  pending: 'warning',
  active: 'success',
  suspended: 'default',
};

function BarList({
  rows,
  labelKey,
  emptyLabel,
}: {
  rows: CountRow[];
  labelKey: string;
  emptyLabel: string;
}) {
  if (rows.length === 0) {
    return (
      <Typography variant="body2" color="text.secondary">
        {emptyLabel}
      </Typography>
    );
  }
  const max = Math.max(...rows.map((r) => r.count), 1);
  return (
    <Stack spacing={1}>
      {rows.map((r) => (
        <Box key={String(r[labelKey])}>
          <Stack direction="row" justifyContent="space-between">
            <Typography variant="body2">{String(r[labelKey])}</Typography>
            <Typography variant="body2" color="text.secondary">
              {r.count}
            </Typography>
          </Stack>
          <Box sx={{ bgcolor: 'action.hover', borderRadius: 1, height: 6, mt: 0.5 }}>
            <Box
              sx={{
                bgcolor: 'primary.main',
                borderRadius: 1,
                height: 6,
                width: `${(r.count / max) * 100}%`,
              }}
            />
          </Box>
        </Box>
      ))}
    </Stack>
  );
}

export default function CompanyDetail() {
  const { tenantId } = useParams<{ tenantId: string }>();
  const [tenant, setTenant] = useState<Tenant | null>(null);
  const [analytics, setAnalytics] = useState<Analytics | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    if (!tenantId) return;
    setLoading(true);
    setError(null);

    const [{ data: tenantRow, error: tenantErr }, { data: analyticsData, error: analyticsErr }] =
      await Promise.all([
        supabase.from('tenants').select('id, name, status, created_at').eq('id', tenantId).maybeSingle(),
        supabase.rpc('get_company_analytics', { p_tenant_id: tenantId }),
      ]);

    if (tenantErr || analyticsErr) {
      setError(tenantErr?.message ?? analyticsErr?.message ?? 'Failed to load company.');
      setLoading(false);
      return;
    }

    setTenant(tenantRow as Tenant);
    setAnalytics(analyticsData as unknown as Analytics);
    setLoading(false);
  }, [tenantId]);

  useEffect(() => {
    load();
  }, [load]);

  if (loading) {
    return (
      <Box display="flex" justifyContent="center" py={6}>
        <CircularProgress />
      </Box>
    );
  }

  if (error || !tenant || !analytics) {
    return (
      <Box sx={{ maxWidth: 900 }}>
        <Link component={RouterLink} to="/admin/companies" sx={{ display: 'inline-flex', alignItems: 'center', mb: 2 }}>
          <ArrowBackIcon fontSize="small" sx={{ mr: 0.5 }} /> Back to Companies
        </Link>
        <Alert severity="error">{error ?? 'Company not found.'}</Alert>
      </Box>
    );
  }

  return (
    <Box sx={{ maxWidth: 900 }}>
      <Link component={RouterLink} to="/admin/companies" sx={{ display: 'inline-flex', alignItems: 'center', mb: 2 }}>
        <ArrowBackIcon fontSize="small" sx={{ mr: 0.5 }} /> Back to Companies
      </Link>

      <Stack direction="row" alignItems="center" spacing={2} sx={{ mb: 1 }}>
        <Typography variant="h5">{tenant.name}</Typography>
        <Chip size="small" label={tenant.status} color={tenantStatusColor[tenant.status] ?? 'default'} />
      </Stack>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        Onboarded {new Date(tenant.created_at).toLocaleDateString()}
      </Typography>

      <Stack direction="row" spacing={2} flexWrap="wrap" sx={{ mb: 3 }}>
        <Paper variant="outlined" sx={{ px: 2, py: 1, minWidth: 160 }}>
          <Typography variant="h6">{analytics.purchase_orders.count}</Typography>
          <Typography variant="caption" color="text.secondary">
            Purchase orders
          </Typography>
        </Paper>
        <Paper variant="outlined" sx={{ px: 2, py: 1, minWidth: 200 }}>
          <Typography variant="h6">
            {analytics.purchase_orders.total_value.toLocaleString(undefined, {
              maximumFractionDigits: 0,
            })}
          </Typography>
          <Typography variant="caption" color="text.secondary">
            Total PO value (UGX)
          </Typography>
        </Paper>
      </Stack>

      <Stack direction="row" spacing={2} flexWrap="wrap" useFlexGap>
        <Paper variant="outlined" sx={{ p: 2, flex: '1 1 260px' }}>
          <Typography variant="subtitle2" sx={{ mb: 1.5 }}>
            Requests by status
          </Typography>
          <BarList rows={analytics.requests_by_status} labelKey="status" emptyLabel="No requests yet." />
        </Paper>

        <Paper variant="outlined" sx={{ p: 2, flex: '1 1 260px' }}>
          <Typography variant="subtitle2" sx={{ mb: 1.5 }}>
            Requests, last 6 months
          </Typography>
          <BarList rows={analytics.requests_by_month} labelKey="month" emptyLabel="No requests in this window." />
        </Paper>

        <Paper variant="outlined" sx={{ p: 2, flex: '1 1 260px' }}>
          <Typography variant="subtitle2" sx={{ mb: 1.5 }}>
            Members by department
          </Typography>
          <BarList
            rows={analytics.members_by_department}
            labelKey="department"
            emptyLabel="No members yet."
          />
        </Paper>

        <Paper variant="outlined" sx={{ p: 2, flex: '1 1 260px' }}>
          <Typography variant="subtitle2" sx={{ mb: 1.5 }}>
            Top requesters
          </Typography>
          {analytics.top_requesters.length === 0 ? (
            <Typography variant="body2" color="text.secondary">
              No requests yet.
            </Typography>
          ) : (
            <Table size="small">
              <TableBody>
                {analytics.top_requesters.map((r) => (
                  <TableRow key={String(r.name)}>
                    <TableCell>{String(r.name)}</TableCell>
                    <TableCell align="right">{r.count}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </Paper>
      </Stack>
    </Box>
  );
}