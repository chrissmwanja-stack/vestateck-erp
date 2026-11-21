import { businessToday, businessTodayDate } from '../../../../../lib/businessDate';
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
  WHT_REMITTANCE_STATUS_LABEL, canApproveRemittance, canPayRemittance, canVoidRemittance, isOpenRemittance,
  monthBounds, prepareWarning, previousMonth, remittanceBlockedReason, sortRemittances, whtCurrencyLines,
  type WhtPosition, type WhtRemittance, type WhtRemittanceStatus,
} from '../../agentCommission';

interface BankAccount { id: string; name: string; currency: string | null }

const statusColour: Record<WhtRemittanceStatus, 'default' | 'info' | 'success' | 'warning'> = {
  prepared: 'warning',
  approved: 'info',
  paid: 'success',
  void: 'default',
};

/** Short form for the chip; the full sentence lives in WHT_REMITTANCE_STATUS_LABEL. */
const AGENT_WHT_SHORT_STATUS: Record<WhtRemittanceStatus, string> = {
  prepared: 'Prepared',
  approved: 'Approved',
  paid: 'Paid',
  void: 'Void',
};

const periodOf = (r: Pick<WhtRemittance, 'period_start' | 'period_end'>) =>
  new Date(`${r.period_start}T00:00:00`).toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' })
  + ' – '
  + new Date(`${r.period_end}T00:00:00`).toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' });

/**
 * Withheld tax on agent commission, and what has been done with it.
 *
 * The tab exists to answer one question without arithmetic: how much tax have we
 * taken off agents that we have not yet reported, and how much have we reported
 * that we have not yet paid over. Everything on screen comes from
 * ins_wht_position() and the remittance RPCs; the browser totals nothing.
 */
const AgentCommissionWht = () => {
  const { canManage } = useInsuranceAccess();

  const [position, setPosition] = useState<WhtPosition | null>(null);
  const [remittances, setRemittances] = useState<WhtRemittance[]>([]);
  const [banks, setBanks] = useState<BankAccount[]>([]);
  const [people, setPeople] = useState<Record<string, string>>({});
  const [userId, setUserId] = useState<string | null>(null);

  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const lastMonth = useMemo(() => monthBounds(previousMonth(businessTodayDate())), []);
  const [prepareOpen, setPrepareOpen] = useState(false);
  const [period, setPeriod] = useState({ start: lastMonth.start, end: lastMonth.end });
  const [prepareError, setPrepareError] = useState<string | null>(null);

  const [paying, setPaying] = useState<WhtRemittance | null>(null);
  const [payment, setPayment] = useState({ bank_account_id: '', paid_on: '', reference: '' });
  const [payError, setPayError] = useState<string | null>(null);

  const [voiding, setVoiding] = useState<WhtRemittance | null>(null);
  const [voidReason, setVoidReason] = useState('');
  const [voidError, setVoidError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const [pos, rows, ppl] = await Promise.all([
        rpc<WhtPosition>('ins_wht_position'),
        allRows<WhtRemittance>(() => table('ins_wht_remittances').select('*').order('period_start', { ascending: false }).order('id')),
        allRows<{ id: string; name: string | null; email: string | null }>(() => table('app_users').select('id, name, email').order('id')),
      ]);
      setPosition(pos);
      setRemittances(rows);
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

  // Only a manager can read the brokerage's bank accounts, and only a manager can
  // pay a return, so the list is not fetched for anybody else.
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

  const lines = useMemo(() => (position ? whtCurrencyLines(position) : []), [position]);
  const overReported = lines.filter((l) => l.over_reported > 0);
  const sorted = useMemo(() => sortRemittances(remittances), [remittances]);
  const open = sorted.filter(isOpenRemittance);
  const settled = sorted.filter((r) => !isOpenRemittance(r));

  const openPrepare = () => {
    setPeriod({ start: lastMonth.start, end: lastMonth.end });
    setPrepareError(null);
    setPrepareOpen(true);
  };

  const prepare = async () => {
    if (!period.start || !period.end) { setPrepareError('A return needs a period, both dates.'); return; }
    if (period.end < period.start) { setPrepareError('The end of the period cannot come before its start.'); return; }
    setPrepareError(null);
    const ok = await run(
      () => rpc('ins_wht_prepare_remittance', { p_period_start: period.start, p_period_end: period.end, p_currency: null }),
      'Return prepared. A second manager has to approve the figure before it is paid.',
    );
    if (ok) setPrepareOpen(false);
  };

  const approve = (r: WhtRemittance) =>
    run(() => rpc('ins_wht_approve_remittance', { p_id: r.id }), 'Return approved. It is ready to pay.');

  const openPay = (r: WhtRemittance) => {
    setPayment({ bank_account_id: '', paid_on: businessToday(), reference: '' });
    setPayError(null);
    setPaying(r);
  };

  const pay = async () => {
    if (!paying) return;
    if (!payment.bank_account_id) { setPayError('Choose the account the money will leave.'); return; }
    if (!payment.paid_on) { setPayError('Enter the date the tax was paid to URA.'); return; }
    if (payment.reference.trim().length < 3) {
      setPayError('Enter the URA payment reference. It is the only link between this ledger and their record of the payment.');
      return;
    }
    setPayError(null);
    const ok = await run(
      () => rpc('ins_wht_pay_remittance', {
        p_id: paying.id,
        p_bank_account_id: payment.bank_account_id,
        p_paid_on: payment.paid_on,
        p_reference: payment.reference.trim(),
      }),
      'Tax paid and posted. Wait for URA to acknowledge it before treating the period as closed.',
    );
    if (ok) setPaying(null);
  };

  const voidReturn = async () => {
    if (!voiding) return;
    if (voidReason.trim().length < 10) {
      setVoidError('Say why, in at least 10 characters. This is the only record of why a filed figure was withdrawn.');
      return;
    }
    setVoidError(null);
    const ok = await run(
      () => rpc('ins_wht_void_remittance', { p_id: voiding.id, p_reason: voidReason.trim() }),
      'Return voided. Its tax is available to a later return.',
    );
    if (ok) { setVoiding(null); setVoidReason(''); }
  };

  if (loading) return <CircularProgress />;

  const nameOf = (id: string | null | undefined) => (id ? people[id] ?? 'Another user' : '-');

  const headers = (
    <TableRow>
      <TableCell>Return</TableCell><TableCell>Period</TableCell>
      <TableCell align="right">Tax</TableCell><TableCell>Status</TableCell>
      <TableCell>Prepared by</TableCell><TableCell>Paid on</TableCell><TableCell>Reference</TableCell>
      <TableCell align="right">Actions</TableCell>
    </TableRow>
  );

  const row = (r: WhtRemittance) => {
    const blocked = remittanceBlockedReason(r, userId, canManage);
    return (
      <TableRow key={r.id} hover>
        <TableCell>{r.remittance_no}</TableCell>
        <TableCell>{periodOf(r)}</TableCell>
        <TableCell align="right">{formatMoney(r.amount, r.currency)}</TableCell>
        <TableCell>
          <Chip size="small" color={statusColour[r.status]} label={AGENT_WHT_SHORT_STATUS[r.status]}
            title={WHT_REMITTANCE_STATUS_LABEL[r.status]} />
        </TableCell>
        <TableCell>{nameOf(r.prepared_by)}</TableCell>
        <TableCell>{r.paid_on ?? '-'}</TableCell>
        <TableCell>{r.payment_reference ?? '-'}</TableCell>
        <TableCell align="right">
          <Stack direction="row" spacing={1} justifyContent="flex-end">
            {canApproveRemittance(r, userId, canManage) && (
              <Button size="small" variant="contained" disabled={busy} onClick={() => approve(r)}
                title={blocked ?? 'Approve this return'}>
                Approve
              </Button>
            )}
            {canPayRemittance(r, canManage) && (
              <Button size="small" variant="contained" color="success" disabled={busy} onClick={() => openPay(r)}>
                Pay
              </Button>
            )}
            {canVoidRemittance(r, canManage) && (
              <Button size="small" color="error" disabled={busy}
                onClick={() => { setVoiding(r); setVoidReason(''); setVoidError(null); }}>
                Void
              </Button>
            )}
          </Stack>
          {blocked && r.status === 'prepared' && r.prepared_by === userId && (
            <Typography variant="caption" color="text.secondary" display="block">
              {blocked}
            </Typography>
          )}
        </TableCell>
      </TableRow>
    );
  };

  const money = (n: number, currency = 'UGX') => formatMoney(n, currency);

  return (
    <Box>
      <Typography variant="body2" color="text.secondary" sx={{ maxWidth: 780, mb: 2 }}>
        Tax withheld from agents is the revenue authority&apos;s money, not the brokerage&apos;s. A return covers the
        month the payment was <strong>made</strong>, not the month the commission was earned; it is prepared by one
        manager, approved by a second, and paid with URA&apos;s reference.
      </Typography>
      <ErrorBanner message={error} />
      {notice && <Alert severity="success" onClose={() => setNotice(null)} sx={{ mb: 2 }}>{notice}</Alert>}

      {position && (
        <>
          <Grid container spacing={2} sx={{ mb: 3 }}>
            {lines.map((line) => (
              <Grid item xs={12} md={6} lg={3} key={line.currency}>
                <Card variant="outlined" sx={{ height: '100%' }}>
                  <CardContent>
                    <Typography variant="overline" color="text.secondary">{line.currency}</Typography>
                    <Stack spacing={1.5} sx={{ mt: 0.5 }}>
                      <Figure label="Withheld from agents" value={money(line.withheld_total, line.currency)}
                        hint="Tax deducted from commission actually paid" />
                      <Figure label="Not on any return" value={money(line.unreported_open, line.currency)}
                        hint={line.over_reported > 0
                          ? `${money(line.over_reported, line.currency)} over-reported on a return that is no longer withheld`
                          : 'Withheld and never reported yet'} />
                      <Figure label="Reported, not paid" value={money(line.awaiting_payment, line.currency)}
                        hint="On a return, still owed to URA" />
                      <Figure label="Paid to URA" value={money(line.paid_total, line.currency)}
                        hint="Settled with the revenue authority" />
                    </Stack>
                  </CardContent>
                </Card>
              </Grid>
            ))}
          </Grid>
          {overReported.length > 0 && (
            <Alert severity="warning" sx={{ mb: 3 }}>
              {overReported.map((l) => money(l.over_reported, l.currency)).join(' and ')} on a return is no longer
              withheld, because a share behind it was reversed. A filed return is not edited: raise this with URA as
              a credit against the next period, and record the outcome here as a new return.
            </Alert>
          )}
        </>
      )}

      <Stack direction="row" justifyContent="space-between" alignItems="center" sx={{ mb: 1 }}>
        <Typography variant="h6">Returns still open</Typography>
        {canManage && <Button variant="contained" onClick={openPrepare}>Prepare a return</Button>}
      </Stack>
      <Card sx={{ mb: 4 }}>
        <CardContent sx={{ p: 0, overflowX: 'auto' }}>
          <Table size="small">
            <TableHead>{headers}</TableHead>
            <TableBody>
              {open.length === 0 && <EmptyRow colSpan={8} text="No return is open. Everything withheld is either paid or not yet on a return." />}
              {open.map(row)}
            </TableBody>
          </Table>
        </CardContent>
      </Card>

      <Typography variant="h6" sx={{ mb: 1 }}>Closed returns</Typography>
      <Card>
        <CardContent sx={{ p: 0, overflowX: 'auto' }}>
          <Table size="small">
            <TableHead>{headers}</TableHead>
            <TableBody>
              {settled.length === 0 && <EmptyRow colSpan={8} text="No return has been paid or voided yet." />}
              {settled.map(row)}
            </TableBody>
          </Table>
        </CardContent>
      </Card>

      <Dialog open={prepareOpen} onClose={() => setPrepareOpen(false)} fullWidth maxWidth="sm">
        <DialogTitle>Prepare a return</DialogTitle>
        <DialogContent dividers>
          {prepareError && <Alert severity="error" sx={{ mb: 2 }}>{prepareError}</Alert>}
          <Stack spacing={2} sx={{ mt: 1 }}>
            <Stack direction="row" spacing={2}>
              <TextField type="date" label="Period starts" InputLabelProps={{ shrink: true }} fullWidth
                value={period.start} onChange={(e) => setPeriod((p) => ({ ...p, start: e.target.value }))} />
              <TextField type="date" label="Period ends" InputLabelProps={{ shrink: true }} fullWidth
                value={period.end} onChange={(e) => setPeriod((p) => ({ ...p, end: e.target.value }))} />
            </Stack>
            <Typography variant="caption" color="text.secondary">
              Last month, {lastMonth.label}, is filled in because a return is filed for a period that has closed.
            </Typography>
            {prepareWarning(period.end, businessTodayDate()) && (
              <Alert severity="warning">{prepareWarning(period.end, businessTodayDate())}</Alert>
            )}
            <Alert severity="info">
              The amount is whatever tax was withheld on payments dated inside this period and is not already on
              another return. It is fixed when the return is prepared, so the approver agrees to a figure rather
              than a formula.
            </Alert>
          </Stack>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setPrepareOpen(false)} disabled={busy}>Cancel</Button>
          <Button variant="contained" onClick={prepare} disabled={busy}>Prepare</Button>
        </DialogActions>
      </Dialog>

      <Dialog open={paying !== null} onClose={() => setPaying(null)} fullWidth maxWidth="sm">
        <DialogTitle>Pay {paying?.remittance_no} to URA</DialogTitle>
        <DialogContent dividers>
          {payError && <Alert severity="error" sx={{ mb: 2 }}>{payError}</Alert>}
          {paying && (
            <Typography variant="body2" sx={{ mb: 2 }}>
              {formatMoney(paying.amount, paying.currency)} for {periodOf(paying)}.
            </Typography>
          )}
          <Stack spacing={2} sx={{ mt: 1 }}>
            <TextField select label="Paid from" value={payment.bank_account_id}
              onChange={(e) => setPayment((p) => ({ ...p, bank_account_id: e.target.value }))}>
              {banks.map((b) => (
                <MenuItem key={b.id} value={b.id}>
                  {b.name}{b.currency ? ` (${b.currency})` : ''}
                </MenuItem>
              ))}
            </TextField>
            <TextField type="date" label="Paid on" InputLabelProps={{ shrink: true }}
              value={payment.paid_on} onChange={(e) => setPayment((p) => ({ ...p, paid_on: e.target.value }))} />
            <TextField label="URA reference" value={payment.reference}
              onChange={(e) => setPayment((p) => ({ ...p, reference: e.target.value }))}
              helperText="The acknowledgement number URA gives. Without it there is nothing to reconcile against." />
          </Stack>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setPaying(null)} disabled={busy}>Cancel</Button>
          <Button variant="contained" color="success" onClick={pay} disabled={busy}>Record payment</Button>
        </DialogActions>
      </Dialog>

      <Dialog open={voiding !== null} onClose={() => setVoiding(null)} fullWidth maxWidth="sm">
        <DialogTitle>Void {voiding?.remittance_no}</DialogTitle>
        <DialogContent dividers>
          {voidError && <Alert severity="error" sx={{ mb: 2 }}>{voidError}</Alert>}
          <Typography variant="body2" sx={{ mb: 2 }}>
            Voiding releases the tax on this return so a later return can claim it. The return itself is kept,
            marked void, because a numbered document that has existed does not stop having existed.
          </Typography>
          <TextField autoFocus fullWidth multiline minRows={2} label="Reason"
            value={voidReason} onChange={(e) => setVoidReason(e.target.value)}
            helperText="At least 10 characters." error={voidError !== null} />
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setVoiding(null)} disabled={busy}>Cancel</Button>
          <Button color="error" variant="contained" onClick={voidReturn} disabled={busy}>Void</Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
};

/** One figure with the sentence that makes it mean something. */
function Figure({ label, value, hint }: { label: string; value: string; hint: string }) {
  return (
    <Box>
      <Typography variant="body2" color="text.secondary">{label}</Typography>
      <Typography variant="h6" fontWeight={700} lineHeight={1.2}>{value}</Typography>
      <Typography variant="caption" color="text.secondary">{hint}</Typography>
    </Box>
  );
}

export default AgentCommissionWht;
