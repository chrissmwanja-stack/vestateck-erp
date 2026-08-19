import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Alert,
  Box,
  Button,
  Card,
  CardContent,
  Chip,
  CircularProgress,
  Divider,
  Link,
  Paper,
  Stack,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  Typography,
  Tooltip,
  IconButton,
} from '@mui/material';
import {
  Business,
  People,
  ReceiptLong,
  AccountBalance,
  AddBusiness,
  Refresh,
  Visibility,
  Settings,
  TrendingUp,
  WarningAmber,
  CheckCircle,
  HourglassEmpty,
} from '@mui/icons-material';
import { Link as RouterLink, useNavigate } from 'react-router-dom';
import {
  ResponsiveContainer,
  AreaChart,
  Area,
  BarChart,
  Bar,
  PieChart,
  Pie,
  Cell,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip as ReTooltip,
  Legend,
} from 'recharts';
import { supabase } from '../../lib/supabaseClient';
import CompanyCreateWizard from './CompanyCreateWizard';

interface PlatformStats {
  totals: {
    total_companies: number;
    active_companies: number;
    pending_companies: number;
    suspended_companies: number;
    total_members: number;
    total_pos: number;
    total_po_value: number;
    total_requests: number;
    requests_30d: number;
    pending_requests: number;
    pending_invites: number;
  };
  by_status: { status: string; count: number }[];
  companies_by_month: { month: string; count: number }[];
  requests_by_month: { month: string; count: number }[];
  module_adoption: { module: string; count: number }[];
  recent_companies: { id: string; name: string; status: string; created_at: string }[];
  top_companies_by_requests: { name: string; count: number; tenant_id: string }[];
  pending_invites_list: { id: string; email: string; tenant_id: string; created_at: string }[];
}

const STATUS_COLOR: Record<string, string> = {
  active: '#1B5560',
  pending: '#E0B368',
  suspended: '#9AABAE',
};

const MODULE_LABEL: Record<string, string> = {
  hr: 'HR',
  legal: 'Law & Compliance',
  bd: 'Business Dev',
  it: 'IT Support',
  pmo: 'PMO',
  procurement: 'Purchasing+',
  machine_operation: 'Machine Ops',
  sustainability: 'Sustainability',
};

const PIE_COLORS = ['#123B44', '#C4872B', '#4C818B', '#8F5D14', '#DCE8EA', '#5B6C71', '#E0B368', '#0A2530'];

function KpiCard({ icon, label, value, sub, color }: { icon: React.ReactNode; label: string; value: string | number; sub?: string; color?: string }) {
  return (
    <Card variant="outlined" sx={{ flex: '1 1 180px', minWidth: 180, borderRadius: 2 }}>
      <CardContent sx={{ p: 2, '&:last-child': { pb: 2 } }}>
        <Stack direction="row" spacing={1.5} alignItems="center">
          <Box sx={{ width: 40, height: 40, borderRadius: 1.5, bgcolor: color ? `${color}15` : 'primary.main', color: color || 'primary.contrastText', display: 'grid', placeItems: 'center' }}>
            {icon}
          </Box>
          <Box>
            <Typography variant="caption" color="text.secondary" sx={{ textTransform: 'uppercase', letterSpacing: 0.6, fontSize: 11 }}>
              {label}
            </Typography>
            <Typography variant="h6" sx={{ lineHeight: 1.1 }}>{value}</Typography>
            {sub && <Typography variant="caption" color="text.secondary">{sub}</Typography>}
          </Box>
        </Stack>
      </CardContent>
    </Card>
  );
}

export default function PlatformDashboard() {
  const navigate = useNavigate();
  const [stats, setStats] = useState<PlatformStats | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [wizardOpen, setWizardOpen] = useState(false);
  const [impersonatingId, setImpersonatingId] = useState<string | null>(null);
  const [resendId, setResendId] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const { data, error: err } = await (supabase.rpc as any)('get_platform_dashboard_stats');
    if (err) {
      // Fallback: try the older RPC if this new one hasn't migrated yet
      const { data: fallback, error: fallbackErr } = await supabase.rpc('get_companies_overview');
      if (fallbackErr) {
        setError(err.message || fallbackErr.message);
        setLoading(false);
        return;
      }
      // Build a minimal stats shape from the fallback
      const rows = (fallback ?? []) as any[];
      const minimal: PlatformStats = {
        totals: {
          total_companies: rows.length,
          active_companies: rows.filter((r) => r.status === 'active').length,
          pending_companies: rows.filter((r) => r.status === 'pending').length,
          suspended_companies: rows.filter((r) => r.status === 'suspended').length,
          total_members: rows.reduce((s, r) => s + Number(r.member_count || 0), 0),
          total_pos: 0,
          total_po_value: 0,
          total_requests: rows.reduce((s, r) => s + Number(r.request_count_30d || 0), 0),
          requests_30d: rows.reduce((s, r) => s + Number(r.request_count_30d || 0), 0),
          pending_requests: rows.reduce((s, r) => s + Number(r.pending_request_count || 0), 0),
          pending_invites: 0,
        },
        by_status: [
          { status: 'active', count: rows.filter((r) => r.status === 'active').length },
          { status: 'pending', count: rows.filter((r) => r.status === 'pending').length },
          { status: 'suspended', count: rows.filter((r) => r.status === 'suspended').length },
        ].filter((r) => r.count > 0),
        companies_by_month: [],
        requests_by_month: [],
        module_adoption: [],
        recent_companies: rows.slice(0, 5).map((r) => ({ id: r.tenant_id, name: r.name, status: r.status, created_at: r.created_at })),
        top_companies_by_requests: [...rows].sort((a, b) => Number(b.request_count_30d) - Number(a.request_count_30d)).slice(0, 5).map((r) => ({ name: r.name, count: Number(r.request_count_30d), tenant_id: r.tenant_id })),
        pending_invites_list: [],
      };
      setStats(minimal);
      setError(`Live stats RPC not yet migrated — showing limited view. Apply migration 20260818140000: ${err.message}`);
      setLoading(false);
      return;
    }
    setStats(data as unknown as PlatformStats);
    setLoading(false);
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const handleViewAs = async (tenantId: string) => {
    setImpersonatingId(tenantId);
    const { data: _impData, error } = await (supabase.rpc as any)('start_impersonation', { p_tenant_id: tenantId });
    if (error) {
      alert(error.message);
      setImpersonatingId(null);
      return;
    }
    // After impersonation, tenant-scoped get_my_tenant_id() resolves to the target.
    // Navigate to that company's Purchasing dashboard to make the context obvious.
    navigate('/purchasing/dashboard');
    setImpersonatingId(null);
  };

  const handleResend = async (invite: { id: string }) => {
    setResendId(invite.id);
    const { error } = await supabase.functions.invoke('resend-invite', { body: { invitation_id: invite.id } });
    if (error) alert(error.message);
    else load();
    setResendId(null);
  };

  // Compose month timeline for charts (last 6 months, fill missing with 0)
  const monthlyTimeline = useMemo(() => {
    if (!stats) return [];
    const map = new Map<string, { month: string; companies: number; requests: number }>();
    stats.companies_by_month.forEach((r) => {
      const cur = map.get(r.month) || { month: r.month, companies: 0, requests: 0 };
      cur.companies = r.count;
      map.set(r.month, cur);
    });
    stats.requests_by_month.forEach((r) => {
      const cur = map.get(r.month) || { month: r.month, companies: 0, requests: 0 };
      cur.requests = r.count;
      map.set(r.month, cur);
    });
    return Array.from(map.values()).sort((a, b) => a.month.localeCompare(b.month));
  }, [stats]);

  if (loading) {
    return (
      <Box display="flex" justifyContent="center" py={6}>
        <CircularProgress />
      </Box>
    );
  }

  if (error && !stats) {
    return (
      <Box sx={{ maxWidth: 900 }}>
        <Alert severity="error" sx={{ mb: 2 }}>{error}</Alert>
        <Button onClick={load} startIcon={<Refresh />}>Retry</Button>
      </Box>
    );
  }

  const t = stats!.totals;

  return (
    <Box sx={{ maxWidth: 1280 }}>
      {/* DISTINCT HEADER — Harbor Slate, not the white company dashboards */}
      <Paper
        sx={{
          background: 'linear-gradient(135deg, #0A2530 0%, #123B44 55%, #1B5560 100%)',
          color: '#FFFFFF',
          borderRadius: 2,
          p: { xs: 2.5, md: 3 },
          mb: 3,
          position: 'relative',
          overflow: 'hidden',
          display: 'flex',
          flexWrap: 'wrap',
          gap: 2,
          alignItems: 'center',
          justifyContent: 'space-between',
        }}
      >
        <Box>
          <Stack direction="row" spacing={1.5} alignItems="center" sx={{ mb: 0.5 }}>
            <Box sx={{ width: 36, height: 36, borderRadius: 1.5, bgcolor: 'rgba(255,255,255,0.14)', display: 'grid', placeItems: 'center' }}>
              <Business sx={{ color: '#E0B368' }} />
            </Box>
            <Typography variant="overline" sx={{ color: '#E0B368', letterSpacing: 1.2, fontWeight: 700 }}>
              Platform Administration
            </Typography>
            <Chip label="Platform-only" size="small" sx={{ bgcolor: 'rgba(224,179,104,0.2)', color: '#F6E7CE', fontSize: 11, height: 20 }} />
          </Stack>
          <Typography variant="h5" sx={{ fontWeight: 700, color: '#FFFFFF' }}>
            VestaPortal — all companies
          </Typography>
          <Typography variant="body2" sx={{ color: 'rgba(255,255,255,0.75)', maxWidth: 560 }}>
            Company setup and network analytics. This view is distinct from any company's own dashboard — nothing here leaks a company's private procurement or finance data beyond the aggregates platform admins are gated to.
          </Typography>
        </Box>

        <Stack direction="row" spacing={1.5} alignItems="center" flexWrap="wrap">
          <Button
            variant="contained"
            startIcon={<AddBusiness />}
            onClick={() => setWizardOpen(true)}
            sx={{ bgcolor: '#E0B368', color: '#0A2530', '&:hover': { bgcolor: '#C4872B' }, fontWeight: 700 }}
          >
            New Company
          </Button>
          <Button component={RouterLink} to="/admin/companies" variant="outlined" sx={{ color: '#FFFFFF', borderColor: 'rgba(255,255,255,0.35)', '&:hover': { borderColor: '#FFFFFF', bgcolor: 'rgba(255,255,255,0.08)' } }}>
            All companies
          </Button>
          <Tooltip title="Refresh stats">
            <IconButton onClick={load} sx={{ color: '#FFFFFF', bgcolor: 'rgba(255,255,255,0.08)' }}>
              <Refresh fontSize="small" />
            </IconButton>
          </Tooltip>
        </Stack>

        {/* subtle arch mark */}
        <Box sx={{ position: 'absolute', right: -20, bottom: -30, opacity: 0.07, fontSize: 120, lineHeight: 1, pointerEvents: 'none' }}>◯</Box>
      </Paper>

      {error && <Alert severity="warning" sx={{ mb: 2 }}>{error}</Alert>}

      {/* KPI ROW */}
      <Box sx={{ display: 'grid', gridTemplateColumns: { xs: '1fr 1fr', md: 'repeat(4, 1fr)' }, gap: 1.5, mb: 2 }}>
        <KpiCard icon={<Business fontSize="small" />} label="Total Companies" value={t.total_companies} sub={`${t.active_companies} active · ${t.pending_companies} pending · ${t.suspended_companies} suspended`} color="#123B44" />
        <KpiCard icon={<People fontSize="small" />} label="Total Members" value={t.total_members.toLocaleString()} sub="Across all companies" color="#1B5560" />
        <KpiCard icon={<ReceiptLong fontSize="small" />} label="Requests (30d)" value={t.requests_30d.toLocaleString()} sub={`${t.pending_requests} still open`} color="#C4872B" />
        <KpiCard icon={<AccountBalance fontSize="small" />} label="PO Value (UGX)" value={t.total_po_value.toLocaleString(undefined, { maximumFractionDigits: 0 })} sub={`${t.total_pos} purchase orders`} color="#0A2530" />
      </Box>

      <Box sx={{ display: 'grid', gridTemplateColumns: { xs: '1fr 1fr', md: 'repeat(4, 1fr)' }, gap: 1.5, mb: 3 }}>
        <KpiCard icon={<HourglassEmpty fontSize="small" />} label="Pending Invites" value={t.pending_invites} sub="Company admin invites" />
        <KpiCard icon={<CheckCircle fontSize="small" />} label="Total Requests" value={t.total_requests.toLocaleString()} sub="All time" />
        <KpiCard icon={<WarningAmber fontSize="small" />} label="Suspended" value={t.suspended_companies} sub={t.suspended_companies > 0 ? 'Needs review' : 'All clear'} color={t.suspended_companies > 0 ? '#8F5D14' : undefined} />
        <KpiCard icon={<TrendingUp fontSize="small" />} label="Adoption" value={`${stats!.module_adoption.length ? Math.round(stats!.module_adoption.reduce((s, m) => s + m.count, 0) / Math.max(t.total_companies, 1)) : 0} mods avg`} sub="Avg modules / company" />
      </Box>

      {/* CHARTS */}
      <Box sx={{ display: 'grid', gridTemplateColumns: { xs: '1fr', lg: '2fr 1fr' }, gap: 2, mb: 3 }}>
        <Paper variant="outlined" sx={{ p: 2, borderRadius: 2 }}>
          <Stack direction="row" justifyContent="space-between" alignItems="center" sx={{ mb: 1 }}>
            <Typography variant="subtitle2">Growth — last 6 months</Typography>
            <Typography variant="caption" color="text.secondary">Companies created vs requests submitted</Typography>
          </Stack>
          <Box sx={{ height: 260 }}>
            {monthlyTimeline.length ? (
              <ResponsiveContainer width="100%" height="100%">
                <AreaChart data={monthlyTimeline}>
                  <CartesianGrid strokeDasharray="3 3" stroke="#E4E8E9" />
                  <XAxis dataKey="month" tick={{ fontSize: 11 }} />
                  <YAxis tick={{ fontSize: 11 }} allowDecimals={false} />
                  <ReTooltip />
                  <Legend />
                  <Area type="monotone" dataKey="companies" name="Companies" stroke="#123B44" fill="#DCE8EA" strokeWidth={2} />
                  <Area type="monotone" dataKey="requests" name="Requests" stroke="#C4872B" fill="#F6E7CE" strokeWidth={2} />
                </AreaChart>
              </ResponsiveContainer>
            ) : (
              <Box sx={{ height: '100%', display: 'grid', placeItems: 'center' }}><Typography variant="body2" color="text.secondary">Not enough history yet — comes alive after your first month of onboardings.</Typography></Box>
            )}
          </Box>
        </Paper>

        <Paper variant="outlined" sx={{ p: 2, borderRadius: 2 }}>
          <Typography variant="subtitle2" sx={{ mb: 1 }}>Status mix</Typography>
          <Box sx={{ height: 260 }}>
            <ResponsiveContainer width="100%" height="100%">
              <PieChart>
                <Pie
                  data={stats!.by_status}
                  dataKey="count"
                  nameKey="status"
                  cx="50%"
                  cy="50%"
                  outerRadius={86}
                  label={(props: any) => `${props.status}: ${props.count}`}
                >
                  {stats!.by_status.map((e, i) => (
                    <Cell key={e.status} fill={STATUS_COLOR[e.status] || PIE_COLORS[i % PIE_COLORS.length]} />
                  ))}
                </Pie>
                <ReTooltip />
              </PieChart>
            </ResponsiveContainer>
          </Box>
          <Stack direction="row" spacing={1} flexWrap="wrap" sx={{ mt: 1 }}>
            {stats!.by_status.map((s) => (
              <Chip key={s.status} size="small" label={`${s.status} · ${s.count}`} sx={{ bgcolor: STATUS_COLOR[s.status] || '#EEE', color: s.status === 'pending' ? '#0A2530' : '#FFFFFF' }} />
            ))}
          </Stack>
        </Paper>
      </Box>

      <Box sx={{ display: 'grid', gridTemplateColumns: { xs: '1fr', lg: '1.2fr 0.8fr' }, gap: 2, mb: 3 }}>
        <Paper variant="outlined" sx={{ p: 2, borderRadius: 2 }}>
          <Typography variant="subtitle2" sx={{ mb: 1 }}>Module adoption — companies per module</Typography>
          <Typography variant="caption" color="text.secondary" sx={{ mb: 1, display: 'block' }}>Finance + core Procurement are baseline (not shown) — this is the optional 8.</Typography>
          <Box sx={{ height: 260 }}>
            <ResponsiveContainer width="100%" height="100%">
              <BarChart data={stats!.module_adoption.map((m) => ({ module: MODULE_LABEL[m.module] || m.module, count: m.count }))} layout="vertical" margin={{ left: 24 }}>
                <CartesianGrid strokeDasharray="3 3" stroke="#E4E8E9" />
                <XAxis type="number" allowDecimals={false} tick={{ fontSize: 11 }} />
                <YAxis type="category" dataKey="module" width={110} tick={{ fontSize: 11 }} />
                <ReTooltip />
                <Bar dataKey="count" fill="#1B5560" radius={[0, 6, 6, 0]} name="Companies" />
              </BarChart>
            </ResponsiveContainer>
          </Box>
        </Paper>

        <Paper variant="outlined" sx={{ p: 2, borderRadius: 2 }}>
          <Typography variant="subtitle2" sx={{ mb: 1 }}>Top companies by request volume</Typography>
          <TableContainer>
            <Table size="small">
              <TableHead>
                <TableRow><TableCell>Company</TableCell><TableCell align="right">Requests</TableCell></TableRow>
              </TableHead>
              <TableBody>
                {stats!.top_companies_by_requests.length ? stats!.top_companies_by_requests.map((r) => (
                  <TableRow key={r.tenant_id} hover>
                    <TableCell><Link component={RouterLink} to={`/admin/companies/${r.tenant_id}`}>{r.name}</Link></TableCell>
                    <TableCell align="right">{r.count}</TableCell>
                  </TableRow>
                )) : (
                  <TableRow><TableCell colSpan={2} sx={{ color: 'text.secondary', textAlign: 'center', py: 3 }}>No requests yet.</TableCell></TableRow>
                )}
              </TableBody>
            </Table>
          </TableContainer>
          <Button component={RouterLink} to="/admin/companies" size="small" sx={{ mt: 1 }}>View all companies</Button>
        </Paper>
      </Box>

      {/* SETUP + OPS */}
      <Box sx={{ display: 'grid', gridTemplateColumns: { xs: '1fr', lg: '1fr 1fr' }, gap: 2, mb: 3 }}>
        <Paper variant="outlined" sx={{ p: 2, borderRadius: 2 }}>
          <Stack direction="row" justifyContent="space-between" alignItems="center" sx={{ mb: 1.5 }}>
            <Typography variant="subtitle2">Company setup</Typography>
            <Button startIcon={<AddBusiness />} variant="contained" onClick={() => setWizardOpen(true)}>New Company</Button>
          </Stack>
          <Typography variant="body2" color="text.secondary" sx={{ mb: 1.5 }}>
            Create a tenant, pick its industry template and modules, and invite its first admin. The pipeline (7 stages, 5M threshold) is identical for every company — this is not per-company customizable yet.
          </Typography>
          <Stack direction="row" spacing={1} flexWrap="wrap">
            <Button component={RouterLink} to="/admin/companies" startIcon={<Business />} variant="outlined" size="small">Companies</Button>
            <Button component={RouterLink} to="/team/invite" startIcon={<People />} variant="outlined" size="small">Invite team</Button>
            <Button component={RouterLink} to="/setup" startIcon={<Settings />} variant="outlined" size="small">Setup checklist</Button>
          </Stack>
          <Divider sx={{ my: 2 }} />
          <Alert severity="info">
            Tip: after creating a company, use <b>View as</b> on its row to impersonate its workspace and verify modules landed correctly.
          </Alert>
        </Paper>

        <Paper variant="outlined" sx={{ p: 2, borderRadius: 2 }}>
          <Stack direction="row" justifyContent="space-between" alignItems="center" sx={{ mb: 1 }}>
            <Typography variant="subtitle2">Recent companies</Typography>
            <Button size="small" component={RouterLink} to="/admin/companies">View all</Button>
          </Stack>
          <TableContainer>
            <Table size="small">
              <TableHead><TableRow><TableCell>Company</TableCell><TableCell>Status</TableCell><TableCell>Onboarded</TableCell><TableCell align="right"></TableCell></TableRow></TableHead>
              <TableBody>
                {stats!.recent_companies.map((c) => (
                  <TableRow key={c.id} hover>
                    <TableCell>{c.name}</TableCell>
                    <TableCell><Chip size="small" label={c.status} color={c.status === 'active' ? 'success' : c.status === 'pending' ? 'warning' : 'default'} /></TableCell>
                    <TableCell>{new Date(c.created_at).toLocaleDateString()}</TableCell>
                    <TableCell align="right">
                      <Stack direction="row" spacing={0.5} justifyContent="flex-end">
                        <Tooltip title="View analytics"><IconButton size="small" component={RouterLink} to={`/admin/companies/${c.id}`}><Visibility fontSize="small" /></IconButton></Tooltip>
                        <Tooltip title="View as this company (impersonate)"><span><IconButton size="small" onClick={() => handleViewAs(c.id)} disabled={!!impersonatingId}><People fontSize="small" /></IconButton></span></Tooltip>
                      </Stack>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </TableContainer>
          <Divider sx={{ my: 1.5 }} />
          <Typography variant="caption" color="text.secondary">
            Need a deeper drill-down? Every row links to its per-company analytics (requests by status/month, PO value, members by department, top requesters).
          </Typography>
        </Paper>
      </Box>

      {/* PENDING INVITES */}
      <Paper variant="outlined" sx={{ p: 2, borderRadius: 2, mb: 2 }}>
        <Stack direction="row" justifyContent="space-between" alignItems="center" sx={{ mb: 1 }}>
          <Typography variant="subtitle2">Pending first-admin invites</Typography>
          <Chip size="small" label={`${t.pending_invites} pending`} color={t.pending_invites ? 'warning' : 'default'} />
        </Stack>
        {stats!.pending_invites_list.length ? (
          <TableContainer>
            <Table size="small">
              <TableHead><TableRow><TableCell>Email</TableCell><TableCell>Company</TableCell><TableCell>Sent</TableCell><TableCell align="right">Action</TableCell></TableRow></TableHead>
              <TableBody>
                {stats!.pending_invites_list.map((inv) => {
                  const tenantName = stats!.recent_companies.find((c) => c.id === inv.tenant_id)?.name || inv.tenant_id.slice(0, 8);
                  return (
                    <TableRow key={inv.id} hover>
                      <TableCell>{inv.email}</TableCell>
                      <TableCell>{tenantName}</TableCell>
                      <TableCell>{new Date(inv.created_at).toLocaleDateString()}</TableCell>
                      <TableCell align="right"><Button size="small" onClick={() => handleResend(inv)} disabled={resendId === inv.id}>{resendId === inv.id ? 'Sending…' : 'Resend'}</Button></TableCell>
                    </TableRow>
                  );
                })}
              </TableBody>
            </Table>
          </TableContainer>
        ) : (
          <Typography variant="body2" color="text.secondary">No pending first-admin invites — all onboarded companies have accepted.</Typography>
        )}
      </Paper>

      <CompanyCreateWizard open={wizardOpen} onClose={() => setWizardOpen(false)} onCreated={load} />
    </Box>
  );
}