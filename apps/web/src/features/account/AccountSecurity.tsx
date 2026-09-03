import { useCallback, useEffect, useState } from 'react';
import {
  Alert,
  Box,
  Button,
  Chip,
  CircularProgress,
  Dialog,
  DialogActions,
  DialogContent,
  DialogTitle,
  Paper,
  Stack,
  TextField,
  Typography,
} from '@mui/material';
import { supabase } from '../../lib/supabaseClient';
import { useSecuritySettings } from '../../hooks/useSecuritySettings';

interface TotpFactor {
  id: string;
  friendly_name?: string | null;
  status: 'verified' | 'unverified';
  created_at: string;
}

// Supabase's mfa.enroll() has returned `qr_code` both as a bare SVG
// string and as an already-prefixed data URI depending on version --
// handle both rather than assume.
function qrImageSrc(qrCode: string): string {
  return qrCode.startsWith('data:') ? qrCode : `data:image/svg+xml;utf-8,${encodeURIComponent(qrCode)}`;
}

export default function AccountSecurity() {
  const { requireMfa, loading: settingsLoading } = useSecuritySettings();
  const [factors, setFactors] = useState<TotpFactor[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [enrolling, setEnrolling] = useState(false);
  const [enrollFactorId, setEnrollFactorId] = useState<string | null>(null);
  const [qrSrc, setQrSrc] = useState<string | null>(null);
  const [secret, setSecret] = useState<string | null>(null);
  const [verifyCode, setVerifyCode] = useState('');
  const [verifying, setVerifying] = useState(false);
  const [verifyError, setVerifyError] = useState<string | null>(null);

  const [removeTarget, setRemoveTarget] = useState<TotpFactor | null>(null);
  const [removing, setRemoving] = useState(false);
  const [removeError, setRemoveError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const { data, error: err } = await supabase.auth.mfa.listFactors();
    if (err) setError(err.message);
    else setFactors((data?.totp ?? []) as TotpFactor[]);
    setLoading(false);
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const verifiedFactors = factors.filter((f) => f.status === 'verified');

  const startEnroll = async () => {
    setError(null);
    setEnrolling(true);
    const { data, error: err } = await supabase.auth.mfa.enroll({ factorType: 'totp' });
    if (err || !data) {
      setError(err?.message ?? 'Could not start enrollment.');
      setEnrolling(false);
      return;
    }
    setEnrollFactorId(data.id);
    setQrSrc(qrImageSrc(data.totp.qr_code));
    setSecret(data.totp.secret);
    setVerifyCode('');
    setVerifyError(null);
  };

  const cancelEnroll = async () => {
    // Unenroll the just-created (still-unverified) factor rather than
    // leaving an orphaned unverified factor behind if the user backs out.
    if (enrollFactorId) {
      await supabase.auth.mfa.unenroll({ factorId: enrollFactorId });
    }
    setEnrolling(false);
    setEnrollFactorId(null);
    setQrSrc(null);
    setSecret(null);
    setVerifyCode('');
    setVerifyError(null);
  };

  const confirmEnroll = async () => {
    if (!enrollFactorId || verifyCode.trim().length !== 6) {
      setVerifyError('Enter the 6-digit code from your authenticator app.');
      return;
    }
    setVerifying(true);
    setVerifyError(null);
    const { error: err } = await supabase.auth.mfa.challengeAndVerify({
      factorId: enrollFactorId,
      code: verifyCode.trim(),
    });
    setVerifying(false);
    if (err) {
      setVerifyError(err.message);
      return;
    }
    setEnrolling(false);
    setEnrollFactorId(null);
    setQrSrc(null);
    setSecret(null);
    setVerifyCode('');
    load();
  };

  const confirmRemove = async () => {
    if (!removeTarget) return;
    setRemoving(true);
    setRemoveError(null);
    const { error: err } = await supabase.auth.mfa.unenroll({ factorId: removeTarget.id });
    setRemoving(false);
    if (err) {
      setRemoveError(err.message);
      return;
    }
    setRemoveTarget(null);
    load();
  };

  return (
    <Box sx={{ maxWidth: 640, mx: 'auto' }}>
      <Typography variant="h5" fontWeight={700} sx={{ mb: 1 }}>
        Account security
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        Add a time-based authenticator app (Google Authenticator, Authy, 1Password, etc.) for a second sign-in
        step.
      </Typography>

      {requireMfa && !settingsLoading && verifiedFactors.length === 0 && (
        <Alert severity="warning" sx={{ mb: 3 }}>
          Your organization requires multi-factor authentication. Set up an authenticator below to continue using
          VestaPortal.
        </Alert>
      )}

      {error && (
        <Alert severity="error" sx={{ mb: 3 }}>
          {error}
        </Alert>
      )}

      <Paper variant="outlined" sx={{ p: 3, mb: 3 }}>
        {loading ? (
          <Box display="flex" justifyContent="center" py={2}>
            <CircularProgress size={24} />
          </Box>
        ) : verifiedFactors.length === 0 ? (
          <Typography variant="body2" color="text.secondary">
            No authenticator app set up yet.
          </Typography>
        ) : (
          <Stack spacing={1.5}>
            {verifiedFactors.map((f) => (
              <Stack key={f.id} direction="row" alignItems="center" justifyContent="space-between">
                <Stack direction="row" spacing={1.5} alignItems="center">
                  <Chip size="small" color="success" label="Active" />
                  <Typography variant="body2">
                    {f.friendly_name || 'Authenticator app'} — added{' '}
                    {new Date(f.created_at).toLocaleDateString()}
                  </Typography>
                </Stack>
                <Button size="small" color="error" onClick={() => setRemoveTarget(f)}>
                  Remove
                </Button>
              </Stack>
            ))}
          </Stack>
        )}
      </Paper>

      {!enrolling && (
        <Button variant="contained" onClick={startEnroll}>
          Set up authenticator app
        </Button>
      )}

      {enrolling && qrSrc && (
        <Paper variant="outlined" sx={{ p: 3 }}>
          <Stack spacing={2}>
            <Typography variant="subtitle2">1. Scan this with your authenticator app</Typography>
            <Box sx={{ bgcolor: '#fff', p: 2, borderRadius: 1, alignSelf: 'flex-start' }}>
              <img src={qrSrc} alt="QR code for authenticator app enrollment" width={180} height={180} />
            </Box>
            {secret && (
              <Typography variant="caption" color="text.secondary">
                Can't scan? Enter this code manually: <code>{secret}</code>
              </Typography>
            )}
            <Typography variant="subtitle2">2. Enter the 6-digit code it shows</Typography>
            <TextField
              value={verifyCode}
              onChange={(e) => setVerifyCode(e.target.value.replace(/\D/g, '').slice(0, 6))}
              placeholder="123456"
              inputProps={{ inputMode: 'numeric', maxLength: 6 }}
              sx={{ maxWidth: 180 }}
              autoFocus
            />
            {verifyError && <Alert severity="error">{verifyError}</Alert>}
            <Stack direction="row" spacing={1.5}>
              <Button variant="contained" onClick={confirmEnroll} disabled={verifying}>
                {verifying ? 'Verifying…' : 'Verify and activate'}
              </Button>
              <Button onClick={cancelEnroll} disabled={verifying}>
                Cancel
              </Button>
            </Stack>
          </Stack>
        </Paper>
      )}

      <Dialog open={!!removeTarget} onClose={() => !removing && setRemoveTarget(null)} maxWidth="sm" fullWidth>
        <DialogTitle>Remove authenticator app?</DialogTitle>
        <DialogContent>
          <Typography variant="body2">
            You'll no longer be asked for a code at sign-in.
            {requireMfa && ' Your organization requires MFA, so you may be asked to set it up again next time you sign in.'}
          </Typography>
          {removeError && (
            <Alert severity="error" sx={{ mt: 2 }}>
              {removeError}
            </Alert>
          )}
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setRemoveTarget(null)} disabled={removing}>
            Cancel
          </Button>
          <Button onClick={confirmRemove} variant="contained" color="error" disabled={removing}>
            {removing ? 'Removing…' : 'Remove'}
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}