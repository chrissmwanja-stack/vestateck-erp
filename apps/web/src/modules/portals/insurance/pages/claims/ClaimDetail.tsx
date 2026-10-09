import { useCallback, useEffect, useState } from 'react';
import {
  Alert, Box, Button, Card, CardContent, CircularProgress, Dialog, DialogActions, DialogContent, DialogContentText,
  DialogTitle, Grid, Stack, TextField, Typography,
} from '@mui/material';
import { useParams } from 'react-router-dom';
import { errorText, rows, rpc, table } from '../../db';
import { useInsuranceAccess } from '../../access';
import { CLAIM_DECISION_STATUSES, CLAIM_STATUS_LABEL, formatMoney, nextClaimStatuses } from '../../logic';
import type { Claim, ClaimEvent, ClaimStatus } from '../../types';
import { ClaimStatusChip, ErrorBanner, PageHeader } from '../../shared';

// Each transition the UI can offer and what it needs from the user.
type Step = { to: ClaimStatus; label: string; needsAmount?: boolean; needsNote?: boolean; note: string };

const STEPS: Record<string, Step> = {
  notified_assessing: { to: 'assessing', label: 'Start assessment', note: 'Moves the claim into assessment. No amounts change.' },
  notified_repudiated: { to: 'repudiated', label: 'Repudiate', needsNote: true, note: 'The insurer or broker declines the claim. A reason is required.' },
  assessing_approved: { to: 'approved', label: 'Approve', needsAmount: true, note: 'Records the approved amount. It cannot exceed the sum insured.' },
  assessing_repudiated: { to: 'repudiated', label: 'Repudiate', needsNote: true, note: 'The claim is declined. A reason is required.' },
  approved_settled: { to: 'settled', label: 'Mark settled', note: 'Marks the claim settled at the approved amount. No cash is posted to the ledger in this release.' },
  settled_closed: { to: 'closed', label: 'Close', note: 'Closes the file.' },
  repudiated_closed: { to: 'closed', label: 'Close', note: 'Closes the file.' },
};

export default function ClaimDetail() {
  const { id = '' } = useParams();
  const { canManage } = useInsuranceAccess();
  const [claim, setClaim] = useState<Claim | null>(null);
  const [events, setEvents] = useState<ClaimEvent[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [step, setStep] = useState<Step | null>(null);
  const [amount, setAmount] = useState('');
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const [c] = await rows<Claim>(
        table('ins_claims')
          .select('*, ins_policies(policy_no, sum_insured, currency, expiry_date, ins_clients(bd_clients(name)))')
          .eq('id', id),
      );
      setClaim(c ?? null);
      setEvents(await rows<ClaimEvent>(table('ins_claim_events').select('id, from_status, to_status, note, created_at').eq('claim_id', id).order('created_at', { ascending: true })));
      setError(null);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setLoading(false);
    }
  }, [id]);

  useEffect(() => {
    load();
  }, [load]);

  const openStep = (to: ClaimStatus) => {
    if (!claim) return;
    const s = STEPS[`${claim.status}_${to}`];
    if (!s) return;
    setStep(s);
    setAmount(s.needsAmount ? String(claim.reserve_amount || '') : '');
    setNote('');
  };

  const submit = async () => {
    if (!step) return;
    setBusy(true);
    setError(null);
    try {
      await rpc('ins_transition_claim', {
        p_claim_id: id,
        p_to: step.to,
        p_note: note.trim() || null,
        p_amount: step.needsAmount ? Number(amount) : null,
      });
      setStep(null);
      await load();
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  };

  if (loading) return <Box sx={{ p: 3, display: 'flex', justifyContent: 'center' }}><CircularProgress /></Box>;
  if (!claim) return <Box sx={{ p: 3 }}><Alert severity="warning">Claim not found, or you do not have access to it.</Alert></Box>;

  const currency = claim.ins_policies?.currency ?? 'UGX';
  const available = nextClaimStatuses(claim.status).filter((to) => {
    const s = STEPS[`${claim.status}_${to}`];
    if (!s) return false;
    // Decisions are manager/admin only on the server; hide them for members.
    return !CLAIM_DECISION_STATUSES.includes(to) || canManage;
  });
  const sumInsured = claim.ins_policies?.sum_insured ?? 0;
  const amountNum = Number(amount);
  const amountInvalid = !!step?.needsAmount && (!(amountNum > 0) || (sumInsured > 0 && amountNum > sumInsured));
  const noteInvalid = step?.needsNote && !note.trim();

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <PageHeader
        title={claim.claim_no}
        subtitle={`${claim.ins_policies?.ins_clients?.bd_clients?.name ?? 'Client'} · policy ${claim.ins_policies?.policy_no ?? '-'}`}
        actions={
          <Stack direction="row" spacing={1} alignItems="center" flexWrap="wrap" useFlexGap>
            <ClaimStatusChip status={claim.status} />
            {available.map((to) => {
              const s = STEPS[`${claim.status}_${to}`];
              return (
                <Button key={to} variant={to === 'repudiated' ? 'outlined' : 'contained'} color={to === 'repudiated' ? 'error' : 'primary'} onClick={() => openStep(to)}>
                  {s.label}
                </Button>
              );
            })}
          </Stack>
        }
      />
      <ErrorBanner message={error} />
      <Grid container spacing={2}>
        <Grid item xs={12} md={6}>
          <Card variant="outlined">
            <CardContent>
              <Typography variant="subtitle2" gutterBottom>Loss</Typography>
              <Row label="Loss date" value={claim.loss_date} />
              <Row label="Notified" value={claim.notified_date} />
              <Row label="Insurer reference" value={claim.insurer_claim_ref ?? '-'} />
              <Row label="Description" value={claim.loss_description} />
            </CardContent>
          </Card>
        </Grid>
        <Grid item xs={12} md={6}>
          <Card variant="outlined">
            <CardContent>
              <Typography variant="subtitle2" gutterBottom>Amounts ({currency})</Typography>
              <Row label="Reserve" value={formatMoney(claim.reserve_amount, currency)} />
              <Row label="Approved" value={claim.approved_amount == null ? '-' : formatMoney(claim.approved_amount, currency)} />
              <Row label="Recorded as paid" value={formatMoney(claim.paid_amount, currency)} />
              {claim.settled_at && <Row label="Settled" value={new Date(claim.settled_at).toLocaleString()} />}
              <Typography variant="caption" color="text.secondary" sx={{ display: 'block', mt: 1 }}>
                Reserve is set when the claim is reported. Cash payments are not posted by this module yet.
              </Typography>
            </CardContent>
          </Card>
        </Grid>
      </Grid>

      <Typography variant="h6" sx={{ mt: 3, mb: 1 }}>History</Typography>
      <Card variant="outlined">
        <CardContent>
          {events.length === 0 ? (
            <Typography color="text.secondary">No history yet.</Typography>
          ) : (
            <Stack spacing={1}>
              {events.map((e) => (
                <Box key={e.id} sx={{ borderLeft: 3, borderColor: 'primary.main', pl: 2, py: 0.5 }}>
                  <Typography variant="body2" fontWeight={600}>
                    {e.from_status ? `${CLAIM_STATUS_LABEL[e.from_status]} → ` : ''}{CLAIM_STATUS_LABEL[e.to_status]}
                  </Typography>
                  <Typography variant="caption" color="text.secondary">{new Date(e.created_at).toLocaleString()}</Typography>
                  {e.note && <Typography variant="body2">{e.note}</Typography>}
                </Box>
              ))}
            </Stack>
          )}
        </CardContent>
      </Card>

      <Dialog open={step !== null} onClose={() => !busy && setStep(null)} fullWidth maxWidth="sm">
        <DialogTitle>{step?.label}</DialogTitle>
        <DialogContent>
          <DialogContentText sx={{ mb: 2 }}>{step?.note}</DialogContentText>
          <Stack spacing={2}>
            {step?.needsAmount && (
              <TextField autoFocus label={`Approved amount (${currency})`} type="number" value={amount} onChange={(e) => setAmount(e.target.value)}
                error={amountInvalid} helperText={claim.ins_policies?.sum_insured ? `Must be above zero and at most ${formatMoney(claim.ins_policies.sum_insured, currency)}.` : 'Must be above zero.'}
                inputProps={{ min: 0, step: '0.01' }} />
            )}
            {step?.needsNote && (
              <TextField autoFocus={!step.needsAmount} label="Reason" required multiline minRows={2} value={note} onChange={(e) => setNote(e.target.value)} />
            )}
            {step && !step.needsNote && (
              <TextField label="Note (optional)" multiline minRows={1} value={note} onChange={(e) => setNote(e.target.value)} />
            )}
          </Stack>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setStep(null)} disabled={busy}>Cancel</Button>
          <Button variant="contained" onClick={submit} disabled={busy || amountInvalid || !!noteInvalid}>
            {busy ? 'Saving…' : step?.label}
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <Stack direction="row" justifyContent="space-between" alignItems="flex-start" sx={{ py: 0.5, gap: 2 }}>
      <Typography variant="body2" color="text.secondary">{label}</Typography>
      <Typography variant="body2" sx={{ textAlign: 'right' }}>{value}</Typography>
    </Stack>
  );
}
