import { useCallback, useEffect, useMemo, useState } from 'react';
import { supabase } from '../../../lib/supabaseClient';
import { db } from './db';
import type {
  BankAccountRow,
  BookSelection,
  CashBankTxn,
  CommissionTransferRow,
  DoubleEntryRow,
  PositionRow,
  SettlementRow,
  StatementLine,
  SuggestedMatch,
  TransferSideRow,
  VarianceRow,
} from './types';
import { MATCH_WINDOW_DAYS, shiftDate } from './utils';

// Everything the screen reads: the bank registry, the unmatched statement
// lines, the open book entries (settlements, commission transfers, legacy
// cash/bank transactions), the position summary and the variance report.
// `load` re-reads all of it and clears the current selection.
export function useReconciliationData(bankAccount: string, dateFrom: string, dateTo: string) {
  const [registry, setRegistry] = useState<BankAccountRow[]>([]);
  const [registryLoaded, setRegistryLoaded] = useState(false);

  const [statementLines, setStatementLines] = useState<StatementLine[]>([]);
  const [cashTxns, setCashTxns] = useState<CashBankTxn[]>([]);
  const [settlements, setSettlements] = useState<SettlementRow[]>([]);
  const [transferSides, setTransferSides] = useState<TransferSideRow[]>([]);
  const [doubleEntryLineIds, setDoubleEntryLineIds] = useState<Set<string>>(new Set());
  const [position, setPosition] = useState<PositionRow[] | null>(null);
  const [positionError, setPositionError] = useState<string | null>(null);
  const [variances, setVariances] = useState<VarianceRow[]>([]);
  const [suggestions, setSuggestions] = useState<SuggestedMatch[]>([]);
  const [suggestionsError, setSuggestionsError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [selectedStatementLine, setSelectedStatementLine] = useState<string | null>(null);
  const [selectedBook, setSelectedBook] = useState<BookSelection | null>(null);

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
      setTransferSides([]);
      setDoubleEntryLineIds(new Set());
      setPosition(null);
      setPositionError(null);
      setVariances([]);
      setSuggestions([]);
      setSuggestionsError(null);
      return;
    }
    setLoading(true);
    setError(null);

    const bookFrom = shiftDate(dateFrom, -MATCH_WINDOW_DAYS);
    const bookTo = shiftDate(dateTo, MATCH_WINDOW_DAYS);

    const settlementsQuery = resolvedAccountId
      ? db
          .from('fin_settlements')
          .select('id, settlement_no, direction, amount, currency, settlement_date, reference, notes, subledger_only, funding_transaction_id')
          .eq('bank_account_id', resolvedAccountId)
          .eq('status', 'posted')
          .gte('settlement_date', bookFrom)
          .lte('settlement_date', bookTo)
          .order('settlement_date')
      : Promise.resolve({ data: [] as SettlementRow[], error: null });

    // Commission transfers are read by account in JS below: the table is
    // tenant-scoped by RLS and small, and filtering on either bank column
    // would need an OR the other lists do not.
    const transfersQuery = resolvedAccountId
      ? db
          .from('ins_commission_transfers')
          .select('id, transfer_no, from_bank_account_id, to_bank_account_id, transfer_date, amount, currency, notes')
          .eq('status', 'posted')
          .gte('transfer_date', bookFrom)
          .lte('transfer_date', bookTo)
          .order('transfer_date')
      : Promise.resolve({ data: [] as CommissionTransferRow[], error: null });

    // The suggestion queue: what the database thinks could match each open
    // line. Read-only -- it persists nothing.
    const suggestionsQuery = db.rpc('fin_bank_suggested_matches', {
      p_bank_account: account,
      p_date_from: dateFrom,
      p_date_to: dateTo,
    });

    const positionQuery = resolvedAccountId
      ? db.rpc('fin_bank_reconciliation_position', { p_bank_account_id: resolvedAccountId, p_as_of: dateTo })
      : Promise.resolve({ data: null, error: null });

    const [
      { data: lines, error: lineErr },
      { data: txns, error: txnErr },
      { data: varRows, error: varErr },
      { data: settleRows, error: settleErr },
      { data: transferRows, error: transferErr },
      { data: doubleRows, error: doubleErr },
      { data: posRows, error: posErr },
      { data: suggestionRows, error: suggestionErr },
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
      transfersQuery,
      db.from('v_bank_possible_double_entries').select('statement_line_id').eq('bank_account', account),
      positionQuery,
      suggestionsQuery,
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

    // Keep only the side of each transfer that belongs to this bank, and drop
    // sides that already have a reconciliation row.
    let openTransferSides: TransferSideRow[] = [];
    let transferReconErr: string | null = null;
    const transferList = ((transferRows ?? []) as CommissionTransferRow[]).filter(
      (t) => t.from_bank_account_id === resolvedAccountId || t.to_bank_account_id === resolvedAccountId
    );
    if (!transferErr && transferList.length > 0) {
      const { data: tReconRows, error: tErr } = await db
        .from('bank_reconciliations')
        .select('commission_transfer_id, transfer_side')
        .in(
          'commission_transfer_id',
          transferList.map((t) => t.id)
        );
      if (tErr) {
        transferReconErr = tErr.message;
      } else {
        const done = new Set(
          (tReconRows ?? []).map(
            (r: { commission_transfer_id: string; transfer_side: string }) => `${r.commission_transfer_id}:${r.transfer_side}`
          )
        );
        openTransferSides = transferList
          .map((t): TransferSideRow => {
            const side = t.from_bank_account_id === resolvedAccountId ? 'from' : 'to';
            return {
              id: t.id,
              transfer_no: t.transfer_no,
              side,
              signed: side === 'to' ? Number(t.amount) : -Number(t.amount),
              currency: t.currency,
              transfer_date: t.transfer_date,
              notes: t.notes,
            };
          })
          .filter((t) => !done.has(`${t.id}:${t.side}`));
      }
    }

    const firstError = lineErr ?? txnErr ?? varErr ?? settleErr ?? transferErr ?? doubleErr;
    if (firstError || reconErr || transferReconErr) {
      setError(firstError?.message ?? reconErr ?? transferReconErr ?? 'Could not load reconciliation data.');
    } else {
      setStatementLines((lines ?? []) as StatementLine[]);
      setCashTxns((txns ?? []) as CashBankTxn[]);
      setSettlements(openSettlements);
      setTransferSides(openTransferSides);
      setVariances((varRows ?? []) as unknown as VarianceRow[]);
      const lineIds = new Set(((lines ?? []) as StatementLine[]).map((l) => l.id));
      setDoubleEntryLineIds(
        new Set(
          ((doubleRows ?? []) as DoubleEntryRow[]).map((r) => r.statement_line_id).filter((id) => lineIds.has(id))
        )
      );
    }

    // Suggestions have their own error slot too: a queue that cannot load
    // must not stop the desk matching by hand.
    if (suggestionErr) {
      setSuggestions([]);
      setSuggestionsError(suggestionErr.message ?? 'Could not load suggested matches.');
    } else {
      setSuggestions((suggestionRows ?? []) as SuggestedMatch[]);
      setSuggestionsError(null);
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

  return {
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
    suggestions,
    suggestionsError,
    loading,
    error,
    setError,
    selectedStatementLine,
    setSelectedStatementLine,
    selectedBook,
    setSelectedBook,
    load,
  };
}
