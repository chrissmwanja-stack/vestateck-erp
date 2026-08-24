import { useCallback, useEffect, useMemo, useState, FormEvent } from 'react';
import {
  Alert,
  Autocomplete,
  Box,
  Button,
  Card,
  CardContent,
  Chip,
  CircularProgress,
  MenuItem,
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
import { Search as SearchIcon, Clear as ClearIcon, Add as AddIcon } from '@mui/icons-material';
import { supabase } from '../../lib/supabaseClient';
import { useAuth } from '../../lib/authContext';
import { resolveTenantId } from '../../lib/ResolveTenantId';
import type { Database } from '@erp-platform/shared';

type ReferenceType = 'supplier_invoice' | 'expenditure_slip' | 'receivable_invoice' | 'payroll_run';
type PublicTableName = keyof Database['public']['Tables'];

const REFERENCE_TABLES: Record<ReferenceType, { table: PublicTableName; numberField: string; label: string }> = {
  supplier_invoice: { table: 'supplier_invoices', numberField: 'invoice_number', label: 'Supplier Invoice' },
  expenditure_slip: { table: 'expenditure_slips', numberField: 'slip_number', label: 'Expenditure Slip' },
  receivable_invoice: { table: 'receivable_invoices', numberField: 'invoice_number', label: 'Receivable Invoice' },
  payroll_run: { table: 'hr_payroll_runs', numberField: 'period', label: 'Payroll Run' },
};

interface CashBankTransactionRow {
  id: string;
  transaction_type: 'payment' | 'receipt';
  payment_method: 'cash' | 'bank';
  reference_type: ReferenceType;
  reference_id: string;
  amount: number;
  currency: string;
  transaction_date: string;
  bank_account: string | null;
  description: string | null;
  created_at: string;
  recorded_by_user: { name: string } | { name: string }[] | null;
}

interface SearchFilters {
  transactionType: string;
  dateFrom: string;
  dateTo: string;
}

const emptyFilters: SearchFilters = { transactionType: '', dateFrom: '', dateTo: '' };

interface RefOption {
  id: string;
  label: string;
}

interface EntryState {
  transaction_type: 'payment' | 'receipt';
  payment_method: 'cash' | 'bank';
  reference_type: ReferenceType;
  reference_id: string;
  amount: string;
  currency: string;
  transaction_date: string;
  bank_account: string;
  description: string;
}

const emptyEntry: EntryState = {
  transaction_type: 'payment',
  payment_method: 'bank',
  reference_type: 'supplier_invoice',
  reference_id: '',
  amount: '',
  currency: 'UGX',
  transaction_date: '',
  bank_account: '',
  description: '',
};

function embedOne<T>(value: T | T[] | null | undefined): T | null {
  if (!value) return null;
  return Array.isArray(value) ? value[0] ?? null : value;
}

export default function CashBankOperations() {
  const { session } = useAuth();
  const [filters, setFilters] = useState<SearchFilters>(emptyFilters);
  const [rows, setRows] = useState<CashBankTransactionRow[]>([]);
  const [refLabels, setRefLabels] = useState<Record<string, string>>({});
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [showEntryForm, setShowEntryForm] = useState(false);
  const [entry, setEntry] = useState<EntryState>(emptyEntry);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [saveWarning, setSaveWarning] = useState<string | null>(null);

  const [refOptions, setRefOptions] = useState<RefOption[]>([]);
  const [loadingRefOptions, setLoadingRefOptions] = useState(false);

  const runSearch = useCallback(async (activeFilters: SearchFilters) => {
    setLoading(true);
    setError(null);
    try {
      let query = supabase
        .from('cash_bank_transactions')
        .select(
          'id, transaction_type, payment_method, reference_type, reference_id, amount, currency, transaction_date, bank_account, description, created_at, recorded_by_user:app_users!recorded_by(name)'
        )
        .order('transaction_date', { ascending: false });

      if (activeFilters.transactionType) {
        query = query.eq('transaction_type', activeFilters.transactionType);
      }
      if (activeFilters.dateFrom) {
        query = query.gte('transaction_date', activeFilters.dateFrom);
      }
      if (activeFilters.dateTo) {
        query = query.lte('transaction_date', activeFilters.dateTo);
      }

      const { data, error: queryError } = await query;
      if (queryError) throw queryError;
      const loadedRows = (data ?? []) as unknown as CashBankTransactionRow[];
      setRows(loadedRows);

      // Every row here always has a reference_type + reference_id (both are
      // NOT NULL on the table), so batch-resolve labels per type in one
      // query each rather than N+1 lookups.
      const idsByType = loadedRows.reduce<Record<string, Set<string>>>((acc, row) => {
        acc[row.reference_type] ??= new Set();
        acc[row.reference_type].add(row.reference_id);
        return acc;
      }, {});

      const labelEntries: [string, string][] = [];
      await Promise.all(
        (Object.keys(idsByType) as ReferenceType[]).map(async (refType) => {
          const cfg = REFERENCE_TABLES[refType];
          const ids = Array.from(idsByType[refType]);
          const { data: refRows } = await supabase.from(cfg.table).select(`id, ${cfg.numberField}`).in('id', ids);
          (refRows ?? []).forEach((r: any) => {
            labelEntries.push([`${refType}:${r.id}`, r[cfg.numberField]]);
          });
        })
      );
      setRefLabels(Object.fromEntries(labelEntries));
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed to load cash and bank transactions');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    runSearch(emptyFilters);
  }, [runSearch]);

  // Load candidate reference rows whenever the entry form's reference_type
  // changes. receivable_invoices has an open/paid status, so once a receipt
  // settles one it drops out of this list; supplier_invoices and
  // expenditure_slips have no status column to filter on, so every row is
  // still a candidate for those two.
  useEffect(() => {
    const cfg = REFERENCE_TABLES[entry.reference_type];
    let cancelled = false;
    setLoadingRefOptions(true);
    // receivable_invoices is queried directly by name (rather than through
    // cfg.table) so its status column type-checks — cfg.table is a union
    // of all four reference tables, and only receivable_invoices has a
    // status column, so .eq('status', ...) can't resolve against the union.
    const refQuery =
      entry.reference_type === 'receivable_invoice'
        ? supabase.from('receivable_invoices').select(`id, ${cfg.numberField}`).eq('status', 'open').order(cfg.numberField)
        : supabase.from(cfg.table).select(`id, ${cfg.numberField}`).order(cfg.numberField);
    refQuery.then(({ data, error: refError }) => {
      if (cancelled) return;
      if (refError) {
        setSaveError(refError.message);
        setRefOptions([]);
      } else {
        setRefOptions((data ?? []).map((r: any) => ({ id: r.id, label: r[cfg.numberField] })));
      }
      setLoadingRefOptions(false);
    });
    return () => {
      cancelled = true;
    };
  }, [entry.reference_type]);

  function handleSearchSubmit(e: FormEvent) {
    e.preventDefault();
    runSearch(filters);
  }

  function handleClear() {
    setFilters(emptyFilters);
    runSearch(emptyFilters);
  }

  function handleOpenEntryForm() {
    setSaveError(null);
    setSaveWarning(null);
    setEntry(emptyEntry);
    setShowEntryForm(true);
  }

  async function handleSaveEntry(e: FormEvent) {
    e.preventDefault();
    setSaveError(null);
    setSaveWarning(null);

    if (!entry.reference_id || !entry.amount || !entry.transaction_date) {
      setSaveError('Reference item, amount, and transaction date are required.');
      return;
    }

    const parsedAmount = Number(entry.amount);
    if (Number.isNaN(parsedAmount) || parsedAmount <= 0) {
      setSaveError('Amount must be a valid number greater than 0.');
      return;
    }

    setSaving(true);
    // tenant_id is `uuid NOT NULL` with no column default. The comment
    // this replaced claimed set_cash_bank_transaction_defaults_trigger
    // "unconditionally overwrites it server-side... this value is never
    // actually used" -- that's not correct: Postgres coerces insert
    // values to their column type before any row-level trigger ever
    // runs, so a placeholder '' fails outright ("invalid input syntax
    // for type uuid") and the trigger never gets the chance to run at
    // all. Resolve the real tenant_id client-side instead.
    const tenantResult = await resolveTenantId(session);
    if (!tenantResult.ok) {
      setSaving(false);
      setSaveError(tenantResult.error);
      return;
    }
    const { error: insertError } = await supabase.from('cash_bank_transactions').insert({
      tenant_id: tenantResult.tenantId,
      transaction_type: entry.transaction_type,
      payment_method: entry.payment_method,
      reference_type: entry.reference_type,
      reference_id: entry.reference_id,
      amount: parsedAmount,
      currency: entry.currency,
      transaction_date: entry.transaction_date,
      bank_account: entry.payment_method === 'bank' ? entry.bank_account.trim() || null : null,
      description: entry.description.trim() || null,
    });

    if (insertError) {
      setSaving(false);
      setSaveError(insertError.message ?? 'Could not save the transaction. Try again.');
      return;
    }

    // A receipt against a receivable invoice settles it -- nothing in the
    // database does this automatically (no trigger touches
    // receivable_invoices.status), so it's done here, as a second step
    // after the transaction itself is safely saved. If this step fails,
    // the transaction still stands; surface a warning rather than losing
    // the record of money received.
    if (entry.reference_type === 'receivable_invoice' && entry.transaction_type === 'receipt') {
      const { error: statusError } = await supabase
        .from('receivable_invoices')
        .update({ status: 'paid' })
        .eq('id', entry.reference_id);
      if (statusError) {
        setSaving(false);
        setSaveWarning(
          `Transaction saved, but the invoice could not be marked paid (${statusError.message}). Update its status manually.`
        );
        setShowEntryForm(false);
        setEntry(emptyEntry);
        runSearch(filters);
        return;
      }
    }

    setSaving(false);
    setShowEntryForm(false);
    setEntry(emptyEntry);
    runSearch(filters);
  }

  const selectedRefOption = useMemo(
    () => refOptions.find((o) => o.id === entry.reference_id) ?? null,
    [refOptions, entry.reference_id]
  );

  return (
    <Box>
      <Stack direction="row" justifyContent="space-between" alignItems="center" sx={{ mb: 2 }}>
        <Typography variant="h5">Cash and Bank Operations</Typography>
        <Button variant="contained" startIcon={<AddIcon />} onClick={handleOpenEntryForm}>
          New Transaction
        </Button>
      </Stack>

      {saveWarning && (
        <Alert severity="warning" sx={{ mb: 2 }} onClose={() => setSaveWarning(null)}>
          {saveWarning}
        </Alert>
      )}

      {/* Search */}
      <Paper sx={{ p: 3, mb: 3 }} variant="outlined">
        <Typography variant="subtitle1" sx={{ fontWeight: 600, mb: 2 }}>
          Search
        </Typography>
        <Box component="form" onSubmit={handleSearchSubmit}>
          <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2} flexWrap="wrap">
            <TextField
              select
              label="Type"
              size="small"
              sx={{ flex: 1, minWidth: 160 }}
              value={filters.transactionType}
              onChange={(e) => setFilters((f) => ({ ...f, transactionType: e.target.value }))}
            >
              <MenuItem value="">Any</MenuItem>
              <MenuItem value="payment">Payment</MenuItem>
              <MenuItem value="receipt">Receipt</MenuItem>
            </TextField>
            <TextField
              label="Date From"
              type="date"
              size="small"
              sx={{ flex: 1, minWidth: 160 }}
              InputLabelProps={{ shrink: true }}
              value={filters.dateFrom}
              onChange={(e) => setFilters((f) => ({ ...f, dateFrom: e.target.value }))}
            />
            <TextField
              label="Date To"
              type="date"
              size="small"
              sx={{ flex: 1, minWidth: 160 }}
              InputLabelProps={{ shrink: true }}
              value={filters.dateTo}
              onChange={(e) => setFilters((f) => ({ ...f, dateTo: e.target.value }))}
            />
          </Stack>
          <Stack direction="row" spacing={1} sx={{ mt: 2 }}>
            <Button type="submit" variant="contained" startIcon={<SearchIcon />}>
              Search
            </Button>
            <Button variant="outlined" startIcon={<ClearIcon />} onClick={handleClear}>
              Clear
            </Button>
          </Stack>
        </Box>
      </Paper>

      {/* Entry form */}
      {showEntryForm && (
        <Card sx={{ mb: 3 }} variant="outlined">
          <CardContent>
            <Typography variant="h6" gutterBottom>
              New Cash / Bank Transaction
            </Typography>
            <Box component="form" onSubmit={handleSaveEntry} noValidate>
              <Stack spacing={2.5}>
                <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2}>
                  <TextField
                    select
                    label="Transaction Type"
                    required
                    sx={{ flex: 1 }}
                    value={entry.transaction_type}
                    onChange={(e) =>
                      setEntry((v) => ({ ...v, transaction_type: e.target.value as 'payment' | 'receipt' }))
                    }
                  >
                    <MenuItem value="payment">Payment (money out)</MenuItem>
                    <MenuItem value="receipt">Receipt (money in)</MenuItem>
                  </TextField>
                  <TextField
                    select
                    label="Payment Method"
                    required
                    sx={{ flex: 1 }}
                    value={entry.payment_method}
                    onChange={(e) => setEntry((v) => ({ ...v, payment_method: e.target.value as 'cash' | 'bank' }))}
                  >
                    <MenuItem value="cash">Cash</MenuItem>
                    <MenuItem value="bank">Bank</MenuItem>
                  </TextField>
                  <TextField
                    select
                    label="Settles Against"
                    required
                    sx={{ flex: 1 }}
                    value={entry.reference_type}
                    onChange={(e) =>
                      setEntry((v) => ({
                        ...v,
                        reference_type: e.target.value as ReferenceType,
                        reference_id: '',
                      }))
                    }
                  >
                    <MenuItem value="supplier_invoice">Supplier Invoice</MenuItem>
                    <MenuItem value="expenditure_slip">Expenditure Slip</MenuItem>
                    <MenuItem value="receivable_invoice">Receivable Invoice</MenuItem>
                    <MenuItem value="payroll_run">Payroll Run</MenuItem>
                  </TextField>
                </Stack>

                <Autocomplete
                  options={refOptions}
                  loading={loadingRefOptions}
                  onChange={(_, option) => setEntry((v) => ({ ...v, reference_id: option?.id ?? '' }))}
                  value={selectedRefOption}
                  isOptionEqualToValue={(option, value) => option.id === value.id}
                  renderInput={(params) => (
                    <TextField
                      {...params}
                      label={`${REFERENCE_TABLES[entry.reference_type].label} No.`}
                      required
                      helperText={
                        entry.reference_type === 'receivable_invoice'
                          ? 'Showing open (unpaid) invoices only'
                          : undefined
                      }
                      InputProps={{
                        ...params.InputProps,
                        endAdornment: (
                          <>
                            {loadingRefOptions ? <CircularProgress color="inherit" size={16} /> : null}
                            {params.InputProps.endAdornment}
                          </>
                        ),
                      }}
                    />
                  )}
                />

                {entry.reference_type === 'receivable_invoice' && entry.transaction_type === 'receipt' && (
                  <Alert severity="info">Saving this will mark the selected invoice as paid.</Alert>
                )}

                <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2}>
                  <TextField
                    label="Amount"
                    type="number"
                    required
                    sx={{ flex: 1 }}
                    value={entry.amount}
                    onChange={(e) => setEntry((v) => ({ ...v, amount: e.target.value }))}
                  />
                  <TextField
                    select
                    label="Currency"
                    sx={{ flex: 1 }}
                    value={entry.currency}
                    onChange={(e) => setEntry((v) => ({ ...v, currency: e.target.value }))}
                  >
                    <MenuItem value="UGX">UGX</MenuItem>
                    <MenuItem value="USD">USD</MenuItem>
                    <MenuItem value="EUR">EUR</MenuItem>
                  </TextField>
                  <TextField
                    label="Transaction Date"
                    type="date"
                    required
                    sx={{ flex: 1 }}
                    InputLabelProps={{ shrink: true }}
                    value={entry.transaction_date}
                    onChange={(e) => setEntry((v) => ({ ...v, transaction_date: e.target.value }))}
                  />
                </Stack>

                {entry.payment_method === 'bank' && (
                  <TextField
                    label="Bank Account"
                    fullWidth
                    value={entry.bank_account}
                    onChange={(e) => setEntry((v) => ({ ...v, bank_account: e.target.value }))}
                  />
                )}

                <TextField
                  label="Description"
                  fullWidth
                  value={entry.description}
                  onChange={(e) => setEntry((v) => ({ ...v, description: e.target.value }))}
                />

                {saveError && <Alert severity="error">{saveError}</Alert>}

                <Stack direction="row" spacing={1}>
                  <Button type="submit" variant="contained" disabled={saving}>
                    {saving ? 'Saving…' : 'Save'}
                  </Button>
                  <Button variant="outlined" onClick={() => setShowEntryForm(false)} disabled={saving}>
                    Cancel
                  </Button>
                </Stack>
              </Stack>
            </Box>
          </CardContent>
        </Card>
      )}

      {/* Results */}
      <Paper sx={{ p: 2 }} variant="outlined">
        <Typography variant="subtitle1" sx={{ fontWeight: 600, mb: 1 }}>
          Items
        </Typography>
        {error && <Alert severity="error">{error}</Alert>}
        {loading ? (
          <Box sx={{ display: 'flex', justifyContent: 'center', py: 4 }}>
            <CircularProgress size={24} />
          </Box>
        ) : (
          <TableContainer>
            <Table size="small">
              <TableHead>
                <TableRow>
                  <TableCell>Type</TableCell>
                  <TableCell>Method</TableCell>
                  <TableCell>Reference</TableCell>
                  <TableCell>Date</TableCell>
                  <TableCell align="right">Amount</TableCell>
                  <TableCell>Currency</TableCell>
                  <TableCell>Bank Account</TableCell>
                  <TableCell>Recorded By</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {rows.map((row) => {
                  const refLabel = refLabels[`${row.reference_type}:${row.reference_id}`] ?? '—';
                  return (
                    <TableRow key={row.id} hover>
                      <TableCell>
                        <Chip
                          size="small"
                          label={row.transaction_type}
                          color={row.transaction_type === 'receipt' ? 'success' : 'default'}
                        />
                      </TableCell>
                      <TableCell>{row.payment_method}</TableCell>
                      <TableCell>{`${REFERENCE_TABLES[row.reference_type].label}: ${refLabel}`}</TableCell>
                      <TableCell>{row.transaction_date}</TableCell>
                      <TableCell align="right">{row.amount.toLocaleString()}</TableCell>
                      <TableCell>{row.currency}</TableCell>
                      <TableCell>{row.bank_account ?? '—'}</TableCell>
                      <TableCell>{embedOne(row.recorded_by_user)?.name ?? '—'}</TableCell>
                    </TableRow>
                  );
                })}
                {rows.length === 0 && (
                  <TableRow>
                    <TableCell colSpan={8} align="center" sx={{ color: 'text.secondary', py: 3 }}>
                      No transactions found.
                    </TableCell>
                  </TableRow>
                )}
              </TableBody>
            </Table>
          </TableContainer>
        )}
      </Paper>
    </Box>
  );
}