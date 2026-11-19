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
import type { StatementLine } from './types';

// Bank adjustments (D4e): book a statement line that has no book entry, such
// as a bank charge or interest. Two people are involved by design. One
// proposes an adjustment and picks the other side of the entry; a DIFFERENT
// finance user approves it, which posts the journal entry and matches the line
// in one step. The server enforces all of this (create_bank_adjustment /
// approve_bank_adjustment / reject_bank_adjustment /
// request_bank_adjustment_reversal); this panel only disables the approve
// button on your own proposals so you do not have to find out by being refused.
//
// Reversing a POSTED adjustment does not happen in one click here on purpose:
// it mirrors the same two-person control (request, then an independent
// approval) before the reversal journal is posted and the line is unmatched.
//
// The generated database.types.ts does not know these objects yet, so calls go
// through the untyped `db` handle (see ./db).

type Mode = 'approve' | 'reject' | 'reverse';
type Status = 'pending' | 'posted' | 'rejected' | 'reversed';

interface AdjustmentRow {
  id: string;
  kind: 'adjustment' | 'reversal';
  status: Status;
  amount: number;
  currency: string;
  direction: 'in' | 'out';
  reason: string;
  bank_account: string;
  created_by: string;
  created_at: string;
  rejection_reason: string | null;
  reversal_reason: string | null;
  line: { statement_date: string; description: string | null; reference: string | null } | null;
  counter: { account_code: string; name: string } | null;
}

interface GlOption {
  id: string;
  account_code: string;
  name: string;
}

const STATUS_COLOR: Record<Status, 'warning' | 'success' | 'default' | 'error'> = {
  pending: 'warning',
  posted: 'success',
  rejected: 'default',
  reversed: 'error',
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

export function BankAdjustmentsPanel({
  bankAccountName,
  selectedLine,
  onChanged,
  onError,
}: {
  // The registry name of the account on screen (the same free-text value used
  // for the statement queries). Rows are filtered client-side to this bank.
  bankAccountName: string | null;
  selectedLine: StatementLine | null;
  onChanged: (message: string) => void;
  onError: (message: string) => void;
}) {
  const [rows, setRows] = useState<AdjustmentRow[]>([]);
  const [glAccounts, setGlAccounts] = useState<GlOption[]>([]);
  const [me, setMe] = useState<string | null>(null);
  const [counter, setCounter] = useState<GlOption | null>(null);
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);
  const [dialog, setDialog] = useState<{ mode: Mode; row: AdjustmentRow } | null>(null);
  const [note, setNote] = useState('');
  const [loadError, setLoadError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoadError(null);
    const [adj, gl, user] = await Promise.all([
      db
        .from('bank_adjustments')
        .select(
          'id, kind, status, amount, currency, direction, reason, bank_account, created_by, created_at, rejection_reason, reversal_reason, line:bank_statement_lines!bank_adjustments_statement_line_id_fkey(statement_date, description, reference), counter:gl_accounts!bank_adjustments_counter_account_id_fkey(account_code, name)'
        )
        .order('created_at', { ascending: false })
        .limit(50),
      db.from('gl_accounts').select('id, account_code, name').eq('is_active', true).order('account_code'),
      db.auth.getUser(),
    ]);
    if (adj.error) {
      setLoadError(adj.error.message ?? 'Could not load bank adjustments.');
      return;
    }
    setRows((adj.data ?? []) as unknown as AdjustmentRow[]);
    setGlAccounts((gl.data ?? []) as GlOption[]);
    setMe(user.data?.user?.id ?? null);
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  async function propose() {
    if (!selectedLine || !counter) return;
    setBusy(true);
    const { error } = await db.rpc('create_bank_adjustment', {
      p_statement_line_id: selectedLine.id,
      p_counter_account_id: counter.id,
      p_reason: reason.trim(),
    });
    setBusy(false);
    if (error) {
      onError(error.message ?? 'Could not propose that adjustment.');
      return;
    }
    setCounter(null);
    setReason('');
    await load();
    onChanged('Adjustment proposed. A different finance user must approve it before anything is posted.');
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
    if (mode === 'approve') {
      onChanged(
        row.kind === 'reversal'
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
  const canPropose = Boolean(selectedLine && counter && reason.trim().length >= 5) && !busy;

  return (
    <Paper sx={{ p: 2, mb: 3 }} data-testid="bank-adjustments-panel">
      <Typography variant="subtitle1" sx={{ mb: 0.5 }}>
        Bank adjustments
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
        For a statement line with no book entry (a bank charge, interest received, an unrecorded deposit). Select the line above,
        choose the other side of the entry and say why. A different finance user then approves it, which posts the entry
        and matches the line.
      </Typography>

      {loadError && <Alert severity="error" sx={{ mb: 2 }}>{loadError}</Alert>}

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
          sx={{ minWidth: 280 }}
          options={glAccounts}
          value={counter}
          onChange={(_, v) => setCounter(v)}
          getOptionLabel={(o) => `${o.account_code} ${o.name}`}
          isOptionEqualToValue={(a, b) => a.id === b.id}
          renderInput={(params) => <TextField {...params} label="Other side of the entry" />}
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
          Propose adjustment
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
              <TableCell />
            </TableRow>
          </TableHead>
          <TableBody>
            {visible.map((r) => {
              const own = me !== null && r.created_by === me;
              const terminalNote = r.status === 'rejected' ? r.rejection_reason : r.status === 'reversed' ? r.reversal_reason : null;
              const statusChip = (
                <Chip size="small" label={r.status} color={STATUS_COLOR[r.status]} />
              );
              return (
                <TableRow key={r.id}>
                  <TableCell>
                    {r.line?.statement_date} {r.line?.description ?? r.line?.reference ?? ''}
                    {r.kind === 'reversal' && (
                      <Chip size="small" variant="outlined" label="reversal" sx={{ ml: 1 }} />
                    )}
                  </TableCell>
                  <TableCell align="right">{formatSigned(r)} {r.currency}</TableCell>
                  <TableCell>{r.counter ? `${r.counter.account_code} ${r.counter.name}` : ''}</TableCell>
                  <TableCell>{r.reason}</TableCell>
                  <TableCell>
                    {terminalNote ? (
                      <Tooltip title={terminalNote}>
                        <span>{statusChip}</span>
                      </Tooltip>
                    ) : (
                      statusChip
                    )}
                  </TableCell>
                  <TableCell align="right">
                    {r.status === 'pending' && (
                      <Stack direction="row" spacing={1} justifyContent="flex-end">
                        <Tooltip title={own ? 'A different finance user must approve your proposal' : ''}>
                          <span>
                            <Button size="small" variant="contained" disabled={own || busy}
                              onClick={() => { setNote(''); setDialog({ mode: 'approve', row: r }); }}>
                              Approve
                            </Button>
                          </span>
                        </Tooltip>
                        <Button size="small" disabled={busy}
                          onClick={() => { setNote(''); setDialog({ mode: 'reject', row: r }); }}>
                          {own ? 'Withdraw' : 'Reject'}
                        </Button>
                      </Stack>
                    )}
                    {r.status === 'posted' && r.kind === 'adjustment' && (
                      <Button size="small" color="error" disabled={busy}
                        onClick={() => { setNote(''); setDialog({ mode: 'reverse', row: r }); }}>
                        Reverse
                      </Button>
                    )}
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
          <Button variant="contained" onClick={decide}
            disabled={busy || (copy?.required === true && note.trim().length < 5)}>
            {copy?.confirm}
          </Button>
        </DialogActions>
      </Dialog>
    </Paper>
  );
}

