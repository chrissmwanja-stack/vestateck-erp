import { Alert, Box, Chip, CircularProgress, Stack, Tab, Tabs, Typography } from '@mui/material';
import ImpersonationReasonDialog from '../../ImpersonationReasonDialog';
import { LifecycleDialogs } from './LifecycleDialogs';
import { ActivityTab } from './ActivityTab';
import { ApprovalsTab } from './ApprovalsTab';
import { NotesTab } from './NotesTab';
import { SummaryTab } from './SummaryTab';
import { PLAN_OPTIONS, SUBSCRIPTION_OPTIONS, subscriptionColor, tenantStatusColor } from './Constants';
import { useCompanyDetail } from './useCompanyDetail';
import { daysUntil, fmtDate } from './utils';

// Single-company drill-down for the platform operator.
//
// Tabs:
//   Summary   -- customer profile (contact, TIN, plan, seats, trial),
//                lifecycle controls (suspend / read-only / View as), last
//                status event and recent audit entries.
//   Activity  -- the request/PO/department breakdowns that used to be the
//                whole page.
//   Approvals -- workflow threshold editor (unchanged).
//   Notes     -- operator-only timeline (tenant_notes); customers never see it.
export default function CompanyDetail() {
  const state = useCompanyDetail();
  const {
    navigate,
    tab,
    setTab,
    profile,
    analytics,
    loading,
    error,
    draft,
    notice,
    setNotice,
    actionError,
    setActionError,
    impersonateOpen,
    setImpersonateOpen,
  } = state;

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

      {tab === 'summary' && <SummaryTab state={state} />}
      {tab === 'activity' && <ActivityTab analytics={analytics} />}
      {tab === 'approvals' && <ApprovalsTab state={state} />}
      {tab === 'notes' && <NotesTab state={state} />}

      <LifecycleDialogs state={state} t={t} />

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

export { buildProfilePatch, daysUntil, actionLabel } from './utils';
export { PLAN_OPTIONS, SUBSCRIPTION_OPTIONS } from './Constants';