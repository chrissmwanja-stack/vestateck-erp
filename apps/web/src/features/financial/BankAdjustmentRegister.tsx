import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Alert,
  Box,
  Button,
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
import { Download as DownloadIcon } from '@mui/icons-material';
import { db } from './bank-reconciliation/db';
import type { AdjustmentStatus, RegisterRow } from './bank-reconciliation/types';

// The accountant's bank adjustment register (D4e).
//
// Every adjustment and reversal, in one place, with who proposed it, who
// decided it, how it was allowed to post and which statement line it belongs
// to. Three things it exists for:
//   1. the self-approved rows from the one-person exception are visible to the
//      accountant (they are what bank_adjustment_exceptions is for), and can be
//      pulled out with one click;
//   2. the rejected-to-reworked chain can be followed from the original row;
//   3. the list can leave the system. An accountant signs off a spreadsheet or
//      a working paper, not an HTML table, so the filtered view exports as CSV
//      with the facts that matter for sign-off.
//
// Reads bank_adjustment_register (security_invoker, so the caller's RLS still
// applies) rather than the base table: one definition of the register for this
// screen, the exception report and anything else that comes later.

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

const SELECT =
  'adjustment_id, tenant_id, kind, status, bank_account, transaction_date, bank_line_reference, bank_line_description, counter_account_code, counter_account_name, amount, currency, direction, description_reason, created_by_name, created_at, approver_name, approval_date, self_approved, approval_mode, rejection_reason, posting_journal_reference, reworked_from, reverses_adjustment_id';

function signed(r: Pick<RegisterRow, 'amount' | 'direction'>): string {
  const n = Number(r.amount);
  const v = r.direction === 'out' ? -n : n;
  return `${v > 0 ? '+' : ''}${v.toLocaleString()}`;
}

/** One CSV field, quoted only when it has to be (and doubling embedded quotes). */
function csvField(value: unknown): string {
  if (value === null || value === undefined) return '';
  const s = String(value);
  return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

function toCsv(rows: RegisterRow[]): string {
  const header = [
    'Adjustment ID', 'Statement date', 'Bank account', 'Statement reference',
    'Statement description', 'Kind', 'Status', 'Amount', 'Currency', 'Direction',
    'Counter account code', 'Counter account name', 'Reason', 'Proposed by',
    'Proposed at', 'Decided by', 'Decided at', 'Approval mode', 'Self approved',
    'Rejection reason', 'Posting journal', 'Rework of',
  ];
  const body = rows.map((r) => [
    r.adjustment_id,
    r.transaction_date,
    r.bank_account,
    r.bank_line_reference,
    r.bank_line_description,
    r.kind,
    r.status,
    signed(r),
    r.currency,
    r.direction,
    r.counter_account_code,
    r.counter_account_name,
    r.description_reason,
    r.created_by_name,
    r.created_at,
    r.approver_name,
    r.approval_date,
    r.approval_mode,
    r.self_approved ? 'yes' : 'no',
    r.rejection_reason,
    r.posting_journal_reference,
    r.reworked_from,
  ]);
  return [header, ...body].map((line) => line.map(csvField).join(',')).join('\r\n');
}

function download(filename: string, text: string) {
  // BOM so Excel opens UTF-8 correctly: bank names and reasons contain
  // characters that a bare UTF-8 CSV renders as mojibake in Windows Excel.
  const blob = new Blob([`\uFEFF${text}`], { type: 'text/csv;charset=utf-8;' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
}

export default function BankAdjustmentRegister() {
  const [rows, setRows] = useState<RegisterRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [filter, setFilter] = useState<Filter>('all');
  const [bankAccount, setBankAccount] = useState('');

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const { data, error: err } = await db
      .from('bank_adjustment_register')
      .select(SELECT)
      .order('created_at', { ascending: false })
      .limit(500);
    setLoading(false);
    if (err) {
      setError(err.message ?? 'Could not load the adjustment register.');
      return;
    }
    setRows((data ?? []) as unknown as RegisterRow[]);
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

  function exportCsv() {
    const scope = filter === 'all' ? 'all' : filter;
    const account = bankAccount.trim() ? `-${bankAccount.trim().replace(/[^A-Za-z0-9-]+/g, '_')}` : '';
    download(
      `bank-adjustment-register-${scope}${account}-${new Date().toISOString().slice(0, 10)}.csv`,
      toCsv(visible)
    );
  }

  return (
    <Box>
      <Typography variant="h5" sx={{ mb: 1 }}>Bank adjustment register</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
        Every adjustment and reversal of a bank statement line, with who proposed it, who decided it and how it was
        allowed to post. Rows marked self-approved were approved by the person who proposed them under the company’s
        one-person exception and are the ones an accountant reviews.
      </Typography>

      {selfApproved > 0 && (
        <Alert
          severity="warning"
          sx={{ mb: 2 }}
          data-testid="register-exception-alert"
          action={
            filter === 'self_approved' ? undefined : (
              <Button color="inherit" size="small" onClick={() => setFilter('self_approved')}>
                Show only these
              </Button>
            )
          }
        >
          {selfApproved} adjustment{selfApproved === 1 ? ' is' : 's are'} self-approved under the one-person exception.
          Review {selfApproved === 1 ? 'it' : 'them'} and record sign-off in your usual audit record — nothing in this
          register changes once posted; a wrong one is corrected by a reversal.
        </Alert>
      )}

      {error && <Alert severity="error" sx={{ mb: 2 }}>{error}</Alert>}

      <Paper sx={{ p: 2, mb: 2 }}>
        <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2} alignItems={{ sm: 'center' }}>
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
          <Typography variant="body2" color="text.secondary">
            {visible.length} of {rows.length} row{rows.length === 1 ? '' : 's'}
          </Typography>
          <Button
            variant="outlined"
            startIcon={<DownloadIcon />}
            onClick={exportCsv}
            disabled={visible.length === 0}
            data-testid="export-register-csv"
          >
            Export CSV
          </Button>
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
                const terminal = r.status === 'rejected' ? r.rejection_reason : null;
                const line = [r.transaction_date, r.bank_line_description ?? r.bank_line_reference ?? '']
                  .filter(Boolean)
                  .join(' ');
                return (
                  <TableRow key={r.adjustment_id}>
                    <TableCell>
                      {line}
                      {r.kind === 'reversal' && <Chip size="small" variant="outlined" label="reversal" sx={{ ml: 1 }} />}
                      {r.reworked_from && (
                        <Tooltip title={`Rework of adjustment ${r.reworked_from}`}>
                          <Chip size="small" variant="outlined" label="rework" sx={{ ml: 1 }} />
                        </Tooltip>
                      )}
                    </TableCell>
                    <TableCell>{r.bank_account}</TableCell>
                    <TableCell align="right">{signed(r)} {r.currency}</TableCell>
                    <TableCell>{r.counter_account_code} {r.counter_account_name}</TableCell>
                    <TableCell>
                      {r.description_reason}
                      {terminal && (
                        <Typography variant="caption" color="text.secondary" display="block">
                          Rejected: {terminal}
                        </Typography>
                      )}
                    </TableCell>
                    <TableCell>{r.created_by_name ?? '—'}</TableCell>
                    <TableCell>
                      {r.approval_date ? new Date(r.approval_date).toLocaleDateString() : '—'}
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
                      {r.approval_mode === 'two_person' && (
                        <Typography variant="caption" color="text.secondary" display="block">
                          two-person approval
                        </Typography>
                      )}
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
