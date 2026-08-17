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
import type { CostCenter } from '@erp-platform/shared';

interface AccountOption {
  id: string;
  account_code: string;
  name: string;
  category_id: string | null;
}

interface OrganizationOption {
  id: string;
  company_code: string;
  site_name: string;
}

interface AccountCategoryOption {
  id: string;
  code: string;
  name: string;
}

interface ReceivableInvoiceRow {
  id: string;
  invoice_number: string;
  invoice_date: string;
  amount_incl_vat: number;
  vat_amount: number;
  currency: string;
  description: string | null;
  status: string;
  created_at: string;
  cost_centers: { name: string; project_code: string | null } | { name: string; project_code: string | null }[] | null;
  client_account: { name: string; account_code: string } | { name: string; account_code: string }[] | null;
  organization: { company_code: string; site_name: string } | { company_code: string; site_name: string }[] | null;
  recorded_by_user: { name: string } | { name: string }[] | null;
}

interface SearchFilters {
  invoiceNo: string;
  status: string;
  dateFrom: string;
  dateTo: string;
}

const emptyFilters: SearchFilters = { invoiceNo: '', status: '', dateFrom: '', dateTo: '' };

interface EntryState {
  organization_id: string;
  cost_center_id: string;
  client_account_id: string;
  invoice_number: string;
  invoice_date: string;
  amount_incl_vat: string;
  vat_amount: string;
  currency: string;
  description: string;
}

const emptyEntry: EntryState = {
  organization_id: '',
  cost_center_id: '',
  client_account_id: '',
  invoice_number: '',
  invoice_date: '',
  amount_incl_vat: '',
  vat_amount: '0',
  currency: 'UGX',
  description: '',
};

function embedOne<T>(value: T | T[] | null | undefined): T | null {
  if (!value) return null;
  return Array.isArray(value) ? value[0] ?? null : value;
}

export default function ReceivableInvoice() {
  const [filters, setFilters] = useState<SearchFilters>(emptyFilters);
  const [rows, setRows] = useState<ReceivableInvoiceRow[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [costCenters, setCostCenters] = useState<CostCenter[]>([]);
  const [loadingCostCenters, setLoadingCostCenters] = useState(false);
  const [clientAccounts, setClientAccounts] = useState<AccountOption[]>([]);
  const [loadingClientAccounts, setLoadingClientAccounts] = useState(false);
  const [organizations, setOrganizations] = useState<OrganizationOption[]>([]);
  const [loadingOrganizations, setLoadingOrganizations] = useState(false);
  const [accountCategories, setAccountCategories] = useState<AccountCategoryOption[]>([]);
  // UI-only: narrows the Client Account list below. Not persisted on
  // receivable_invoices -- category lives on accounts, not on the invoice.
  const [entryCategoryId, setEntryCategoryId] = useState('');

  const [showEntryForm, setShowEntryForm] = useState(false);
  const [entry, setEntry] = useState<EntryState>(emptyEntry);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);

  const runSearch = useCallback(async (activeFilters: SearchFilters) => {
    setLoading(true);
    setError(null);
    try {
      let query = supabase
        .from('receivable_invoices')
        .select(
          'id, invoice_number, invoice_date, amount_incl_vat, vat_amount, currency, description, status, created_at, cost_centers(name, project_code), client_account:accounts!client_account_id(name, account_code), organization:organizations!organization_id(company_code, site_name), recorded_by_user:app_users!recorded_by(name)'
        )
        .order('created_at', { ascending: false });

      if (activeFilters.invoiceNo.trim()) {
        query = query.ilike('invoice_number', `%${activeFilters.invoiceNo.trim()}%`);
      }
      if (activeFilters.status) {
        query = query.eq('status', activeFilters.status);
      }
      if (activeFilters.dateFrom) {
        query = query.gte('invoice_date', activeFilters.dateFrom);
      }
      if (activeFilters.dateTo) {
        query = query.lte('invoice_date', activeFilters.dateTo);
      }

      const { data, error: queryError } = await query;
      if (queryError) throw queryError;
      setRows((data ?? []) as unknown as ReceivableInvoiceRow[]);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed to load receivable invoices');
    } finally {
      setLoading(false);
    }
  }, []);

  const loadCostCenters = useCallback(async () => {
    setLoadingCostCenters(true);
    try {
      const { data, error: ccError } = await supabase
        .from('cost_centers')
        .select('id, tenant_id, name, project_code, budget_amount, created_at')
        .order('name');
      if (ccError) throw ccError;
      setCostCenters(data ?? []);
    } catch (e) {
      setSaveError(e instanceof Error ? e.message : 'Failed to load cost centers');
    } finally {
      setLoadingCostCenters(false);
    }
  }, []);

  const loadClientAccounts = useCallback(async () => {
    setLoadingClientAccounts(true);
    try {
      const { data, error: accError } = await supabase
        .from('accounts')
        .select('id, account_code, name, category_id')
        .eq('is_active', true)
        .in('account_type', ['client', 'both'])
        .order('name');
      if (accError) throw accError;
      setClientAccounts(data ?? []);
    } catch (e) {
      setSaveError(e instanceof Error ? e.message : 'Failed to load client accounts');
    } finally {
      setLoadingClientAccounts(false);
    }
  }, []);

  const loadOrganizations = useCallback(async () => {
    setLoadingOrganizations(true);
    try {
      const { data, error: orgError } = await supabase
        .from('organizations')
        .select('id, company_code, site_name')
        .eq('is_active', true)
        .order('company_code')
        .order('site_name');
      if (orgError) throw orgError;
      setOrganizations(data ?? []);
    } catch (e) {
      setSaveError(e instanceof Error ? e.message : 'Failed to load organizations');
    } finally {
      setLoadingOrganizations(false);
    }
  }, []);

  const loadAccountCategories = useCallback(async () => {
    try {
      const { data, error: catError } = await supabase
        .from('account_categories')
        .select('id, code, name')
        .eq('is_active', true)
        .order('name');
      if (catError) throw catError;
      setAccountCategories(data ?? []);
    } catch (e) {
      setSaveError(e instanceof Error ? e.message : 'Failed to load account categories');
    }
  }, []);

  useEffect(() => {
    runSearch(emptyFilters);
  }, [runSearch]);

  const costCenterOptions = useMemo(
    () => costCenters.map((cc) => ({ id: cc.id, label: `${cc.project_code} — ${cc.name}` })),
    [costCenters]
  );
  const organizationOptions = useMemo(
    () => organizations.map((o) => ({ id: o.id, label: `${o.company_code} — ${o.site_name}` })),
    [organizations]
  );
  const accountCategoryOptions = useMemo(
    () => accountCategories.map((c) => ({ id: c.id, label: c.name })),
    [accountCategories]
  );
  const clientAccountOptions = useMemo(
    () =>
      clientAccounts
        .filter((a) => !entryCategoryId || a.category_id === entryCategoryId)
        .map((a) => ({ id: a.id, label: `${a.account_code} — ${a.name}` })),
    [clientAccounts, entryCategoryId]
  );

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
    setEntry(emptyEntry);
    setEntryCategoryId('');
    loadCostCenters();
    loadClientAccounts();
    loadOrganizations();
    loadAccountCategories();
    setShowEntryForm(true);
  }

  async function handleSaveEntry(e: FormEvent) {
    e.preventDefault();
    setSaveError(null);

    if (
      !entry.organization_id ||
      !entry.client_account_id ||
      !entry.invoice_number ||
      !entry.invoice_date ||
      !entry.amount_incl_vat
    ) {
      setSaveError('Organization, client account, invoice number, invoice date, and amount are required.');
      return;
    }

    const parsedAmount = Number(entry.amount_incl_vat);
    if (Number.isNaN(parsedAmount) || parsedAmount <= 0) {
      setSaveError('Amount must be a valid number greater than 0.');
      return;
    }

    setSaving(true);

    const {
      data: { user },
    } = await supabase.auth.getUser();
    const { data: profile, error: profileError } = await supabase
      .from('app_users')
      .select('tenant_id')
      .eq('id', user?.id ?? '')
      .single();

    if (profileError || !profile) {
      setSaving(false);
      setSaveError(profileError?.message ?? 'Could not determine your tenant. Contact an admin.');
      return;
    }

    const { error: insertError } = await supabase.from('receivable_invoices').insert({
      tenant_id: profile.tenant_id,
      organization_id: entry.organization_id,
      // Overwritten unconditionally by assign_receivable_invoice_oif before the row is written.
      prf_oif_number: '',
      cost_center_id: entry.cost_center_id || null,
      client_account_id: entry.client_account_id,
      invoice_number: entry.invoice_number.trim(),
      invoice_date: entry.invoice_date,
      amount_incl_vat: parsedAmount,
      vat_amount: Number(entry.vat_amount || 0),
      currency: entry.currency,
      description: entry.description.trim() || null,
    });
    setSaving(false);

    if (insertError) {
      setSaveError(insertError.message ?? 'Could not save the receivable invoice. Try again.');
      return;
    }

    setShowEntryForm(false);
    setEntry(emptyEntry);
    setEntryCategoryId('');
    runSearch(filters);
  }

  return (
    <Box>
      <Stack direction="row" justifyContent="space-between" alignItems="center" sx={{ mb: 2 }}>
        <Typography variant="h5">Receivable Invoice</Typography>
        <Button variant="contained" startIcon={<AddIcon />} onClick={handleOpenEntryForm}>
          New Receivable Invoice
        </Button>
      </Stack>

      {/* Search */}
      <Paper sx={{ p: 3, mb: 3 }} variant="outlined">
        <Typography variant="subtitle1" sx={{ fontWeight: 600, mb: 2 }}>
          Search
        </Typography>
        <Box component="form" onSubmit={handleSearchSubmit}>
          <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2} flexWrap="wrap">
            <TextField
              label="Invoice No"
              size="small"
              sx={{ flex: 1, minWidth: 160 }}
              value={filters.invoiceNo}
              onChange={(e) => setFilters((f) => ({ ...f, invoiceNo: e.target.value }))}
            />
            <TextField
              select
              label="Status"
              size="small"
              sx={{ flex: 1, minWidth: 160 }}
              value={filters.status}
              onChange={(e) => setFilters((f) => ({ ...f, status: e.target.value }))}
            >
              <MenuItem value="">Any</MenuItem>
              <MenuItem value="open">Open</MenuItem>
              <MenuItem value="paid">Paid</MenuItem>
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
              New Receivable Invoice
            </Typography>
            <Box component="form" onSubmit={handleSaveEntry} noValidate>
              <Stack spacing={2.5}>
                <Autocomplete
                  options={organizationOptions}
                  loading={loadingOrganizations}
                  onChange={(_, option) => setEntry((v) => ({ ...v, organization_id: option?.id ?? '' }))}
                  value={organizationOptions.find((o) => o.id === entry.organization_id) ?? null}
                  isOptionEqualToValue={(option, value) => option.id === value.id}
                  renderInput={(params) => (
                    <TextField
                      {...params}
                      label="Organization"
                      InputProps={{
                        ...params.InputProps,
                        endAdornment: (
                          <>
                            {loadingOrganizations ? <CircularProgress color="inherit" size={16} /> : null}
                            {params.InputProps.endAdornment}
                          </>
                        ),
                      }}
                    />
                  )}
                />

                <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2}>
                  <TextField
                    select
                    label="Account Type"
                    sx={{ flex: 1 }}
                    value={entryCategoryId}
                    onChange={(e) => {
                      setEntryCategoryId(e.target.value);
                      setEntry((v) => ({ ...v, client_account_id: '' }));
                    }}
                  >
                    <MenuItem value="">All</MenuItem>
                    {accountCategoryOptions.map((c) => (
                      <MenuItem key={c.id} value={c.id}>
                        {c.label}
                      </MenuItem>
                    ))}
                  </TextField>

                  <Autocomplete
                    sx={{ flex: 2 }}
                    options={clientAccountOptions}
                    loading={loadingClientAccounts}
                    onChange={(_, option) => setEntry((v) => ({ ...v, client_account_id: option?.id ?? '' }))}
                    value={clientAccountOptions.find((o) => o.id === entry.client_account_id) ?? null}
                    isOptionEqualToValue={(option, value) => option.id === value.id}
                    renderInput={(params) => (
                      <TextField
                        {...params}
                        label="Client Account"
                        required
                        helperText={
                          !loadingClientAccounts && clientAccountOptions.length === 0
                            ? 'No client accounts set up yet'
                            : undefined
                        }
                        InputProps={{
                          ...params.InputProps,
                          endAdornment: (
                            <>
                              {loadingClientAccounts ? <CircularProgress color="inherit" size={16} /> : null}
                              {params.InputProps.endAdornment}
                            </>
                          ),
                        }}
                      />
                    )}
                  />
                </Stack>

                <TextField
                  label="Invoice No"
                  required
                  fullWidth
                  value={entry.invoice_number}
                  onChange={(e) => setEntry((v) => ({ ...v, invoice_number: e.target.value }))}
                />

                <Autocomplete
                  options={costCenterOptions}
                  loading={loadingCostCenters}
                  onChange={(_, option) => setEntry((v) => ({ ...v, cost_center_id: option?.id ?? '' }))}
                  value={costCenterOptions.find((o) => o.id === entry.cost_center_id) ?? null}
                  isOptionEqualToValue={(option, value) => option.id === value.id}
                  renderInput={(params) => (
                    <TextField
                      {...params}
                      label="Cost Center (optional — attributes revenue to a project)"
                      InputProps={{
                        ...params.InputProps,
                        endAdornment: (
                          <>
                            {loadingCostCenters ? <CircularProgress color="inherit" size={16} /> : null}
                            {params.InputProps.endAdornment}
                          </>
                        ),
                      }}
                    />
                  )}
                />

                <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2}>
                  <TextField
                    label="Invoice Date"
                    type="date"
                    required
                    sx={{ flex: 1 }}
                    InputLabelProps={{ shrink: true }}
                    value={entry.invoice_date}
                    onChange={(e) => setEntry((v) => ({ ...v, invoice_date: e.target.value }))}
                  />
                  <TextField
                    label="Amount (incl. VAT)"
                    type="number"
                    required
                    sx={{ flex: 1 }}
                    value={entry.amount_incl_vat}
                    onChange={(e) => setEntry((v) => ({ ...v, amount_incl_vat: e.target.value }))}
                  />
                </Stack>

                <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2}>
                  <TextField
                    label="VAT Amount"
                    type="number"
                    sx={{ flex: 1 }}
                    value={entry.vat_amount}
                    onChange={(e) => setEntry((v) => ({ ...v, vat_amount: e.target.value }))}
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
                </Stack>

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
                  <TableCell>Organization</TableCell>
                  <TableCell>Client</TableCell>
                  <TableCell>Cost Center</TableCell>
                  <TableCell>Invoice No</TableCell>
                  <TableCell>Invoice Date</TableCell>
                  <TableCell align="right">Amount (incl. VAT)</TableCell>
                  <TableCell>Currency</TableCell>
                  <TableCell align="right">VAT Amount</TableCell>
                  <TableCell>Status</TableCell>
                  <TableCell>Recorded By</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {rows.map((row) => {
                  const cc = embedOne(row.cost_centers);
                  const client = embedOne(row.client_account);
                  const org = embedOne(row.organization);
                  return (
                    <TableRow key={row.id} hover>
                      <TableCell>{org ? `${org.company_code} — ${org.site_name}` : '—'}</TableCell>
                      <TableCell>{client ? `${client.account_code} — ${client.name}` : '—'}</TableCell>
                      <TableCell>{cc ? `${cc.project_code ?? ''} ${cc.name}`.trim() : '—'}</TableCell>
                      <TableCell>{row.invoice_number}</TableCell>
                      <TableCell>{row.invoice_date}</TableCell>
                      <TableCell align="right">{row.amount_incl_vat.toLocaleString()}</TableCell>
                      <TableCell>{row.currency}</TableCell>
                      <TableCell align="right">{row.vat_amount.toLocaleString()}</TableCell>
                      <TableCell>
                        <Chip size="small" label={row.status} color={row.status === 'paid' ? 'success' : 'default'} />
                      </TableCell>
                      <TableCell>{embedOne(row.recorded_by_user)?.name ?? '—'}</TableCell>
                    </TableRow>
                  );
                })}
                {rows.length === 0 && (
                  <TableRow>
                    <TableCell colSpan={10} align="center" sx={{ color: 'text.secondary', py: 3 }}>
                      No receivable invoices found.
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