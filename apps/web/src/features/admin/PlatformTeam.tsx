import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Alert,
  Autocomplete,
  Box,
  Button,
  Chip,
  CircularProgress,
  Dialog,
  DialogActions,
  DialogContent,
  DialogContentText,
  DialogTitle,
  Paper,
  Stack,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  TextField,
  Tooltip,
  Typography,
} from '@mui/material';
import { PersonAdd, PersonRemove, VerifiedUser } from '@mui/icons-material';
import { Link as RouterLink } from 'react-router-dom';
import { supabase } from '../../lib/supabaseClient';
import { describeBlockedReason, friendlyPlatformError, usePlatformAdminSession } from './usePlatformAdminSession';
import { lastSeenLabel, teamWarnings, type DirectoryUser, type PlatformAdminRow } from './usersDirectory';

// /admin/team -- who can operate this console.
//
// Until 20260922200000 the schema allowed exactly one platform admin (a
// partial unique index), so the only way to add a colleague was a manual
// SQL update in production. Now: list_platform_admins() shows everyone
// holding the flag with their MFA state and last sign-in;
// set_platform_admin() grants/revokes with a mandatory reason, writes a
// platform_admin.grant/revoke audit event, refuses self-removal and
// refuses to remove the last admin. The flag can no longer be flipped by
// editing app_users directly (guard trigger), so this screen is the one
// place it changes.

const MIN_REASON = 5;

interface Candidate {
  id: string;
  label: string;
  email: string;
  name: string;
  tenant_name: string;
}

export default function PlatformTeam() {
  const { session: adminSession, refresh: refreshSession } = usePlatformAdminSession();
  const blockedReason = describeBlockedReason(adminSession);

  const [rows, setRows] = useState<PlatformAdminRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [grantOpen, setGrantOpen] = useState(false);
  const [revokeTarget, setRevokeTarget] = useState<PlatformAdminRow | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    const { data, error: err } = await supabase.rpc('list_platform_admins');
    setLoading(false);
    if (err) {
      setError(friendlyPlatformError(err.message));
      setRows([]);
      return;
    }
    setError(null);
    setRows((data ?? []) as PlatformAdminRow[]);
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const warnings = useMemo(() => teamWarnings(rows), [rows]);

  return (
    <Box sx={{ maxWidth: 1100 }}>
      <Stack direction="row" alignItems="flex-start" justifyContent="space-between" flexWrap="wrap" gap={2} mb={2}>
        <Box>
          <Typography variant="h4" gutterBottom>
            Platform team
          </Typography>
          <Typography variant="body2" color="text.secondary" sx={{ maxWidth: 760 }}>
            The people who can open this console, see every company and act on their behalf. Keep this list
            short. Every grant and revoke needs a reason and is written to the audit log.
          </Typography>
        </Box>
        <Tooltip title={blockedReason ?? ''}>
          <span>
            <Button variant="contained" startIcon={<PersonAdd />} disabled={!!blockedReason} onClick={() => setGrantOpen(true)}>
              Add platform admin
            </Button>
          </span>
        </Tooltip>
      </Stack>

      {blockedReason && (
        <Alert severity="warning" sx={{ mb: 2 }}>
          {blockedReason}
        </Alert>
      )}
      {error && (
        <Alert severity="error" sx={{ mb: 2 }} onClose={() => setError(null)}>
          {error}
        </Alert>
      )}
      {!loading &&
        warnings.map((w) => (
          <Alert key={w} severity="warning" variant="outlined" sx={{ mb: 1 }}>
            {w}
          </Alert>
        ))}

      <TableContainer component={Paper} variant="outlined" sx={{ mt: 2 }}>
        <Table size="small">
          <TableHead>
            <TableRow>
              <TableCell>Person</TableCell>
              <TableCell>Home company</TableCell>
              <TableCell align="center">MFA</TableCell>
              <TableCell>Last sign-in</TableCell>
              <TableCell>Granted</TableCell>
              <TableCell align="right">Actions</TableCell>
            </TableRow>
          </TableHead>
          <TableBody>
            {loading ? (
              <TableRow>
                <TableCell colSpan={6} align="center" sx={{ py: 4 }}>
                  <CircularProgress size={22} />
                </TableCell>
              </TableRow>
            ) : rows.length === 0 ? (
              <TableRow>
                <TableCell colSpan={6} align="center" sx={{ py: 4, color: 'text.secondary' }}>
                  No platform admins found.
                </TableCell>
              </TableRow>
            ) : (
              rows.map((r) => (
                <TableRow key={r.user_id} hover>
                  <TableCell>
                    <Typography variant="body2" fontWeight={600}>
                      {r.name}
                      {r.is_self && <Chip size="small" label="you" sx={{ ml: 1 }} />}
                    </Typography>
                    <Typography variant="caption" color="text.secondary">
                      {r.email}
                    </Typography>
                  </TableCell>
                  <TableCell>
                    <Typography variant="body2">{r.tenant_name}</Typography>
                  </TableCell>
                  <TableCell align="center">
                    {r.mfa_enrolled ? (
                      <Tooltip title="Authenticator enrolled — console actions require a code">
                        <VerifiedUser fontSize="small" color="success" />
                      </Tooltip>
                    ) : (
                      <Chip size="small" label="not enrolled" color="warning" variant="outlined" />
                    )}
                  </TableCell>
                  <TableCell>
                    <Typography variant="body2">{lastSeenLabel(r.last_sign_in_at)}</Typography>
                  </TableCell>
                  <TableCell>
                    {r.granted_at ? (
                      <>
                        <Typography variant="body2">{new Date(r.granted_at).toLocaleDateString()}</Typography>
                        {r.granted_by_email && (
                          <Typography variant="caption" color="text.secondary">
                            by {r.granted_by_email}
                          </Typography>
                        )}
                      </>
                    ) : (
                      <Typography variant="caption" color="text.secondary">
                        bootstrap / before audit
                      </Typography>
                    )}
                  </TableCell>
                  <TableCell align="right">
                    <Tooltip
                      title={
                        r.is_self
                          ? 'You cannot remove yourself — ask another platform admin'
                          : rows.length === 1
                            ? 'The last platform admin cannot be removed'
                            : (blockedReason ?? '')
                      }
                    >
                      <span>
                        <Button
                          size="small"
                          color="error"
                          startIcon={<PersonRemove fontSize="small" />}
                          disabled={r.is_self || rows.length === 1 || !!blockedReason}
                          onClick={() => setRevokeTarget(r)}
                        >
                          Remove
                        </Button>
                      </span>
                    </Tooltip>
                  </TableCell>
                </TableRow>
              ))
            )}
          </TableBody>
        </Table>
      </TableContainer>

      <Typography variant="caption" color="text.secondary" sx={{ display: 'block', mt: 1.5 }}>
        Looking for someone who is not an operator? Every account on the platform is in{' '}
        <RouterLink to="/admin/users">Users</RouterLink>. Grants and revokes appear in the{' '}
        <RouterLink to="/admin/audit">audit log</RouterLink> as platform_admin.grant / platform_admin.revoke.
      </Typography>

      <GrantDialog
        open={grantOpen}
        existingIds={rows.map((r) => r.user_id)}
        onClose={() => setGrantOpen(false)}
        onDone={() => {
          setGrantOpen(false);
          load();
          refreshSession();
        }}
      />

      <ReasonDialog
        open={!!revokeTarget}
        title={`Remove ${revokeTarget?.name ?? ''} from the platform team`}
        body={`${revokeTarget?.email ?? ''} will lose access to this console immediately, and any View-as session they have open will be ended. Their ordinary account in ${revokeTarget?.tenant_name ?? 'their company'} is unaffected.`}
        confirmLabel="Remove"
        confirmColor="error"
        onClose={() => setRevokeTarget(null)}
        onConfirm={async (reason) => {
          if (!revokeTarget) return null;
          const { error: err } = await supabase.rpc('set_platform_admin', {
            p_user_id: revokeTarget.user_id,
            p_enabled: false,
            p_reason: reason,
          });
          if (err) return friendlyPlatformError(err.message);
          setRevokeTarget(null);
          load();
          return null;
        }}
      />
    </Box>
  );
}

// ---------------------------------------------------------------------
// Grant: pick anyone from the directory who is not already an admin.
// ---------------------------------------------------------------------
function GrantDialog({
  open,
  existingIds,
  onClose,
  onDone,
}: {
  open: boolean;
  existingIds: string[];
  onClose: () => void;
  onDone: () => void;
}) {
  const [query, setQuery] = useState('');
  const [options, setOptions] = useState<Candidate[]>([]);
  const [searching, setSearching] = useState(false);
  const [picked, setPicked] = useState<Candidate | null>(null);
  const [reason, setReason] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (open) {
      setQuery('');
      setOptions([]);
      setPicked(null);
      setReason('');
      setError(null);
      setSubmitting(false);
    }
  }, [open]);

  useEffect(() => {
    if (!open) return;
    const q = query.trim();
    if (q.length < 2) {
      setOptions([]);
      return;
    }
    let cancelled = false;
    setSearching(true);
    const id = window.setTimeout(async () => {
      const { data } = await supabase.rpc('platform_users_directory', { p_search: q, p_limit: 20 });
      if (cancelled) return;
      setSearching(false);
      const list = ((data ?? []) as DirectoryUser[])
        .filter((u) => !u.is_platform_admin && !existingIds.includes(u.user_id))
        .map((u) => ({
          id: u.user_id,
          label: `${u.name} — ${u.email} (${u.tenant_name})`,
          email: u.email,
          name: u.name,
          tenant_name: u.tenant_name,
        }));
      setOptions(list);
    }, 300);
    return () => {
      cancelled = true;
      window.clearTimeout(id);
    };
  }, [query, open, existingIds]);

  const trimmed = reason.trim();
  const tooShort = trimmed.length < MIN_REASON;

  const submit = async () => {
    if (!picked || tooShort) return;
    setSubmitting(true);
    setError(null);
    const { error: err } = await supabase.rpc('set_platform_admin', {
      p_user_id: picked.id,
      p_enabled: true,
      p_reason: trimmed,
    });
    setSubmitting(false);
    if (err) {
      setError(friendlyPlatformError(err.message));
      return;
    }
    onDone();
  };

  return (
    <Dialog open={open} onClose={submitting ? undefined : onClose} maxWidth="sm" fullWidth>
      <DialogTitle>Add a platform admin</DialogTitle>
      <DialogContent>
        <DialogContentText sx={{ mb: 2 }}>
          The person must already have an account (accept an invitation into any company first — the
          platform&apos;s own internal company is fine). They gain full operator access the moment you
          confirm, and will be asked to enrol an authenticator before they can act.
        </DialogContentText>
        {error && (
          <Alert severity="error" sx={{ mb: 2 }} onClose={() => setError(null)}>
            {error}
          </Alert>
        )}
        <Autocomplete
          options={options}
          value={picked}
          onChange={(_, v) => setPicked(v)}
          inputValue={query}
          onInputChange={(_, v) => setQuery(v)}
          loading={searching}
          filterOptions={(x) => x}
          isOptionEqualToValue={(a, b) => a.id === b.id}
          noOptionsText={query.trim().length < 2 ? 'Type at least 2 characters' : 'No matching accounts'}
          renderInput={(params) => (
            <TextField {...params} autoFocus label="Find by name or email" placeholder="jane@company.com" />
          )}
          sx={{ mb: 2 }}
        />
        <TextField
          fullWidth
          multiline
          minRows={2}
          label="Reason"
          placeholder="e.g. Joining the support rota from October"
          value={reason}
          onChange={(e) => setReason(e.target.value)}
          helperText={tooShort ? `At least ${MIN_REASON} characters` : ' '}
          error={reason.length > 0 && tooShort}
          disabled={submitting}
        />
      </DialogContent>
      <DialogActions>
        <Button onClick={onClose} disabled={submitting}>
          Cancel
        </Button>
        <Button variant="contained" onClick={submit} disabled={!picked || tooShort || submitting}>
          {submitting ? 'Granting…' : 'Grant access'}
        </Button>
      </DialogActions>
    </Dialog>
  );
}

// ---------------------------------------------------------------------
// Generic "reason required" confirm, used for revoke.
// ---------------------------------------------------------------------
function ReasonDialog({
  open,
  title,
  body,
  confirmLabel,
  confirmColor = 'primary',
  onClose,
  onConfirm,
}: {
  open: boolean;
  title: string;
  body: string;
  confirmLabel: string;
  confirmColor?: 'primary' | 'error';
  onClose: () => void;
  // Return an error message to show, or null on success.
  onConfirm: (reason: string) => Promise<string | null>;
}) {
  const [reason, setReason] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (open) {
      setReason('');
      setError(null);
      setSubmitting(false);
    }
  }, [open]);

  const trimmed = reason.trim();
  const tooShort = trimmed.length < MIN_REASON;

  const submit = async () => {
    if (tooShort) return;
    setSubmitting(true);
    setError(null);
    const msg = await onConfirm(trimmed);
    setSubmitting(false);
    if (msg) setError(msg);
  };

  return (
    <Dialog open={open} onClose={submitting ? undefined : onClose} maxWidth="sm" fullWidth>
      <DialogTitle>{title}</DialogTitle>
      <DialogContent>
        <DialogContentText sx={{ mb: 2 }}>{body}</DialogContentText>
        {error && (
          <Alert severity="error" sx={{ mb: 2 }} onClose={() => setError(null)}>
            {error}
          </Alert>
        )}
        <TextField
          autoFocus
          fullWidth
          multiline
          minRows={2}
          label="Reason"
          value={reason}
          onChange={(e) => setReason(e.target.value)}
          helperText={tooShort ? `At least ${MIN_REASON} characters` : ' '}
          error={reason.length > 0 && tooShort}
          disabled={submitting}
        />
      </DialogContent>
      <DialogActions>
        <Button onClick={onClose} disabled={submitting}>
          Cancel
        </Button>
        <Button variant="contained" color={confirmColor} onClick={submit} disabled={tooShort || submitting}>
          {submitting ? 'Working…' : confirmLabel}
        </Button>
      </DialogActions>
    </Dialog>
  );
}
