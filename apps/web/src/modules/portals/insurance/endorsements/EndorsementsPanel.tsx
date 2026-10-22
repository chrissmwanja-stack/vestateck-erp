// Endorsements on a policy: the propose dialog (insurance managers), the
// endorsements list, and the Finance maker/checker controls. The money math is
// server-side; this panel only shapes the request and shows the calculation.
import { useCallback, useEffect, useState } from 'react';
import {
  Alert,Button, Card, CardContent, Checkbox, Chip, CircularProgress, Dialog, DialogActions, DialogContent,
  DialogTitle, FormControl, Grid, InputLabel, MenuItem, Select, Stack, Table, TableBody, TableCell, TableHead,
  TableRow, TextField, Typography, FormControlLabel,
} from '@mui/material';
import { errorText, rows, rpc, table } from '../db';
import {
  buildChanges, buildTerms, decideEndorsement, formatSigned, isLive, prepareEndorsement, previewEndorsement,
  proposeEndorsement, reviewPosition, statusTone, withdrawEndorsement,
  type EndorsementCalculation, type EndorsementChangesDraft, type EndorsementPosition, type EndorsementRow,
  type EndorsementTermsDraft,
} from './workflow';

interface GlAccountOption {
  id: string;
  account_code: string;
  name: string;
}

const today = () => new Date().toISOString().slice(0, 10);

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
  const [effective, setEffective] = useState(today());
  const [terms, setTerms] = useState<EndorsementTermsDraft[]>([]);
  const [changes, setChanges] = useState<EndorsementChangesDraft>({ sum_insured: '', risk_description: '', notes: '' });
  const [reason, setReason] = useState('');
  const [quote, setQuote] = useState<EndorsementCalculation | null>(null);

  const [withdrawRow, setWithdrawRow] = useState<EndorsementRow | null>(null);
  const [withdrawReason, setWithdrawReason] = useState('');
  const [prepareRow, setPrepareRow] = useState<EndorsementRow | null>(null);
  const [prepareClearing, setPrepareClearing] = useState('');
  const [decideRow, setDecideRow] = useState<EndorsementRow | null>(null);
  const [decideNote, setDecideNote] = useState('');
  const [acceptException, setAcceptException] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const [items, pos, accounts, finance] = await Promise.all([
        rows<EndorsementRow>(
          table('ins_policy_endorsements').select('*').eq('policy_id', policyId).order('proposed_at', { ascending: false }),
        ),
        reviewPosition(policyId).catch(() => null),
        rows<GlAccountOption>(table('gl_accounts').select('id, account_code, name').order('account_code')).catch(() => []),
        rpc<boolean>('is_finance_team_member', { p_role: 'finance' }).catch(() => false),
      ]);
      setList(items);
      setPosition(pos);
      setClearingAccounts(accounts);
      setIsFinance(finance === true);
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
    const bound = position ? Math.max((position.current_gross_premium ?? 0) - (position.bound_gross_premium ?? 0), 0) : 0;
    setTerms(
      (position?.live_endorsements?.length ?? 0) === 0 && bound === 0 && position
        ? [{ insurer_id: '', agreed_delta: '' }]
        : [],
    );
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
  const shares: { insurer_id: string; label: string }[] = [{ insurer_id: '', label: 'All insurers on the policy' }];

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
                      </Stack>
                    </TableCell>
                  </TableRow>
                );
              })}
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
            {terms.map((t, idx) => (
              <Grid item xs={12} sm={4} key={idx}>
                <TextField
                  label={`Agreed premium delta${shares.length > 1 ? ` (${idx + 1})` : ''}`}
                  value={t.agreed_delta}
                  onChange={(e) =>
                    setTerms(terms.map((x, i) => (i === idx ? { ...x, agreed_delta: e.target.value } : x)))
                  }
                  helperText="Signed; negative for a return premium. Leave empty for a descriptive-only endorsement."
                  fullWidth
                />
              </Grid>
            ))}
            {terms.length === 0 && (
              <Grid item xs={12}>
                <Button size="small" onClick={() => setTerms([{ insurer_id: '', agreed_delta: '' }])}>
                  Add a premium change
                </Button>
              </Grid>
            )}
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
    </Card>
  );
}
