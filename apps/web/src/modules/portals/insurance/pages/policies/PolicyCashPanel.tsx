import { useCallback, useEffect, useRef, useState } from 'react';
import {
  Alert, Box, Button, Card, CardContent, Chip, Dialog, DialogActions, DialogContent,
  DialogTitle, MenuItem, Stack, Table, TableBody, TableCell, TableHead, TableRow, TextField, Typography,
} from '@mui/material';
import { Link as RouterLink } from 'react-router-dom';
import { errorText, rpc } from '../../db';
import { formatMoney } from '../../logic';
import {
  policyCashActions, policyCashToday, validatePolicyCashInput, type PolicyCashBank,
  type PolicyCashDecision, type PolicyCashKind, type PolicyCashPosition, type PolicyCashRequest,
} from '../../policyCash';

interface Props { policyId: string; mode?: 'view' | 'finance' }
const labels: Record<PolicyCashDecision, string> = { approve: 'Approve and post', reject: 'Reject', cancel: 'Cancel request' };

export default function PolicyCashPanel({ policyId, mode = 'view' }: Props) {
  const [position, setPosition] = useState<PolicyCashPosition | null>(null);
  const [banks, setBanks] = useState<PolicyCashBank[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [kind, setKind] = useState<PolicyCashKind | null>(null);
  const [amount, setAmount] = useState('');
  const [shareId, setShareId] = useState('');
  const [bankId, setBankId] = useState('');
  const [date, setDate] = useState(policyCashToday());
  const [reference, setReference] = useState('');
  const [notes, setNotes] = useState('');
  const [decision, setDecision] = useState<{ request: PolicyCashRequest; action: PolicyCashDecision } | null>(null);
  const [reason, setReason] = useState('');
  // Retain the same key on retry after an uncertain network result. Any edit
  // starts a new intent, since the server rejects key/payload mismatches.
  const requestKey = useRef<string | null>(null);
  const generation = useRef(0);
  const load = useCallback(async () => {
    const current = ++generation.current;
    try {
      const data = await rpc<PolicyCashPosition>('ins_policy_cash_position', { p_policy_id: policyId });
      if (current !== generation.current) return;
      setPosition(data);
      if (mode === 'finance' && data.can_prepare) {
        const all = await rpc<PolicyCashBank[]>('ins_policy_cash_bank_accounts');
        if (current !== generation.current) return;
        setBanks(all.filter((b) => b.currency === data.currency));
      }
      setError(null);
    } catch (e) { if (current === generation.current) setError(errorText(e)); }
  }, [policyId, mode]);
  useEffect(() => {
    setPosition(null); setKind(null); setDecision(null); setBanks([]); setError(null);
    void load();
    return () => { generation.current++; };
  }, [load]);

  const canPrepare = mode === 'finance' && Boolean(position?.can_prepare);
  const open = (newKind: PolicyCashKind) => {
    setKind(newKind); setShareId(''); setAmount(''); setBankId(''); setDate(policyCashToday()); setReference(''); setNotes('');
    setError(null); requestKey.current = null;
  };
  const hasShares = Boolean(position?.shares?.length);
  const selectedShare = position?.shares?.find((s) => s.share_id === shareId);
  const maximum = Number(kind === 'remittance' ? (hasShares ? selectedShare?.maximum_remittance ?? 0 : position?.maximum_remittance ?? 0) : position?.client_outstanding ?? 0);
  const edit = (update: () => void) => { requestKey.current = null; update(); };
  const submit = async () => {
    if (!kind) return;
    if (kind === 'remittance' && hasShares && !shareId) { setError('Choose the insurer receiving this remittance.'); return; }
    const invalid = validatePolicyCashInput(amount, date, bankId, maximum, policyCashToday());
    if (invalid) { setError(invalid); return; }
    setBusy(true); setError(null);
    requestKey.current ??= crypto.randomUUID();
    try {
      if (kind === 'remittance' && hasShares) {
        await rpc('ins_submit_policy_share_cash_request', { p_policy_id: policyId, p_insurer_share_id: shareId, p_bank_account_id: bankId,
          p_amount: Number(amount), p_cash_date: date, p_request_key: requestKey.current, p_reference: reference || null, p_notes: notes || null });
      } else await rpc('ins_submit_policy_cash_request', {
        p_policy_id: policyId, p_kind: kind, p_bank_account_id: bankId, p_amount: Number(amount),
        p_cash_date: date, p_request_key: requestKey.current, p_reference: reference || null, p_notes: notes || null,
      });
      setKind(null); requestKey.current = null; await load();
    } catch (e) { setError(errorText(e)); } finally { setBusy(false); }
  };
  const decide = async () => {
    if (!decision) return;
    if (decision.action !== 'approve' && reason.trim().length < 5) { setError('Enter a reason of at least five characters.'); return; }
    setBusy(true); setError(null);
    try {
      await rpc('ins_decide_policy_cash_request', {
        p_request_id: decision.request.id, p_decision: decision.action, p_reason: reason.trim() || null,
      });
      setDecision(null); await load();
    } catch (e) { setError(errorText(e)); } finally { setBusy(false); }
  };

  return <Box sx={{ mt: 3 }}>
    <Stack direction="row" spacing={2} alignItems="center" sx={{ mb: 1 }}>
      <Typography variant="h6">Premium receipts & insurer remittances</Typography>
      <Button onClick={() => void load()} disabled={busy}>Refresh cash status</Button>
    </Stack>
    {error && !kind && !decision && <Alert severity="error" sx={{ mb: 1 }}>{error}</Alert>}
    {!position ? <Typography>Loading cash position…</Typography> : <>
      <Alert severity="info" sx={{ mb: 2 }}>
        Finance maker → different Finance checker (approval posts the settlement) → third Finance reconciler.
        Pending requests do not post or reserve funds. Insurance access alone is read-only.
      </Alert>
      <Card variant="outlined"><CardContent>
        <Stack direction="row" useFlexGap flexWrap="wrap" spacing={3}>
          {([
            ['Client money collected', position.collected], ['Remitted to insurer', position.remitted],
            ['Available allocated funds', position.available_allocated_funds], ['Client still owes', position.client_outstanding],
            ['Outstanding insurer liability', position.insurer_outstanding], ['Maximum remittance now', position.maximum_remittance],
          ] as const).map(([label, value]) => <Box key={label}><Typography variant="caption">{label}</Typography>
            <Typography>{formatMoney(value, position.currency)}</Typography></Box>)}
        </Stack>
        <Typography variant="body2" sx={{ mt: 2 }}>
          Commission: {formatMoney(position.commission_amount, position.currency)} · {position.commission_status ?? 'not applicable'}.
          {' '}Transferred: {formatMoney(position.commission_transferred, position.currency)}. Collections are not commission income.
          {' '}Available funds = allocated collections less effective remittances and commission already withdrawn.
          {' '}Maximum remittance = min(available allocated funds, outstanding insurer liability).
        </Typography>
        {canPrepare && ['active', 'renewed'].includes(position.policy_status) && <Stack direction="row" spacing={1} sx={{ mt: 2 }}>
          <Button variant="outlined" disabled={busy || Number(position.client_outstanding) <= 0} onClick={() => open('receipt')}>Prepare premium receipt</Button>
          <Button variant="outlined" disabled={busy || Number(position.maximum_remittance) <= 0} onClick={() => open('remittance')}>Prepare insurer remittance</Button>
        </Stack>}
        {mode === 'finance' && !position.can_prepare && <Alert severity="warning">Authorized Finance membership is required. This view cannot prepare or approve cash.</Alert>}
        {mode === 'view' && position.can_prepare && <Button component={RouterLink} to={`/financial-management/insurance-premium-cash?policy=${encodeURIComponent(policyId)}`}>
          Open Finance cash workflow
        </Button>}
        {canPrepare && <Button component={RouterLink} to="/financial-management/bank-reconciliation" sx={{ mt: 1 }}>Bank reconciliation (independent third user)</Button>}
      </CardContent></Card>
      {hasShares && <Box sx={{ mt: 2, overflowX: 'auto' }}><Typography variant="subtitle1">Per-insurer pro-rata funding</Typography>
        <Typography variant="body2">Collections are apportioned across premium and charge components; broker fees and VAT are excluded from insurer funding. Partial funding is rounded down to cents until full collection.</Typography>
        <Table size="small"><TableHead><TableRow><TableCell>Insurer</TableCell><TableCell>Funded</TableCell><TableCell>Remitted</TableCell><TableCell>Outstanding</TableCell><TableCell>Maximum remittance</TableCell></TableRow></TableHead>
        <TableBody>{position.shares?.map((s) => <TableRow key={s.share_id}><TableCell>{s.insurer_name} {s.is_lead ? '(lead)' : ''} · {s.share_pct}%</TableCell><TableCell>{formatMoney(s.funded, position.currency)}</TableCell><TableCell>{formatMoney(s.remitted, position.currency)}</TableCell><TableCell>{formatMoney(s.outstanding, position.currency)}</TableCell><TableCell>{formatMoney(s.maximum_remittance, position.currency)}</TableCell></TableRow>)}</TableBody></Table></Box>}
      <Box sx={{ overflowX: 'auto', mt: 2 }}><Table size="small" aria-label="Policy cash requests">
        <TableHead><TableRow><TableCell>Request / bank / reference</TableCell><TableCell>Cash date / amount</TableCell>
          <TableCell>Approval evidence</TableCell><TableCell>Posting / reconciliation</TableCell><TableCell>Actions</TableCell>
        </TableRow></TableHead><TableBody>
          {position.requests.length === 0 && <TableRow><TableCell colSpan={5}>No cash requests yet. The totals also include any historical Finance settlements.</TableCell></TableRow>}
          {position.requests.map((q) => <TableRow key={q.id}>
            <TableCell>{q.kind === 'receipt' ? 'Premium receipt' : 'Insurer remittance'}<Typography variant="caption" display="block">{q.insurer_name ? `${q.insurer_name} · ` : ''}{q.bank_name} · {q.reference || 'No reference'}</Typography>
              {q.notes && <Typography variant="caption" display="block">{q.notes}</Typography>}</TableCell>
            <TableCell>{q.cash_date}<Typography>{formatMoney(q.amount, position.currency)}</Typography></TableCell>
            <TableCell><Chip size="small" label={q.status} />
              <Typography variant="caption" display="block">Maker: {q.maker_id}</Typography>
              {q.checker_id && <Typography variant="caption" display="block">Checker / poster: {q.checker_id}</Typography>}
              <Typography variant="caption" display="block">Submitted {new Date(q.created_at).toLocaleString()}</Typography>
              {q.checked_at && <Typography variant="caption" display="block">Decided {new Date(q.checked_at).toLocaleString()}</Typography>}
              {q.decision_reason && <Typography variant="caption" display="block">{q.decision_reason}</Typography>}
            </TableCell>
            <TableCell>{q.settlement_no || 'Not posted'}
              {q.status === 'posted' && <Typography variant="caption" display="block">{q.reconciled ? 'Bank reconciled' : 'Awaiting independent bank reconciliation'}</Typography>}
              {q.reconciled_by && <Typography variant="caption" display="block">Reconciler: {q.reconciled_by}</Typography>}
            </TableCell>
            <TableCell>{canPrepare && policyCashActions(position, q).map((action) => <Button key={action} size="small" disabled={busy}
              onClick={() => { setDecision({ request: q, action }); setReason(''); setError(null); }}>{labels[action]}</Button>)}</TableCell>
          </TableRow>)}
        </TableBody></Table></Box>
    </>}

    <Dialog open={kind !== null} onClose={() => !busy && setKind(null)} maxWidth="sm" fullWidth>
      <DialogTitle>Prepare {kind === 'receipt' ? 'premium receipt' : 'insurer remittance'}</DialogTitle>
      <DialogContent>
        <Alert severity="info" sx={{ mb: 2 }}>Submission does not post cash. Another authorized Finance user must approve it. Current limit: {formatMoney(maximum, position?.currency ?? 'UGX')}.</Alert>
        {error && <Alert severity="error" sx={{ mb: 2 }}>{error}</Alert>}
        <Stack spacing={2} sx={{ mt: 1 }}>
          {kind === 'remittance' && hasShares && <TextField select label="Insurer to remit to" value={shareId} onChange={(e) => edit(() => setShareId(e.target.value))} disabled={busy}>
            {position?.shares?.map((s) => <MenuItem key={s.share_id} value={s.share_id}>{s.insurer_name} — available {formatMoney(s.maximum_remittance, position?.currency ?? 'UGX')}</MenuItem>)}
          </TextField>}
          <TextField select label="Client-money bank account" value={bankId} onChange={(e) => edit(() => setBankId(e.target.value))} disabled={busy}>
            {banks.map((b) => <MenuItem key={b.id} value={b.id}>{b.name} ({b.currency})</MenuItem>)}
          </TextField>
          <TextField label="Amount" value={amount} onChange={(e) => edit(() => setAmount(e.target.value))} inputProps={{ inputMode: 'decimal' }} disabled={busy} />
          <TextField label="Cash date" type="date" value={date} onChange={(e) => edit(() => setDate(e.target.value))} InputLabelProps={{ shrink: true }} inputProps={{ max: policyCashToday() }} disabled={busy} />
          <TextField label="Bank reference" value={reference} onChange={(e) => edit(() => setReference(e.target.value))} disabled={busy} />
          <TextField label="Notes" multiline value={notes} onChange={(e) => edit(() => setNotes(e.target.value))} disabled={busy} />
        </Stack>
      </DialogContent><DialogActions><Button onClick={() => setKind(null)} disabled={busy}>Close</Button>
        <Button variant="contained" onClick={() => void submit()} disabled={busy}>Submit for approval</Button></DialogActions>
    </Dialog>
    <Dialog open={decision !== null} onClose={() => !busy && setDecision(null)} maxWidth="sm" fullWidth>
      <DialogTitle>{decision && labels[decision.action]}</DialogTitle>
      <DialogContent>
        {error && <Alert severity="error" sx={{ mb: 2 }}>{error}</Alert>}
        {decision && <>
          <Typography>{decision.request.kind === 'receipt' ? 'Premium receipt' : 'Insurer remittance'} · {formatMoney(decision.request.amount, position?.currency ?? 'UGX')}</Typography>
          <Typography>{decision.request.insurer_name ? `${decision.request.insurer_name} · ` : ''}{decision.request.bank_name} · {decision.request.cash_date} · {decision.request.reference || 'No reference'}</Typography>
          <Typography sx={{ mb: 2 }}>{decision.request.notes}</Typography>
          {decision.action === 'approve' ? <Alert severity="warning">Approval immediately posts one Finance settlement and its journal. A third Finance user must reconcile it. Balances and policy eligibility are rechecked atomically.</Alert>
            : <TextField label="Decision reason" value={reason} onChange={(e) => setReason(e.target.value)} fullWidth multiline disabled={busy} />}
        </>}
      </DialogContent><DialogActions><Button onClick={() => setDecision(null)} disabled={busy}>Close</Button>
        <Button variant="contained" onClick={() => void decide()} disabled={busy}>{decision && labels[decision.action]}</Button></DialogActions>
    </Dialog>
  </Box>;
}
