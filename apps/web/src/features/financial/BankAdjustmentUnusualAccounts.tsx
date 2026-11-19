import { useMemo, useState } from 'react';
import {
  Alert,
  Autocomplete,
  Box,
  Button,
  Chip,
  CircularProgress,
  Dialog,
  DialogActions,
  DialogContent,
  DialogTitle,
  IconButton,
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
import { Delete as DeleteIcon, Settings as SettingsIcon } from '@mui/icons-material';
import { db } from './bank-reconciliation/db';
import { counterAccountBlockReason, type GlAccountOption } from './bank-reconciliation/types';
import { useAdjustmentLookups, useUnusualAccounts, useUsualAccounts } from './bank-reconciliation/useBankAdjustments';

// Unusual account usage (D4e), and the usual-accounts list it is measured
// against.
//
// A posted adjustment whose counter-account is not on the company's list of
// usual suspects is flagged here for review. The report is deliberately
// "flags, not verdicts": a one-off counter-account is not wrong, it just has
// to be looked at. The list is per company and finance-managed, through the
// usual-account RPCs (so the table needs no write grants for the client).
//
// Until at least one account is listed, every posted adjustment is unusual --
// that is stated on screen rather than shown as a wall of warnings with no
// explanation.

const WINDOW_OPTIONS: { value: number | null; label: string }[] = [
  { value: 30, label: 'Last 30 days' },
  { value: 90, label: 'Last 90 days' },
  { value: 365, label: 'Last 12 months' },
  { value: null, label: 'Everything posted' },
];

function signed(direction: 'in' | 'out', amount: number): string {
  const n = Number(amount);
  const v = direction === 'out' ? -n : n;
  return `${v > 0 ? '+' : ''}${v.toLocaleString()}`;
}

export default function BankAdjustmentUnusualAccounts() {
  const [days, setDays] = useState<number | null>(90);
  const { rows, loading, error, reload } = useUnusualAccounts(days);
  const usual = useUsualAccounts();
  const lookups = useAdjustmentLookups();

  const [settingsOpen, setSettingsOpen] = useState(false);
  const [pick, setPick] = useState<GlAccountOption | null>(null);
  const [busy, setBusy] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);

  // Ids, for greying out accounts already on the list in the picker.
  const usualIds = useMemo(() => new Set(usual.rows.map((u) => u.gl_account_id)), [usual.rows]);
  const listIsEmpty = !usual.loading && usual.rows.length === 0;

  async function addUsual() {
    if (!pick) return;
    setBusy(true);
    setActionError(null);
    const { error: err } = await db.rpc('bank_adjustment_add_usual_account', { p_gl_account_id: pick.id });
    setBusy(false);
    if (err) {
      setActionError(err.message ?? 'Could not add that account.');
      return;
    }
    setPick(null);
    await Promise.all([usual.reload(), reload()]);
  }

  async function removeUsual(glAccountId: string) {
    setBusy(true);
    setActionError(null);
    const { error: err } = await db.rpc('bank_adjustment_remove_usual_account', { p_gl_account_id: glAccountId });
    setBusy(false);
    if (err) {
      setActionError(err.message ?? 'Could not remove that account.');
      return;
    }
    await Promise.all([usual.reload(), reload()]);
  }

  return (
    <Box>
      <Stack direction="row" alignItems="center" spacing={1} sx={{ mb: 1 }}>
        <Typography variant="h5">Unusual bank adjustment accounts</Typography>
        <Box sx={{ flex: 1 }} />
        <Button startIcon={<SettingsIcon />} onClick={() => setSettingsOpen(true)}>
          Usual accounts ({usual.rows.length})
        </Button>
      </Stack>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
        Posted bank adjustments whose other side is not one of the company’s usual accounts. These are flagged for
        review, not judged: an account used once is not necessarily wrong, it just has to be looked at.
      </Typography>

      {listIsEmpty && (
        <Alert severity="info" sx={{ mb: 2 }} data-testid="usual-empty-alert">
          No usual accounts are configured yet, so every posted adjustment appears here. Add the accounts your bank
          charges and interest usually go to — the report then only shows what is out of the ordinary.
        </Alert>
      )}

      {error && <Alert severity="error" sx={{ mb: 2 }}>{error}</Alert>}

      <Paper sx={{ p: 2, mb: 2 }}>
        <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2} alignItems="center">
          <TextField
            select
            size="small"
            label="Period"
            value={days === null ? 'all' : String(days)}
            onChange={(e) => setDays(e.target.value === 'all' ? null : Number(e.target.value))}
            sx={{ minWidth: 200 }}
          >
            {WINDOW_OPTIONS.map((o) => (
              <MenuItem key={o.label} value={o.value === null ? 'all' : String(o.value)}>{o.label}</MenuItem>
            ))}
          </TextField>
          <Box sx={{ flex: 1 }} />
          <Typography variant="body2" color="text.secondary">
            {rows.length} flagged adjustment{rows.length === 1 ? '' : 's'}
          </Typography>
        </Stack>
      </Paper>

      {loading ? (
        <Box display="flex" justifyContent="center" py={4}><CircularProgress size={24} /></Box>
      ) : rows.length === 0 ? (
        <Alert severity="success">No posted adjustment used an unusual account in this period.</Alert>
      ) : (
        <Paper>
          <Table size="small" data-testid="unusual-accounts-table">
            <TableHead>
              <TableRow>
                <TableCell>Statement date</TableCell>
                <TableCell>Bank account</TableCell>
                <TableCell align="right">Amount</TableCell>
                <TableCell>Other side</TableCell>
                <TableCell>Reason</TableCell>
                <TableCell>Proposed / approved</TableCell>
                <TableCell>Status</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {rows.map((r) => (
                <TableRow key={r.adjustment_id}>
                  <TableCell>{r.statement_date}</TableCell>
                  <TableCell>{r.bank_account}</TableCell>
                  <TableCell align="right">{signed(r.direction, r.amount)} {r.currency}</TableCell>
                  <TableCell>
                    {r.counter_account_code} {r.counter_account_name}
                  </TableCell>
                  <TableCell>{r.reason}</TableCell>
                  <TableCell>
                    {r.created_by_name ?? '—'}
                    {r.approver_name && (
                      <Typography variant="caption" color="text.secondary" display="block">
                        approved by {r.approver_name}
                      </Typography>
                    )}
                  </TableCell>
                  <TableCell>
                    {r.self_approved ? (
                      <Tooltip title="Approved by the person who proposed it under the one-person exception">
                        <Chip size="small" color="warning" variant="outlined" label="self-approved" />
                      </Tooltip>
                    ) : (
                      <Chip size="small" label="posted" color="success" />
                    )}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </Paper>
      )}

      <Dialog open={settingsOpen} onClose={() => !busy && setSettingsOpen(false)} maxWidth="sm" fullWidth>
        <DialogTitle>Usual counter-accounts</DialogTitle>
        <DialogContent>
          <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
            Accounts a bank adjustment can normally be posted against — bank charges, interest received, and so on.
            Anything else appears in the report above.
          </Typography>
          {actionError && <Alert severity="error" sx={{ mb: 2 }}>{actionError}</Alert>}
          {usual.error && <Alert severity="error" sx={{ mb: 2 }}>{usual.error}</Alert>}

          <Stack direction="row" spacing={1} sx={{ mb: 2 }}>
            <Autocomplete
              size="small"
              sx={{ flex: 1 }}
              options={lookups.glAccounts}
              value={pick}
              onChange={(_, v) => setPick(v)}
              getOptionLabel={(o) => `${o.account_code} ${o.name}`}
              isOptionEqualToValue={(a, b) => a.id === b.id}
              getOptionDisabled={(o) => counterAccountBlockReason(o) !== null || usualIds.has(o.id)}
              renderInput={(params) => <TextField {...params} label="Add an account" />}
            />
            <Button variant="contained" onClick={addUsual} disabled={!pick || busy}>Add</Button>
          </Stack>

          {usual.loading ? (
            <Typography variant="body2" color="text.secondary">Loading…</Typography>
          ) : usual.rows.length === 0 ? (
            <Typography variant="body2" color="text.secondary">No usual accounts yet.</Typography>
          ) : (
            <Table size="small">
              <TableHead>
                <TableRow>
                  <TableCell>Account</TableCell>
                  <TableCell>Added</TableCell>
                  <TableCell />
                </TableRow>
              </TableHead>
              <TableBody>
                {usual.rows.map((u) => (
                  <TableRow key={u.gl_account_id}>
                    <TableCell>{u.account_code} {u.account_name}</TableCell>
                    <TableCell>{new Date(u.created_at).toLocaleDateString()}</TableCell>
                    <TableCell align="right">
                      <IconButton
                        size="small"
                        aria-label={`Remove ${u.account_code}`}
                        disabled={busy}
                        onClick={() => removeUsual(u.gl_account_id)}
                      >
                        <DeleteIcon fontSize="small" />
                      </IconButton>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setSettingsOpen(false)} disabled={busy}>Close</Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}
