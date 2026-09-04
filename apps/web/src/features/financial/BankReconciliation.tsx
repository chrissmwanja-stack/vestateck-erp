import { useCallback, useEffect, useState } from 'react';
import {
  Alert,
  Box,
  Button,
  Chip,
  CircularProgress,
  Dialog,
  DialogActions,
  DialogContent,
  DialogTitle,
  Divider,
  Paper,
  Stack,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  TextField,
  Typography,
} from '@mui/material';
import { AccountBalance as AccountBalanceIcon, Sync as SyncIcon, UploadFile as UploadFileIcon } from '@mui/icons-material';
import { supabase } from '../../lib/supabaseClient';

function useFinanceAccess() {
  const [isFinance, setIsFinance] = useState<boolean | null>(null);
  useEffect(() => {
    supabase.rpc('is_finance_team_member', { p_role: 'finance' }).then(({ data, error }) =>
      setIsFinance(error ? false : Boolean(data))
    );
  }, []);
  return isFinance;
}

interface StatementLine {
  id: string;
  statement_date: string;
  description: string | null;
  reference: string | null;
  amount: number;
  currency: string;
}

interface CashBankTxn {
  id: string;
  transaction_date: string;
  transaction_type: 'payment' | 'receipt';
  amount: number;
  currency: string;
  description: string | null;
  reference_type: string;
}

interface VarianceRow {
  reconciliation_id: string;
  match_type: string;
  variance: number;
  matched_at: string;
  statement_date: string;
  statement_description: string | null;
  statement_amount: number;
  transaction_date: string;
  transaction_description: string | null;
  transaction_amount: number;
  transaction_type: string;
}

const today = () => new Date().toISOString().slice(0, 10);
const monthAgo = () => {
  const d = new Date();
  d.setMonth(d.getMonth() - 1);
  return d.toISOString().slice(0, 10);
};

// Minimal CSV parser -- no external dependency. Handles a header row
// plus simple quoted fields (a bank export with a comma inside a
// quoted description). Doesn't attempt full RFC 4180 edge cases
// (escaped quotes within quotes) -- good enough for a bank statement
// export, and the import RPC validates required fields regardless.
function parseCsv(text: string): Record<string, string>[] {
  const lines = text.split(/\r?\n/).filter((l) => l.trim().length > 0);
  if (lines.length < 2) return [];
  const splitLine = (line: string) => {
    const cells: string[] = [];
    let cur = '';
    let inQuotes = false;
    for (let i = 0; i < line.length; i++) {
      const ch = line[i];
      if (ch === '"') {
        inQuotes = !inQuotes;
      } else if (ch === ',' && !inQuotes) {
        cells.push(cur.trim());
        cur = '';
      } else {
        cur += ch;
      }
    }
    cells.push(cur.trim());
    return cells;
  };
  const headers = splitLine(lines[0]).map((h) => h.toLowerCase());
  return lines.slice(1).map((line) => {
    const cells = splitLine(line);
    const row: Record<string, string> = {};
    headers.forEach((h, i) => (row[h] = cells[i] ?? ''));
    return row;
  });
}

export default function BankReconciliation() {
  const isFinance = useFinanceAccess();
  const [bankAccount, setBankAccount] = useState('');
  const [dateFrom, setDateFrom] = useState(monthAgo());
  const [dateTo, setDateTo] = useState(today());

  const [statementLines, setStatementLines] = useState<StatementLine[]>([]);
  const [cashTxns, setCashTxns] = useState<CashBankTxn[]>([]);
  const [variances, setVariances] = useState<VarianceRow[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [info, setInfo] = useState<string | null>(null);

  const [selectedStatementLine, setSelectedStatementLine] = useState<string | null>(null);
  const [selectedTxn, setSelectedTxn] = useState<string | null>(null);
  const [matching, setMatching] = useState(false);
  const [autoMatching, setAutoMatching] = useState(false);

  const [importOpen, setImportOpen] = useState(false);
  const [importText, setImportText] = useState('');
  const [importing, setImporting] = useState(false);
  const [importError, setImportError] = useState<string | null>(null);

  const load = useCallback(async () => {
    if (!bankAccount.trim()) {
      setStatementLines([]);
      setCashTxns([]);
      setVariances([]);
      return;
    }
    setLoading(true);
    setError(null);

    const [{ data: lines, error: lineErr }, { data: txns, error: txnErr }, { data: varRows, error: varErr }] =
      await Promise.all([
        supabase
          .from('v_bank_statement_unmatched')
          .select('id, statement_date, description, reference, amount, currency')
          .eq('bank_account', bankAccount.trim())
          .gte('statement_date', dateFrom)
          .lte('statement_date', dateTo)
          .order('statement_date'),
        supabase
          .from('v_cash_bank_unmatched')
          .select('id, transaction_date, transaction_type, amount, currency, description, reference_type')
          .eq('bank_account', bankAccount.trim())
          .gte('transaction_date', dateFrom)
          .lte('transaction_date', dateTo)
          .order('transaction_date'),
        supabase
          .from('v_bank_reconciliation_variance')
          .select('*')
          .eq('bank_account', bankAccount.trim())
          .order('matched_at', { ascending: false }),
      ]);

    if (lineErr || txnErr || varErr) {
      setError(lineErr?.message ?? txnErr?.message ?? varErr?.message ?? 'Could not load reconciliation data.');
    } else {
      setStatementLines((lines ?? []) as StatementLine[]);
      setCashTxns((txns ?? []) as CashBankTxn[]);
      setVariances((varRows ?? []) as VarianceRow[]);
    }
    setSelectedStatementLine(null);
    setSelectedTxn(null);
    setLoading(false);
  }, [bankAccount, dateFrom, dateTo]);

  useEffect(() => {
    load();
  }, [load]);

  async function handleMatch() {
    if (!selectedStatementLine || !selectedTxn) return;
    setMatching(true);
    setError(null);
    const { error: err } = await supabase.rpc('match_bank_statement_line', {
      p_statement_line_id: selectedStatementLine,
      p_cash_bank_transaction_id: selectedTxn,
    });
    setMatching(false);
    if (err) {
      setError(err.message ?? 'Could not match those two lines.');
      return;
    }
    setInfo('Matched.');
    load();
  }

  async function handleAutoMatch() {
    if (!bankAccount.trim()) return;
    setAutoMatching(true);
    setError(null);
    const { data, error: err } = await supabase.rpc('auto_match_bank_statement', {
      p_bank_account: bankAccount.trim(),
      p_date_from: dateFrom,
      p_date_to: dateTo,
    });
    setAutoMatching(false);
    if (err) {
      setError(err.message ?? 'Auto-match failed.');
      return;
    }
    setInfo(`Auto-matched ${data ?? 0} line${data === 1 ? '' : 's'}.`);
    load();
  }

  async function handleUnmatch(reconciliationId: string) {
    setError(null);
    const { error: err } = await supabase.rpc('unmatch_bank_reconciliation', { p_reconciliation_id: reconciliationId });
    if (err) {
      setError(err.message ?? 'Could not undo that match.');
      return;
    }
    load();
  }

  async function handleImport() {
    if (!bankAccount.trim()) {
      setImportError('Enter a bank account above before importing.');
      return;
    }
    const rows = parseCsv(importText);
    if (rows.length === 0) {
      setImportError('Paste CSV with a header row: statement_date, description, reference, amount[, currency]');
      return;
    }
    const payload = rows.map((r) => ({
      statement_date: r.statement_date || r.date,
      description: r.description || null,
      reference: r.reference || null,
      amount: Number(r.amount),
      currency: r.currency || undefined,
    }));
    if (payload.some((p) => !p.statement_date || Number.isNaN(p.amount))) {
      setImportError('Every row needs a statement_date and a numeric amount.');
      return;
    }

    setImporting(true);
    setImportError(null);
    const { error: err } = await supabase.rpc('import_bank_statement_lines', {
      p_bank_account: bankAccount.trim(),
      p_lines: payload,
    });
    setImporting(false);
    if (err) {
      setImportError(err.message ?? 'Import failed.');
      return;
    }
    setImportOpen(false);
    setImportText('');
    setInfo(`Imported ${payload.length} statement line${payload.length === 1 ? '' : 's'}.`);
    load();
  }

  function handleFilePick(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    if (!file) return;
    const reader = new FileReader();
    reader.onload = () => setImportText(String(reader.result ?? ''));
    reader.readAsText(file);
  }

  return (
    <Box sx={{ p: 3, maxWidth: 1300 }}>
      <Typography variant="h5" sx={{ display: 'flex', alignItems: 'center', gap: 1, mb: 1 }}>
        <AccountBalanceIcon /> Bank Reconciliation
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        Import a bank statement, then match each line against a recorded cash/bank transaction — automatically where the
        amount and date line up, manually otherwise.
      </Typography>

      {isFinance === false && (
        <Alert severity="info" sx={{ mb: 2 }}>
          You're not currently listed as a finance team member for this organization.
        </Alert>
      )}
      {error && <Alert severity="error" sx={{ mb: 2 }} onClose={() => setError(null)}>{error}</Alert>}
      {info && <Alert severity="success" sx={{ mb: 2 }} onClose={() => setInfo(null)}>{info}</Alert>}

      <Paper sx={{ p: 2, mb: 2 }}>
        <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2} alignItems="center">
          <TextField
            label="Bank Account"
            size="small"
            placeholder="e.g. Stanbic-001"
            value={bankAccount}
            onChange={(e) => setBankAccount(e.target.value)}
            sx={{ minWidth: 220 }}
          />
          <TextField
            label="From"
            type="date"
            size="small"
            InputLabelProps={{ shrink: true }}
            value={dateFrom}
            onChange={(e) => setDateFrom(e.target.value)}
          />
          <TextField
            label="To"
            type="date"
            size="small"
            InputLabelProps={{ shrink: true }}
            value={dateTo}
            onChange={(e) => setDateTo(e.target.value)}
          />
          <Button variant="outlined" startIcon={<UploadFileIcon />} onClick={() => { setImportError(null); setImportOpen(true); }}>
            Import Statement
          </Button>
          <Button
            variant="outlined"
            startIcon={<SyncIcon />}
            onClick={handleAutoMatch}
            disabled={!bankAccount.trim() || autoMatching}
          >
            {autoMatching ? 'Matching…' : 'Auto-Match'}
          </Button>
        </Stack>
      </Paper>

      {!bankAccount.trim() ? (
        <Alert severity="info">Enter a bank account to load its unmatched statement lines and transactions.</Alert>
      ) : loading ? (
        <Box display="flex" justifyContent="center" py={4}>
          <CircularProgress size={24} />
        </Box>
      ) : (
        <>
          <Stack direction={{ xs: 'column', md: 'row' }} spacing={2} sx={{ mb: 2 }}>
            <TableContainer component={Paper} sx={{ flex: 1 }}>
              <Box sx={{ p: 1.5, pb: 0 }}>
                <Typography variant="subtitle2">Statement — Unmatched ({statementLines.length})</Typography>
              </Box>
              <Table size="small">
                <TableHead>
                  <TableRow>
                    <TableCell />
                    <TableCell>Date</TableCell>
                    <TableCell>Description</TableCell>
                    <TableCell align="right">Amount</TableCell>
                  </TableRow>
                </TableHead>
                <TableBody>
                  {statementLines.map((l) => (
                    <TableRow
                      key={l.id}
                      hover
                      selected={selectedStatementLine === l.id}
                      onClick={() => setSelectedStatementLine(l.id === selectedStatementLine ? null : l.id)}
                      sx={{ cursor: 'pointer' }}
                    >
                      <TableCell padding="checkbox">
                        <Chip size="small" label={selectedStatementLine === l.id ? 'Selected' : ''} sx={{ visibility: selectedStatementLine === l.id ? 'visible' : 'hidden' }} color="primary" />
                      </TableCell>
                      <TableCell>{l.statement_date}</TableCell>
                      <TableCell>
                        {l.description ?? '—'}
                        {l.reference && (
                          <Typography variant="caption" color="text.secondary" display="block">
                            Ref: {l.reference}
                          </Typography>
                        )}
                      </TableCell>
                      <TableCell align="right">{Number(l.amount).toLocaleString()}</TableCell>
                    </TableRow>
                  ))}
                  {statementLines.length === 0 && (
                    <TableRow>
                      <TableCell colSpan={4} align="center" sx={{ color: 'text.secondary', py: 3 }}>
                        Nothing unmatched in this window.
                      </TableCell>
                    </TableRow>
                  )}
                </TableBody>
              </Table>
            </TableContainer>

            <TableContainer component={Paper} sx={{ flex: 1 }}>
              <Box sx={{ p: 1.5, pb: 0 }}>
                <Typography variant="subtitle2">Book — Unmatched Transactions ({cashTxns.length})</Typography>
              </Box>
              <Table size="small">
                <TableHead>
                  <TableRow>
                    <TableCell />
                    <TableCell>Date</TableCell>
                    <TableCell>Description</TableCell>
                    <TableCell align="right">Amount</TableCell>
                  </TableRow>
                </TableHead>
                <TableBody>
                  {cashTxns.map((t) => {
                    const signed = t.transaction_type === 'receipt' ? Number(t.amount) : -Number(t.amount);
                    return (
                      <TableRow
                        key={t.id}
                        hover
                        selected={selectedTxn === t.id}
                        onClick={() => setSelectedTxn(t.id === selectedTxn ? null : t.id)}
                        sx={{ cursor: 'pointer' }}
                      >
                        <TableCell padding="checkbox">
                          <Chip size="small" label={selectedTxn === t.id ? 'Selected' : ''} sx={{ visibility: selectedTxn === t.id ? 'visible' : 'hidden' }} color="primary" />
                        </TableCell>
                        <TableCell>{t.transaction_date}</TableCell>
                        <TableCell>
                          {t.description ?? '—'}
                          <Typography variant="caption" color="text.secondary" display="block">
                            {t.reference_type.replace('_', ' ')}
                          </Typography>
                        </TableCell>
                        <TableCell align="right">{signed.toLocaleString()}</TableCell>
                      </TableRow>
                    );
                  })}
                  {cashTxns.length === 0 && (
                    <TableRow>
                      <TableCell colSpan={4} align="center" sx={{ color: 'text.secondary', py: 3 }}>
                        Nothing unmatched in this window.
                      </TableCell>
                    </TableRow>
                  )}
                </TableBody>
              </Table>
            </TableContainer>
          </Stack>

          <Stack direction="row" justifyContent="flex-end" sx={{ mb: 3 }}>
            <Button
              variant="contained"
              disabled={!selectedStatementLine || !selectedTxn || matching}
              onClick={handleMatch}
            >
              {matching ? 'Matching…' : 'Match Selected Pair'}
            </Button>
          </Stack>

          <Divider sx={{ mb: 2 }} />

          <Typography variant="subtitle1" sx={{ mb: 1 }}>
            Variance Report — Force-Matched Pairs ({variances.length})
          </Typography>
          <TableContainer component={Paper}>
            <Table size="small">
              <TableHead>
                <TableRow>
                  <TableCell>Statement</TableCell>
                  <TableCell align="right">Statement Amt</TableCell>
                  <TableCell>Transaction</TableCell>
                  <TableCell align="right">Txn Amt</TableCell>
                  <TableCell align="right">Variance</TableCell>
                  <TableCell />
                </TableRow>
              </TableHead>
              <TableBody>
                {variances.map((v) => (
                  <TableRow key={v.reconciliation_id}>
                    <TableCell>
                      {v.statement_date} — {v.statement_description ?? '—'}
                    </TableCell>
                    <TableCell align="right">{Number(v.statement_amount).toLocaleString()}</TableCell>
                    <TableCell>
                      {v.transaction_date} — {v.transaction_description ?? '—'}
                    </TableCell>
                    <TableCell align="right">{Number(v.transaction_amount).toLocaleString()}</TableCell>
                    <TableCell align="right">
                      <Typography color={v.variance === 0 ? 'text.primary' : 'error'} fontWeight={600}>
                        {Number(v.variance).toLocaleString()}
                      </Typography>
                    </TableCell>
                    <TableCell align="right">
                      <Button size="small" onClick={() => handleUnmatch(v.reconciliation_id)}>
                        Undo
                      </Button>
                    </TableCell>
                  </TableRow>
                ))}
                {variances.length === 0 && (
                  <TableRow>
                    <TableCell colSpan={6} align="center" sx={{ color: 'text.secondary', py: 3 }}>
                      No force-matched pairs with a variance for this account.
                    </TableCell>
                  </TableRow>
                )}
              </TableBody>
            </Table>
          </TableContainer>
        </>
      )}

      <Dialog open={importOpen} onClose={() => !importing && setImportOpen(false)} maxWidth="sm" fullWidth>
        <DialogTitle>Import Bank Statement — {bankAccount || '(enter a bank account first)'}</DialogTitle>
        <DialogContent>
          <Stack spacing={2} sx={{ mt: 1 }}>
            <Typography variant="body2" color="text.secondary">
              Upload a CSV or paste rows below. Expected columns: <code>statement_date, description, reference, amount</code>{' '}
              (positive = money in, negative = money out). <code>currency</code> is optional and defaults to UGX.
            </Typography>
            <Button component="label" variant="outlined" startIcon={<UploadFileIcon />}>
              Choose CSV File
              <input type="file" accept=".csv,text/csv" hidden onChange={handleFilePick} />
            </Button>
            <TextField
              label="CSV contents"
              multiline
              minRows={8}
              fullWidth
              value={importText}
              onChange={(e) => setImportText(e.target.value)}
              placeholder={'statement_date,description,reference,amount\n2026-09-06,SALARY PYMT,REF001,-1674500'}
            />
            {importError && <Alert severity="error">{importError}</Alert>}
          </Stack>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setImportOpen(false)} disabled={importing}>Cancel</Button>
          <Button variant="contained" onClick={handleImport} disabled={importing}>
            {importing ? 'Importing…' : 'Import'}
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}