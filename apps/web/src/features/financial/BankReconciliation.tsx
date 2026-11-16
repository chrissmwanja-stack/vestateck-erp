import { useState } from 'react';
import { Alert, Autocomplete, Box, Button, CircularProgress, Divider, Paper, Stack, TextField, Typography } from '@mui/material';
import { AccountBalance as AccountBalanceIcon, Sync as SyncIcon, UploadFile as UploadFileIcon } from '@mui/icons-material';
import { supabase } from '../../lib/supabaseClient';
import { db } from './bank-reconciliation/db';
import type { BookSource } from './bank-reconciliation/types';
import { monthAgo, today } from './bank-reconciliation/utils';
import { useFinanceAccess } from './bank-reconciliation/useFinanceAccess';
import { useReconciliationData } from './bank-reconciliation/useReconciliationData';
import { PositionPanel } from './bank-reconciliation/PositionPanel';
import { StatementTable } from './bank-reconciliation/StatementTable';
import { SettlementsTable } from './bank-reconciliation/SettlementsTable';
import { TransferSidesTable } from './bank-reconciliation/TransferSidesTable';
import { CashTransactionsTable } from './bank-reconciliation/CashTransactionsTable';
import { VarianceReport } from './bank-reconciliation/VarianceReport';
import { ImportStatementDialog } from './bank-reconciliation/ImportStatementDialog';

// Bank reconciliation screen: pick a bank account and window, then match each
// unmatched statement line against a posted settlement, a commission transfer
// or a legacy cash/bank transaction -- automatically where amount and date
// line up, by hand otherwise. This file owns the form state and the match /
// auto-match / unmatch actions; reads live in useReconciliationData and the
// tables in ./bank-reconciliation/.

export default function BankReconciliation() {
  const isFinance = useFinanceAccess();
  const [bankAccount, setBankAccount] = useState('');
  const [dateFrom, setDateFrom] = useState(monthAgo());
  const [dateTo, setDateTo] = useState(today());

  const {
    registry,
    registryLoaded,
    resolvedAccount,
    statementLines,
    cashTxns,
    settlements,
    transferSides,
    doubleEntryLineIds,
    position,
    positionError,
    variances,
    loading,
    error,
    setError,
    selectedStatementLine,
    setSelectedStatementLine,
    selectedBook,
    setSelectedBook,
    load,
  } = useReconciliationData(bankAccount, dateFrom, dateTo);

  const [info, setInfo] = useState<string | null>(null);
  const [matching, setMatching] = useState(false);
  const [autoMatching, setAutoMatching] = useState(false);
  const [importOpen, setImportOpen] = useState(false);

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
        : selectedBook.source === 'transfer'
          ? await db.rpc('match_bank_statement_line_to_commission_transfer', {
              p_statement_line_id: selectedStatementLine,
              p_transfer_id: selectedBook.id,
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

  function handleImported(count: number) {
    setImportOpen(false);
    setInfo(`Imported ${count} statement line${count === 1 ? '' : 's'}.`);
    load();
  }

  const isSelected = (source: BookSource, id: string) => selectedBook?.source === source && selectedBook.id === id;
  const toggleBook = (source: BookSource, id: string) =>
    setSelectedBook(isSelected(source, id) ? null : { source, id });
  // Hint only -- the server re-checks amount, currency, status and date
  // window when the match is made.
  const amountMatchesLine = (signed: number) => selectedLine != null && Number(selectedLine.amount) === signed;

  const account = bankAccount.trim();

  return (
    <Box sx={{ p: 3, maxWidth: 1300 }}>
      <Typography variant="h5" sx={{ display: 'flex', alignItems: 'center', gap: 1, mb: 1 }}>
        <AccountBalanceIcon /> Bank Reconciliation
      </Typography>
      <Alert severity="info" sx={{ mb: 2 }}>
        Insurance premium receipts and insurer remittances must be matched or unmatched by a third Finance user,
        different from their maker and checker/poster. Auto-match skips movements you are not independent of.
      </Alert>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        Import a bank statement, then match each line against a posted settlement, a commission transfer or a recorded cash/bank transaction —
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
          <Button variant="outlined" startIcon={<UploadFileIcon />} onClick={() => setImportOpen(true)}>
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

          {resolvedAccount && <PositionPanel position={position} positionError={positionError} dateTo={dateTo} />}

          {doubleEntryLineIds.size > 0 && (
            <Alert severity="warning" sx={{ mb: 2 }} data-testid="double-entry-alert">
              {doubleEntryLineIds.size} statement line{doubleEntryLineIds.size === 1 ? '' : 's'} could match both a
              settlement and a legacy cash/bank transaction. The same movement may be recorded twice — match one and
              review the other. Auto-match leaves these for you.
            </Alert>
          )}

          <Stack direction={{ xs: 'column', md: 'row' }} spacing={2} sx={{ mb: 2 }}>
            <StatementTable
              statementLines={statementLines}
              selectedStatementLine={selectedStatementLine}
              setSelectedStatementLine={setSelectedStatementLine}
              doubleEntryLineIds={doubleEntryLineIds}
            />

            <Stack spacing={2} sx={{ flex: 1 }}>
              {resolvedAccount && (
                <SettlementsTable
                  settlements={settlements}
                  isSelected={isSelected}
                  toggleBook={toggleBook}
                  amountMatchesLine={amountMatchesLine}
                />
              )}

              {resolvedAccount && transferSides.length > 0 && (
                <TransferSidesTable
                  transferSides={transferSides}
                  isSelected={isSelected}
                  toggleBook={toggleBook}
                  amountMatchesLine={amountMatchesLine}
                />
              )}

              <CashTransactionsTable
                cashTxns={cashTxns}
                isSelected={isSelected}
                toggleBook={toggleBook}
                amountMatchesLine={amountMatchesLine}
              />
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

          <VarianceReport variances={variances} onUnmatch={handleUnmatch} />
        </>
      )}

      <ImportStatementDialog
        open={importOpen}
        bankAccount={bankAccount}
        onClose={() => setImportOpen(false)}
        onImported={handleImported}
      />
    </Box>
  );
}
