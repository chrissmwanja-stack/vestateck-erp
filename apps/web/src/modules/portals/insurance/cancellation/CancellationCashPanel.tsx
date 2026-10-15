import { useCallback, useEffect, useRef, useState } from 'react';
import {
  Alert,
  Box,
  Button,
  CircularProgress,
  Dialog,
  DialogActions,
  DialogContent,
  DialogTitle,
  MenuItem,
  Stack,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableRow,
  TextField,
  Typography,
} from '@mui/material';
import { Link as RouterLink } from 'react-router-dom';
import { rpc, errorText } from '../db';
import { policyCashToday } from '../policyCash';
import {
  CASH_KINDS,
  cashActions,
  cashMaximum,
  insurerCash,
  pairedCash,
  parseCashContext,
  validateCashAmount,
  type CancellationCashContext,
  type CancellationCashKind,
  type CancellationCashRequest,
} from './cashWorkflow';

export default function CancellationCashPanel({
  policyId,
  mode = 'view',
}: {
  policyId: string;
  mode?: 'view' | 'finance';
}) {
  const [context, setContext] = useState<CancellationCashContext | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const inFlight = useRef(false);
  const generation = useRef(0);
  const [offset, setOffset] = useState(0);
  const [bank, setBank] = useState('');
  const [kind, setKind] = useState<CancellationCashKind>('refund');
  const [adjustment, setAdjustment] = useState('');
  const [form, setForm] = useState(false);
  const [amount, setAmount] = useState('');
  const [destination, setDestination] = useState('');
  const [reference, setReference] = useState('');
  const [notes, setNotes] = useState('');
  const [decision, setDecision] = useState<{
    row: CancellationCashRequest;
    action: string;
  } | null>(null);
  const [review, setReview] = useState('');
  const retry = useRef({ fingerprint: '', key: '' });
  const voidRetry = useRef({ fingerprint: '', key: '' });
  const load = useCallback(async () => {
    const g = ++generation.current;
    setLoading(true);
    try {
      const data = parseCashContext(
        await rpc<unknown>('ins_cancellation_cash_context', {
          p_policy_id: policyId,
          p_bank_account_id: bank || null,
          p_offset: offset,
        }),
        policyId,
      );
      if (g === generation.current) {
        setContext(data);
        setError(null);
      }
    } catch (e) {
      if (g === generation.current) {
        setContext(null);
        setError(errorText(e));
      }
    } finally {
      if (g === generation.current) setLoading(false);
    }
  }, [policyId, bank, offset]);
  useEffect(() => {
    void load();
    return () => {
      generation.current++;
    };
  }, [load]);
  useEffect(() => {
    setForm(false);
    setDecision(null);
    setBank('');
    setOffset(0);
    retry.current = { fingerprint: '', key: '' };
  }, [policyId]);
  const finance = mode === 'finance' && Boolean(context?.can_finance);
  const maximum = context ? cashMaximum(context, kind, adjustment) : '0';
  const sourceKind =
    kind === 'commission_return' ? 'operating' : 'client_money';
  const destinationKind =
    kind === 'commission_return' ? 'client_money' : 'operating';
  const readyBank = Boolean(
    context &&
    context.selected_bank_id === bank &&
    context.banks.some((b) => b.id === bank && b.kind === sourceKind),
  );
  const run = async (action: () => Promise<void>) => {
    if (inFlight.current) return;
    inFlight.current = true;
    setBusy(true);
    setError(null);
    try {
      await action();
    } catch (e) {
      setError(errorText(e));
    } finally {
      inFlight.current = false;
      setBusy(false);
    }
  };
  const submit = () =>
    void run(async () => {
      if (!context || !finance || !readyBank || loading)
        throw new Error(
          'Select and refresh the correct Finance bank before submitting.',
        );
      validateCashAmount(amount, maximum);
      if (
        reference.trim().length < 3 ||
        notes.trim().length < 5 ||
        (insurerCash(kind) && !adjustment) ||
        (pairedCash(kind) && !destination)
      )
        throw new Error(
          'Select the insurer/destination where applicable and record the reference and detailed verified purpose.',
        );
      const args = {
        p_cancellation_id: context.cancellation_id,
        p_kind: kind,
        p_adjustment_id: insurerCash(kind) ? adjustment : null,
        p_bank_account_id: bank,
        p_to_bank_account_id: pairedCash(kind) ? destination : null,
        p_amount: amount,
        p_cash_date: policyCashToday(),
        p_reference: reference.trim(),
        p_notes: notes.trim(),
      };
      const fingerprint = JSON.stringify(args);
      if (retry.current.fingerprint !== fingerprint)
        retry.current = { fingerprint, key: crypto.randomUUID() };
      await rpc('ins_submit_cancellation_cash', {
        ...args,
        p_request_key: retry.current.key,
      });
      setForm(false);
      setAmount('');
      setOffset(0);
      await load();
    });
  const decide = () =>
    void run(async () => {
      if (!decision || !finance || review.trim().length < 5) return;
      if (decision.action === 'void') {
        const fingerprint = JSON.stringify([decision.row.id, review.trim()]);
        if (voidRetry.current.fingerprint !== fingerprint)
          voidRetry.current = { fingerprint, key: crypto.randomUUID() };
        await rpc('ins_submit_cancellation_cash_void', {
          p_request_id: decision.row.id,
          p_reason: review.trim(),
          p_request_key: voidRetry.current.key,
        });
      } else
        await rpc('ins_decide_cancellation_cash', {
          p_request_id: decision.row.id,
          p_decision: decision.action,
          p_reason: review.trim(),
        });
      setDecision(null);
      await load();
    });
  return (
    <Box sx={{ mt: 2, borderTop: '1px solid', borderColor: 'divider', pt: 2 }}>
      <Typography variant="h6">Cancellation recoveries & payments</Typography>
      <Alert severity="info">
        Cancellation approval is not cash approval. A Finance maker prepares
        each movement; a different Finance checker posts it. A third Finance
        user reconciles it. Only exact reconciled incoming funds are usable;
        commission returns require both bank legs matched.
      </Alert>
      {error && (
        <Alert severity="error" sx={{ mt: 1 }}>
          {error}
        </Alert>
      )}
      <Button onClick={() => void load()} disabled={busy || loading}>
        Refresh cancellation cash
      </Button>
      {loading && (
        <CircularProgress size={20} aria-label="Loading cancellation cash" />
      )}
      {context && (
        <>
          {context.bank_funding_sound === false && (
            <Alert severity="error">
              A client-bank book shortfall is not attributed to a policy.
              Outgoing payments are blocked to protect other policies and
              claims. Finance must resolve the shortfall first.
            </Alert>
          )}
          <Typography variant="body2">
            Verified client-money cash: {context.proven_cash} {context.currency}{' '}
            · Client refund outstanding: {context.client_refund_outstanding} ·
            Insurer liabilities: {context.insurer_payable_reserve} · Commission
            reserve: {context.commission_reserve} · Retained fee/VAT reserve:{' '}
            {context.retained_fee_vat_reserve}
          </Typography>
          <Typography variant="caption" display="block">
            These are policy-specific balances, not the bank's unrestricted
            funds. Incoming receipts remain unavailable until independently
            matched. Pending requests reserve nothing; approval rechecks all
            limits.
          </Typography>
          <Table size="small" aria-label="Cancellation insurer cash positions">
            <TableHead>
              <TableRow>
                <TableCell>Insurer</TableCell>
                <TableCell>Recovery outstanding</TableCell>
                <TableCell>Commission return due</TableCell>
                <TableCell>Retained payable</TableCell>
                <TableCell>Retained commission</TableCell>
                <TableCell>Funded gross / spent</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {context.insurers.map((a) => (
                <TableRow key={a.adjustment_id}>
                  <TableCell>{a.insurer_name}</TableCell>
                  <TableCell>{a.recovery_due}</TableCell>
                  <TableCell>{a.commission_return_due}</TableCell>
                  <TableCell>{a.outstanding}</TableCell>
                  <TableCell>
                    {a.retained_commission} · {a.commission_status}
                  </TableCell>
                  <TableCell>
                    {a.funded_gross} / {a.spent}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
          {finance ? (
            <Stack direction="row" spacing={1} sx={{ my: 1 }}>
              <Button
                variant="outlined"
                disabled={busy || loading}
                onClick={() => {
                  setForm(true);
                  setAmount('');
                }}
              >
                Prepare cancellation cash
              </Button>
              <Button
                component={RouterLink}
                to="/financial-management/bank-reconciliation"
              >
                Bank reconciliation — third Finance user
              </Button>
            </Stack>
          ) : (
            <>
              <Typography variant="body2">
                Read-only cash status. Insurance permissions cannot prepare,
                approve or reconcile payments.
              </Typography>
              {context.can_finance && (
                <Button
                  component={RouterLink}
                  to={`/financial-management/insurance-premium-cash?policy=${encodeURIComponent(policyId)}`}
                >
                  Open Finance cancellation cash
                </Button>
              )}
            </>
          )}
          <Table size="small" aria-label="Cancellation cash requests">
            <TableHead>
              <TableRow>
                <TableCell>Movement / amount</TableCell>
                <TableCell>Evidence</TableCell>
                <TableCell>Maker / checker</TableCell>
                <TableCell>Bank matching</TableCell>
                <TableCell>Actions</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {context.requests.map((row) => (
                <TableRow key={row.id}>
                  <TableCell>
                    {row.kind === 'void'
                      ? 'Void request'
                      : CASH_KINDS[row.kind]}{' '}
                    · {row.amount} {context.currency}
                    <Typography variant="caption" display="block">
                      {row.status} · {row.cash_date}
                    </Typography>
                  </TableCell>
                  <TableCell>
                    {row.reference}
                    <Typography variant="caption" display="block">
                      {row.notes}
                    </Typography>
                    <Typography variant="caption" display="block">
                      {row.decision_reason}
                    </Typography>
                    {row.settlement_no && (
                      <Typography variant="caption" display="block">
                        Settlement: {row.settlement_no}
                        {row.destination_settlement_no
                          ? ` / ${row.destination_settlement_no}`
                          : ''}
                      </Typography>
                    )}
                    {row.voids_request_id && (
                      <Typography variant="caption" display="block">
                        Corrects request {row.voids_request_id}
                      </Typography>
                    )}
                    {row.journals.map((j) => (
                      <Typography
                        variant="caption"
                        display="block"
                        key={j.journal_entry_id}
                      >
                        {j.purpose}: {j.journal_entry_id}
                      </Typography>
                    ))}
                  </TableCell>
                  <TableCell>
                    <Typography variant="caption" display="block">
                      Maker: {row.maker_id}
                    </Typography>
                    <Typography variant="caption" display="block">
                      Checker:{' '}
                      {row.checker_id ?? 'Awaiting independent Finance checker'}
                    </Typography>
                  </TableCell>
                  <TableCell>
                    {row.settlement_id
                      ? row.matched
                        ? 'Exact bank match'
                        : 'Not bank matched'
                      : 'No settlement'}
                    {row.to_settlement_id && (
                      <Typography variant="caption" display="block">
                        Destination:{' '}
                        {row.destination_matched
                          ? 'exact bank match'
                          : 'not matched'}
                      </Typography>
                    )}
                  </TableCell>
                  <TableCell>
                    {cashActions(context, row, mode).map((action) => (
                      <Button
                        key={action}
                        size="small"
                        disabled={busy || loading}
                        onClick={() => {
                          setReview('');
                          setDecision({ row, action });
                        }}
                      >
                        {action === 'void' ? 'Request correction void' : action}
                      </Button>
                    ))}
                  </TableCell>
                </TableRow>
              ))}
              {!context.requests.length && (
                <TableRow>
                  <TableCell colSpan={5}>
                    No cancellation cash requests.
                  </TableCell>
                </TableRow>
              )}
            </TableBody>
          </Table>
          <Stack direction="row">
            <Button
              disabled={busy || loading || offset === 0}
              onClick={() => setOffset((x) => Math.max(x - 25, 0))}
            >
              Previous cash requests
            </Button>
            <Button
              disabled={busy || loading || !context.has_more}
              onClick={() => setOffset((x) => x + 25)}
            >
              Next cash requests
            </Button>
          </Stack>
        </>
      )}
      <Dialog
        open={form && finance}
        onClose={() => {
          if (!busy) setForm(false);
        }}
        fullWidth
        maxWidth="md"
      >
        <DialogTitle>
          Prepare cancellation cash request — not a payment
        </DialogTitle>
        <DialogContent>
          {error && <Alert severity="error">{error}</Alert>}
          <Stack spacing={2} sx={{ mt: 1 }}>
            <TextField
              select
              label="Cash movement"
              value={kind}
              disabled={busy}
              onChange={(e) => {
                setKind(e.target.value as CancellationCashKind);
                setAmount('');
                setAdjustment('');
                setBank('');
                setDestination('');
              }}
            >
              {Object.entries(CASH_KINDS).map(([key, name]) => (
                <MenuItem key={key} value={key}>
                  {name}
                </MenuItem>
              ))}
            </TextField>
            {insurerCash(kind) && (
              <TextField
                select
                label="Insurer cancellation adjustment"
                value={adjustment}
                disabled={busy}
                onChange={(e) => {
                  setAdjustment(e.target.value);
                  setAmount('');
                }}
              >
                {context?.insurers.map((a) => (
                  <MenuItem key={a.adjustment_id} value={a.adjustment_id}>
                    {a.insurer_name}
                  </MenuItem>
                ))}
              </TextField>
            )}
            <TextField
              select
              label="Source / receipt bank"
              value={bank}
              disabled={busy}
              onChange={(e) => {
                setBank(e.target.value);
                setAmount('');
              }}
            >
              {context?.banks
                .filter((b) => b.kind === sourceKind)
                .map((b) => (
                  <MenuItem key={b.id} value={b.id}>
                    {b.name} ({b.currency})
                  </MenuItem>
                ))}
            </TextField>
            {pairedCash(kind) && (
              <TextField
                select
                label="Destination bank"
                value={destination}
                disabled={busy}
                onChange={(e) => setDestination(e.target.value)}
              >
                {context?.banks
                  .filter((b) => b.kind === destinationKind)
                  .map((b) => (
                    <MenuItem key={b.id} value={b.id}>
                      {b.name} ({b.currency})
                    </MenuItem>
                  ))}
              </TextField>
            )}
            <Typography>
              Current server limit for this bank/action:{' '}
              {readyBank && !loading ? maximum : 'Select bank and refresh'}{' '}
              {context?.currency}
            </Typography>
            <TextField
              label="Exact cash amount"
              value={amount}
              disabled={busy || loading}
              onChange={(e) => setAmount(e.target.value)}
              inputProps={{ inputMode: 'decimal' }}
            />
            <TextField
              label="Bank / beneficiary reference"
              value={reference}
              disabled={busy}
              onChange={(e) => setReference(e.target.value)}
              inputProps={{ maxLength: 200 }}
            />
            <TextField
              label="Verified purpose and beneficiary / insurer evidence"
              multiline
              minRows={2}
              value={notes}
              disabled={busy}
              onChange={(e) => setNotes(e.target.value)}
              inputProps={{ maxLength: 2000 }}
            />
            <Alert severity="warning">
              Submission creates only a pending request. Approval posts the
              exact movement. It does not send a bank instruction. Verify the
              actual beneficiary and bank transaction. Recovery receivables and
              commission income are not cash. Returns must use the original
              operating bank.
            </Alert>
          </Stack>
        </DialogContent>
        <DialogActions>
          <Button disabled={busy} onClick={() => setForm(false)}>
            Close
          </Button>
          <Button
            disabled={
              busy ||
              loading ||
              !readyBank ||
              !amount ||
              reference.trim().length < 3 ||
              notes.trim().length < 5 ||
              (pairedCash(kind) && !destination) ||
              (insurerCash(kind) && !adjustment)
            }
            onClick={submit}
          >
            Submit cash proposal only
          </Button>
        </DialogActions>
      </Dialog>
      <Dialog
        open={Boolean(decision) && finance}
        onClose={() => {
          if (!busy) setDecision(null);
        }}
        fullWidth
        maxWidth="sm"
      >
        <DialogTitle>
          {decision?.action === 'void'
            ? 'Request an independently checked correction void'
            : `${decision?.action ?? ''} cancellation cash`}
        </DialogTitle>
        <DialogContent>
          {error && <Alert severity="error">{error}</Alert>}
          <Typography>
            {decision?.row.reference} · {decision?.row.amount}{' '}
            {context?.currency}
          </Typography>
          <Alert severity="warning">
            {decision?.action === 'void' || decision?.row.kind === 'void'
              ? 'A void corrects a mistaken booking; it is not a way to recover a real payment. Both bank matches must be removed by an independent reconciler. Downstream uses and commission withdrawals must be reversed first. Approval reverses both internal legs atomically.'
              : 'Approval posts cash immediately after server-side funds, bank and liability checks. A third distinct Finance user must reconcile it.'}
          </Alert>
          <TextField
            fullWidth
            multiline
            minRows={2}
            sx={{ mt: 2 }}
            label="Detailed cash review / correction reason"
            value={review}
            disabled={busy}
            onChange={(e) => setReview(e.target.value)}
            inputProps={{ maxLength: 2000 }}
          />
        </DialogContent>
        <DialogActions>
          <Button disabled={busy} onClick={() => setDecision(null)}>
            Close
          </Button>
          <Button disabled={busy || review.trim().length < 5} onClick={decide}>
            {decision?.action === 'void'
              ? 'Submit void proposal only'
              : decision?.action === 'approve'
                ? 'Approve and post cash / correction'
                : 'Confirm decision'}
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}
