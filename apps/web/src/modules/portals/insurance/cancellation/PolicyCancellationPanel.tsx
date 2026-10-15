import { useCallback, useEffect, useRef, useState } from 'react';
import {
  Alert,
  Box,
  Button,
  Checkbox,
  Dialog,
  DialogActions,
  DialogContent,
  DialogTitle,
  FormControlLabel,
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
import { errorText, rpc } from '../db';
import { policyCashToday } from '../policyCash';
import { cents, money } from './calculation';
import CancellationCashPanel from './CancellationCashPanel';
import {
  cancellationCaseActions,
  cancellationPayload,
  newTermsDraft,
  parseCancellationContext,
  type CancellationCase,
  type CancellationContext,
  type CancellationQuote,
  type ChargeDraft,
  type TermsDraft,
} from './workflow';

function Quote({
  value,
  currency,
  names = {},
}: {
  value: CancellationQuote;
  currency: string;
  names?: Record<string, string>;
}) {
  return (
    <Box sx={{ my: 2 }}>
      <Typography>
        Invoice credit: {value.invoice_credit} {currency} · Credit against
        unpaid premium: {value.receivable_credit} · Client cash refund due:{' '}
        {value.client_refund_due}
      </Typography>
      <Alert severity="info">
        These are credits and liabilities—not available funds or payment
        authorization. A cash refund needs separate Finance approval and
        sufficient policy-specific funds.
      </Alert>
      <Box sx={{ overflowX: 'auto' }}>
        <Table size="small" aria-label="Cancellation calculation">
          <TableHead>
            <TableRow>
              <TableCell>Insurer</TableCell>
              <TableCell>Return premium</TableCell>
              <TableCell>Commission clawback</TableCell>
              <TableCell>Charge refund</TableCell>
              <TableCell>Net insurer credit</TableCell>
              <TableCell>Current payable / reduction / recovery</TableCell>
              <TableCell>Transferred commission cash to recover</TableCell>
            </TableRow>
          </TableHead>
          <TableBody>
            {value.insurers.map((s) => {
              const balance = value.insurer_balances?.find(
                (b) => b.insurer_id === s.insurer_id,
              );
              const applied = balance
                ? cents(balance.outstanding) < cents(s.total_insurer_credit)
                  ? cents(balance.outstanding)
                  : cents(s.total_insurer_credit)
                : null;
              const originalEntry = balance
                ? value.commission_entries?.find(
                    (e) => e.insurer_share_id === balance.insurer_share_id,
                  )
                : undefined;
              return (
                <TableRow key={s.insurer_id}>
                  <TableCell>{names[s.insurer_id] ?? s.insurer_id}</TableCell>
                  <TableCell>{s.return_premium}</TableCell>
                  <TableCell>{s.commission_clawback}</TableCell>
                  <TableCell>{s.pass_through_refund}</TableCell>
                  <TableCell>{s.total_insurer_credit}</TableCell>
                  <TableCell>
                    {balance && applied !== null
                      ? `${balance.outstanding} / ${money(applied)} / ${money(cents(s.total_insurer_credit) - applied)}`
                      : 'Finance preparation required'}
                  </TableCell>
                  <TableCell>
                    {originalEntry?.status === 'transferred'
                      ? s.commission_clawback
                      : '0.00'}
                  </TableCell>
                </TableRow>
              );
            })}
          </TableBody>
        </Table>
      </Box>
      {value.cash_position && (
        <Typography variant="body2">
          Reviewed historical cash: collected {value.cash_position.collected};
          remitted {value.cash_position.remitted}; commission withdrawn{' '}
          {value.cash_position.commission_transferred}. These are not
          uncommitted refund funds.
        </Typography>
      )}
      {value.requires_finance_exception && (
        <Alert severity="warning">
          Contains a manual exception. An independent Finance checker must
          explicitly accept its documented basis.
        </Alert>
      )}
    </Box>
  );
}
function Evidence({ row }: { row: CancellationCase }) {
  return (
    <Box sx={{ my: 1 }}>
      <Typography variant="subtitle2">Recorded contractual evidence</Typography>
      {row.accounting_mappings && (
        <Typography variant="body2">
          Original commission accounting:{' '}
          {row.accounting_mappings.commission_treatment}
        </Typography>
      )}
      {row.insurer_terms.map((s) => (
        <Typography variant="body2" key={s.insurer_id}>
          {s.insurer_id}: {s.terms.method} · {s.terms.contract_reference} ·
          Minimum retained {s.terms.minimum_retained_premium ?? '0'}
          {s.terms.short_period_bands?.length
            ? ` · Short-period bands: ${s.terms.short_period_bands.map((b) => `${b.through_day} days: ${b.retained_pct}% retained`).join('; ')}`
            : ''}
          {s.terms.method === 'manual_review'
            ? ` · Proposed manual return ${s.terms.manual_return_premium}`
            : ''}
        </Typography>
      ))}
      {row.charge_refunds.map((c) => (
        <Box key={c.charge_id}>
          <Typography variant="body2">
            Charge {c.charge_id}: refund {c.refund_amount} · {c.basis}
          </Typography>
          {c.insurer_refunds?.map((r) => (
            <Typography variant="caption" display="block" key={r.insurer_id}>
              {r.insurer_id}: {r.refund_amount} · {r.basis}
            </Typography>
          ))}
        </Box>
      ))}
    </Box>
  );
}
export default function PolicyCancellationPanel({
  policyId,
  onPosted,
  cashMode = 'view',
}: {
  policyId: string;
  cashMode?: 'view' | 'finance';
  onPosted?: () => void | Promise<void>;
}) {
  const [context, setContext] = useState<CancellationContext | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [offset, setOffset] = useState(0);
  const [form, setForm] = useState(false);
  const [effective, setEffective] = useState(policyCashToday());
  const [reason, setReason] = useState('');
  const [terms, setTerms] = useState<Record<string, TermsDraft>>({});
  const [charges, setCharges] = useState<Record<string, ChargeDraft>>({});
  const [preview, setPreview] = useState<CancellationQuote | null>(null);
  const [clearing, setClearing] = useState<Record<string, string>>({});
  const [decision, setDecision] = useState<{
    row: CancellationCase;
    action: 'approve' | 'reject' | 'withdraw';
  } | null>(null);
  const [note, setNote] = useState('');
  const [acceptException, setAcceptException] = useState(false);
  const generation = useRef(0);
  const inFlight = useRef(false);
  const retry = useRef({ fingerprint: '', key: '' });
  const names = Object.fromEntries(
    (context?.insurers ?? []).map((s) => [s.insurer_id, s.insurer_name]),
  );
  const load = useCallback(async () => {
    const g = ++generation.current;
    try {
      const response = await rpc<unknown>('ins_policy_cancellation_context', {
        p_policy_id: policyId,
        p_offset: offset,
      });
      const value = parseCancellationContext(response, policyId);
      if (g === generation.current) {
        setContext(value);
        setError(null);
      }
    } catch (e) {
      if (g === generation.current) {
        setContext(null);
        setError(errorText(e));
      }
    }
  }, [policyId, offset]);
  useEffect(() => {
    setContext(null);
    setForm(false);
    setPreview(null);
    setDecision(null);
    void load();
    return () => {
      generation.current++;
    };
  }, [load]);
  const perform = async (operation: () => Promise<void>) => {
    if (inFlight.current) return;
    inFlight.current = true;
    setBusy(true);
    setError(null);
    try {
      await operation();
    } catch (e) {
      setError(errorText(e));
    } finally {
      inFlight.current = false;
      setBusy(false);
    }
  };
  const editTerms = (id: string, change: Partial<TermsDraft>) => {
    setPreview(null);
    setTerms((v) => ({
      ...v,
      [id]: { ...(v[id] ?? newTermsDraft()), ...change },
    }));
  };
  const editCharge = (id: string, change: Partial<ChargeDraft>) => {
    setPreview(null);
    setCharges((v) => ({ ...v, [id]: { ...v[id], ...change } }));
  };
  const openForm = () => {
    if (!context) return;
    setTerms(
      Object.fromEntries(
        context.insurers.map((s) => [s.insurer_id, newTermsDraft()]),
      ),
    );
    setCharges(
      Object.fromEntries(
        context.charges.map((c) => [
          c.id,
          {
            refund: '',
            basis: '',
            confirmed: false,
            recipients: Object.fromEntries(
              c.original_allocations.map((r) => [
                r.insurer_id,
                { refund: '', basis: '' },
              ]),
            ),
          },
        ]),
      ),
    );
    setReason('');
    setEffective(policyCashToday());
    setPreview(null);
    setForm(true);
  };
  const calculate = () =>
    perform(async () => {
      if (!context) return;
      const payload = cancellationPayload(
        context,
        effective,
        reason,
        terms,
        charges,
      );
      setPreview(
        await rpc<CancellationQuote>('ins_preview_policy_cancellation', {
          p_policy_id: policyId,
          p_effective_date: effective,
          p_insurer_terms: payload.p_insurer_terms,
          p_charge_refunds: payload.p_charge_refunds,
        }),
      );
    });
  const propose = () =>
    perform(async () => {
      if (!context || !preview) return;
      const payload = cancellationPayload(
        context,
        effective,
        reason,
        terms,
        charges,
      );
      const fingerprint = JSON.stringify(payload);
      if (retry.current.fingerprint !== fingerprint)
        retry.current = { fingerprint, key: crypto.randomUUID() };
      await rpc('ins_submit_policy_cancellation', {
        ...payload,
        p_request_key: retry.current.key,
      });
      setForm(false);
      setPreview(null);
      await load();
    });
  const prepare = (row: CancellationCase) =>
    perform(async () => {
      const account = clearing[row.id] ?? row.clearing_gl_account_id;
      if (!account)
        throw new Error('Choose the cancellation clearing account.');
      await rpc('ins_prepare_policy_cancellation', {
        p_cancellation_id: row.id,
        p_clearing_gl_account_id: account,
      });
      await load();
    });
  const decide = () =>
    perform(async () => {
      if (!decision) return;
      if (decision.action === 'withdraw')
        await rpc('ins_withdraw_policy_cancellation', {
          p_cancellation_id: decision.row.id,
          p_reason: note,
        });
      else
        await rpc('ins_decide_policy_cancellation', {
          p_cancellation_id: decision.row.id,
          p_decision: decision.action,
          p_review_note: note,
          p_accept_manual_exception: acceptException,
        });
      const posted = decision.action === 'approve';
      setDecision(null);
      await load();
      if (posted) await onPosted?.();
    });
  return (
    <Box sx={{ my: 3 }}>
      <Stack direction="row" spacing={2}>
        <Typography variant="h6">Policy cancellation</Typography>
        <Button disabled={busy} onClick={() => void load()}>
          Refresh cancellation
        </Button>
      </Stack>
      {error && <Alert severity="error">{error}</Alert>}
      {!context && !error && (
        <Typography>Loading cancellation review…</Typography>
      )}
      {context && (
        <>
          <Alert severity="info">
            Cancellation is separate from reverse-and-reissue. Original bind and
            cash records stay intact. Existing claims block v1. Only this policy
            is considered; linked renewals are not automatically cancelled.
          </Alert>
          {context.has_claims && (
            <Alert severity="warning">
              This policy has an existing claim. Cancellation is not supported
              in v1.
            </Alert>
          )}
          {context.can_propose &&
            !context.has_claims &&
            ['active', 'renewed'].includes(context.policy_status) &&
            !(
              context.has_live_case ??
              context.cases.some((c) =>
                ['proposed', 'prepared', 'posted'].includes(c.status),
              )
            ) && (
              <Button onClick={openForm} disabled={busy}>
                Propose cancellation
              </Button>
            )}
          {context.cases.map((row) => {
            const actions = cancellationCaseActions(context, row);
            return (
              <Box
                key={row.id}
                sx={{
                  border: '1px solid',
                  borderColor: 'divider',
                  borderRadius: 1,
                  p: 2,
                  mt: 2,
                }}
              >
                <Typography variant="subtitle1">
                  {row.cancellation_no ?? `Proposal ${row.id}`} · {row.status}
                </Typography>
                <Typography>
                  Effective: {row.effective_date} · {row.reason}
                </Typography>
                <Typography variant="caption">
                  Proposer: {row.proposed_by} · Finance maker:{' '}
                  {row.prepared_by ?? 'not prepared'} · Checker:{' '}
                  {row.checked_by ?? 'not checked'}
                </Typography>
                <Evidence row={row} />
                <Quote
                  value={row.calculation}
                  currency={context.currency}
                  names={names}
                />
                {row.status === 'posted' && (
                  <>
                    <Alert severity="warning">
                      Cancellation posted on {row.posting_date}. No cash was
                      paid by approval. Recovery/refund payment controls are a
                      separate workflow and are not enabled by this action.
                    </Alert>
                    <CancellationCashPanel policyId={policyId} mode={cashMode} />
                    {row.insurer_adjustments.map((a) => (
                      <Typography key={a.insurer_id}>
                        {a.insurer_name}: payable reduced {a.payable_credit};
                        insurer recovery due {a.recovery_due}; retained
                        commission {a.retained_commission}; transferred
                        commission to recover {a.transferred_clawback_due}.
                      </Typography>
                    ))}
                    {row.credits.map((c) => (
                      <Typography
                        variant="caption"
                        display="block"
                        key={c.credit_note_id}
                      >
                        Credit {c.credit_note_no} · {c.amount} · Journal{' '}
                        {c.journal_entry_id}
                      </Typography>
                    ))}
                    {row.journals.map((j) => (
                      <Typography
                        variant="caption"
                        display="block"
                        key={j.journal_entry_id}
                      >
                        {j.purpose}: {j.journal_entry_id}
                      </Typography>
                    ))}
                    {row.refund_item_id && (
                      <Typography variant="caption">
                        Refund liability reference: {row.refund_item_id}
                      </Typography>
                    )}
                  </>
                )}
                {row.review_note && (
                  <Typography>Review: {row.review_note}</Typography>
                )}
                {actions.includes('prepare') && (
                  <Stack direction="row" spacing={1} sx={{ my: 1 }}>
                    <TextField
                      select
                      label="Cancellation clearing account"
                      sx={{ minWidth: 260 }}
                      value={
                        clearing[row.id] ?? row.clearing_gl_account_id ?? ''
                      }
                      onChange={(e) =>
                        setClearing((v) => ({ ...v, [row.id]: e.target.value }))
                      }
                      disabled={busy}
                    >
                      {context.clearing_accounts.map((a) => (
                        <MenuItem key={a.id} value={a.id}>
                          {a.account_code} — {a.name}
                        </MenuItem>
                      ))}
                    </TextField>
                    <Button disabled={busy} onClick={() => void prepare(row)}>
                      {row.status === 'prepared'
                        ? 'Refresh Finance preparation'
                        : 'Prepare for Finance approval'}
                    </Button>
                  </Stack>
                )}
                {actions
                  .filter((a) => a !== 'prepare')
                  .map((action) => (
                    <Button
                      key={action}
                      disabled={busy}
                      color={action === 'approve' ? 'error' : 'primary'}
                      onClick={() => {
                        setDecision({ row, action });
                        setNote('');
                        setAcceptException(false);
                      }}
                    >
                      {action === 'approve'
                        ? 'Review and approve cancellation'
                        : action === 'reject'
                          ? 'Reject proposal'
                          : 'Withdraw proposal'}
                    </Button>
                  ))}
              </Box>
            );
          })}
          {context.cases.length === 0 && (
            <Typography sx={{ my: 1 }}>
              No cancellation proposals for this policy.
            </Typography>
          )}
          <Stack direction="row">
            <Button
              disabled={busy || offset === 0}
              onClick={() => setOffset((v) => Math.max(0, v - 20))}
            >
              Earlier page
            </Button>
            <Button
              disabled={busy || !context.has_more}
              onClick={() => setOffset((v) => v + 20)}
            >
              Next page
            </Button>
          </Stack>
        </>
      )}
      <Dialog
        open={form}
        onClose={() => {
          if (!busy) setForm(false);
        }}
        maxWidth="md"
        fullWidth
      >
        <DialogTitle>Propose policy cancellation</DialogTitle>
        <DialogContent>
          <Alert severity="warning">
            Record each insurer’s actual contractual terms. Do not invent a
            short-period rate. Pro-rata is a fallback only where permitted.
            Cover dates are inclusive; the effective cancellation day is not
            earned cover. Proposal submission does not cancel cover or authorize
            a refund.
          </Alert>
          <Stack spacing={2} sx={{ mt: 2 }}>
            <TextField
              type="date"
              label="Effective cancellation date"
              InputLabelProps={{ shrink: true }}
              value={effective}
              onChange={(e) => {
                setEffective(e.target.value);
                setPreview(null);
              }}
              disabled={busy}
            />
            <TextField
              label="Cancellation reason"
              value={reason}
              onChange={(e) => {
                setReason(e.target.value);
                setPreview(null);
              }}
              disabled={busy}
              multiline
            />
            {context?.insurers.map((s) => {
              const t = terms[s.insurer_id] ?? newTermsDraft();
              return (
                <Box key={s.insurer_id}>
                  <Typography variant="subtitle1">
                    {s.insurer_name} · Original premium {s.premium_amount} ·
                    Original commission {s.commission_rate_pct}% (
                    {s.commission_amount})
                  </Typography>
                  <Stack spacing={1} sx={{ my: 1 }}>
                    <TextField
                      select
                      label={`${s.insurer_name} cancellation method`}
                      value={t.method}
                      onChange={(e) =>
                        editTerms(s.insurer_id, {
                          method: e.target.value as TermsDraft['method'],
                        })
                      }
                      disabled={busy}
                    >
                      <MenuItem value="pro_rata">
                        Contract permits pro-rata
                      </MenuItem>
                      <MenuItem value="short_period">
                        Contractual short-period schedule
                      </MenuItem>
                      <MenuItem value="non_refundable">
                        Contractually non-refundable premium
                      </MenuItem>
                      <MenuItem value="manual_review">
                        Manual Finance exception
                      </MenuItem>
                    </TextField>
                    <TextField
                      label={`${s.insurer_name} contract / evidence reference`}
                      value={t.reference}
                      onChange={(e) =>
                        editTerms(s.insurer_id, { reference: e.target.value })
                      }
                      disabled={busy}
                    />
                    <TextField
                      label={`${s.insurer_name} minimum retained premium`}
                      value={t.minimum}
                      onChange={(e) =>
                        editTerms(s.insurer_id, { minimum: e.target.value })
                      }
                      disabled={busy}
                      helperText="Leave blank only if no contractual minimum applies."
                    />
                    {t.method === 'pro_rata' && (
                      <FormControlLabel
                        control={
                          <Checkbox
                            checked={t.prorataPermitted}
                            onChange={(e) =>
                              editTerms(s.insurer_id, {
                                prorataPermitted: e.target.checked,
                              })
                            }
                            disabled={busy}
                          />
                        }
                        label="The contract permits pro-rata and no more specific cancellation method applies"
                      />
                    )}
                    {t.method === 'short_period' && (
                      <TextField
                        multiline
                        minRows={3}
                        label={`${s.insurer_name} short-period schedule`}
                        value={t.bands}
                        onChange={(e) =>
                          editTerms(s.insurer_id, { bands: e.target.value })
                        }
                        disabled={busy}
                        helperText="One band per line: through day : retained %. Example 30:20. Enter actual terms; final band must cover the full term at 100%."
                      />
                    )}
                    {t.method === 'manual_review' && (
                      <TextField
                        label={`${s.insurer_name} proposed return premium`}
                        value={t.manualReturn}
                        onChange={(e) =>
                          editTerms(s.insurer_id, {
                            manualReturn: e.target.value,
                          })
                        }
                        disabled={busy}
                        helperText="Not approved here. Independent Finance exception acceptance is mandatory."
                      />
                    )}
                  </Stack>
                </Box>
              );
            })}
            {context?.charges.map((c) => {
              const d = charges[c.id];
              return (
                d && (
                  <Box key={c.id}>
                    <Typography variant="subtitle1">
                      {c.description} ·{' '}
                      {c.kind === 'broker_fee'
                        ? 'Broker fee'
                        : 'Insurer pass-through'}{' '}
                      · Original {c.amount}, VAT {c.vat_amount}
                    </Typography>
                    <Stack spacing={1}>
                      <TextField
                        label={`${c.description} refundable base`}
                        value={d.refund}
                        onChange={(e) =>
                          editCharge(c.id, { refund: e.target.value })
                        }
                        disabled={busy}
                        helperText="Enter an explicit amount, including zero. VAT credit follows original charged VAT."
                      />
                      <TextField
                        label={`${c.description} refund / retention basis`}
                        value={d.basis}
                        onChange={(e) =>
                          editCharge(c.id, { basis: e.target.value })
                        }
                        disabled={busy}
                      />
                      {c.original_allocations.map((r) => (
                        <Stack spacing={1} key={r.insurer_id}>
                          <Typography>
                            {r.insurer_name} originally received {r.amount}
                          </Typography>
                          <TextField
                            label={`${c.description} — ${r.insurer_name} refund`}
                            value={d.recipients[r.insurer_id]?.refund ?? ''}
                            onChange={(e) =>
                              editCharge(c.id, {
                                recipients: {
                                  ...d.recipients,
                                  [r.insurer_id]: {
                                    ...d.recipients[r.insurer_id],
                                    refund: e.target.value,
                                  },
                                },
                              })
                            }
                            disabled={busy}
                          />
                          <TextField
                            label={`${c.description} — ${r.insurer_name} basis`}
                            value={d.recipients[r.insurer_id]?.basis ?? ''}
                            onChange={(e) =>
                              editCharge(c.id, {
                                recipients: {
                                  ...d.recipients,
                                  [r.insurer_id]: {
                                    ...d.recipients[r.insurer_id],
                                    basis: e.target.value,
                                  },
                                },
                              })
                            }
                            disabled={busy}
                          />
                        </Stack>
                      ))}
                      <FormControlLabel
                        control={
                          <Checkbox
                            checked={d.confirmed}
                            onChange={(e) =>
                              editCharge(c.id, { confirmed: e.target.checked })
                            }
                            disabled={busy}
                          />
                        }
                        label="I have recorded the contractual/legal basis for refunding or retaining this charge"
                      />
                    </Stack>
                  </Box>
                )
              );
            })}
          </Stack>
          {preview && context && (
            <Quote value={preview} currency={context.currency} names={names} />
          )}
          {error && <Alert severity="error">{error}</Alert>}
        </DialogContent>
        <DialogActions>
          <Button disabled={busy} onClick={() => setForm(false)}>
            Close
          </Button>
          <Button disabled={busy} onClick={() => void calculate()}>
            Calculate for review
          </Button>
          <Button disabled={busy || !preview} onClick={() => void propose()}>
            Submit proposal only
          </Button>
        </DialogActions>
      </Dialog>
      <Dialog
        open={!!decision}
        onClose={() => {
          if (!busy) setDecision(null);
        }}
        maxWidth="md"
        fullWidth
      >
        <DialogTitle>
          {decision?.action === 'approve'
            ? 'Independently approve and post cancellation?'
            : decision?.action === 'reject'
              ? 'Reject cancellation proposal?'
              : 'Withdraw cancellation proposal?'}
        </DialogTitle>
        <DialogContent>
          {decision?.action === 'approve' && (
            <>
              <Alert severity="warning">
                This cancels the policy and posts linked credits, recoveries and
                refund liabilities dated today. It does not pay cash. Review
                each insurer’s terms, charge decisions and current balances.
              </Alert>
              <Evidence row={decision.row} />
              {context && (
                <Quote
                  value={decision.row.calculation}
                  currency={context.currency}
                  names={names}
                />
              )}
            </>
          )}
          <TextField
            fullWidth
            multiline
            label="Detailed review / decision note"
            value={note}
            onChange={(e) => setNote(e.target.value)}
            disabled={busy}
            sx={{ mt: 2 }}
          />
          {decision?.action === 'approve' &&
            decision.row.calculation.requires_finance_exception && (
              <FormControlLabel
                control={
                  <Checkbox
                    checked={acceptException}
                    onChange={(e) => setAcceptException(e.target.checked)}
                    disabled={busy}
                  />
                }
                label="As independent Finance checker, I explicitly accept the documented insurer-specific manual exception"
              />
            )}
          {error && <Alert severity="error">{error}</Alert>}
        </DialogContent>
        <DialogActions>
          <Button disabled={busy} onClick={() => setDecision(null)}>
            Back
          </Button>
          <Button
            color="error"
            disabled={
              busy ||
              note.trim().length < 5 ||
              (decision?.action === 'approve' &&
                decision.row.calculation.requires_finance_exception &&
                !acceptException)
            }
            onClick={() => void decide()}
          >
            {decision?.action === 'approve'
              ? 'Approve and post cancellation — no cash payment'
              : 'Confirm decision'}
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}
