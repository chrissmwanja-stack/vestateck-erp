import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Alert,
  Box,
  Button,
  Chip,
  CircularProgress,
  Dialog,
  DialogActions,
  DialogContent,
  DialogContentText,
  DialogTitle,
  Divider,
  FormControl,
  InputLabel,
  Link,
  MenuItem,
  Paper,
  Select,
  Stack,
  Tab,
  Table,
  TableBody,
  TableCell,
  TableRow,
  Tabs,
  TextField,
  Tooltip,
  Typography,
} from '@mui/material';
import { Link as RouterLink, useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { supabase } from '../../lib/supabaseClient';
import type { Json } from '@erp-platform/shared';
import ImpersonationReasonDialog from './ImpersonationReasonDialog';
import { describeBlockedReason, friendlyPlatformError, usePlatformAdminSession } from './usePlatformAdminSession';

// Single-company drill-down for the platform operator. One
// platform-admin-gated RPC (get_tenant_profile) supplies the summary tab;
// get_company_analytics / get_tenant_workflow_stages feed the other two.
//
// Tabs:
//   Summary   -- customer profile (contact, TIN, plan, seats, trial),
//                lifecycle controls (suspend / read-only / View as), last
//                status event and recent audit entries.
//   Activity  -- the request/PO/department breakdowns that used to be the
//                whole page.
//   Approvals -- workflow threshold editor (unchanged).
//   Notes     -- operator-only timeline (tenant_notes); customers never see it.

interface TenantRow {
  id: string;
  name: string;
  status: 'pending' | 'active' | 'suspended';
  created_at: string;
  industry_template: string;
  contact_name: string | null;
  contact_email: string | null;
  contact_phone: string | null;
  tax_id: string | null;
  address: string | null;
  country: string;
  plan: string;
  subscription_status: string;
  seat_limit: number | null;
  trial_ends_at: string | null;
  renews_at: string | null;
  status_changed_at: string | null;
  read_only: boolean;
  read_only_reason: string | null;
  read_only_since: string | null;
  updated_at: string;
}

interface Profile {
  tenant: TenantRow;
  seats: { limit: number | null; members: number; pending_invites: number };
  activity: {
    modules: number;
    requests_30d: number;
    last_request_at: string | null;
    last_sign_in_at: string | null;
    company_admins: { name: string; email: string }[];
  };
  last_status_event: { action: string; reason: string | null; created_at: string; actor_email: string | null } | null;
  recent_events: {
    id: string;
    action: string;
    reason: string | null;
    created_at: string;
    actor_email: string | null;
    mfa_verified: boolean;
  }[];
  notes_count: number;
}

interface Note {
  id: string;
  body: string;
  author_email: string | null;
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

export const PLAN_OPTIONS = [
  { value: 'trial', label: 'Trial' },
  { value: 'starter', label: 'Starter' },
  { value: 'standard', label: 'Standard' },
  { value: 'enterprise', label: 'Enterprise' },
  { value: 'internal', label: 'Internal (platform)' },
];

export const SUBSCRIPTION_OPTIONS = [
  { value: 'trialing', label: 'Trialing' },
  { value: 'active', label: 'Active (paid)' },
  { value: 'past_due', label: 'Past due' },
  { value: 'cancelled', label: 'Cancelled' },
];

const subscriptionColor: Record<string, 'default' | 'success' | 'warning' | 'error' | 'info'> = {
  trialing: 'info',
  active: 'success',
  past_due: 'warning',
  cancelled: 'error',
};

const ACTION_LABEL: Record<string, string> = {
  'tenant.suspend': 'Suspended',
  'tenant.activate': 'Reactivated',
  'tenant.read_only.on': 'Read-only enabled',
  'tenant.read_only.off': 'Read-only lifted',
  'tenant.profile.update': 'Profile edited',
  'tenant.modules.set': 'Modules changed',
  'impersonation.start': 'View-as started',
  'impersonation.end': 'View-as ended',
  'workflow.threshold.update': 'Threshold edited',
  'invitation.revoke': 'Invite revoked',
};

export function actionLabel(action: string): string {
  return ACTION_LABEL[action] ?? action;
}

// Days until a timestamp; negative when past. Exported for tests.
export function daysUntil(iso: string | null, now: Date = new Date()): number | null {
  if (!iso) return null;
  return Math.ceil((new Date(iso).getTime() - now.getTime()) / 86_400_000);
}

function fmtDate(iso: string | null | undefined): string {
  return iso ? new Date(iso).toLocaleDateString() : '—';
}

function fmtDateTime(iso: string | null | undefined): string {
  return iso ? new Date(iso).toLocaleString() : '—';
}

// <input type="date"> wants yyyy-mm-dd in local time.
function toDateInput(iso: string | null): string {
  if (!iso) return '';
  const d = new Date(iso);
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

function BarList({ rows, labelKey, emptyLabel }: { rows: CountRow[]; labelKey: string; emptyLabel: string }) {
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
            <Box sx={{ bgcolor: 'primary.main', borderRadius: 1, height: 6, width: `${(r.count / max) * 100}%` }} />
          </Box>
        </Box>
      ))}
    </Stack>
  );
}

function Stat({ label, value, hint }: { label: string; value: string | number; hint?: string }) {
  return (
    <Paper variant="outlined" sx={{ px: 2, py: 1, minWidth: 150, flex: '1 1 150px' }}>
      <Typography variant="h6">{value}</Typography>
      <Typography variant="caption" color="text.secondary">
        {label}
      </Typography>
      {hint && (
        <Typography variant="caption" color="text.secondary" display="block">
          {hint}
        </Typography>
      )}
    </Paper>
  );
}

type ProfileDraft = {
  name: string;
  contact_name: string;
  contact_email: string;
  contact_phone: string;
  tax_id: string;
  address: string;
  country: string;
  plan: string;
  subscription_status: string;
  seat_limit: string;
  trial_ends_at: string;
  renews_at: string;
};

function draftFrom(t: TenantRow): ProfileDraft {
  return {
    name: t.name,
    contact_name: t.contact_name ?? '',
    contact_email: t.contact_email ?? '',
    contact_phone: t.contact_phone ?? '',
    tax_id: t.tax_id ?? '',
    address: t.address ?? '',
    country: t.country ?? 'UG',
    plan: t.plan,
    subscription_status: t.subscription_status,
    seat_limit: t.seat_limit == null ? '' : String(t.seat_limit),
    trial_ends_at: toDateInput(t.trial_ends_at),
    renews_at: toDateInput(t.renews_at),
  };
}

// Build the minimal jsonb patch: only keys whose value differs from the
// saved row, so the audit diff stays honest. Exported for tests.
export function buildProfilePatch(saved: TenantRow, draft: ProfileDraft): Record<string, Json> {
  const base = draftFrom(saved);
  const patch: Record<string, Json> = {};
  (Object.keys(draft) as (keyof ProfileDraft)[]).forEach((k) => {
    if (draft[k] === base[k]) return;
    const v = draft[k].trim();
    if (k === 'seat_limit') {
      patch[k] = v === '' ? null : Number(v);
    } else if (k === 'trial_ends_at' || k === 'renews_at') {
      // Date-only input -> end of that local day, so "ends 30 Sep" means
      // the customer keeps access through the 30th.
      patch[k] = v === '' ? null : new Date(`${v}T23:59:59`).toISOString();
    } else {
      patch[k] = v === '' ? null : v;
    }
  });
  return patch;
}

export default function CompanyDetail() {
  const { tenantId } = useParams<{ tenantId: string }>();
  const navigate = useNavigate();
  const [searchParams, setSearchParams] = useSearchParams();
  const tab = searchParams.get('tab') ?? 'summary';
  const setTab = (next: string) => setSearchParams(next === 'summary' ? {} : { tab: next }, { replace: true });

  const { session: adminSession } = usePlatformAdminSession();
  const blockedReason = describeBlockedReason(adminSession);

  const [profile, setProfile] = useState<Profile | null>(null);
  const [analytics, setAnalytics] = useState<Analytics | null>(null);
  const [stages, setStages] = useState<WorkflowStage[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);

  // Profile editing
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState<ProfileDraft | null>(null);
  const [savingProfile, setSavingProfile] = useState(false);

  // Lifecycle dialogs
  const [statusDialog, setStatusDialog] = useState<'active' | 'suspended' | null>(null);
  const [readOnlyDialog, setReadOnlyDialog] = useState<boolean | null>(null); // next value
  const [reason, setReason] = useState('');
  const [dialogSaving, setDialogSaving] = useState(false);
  const [impersonateOpen, setImpersonateOpen] = useState(false);

  // Notes
  const [notes, setNotes] = useState<Note[] | null>(null);
  const [noteDraft, setNoteDraft] = useState('');
  const [noteSaving, setNoteSaving] = useState(false);

  // Threshold drafts keyed by stage id.
  const [drafts, setDrafts] = useState<Record<string, string>>({});
  const [savingStageId, setSavingStageId] = useState<string | null>(null);
  const [saveError, setSaveError] = useState<string | null>(null);

  const loadProfile = useCallback(async () => {
    if (!tenantId) return null;
    const { data, error: err } = await supabase.rpc('get_tenant_profile', { p_tenant_id: tenantId });
    if (err) throw new Error(friendlyPlatformError(err.message));
    return data as unknown as Profile | null;
  }, [tenantId]);

  const load = useCallback(async () => {
    if (!tenantId) return;
    setLoading(true);
    setError(null);
    try {
      const [p, { data: analyticsData, error: analyticsErr }, { data: stagesData, error: stagesErr }] =
        await Promise.all([
          loadProfile(),
          supabase.rpc('get_company_analytics', { p_tenant_id: tenantId }),
          supabase.rpc('get_tenant_workflow_stages', { p_tenant_id: tenantId }),
        ]);
      if (analyticsErr || stagesErr) {
        throw new Error(analyticsErr?.message ?? stagesErr?.message ?? 'Failed to load company.');
      }
      if (!p) {
        setError('Company not found.');
        setLoading(false);
        return;
      }
      const stageRows = (stagesData as unknown as WorkflowStage[]) ?? [];
      setProfile(p);
      setDraft(draftFrom(p.tenant));
      setAnalytics(analyticsData as unknown as Analytics);
      setStages(stageRows);
      setDrafts(
        Object.fromEntries(
          stageRows.filter((s) => s.threshold_amount !== null).map((s) => [s.id, String(s.threshold_amount)])
        )
      );
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed to load company.');
    }
    setLoading(false);
  }, [tenantId, loadProfile]);

  const refreshProfile = useCallback(async () => {
    try {
      const p = await loadProfile();
      if (p) {
        setProfile(p);
        setDraft(draftFrom(p.tenant));
      }
    } catch (e) {
      setActionError(e instanceof Error ? e.message : 'Failed to refresh.');
    }
  }, [loadProfile]);

  const loadNotes = useCallback(async () => {
    if (!tenantId) return;
    const { data, error: err } = await supabase
      .from('tenant_notes')
      .select('id, body, author_email, created_at')
      .eq('tenant_id', tenantId)
      .order('created_at', { ascending: false })
      .limit(200);
    if (err) {
      setActionError(err.message);
      return;
    }
    setNotes((data as Note[]) ?? []);
  }, [tenantId]);

  useEffect(() => {
    load();
  }, [load]);

  useEffect(() => {
    if (tab === 'notes' && notes === null) loadNotes();
  }, [tab, notes, loadNotes]);

  const patch = useMemo(
    () => (profile && draft ? buildProfilePatch(profile.tenant, draft) : {}),
    [profile, draft]
  );
  const dirty = Object.keys(patch).length > 0;

  const saveProfile = async () => {
    if (!tenantId || !dirty) return;
    setSavingProfile(true);
    setActionError(null);
    const { error: err } = await supabase.rpc('update_tenant_profile', { p_tenant_id: tenantId, p_patch: patch });
    setSavingProfile(false);
    if (err) {
      setActionError(friendlyPlatformError(err.message));
      return;
    }
    setNotice('Profile saved.');
    setEditing(false);
    await refreshProfile();
  };

  const confirmStatus = async () => {
    if (!tenantId || !statusDialog) return;
    setDialogSaving(true);
    setActionError(null);
    const { error: err } = await supabase.rpc('set_tenant_status', {
      p_tenant_id: tenantId,
      p_status: statusDialog,
      p_reason: reason.trim() || null,
    });
    setDialogSaving(false);
    if (err) {
      setActionError(friendlyPlatformError(err.message));
      return;
    }
    setNotice(statusDialog === 'suspended' ? 'Company suspended.' : 'Company reactivated.');
    setStatusDialog(null);
    setReason('');
    await refreshProfile();
  };

  const confirmReadOnly = async () => {
    if (!tenantId || readOnlyDialog === null) return;
    setDialogSaving(true);
    setActionError(null);
    const { error: err } = await supabase.rpc('set_tenant_read_only', {
      p_tenant_id: tenantId,
      p_read_only: readOnlyDialog,
      p_reason: reason.trim() || null,
    });
    setDialogSaving(false);
    if (err) {
      setActionError(friendlyPlatformError(err.message));
      return;
    }
    setNotice(readOnlyDialog ? 'Company is now read-only.' : 'Read-only mode lifted.');
    setReadOnlyDialog(null);
    setReason('');
    await refreshProfile();
  };

  const addNote = async () => {
    if (!tenantId || noteDraft.trim().length === 0) return;
    setNoteSaving(true);
    setActionError(null);
    const { error: err } = await supabase.rpc('add_tenant_note', { p_tenant_id: tenantId, p_body: noteDraft.trim() });
    setNoteSaving(false);
    if (err) {
      setActionError(friendlyPlatformError(err.message));
      return;
    }
    setNoteDraft('');
    await loadNotes();
    setProfile((p) => (p ? { ...p, notes_count: p.notes_count + 1 } : p));
  };

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
        setSaveError(friendlyPlatformError(rpcError.message));
        setSavingStageId(null);
        return;
      }
      setStages((prev) => prev.map((s) => (s.id === stageId ? { ...s, threshold_amount: parsed } : s)));
      setSavingStageId(null);
    },
    [drafts]
  );

  if (loading) {
    return (
      <Box display="flex" justifyContent="center" py={6}>
        <CircularProgress />
      </Box>
    );
  }

  if (error || !profile || !analytics || !draft) {
    return (
      <Box sx={{ maxWidth: 900 }}>
        <Alert severity="error">{error ?? 'Company not found.'}</Alert>
      </Box>
    );
  }

  const t = profile.tenant;
  const trialDays = daysUntil(t.trial_ends_at);
  const seatsUsed = profile.seats.members + profile.seats.pending_invites;
  const seatsFull = t.seat_limit != null && seatsUsed >= t.seat_limit;

  return (
    <Box sx={{ maxWidth: 1000 }}>
      <Stack direction={{ xs: 'column', sm: 'row' }} alignItems={{ sm: 'center' }} spacing={2} sx={{ mb: 0.5 }}>
        <Typography variant="h5" sx={{ flex: 1 }}>
          {t.name}
        </Typography>
        <Stack direction="row" spacing={1} flexWrap="wrap" useFlexGap>
          <Chip size="small" label={t.status} color={tenantStatusColor[t.status] ?? 'default'} />
          {t.read_only && <Chip size="small" label="read-only" color="warning" variant="outlined" />}
          <Chip size="small" label={PLAN_OPTIONS.find((p) => p.value === t.plan)?.label ?? t.plan} variant="outlined" />
          <Chip
            size="small"
            label={SUBSCRIPTION_OPTIONS.find((s) => s.value === t.subscription_status)?.label ?? t.subscription_status}
            color={subscriptionColor[t.subscription_status] ?? 'default'}
            variant="outlined"
          />
        </Stack>
      </Stack>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
        Onboarded {fmtDate(t.created_at)} · {t.industry_template} template
        {t.status_changed_at && ` · status changed ${fmtDate(t.status_changed_at)}`}
      </Typography>

      {notice && (
        <Alert severity="success" sx={{ mb: 2 }} onClose={() => setNotice(null)}>
          {notice}
        </Alert>
      )}
      {actionError && (
        <Alert severity="error" sx={{ mb: 2 }} onClose={() => setActionError(null)}>
          {actionError}
        </Alert>
      )}
      {t.read_only && (
        <Alert severity="warning" sx={{ mb: 2 }}>
          <strong>Read-only since {fmtDate(t.read_only_since)}:</strong> {t.read_only_reason}. Their users can sign in
          and view everything but every write is refused. You can still make changes via View as.
        </Alert>
      )}
      {t.status === 'suspended' && profile.last_status_event?.action === 'tenant.suspend' && (
        <Alert severity="info" sx={{ mb: 2 }}>
          <strong>Suspended {fmtDate(profile.last_status_event.created_at)}</strong>
          {profile.last_status_event.actor_email && ` by ${profile.last_status_event.actor_email}`}
          {profile.last_status_event.reason && <>: {profile.last_status_event.reason}</>}
        </Alert>
      )}
      {trialDays !== null && t.subscription_status === 'trialing' && trialDays <= 14 && (
        <Alert severity={trialDays < 0 ? 'error' : 'warning'} sx={{ mb: 2 }}>
          {trialDays < 0
            ? `Trial ended ${Math.abs(trialDays)} day${Math.abs(trialDays) === 1 ? '' : 's'} ago and the subscription is still "trialing".`
            : `Trial ends in ${trialDays} day${trialDays === 1 ? '' : 's'} (${fmtDate(t.trial_ends_at)}).`}
        </Alert>
      )}

      <Tabs value={tab} onChange={(_, v) => setTab(v)} sx={{ mb: 2, borderBottom: 1, borderColor: 'divider' }}>
        <Tab value="summary" label="Summary" />
        <Tab value="activity" label="Activity" />
        <Tab value="approvals" label="Approval thresholds" />
        <Tab value="notes" label={`Notes${profile.notes_count ? ` (${profile.notes_count})` : ''}`} />
      </Tabs>

      {/* ------------------------------------------------------------ */}
      {tab === 'summary' && (
        <Stack spacing={2}>
          <Stack direction="row" spacing={2} flexWrap="wrap" useFlexGap>
            <Stat
              label="Seats used"
              value={t.seat_limit == null ? `${seatsUsed}` : `${seatsUsed} / ${t.seat_limit}`}
              hint={`${profile.seats.members} members · ${profile.seats.pending_invites} pending invites${seatsFull ? ' · FULL' : ''}`}
            />
            <Stat label="Modules enabled" value={profile.activity.modules} />
            <Stat label="Requests (30d)" value={profile.activity.requests_30d} />
            <Stat label="Last sign-in" value={fmtDate(profile.activity.last_sign_in_at)} hint="any member" />
            <Stat label="Last request" value={fmtDate(profile.activity.last_request_at)} />
          </Stack>

          <Paper variant="outlined" sx={{ p: 2 }}>
            <Stack direction="row" justifyContent="space-between" alignItems="center" sx={{ mb: 1.5 }}>
              <Typography variant="subtitle1">Lifecycle</Typography>
              <Stack direction="row" spacing={1}>
                <Tooltip title={blockedReason ?? ''}>
                  <span>
                    <Button size="small" variant="outlined" disabled={!!blockedReason} onClick={() => setImpersonateOpen(true)}>
                      View as
                    </Button>
                  </span>
                </Tooltip>
                {t.status !== 'pending' && (
                  <Tooltip title={blockedReason ?? ''}>
                    <span>
                      <Button
                        size="small"
                        variant="outlined"
                        color="warning"
                        disabled={!!blockedReason}
                        onClick={() => {
                          setReason('');
                          setReadOnlyDialog(!t.read_only);
                        }}
                      >
                        {t.read_only ? 'Lift read-only' : 'Make read-only'}
                      </Button>
                    </span>
                  </Tooltip>
                )}
                {t.status !== 'pending' && (
                  <Tooltip title={blockedReason ?? ''}>
                    <span>
                      <Button
                        size="small"
                        variant="outlined"
                        color={t.status === 'suspended' ? 'success' : 'error'}
                        disabled={!!blockedReason}
                        onClick={() => {
                          setReason('');
                          setStatusDialog(t.status === 'suspended' ? 'active' : 'suspended');
                        }}
                      >
                        {t.status === 'suspended' ? 'Reactivate' : 'Suspend'}
                      </Button>
                    </span>
                  </Tooltip>
                )}
              </Stack>
            </Stack>
            <Typography variant="body2" color="text.secondary">
              <strong>Read-only</strong> keeps the customer's data visible but refuses every change — the usual first
              step for an overdue account. <strong>Suspend</strong> locks their users out entirely. Both require a
              reason and are written to the audit log; you keep View-as access either way.
            </Typography>
            {profile.activity.company_admins.length > 0 && (
              <Typography variant="body2" sx={{ mt: 1.5 }}>
                <strong>Company admins:</strong>{' '}
                {profile.activity.company_admins.map((a) => `${a.name} (${a.email})`).join(', ')}
              </Typography>
            )}
          </Paper>

          <Paper variant="outlined" sx={{ p: 2 }}>
            <Stack direction="row" justifyContent="space-between" alignItems="center" sx={{ mb: 1.5 }}>
              <Typography variant="subtitle1">Customer profile</Typography>
              {editing ? (
                <Stack direction="row" spacing={1}>
                  <Button
                    size="small"
                    onClick={() => {
                      setEditing(false);
                      setDraft(draftFrom(t));
                    }}
                    disabled={savingProfile}
                  >
                    Cancel
                  </Button>
                  <Button size="small" variant="contained" onClick={saveProfile} disabled={!dirty || savingProfile}>
                    {savingProfile ? 'Saving…' : 'Save'}
                  </Button>
                </Stack>
              ) : (
                <Tooltip title={blockedReason ?? ''}>
                  <span>
                    <Button size="small" variant="outlined" disabled={!!blockedReason} onClick={() => setEditing(true)}>
                      Edit
                    </Button>
                  </span>
                </Tooltip>
              )}
            </Stack>

            {editing ? (
              <Stack spacing={2}>
                <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2}>
                  <TextField
                    label="Company name"
                    size="small"
                    fullWidth
                    required
                    value={draft.name}
                    onChange={(e) => setDraft({ ...draft, name: e.target.value })}
                  />
                  <TextField
                    label="TIN / tax ID"
                    size="small"
                    fullWidth
                    value={draft.tax_id}
                    onChange={(e) => setDraft({ ...draft, tax_id: e.target.value })}
                  />
                  <TextField
                    label="Country"
                    size="small"
                    sx={{ width: { sm: 120 } }}
                    value={draft.country}
                    inputProps={{ maxLength: 2, style: { textTransform: 'uppercase' } }}
                    helperText="ISO code"
                    onChange={(e) => setDraft({ ...draft, country: e.target.value.toUpperCase() })}
                  />
                </Stack>
                <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2}>
                  <TextField
                    label="Primary contact"
                    size="small"
                    fullWidth
                    value={draft.contact_name}
                    onChange={(e) => setDraft({ ...draft, contact_name: e.target.value })}
                  />
                  <TextField
                    label="Contact email"
                    size="small"
                    type="email"
                    fullWidth
                    value={draft.contact_email}
                    onChange={(e) => setDraft({ ...draft, contact_email: e.target.value })}
                  />
                  <TextField
                    label="Contact phone"
                    size="small"
                    fullWidth
                    value={draft.contact_phone}
                    onChange={(e) => setDraft({ ...draft, contact_phone: e.target.value })}
                  />
                </Stack>
                <TextField
                  label="Address"
                  size="small"
                  fullWidth
                  multiline
                  minRows={2}
                  value={draft.address}
                  onChange={(e) => setDraft({ ...draft, address: e.target.value })}
                />
                <Divider />
                <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2}>
                  <FormControl size="small" fullWidth>
                    <InputLabel id="plan-label">Plan</InputLabel>
                    <Select
                      labelId="plan-label"
                      label="Plan"
                      value={draft.plan}
                      onChange={(e) => setDraft({ ...draft, plan: e.target.value })}
                    >
                      {PLAN_OPTIONS.map((p) => (
                        <MenuItem key={p.value} value={p.value}>
                          {p.label}
                        </MenuItem>
                      ))}
                    </Select>
                  </FormControl>
                  <FormControl size="small" fullWidth>
                    <InputLabel id="sub-label">Subscription</InputLabel>
                    <Select
                      labelId="sub-label"
                      label="Subscription"
                      value={draft.subscription_status}
                      onChange={(e) => setDraft({ ...draft, subscription_status: e.target.value })}
                    >
                      {SUBSCRIPTION_OPTIONS.map((p) => (
                        <MenuItem key={p.value} value={p.value}>
                          {p.label}
                        </MenuItem>
                      ))}
                    </Select>
                  </FormControl>
                  <TextField
                    label="Seat limit"
                    size="small"
                    type="number"
                    fullWidth
                    value={draft.seat_limit}
                    inputProps={{ min: 1 }}
                    helperText="Blank = unlimited"
                    onChange={(e) => setDraft({ ...draft, seat_limit: e.target.value })}
                  />
                </Stack>
                <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2}>
                  <TextField
                    label="Trial ends"
                    size="small"
                    type="date"
                    fullWidth
                    InputLabelProps={{ shrink: true }}
                    value={draft.trial_ends_at}
                    onChange={(e) => setDraft({ ...draft, trial_ends_at: e.target.value })}
                  />
                  <TextField
                    label="Renews / next invoice"
                    size="small"
                    type="date"
                    fullWidth
                    InputLabelProps={{ shrink: true }}
                    value={draft.renews_at}
                    onChange={(e) => setDraft({ ...draft, renews_at: e.target.value })}
                  />
                </Stack>
                <Typography variant="caption" color="text.secondary">
                  Only changed fields are saved and each change is recorded in the audit log.
                </Typography>
              </Stack>
            ) : (
              <Table size="small">
                <TableBody>
                  {[
                    ['Primary contact', t.contact_name],
                    ['Contact email', t.contact_email],
                    ['Contact phone', t.contact_phone],
                    ['TIN / tax ID', t.tax_id],
                    ['Address', t.address],
                    ['Country', t.country],
                    ['Plan', PLAN_OPTIONS.find((p) => p.value === t.plan)?.label ?? t.plan],
                    [
                      'Subscription',
                      SUBSCRIPTION_OPTIONS.find((s) => s.value === t.subscription_status)?.label ?? t.subscription_status,
                    ],
                    ['Seat limit', t.seat_limit == null ? 'Unlimited' : String(t.seat_limit)],
                    ['Trial ends', fmtDate(t.trial_ends_at)],
                    ['Renews / next invoice', fmtDate(t.renews_at)],
                    ['Profile updated', fmtDateTime(t.updated_at)],
                  ].map(([k, v]) => (
                    <TableRow key={k as string}>
                      <TableCell sx={{ width: 200, color: 'text.secondary', borderBottom: 'none', py: 0.5 }}>{k}</TableCell>
                      <TableCell sx={{ borderBottom: 'none', py: 0.5 }}>
                        {v && String(v).length > 0 ? String(v) : <span style={{ opacity: 0.5 }}>—</span>}
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            )}
          </Paper>

          <Paper variant="outlined" sx={{ p: 2 }}>
            <Stack direction="row" justifyContent="space-between" alignItems="center" sx={{ mb: 1 }}>
              <Typography variant="subtitle1">Recent platform actions</Typography>
              <Link component={RouterLink} to={`/admin/audit?tenant=${t.id}`} variant="body2">
                Full audit log
              </Link>
            </Stack>
            {profile.recent_events.length === 0 ? (
              <Typography variant="body2" color="text.secondary">
                Nothing yet.
              </Typography>
            ) : (
              <Table size="small">
                <TableBody>
                  {profile.recent_events.map((e) => (
                    <TableRow key={e.id}>
                      <TableCell sx={{ whiteSpace: 'nowrap', width: 170 }}>{fmtDateTime(e.created_at)}</TableCell>
                      <TableCell sx={{ whiteSpace: 'nowrap' }}>{actionLabel(e.action)}</TableCell>
                      <TableCell sx={{ color: 'text.secondary' }}>{e.reason ?? ''}</TableCell>
                      <TableCell sx={{ color: 'text.secondary', whiteSpace: 'nowrap' }}>{e.actor_email ?? ''}</TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            )}
          </Paper>
        </Stack>
      )}

      {/* ------------------------------------------------------------ */}
      {tab === 'activity' && (
        <>
          <Stack direction="row" spacing={2} flexWrap="wrap" sx={{ mb: 3 }}>
            <Paper variant="outlined" sx={{ px: 2, py: 1, minWidth: 160 }}>
              <Typography variant="h6">{analytics.purchase_orders.count}</Typography>
              <Typography variant="caption" color="text.secondary">
                Purchase orders
              </Typography>
            </Paper>
            <Paper variant="outlined" sx={{ px: 2, py: 1, minWidth: 200 }}>
              <Typography variant="h6">
                {analytics.purchase_orders.total_value.toLocaleString(undefined, { maximumFractionDigits: 0 })}
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
              <BarList rows={analytics.members_by_department} labelKey="department" emptyLabel="No members yet." />
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
        </>
      )}

      {/* ------------------------------------------------------------ */}
      {tab === 'approvals' && (
        <>
          <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
            Amount (UGX) at which each branch point routes to the higher-authority path instead of the default one.
            New tenants are seeded at 5,000,000; edit per stage below.
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
                          disabled={
                            !!blockedReason ||
                            savingStageId === stage.id ||
                            drafts[stage.id] === String(stage.threshold_amount)
                          }
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
        </>
      )}

      {/* ------------------------------------------------------------ */}
      {tab === 'notes' && (
        <Stack spacing={2}>
          <Alert severity="info" icon={false}>
            Operator-only. Customers never see these notes — use them for account history, calls, commitments.
          </Alert>
          <Paper variant="outlined" sx={{ p: 2 }}>
            <TextField
              fullWidth
              multiline
              minRows={2}
              placeholder="e.g. Spoke with Jane — will pay INV-0231 by Friday; agreed to hold read-only until then."
              value={noteDraft}
              onChange={(e) => setNoteDraft(e.target.value)}
              disabled={noteSaving}
              inputProps={{ maxLength: 4000 }}
            />
            <Stack direction="row" justifyContent="flex-end" sx={{ mt: 1 }}>
              <Button variant="contained" size="small" onClick={addNote} disabled={noteSaving || noteDraft.trim().length === 0}>
                {noteSaving ? 'Adding…' : 'Add note'}
              </Button>
            </Stack>
          </Paper>
          {notes === null ? (
            <CircularProgress size={20} />
          ) : notes.length === 0 ? (
            <Typography variant="body2" color="text.secondary">
              No notes yet.
            </Typography>
          ) : (
            notes.map((n) => (
              <Paper key={n.id} variant="outlined" sx={{ p: 2 }}>
                <Typography variant="body2" sx={{ whiteSpace: 'pre-wrap' }}>
                  {n.body}
                </Typography>
                <Typography variant="caption" color="text.secondary">
                  {fmtDateTime(n.created_at)}
                  {n.author_email && ` · ${n.author_email}`}
                </Typography>
              </Paper>
            ))
          )}
        </Stack>
      )}

      {/* ------------------------------------------------------------ */}
      <Dialog open={!!statusDialog} onClose={() => !dialogSaving && setStatusDialog(null)}>
        <DialogTitle>{statusDialog === 'suspended' ? 'Suspend company?' : 'Reactivate company?'}</DialogTitle>
        <DialogContent>
          <DialogContentText>
            {statusDialog === 'suspended' ? (
              <>
                {t.name} will be marked suspended. Their users will immediately lose access (they'll see a "your
                company's access has been suspended" message). You'll still be able to View as them.
              </>
            ) : (
              <>{t.name} will be marked active again.</>
            )}
          </DialogContentText>
          <TextField
            fullWidth
            multiline
            minRows={2}
            sx={{ mt: 2 }}
            label={statusDialog === 'suspended' ? 'Reason (required)' : 'Reason (optional)'}
            placeholder={statusDialog === 'suspended' ? 'e.g. Invoice INV-0231 unpaid 60 days past due' : 'e.g. Payment received 22 Sep'}
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            disabled={dialogSaving}
            helperText="Recorded in the platform audit log."
          />
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setStatusDialog(null)} disabled={dialogSaving}>
            Cancel
          </Button>
          <Button
            color={statusDialog === 'suspended' ? 'error' : 'success'}
            onClick={confirmStatus}
            disabled={dialogSaving || (statusDialog === 'suspended' && reason.trim().length === 0)}
          >
            {dialogSaving ? 'Saving…' : statusDialog === 'suspended' ? 'Suspend' : 'Reactivate'}
          </Button>
        </DialogActions>
      </Dialog>

      <Dialog open={readOnlyDialog !== null} onClose={() => !dialogSaving && setReadOnlyDialog(null)}>
        <DialogTitle>{readOnlyDialog ? 'Put company in read-only mode?' : 'Lift read-only mode?'}</DialogTitle>
        <DialogContent>
          <DialogContentText>
            {readOnlyDialog ? (
              <>
                {t.name}'s users will keep signing in and seeing their data, but every create/edit/delete will be
                refused with a message quoting the reason below. Platform admins are exempt.
              </>
            ) : (
              <>{t.name}'s users will be able to make changes again.</>
            )}
          </DialogContentText>
          <TextField
            fullWidth
            multiline
            minRows={2}
            sx={{ mt: 2 }}
            label={readOnlyDialog ? 'Reason (required — shown to their users)' : 'Reason (optional)'}
            placeholder={readOnlyDialog ? 'e.g. Subscription payment overdue — contact billing@vestateck.com' : ''}
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            disabled={dialogSaving}
            helperText="Recorded in the platform audit log."
          />
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setReadOnlyDialog(null)} disabled={dialogSaving}>
            Cancel
          </Button>
          <Button
            color="warning"
            onClick={confirmReadOnly}
            disabled={dialogSaving || (readOnlyDialog === true && reason.trim().length === 0)}
          >
            {dialogSaving ? 'Saving…' : readOnlyDialog ? 'Make read-only' : 'Lift read-only'}
          </Button>
        </DialogActions>
      </Dialog>

      <ImpersonationReasonDialog
        open={impersonateOpen}
        tenant={{ id: t.id, name: t.name }}
        onClose={() => setImpersonateOpen(false)}
        onStarted={() => {
          setImpersonateOpen(false);
          navigate('/requests/new');
        }}
      />
    </Box>
  );
}
