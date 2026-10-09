import { useCallback, useEffect, useMemo, useState } from 'react';
import type { SupabaseClient } from '@supabase/supabase-js';
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

// The D4d-1 objects (settlement matching, double-entry view, position
// function, fin_bank_accounts) are not in the generated database.types.ts
// yet, so calls that touch them go through this untyped handle. Once the
// types are regenerated these can move back to `supabase`.
const db = supabase as unknown as SupabaseClient;

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

interface SettlementRow {
  id: string;
  settlement_no: string | null;
  direction: 'in' | 'out';
  amount: number;
  currency: string;
  settlement_date: string;
  reference: string | null;
  notes: string | null;
}

interface BankAccountRow {
  id: string;
  name: string;
  currency: string;
}

interface DoubleEntryRow {
  statement_line_id: string;
}

interface PositionRow {
  line_order: number;
  component: string;
  label: string;
  amount: number | null;
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
  source?: string | null;
}

type BookSource = 'cash' | 'settlement';
interface BookSelection {
  source: BookSource;
  id: string;
}

// Matching looks up to this many days either side of the statement date
// (fin_bank_line_candidates), so the book-side lists reach that far past
// the statement window or a candidate just outside it would be invisible.
const MATCH_WINDOW_DAYS = 5;

const today = () => new Date().toISOString().slice(0, 10);
const monthAgo = () => {
  const d = new Date();
  d.setMonth(d.getMonth() - 1);
  return d.toISOString().slice(0, 10);
};
const shiftDate = (iso: string, days: number) => {
  const d = new Date(`${iso}T00:00:00Z`);
  if (Number.isNaN(d.getTime())) return iso;
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
};
const fmt = (n: number | null | undefined) => (n == null ? '—' : Number(n).toLocaleString());

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

  const [registry, setRegistry] = useState<BankAccountRow[]>([]);
  const [registryLoaded, setRegistryLoaded] = useState(false);

  const [statementLines, setStatementLines] = useState<StatementLine[]>([]);
  const [cashTxns, setCashTxns] = useState<CashBankTxn[]>([]);
  const [settlements, setSettlements] = useState<SettlementRow[]>([]);
  const [doubleEntryLineIds, setDoubleEntryLineIds] = useState<Set<string>>(new Set());
  const [position, setPosition] = useState<PositionRow[] | null>(null);
  const [positionError, setPositionError] = useState<string | null>(null);
  const [variances, setVariances] = useState<VarianceRow[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [info, setInfo] = useState<string | null>(null);

  const [selectedStatementLine, setSelectedStatementLine] = useState<string | null>(null);
  const [selectedBook, setSelectedBook] = useState<BookSelection | null>(null);
  const [matching, setMatching] = useState(false);
  const [autoMatching, setAutoMatching] = useState(false);

  const [importOpen, setImportOpen] = useState(false);
  const [importText, setImportText] = useState('');
  const [importing, setImporting] = useState(false);
  const [importError, setImportError] = useState<string | null>(null);

  // Statement lines and legacy cash/bank transactions identify the bank
  // by name; settlements and the position summary need the registry id.
  const resolvedAccount = useMemo(
    () => registry.find((a) => a.name === bankAccount.trim()) ?? null,
    [registry, bankAccount]
  );
  const resolvedAccountId = resolvedAccount?.id ?? null;

  useEffect(() => {
    let cancelled = false;
    db.from('fin_bank_accounts')
      .select('id, name, currency')
      .eq('is_active', true)
      .order('name')
      .then(({ data }) => {
        if (cancelled) return;
        setRegistry((data ?? []) as BankAccountRow[]);
        setRegistryLoaded(true);
      });
    return () => {
      cancelled = true;
    };
  }, []);

  const load = useCallback(async () => {
    const account = bankAccount.trim();
    if (!account) {
      setStatementLines([]);
      setCashTxns([]);
      setSettlements([]);
      setDoubleEntryLineIds(new Set());
      setPosition(null);
      setPositionError(null);
      setVariances([]);
      return;
    }
    setLoading(true);
    setError(null);

    const bookFrom = shiftDate(dateFrom, -MATCH_WINDOW_DAYS);
    const bookTo = shiftDate(dateTo, MATCH_WINDOW_DAYS);

    const settlementsQuery = resolvedAccountId
      ? db
          .from('fin_settlements')
          .select('id, settlement_no, direction, amount, currency, settlement_date, reference, notes')
          .eq('bank_account_id', resolvedAccountId)
          .eq('status', 'posted')
          .gte('settlement_date', bookFrom)
          .lte('settlement_date', bookTo)
          .order('settlement_date')
      : Promise.resolve({ data: [] as SettlementRow[], error: null });

    const positionQuery = resolvedAccountId
      ? db.rpc('fin_bank_reconciliation_position', { p_bank_account_id: resolvedAccountId, p_as_of: dateTo })
      : Promise.resolve({ data: null, error: null });

    const [
      { data: lines, error: lineErr },
      { data: txns, error: txnErr },
      { data: varRows, error: varErr },
      { data: settleRows, error: settleErr },
      { data: doubleRows, error: doubleErr },
      { data: posRows, error: posErr },
    ] = await Promise.all([
      supabase
        .from('v_bank_statement_unmatched')
        .select('id, statement_date, description, reference, amount, currency')
        .eq('bank_account', account)
        .gte('statement_date', dateFrom)
        .lte('statement_date', dateTo)
        .order('statement_date'),
      supabase
        .from('v_cash_bank_unmatched')
        .select('id, transaction_date, transaction_type, amount, currency, description, reference_type')
        .eq('bank_account', account)
        .gte('transaction_date', bookFrom)
        .lte('transaction_date', bookTo)
        .order('transaction_date'),
      supabase
        .from('v_bank_reconciliation_variance')
        .select('*')
        .eq('bank_account', account)
        .order('matched_at', { ascending: false }),
      settlementsQuery,
      db.from('v_bank_possible_double_entries').select('statement_line_id').eq('bank_account', account),
      positionQuery,
    ]);

    // Settlements that already have a reconciliation row are not
    // candidates; the list shows only the ones still open.
    let openSettlements: SettlementRow[] = [];
    let reconErr: string | null = null;
    const settleList = (settleRows ?? []) as SettlementRow[];
    if (!settleErr && settleList.length > 0) {
      const { data: reconRows, error: rErr } = await db
        .from('bank_reconciliations')
        .select('settlement_id')
        .in(
          'settlement_id',
          settleList.map((s) => s.id)
        );
      if (rErr) {
        reconErr = rErr.message;
      } else {
        const reconciled = new Set((reconRows ?? []).map((r: { settlement_id: string }) => r.settlement_id));
        openSettlements = settleList.filter((s) => !reconciled.has(s.id));
      }
    }

    const firstError = lineErr ?? txnErr ?? varErr ?? settleErr ?? doubleErr;
    if (firstError || reconErr) {
      setError(firstError?.message ?? reconErr ?? 'Could not load reconciliation data.');
    } else {
      setStatementLines((lines ?? []) as StatementLine[]);
      setCashTxns((txns ?? []) as CashBankTxn[]);
      setSettlements(openSettlements);
      setVariances((varRows ?? []) as unknown as VarianceRow[]);
      const lineIds = new Set(((lines ?? []) as StatementLine[]).map((l) => l.id));
      setDoubleEntryLineIds(
        new Set(
          ((doubleRows ?? []) as DoubleEntryRow[]).map((r) => r.statement_line_id).filter((id) => lineIds.has(id))
        )
      );
    }

    // The position summary has its own error slot: a GL or permission
    // problem there should not hide the lines the user came to match.
    if (posErr) {
      setPosition(null);
      setPositionError(posErr.message ?? 'Could not load the reconciliation position.');
    } else {
      setPosition(posRows ? ((posRows as PositionRow[]).slice().sort((a, b) => a.line_order - b.line_order)) : null);
      setPositionError(null);
    }

    setSelectedStatementLine(null);
    setSelectedBook(null);
    setLoading(false);
  }, [bankAccount, dateFrom, dateTo, resolvedAccountId]);

  useEffect(() => {
    load();
  }, [load]);

  const selectedLine = statementLines.find((l) => l.id === selectedStatementLine) ?? null;

  async function handleMatch() {
    if (!selectedStatementLine || !selectedBook) return;
    setMatching(true);
    setError(null);
    const { data, error: err } =
      selectedBook.source === 'settlement'
        ? await db.rpc('match_bank_statement_line_to_settlement', {
            p_statement_line_id: selectedStatementLine,
            p_settlement_id: selectedBook.id,
          })
        : await supabase.rpc('match_bank_statement_line', {
            p_statement_line_id: selectedStatementLine,
            p_cash_bank_transaction_id: selectedBook.id,
          });
    setMatching(false);
    if (err) {
      setError(err.message ?? 'Could not match those two lines.');
      return;
    }
    const variance = Number((data as { variance?: number } | null)?.variance ?? 0);
    setInfo(variance !== 0 ? `Matched with a variance of ${variance.toLocaleString()}.` : 'Matched.');
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
    setInfo(
      `Auto-matched ${data ?? 0} line${data === 1 ? '' : 's'}. Lines with more than one possible match are left for you to match by hand.`
    );
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

  const isSelected = (source: BookSource, id: string) => selectedBook?.source === source && selectedBook.id === id;
  const toggleBook = (source: BookSource, id: string) =>
    setSelectedBook(isSelected(source, id) ? null : { source, id });
  // Hint only -- the server re-checks amount, currency, status and date
  // window when the match is made.
  const amountMatchesLine = (signed: number) => selectedLine != null && Number(selectedLine.amount) === signed;

  const unexplained = position?.find((p) => p.component === 'unexplained_difference')?.amount ?? null;
  const account = bankAccount.trim();

  return (
    <Box sx={{ p: 3, maxWidth: 1300 }}>
      <Typography variant="h5" sx={{ display: 'flex', alignItems: 'center', gap: 1, mb: 1 }}>
        <AccountBalanceIcon /> Bank Reconciliation
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        Import a bank statement, then match each line against a posted settlement or a recorded cash/bank transaction —
        automatically where the amount and date line up, manually otherwise.
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
          <Autocomplete
            freeSolo
            size="small"
            options={registry.map((a) => a.name)}
            inputValue={bankAccount}
            onInputChange={(_, value) => setBankAccount(value)}
            sx={{ minWidth: 240 }}
            renderInput={(params) => (
              <TextField {...params} label="Bank Account" placeholder="e.g. Stanbic-001" />
            )}
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
            disabled={!account || autoMatching}
          >
            {autoMatching ? 'Matching…' : 'Auto-Match'}
          </Button>
        </Stack>
      </Paper>

      {!account ? (
        <Alert severity="info">Enter a bank account to load its unmatched statement lines and book entries.</Alert>
      ) : loading ? (
        <Box display="flex" justifyContent="center" py={4}>
          <CircularProgress size={24} />
        </Box>
      ) : (
        <>
          {registryLoaded && !resolvedAccount && (
            <Alert severity="info" sx={{ mb: 2 }}>
              “{account}” is not in the bank account registry, so settlements and the reconciliation position are not
              available for it. Statement lines and legacy cash/bank transactions still work.
            </Alert>
          )}

          {resolvedAccount && (
            <Paper sx={{ p: 2, mb: 2 }} data-testid="position-panel">
              <Typography variant="subtitle1" sx={{ mb: 1 }}>
                Reconciliation Position — as of {dateTo}
              </Typography>
              {positionError ? (
                <Alert severity="warning">{positionError}</Alert>
              ) : position ? (
                <>
                  <Table size="small">
                    <TableBody>
                      {position
                        .filter((p) => p.component !== 'unexplained_difference')
                        .map((p) => (
                          <TableRow key={p.component}>
                            <TableCell sx={{ fontWeight: p.component === 'expected_statement_balance' ? 600 : 400 }}>
                              {p.label}
                            </TableCell>
                            <TableCell align="right" sx={{ fontWeight: p.component === 'expected_statement_balance' ? 600 : 400 }}>
                              {fmt(p.amount)}
                            </TableCell>
                          </TableRow>
                        ))}
                    </TableBody>
                  </Table>
                  <Typography variant="caption" color="text.secondary" display="block" sx={{ mt: 1 }}>
                    Statement lines carry no balance, so compare the expected closing balance with the closing balance
                    printed on the bank statement.
                  </Typography>
                  {unexplained != null && (
                    <Alert severity={Number(unexplained) === 0 ? 'success' : 'warning'} sx={{ mt: 1.5 }}>
                      Unexplained difference: <strong>{fmt(unexplained)}</strong>. This is GL movement on the bank's
                      ledger account that reconciliation cannot see (manual journals, opening balances, or bank
                      transactions posted to a different GL account). It is not netted into the expected balance above.
                    </Alert>
                  )}
                  {resolvedAccount && position.some((p) => p.component === 'gl_balance' && p.amount == null) && (
                    <Alert severity="info" sx={{ mt: 1.5 }}>
                      This bank account has no GL account linked, so the GL-based lines are blank.
                    </Alert>
                  )}
                </>
              ) : null}
            </Paper>
          )}

          {doubleEntryLineIds.size > 0 && (
            <Alert severity="warning" sx={{ mb: 2 }} data-testid="double-entry-alert">
              {doubleEntryLineIds.size} statement line{doubleEntryLineIds.size === 1 ? '' : 's'} could match both a
              settlement and a legacy cash/bank transaction. The same movement may be recorded twice — match one and
              review the other. Auto-match leaves these for you.
            </Alert>
          )}

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
                        {doubleEntryLineIds.has(l.id) && (
                          <Chip size="small" color="warning" label="Possible double entry" sx={{ mt: 0.5 }} />
                        )}
                      </TableCell>
                      <TableCell align="right">{fmt(l.amount)}</TableCell>
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

            <Stack spacing={2} sx={{ flex: 1 }}>
              {resolvedAccount && (
                <TableContainer component={Paper}>
                  <Box sx={{ p: 1.5, pb: 0 }}>
                    <Typography variant="subtitle2">Book — Open Settlements ({settlements.length})</Typography>
                  </Box>
                  <Table size="small">
                    <TableHead>
                      <TableRow>
                        <TableCell />
                        <TableCell>Date</TableCell>
                        <TableCell>Settlement</TableCell>
                        <TableCell align="right">Amount</TableCell>
                      </TableRow>
                    </TableHead>
                    <TableBody>
                      {settlements.map((s) => {
                        const signed = s.direction === 'in' ? Number(s.amount) : -Number(s.amount);
                        return (
                          <TableRow
                            key={s.id}
                            hover
                            selected={isSelected('settlement', s.id)}
                            onClick={() => toggleBook('settlement', s.id)}
                            sx={{ cursor: 'pointer' }}
                          >
                            <TableCell padding="checkbox">
                              <Chip size="small" label={isSelected('settlement', s.id) ? 'Selected' : ''} sx={{ visibility: isSelected('settlement', s.id) ? 'visible' : 'hidden' }} color="primary" />
                            </TableCell>
                            <TableCell>{s.settlement_date}</TableCell>
                            <TableCell>
                              {s.settlement_no ?? '—'}
                              <Typography variant="caption" color="text.secondary" display="block">
                                {s.direction === 'in' ? 'Money in' : 'Money out'}
                                {s.reference ? ` · Ref: ${s.reference}` : ''}
                              </Typography>
                              {amountMatchesLine(signed) && (
                                <Chip size="small" variant="outlined" color="success" label="Amount matches" sx={{ mt: 0.5 }} />
                              )}
                            </TableCell>
                            <TableCell align="right">
                              {signed.toLocaleString()}
                              <Typography variant="caption" color="text.secondary" display="block">
                                {s.currency}
                              </Typography>
                            </TableCell>
                          </TableRow>
                        );
                      })}
                      {settlements.length === 0 && (
                        <TableRow>
                          <TableCell colSpan={4} align="center" sx={{ color: 'text.secondary', py: 3 }}>
                            No open settlements near this window.
                          </TableCell>
                        </TableRow>
                      )}
                    </TableBody>
                  </Table>
                </TableContainer>
              )}

              <TableContainer component={Paper}>
                <Box sx={{ p: 1.5, pb: 0 }}>
                  <Typography variant="subtitle2">Book — Cash/Bank Transactions ({cashTxns.length})</Typography>
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
                          selected={isSelected('cash', t.id)}
                          onClick={() => toggleBook('cash', t.id)}
                          sx={{ cursor: 'pointer' }}
                        >
                          <TableCell padding="checkbox">
                            <Chip size="small" label={isSelected('cash', t.id) ? 'Selected' : ''} sx={{ visibility: isSelected('cash', t.id) ? 'visible' : 'hidden' }} color="primary" />
                          </TableCell>
                          <TableCell>{t.transaction_date}</TableCell>
                          <TableCell>
                            {t.description ?? '—'}
                            <Typography variant="caption" color="text.secondary" display="block">
                              {t.reference_type.replace('_', ' ')}
                            </Typography>
                            {amountMatchesLine(signed) && (
                              <Chip size="small" variant="outlined" color="success" label="Amount matches" sx={{ mt: 0.5 }} />
                            )}
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
          </Stack>

          <Stack direction="row" justifyContent="flex-end" sx={{ mb: 3 }}>
            <Button
              variant="contained"
              disabled={!selectedStatementLine || !selectedBook || matching}
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
                  <TableCell>Book entry</TableCell>
                  <TableCell align="right">Book Amt</TableCell>
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
                    <TableCell align="right">{fmt(v.statement_amount)}</TableCell>
                    <TableCell>
                      {v.transaction_date} — {v.transaction_description ?? '—'}
                      <Typography variant="caption" color="text.secondary" display="block">
                        {v.source === 'settlement' ? 'Settlement' : 'Cash/bank transaction'}
                      </Typography>
                    </TableCell>
                    <TableCell align="right">{fmt(v.transaction_amount)}</TableCell>
                    <TableCell align="right">
                      <Typography color={Number(v.variance) === 0 ? 'text.primary' : 'error'} fontWeight={600}>
                        {fmt(v.variance)}
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
