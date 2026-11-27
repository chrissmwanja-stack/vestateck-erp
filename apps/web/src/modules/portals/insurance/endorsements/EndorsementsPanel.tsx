// Endorsements on a policy: the propose dialog (insurance managers), the
// endorsements list, and the Finance maker/checker controls. The money math is
// server-side; this panel only shapes the request and shows the calculation.
import { businessToday } from '../../../../lib/businessDate';
import EndorsementNotes from './EndorsementNotes';
import { useCallback, useEffect, useState } from 'react';
import {
  Alert, Box, Button, Card, CardContent, Checkbox, Chip, CircularProgress, Dialog, DialogActions, DialogContent,
  DialogTitle, FormControl, Grid, InputLabel, MenuItem, Select, Stack, Table, TableBody, TableCell, TableHead,
  TableRow, TextField, Typography, FormControlLabel,
} from '@mui/material';
import { errorText, rows, rpc, table } from '../db';
import {
  directionFor, endorsementSettlementPosition, settleEndorsementItem, voidSettlement,
  type EndorsementSettlement, type EndorsementSettlementItem, type EndorsementSettlementPosition,
} from './settlement';
import type { PolicyCashBank } from '../policyCash';
import {
  buildChanges, buildTerms, decideEndorsement, formatSigned, isLive, prepareEndorsement, previewEndorsement,
  approveEndorsementCancellation, prepareEndorsementCancellation, unwindPosition,
  proposeEndorsement, reviewPosition, statusTone, withdrawEndorsement,
  type EndorsementCalculation, type EndorsementChangesDraft, type EndorsementPosition, type EndorsementRow,
  type EndorsementTermsDraft, type EndorsementUnwindPosition,
} from './workflow';

interface GlAccountOption {
  id: string;
  account_code: string;
  name: string;
}

const today = () => businessToday();

export default function EndorsementsPanel({
  policyId,
  canManage,
  policyActive,
}: {
  policyId: string;
  canManage: boolean;
  policyActive: boolean;
}) {
  const [list, setList] = useState<EndorsementRow[]>([]);
  const [position, setPosition] = useState<EndorsementPosition | null>(null);
  const [clearingAccounts, setClearingAccounts] = useState<GlAccountOption[]>([]);
  const [isFinance, setIsFinance] = useState(false);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);

  const [formOpen, setFormOpen] = useState(false);
  const [notesRow, setNotesRow] = useState<EndorsementRow | null>(null);
  const [effective, setEffective] = useState(today());
  const [terms, setTerms] = useState<EndorsementTermsDraft[]>([]);
  const [changes, setChanges] = useState<EndorsementChangesDraft>({ sum_insured: '', risk_description: '', notes: '' });
  const [reason, setReason] = useState('');
  const [quote, setQuote] = useState<EndorsementCalculation | null>(null);

  const [withdrawRow, setWithdrawRow] = useState<EndorsementRow | null>(null);
  const [withdrawReason, setWithdrawReason] = useState('');
  // E4: cancelling a posted endorsement. The eligibility is fetched when the dialog
  // opens rather than guessed from the row, because only the server knows whether
  // the money has moved.
  const [cancelRow, setCancelRow] = useState<EndorsementRow | null>(null);
  const [cancelReason, setCancelReason] = useState('');
  const [cancelPosition, setCancelPosition] = useState<EndorsementUnwindPosition | null>(null);
  const [cancelPosLoading, setCancelPosLoading] = useState(false);
  const [prepareRow, setPrepareRow] = useState<EndorsementRow | null>(null);
  const [prepareClearing, setPrepareClearing] = useState('');
  const [decideRow, setDecideRow] = useState<EndorsementRow | null>(null);
  const [decideNote, setDecideNote] = useState('');
  const [acceptException, setAcceptException] = useState(false);
  // The insurance managers' per-insurer share list, so the propose dialog can ask for a delta per share.
  const [shares, setShares] = useState<{ insurer_id: string; name: string }[]>([]);
  // Settlement workflow: a posted endorsement's open items, and the settlements over them.
  const [settleRow, setSettleRow] = useState<EndorsementRow | null>(null);
  const [settlePosition, setSettlePosition] = useState<EndorsementSettlementPosition | null>(null);
  const [settleLoading, setSettleLoading] = useState(false);
  const [settleTarget, setSettleTarget] = useState<EndorsementSettlementItem | null>(null);
  const [settleBank, setSettleBank] = useState('');
  const [settleAmount, setSettleAmount] = useState('');
  const [settleDate, setSettleDate] = useState(today());
  const [settleReference, setSettleReference] = useState('');
  const [settleNotes, setSettleNotes] = useState('');
  const [settleBanks, setSettleBanks] = useState<PolicyCashBank[]>([]);
  const [voidRow, setVoidRow] = useState<EndorsementSettlement | null>(null);
  const [voidReason, setVoidReason] = useState('');

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const [items, pos, accounts, finance, pol, sh] = await Promise.all([
        rows<EndorsementRow>(
          table('ins_policy_endorsements').select('*').eq('policy_id', policyId).order('proposed_at', { ascending: false }),
        ),
        reviewPosition(policyId).catch(() => null),
        rows<GlAccountOption>(table('gl_accounts').select('id, account_code, name').order('account_code')).catch(() => []),
        rpc<boolean>('is_finance_team_member', { p_role: 'finance' }).catch(() => false),
        rows<{ insurer_id: string | null }>(table('ins_policies').select('insurer_id').eq('id', policyId)).catch(() => []),
        rows<{ insurer_id: string; share_pct: number; ins_insurers: { name: string } | null }>(
          table('ins_policy_insurer_shares').select('insurer_id, share_pct, ins_insurers(name)').eq('policy_id', policyId),
        ).catch(() => []),
      ]);
      setList(items);
      setPosition(pos);
      setClearingAccounts(accounts);
      setIsFinance(finance === true);
      setShares(sh.length
        ? sh.map((s) => ({ insurer_id: s.insurer_id, name: s.ins_insurers?.name ?? 'Insurer' }))
        : pol[0]?.insurer_id
          ? [{ insurer_id: pol[0].insurer_id, name: 'Insurer' }]
          : []);
      setError(null);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setLoading(false);
    }
  }, [policyId]);

  useEffect(() => {
    load();
  }, [load]);

  const openForm = () => {
    setTerms(shares.length ? shares.map((s) => ({ insurer_id: s.insurer_id, agreed_delta: '' })) : []);
    setEffective(today());
    setChanges({ sum_insured: '', risk_description: '', notes: '' });
    setReason('');
    setQuote(null);
    setError(null);
    setFormOpen(true);
  };

  const runPreview = async () => {
    setBusy(true);
    setError(null);
    try {
      const q = await previewEndorsement(policyId, effective, buildTerms(terms), buildChanges(changes));
      setQuote(q);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  };

  const submit = async () => {
    setBusy(true);
    setError(null);
    try {
      await proposeEndorsement({
        policyId,
        effectiveDate: effective,
        terms: buildTerms(terms),
        changes: buildChanges(changes),
        reason,
      });
      setFormOpen(false);
      setNotice('Endorsement proposed. Finance will prepare and decide it.');
      await load();
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  };

  const runWithdraw = async () => {
    if (!withdrawRow) return;
    setBusy(true);
    setError(null);
    try {
      await withdrawEndorsement(withdrawRow.id, withdrawReason);
      setWithdrawRow(null);
      setWithdrawReason('');
      setNotice('Endorsement withdrawn.');
      await load();
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  };

  const openCancel = async (row: EndorsementRow) => {
    setCancelRow(row);
    setCancelReason('');
    setCancelPosition(null);
    setCancelPosLoading(true);
    setError(null);
    try {
      setCancelPosition(await unwindPosition(row.id));
    } catch (e) {
      setError(errorText(e));
    } finally {
      setCancelPosLoading(false);
    }
  };

  // Settlement workflow. The item list comes from the server position read;
  // the write is the existing finance-gated RPC, unchanged.
  const openSettle = async (row: EndorsementRow) => {
    setSettleRow(row);
    setSettlePosition(null);
    setSettleLoading(true);
    setSettleTarget(null);
    setError(null);
    try {
      const pos = await endorsementSettlementPosition(row.id);
      setSettlePosition(pos);
      if (pos.items.some((i) => i.outstanding > 0)) {
        const all = await rpc<PolicyCashBank[]>('ins_policy_cash_bank_accounts').catch(() => []);
        // Endorsement items settle against client-money accounts (the premium money the
        // brokerage holds on the client's behalf); operating accounts are for payroll
        // and company overheads, never this flow. The server re-checks the kind anyway.
        setSettleBanks(all.filter((b) => b.currency === pos.currency && b.kind === 'client_money'));
      } else {
        setSettleBanks([]);
      }
    } catch (e) {
      setError(errorText(e));
    } finally {
      setSettleLoading(false);
    }
  };

  const chooseSettleTarget = (item: EndorsementSettlementItem | null) => {
    setSettleTarget(item);
    setError(null);
    if (item) {
      setSettleBank('');
      setSettleAmount(item.outstanding ? String(item.outstanding) : '');
      setSettleDate(today());
      setSettleReference('');
      setSettleNotes('');
    }
  };

  const runSettle = async () => {
    if (!settleTarget) return;
    if (!settleBank) { setError('Choose a client-money bank account.'); return; }
    const amount = Number(settleAmount);
    if (!/^\d+(\.\d{1,2})?$/.test(settleAmount.trim()) || !Number.isFinite(amount) || amount <= 0) {
      setError('Enter a positive amount with at most two decimals.'); return;
    }
    if (amount > settleTarget.outstanding) { setError('Amount exceeds the outstanding balance of this item.'); return; }
    if (settleDate > today()) { setError('Choose a settlement date no later than today.'); return; }
    setBusy(true); setError(null);
    try {
      await settleEndorsementItem({
        bankAccountId: settleBank,
        direction: directionFor(settleTarget),
        partyAccountId: settleTarget.party_account_id,
        amount,
        settlementDate: settleDate,
        itemId: settleTarget.id,
        itemAmount: amount,
        reference: settleReference || null,
        notes: settleNotes || null,
      });
      setSettleTarget(null);
      setNotice('Settlement posted. The endorsement item is credited against the settlement.');
      if (settleRow) setSettlePosition(await endorsementSettlementPosition(settleRow.id));
      await load();
    } catch (e) {
      setError(errorText(e));
    } finally { setBusy(false); }
  };

  const runVoid = async () => {
    if (!voidRow) return;
    setBusy(true); setError(null);
    try {
      await voidSettlement({ settlementId: voidRow.id, reason: voidReason });
      setVoidRow(null);
      setVoidReason('');
      setNotice('Settlement voided. The item and any commission it earned are back to deferred.');
      if (settleRow) setSettlePosition(await endorsementSettlementPosition(settleRow.id));
      await load();
    } catch (e) {
      setError(errorText(e));
    } finally { setBusy(false); }
  };

  const runCancel = async () => {
    if (!cancelRow) return;
    setBusy(true);
    setError(null);
    try {
      await prepareEndorsementCancellation(cancelRow.id, cancelReason);
      // The document needs a second, independent Finance person; say so plainly
      // rather than leaving the row looking unchanged.
      setNotice('Cancellation prepared. An independent Finance checker must approve it before anything is reversed.');
      setCancelRow(null);
      setCancelReason('');
      await load();
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  };

  const runApproveCancel = async () => {
    if (!cancelRow) return;
    setBusy(true);
    setError(null);
    try {
      await approveEndorsementCancellation(cancelRow.id, cancelReason);
      setNotice('Endorsement cancelled. The policy is back to its bound position.');
      setCancelRow(null);
      setCancelReason('');
      await load();
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  };

  const runPrepare = async () => {
    if (!prepareRow) return;
    setBusy(true);
    setError(null);
    try {
      await prepareEndorsement(prepareRow.id, prepareClearing);
      setPrepareRow(null);
      setPrepareClearing('');
      setNotice('Prepared. An independent Finance checker can now decide it.');
      await load();
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  };

  const runDecide = async (decision: 'approve' | 'reject') => {
    if (!decideRow) return;
    setBusy(true);
    setError(null);
    try {
      const updated = await decideEndorsement(decideRow.id, decision, decideNote, acceptException);
      setDecideRow(null);
      setDecideNote('');
      setAcceptException(false);
      setNotice(decision === 'approve' ? `Posted as ${updated.endorsement_no ?? 'endorsement'}.` : 'Endorsement rejected.');
      await load();
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  };

  const showFinanceTools = canManage && isFinance;

  return (
    <Card sx={{ mt: 2 }}>
      <CardContent>
        <Stack direction="row" alignItems="center" justifyContent="space-between" sx={{ mb: 1 }}>
          <Typography variant="h6">Endorsements</Typography>
          {canManage && policyActive && (
            <Button variant="contained" onClick={openForm}>
              Endorse
            </Button>
          )}
        </Stack>
        {position && (
          <Typography variant="body2" color="text.secondary" sx={{ mb: 1 }}>
            Current premium {formatSigned(position.current_gross_premium, position.currency)} · bound{' '}
            {formatSigned(position.bound_gross_premium, position.currency)} · {position.posted_endorsements} posted
          </Typography>
        )}
        {notice && (
          <Alert severity="success" sx={{ mb: 1 }} onClose={() => setNotice(null)}>
            {notice}
          </Alert>
        )}
        {error && (
          <Alert severity="error" sx={{ mb: 1 }} onClose={() => setError(null)}>
            {error}
          </Alert>
        )}
        {loading ? (
          <CircularProgress size={22} />
        ) : (
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>Number</TableCell>
                <TableCell>Effective</TableCell>
                <TableCell align="right">Premium delta</TableCell>
                <TableCell>Status</TableCell>
                <TableCell>Reason</TableCell>
                <TableCell align="right">Actions</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {list.length === 0 && (
                <TableRow>
                  <TableCell colSpan={6}>
                    <Typography variant="body2" color="text.secondary">
                      No endorsements on this policy.
                    </Typography>
                  </TableCell>
                </TableRow>
              )}
              {list.map((row) => {
                const calc = row.calculation;
                return (
                  <TableRow key={row.id}>
                    <TableCell>{row.endorsement_no ?? '—'}</TableCell>
                    <TableCell>{row.effective_date}</TableCell>
                    <TableCell align="right">
                      {calc ? formatSigned(calc.premium_delta, calc.currency) : '—'}
                    </TableCell>
                    <TableCell>
                      <Chip size="small" color={statusTone(row.status)} label={row.status} />
                    </TableCell>
                    <TableCell>
                      {(row.reason || '').length > 60 ? `${row.reason.slice(0, 60)}…` : row.reason}
                    </TableCell>
                    <TableCell align="right">
                      <Stack direction="row" spacing={1} justifyContent="flex-end">
                        <Button size="small" onClick={() => setNotesRow(notesRow?.id === row.id ? null : row)}>
                          Notes
                        </Button>
                        {canManage && isLive(row.status) && (
                          <Button size="small" onClick={() => setWithdrawRow(row)}>
                            Withdraw
                          </Button>
                        )}
                        {showFinanceTools && (row.status === 'proposed' || row.status === 'prepared') && (
                          <Button
                            size="small"
                            onClick={() => {
                              setPrepareRow(row);
                              setPrepareClearing('');
                            }}
                          >
                            Prepare
                          </Button>
                        )}
                        {showFinanceTools && (row.status === 'prepared' || row.status === 'proposed') && (
                          <Button
                            size="small"
                            color="primary"
                            onClick={() => {
                              setDecideRow(row);
                              setDecideNote('');
                              setAcceptException(false);
                            }}
                          >
                            Review
                          </Button>
                        )}
                        {/* E4. Finance-only, like every other money action here: the RPCs
                            assert it too, but offering the button to someone who cannot
                            use it wastes their time. */}
                        {showFinanceTools && row.status === 'posted' && (
                          <Button size="small" color="warning" onClick={() => void openCancel(row)}>
                            Cancel
                          </Button>
                        )}
                        {/* Settlement workflow. Same discipline: finance-only, because the
                            server refuses anyone else at the RPCs. */}
                        {showFinanceTools && row.status === 'posted' && (
                          <Button size="small" onClick={() => void openSettle(row)}>
                            Settle
                          </Button>
                        )}
                      </Stack>
                    </TableCell>
                  </TableRow>
                );
              })}
              {notesRow && (
                <TableRow><TableCell colSpan={6}>
                  <EndorsementNotes endorsementId={notesRow.id} />
                </TableCell></TableRow>
              )}
            </TableBody>
          </Table>
        )}
      </CardContent>

      {/* Propose dialog */}
      <Dialog open={formOpen} onClose={() => setFormOpen(false)} maxWidth="md" fullWidth>
        <DialogTitle>Propose an endorsement</DialogTitle>
        <DialogContent>
          <Grid container spacing={2} sx={{ mt: 0 }}>
            <Grid item xs={12} sm={4}>
              <TextField
                label="Effective date"
                type="date"
                value={effective}
                onChange={(e) => setEffective(e.target.value)}
                fullWidth
                InputLabelProps={{ shrink: true }}
              />
            </Grid>
            {shares.map((s, idx) => (
              <Grid item xs={12} sm={4} key={s.insurer_id || idx}>
                <TextField
                  label={`Agreed premium delta — ${s.name}`}
                  value={terms[idx]?.agreed_delta ?? ''}
                  onChange={(e) => {
                    // Build from `shares`, not from `terms`: if the form was opened before the
                    // shares finished loading, `terms` is still empty and mapping over it would
                    // silently drop what the user typed.
                    const value = e.target.value;
                    setTerms(
                      shares.map((sh, i) => ({
                        insurer_id: sh.insurer_id,
                        agreed_delta: i === idx ? value : terms[i]?.agreed_delta ?? '',
                      })),
                    );
                  }}
                  helperText="Signed; negative for a return premium. Leave empty for a descriptive-only endorsement."
                  fullWidth
                />
              </Grid>
            ))}
            <Grid item xs={12} sm={4}>
              <TextField
                label="New sum insured (optional)"
                value={changes.sum_insured}
                onChange={(e) => setChanges({ ...changes, sum_insured: e.target.value })}
                fullWidth
              />
            </Grid>
            <Grid item xs={12} sm={8}>
              <TextField
                label="Risk description change (optional)"
                value={changes.risk_description}
                onChange={(e) => setChanges({ ...changes, risk_description: e.target.value })}
                fullWidth
              />
            </Grid>
            <Grid item xs={12}>
              <TextField
                label="Notes (optional)"
                value={changes.notes}
                onChange={(e) => setChanges({ ...changes, notes: e.target.value })}
                fullWidth
              />
            </Grid>
            <Grid item xs={12}>
              <TextField
                label="Reason (at least 5 characters)"
                value={reason}
                onChange={(e) => setReason(e.target.value)}
                fullWidth
                multiline
                minRows={2}
              />
            </Grid>
            {quote && (
              <Grid item xs={12}>
                <Alert severity={quote.requires_review || quote.shares.some((s) => s.requires_review) ? 'warning' : 'info'}>
                  Premium delta {formatSigned(quote.premium_delta, quote.currency)} · commission{' '}
                  {formatSigned(quote.commission_delta, quote.currency)} at the bound {quote.commission_rate_pct}% ·{' '}
                  {quote.remaining_days} of {quote.total_days} days remain
                  {quote.shares.some((s) => s.requires_review) ? ' · a share delta exceeds its whole premium: Finance must accept it explicitly' : ''}
                </Alert>
              </Grid>
            )}
          </Grid>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setFormOpen(false)}>Cancel</Button>
          <Button onClick={runPreview} disabled={busy}>
            Calculate
          </Button>
          <Button variant="contained" onClick={submit} disabled={busy || reason.trim().length < 5}>
            Propose
          </Button>
        </DialogActions>
      </Dialog>

      {/* Withdraw dialog */}
      <Dialog open={Boolean(withdrawRow)} onClose={() => setWithdrawRow(null)}>
        <DialogTitle>Withdraw endorsement</DialogTitle>
        <DialogContent>
          <TextField
            label="Reason (at least 5 characters)"
            value={withdrawReason}
            onChange={(e) => setWithdrawReason(e.target.value)}
            fullWidth
            multiline
            minRows={2}
            sx={{ mt: 1 }}
          />
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setWithdrawRow(null)}>Cancel</Button>
          <Button color="warning" variant="contained" onClick={runWithdraw} disabled={busy || withdrawReason.trim().length < 5}>
            Withdraw
          </Button>
        </DialogActions>
      </Dialog>

      {/* E4: cancel a posted endorsement. The dialog leads with what the server
          says about the position, because the reasons are the useful part -- an
          approver who cannot unwind needs to know which movement to reverse first. */}
      <Dialog open={Boolean(cancelRow)} onClose={() => setCancelRow(null)} maxWidth="sm" fullWidth>
        <DialogTitle>Cancel endorsement {cancelRow?.endorsement_no ?? ''}</DialogTitle>
        <DialogContent>
          {cancelPosLoading ? (
            <CircularProgress size={24} sx={{ my: 2 }} />
          ) : cancelPosition ? (
            <Stack spacing={1.5} sx={{ mt: 1 }}>
              {cancelPosition.eligible ? (
                <Alert severity="info">
                  This reverses the endorsement in full and returns the policy to its bound
                  position. {cancelPosition.open_amount_to_clear
                    ? `It will clear ${formatSigned(cancelPosition.open_amount_to_clear, cancelPosition.currency ?? '')} of open items.`
                    : ''}
                </Alert>
              ) : (
                <Alert severity="warning">
                  <Typography variant="subtitle2" gutterBottom>This endorsement cannot be cancelled yet</Typography>
                  <ul style={{ margin: 0, paddingLeft: 18 }}>
                    {(cancelPosition.reasons ?? []).map((r) => <li key={r}>{r}</li>)}
                  </ul>
                </Alert>
              )}
              {cancelPosition.eligible && (
                <>
                  <TextField
                    label="Why is it being cancelled? (at least 5 characters)"
                    value={cancelReason}
                    onChange={(e) => setCancelReason(e.target.value)}
                    fullWidth
                    multiline
                    minRows={2}
                  />
                  <Typography variant="caption" color="text.secondary">
                    Preparing is not approving. A second Finance person must approve before any
                    journal is posted -- if this is you, the approve step will refuse it.
                  </Typography>
                </>
              )}
            </Stack>
          ) : null}
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setCancelRow(null)}>Close</Button>
          <Button
            color="warning"
            disabled={busy || !cancelPosition?.eligible || cancelReason.trim().length < 5}
            onClick={() => void runCancel()}
          >
            Prepare cancellation
          </Button>
          <Button
            color="error"
            variant="contained"
            disabled={busy || !cancelPosition?.eligible || cancelReason.trim().length < 5}
            onClick={() => void runApproveCancel()}
          >
            Approve (independent checker)
          </Button>
        </DialogActions>
      </Dialog>

      {/* Prepare dialog */}
      <Dialog open={Boolean(prepareRow)} onClose={() => setPrepareRow(null)}>
        <DialogTitle>Prepare for posting</DialogTitle>
        <DialogContent>
          <FormControl fullWidth sx={{ mt: 1 }}>
            <InputLabel id="endorsement-clearing-label">Endorsement clearing account</InputLabel>
            <Select
              labelId="endorsement-clearing-label"
              value={prepareClearing}
              label="Endorsement clearing account"
              onChange={(e) => setPrepareClearing(e.target.value)}
            >
              {clearingAccounts.map((a) => (
                <MenuItem key={a.id} value={a.id}>
                  {a.account_code} — {a.name}
                </MenuItem>
              ))}
            </Select>
          </FormControl>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setPrepareRow(null)}>Cancel</Button>
          <Button variant="contained" onClick={runPrepare} disabled={busy || !prepareClearing}>
            Prepare
          </Button>
        </DialogActions>
      </Dialog>

      {/* Decide dialog */}
      <Dialog open={Boolean(decideRow)} onClose={() => setDecideRow(null)} maxWidth="sm" fullWidth>
        <DialogTitle>{decideRow?.status === 'proposed' ? 'Prepare required first' : 'Finance decision'}</DialogTitle>
        <DialogContent>
          {decideRow?.status === 'proposed' && (
            <Alert severity="info" sx={{ mb: 1 }}>
              This proposal is not prepared yet — approve anyway is refused by the server; use Prepare first.
            </Alert>
          )}
          {decideRow?.calculation && (
            <Typography variant="body2" sx={{ mb: 1 }}>
              Premium delta {formatSigned(decideRow.calculation.premium_delta, decideRow.calculation.currency)} ·
              commission {formatSigned(decideRow.calculation.commission_delta, decideRow.calculation.currency)}
            </Typography>
          )}
          <TextField
            label="Review note (at least 5 characters)"
            value={decideNote}
            onChange={(e) => setDecideNote(e.target.value)}
            fullWidth
            multiline
            minRows={2}
            sx={{ mt: 1 }}
          />
          <FormControlLabel
            control={<Checkbox checked={acceptException} onChange={(e) => setAcceptException(e.target.checked)} />}
            label="Accept the flagged calculation explicitly (a share delta exceeds its whole premium)"
          />
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setDecideRow(null)}>Cancel</Button>
          <Button color="error" onClick={() => runDecide('reject')} disabled={busy || decideNote.trim().length < 5}>
            Reject
          </Button>
          <Button variant="contained" onClick={() => runDecide('approve')} disabled={busy || decideNote.trim().length < 5}>
            Approve and post
          </Button>
        </DialogActions>
      </Dialog>

      {/* Settlement workflow. One dialog lists the endorsement's open items and the
          settlements over them; each item can be settled in its own form, and each
          posted settlement can be voided with a reason. Money stays in the finance-gated
          RPCs -- this dialog only shapes the request. */}
      <Dialog open={Boolean(settleRow)} onClose={() => setSettleRow(null)} maxWidth="md" fullWidth>
        <DialogTitle>Settle endorsement {settleRow?.endorsement_no ?? ''}</DialogTitle>
        <DialogContent>
          {settleLoading ? (
            <CircularProgress size={24} sx={{ my: 4 }} />
          ) : settlePosition ? (
            <Stack spacing={2} sx={{ mt: 1 }}>
              {settleTarget === null ? (
                <>
                  <Alert severity="info">
                    The endorsement left open items. Settle them against client-money bank accounts; void a settlement
                    to reverse it. Insurance staff cannot do either -- the server refuses.
                  </Alert>
                  {settlePosition.items.length === 0 && (
                    <Typography variant="body2" color="text.secondary">No open items on this endorsement.</Typography>
                  )}
                  {settlePosition.items.map((item) => (
                    <Box key={item.id} sx={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 2, p: 1.5, border: 1, borderColor: 'divider', borderRadius: 1 }}>
                      <Box>
                        <Typography variant="body2">
                          {item.control_role} · {item.party_name} · {formatSigned(item.outstanding, item.currency)} outstanding
                        </Typography>
                        <Typography variant="caption" color="text.secondary">
                          {item.document_no || 'no document'} · side {item.side} · status {item.settlement_status}
                        </Typography>
                      </Box>
                      {item.outstanding > 0 ? (
                        <Button size="small" variant="contained" onClick={() => chooseSettleTarget(item)}>
                          {item.side === 'receivable' ? 'Collect' : 'Remit'}
                        </Button>
                      ) : (
                        <Chip size="small" label="settled" color="success" />
                      )}
                    </Box>
                  ))}
                  {settlePosition.settlements.length > 0 && (
                    <Typography variant="subtitle2">Posted settlements</Typography>
                  )}
                  {settlePosition.settlements.map((s) => (
                    <Box key={s.id} sx={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 2, p: 1.5, border: 1, borderColor: 'divider', borderRadius: 1 }}>
                      <Box>
                        <Typography variant="body2">
                          {s.settlement_no} · {s.direction === 'in' ? 'receipt' : 'payment'} · {formatSigned(s.amount, s.currency)}
                        </Typography>
                        <Typography variant="caption" color="text.secondary">
                          {s.settlement_date} · {s.party_name}{s.reference ? ` · ${s.reference}` : ''}{s.reconciled ? ' · bank reconciled' : ''}
                        </Typography>
                      </Box>
                      <Button
                        size="small"
                        color="warning"
                        onClick={() => { setVoidRow(s); setVoidReason(''); }}
                      >
                        Void settlement
                      </Button>
                    </Box>
                  ))}
                </>
              ) : (
                <Box>
                  <Typography variant="subtitle2" sx={{ mb: 1 }}>Settle {settleTarget.document_no || 'item'}</Typography>
                  <Typography variant="body2" sx={{ mb: 1 }}>
                    {settleTarget.control_role} · {settleTarget.party_name} · {formatSigned(settleTarget.outstanding, settleTarget.currency)} outstanding
                  </Typography>
                  <Stack spacing={2} sx={{ mt: 1 }}>
                    <TextField select label="Client-money bank account" value={settleBank} onChange={(e) => setSettleBank(e.target.value)} disabled={busy}>
                      {settleBanks.map((b) => (
                        <MenuItem key={b.id} value={b.id}>{b.name} ({b.currency})</MenuItem>
                      ))}
                    </TextField>
                    <TextField label="Amount" value={settleAmount} onChange={(e) => setSettleAmount(e.target.value)} inputProps={{ inputMode: 'decimal' }} disabled={busy} />
                    <TextField label="Settlement date" type="date" value={settleDate} onChange={(e) => setSettleDate(e.target.value)} InputLabelProps={{ shrink: true }} inputProps={{ max: today() }} disabled={busy} />
                    <TextField label="Bank reference" value={settleReference} onChange={(e) => setSettleReference(e.target.value)} disabled={busy} />
                    <TextField label="Notes" multiline value={settleNotes} onChange={(e) => setSettleNotes(e.target.value)} disabled={busy} />
                  </Stack>
                </Box>
              )}
            </Stack>
          ) : null}
        </DialogContent>
        <DialogActions>
          {settleTarget === null ? (
            <Button onClick={() => setSettleRow(null)}>Close</Button>
          ) : (
            <>
              <Button onClick={() => chooseSettleTarget(null)} disabled={busy}>Back</Button>
              <Button variant="contained" onClick={() => void runSettle()} disabled={busy}>Post settlement</Button>
            </>
          )}
        </DialogActions>
      </Dialog>

      <Dialog open={Boolean(voidRow)} onClose={() => setVoidRow(null)} maxWidth="sm" fullWidth>
        <DialogTitle>Void settlement {voidRow?.settlement_no ?? ''}</DialogTitle>
        <DialogContent>
          {voidRow && voidRow.reconciled && (
            <Alert severity="warning" sx={{ mb: 2 }}>
              This settlement is already bank-reconciled. The server will refuse the void until the reconciliation is unmatched by an independent reconciler.
            </Alert>
          )}
          <TextField
            label="Reason for voiding (at least 5 characters)"
            value={voidReason}
            onChange={(e) => setVoidReason(e.target.value)}
            fullWidth multiline minRows={2} sx={{ mt: 1 }} disabled={busy}
          />
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setVoidRow(null)} disabled={busy}>Close</Button>
          <Button color="error" variant="contained" onClick={() => void runVoid()} disabled={busy || voidReason.trim().length < 5 || (voidRow?.reconciled ?? false)}>
            Void settlement
          </Button>
        </DialogActions>
      </Dialog>
    </Card>
  );
}
