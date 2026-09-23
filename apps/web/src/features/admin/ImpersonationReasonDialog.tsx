import { useEffect, useState } from 'react';
import {
  Alert,
  Button,
  Dialog,
  DialogActions,
  DialogContent,
  DialogContentText,
  DialogTitle,
  TextField,
} from '@mui/material';
import { supabase } from '../../lib/supabaseClient';
import { friendlyPlatformError } from './usePlatformAdminSession';

interface Props {
  open: boolean;
  tenant: { id: string; name: string } | null;
  user?: { id: string; name: string; email: string } | null;
  onClose: () => void;
  // Called after the RPC succeeds. The caller decides where to navigate
  // (dashboard today; per-tenant landing later).
  onStarted: (tenantId: string) => void;
}

const MIN_REASON = 5;

// start_impersonation(uuid, text) refuses a blank/short reason server-side;
// this dialog exists so the operator is asked *before* the RPC rather than
// getting a raw error. Every reason lands in platform_audit_events and the
// impersonation history screen, so make it something a customer could read.
export default function ImpersonationReasonDialog({ open, tenant, user, onClose, onStarted }: Props) {
  const [reason, setReason] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (open) {
      setReason('');
      setError(null);
      setSubmitting(false);
    }
  }, [open, tenant?.id]);

  const trimmed = reason.trim();
  const tooShort = trimmed.length < MIN_REASON;

  const submit = async () => {
    if (!tenant || tooShort) return;
    setSubmitting(true);
    setError(null);
    const { error: err } = user
      ? await supabase.rpc('start_impersonation', {
          p_tenant_id: tenant.id,
          p_reason: trimmed,
          p_user_id: user.id,
        })
      : await supabase.rpc('start_impersonation', {
          p_tenant_id: tenant.id,
          p_reason: trimmed,
        });
    setSubmitting(false);
    if (err) {
      setError(friendlyPlatformError(err.message));
      return;
    }
    onStarted(tenant.id);
  };

  return (
    <Dialog open={open} onClose={submitting ? undefined : onClose} maxWidth="sm" fullWidth>
      <DialogTitle>View as {tenant?.name ?? 'company'}</DialogTitle>
      <DialogContent>
        <DialogContentText sx={{ mb: 2 }}>
          You are about to step into this company&apos;s workspace with full access to its data.
          The session lasts 2 hours and is recorded, together with the reason you give here,
          in the platform audit log.
        </DialogContentText>
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
          placeholder="e.g. Support ticket #142 — verifying payroll approver setup"
          value={reason}
          onChange={(e) => setReason(e.target.value)}
          helperText={tooShort ? `At least ${MIN_REASON} characters` : ' '}
          error={reason.length > 0 && tooShort}
          disabled={submitting}
          onKeyDown={(e) => {
            if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) submit();
          }}
        />
      </DialogContent>
      <DialogActions>
        <Button onClick={onClose} disabled={submitting}>
          Cancel
        </Button>
        <Button variant="contained" onClick={submit} disabled={tooShort || submitting}>
          {submitting ? 'Starting…' : 'Start session'}
        </Button>
      </DialogActions>
    </Dialog>
  );
}
