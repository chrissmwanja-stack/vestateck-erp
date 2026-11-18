import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Alert, Box, Button, Card, CardContent, Chip, CircularProgress, Dialog, DialogActions, DialogContent,
  DialogTitle, Grid, MenuItem, Stack, Table, TableBody, TableCell, TableHead, TableRow, TextField, Typography,
} from '@mui/material';
import { allRows, errorText, rpc, table } from '../../db';
import { friendlyError, formatMoney } from '../../logic';
import { supabase } from '../../../../../lib/supabaseClient';
import { useInsuranceAccess } from '../../access';
import { EmptyRow, ErrorBanner } from '../../shared';
import {
  AGENT_PAYMENT_STATUS_LABEL, approvalBlockedReason, canApprovePayment, canCancelPayment, canRejectPayment,
  canReleasePayment, isActionable, paymentQueueTotals, paymentSummary, sortPayments,
  type AgentAccrualDetail, type AgentPayment, type CurrencyTotals,
} from '../../agentCommission';

interface BankAccount { id: string; name: string; currency: string | null }
interface PolicyRef { id: string; policy_no: string | null }
interface PersonRef { id: string; name: string | null; email: string | null }

const perCurrency = (totals: CurrencyTotals): string => {
  const entries = Object.entries(totals);
  return entries.length === 0 ? '-' : entries.map(([c, v]) => formatMoney(v, c)).join(' · ');
};

/**
 * Payment processing for agent commission.
 *
 * Three steps, and the screen exists to make the middle one honest: a payment is
 * proposed by one manager, approved by a SECOND, and only then released. The
 * approve button is not shown to the person who prepared the payment -- not
 * because the client is trusted, but because offering a button that the server
 * will refuse teaches whoever presses it that the control is advisory.
 */
const AgentCommissionPayments = () => {
  const { canManage } = useInsuranceAccess();

  const [payments, setPayments] = useState<AgentPayment[]>([]);
  const [accruals, setAccruals] = useState<AgentAccrualDetail[]>([]);
  const [agents, setAgents] = useState<Record<string, string>>({});
  const [policies, setPolicies] = useState<Record<string, PolicyRef>>({});
  const [banks, setBanks] = useState<BankAccount[]>([]);
  const [people, setPeople] = useState<Record<string, string>>({});
  const [userId, setUserId] = useState<string | null>(null);

  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const [proposeOpen, setProposeOpen] = useState(false);
  const [form, setForm] = useState({ accrual_id: '', bank_account_id: '', paid_on: '', note: '' });
  const [formError, setFormError] = useState<string | null>(null);

  const [declining, setDeclining] = useState<AgentPayment | null>(null);
  const [declineReason, setDeclineReason] = useState('');
  const [declineError, setDeclineError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const [pays, accs, ints, pols, ppl] = await Promise.all([
        allRows<AgentPayment>(() => table('ins_agent_commission_payments').select('*').order('prepared_at', { ascending: false }).order('id')),
        allRows<AgentAccrualDetail>(() => table('ins_agent_commission_accruals').select('*').order('created_at', { ascending: false }).order('id')),
        allRows<{ id: string; name: string }>(() => table('ins_intermediaries').select('id, name').order('id')),
        allRows<PolicyRef>(() => table('ins_policies').select('id, policy_no').order('id')),
        allRows<PersonRef>(() => table('app_users').select('id, name, email').order('id')),
      ]);
      setPayments(pays);
      setAccruals(accs);
      setAgents(Object.fromEntries(ints.map((i) => [i.id, i.name])));
      setPolicies(Object.fromEntries(pols.map((p) => [p.id, p])));
      setPeople(Object.fromEntries(ppl.map((u) => [u.id, u.name ?? u.email ?? 'Unknown'])));
      setError(null);
    } catch (e) {
      setError(friendlyError(errorText(e)));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void load();
    void supabase.auth.getUser().then(({ data }) => setUserId(data.user?.id ?? null));
  }, [load]);

  // Bank accounts come from a manager-only RPC: fin_bank_accounts is not readable
  // by everybody who can see agent commission.
  useEffect(() => {
    if (!canManage) return;
    let cancelled = false;
    (async () => {
      try {
        const list = await rpc<BankAccount[]>('ins_commission_bank_accounts');
        if (!cancelled) setBanks(list ?? []);
      } catch (e) {
        if (!cancelled) setError(friendlyError(errorText(e)));
      }
    })();
    return () => { cancelled = true; };
  }, [canManage]);

  const run = async (action: () => Promise<unknown>, done: string) => {
    setBusy(true);
    try {
      await action();
      setNotice(done);
      setError(null);
      await load();
      return true;
    } catch (e) {
      setError(friendlyError(errorText(e)));
      return false;
    } finally {
      setBusy(false);
    }
  };

  const accrualById = useMemo(() => Object.fromEntries(accruals.map((a) => [a.id, a])), [accruals]);
  const nameOf = (id: string | null) => (id ? people[id] ?? 'Another user' : '-');
  const agentOf = (p: AgentPayment) => {
    const a = accrualById[p.accrual_id];
    return a ? agents[a.intermediary_id] ?? '-' : '-';
  };
  const policyOf = (p: AgentPayment) => {
    const a = accrualById[p.accrual_id];
    return a ? policies[a.policy_id]?.policy_no ?? '-' : '-';
  };

  const sorted = useMemo(() => sortPayments(payments), [payments]);
  const totals = useMemo(() => paymentQueueTotals(payments), [payments]);
  const waiting = useMemo(() => sorted.filter((p) => isActionable(p)), [sorted]);
  const settled = useMemo(() => sorted.filter((p) => !isActionable(p)), [sorted]);

  // Only shares that are eligible and have no live payment can be proposed. The
  // server refuses the rest; this keeps the dropdown honest about it.
  const payableAccruals = useMemo(() => {
    const live = new Set(payments.filter((p) => p.status !== 'rejected' && p.status !== 'cancelled').map((p) => p.accrual_id));
    return accruals.filter((a) => a.status === 'eligible' && !live.has(a.id));
  }, [accruals, payments]);

  const openPropose = () => {
    setForm({ accrual_id: '', bank_account_id: '', paid_on: new Date().toISOString().slice(0, 10), note: '' });
    setFormError(null);
    setProposeOpen(true);
  };

  const propose = async () => {
    if (!form.accrual_id) { setFormError('Choose the agent share you are paying.'); return; }
    if (!form.bank_account_id) { setFormError('Choose the account the money will leave.'); return; }
    if (!form.paid_on) { setFormError('Enter the date the payment will be made.'); return; }
    setFormError(null);
    const ok = await run(
      () => rpc('ins_agent_commission_prepare_payment', {
        p_accrual_id: form.accrual_id,
        p_bank_account_id: form.bank_account_id,
        p_paid_on: form.paid_on,
        p_note: form.note.trim() === '' ? null : form.note.trim(),
      }),
      'Payment proposed. It needs approval by somebody else before any money moves.',
    );
    if (ok) setProposeOpen(false);
  };

  const approve = (p: AgentPayment) =>
    run(() => rpc('ins_agent_commission_approve_payment', { p_payment_id: p.id }),
      'Approved. It is now ready to release.');

  const release = (p: AgentPayment) =>
    run(() => rpc('ins_agent_commission_release_payment', { p_payment_id: p.id, p_note: null }),
      'Payment released and posted.');

  const cancel = (p: AgentPayment) =>
    run(() => rpc('ins_agent_commission_cancel_payment', { p_payment_id: p.id, p_reason: 'withdrawn by the preparer' }),
      'Proposal withdrawn.');

  const decline = async () => {
    if (!declining) return;
    if (declineReason.trim().length < 10) {
      setDeclineError('Say why, in at least 10 characters. The person who proposed it reads this.');
      return;
    }
    setDeclineError(null);
    const ok = await run(
      () => rpc('ins_agent_commission_reject_payment', { p_payment_id: declining.id, p_reason: declineReason.trim() }),
      'Proposal declined.',
    );
    if (ok) { setDeclining(null); setDeclineReason(''); }
  };

  if (loading) return <CircularProgress />;

  const row = (p: AgentPayment) => {
    const blocked = approvalBlockedReason(p, userId, canManage);
    return (
      <TableRow key={p.id} hover>
        <TableCell>{agentOf(p)}</TableCell>
        <TableCell>{policyOf(p)}</TableCell>
        <TableCell align="right">{formatMoney(p.gross_amount, p.currency)}</TableCell>
        <TableCell align="right">{formatMoney(p.wht_amount, p.currency)}</TableCell>
        <TableCell align="right">{formatMoney(p.net_amount, p.currency)}</TableCell>
        <TableCell>{p.paid_on}</TableCell>
        <TableCell>
          <Chip size="small" label={AGENT_PAYMENT_STATUS_LABEL[p.status]} />
        </TableCell>
        <TableCell>{nameOf(p.prepared_by)}</TableCell>
        <TableCell>{nameOf(p.approved_by)}</TableCell>
        <TableCell align="right">
          <Stack direction="row" spacing={1} justifyContent="flex-end">
            {canApprovePayment(p, userId, canManage) && (
              <Button size="small" variant="contained" disabled={busy} onClick={() => approve(p)}
                title={blocked ?? 'Approve this payment'}>
                Approve
              </Button>
            )}
            {canReleasePayment(p, canManage) && (
              <Button size="small" variant="contained" color="success" disabled={busy} onClick={() => release(p)}>
                Release
              </Button>
            )}
            {canCancelPayment(p, userId, canManage) && (
              <Button size="small" disabled={busy} onClick={() => cancel(p)}>Withdraw</Button>
            )}
            {canRejectPayment(p, canManage) && p.prepared_by !== userId && (
              <Button size="small" color="error" disabled={busy} onClick={() => { setDeclining(p); setDeclineReason(''); setDeclineError(null); }}>
                Decline
              </Button>
            )}
          </Stack>
          {/* A disabled decision with no reason reads as a broken system rather
              than a control doing its job. */}
          {blocked && p.status === 'prepared' && p.prepared_by === userId && (
            <Typography variant="caption" color="text.secondary" display="block">
              {blocked}
            </Typography>
          )}
        </TableCell>
      </TableRow>
    );
  };

  const headers = (
    <TableRow>
      <TableCell>Agent</TableCell><TableCell>Policy</TableCell>
      <TableCell align="right">Gross</TableCell><TableCell align="right">Withholding</TableCell>
      <TableCell align="right">Net</TableCell><TableCell>Payment date</TableCell>
      <TableCell>Status</TableCell><TableCell>Prepared by</TableCell><TableCell>Approved by</TableCell>
      <TableCell align="right">Actions</TableCell>
    </TableRow>
  );

  return (
    <Box>
      <Typography variant="body2" color="text.secondary" sx={{ maxWidth: 760, mb: 2 }}>
        Cash to sub-agents and referral partners. One manager proposes a payment and the tax on it is fixed at
        that moment; a <strong>different</strong> manager approves that figure; only then is it released and posted.
      </Typography>
      <ErrorBanner message={error} />
      {notice && <Alert severity="success" onClose={() => setNotice(null)} sx={{ mb: 2 }}>{notice}</Alert>}

      <Grid container spacing={2} sx={{ mb: 3 }}>
        <Grid item xs={12} sm={4}><Kpi label="Awaiting approval" value={perCurrency(totals.prepared)} hint="Proposed, needs a second approver" /></Grid>
        <Grid item xs={12} sm={4}><Kpi label="Approved, not released" value={perCurrency(totals.approved)} hint="Authorised cash still to go out" /></Grid>
        <Grid item xs={12} sm={4}><Kpi label="Paid" value={perCurrency(totals.paid)} hint="Already released to agents" /></Grid>
      </Grid>

      <Stack direction="row" justifyContent="space-between" alignItems="center" sx={{ mb: 1 }}>
        <Typography variant="h6">Waiting on somebody</Typography>
        {canManage && <Button variant="contained" onClick={openPropose} disabled={payableAccruals.length === 0}>Propose a payment</Button>}
      </Stack>
      {canManage && payableAccruals.length === 0 && (
        <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
          No agent share is eligible and unpaid, so there is nothing to propose. Mark a share eligible on the
          Accruals tab once the brokerage&apos;s commission on the policy has been earned.
        </Typography>
      )}
      <Card sx={{ mb: 4 }}>
        <CardContent sx={{ p: 0, overflowX: 'auto' }}>
          <Table size="small">
            <TableHead>{headers}</TableHead>
            <TableBody>
              {waiting.length === 0 && <EmptyRow colSpan={10} text="Nothing is waiting on an approval or a release." />}
              {waiting.map(row)}
            </TableBody>
          </Table>
        </CardContent>
      </Card>

      <Typography variant="h6" sx={{ mb: 1 }}>Settled</Typography>
      <Card>
        <CardContent sx={{ p: 0, overflowX: 'auto' }}>
          <Table size="small">
            <TableHead>{headers}</TableHead>
            <TableBody>
              {settled.length === 0 && <EmptyRow colSpan={10} text="No payment has been released or declined yet." />}
              {settled.map(row)}
            </TableBody>
          </Table>
        </CardContent>
      </Card>

      <Dialog open={proposeOpen} onClose={() => setProposeOpen(false)} fullWidth maxWidth="sm">
        <DialogTitle>Propose a payment</DialogTitle>
        <DialogContent dividers>
          {formError && <Alert severity="error" sx={{ mb: 2 }}>{formError}</Alert>}
          <Stack spacing={2} sx={{ mt: 1 }}>
            <TextField
              select label="Agent share" value={form.accrual_id}
              onChange={(e) => setForm((f) => ({ ...f, accrual_id: e.target.value }))}
              helperText="Only shares that are eligible and not already being paid are offered."
            >
              {payableAccruals.map((a) => (
                <MenuItem key={a.id} value={a.id}>
                  {agents[a.intermediary_id] ?? 'Agent'} · {policies[a.policy_id]?.policy_no ?? '-'} ·{' '}
                  {formatMoney(a.gross_amount, a.currency)}
                </MenuItem>
              ))}
            </TextField>
            <TextField
              select label="Paid from" value={form.bank_account_id}
              onChange={(e) => setForm((f) => ({ ...f, bank_account_id: e.target.value }))}
            >
              {banks.map((b) => (
                <MenuItem key={b.id} value={b.id}>{b.name}{b.currency ? ` (${b.currency})` : ''}</MenuItem>
              ))}
            </TextField>
            <TextField
              type="date" label="Payment date" InputLabelProps={{ shrink: true }}
              value={form.paid_on} onChange={(e) => setForm((f) => ({ ...f, paid_on: e.target.value }))}
              helperText="The withholding rate and character are the ones in force on THIS date."
            />
            <TextField
              label="Note (optional)" multiline minRows={2} value={form.note}
              onChange={(e) => setForm((f) => ({ ...f, note: e.target.value }))}
            />
            <Alert severity="info">
              Proposing does not pay anybody. The tax is calculated and fixed now, and a second manager has to
              approve that figure before the money moves.
            </Alert>
          </Stack>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setProposeOpen(false)} disabled={busy}>Cancel</Button>
          <Button variant="contained" onClick={propose} disabled={busy}>Propose</Button>
        </DialogActions>
      </Dialog>

      <Dialog open={declining !== null} onClose={() => setDeclining(null)} fullWidth maxWidth="sm">
        <DialogTitle>Decline this payment</DialogTitle>
        <DialogContent dividers>
          {declineError && <Alert severity="error" sx={{ mb: 2 }}>{declineError}</Alert>}
          {declining && (
            <Typography variant="body2" sx={{ mb: 2 }}>
              {paymentSummary(declining)}
            </Typography>
          )}
          <TextField
            autoFocus fullWidth multiline minRows={2} label="Reason"
            value={declineReason} onChange={(e) => setDeclineReason(e.target.value)}
            helperText="At least 10 characters. This is what the person who proposed it reads."
            error={declineError !== null}
          />
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setDeclining(null)} disabled={busy}>Cancel</Button>
          <Button color="error" variant="contained" onClick={decline} disabled={busy}>Decline</Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
};

function Kpi({ label, value, hint }: { label: string; value: string; hint: string }) {
  return (
    <Card variant="outlined" sx={{ height: '100%' }}>
      <CardContent>
        <Typography variant="body2" color="text.secondary">{label}</Typography>
        <Typography variant="h5" fontWeight={700}>{value}</Typography>
        <Typography variant="caption" color="text.secondary">{hint}</Typography>
      </CardContent>
    </Card>
  );
}

export default AgentCommissionPayments;
