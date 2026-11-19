import { useCallback, useEffect, useState } from 'react';
import {
  Alert,
  Autocomplete,
  Box,
  Button,
  Chip,
  Dialog,
  DialogActions,
  DialogContent,
  DialogTitle,
  Paper,
  Stack,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableRow,
  TextField,
  Tooltip,
  Typography,
} from '@mui/material';
import { db } from './db';
import {
  counterAccountBlockReason,
  type AdjustmentApprovalMode,
  type AdjustmentEventRow,
  type AdjustmentRow,
  type GlAccountOption,
  type StatementLine,
} from './types';
import { useAdjustmentHistory } from './useBankAdjustments';

// Bank adjustments (D4e): book a statement line that has no book entry, such
// as a bank charge or interest. Two people are involved by design. One
// proposes an adjustment and picks the other side of the entry; a DIFFERENT
// finance user approves it, which posts the journal entry and matches the line
// in one step.
//
// The server enforces everything here (create_bank_adjustment /
// approve_bank_adjustment / reject_bank_adjustment /
// request_bank_adjustment_reversal / bank_adjustment_can_self_approve); this
// panel asks rather than assumes, so that:
//   - a one-person finance team whose company has approved the
//     allow_self_approved_bank_adjustments setting can actually approve their
//     own proposal, and is told plainly that it will be flagged for the
//     accountant (bank_adjustment_exceptions);
//   - everyone else still cannot, and the button says why;
//   - an account the server would refuse (header, AR/AP control, bank/cash) is
//     explained in the picker instead of only in an error after clicking;
//   - a rejected proposal owned by the reader can be reworked as a linked row,
//     so the audit chain exists rather than a lookalike second proposal.
//
// Tax codes are deliberately absent: deferred by decision (19 Nov 2026) because
// no accounting treatment has been agreed.

type Mode = 'approve' | 'reject' | 'reverse';

const STATUS_COLOR: Record<AdjustmentRow['status'], 'warning' | 'success' | 'default' | 'error'> = {
  pending: 'warning',
  posted: 'success',
  rejected: 'default',
  reversed: 'error',
};

const EVENT_LABEL: Record<AdjustmentEventRow['event'], string> = {
  created: 'Proposed',
  reworked: 'Reworked from a rejected proposal',
  approved: 'Approved and posted',
  rejected: 'Rejected',
  reversal_requested: 'Reversal requested',
  reversed: 'Reversed',
};

const DIALOG_COPY: Record<Mode, { title: string; label?: string; required?: boolean; confirm: string }> = {
  approve: { title: 'Approve adjustment', confirm: 'Approve and post' },
  reject: { title: 'Reject adjustment', label: 'Why is it being rejected?', required: true, confirm: 'Reject' },
  reverse: { title: 'Reverse adjustment', label: 'Why is it being reversed?', required: true, confirm: 'Request reversal' },
};

function signedAmount(r: Pick<AdjustmentRow, 'amount' | 'direction'>): number {
  const n = Number(r.amount);
  return r.direction === 'out' ? -n : n;
}

function formatSigned(r: Pick<AdjustmentRow, 'amount' | 'direction'>): string {
  const n = signedAmount(r);
  return `${n > 0 ? '+' : ''}${n.toLocaleString()}`;
}

function modeLabel(mode: AdjustmentApprovalMode | undefined): string | null {
  if (mode === 'one_person_exception') return 'self-approved under the one-person exception';
  if (mode === 'two_person') return 'approved by a second finance user';
  return null;
}

export function BankAdjustmentsPanel({
  bankAccountName,
  selectedLine,
  onChanged,
  onError,
  onSelectLine,
}: {
  // The registry name of the account on screen (the same value the statement
  // queries use). Rows are filtered to this bank.
  bankAccountName: string | null;
  selectedLine: StatementLine | null;
  onChanged: (message: string) => void;
  onError: (message: string) => void;
  /** Selects a statement line in the screen above (Rework, and drill-through
   *  from a row to the line it was booked against). */
  onSelectLine?: (lineId: string) => void;
}) {
  const [rows, setRows] = useState<AdjustmentRow[]>([]);
  const [glAccounts, setGlAccounts] = useState<GlAccountOption[]>([]);
  const [canSelfApprove, setCanSelfApprove] = useState(false);
  const [me, setMe] = useState<string | null>(null);
  const [counter, setCounter] = useState<GlAccountOption | null>(null);
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);
  const [dialog, setDialog] = useState<{ mode: Mode; row: AdjustmentRow } | null>(null);
  const [note, setNote] = useState('');
  const [loadError, setLoadError] = useState<string | null>(null);
  const [reworkFrom, setReworkFrom] = useState<AdjustmentRow | null>(null);
  const [reworkLineId, setReworkLineId] = useState<string | null>(null);
  const [historyFor, setHistoryFor] = useState<AdjustmentRow | null>(null);

  const load = useCallback(async () => {
    setLoadError(null);
    const [adj, gl, selfApprove, user] = await Promise.all([
      db
        .from('bank_adjustments')
        .select(
          'id, kind, status, amount, currency, direction, reason, bank_account, bank_statement_line_id, created_by, created_at, decided_by, decided_at, self_approved, approval_mode, rejection_reason, reversal_reason, reworked_from, reverses_adjustment_id, journal_entry_id, line:bank_statement_lines!bank_adjustments_statement_line_id_fkey(statement_date, description, reference), counter:gl_accounts!bank_adjustments_counter_account_id_fkey(account_code, name)'
        )
        .order('created_at', { ascending: false })
        .limit(100),
      db
        .from('gl_accounts')
        .select('id, account_code, name, is_header, is_control_account')
        .eq('is_active', true)
        .order('account_code'),
      db.rpc('bank_adjustment_can_self_approve'),
      db.auth.getUser(),
    ]);
    if (adj.error) {
      setLoadError(adj.error.message ?? 'Could not load bank adjustments.');
      return;
    }
    setRows((adj.data ?? []) as unknown as AdjustmentRow[]);
    setGlAccounts((gl.data ?? []) as GlAccountOption[]);
    // A failed permission read is "no", never "yes": the server would refuse
    // anyway, and offering the button would be a lie.
    setCanSelfApprove(!selfApprove.error && selfApprove.data === true);
    setMe(user.data?.user?.id ?? null);
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  // Starting a rework: prefill from the rejected row, and pull its statement
  // line into the picker above so the new proposal is against the same line.
  const beginRework = useCallback(
    (row: AdjustmentRow) => {
      setReworkFrom(row);
      setReworkLineId(row.bank_statement_line_id ?? null);
      setReason(row.reason);
      const match = glAccounts.find((a) => a.account_code === row.counter?.account_code);
      setCounter(match ?? null);
      // Pull the same statement line back into the picker above so the rework
      // is proposed against it (the server requires the same line).
      if (row.bank_statement_line_id && onSelectLine) onSelectLine(row.bank_statement_line_id);
    },
    [glAccounts, onSelectLine]
  );

  function cancelRework() {
    setReworkFrom(null);
    setReworkLineId(null);
    setReason('');
    setCounter(null);
  }

  async function propose() {
    if (!selectedLine || !counter) return;
    setBusy(true);
    const { error } = await db.rpc('create_bank_adjustment', {
      p_statement_line_id: selectedLine.id,
      p_counter_account_id: counter.id,
      p_reason: reason.trim(),
      // Only sent when reworking, so an ordinary proposal stays a 3-argument
      // call and the server records which rejected row this replaces.
      ...(reworkFrom ? { p_reworked_from: reworkFrom.id } : {}),
    });
    setBusy(false);
    if (error) {
      onError(error.message ?? 'Could not propose that adjustment.');
      return;
    }
    const wasRework = reworkFrom !== null;
    setCounter(null);
    setReason('');
    setReworkFrom(null);
    setReworkLineId(null);
    await load();
    onChanged(
      wasRework
        ? 'Rework proposed and linked to the rejected adjustment. A different finance user must approve it.'
        : 'Adjustment proposed. A different finance user must approve it before anything is posted.'
    );
  }

  async function decide() {
    if (!dialog) return;
    const { mode, row } = dialog;
    const text = note.trim();
    const spec = DIALOG_COPY[mode];
    if (spec.required && text.length < 5) return;
    setBusy(true);
    const { error } =
      mode === 'approve'
        ? await db.rpc('approve_bank_adjustment', { p_adjustment_id: row.id })
        : mode === 'reject'
          ? await db.rpc('reject_bank_adjustment', { p_adjustment_id: row.id, p_reason: text })
          : await db.rpc('request_bank_adjustment_reversal', { p_adjustment_id: row.id, p_reason: text });
    setBusy(false);
    if (error) {
      onError(error.message ?? 'That action failed.');
      setDialog(null);
      return;
    }
    setDialog(null);
    setNote('');
    await load();
    // A rework that has just been proposed supersedes the row it replaced, so
    // clear the rework banner if it was that one.
    if (reworkFrom && mode === 'approve') setReworkFrom(null);
    if (mode === 'approve') {
      const selfApproved = row.created_by === me;
      onChanged(
        selfApproved
          ? 'Self-approved and posted under your company’s one-person exception. It is flagged for the accountant in the adjustment register.'
          : row.kind === 'reversal'
            ? 'Reversal approved and posted; the statement line is unmatched again.'
            : 'Adjustment approved and posted; the statement line is matched.'
      );
    } else if (mode === 'reject') {
      onChanged(row.created_by === me ? 'Adjustment withdrawn.' : 'Adjustment rejected. Nothing was posted.');
    } else {
      onChanged('Reversal requested. A different finance user must approve it before the reversal posts.');
    }
  }

  const account = bankAccountName?.trim() ?? '';
  const visible = account ? rows.filter((r) => r.bank_account === account) : rows;
  const copy = dialog ? DIALOG_COPY[dialog.mode] : null;
  const counterBlock = counter ? counterAccountBlockReason(counter) : null;
  const canPropose = Boolean(selectedLine && counter && !counterBlock && reason.trim().length >= 5) && !busy;
  const pendingOwn = visible.filter((r) => r.status === 'pending' && r.created_by === me);

  return (
    <Paper sx={{ p: 2, mb: 3 }} data-testid="bank-adjustments-panel">
      <Stack direction="row" alignItems="center" spacing={1} sx={{ mb: 0.5 }}>
        <Typography variant="subtitle1">Bank adjustments</Typography>
        {canSelfApprove && (
          <Chip
            size="small"
            color="warning"
            variant="outlined"
            label="one-person exception active"
            data-testid="self-approve-chip"
          />
        )}
      </Stack>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
        For a statement line with no book entry (a bank charge, interest received, an unrecorded deposit). Select the
        line above, choose the other side of the entry and say why. A different finance user then approves it, which
        posts the entry and matches the line.
      </Typography>

      {canSelfApprove && (
        <Alert severity="warning" sx={{ mb: 2 }} data-testid="self-approve-banner">
          Your company has approved the one-person exception for bank adjustments. You may approve your own proposal,
          but it is recorded as self-approved and listed in the adjustment register for the accountant to sign off.
        </Alert>
      )}

      {loadError && <Alert severity="error" sx={{ mb: 2 }}>{loadError}</Alert>}

      {pendingOwn.length > 0 && !canSelfApprove && (
        <Alert severity="info" sx={{ mb: 2 }} data-testid="pending-own-hint">
          {pendingOwn.length === 1 ? 'One of your proposals is' : `${pendingOwn.length} of your proposals are`} waiting
          for a different finance user — nobody can approve their own. If you are the only person who works on bank
          reconciliation, the company can approve the one-person exception instead. You can withdraw
          {pendingOwn.length === 1 ? ' it' : ' them'} if it is wrong.
        </Alert>
      )}

      {reworkFrom && (
        <Alert
          severity="info"
          sx={{ mb: 2 }}
          data-testid="rework-banner"
          onClose={cancelRework}
        >
          Reworking the rejected proposal “{reworkFrom.reason}”. The statement line
          {reworkLineId ? ' has been re-selected above' : ' must be selected again'}; adjust the account or reason if
          needed and propose. The new proposal is linked to the rejected one in the audit history.
        </Alert>
      )}

      <Stack direction={{ xs: 'column', md: 'row' }} spacing={2} sx={{ mb: 2 }} alignItems={{ md: 'flex-start' }}>
        <Box sx={{ minWidth: 220 }}>
          <Typography variant="caption" color="text.secondary">Selected statement line</Typography>
          <Typography variant="body2">
            {selectedLine
              ? `${selectedLine.statement_date} · ${selectedLine.description ?? selectedLine.reference ?? 'no description'} · ${Number(selectedLine.amount).toLocaleString()} ${selectedLine.currency}`
              : 'None selected'}
          </Typography>
        </Box>
        <Autocomplete
          size="small"
          sx={{ minWidth: 300 }}
          options={glAccounts}
          value={counter}
          onChange={(_, v) => setCounter(v)}
          getOptionLabel={(o) => `${o.account_code} ${o.name}`}
          isOptionEqualToValue={(a, b) => a.id === b.id}
          getOptionDisabled={(o) => counterAccountBlockReason(o) !== null}
          renderOption={(props, o) => {
            const why = counterAccountBlockReason(o);
            return (
              <li {...props} key={o.id}>
                <Stack>
                  <Typography variant="body2">{`${o.account_code} ${o.name}`}</Typography>
                  {why && (
                    <Typography variant="caption" color="text.secondary">
                      not available: {why}
                    </Typography>
                  )}
                </Stack>
              </li>
            );
          }}
          renderInput={(params) => (
            <TextField
              {...params}
              label="Other side of the entry"
              error={counterBlock !== null}
              helperText={counterBlock ? `Not available as the other side: ${counterBlock}.` : undefined}
            />
          )}
        />
        <TextField
          size="small"
          label="Reason"
          sx={{ flex: 1 }}
          value={reason}
          onChange={(e) => setReason(e.target.value)}
          helperText="At least 5 characters"
        />
        <Button variant="contained" onClick={propose} disabled={!canPropose}>
          {reworkFrom ? 'Propose rework' : 'Propose adjustment'}
        </Button>
      </Stack>

      {visible.length === 0 ? (
        <Typography variant="body2" color="text.secondary">
          {account ? 'No adjustments for this bank account yet.' : 'Enter a bank account to see its adjustments.'}
        </Typography>
      ) : (
        <Table size="small">
          <TableHead>
            <TableRow>
              <TableCell>Line</TableCell>
              <TableCell align="right">Amount</TableCell>
              <TableCell>Other side</TableCell>
              <TableCell>Reason</TableCell>
              <TableCell>Status</TableCell>
              <TableCell align="right" />
            </TableRow>
          </TableHead>
          <TableBody>
            {visible.map((r) => {
              const own = me !== null && r.created_by === me;
              const terminalNote = r.status === 'rejected' ? r.rejection_reason : r.status === 'reversed' ? r.reversal_reason : null;
              const decision = modeLabel(r.approval_mode);
              // The exception covers approving your own submission, whether it
              // is an adjustment or a reversal request (20261119235950). Without
              // it a one-person team could never reverse a wrong posting.
              const canApproveThis = !own || canSelfApprove;
              const approveTip = own
                ? canSelfApprove
                  ? 'Approving your own proposal posts it as self-approved under the one-person exception, and flags it for the accountant'
                  : 'A different finance user must approve your proposal'
                : '';
              return (
                <TableRow key={r.id}>
                  <TableCell>
                    {r.bank_statement_line_id && onSelectLine ? (
                      <Tooltip title="Select this statement line in the table above">
                        <Button
                          size="small"
                          sx={{ textTransform: 'none', minWidth: 0, p: 0, fontSize: 'inherit', fontWeight: 'inherit' }}
                          onClick={() => onSelectLine(r.bank_statement_line_id as string)}
                          data-testid={`line-${r.id}`}
                        >
                          {r.line?.statement_date} {r.line?.description ?? r.line?.reference ?? ''}
                        </Button>
                      </Tooltip>
                    ) : (
                      <>
                        {r.line?.statement_date} {r.line?.description ?? r.line?.reference ?? ''}
                      </>
                    )}
                    {r.kind === 'reversal' && <Chip size="small" variant="outlined" label="reversal" sx={{ ml: 1 }} />}
                    {r.reworked_from && (
                      <Chip
                        size="small"
                        variant="outlined"
                        label="reworked"
                        sx={{ ml: 1 }}
                        data-testid="reworked-chip"
                      />
                    )}
                  </TableCell>
                  <TableCell align="right">{formatSigned(r)} {r.currency}</TableCell>
                  <TableCell>{r.counter ? `${r.counter.account_code} ${r.counter.name}` : ''}</TableCell>
                  <TableCell>{r.reason}</TableCell>
                  <TableCell>
                    <Stack direction="row" spacing={0.5} alignItems="center">
                      {terminalNote ? (
                        <Tooltip title={terminalNote}>
                          <span><Chip size="small" label={r.status} color={STATUS_COLOR[r.status]} /></span>
                        </Tooltip>
                      ) : (
                        <Chip size="small" label={r.status} color={STATUS_COLOR[r.status]} />
                      )}
                      {r.self_approved && (
                        <Tooltip title="Approved by the person who proposed it under the company's one-person exception">
                          <Chip size="small" color="warning" variant="outlined" label="self-approved" />
                        </Tooltip>
                      )}
                    </Stack>
                    {decision && (
                      <Typography variant="caption" color="text.secondary" display="block">
                        {decision}
                      </Typography>
                    )}
                  </TableCell>
                  <TableCell align="right">
                    <Stack direction="row" spacing={1} justifyContent="flex-end">
                      <Button size="small" onClick={() => setHistoryFor(r)} data-testid={`history-${r.id}`}>
                        History
                      </Button>
                      {r.status === 'pending' && (
                        <>
                          <Tooltip title={approveTip}>
                            <span>
                              <Button
                                size="small"
                                variant="contained"
                                disabled={!canApproveThis || busy}
                                onClick={() => { setNote(''); setDialog({ mode: 'approve', row: r }); }}
                              >
                                Approve
                              </Button>
                            </span>
                          </Tooltip>
                          <Button
                            size="small"
                            disabled={busy}
                            onClick={() => { setNote(''); setDialog({ mode: 'reject', row: r }); }}
                          >
                            {own ? 'Withdraw' : 'Reject'}
                          </Button>
                        </>
                      )}
                      {r.status === 'rejected' && own && (
                        <Button size="small" onClick={() => beginRework(r)} data-testid={`rework-${r.id}`}>
                          Rework
                        </Button>
                      )}
                      {r.status === 'posted' && r.kind === 'adjustment' && (
                        <Button
                          size="small"
                          color="error"
                          disabled={busy}
                          onClick={() => { setNote(''); setDialog({ mode: 'reverse', row: r }); }}
                        >
                          Reverse
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

      <Dialog open={dialog !== null} onClose={() => !busy && setDialog(null)} maxWidth="sm" fullWidth>
        <DialogTitle>{copy?.title}</DialogTitle>
        <DialogContent>
          {dialog && (
            <Typography variant="body2" sx={{ mb: 2 }}>
              {formatSigned(dialog.row)} {dialog.row.currency} — {dialog.row.reason}
            </Typography>
          )}
          {dialog?.mode === 'approve' && dialog.row.created_by === me && (
            <Alert severity="warning" sx={{ mb: 2 }}>
              This is your own {dialog.row.kind === 'reversal' ? 'reversal request' : 'proposal'}. Approving it posts
              the entry now and records it as self-approved under your company’s one-person exception, for the
              accountant to review.
            </Alert>
          )}
          {dialog && dialog.mode !== 'approve' && (
            <TextField
              autoFocus
              fullWidth
              multiline
              minRows={2}
              label={copy?.label}
              value={note}
              onChange={(e) => setNote(e.target.value)}
              helperText="At least 5 characters"
            />
          )}
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setDialog(null)} disabled={busy}>Cancel</Button>
          <Button
            variant="contained"
            onClick={decide}
            disabled={busy || (copy?.required === true && note.trim().length < 5)}
          >
            {copy?.confirm}
          </Button>
        </DialogActions>
      </Dialog>

      <AdjustmentHistoryDialog row={historyFor} onClose={() => setHistoryFor(null)} />

    </Paper>
  );
}

function AdjustmentHistoryDialog({ row, onClose }: { row: AdjustmentRow | null; onClose: () => void }) {
  const { events, loading, error } = useAdjustmentHistory(row?.id ?? null);
  return (
    <Dialog open={row !== null} onClose={onClose} maxWidth="sm" fullWidth>
      <DialogTitle>Adjustment history</DialogTitle>
      <DialogContent>
        {row && (
          <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
            {row.line?.statement_date} · {formatSigned(row)} {row.currency} · {row.reason}
          </Typography>
        )}
        {error && <Alert severity="error">{error}</Alert>}
        {loading && <Typography variant="body2" color="text.secondary">Loading…</Typography>}
        {!loading && !error && events.length === 0 && (
          <Typography variant="body2" color="text.secondary">No events recorded.</Typography>
        )}
        {events.length > 0 && (
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>When</TableCell>
                <TableCell>Event</TableCell>
                <TableCell>Who</TableCell>
                <TableCell>Detail</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {events.map((e, i) => (
                <TableRow key={`${e.event}-${i}`}>
                  <TableCell>{new Date(e.created_at).toLocaleString()}</TableCell>
                  <TableCell>{EVENT_LABEL[e.event] ?? e.event}</TableCell>
                  <TableCell>{e.actor_name}</TableCell>
                  <TableCell>{e.note ?? '—'}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        )}
      </DialogContent>
      <DialogActions>
        <Button onClick={onClose}>Close</Button>
      </DialogActions>
    </Dialog>
  );
}
