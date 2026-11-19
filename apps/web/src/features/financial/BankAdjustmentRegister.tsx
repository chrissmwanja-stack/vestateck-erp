import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Alert,
  Box,
  Chip,
  CircularProgress,
  MenuItem,
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
import { db } from './bank-reconciliation/db';
import type { AdjustmentRow, AdjustmentStatus } from './bank-reconciliation/types';

// The accountant's bank adjustment register (D4e).
//
// Every adjustment and reversal, in one place, with who proposed it, who
// decided it and how it was allowed to post. Two things it exists for:
//   1. the self-approved rows from the one-person exception are visible to the
//      accountant (they are the reason bank_adjustment_exceptions exists), and
//   2. the rejected-to-reworked chain can be followed from the original row.
//
// Reads bank_adjustments directly rather than the register view: the view is
// security_invoker and needs the same join set, and the embedded form lets the
// screen filter by bank account without a second round trip. Finance-only at
// the RLS layer (is_finance_team_member).

const STATUS_COLOR: Record<AdjustmentStatus, 'warning' | 'success' | 'default' | 'error'> = {
  pending: 'warning',
  posted: 'success',
  rejected: 'default',
  reversed: 'error',
};

type Filter = 'all' | 'self_approved' | 'pending' | 'posted' | 'rejected' | 'reversed';

const FILTERS: { value: Filter; label: string }[] = [
  { value: 'all', label: 'All adjustments' },
  { value: 'self_approved', label: 'Self-approved (one-person exception)' },
  { value: 'pending', label: 'Awaiting approval' },
  { value: 'posted', label: 'Posted' },
  { value: 'rejected', label: 'Rejected' },
  { value: 'reversed', label: 'Reversed' },
];

function signed(r: Pick<AdjustmentRow, 'amount' | 'direction'>): string {
  const n = Number(r.amount);
  const v = r.direction === 'out' ? -n : n;
  return `${v > 0 ? '+' : ''}${v.toLocaleString()}`;
}

export default function BankAdjustmentRegister() {
  const [rows, setRows] = useState<AdjustmentRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [filter, setFilter] = useState<Filter>('all');
  const [bankAccount, setBankAccount] = useState('');

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const { data, error: err } = await db
      .from('bank_adjustments')
      .select(
        'id, kind, status, amount, currency, direction, reason, bank_account, statement_date, created_by, created_at, decided_by, decided_at, self_approved, approval_mode, rejection_reason, reversal_reason, reworked_from, reverses_adjustment_id, line:bank_statement_lines!bank_adjustments_statement_line_id_fkey(statement_date, description, reference), counter:gl_accounts!bank_adjustments_counter_account_id_fkey(account_code, name)'
      )
      .order('created_at', { ascending: false })
      .limit(500);
    setLoading(false);
    if (err) {
      setError(err.message ?? 'Could not load the adjustment register.');
      return;
    }
    setRows((data ?? []) as unknown as AdjustmentRow[]);
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const visible = useMemo(() => {
    const needle = bankAccount.trim().toLowerCase();
    return rows.filter((r) => {
      if (needle && !r.bank_account.toLowerCase().includes(needle)) return false;
      if (filter === 'all') return true;
      if (filter === 'self_approved') return r.self_approved === true;
      return r.status === filter;
    });
  }, [rows, filter, bankAccount]);

  const selfApproved = rows.filter((r) => r.self_approved === true).length;

  return (
    <Box>
      <Typography variant="h5" sx={{ mb: 1 }}>Bank adjustment register</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
        Every adjustment and reversal of a bank statement line, with who proposed it, who decided it and how it was
        allowed to post. Rows marked self-approved were approved by the person who proposed them under the company’s
        one-person exception and are the ones an accountant reviews.
      </Typography>

      {selfApproved > 0 && (
        <Alert severity="warning" sx={{ mb: 2 }} data-testid="register-exception-alert">
          {selfApproved} adjustment{selfApproved === 1 ? ' is' : 's are'} self-approved under the one-person exception.
          Review {selfApproved === 1 ? 'it' : 'them'} and record sign-off in your usual audit record — nothing in this
          register changes once posted; a wrong one is corrected by a reversal.
        </Alert>
      )}

      {error && <Alert severity="error" sx={{ mb: 2 }}>{error}</Alert>}

      <Paper sx={{ p: 2, mb: 2 }}>
        <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2}>
          <TextField
            select
            size="small"
            label="Show"
            value={filter}
            onChange={(e) => setFilter(e.target.value as Filter)}
            sx={{ minWidth: 260 }}
          >
            {FILTERS.map((f) => <MenuItem key={f.value} value={f.value}>{f.label}</MenuItem>)}
          </TextField>
          <TextField
            size="small"
            label="Bank account"
            placeholder="filter by bank account"
            value={bankAccount}
            onChange={(e) => setBankAccount(e.target.value)}
            sx={{ minWidth: 240 }}
          />
          <Box sx={{ flex: 1 }} />
          <Typography variant="body2" color="text.secondary" sx={{ alignSelf: 'center' }}>
            {visible.length} of {rows.length} row{rows.length === 1 ? '' : 's'}
          </Typography>
        </Stack>
      </Paper>

      {loading ? (
        <Box display="flex" justifyContent="center" py={4}><CircularProgress size={24} /></Box>
      ) : visible.length === 0 ? (
        <Alert severity="info">No adjustments match this filter.</Alert>
      ) : (
        <Paper>
          <Table size="small" data-testid="adjustment-register-table">
            <TableHead>
              <TableRow>
                <TableCell>Statement line</TableCell>
                <TableCell>Bank account</TableCell>
                <TableCell align="right">Amount</TableCell>
                <TableCell>Other side</TableCell>
                <TableCell>Reason</TableCell>
                <TableCell>Proposed by</TableCell>
                <TableCell>Decided</TableCell>
                <TableCell>Status</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {visible.map((r) => {
                const terminal = r.status === 'rejected' ? r.rejection_reason : r.status === 'reversed' ? r.reversal_reason : null;
                return (
                  <TableRow key={r.id}>
                    <TableCell>
                      {r.line?.statement_date ?? r.statement_date ?? ''}{' '}
                      {r.line?.description ?? r.line?.reference ?? ''}
                      {r.kind === 'reversal' && <Chip size="small" variant="outlined" label="reversal" sx={{ ml: 1 }} />}
                      {r.reworked_from && <Chip size="small" variant="outlined" label="rework" sx={{ ml: 1 }} />}
                    </TableCell>
                    <TableCell>{r.bank_account}</TableCell>
                    <TableCell align="right">{signed(r)} {r.currency}</TableCell>
                    <TableCell>{r.counter ? `${r.counter.account_code} ${r.counter.name}` : ''}</TableCell>
                    <TableCell>
                      {r.reason}
                      {terminal && (
                        <Typography variant="caption" color="text.secondary" display="block">
                          {r.status === 'rejected' ? 'Rejected' : 'Reversed'}: {terminal}
                        </Typography>
                      )}
                    </TableCell>
                    <TableCell>{r.created_by_name ?? '—'}</TableCell>
                    <TableCell>
                      {r.decided_at ? new Date(r.decided_at).toLocaleDateString() : '—'}
                      {r.approver_name && (
                        <Typography variant="caption" color="text.secondary" display="block">
                          by {r.approver_name}
                        </Typography>
                      )}
                    </TableCell>
                    <TableCell>
                      <Stack direction="row" spacing={0.5} alignItems="center">
                        <Chip size="small" label={r.status} color={STATUS_COLOR[r.status]} />
                        {r.self_approved && (
                          <Tooltip title="Approved by the person who proposed it, under the company's one-person exception">
                            <Chip size="small" color="warning" variant="outlined" label="self-approved" />
                          </Tooltip>
                        )}
                      </Stack>
                    </TableCell>
                  </TableRow>
                );
              })}
            </TableBody>
          </Table>
        </Paper>
      )}
    </Box>
  );
}
