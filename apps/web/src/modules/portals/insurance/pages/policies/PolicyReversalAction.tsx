import { useEffect, useRef, useState } from 'react';
import { Alert, Box, Button, Checkbox, Dialog, DialogActions, DialogContent, DialogTitle, FormControlLabel, TextField, Typography } from '@mui/material';
import { errorText, rpc } from '../../db';
import type { PolicyReversal, ReversalEligibility } from '../../types';

interface Props {
  policyId: string;
  policyNo: string;
  onReversed: (result: PolicyReversal) => void | Promise<void>;
}

/** Server eligibility is advisory here and is rechecked under locks by the RPC. */
export default function PolicyReversalAction({ policyId, policyNo, onReversed }: Props) {
  const [eligibility, setEligibility] = useState<ReversalEligibility | null>(null);
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState('');
  const [reissue, setReissue] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const requestKey = useRef('');
  const submitting = useRef(false);

  useEffect(() => {
    let cancelled = false;
    setEligibility(null);
    rpc<ReversalEligibility>('ins_policy_reversal_eligibility', { p_policy_id: policyId })
      .then((value) => { if (!cancelled) setEligibility(value); })
      .catch((e: unknown) => { if (!cancelled) setError(errorText(e)); });
    return () => { cancelled = true; };
  }, [policyId]);

  const show = () => {
    setReason('');
    setReissue(false);
    setError(null);
    requestKey.current = crypto.randomUUID();
    setOpen(true);
  };

  const reverse = async () => {
    if (submitting.current || reason.trim().length < 5) return;
    submitting.current = true;
    setBusy(true);
    setError(null);
    try {
      const result = await rpc<PolicyReversal>('ins_reverse_policy', {
        p_policy_id: policyId, p_reason: reason.trim(), p_reissue: reissue, p_request_key: requestKey.current,
      });
      setOpen(false);
      await onReversed(result);
    } catch (e) {
      // Keep the dialog and request key for a safe retry after an uncertain response.
      setError(errorText(e));
    } finally {
      submitting.current = false;
      setBusy(false);
    }
  };

  return (
    <Box>
      <Button color="error" variant="outlined" onClick={show} disabled={!eligibility?.eligible || busy}>Reverse policy</Button>
      {eligibility && !eligibility.eligible && <Typography variant="caption" display="block">{eligibility.reason}</Typography>}
      {!open && error && <Alert severity="error">{error}</Alert>}
      <Dialog open={open} onClose={() => { if (!busy) setOpen(false); }} maxWidth="sm" fullWidth>
        <DialogTitle>Reverse {policyNo}?</DialogTitle>
        <DialogContent>
          <Alert severity="warning" sx={{ mb: 2 }}>
            This closes both premium open items with two linked credit notes dated today. No cash is paid or refunded.
            The original policy becomes reversed and cannot be reactivated. Claims, renewals or effective financial movement block reversal.
          </Alert>
          <TextField fullWidth label="Reversal reason" value={reason} onChange={(e) => setReason(e.target.value)} disabled={busy}
            multiline minRows={2} inputProps={{ maxLength: 2000 }} helperText="Required: at least 5 characters." />
          <FormControlLabel control={<Checkbox checked={reissue} onChange={(e) => setReissue(e.target.checked)} disabled={busy} />}
            label="Create a linked replacement draft" />
          <Typography variant="body2">{reissue
            ? 'A replacement draft will copy this policy. A manager must review and bind it separately.'
            : 'Reverse only. No replacement policy will be created.'}</Typography>
          {error && <Alert severity="error" sx={{ mt: 2 }}>{error}</Alert>}
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setOpen(false)} disabled={busy}>Cancel</Button>
          <Button variant="contained" color="error" onClick={reverse} disabled={busy || reason.trim().length < 5}>
            {busy ? 'Reversing…' : 'Confirm reversal'}
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}
