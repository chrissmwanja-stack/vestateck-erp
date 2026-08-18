import { useCallback, useEffect, useState } from 'react';
import {
  Alert,
  Box,
  Button,
  Chip,
  CircularProgress,
  Link,
  Paper,
  Stack,
  Table,
  TableBody,
  TableCell,
  TableRow,
  TextField,
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

interface WorkflowStage {
  id: string;
  name: string;
  sequence_order: number;
  approver_role: string;
  threshold_amount: number | null;
  applies_to: string;
}

const appliesToLabel: Record<string, string> = {
  requests: 'Procurement requests',
  invoices: 'Invoices',
};

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
  const [stages, setStages] = useState<WorkflowStage[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  // Draft values keyed by stage id, separate from `stages` so in-progress
  // edits in one row don't get clobbered by a reload triggered by saving
  // another row.
  const [drafts, setDrafts] = useState<Record<string, string>>({});
  const [savingStageId, setSavingStageId] = useState<string | null>(null);
  const [saveError, setSaveError] = useState<string | null>(null);

  const load = useCallback(async () => {
    if (!tenantId) return;
    setLoading(true);
    setError(null);

    const [
      { data: tenantRow, error: tenantErr },
      { data: analyticsData, error: analyticsErr },
      { data: stagesData, error: stagesErr },
    ] = await Promise.all([
      supabase.from('tenants').select('id, name, status, created_at').eq('id', tenantId).maybeSingle(),
      supabase.rpc('get_company_analytics', { p_tenant_id: tenantId }),
      supabase.rpc('get_tenant_workflow_stages', { p_tenant_id: tenantId }),
    ]);

    if (tenantErr || analyticsErr || stagesErr) {
      setError(tenantErr?.message ?? analyticsErr?.message ?? stagesErr?.message ?? 'Failed to load company.');
      setLoading(false);
      return;
    }

    const stageRows = (stagesData as unknown as WorkflowStage[]) ?? [];
    setTenant(tenantRow as Tenant);
    setAnalytics(analyticsData as unknown as Analytics);
    setStages(stageRows);
    setDrafts(
      Object.fromEntries(
        stageRows
          .filter((s) => s.threshold_amount !== null)
          .map((s) => [s.id, String(s.threshold_amount)])
      )
    );
    setLoading(false);
  }, [tenantId]);

  const saveThreshold = useCallback(
    async (stageId: string) => {
      const raw = drafts[stageId];
      const parsed = Number(raw);
      if (raw === '' || Number.isNaN(parsed) || parsed < 0) {
        setSaveError('Threshold must be a non-negative number.');
        return;
      }

      setSavingStageId(stageId);
      setSaveError(null);

      const { error: rpcError } = await supabase.rpc('update_workflow_stage_threshold', {
        p_stage_id: stageId,
        p_threshold_amount: parsed,
      });

      if (rpcError) {
        setSaveError(rpcError.message);
        setSavingStageId(null);
        return;
      }

      setStages((prev) => prev.map((s) => (s.id === stageId ? { ...s, threshold_amount: parsed } : s)));
      setSavingStageId(null);
    },
    [drafts]
  );

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

      <Typography variant="subtitle1" sx={{ mt: 4, mb: 1 }}>
        Approval thresholds
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
        Amount (UGX) at which each branch point routes to the higher-authority path instead of
        the default one. New tenants are seeded at 5,000,000; edit per stage below.
      </Typography>

      {saveError && (
        <Alert severity="error" sx={{ mb: 2 }} onClose={() => setSaveError(null)}>
          {saveError}
        </Alert>
      )}

      {stages.filter((s) => s.threshold_amount !== null).length === 0 ? (
        <Typography variant="body2" color="text.secondary">
          No threshold branch points configured for this tenant.
        </Typography>
      ) : (
        <Stack direction="row" spacing={2} flexWrap="wrap" useFlexGap>
          {Object.entries(
            stages
              .filter((s) => s.threshold_amount !== null)
              .reduce<Record<string, WorkflowStage[]>>((acc, s) => {
                (acc[s.applies_to] ??= []).push(s);
                return acc;
              }, {})
          ).map(([appliesTo, group]) => (
            <Paper key={appliesTo} variant="outlined" sx={{ p: 2, flex: '1 1 320px' }}>
              <Typography variant="subtitle2" sx={{ mb: 1.5 }}>
                {appliesToLabel[appliesTo] ?? appliesTo}
              </Typography>
              <Stack spacing={1.5}>
                {group.map((stage) => (
                  <Stack key={stage.id} direction="row" spacing={1} alignItems="center">
                    <Box sx={{ flex: 1 }}>
                      <Typography variant="body2">{stage.name}</Typography>
                      <Typography variant="caption" color="text.secondary">
                        {stage.approver_role}
                      </Typography>
                    </Box>
                    <TextField
                      size="small"
                      type="number"
                      value={drafts[stage.id] ?? ''}
                      onChange={(e) => setDrafts((prev) => ({ ...prev, [stage.id]: e.target.value }))}
                      sx={{ width: 140 }}
                      inputProps={{ min: 0, step: '0.01' }}
                    />
                    <Button
                      size="small"
                      variant="outlined"
                      disabled={savingStageId === stage.id || drafts[stage.id] === String(stage.threshold_amount)}
                      onClick={() => saveThreshold(stage.id)}
                    >
                      {savingStageId === stage.id ? 'Saving…' : 'Save'}
                    </Button>
                  </Stack>
                ))}
              </Stack>
            </Paper>
          ))}
        </Stack>
      )}
    </Box>
  );
}