import {
  Button,
  Divider,
  FormControl,
  InputLabel,
  Link,
  MenuItem,
  Paper,
  Select,
  Stack,
  Table,
  TableBody,
  TableCell,
  TableRow,
  TextField,
  Tooltip,
  Typography,
} from '@mui/material';
import { Link as RouterLink } from 'react-router-dom';
import { PLAN_OPTIONS, SUBSCRIPTION_OPTIONS } from './Constants';
import { Stat } from './Stat';
import { actionLabel, draftFrom, fmtDate, fmtDateTime } from './utils';
import type { CompanyDetailState } from './useCompanyDetail';

export function SummaryTab({ state }: { state: CompanyDetailState }) {
  const {
    profile,
    blockedReason,
    setImpersonateOpen,
    setReason,
    setReadOnlyDialog,
    setStatusDialog,
    editing,
    setEditing,
    draft,
    setDraft,
    savingProfile,
    dirty,
    saveProfile,
  } = state;
  if (!profile || !draft) return null;
  const t = profile.tenant;
  const seatsUsed = profile.seats.members + profile.seats.pending_invites;
  const seatsFull = t.seat_limit != null && seatsUsed >= t.seat_limit;

  return (
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
  );
}