import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Alert, Box, Button, Card, CardContent, Chip, Dialog, DialogActions, DialogContent, DialogContentText, DialogTitle,
  MenuItem, Stack, Table, TableBody, TableCell, TableHead, TableRow, TextField, Typography,
} from '@mui/material';
import { errorText, rows, rpc, table } from '../../db';
import {
  CLAIM_PAYMENT_KIND_LABEL, CLAIM_PAYMENT_MODE_HELP, CLAIM_PAYMENT_MODE_LABEL, claimRemainingToPay, formatMoney,
  isValidVoidReason, validateClaimMoneyInput, type ClaimMoneyKind,
} from '../../logic';
import type { Claim, ClaimCashPosition, ClaimPayment, TransferBankAccount } from '../../types';
import { ErrorBanner } from '../../shared';

interface Props {
  claim: Claim;
  currency: string;
  canManage: boolean;
  /** Called after any change so the parent reloads the claim and its history. */
  onChanged: () => void;
}

const todayIso = () => new Date().toISOString().slice(0, 10);

// How a claim gets paid, and the actions that follow from it. The server decides
// everything (ins_record_claim_payment / _receipt / _payout / ins_void_claim_payment);
// this panel only mirrors its rules so the user sees the problem before submitting.
export default function ClaimPayments({ claim, currency, canManage, onChanged }: Props) {
  const mode = claim.payment_mode;
  const [payments, setPayments] = useState<ClaimPayment[]>([]);
  const [position, setPosition] = useState<ClaimCashPosition | null>(null);
  const [banks, setBanks] = useState<TransferBankAccount[]>([]);
  const [error, setError] = useState<string | null>(null);

  const [action, setAction] = useState<ClaimMoneyKind | null>(null);
  const [amount, setAmount] = useState('');
  const [date, setDate] = useState(todayIso());
  const [reference, setReference] = useState('');
  const [notes, setNotes] = useState('');
  const [bankId, setBankId] = useState('');
  const [voiding, setVoiding] = useState<ClaimPayment | null>(null);
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    try {
      setPayments(await rows<ClaimPayment>(table('ins_claim_payments').select('*').eq('claim_id', claim.id).order('created_at', { ascending: true })));
      const [pos] = await rows<ClaimCashPosition>(table('ins_claim_cash_position').select('*').eq('claim_id', claim.id));
      setPosition(pos ?? null);
      setError(null);
    } catch (e) {
      setError(errorText(e));
    }
  }, [claim.id]);

  useEffect(() => {
    load();
  }, [load, claim.status, claim.paid_amount]);

  // Only the brokerage-managed flow needs a bank account, and only managers can list them.
  useEffect(() => {
    if (mode !== 'via_broker' || !canManage) return;
    rpc<TransferBankAccount[]>('ins_commission_bank_accounts')
      .then((all) => setBanks(all.filter((b) => b.kind === 'client_money')))
      .catch((e) => setError(errorText(e)));
  }, [mode, canManage]);

  const approved = claim.approved_amount;
  const unpaid = claimRemainingToPay(approved, claim.paid_amount);
  const held = Number(position?.held_for_client ?? 0);
  const dueFromInsurer = Number(position?.due_from_insurer ?? 0);
  const isOpenForPayment = claim.status === 'approved' && canManage;

  const maxFor = (kind: ClaimMoneyKind) => (kind === 'direct' ? unpaid : kind === 'receipt' ? dueFromInsurer : held);

  const openAction = (kind: ClaimMoneyKind) => {
    setAction(kind);
    setAmount(String(maxFor(kind) || ''));
    setDate(todayIso());
    setReference('');
    setNotes('');
    setBankId(banks.length === 1 ? banks[0].id : '');
    setError(null);
  };

  const problems = useMemo(
    () => (action
      ? validateClaimMoneyInput({
          kind: action, amount: Number(amount), max: maxFor(action), currency, date, todayIso: todayIso(),
          notifiedIso: claim.notified_date, reference, bankId,
        })
      : []),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [action, amount, date, reference, bankId, unpaid, held, dueFromInsurer, currency, claim.notified_date],
  );

  const submit = async () => {
    if (!action) return;
    setBusy(true);
    setError(null);
    try {
      const common = { p_claim_id: claim.id, p_amount: Number(amount), p_reference: reference.trim() || null, p_notes: notes.trim() || null };
      if (action === 'direct') {
        await rpc('ins_record_claim_payment', { ...common, p_payment_date: date, p_reference: reference.trim() });
      } else if (action === 'receipt') {
        await rpc('ins_record_claim_receipt', { ...common, p_bank_account_id: bankId, p_receipt_date: date });
      } else {
        await rpc('ins_record_claim_payout', { ...common, p_bank_account_id: bankId, p_payment_date: date });
      }
      setAction(null);
      await load();
      onChanged();
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  };

  const submitVoid = async () => {
    if (!voiding) return;
    setBusy(true);
    setError(null);
    try {
      await rpc('ins_void_claim_payment', { p_payment_id: voiding.id, p_reason: reason.trim() });
      setVoiding(null);
      setReason('');
      await load();
      onChanged();
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  };

  // Nothing to show until the claim has been approved (that is when the mode is fixed).
  if (!mode || approved == null) return null;

  const dialogTitle = action === 'direct' ? 'Record insurer payment' : action === 'receipt' ? 'Record receipt from insurer' : 'Pay the client';
  const dialogHelp = action === 'direct'
    ? 'Record a payment the insurer has made to the client. Nothing is posted to the ledger.'
    : action === 'receipt'
      ? 'Money the insurer has paid into your client-money account for this claim. Posts to the ledger.'
      : 'Pays the client out of your client-money account. Only money already received from the insurer can be paid out. Posts to the ledger.';

  return (
    <>
      <Typography variant="h6" sx={{ mt: 3, mb: 1 }}>Payment</Typography>
      <Card variant="outlined">
        <CardContent>
          <Stack direction="row" spacing={1} alignItems="center" sx={{ mb: 1 }}>
            <Chip size="small" color={mode === 'via_broker' ? 'primary' : 'default'} label={CLAIM_PAYMENT_MODE_LABEL[mode]} />
          </Stack>
          <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>{CLAIM_PAYMENT_MODE_HELP[mode]}</Typography>
          <ErrorBanner message={action || voiding ? null : error} />

          {mode === 'insurer_direct' ? (
            <>
              <Line label="Approved" value={formatMoney(approved, currency)} />
              <Line label="Paid by the insurer" value={formatMoney(claim.paid_amount, currency)} />
              <Line label="Still unpaid" value={formatMoney(unpaid, currency)} />
            </>
          ) : (
            <>
              <Line label="Approved" value={formatMoney(approved, currency)} />
              <Line label="Received from the insurer" value={formatMoney(position?.received_from_insurer ?? 0, currency)} />
              <Line label="Still due from the insurer" value={formatMoney(dueFromInsurer, currency)} />
              <Line label="Paid to the client" value={formatMoney(claim.paid_amount, currency)} />
              <Line label="Held for the client" value={formatMoney(held, currency)} />
            </>
          )}

          {isOpenForPayment && (
            <Stack direction="row" spacing={1} sx={{ mt: 2 }} flexWrap="wrap" useFlexGap>
              {mode === 'insurer_direct' ? (
                <Button variant="contained" onClick={() => openAction('direct')} disabled={unpaid <= 0}>Record insurer payment</Button>
              ) : (
                <>
                  <Button variant="contained" onClick={() => openAction('receipt')} disabled={dueFromInsurer <= 0}>Record receipt from insurer</Button>
                  <Button variant="outlined" onClick={() => openAction('payout')} disabled={held <= 0}>Pay client</Button>
                </>
              )}
            </Stack>
          )}
          {mode === 'via_broker' && isOpenForPayment && held <= 0 && dueFromInsurer > 0 && (
            <Typography variant="caption" color="text.secondary" sx={{ display: 'block', mt: 1 }}>
              The client can be paid once the insurer's money has been received.
            </Typography>
          )}

          {payments.length > 0 && (
            <Box sx={{ mt: 2, overflowX: 'auto' }}>
              <Table size="small">
                <TableHead>
                  <TableRow>
                    <TableCell>Date</TableCell>
                    <TableCell>What</TableCell>
                    <TableCell>Reference</TableCell>
                    <TableCell align="right">Amount</TableCell>
                    <TableCell>Status</TableCell>
                    {canManage && claim.status !== 'closed' && <TableCell align="right" />}
                  </TableRow>
                </TableHead>
                <TableBody>
                  {payments.map((p) => (
                    <TableRow key={p.id} sx={p.status === 'void' ? { opacity: 0.55 } : undefined}>
                      <TableCell>{p.payment_date}</TableCell>
                      <TableCell>{CLAIM_PAYMENT_KIND_LABEL[p.kind]}</TableCell>
                      <TableCell>{p.reference ?? '-'}</TableCell>
                      <TableCell align="right">{formatMoney(p.amount, currency)}</TableCell>
                      <TableCell>
                        <Chip size="small" variant="outlined" label={p.status === 'void' ? 'Void' : 'Posted'} color={p.status === 'void' ? 'default' : 'success'} />
                        {p.status === 'void' && p.void_reason && (
                          <Typography variant="caption" color="text.secondary" sx={{ display: 'block' }}>{p.void_reason}</Typography>
                        )}
                      </TableCell>
                      {canManage && claim.status !== 'closed' && (
                        <TableCell align="right">
                          {p.status === 'posted' && (
                            <Button size="small" color="error" onClick={() => { setVoiding(p); setReason(''); setError(null); }}>Void</Button>
                          )}
                        </TableCell>
                      )}
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </Box>
          )}
        </CardContent>
      </Card>

      <Dialog open={action !== null} onClose={() => !busy && setAction(null)} fullWidth maxWidth="sm">
        <DialogTitle>{dialogTitle}</DialogTitle>
        <DialogContent>
          <DialogContentText sx={{ mb: 2 }}>{dialogHelp}</DialogContentText>
          <ErrorBanner message={error} />
          <Stack spacing={2} sx={{ mt: 1 }}>
            {action && action !== 'direct' && (
              <TextField select label="Client-money bank account" required value={bankId} onChange={(e) => setBankId(e.target.value)}
                helperText={banks.length === 0 ? 'No client-money bank account is set up. Ask Finance to add one.' : undefined}>
                {banks.map((b) => <MenuItem key={b.id} value={b.id}>{b.name}{b.bank_name ? ` · ${b.bank_name}` : ''}</MenuItem>)}
              </TextField>
            )}
            <TextField autoFocus label={`Amount (${currency})`} type="number" value={amount} onChange={(e) => setAmount(e.target.value)}
              inputProps={{ min: 0, step: '0.01' }} />
            <TextField label="Date" type="date" value={date} onChange={(e) => setDate(e.target.value)} InputLabelProps={{ shrink: true }} />
            <TextField label={action === 'direct' ? "Insurer's payment reference" : 'Reference (optional)'} required={action === 'direct'}
              value={reference} onChange={(e) => setReference(e.target.value)} />
            <TextField label="Notes (optional)" multiline minRows={1} value={notes} onChange={(e) => setNotes(e.target.value)} />
            {problems.length > 0 && amount !== '' && <Alert severity="warning">{problems[0]}</Alert>}
          </Stack>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setAction(null)} disabled={busy}>Cancel</Button>
          <Button variant="contained" onClick={submit} disabled={busy || problems.length > 0}>{busy ? 'Saving…' : 'Save'}</Button>
        </DialogActions>
      </Dialog>

      <Dialog open={voiding !== null} onClose={() => !busy && setVoiding(null)} fullWidth maxWidth="sm">
        <DialogTitle>Void this payment</DialogTitle>
        <DialogContent>
          <DialogContentText sx={{ mb: 2 }}>
            {voiding && voiding.kind !== 'insurer_direct'
              ? 'The bank entry is reversed in the ledger. A receipt that has already been paid out to the client cannot be voided until that payout is voided.'
              : 'The payment is removed from the total paid. If it had settled the claim, the claim goes back to approved.'}
          </DialogContentText>
          <ErrorBanner message={error} />
          <TextField autoFocus fullWidth label="Reason" required multiline minRows={2} value={reason} onChange={(e) => setReason(e.target.value)}
            helperText="At least 5 characters." sx={{ mt: 1 }} />
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setVoiding(null)} disabled={busy}>Cancel</Button>
          <Button variant="contained" color="error" onClick={submitVoid} disabled={busy || !isValidVoidReason(reason)}>{busy ? 'Voiding…' : 'Void payment'}</Button>
        </DialogActions>
      </Dialog>
    </>
  );
}

function Line({ label, value }: { label: string; value: string }) {
  return (
    <Stack direction="row" justifyContent="space-between" sx={{ py: 0.5, gap: 2 }}>
      <Typography variant="body2" color="text.secondary">{label}</Typography>
      <Typography variant="body2">{value}</Typography>
    </Stack>
  );
}
