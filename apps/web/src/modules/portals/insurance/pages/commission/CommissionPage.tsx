import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Alert, Box, Button, Card, CardContent, Checkbox, CircularProgress, Dialog, DialogActions, DialogContent,
  DialogTitle, Grid, MenuItem, Stack, Tab, Tabs, Table, TableBody, TableCell, TableHead, TableRow, TextField, Typography,
} from '@mui/material';
import { errorText, rows, rpc, table } from '../../db';
import { useInsuranceAccess } from '../../access';
import {
  COMMISSION_STATUS_LABEL, formatMoney, isTransferable, isValidVoidReason, sumAmounts, validateTransferInput,
} from '../../logic';
import { CommissionStatusChip, EmptyRow, ErrorBanner, PageHeader } from '../../shared';
import type {
  CommissionEntry, CommissionPosition, CommissionStatus, CommissionTransfer, TransferBankAccount,
} from '../../types';

const todayIso = () => new Date().toISOString().slice(0, 10);

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

const CommissionPage = () => {
  const { canManage } = useInsuranceAccess();
  const [tab, setTab] = useState<'entries' | 'transfers'>('entries');
  const [entries, setEntries] = useState<CommissionEntry[]>([]);
  const [position, setPosition] = useState<CommissionPosition | null>(null);
  const [transfers, setTransfers] = useState<CommissionTransfer[]>([]);
  const [insurers, setInsurers] = useState<Record<string, string>>({});
  const [banks, setBanks] = useState<TransferBankAccount[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [statusFilter, setStatusFilter] = useState<'all' | CommissionStatus>('all');
  const [selected, setSelected] = useState<Set<string>>(new Set());

  const [transferOpen, setTransferOpen] = useState(false);
  const [fromId, setFromId] = useState('');
  const [toId, setToId] = useState('');
  const [date, setDate] = useState(todayIso());
  const [notes, setNotes] = useState('');
  const [bankError, setBankError] = useState<string | null>(null);

  const [voidTarget, setVoidTarget] = useState<CommissionTransfer | null>(null);
  const [voidReason, setVoidReason] = useState('');

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const [ledger, pos, trs, ins] = await Promise.all([
        rows<CommissionEntry>(table('ins_commission_ledger').select('*').order('created_at', { ascending: false })),
        rows<CommissionPosition>(table('ins_commission_position').select('*')),
        rows<CommissionTransfer>(table('ins_commission_transfers').select('*').order('created_at', { ascending: false })),
        rows<{ id: string; name: string }>(table('ins_insurers').select('id, name')),
      ]);
      setEntries(ledger);
      setPosition(pos[0] ?? { unearned_amount: 0, earned_in_client_money: 0, transferred_amount: 0 });
      setTransfers(trs);
      setInsurers(Object.fromEntries(ins.map((i) => [i.id, i.name])));
      setSelected(new Set());
      setError(null);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  // Bank accounts come from an insurance-manager RPC: fin_bank_accounts itself
  // is readable by the finance team only.
  useEffect(() => {
    if (!canManage) return;
    let cancelled = false;
    (async () => {
      try {
        const list = await rpc<TransferBankAccount[]>('ins_commission_bank_accounts');
        if (!cancelled) {
          setBanks(list ?? []);
          setBankError(null);
        }
      } catch (e) {
        if (!cancelled) setBankError(errorText(e));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [canManage]);

  const bankName = useMemo(() => Object.fromEntries(banks.map((b) => [b.id, b.name])), [banks]);
  const trustBanks = banks.filter((b) => b.kind === 'client_money');
  const operatingBanks = banks.filter((b) => b.kind === 'operating');

  const visible = statusFilter === 'all' ? entries : entries.filter((e) => e.status === statusFilter);
  const transferable = entries.filter(isTransferable);
  const chosen = entries.filter((e) => selected.has(e.id) && isTransferable(e));
  const chosenTotal = sumAmounts(chosen);
  const visibleTransferable = visible.filter(isTransferable);
  const allVisibleChosen = visibleTransferable.length > 0 && visibleTransferable.every((e) => selected.has(e.id));

  const toggle = (id: string) =>
    setSelected((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });

  const toggleAllVisible = () =>
    setSelected((prev) => {
      const next = new Set(prev);
      if (allVisibleChosen) visibleTransferable.forEach((e) => next.delete(e.id));
      else visibleTransferable.forEach((e) => next.add(e.id));
      return next;
    });

  const openTransfer = () => {
    setFromId(trustBanks.length === 1 ? trustBanks[0].id : '');
    setToId(operatingBanks.length === 1 ? operatingBanks[0].id : '');
    setDate(todayIso());
    setNotes('');
    setError(null);
    setTransferOpen(true);
  };

  const problems = validateTransferInput({ fromId, toId, date, selected: chosen, todayIso: todayIso() });

  const submitTransfer = async () => {
    setBusy(true);
    setError(null);
    try {
      const t = await rpc<CommissionTransfer>('ins_transfer_earned_commission', {
        p_from_bank_account_id: fromId,
        p_to_bank_account_id: toId,
        p_transfer_date: date,
        p_entry_ids: chosen.map((e) => e.id),
        p_notes: notes.trim() || null,
      });
      setTransferOpen(false);
      setNotice(`Transferred ${formatMoney(chosenTotal)}${t?.transfer_no ? ` as ${t.transfer_no}` : ''}.`);
      await load();
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  };

  const submitVoid = async () => {
    if (!voidTarget) return;
    setBusy(true);
    setError(null);
    try {
      await rpc('ins_void_commission_transfer', { p_transfer_id: voidTarget.id, p_reason: voidReason.trim() });
      setNotice(`Voided ${voidTarget.transfer_no}. The commission is back in client money as earned.`);
      setVoidTarget(null);
      setVoidReason('');
      await load();
    } catch (e) {
      setError(errorText(e));
      setVoidTarget(null);
    } finally {
      setBusy(false);
    }
  };

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <PageHeader
        title="Commission"
        subtitle="Booked as unearned at bind, earned when the insurer is paid in full, then moved out of client money."
        actions={
          canManage && (
            <Button variant="contained" onClick={openTransfer} disabled={chosen.length === 0 || busy}>
              {chosen.length > 0 ? `Transfer ${chosen.length} selected (${formatMoney(chosenTotal)})` : 'Transfer selected'}
            </Button>
          )
        }
      />
      <ErrorBanner message={transferOpen || voidTarget ? null : error} />
      {notice && (
        <Alert severity="success" sx={{ mb: 2 }} onClose={() => setNotice(null)}>{notice}</Alert>
      )}

      {loading && !position ? (
        <Box sx={{ display: 'flex', justifyContent: 'center', py: 6 }}><CircularProgress /></Box>
      ) : (
        <>
          <Grid container spacing={2} sx={{ mb: 2 }}>
            <Grid item xs={12} md={4}>
              <Kpi label="Unearned" value={formatMoney(position?.unearned_amount ?? 0)} hint="Bound, insurer not yet paid in full" />
            </Grid>
            <Grid item xs={12} md={4}>
              <Kpi label="Earned, in client money" value={formatMoney(position?.earned_in_client_money ?? 0)} hint="Income, waiting for a transfer" />
            </Grid>
            <Grid item xs={12} md={4}>
              <Kpi label="Transferred" value={formatMoney(position?.transferred_amount ?? 0)} hint="Moved to an operating account" />
            </Grid>
          </Grid>

          <Alert severity="info" sx={{ mb: 2 }}>
            Commission on policies bound before this feature was introduced is booked as income at bind and does not appear here.
            Bank statement lines for transfers are not matched in bank reconciliation yet, so both sides of a transfer show as unmatched there.
            {!canManage && ' Only insurance managers and admins can transfer commission.'}
          </Alert>

          <Tabs value={tab} onChange={(_, v) => setTab(v)} sx={{ mb: 2 }}>
            <Tab value="entries" label={`Entries (${entries.length})`} />
            <Tab value="transfers" label={`Transfers (${transfers.length})`} />
          </Tabs>

          {tab === 'entries' && (
            <>
              <Card sx={{ mb: 2 }}>
                <CardContent>
                  <Stack direction="row" spacing={2} alignItems="center">
                    <TextField
                      select size="small" label="Status" value={statusFilter} sx={{ minWidth: 220 }}
                      onChange={(e) => setStatusFilter(e.target.value as typeof statusFilter)}
                    >
                      <MenuItem value="all">All</MenuItem>
                      {(Object.keys(COMMISSION_STATUS_LABEL) as CommissionStatus[]).map((s) => (
                        <MenuItem key={s} value={s}>{COMMISSION_STATUS_LABEL[s]}</MenuItem>
                      ))}
                    </TextField>
                    {canManage && (
                      <Typography variant="body2" color="text.secondary">
                        {transferable.length} earned {transferable.length === 1 ? 'entry' : 'entries'} can be transferred.
                      </Typography>
                    )}
                  </Stack>
                </CardContent>
              </Card>
              <Card>
                <CardContent sx={{ p: 0 }}>
                  <Table size="small">
                    <TableHead>
                      <TableRow>
                        {canManage && (
                          <TableCell padding="checkbox">
                            <Checkbox
                              size="small" checked={allVisibleChosen} disabled={visibleTransferable.length === 0}
                              indeterminate={!allVisibleChosen && visibleTransferable.some((e) => selected.has(e.id))}
                              onChange={toggleAllVisible} inputProps={{ 'aria-label': 'Select all earned entries' }}
                            />
                          </TableCell>
                        )}
                        <TableCell>Policy</TableCell>
                        <TableCell>Insurer</TableCell>
                        <TableCell align="right">Commission</TableCell>
                        <TableCell>Status</TableCell>
                        <TableCell>Earned on</TableCell>
                        <TableCell>Transfer</TableCell>
                      </TableRow>
                    </TableHead>
                    <TableBody>
                      {visible.length === 0 ? (
                        <EmptyRow colSpan={canManage ? 7 : 6} text="No commission entries." />
                      ) : (
                        visible.map((e) => (
                          <TableRow key={e.id} hover>
                            {canManage && (
                              <TableCell padding="checkbox">
                                <Checkbox
                                  size="small" checked={selected.has(e.id)} disabled={!isTransferable(e)}
                                  onChange={() => toggle(e.id)} inputProps={{ 'aria-label': `Select ${e.policy_no}` }}
                                />
                              </TableCell>
                            )}
                            <TableCell sx={{ fontFamily: 'monospace', fontWeight: 600 }}>{e.policy_no}</TableCell>
                            <TableCell>{insurers[e.insurer_id] ?? '-'}</TableCell>
                            <TableCell align="right">{formatMoney(e.amount)}</TableCell>
                            <TableCell><CommissionStatusChip status={e.status} /></TableCell>
                            <TableCell>{e.earned_on ?? '-'}</TableCell>
                            <TableCell>{e.transfer_no ?? '-'}</TableCell>
                          </TableRow>
                        ))
                      )}
                    </TableBody>
                  </Table>
                </CardContent>
              </Card>
            </>
          )}

          {tab === 'transfers' && (
            <Card>
              <CardContent sx={{ p: 0 }}>
                <Table size="small">
                  <TableHead>
                    <TableRow>
                      <TableCell>Transfer no</TableCell>
                      <TableCell>Date</TableCell>
                      <TableCell>From</TableCell>
                      <TableCell>To</TableCell>
                      <TableCell align="right">Amount</TableCell>
                      <TableCell>Status</TableCell>
                      <TableCell>Notes</TableCell>
                      {canManage && <TableCell />}
                    </TableRow>
                  </TableHead>
                  <TableBody>
                    {transfers.length === 0 ? (
                      <EmptyRow colSpan={canManage ? 8 : 7} text="No commission transfers yet." />
                    ) : (
                      transfers.map((t) => (
                        <TableRow key={t.id} hover>
                          <TableCell sx={{ fontFamily: 'monospace', fontWeight: 600 }}>{t.transfer_no}</TableCell>
                          <TableCell>{t.transfer_date}</TableCell>
                          <TableCell>{bankName[t.from_bank_account_id] ?? '-'}</TableCell>
                          <TableCell>{bankName[t.to_bank_account_id] ?? '-'}</TableCell>
                          <TableCell align="right">{formatMoney(t.amount, t.currency)}</TableCell>
                          <TableCell>{t.status === 'void' ? `Void: ${t.void_reason ?? ''}` : 'Posted'}</TableCell>
                          <TableCell>{t.notes ?? '-'}</TableCell>
                          {canManage && (
                            <TableCell align="right">
                              {t.status === 'posted' && (
                                <Button size="small" color="error" onClick={() => { setError(null); setVoidReason(''); setVoidTarget(t); }}>Void</Button>
                              )}
                            </TableCell>
                          )}
                        </TableRow>
                      ))
                    )}
                  </TableBody>
                </Table>
              </CardContent>
            </Card>
          )}
        </>
      )}

      <Dialog open={transferOpen} onClose={() => !busy && setTransferOpen(false)} maxWidth="sm" fullWidth>
        <DialogTitle>Transfer commission to an operating account</DialogTitle>
        <DialogContent>
          <Stack spacing={2} sx={{ mt: 1 }}>
            <ErrorBanner message={error} />
            {bankError && <Alert severity="warning">Could not load bank accounts: {bankError}</Alert>}
            {!bankError && banks.length > 0 && (trustBanks.length === 0 || operatingBanks.length === 0) && (
              <Alert severity="warning">
                A transfer needs one active client-money account and one active operating account, both mapped to ledger accounts.
                Ask finance to register the missing one under Bank accounts.
              </Alert>
            )}
            <Typography variant="body2">
              {chosen.length} {chosen.length === 1 ? 'entry' : 'entries'}, total <strong>{formatMoney(chosenTotal)}</strong>.
              This books Dr operating bank, Cr client money on the transfer date.
            </Typography>
            <TextField
              select label="From (client money)" size="small" value={fromId} onChange={(e) => setFromId(e.target.value)}
              SelectProps={{ native: true }} InputLabelProps={{ shrink: true }}
            >
              <option value="">Choose…</option>
              {trustBanks.map((b) => <option key={b.id} value={b.id}>{b.name}{b.bank_name ? ` (${b.bank_name})` : ''}</option>)}
            </TextField>
            <TextField
              select label="To (operating)" size="small" value={toId} onChange={(e) => setToId(e.target.value)}
              SelectProps={{ native: true }} InputLabelProps={{ shrink: true }}
            >
              <option value="">Choose…</option>
              {operatingBanks.map((b) => <option key={b.id} value={b.id}>{b.name}{b.bank_name ? ` (${b.bank_name})` : ''}</option>)}
            </TextField>
            <TextField label="Transfer date" type="date" size="small" value={date} onChange={(e) => setDate(e.target.value)} InputLabelProps={{ shrink: true }} />
            <TextField label="Notes (optional)" size="small" value={notes} onChange={(e) => setNotes(e.target.value)} />
            {problems.length > 0 && (
              <Alert severity="info">{problems.map((p) => <div key={p}>{p}</div>)}</Alert>
            )}
          </Stack>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setTransferOpen(false)} disabled={busy}>Cancel</Button>
          <Button variant="contained" onClick={submitTransfer} disabled={busy || problems.length > 0}>
            {busy ? 'Transferring…' : 'Transfer commission'}
          </Button>
        </DialogActions>
      </Dialog>

      <Dialog open={!!voidTarget} onClose={() => !busy && setVoidTarget(null)} maxWidth="sm" fullWidth>
        <DialogTitle>Void {voidTarget?.transfer_no}?</DialogTitle>
        <DialogContent>
          <Stack spacing={2} sx={{ mt: 1 }}>
            <ErrorBanner message={error} />
            <Typography variant="body2">
              This reverses the transfer entry. The commission goes back to earned and in client money. If the money has already moved at the bank, correct that at the bank too.
            </Typography>
            <TextField
              label="Reason (at least 5 characters)" size="small" value={voidReason}
              onChange={(e) => setVoidReason(e.target.value)} autoFocus
            />
          </Stack>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setVoidTarget(null)} disabled={busy}>Cancel</Button>
          <Button variant="contained" color="error" onClick={submitVoid} disabled={busy || !isValidVoidReason(voidReason)}>
            {busy ? 'Voiding…' : 'Void transfer'}
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
};

export default CommissionPage;