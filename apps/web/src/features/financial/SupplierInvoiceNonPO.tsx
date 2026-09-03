import { useCallback, useEffect, useMemo, useState, FormEvent } from 'react';
import {
  Alert,
  Autocomplete,
  Box,
  Button,
  Card,
  CardContent,
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

interface SupplierInvoiceRow {
  id: string;
  invoice_number: string;
  invoice_date: string;
  amount_incl_vat: number;
  vat_amount: number;
  wht_rate: number | null;
  wht_amount: number;
  currency: string;
  description: string | null;
  created_at: string;
  cost_centers: { name: string; project_code: string | null } | { name: string; project_code: string | null }[] | null;
  vendor_account: { name: string; account_code: string } | { name: string; account_code: string }[] | null;
  organization: { company_code: string; site_name: string } | { company_code: string; site_name: string }[] | null;
  recorded_by_user: { name: string } | { name: string }[] | null;
}

interface SearchFilters {
  invoiceNo: string;
  dateFrom: string;
  dateTo: string;
}

const emptyFilters: SearchFilters = { invoiceNo: '', dateFrom: '', dateTo: '' };

interface EntryState {
  cost_center_id: string;
  vendor_account_id: string;
  organization_id: string;
  invoice_number: string;
  invoice_date: string;
  amount_incl_vat: string;
  vat_amount: string;
  wht_rate: string;
  wht_amount: string;
  currency: string;
  description: string;
}

const emptyEntry: EntryState = {
  cost_center_id: '',
  vendor_account_id: '',
  organization_id: '',
  invoice_number: '',
  invoice_date: '',
  amount_incl_vat: '',
  vat_amount: '0',
  wht_rate: '',
  wht_amount: '0',
  currency: 'UGX',
  description: '',
};

function embedOne<T>(value: T | T[] | null | undefined): T | null {
  if (!value) return null;
  return Array.isArray(value) ? value[0] ?? null : value;
}

export default function SupplierInvoiceNonPO() {
  const [filters, setFilters] = useState<SearchFilters>(emptyFilters);
  const [rows, setRows] = useState<SupplierInvoiceRow[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [costCenters, setCostCenters] = useState<CostCenter[]>([]);
  const [loadingCostCenters, setLoadingCostCenters] = useState(false);
  const [vendorAccounts, setVendorAccounts] = useState<AccountOption[]>([]);
  const [loadingVendorAccounts, setLoadingVendorAccounts] = useState(false);
  const [organizations, setOrganizations] = useState<OrganizationOption[]>([]);
  const [loadingOrganizations, setLoadingOrganizations] = useState(false);
  const [accountCategories, setAccountCategories] = useState<AccountCategoryOption[]>([]);
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
        .from('supplier_invoices')
        .select(
          'id, invoice_number, invoice_date, amount_incl_vat, vat_amount, currency, description, created_at, cost_centers(name, project_code), vendor_account:accounts!vendor_account_id(name, account_code), organization:organizations!organization_id(company_code, site_name), recorded_by_user:app_users!recorded_by(name)'
        )
        .eq('invoice_type', 'non_po')
        .order('created_at', { ascending: false });

      if (activeFilters.invoiceNo.trim()) {
        query = query.ilike('invoice_number', `%${activeFilters.invoiceNo.trim()}%`);
      }
      if (activeFilters.dateFrom) {
        query = query.gte('invoice_date', activeFilters.dateFrom);
      }
      if (activeFilters.dateTo) {
        query = query.lte('invoice_date', activeFilters.dateTo);
      }

      const { data, error: queryError } = await query;
      if (queryError) throw queryError;
      setRows((data ?? []) as unknown as SupplierInvoiceRow[]);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed to load supplier invoices');
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

  const loadVendorAccounts = useCallback(async () => {
    setLoadingVendorAccounts(true);
    try {
      const { data, error: accError } = await supabase
        .from('accounts')
        .select('id, account_code, name, category_id')
        .eq('is_active', true)
        .in('account_type', ['vendor', 'both'])
        .order('name');
      if (accError) throw accError;
      setVendorAccounts(data ?? []);
    } catch (e) {
      setSaveError(e instanceof Error ? e.message : 'Failed to load vendor accounts');
    } finally {
      setLoadingVendorAccounts(false);
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
  const vendorAccountOptions = useMemo(
    () =>
      vendorAccounts
        .filter((a) => !entryCategoryId || a.category_id === entryCategoryId)
        .map((a) => ({ id: a.id, label: `${a.account_code} — ${a.name}` })),
    [vendorAccounts, entryCategoryId]
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
    loadVendorAccounts();
    loadOrganizations();
    loadAccountCategories();
    setShowEntryForm(true);
  }

  async function handleSaveEntry(e: FormEvent) {
    e.preventDefault();
    setSaveError(null);

    if (
      !entry.organization_id ||
      !entry.cost_center_id ||
      !entry.vendor_account_id ||
      !entry.invoice_number ||
      !entry.invoice_date ||
      !entry.amount_incl_vat
    ) {
      setSaveError('Organization, cost center, vendor account, invoice number, invoice date, and amount are required.');
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

    const { error: insertError } = await supabase.from('supplier_invoices').insert({
      tenant_id: profile.tenant_id,
      // Overwritten unconditionally by assign_supplier_invoice_oif before the row is written.
      prf_oif_number: '',
      cost_center_id: entry.cost_center_id,
      vendor_account_id: entry.vendor_account_id,
      organization_id: entry.organization_id,
      invoice_number: entry.invoice_number.trim(),
      invoice_date: entry.invoice_date,
      amount_incl_vat: parsedAmount,
      vat_amount: Number(entry.vat_amount || 0),
      currency: entry.currency,
      description: entry.description.trim() || null,
      // purchase_order_id intentionally omitted -- NULL is what makes this a non-PO row.
    });
    setSaving(false);

    if (insertError) {
      setSaveError(insertError.message ?? 'Could not save the supplier invoice. Try again.');
      return;
    }

    setShowEntryForm(false);
    setEntry(emptyEntry);
    runSearch(filters);
  }

  return (
    <Box>
      <Stack direction="row" justifyContent="space-between" alignItems="center" sx={{ mb: 2 }}>
        <Typography variant="h5">Supplier Invoice</Typography>
        <Button variant="contained" startIcon={<AddIcon />} onClick={handleOpenEntryForm}>
          New Supplier Invoice
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
              New Supplier Invoice
            </Typography>
            <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
              For expenses not tied to a purchase order — charged directly to a cost center.
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

                <Autocomplete
                  options={costCenterOptions}
                  loading={loadingCostCenters}
                  onChange={(_, option) => setEntry((v) => ({ ...v, cost_center_id: option?.id ?? '' }))}
                  value={costCenterOptions.find((o) => o.id === entry.cost_center_id) ?? null}
                  isOptionEqualToValue={(option, value) => option.id === value.id}
                  renderInput={(params) => (
                    <TextField
                      {...params}
                      label="Cost Center"
                      required
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
                    select
                    label="Account Type"
                    sx={{ flex: 1 }}
                    value={entryCategoryId}
                    onChange={(e) => {
                      setEntryCategoryId(e.target.value);
                      setEntry((v) => ({ ...v, vendor_account_id: '' }));
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
                    options={vendorAccountOptions}
                    loading={loadingVendorAccounts}
                    onChange={(_, option) => setEntry((v) => ({ ...v, vendor_account_id: option?.id ?? '' }))}
                    value={vendorAccountOptions.find((o) => o.id === entry.vendor_account_id) ?? null}
                    isOptionEqualToValue={(option, value) => option.id === value.id}
                    renderInput={(params) => (
                      <TextField
                        {...params}
                        label="Vendor Account"
                        required
                        helperText={
                          !loadingVendorAccounts && vendorAccountOptions.length === 0
                            ? 'No vendor accounts set up yet'
                            : undefined
                        }
                        InputProps={{
                          ...params.InputProps,
                          endAdornment: (
                            <>
                              {loadingVendorAccounts ? <CircularProgress color="inherit" size={16} /> : null}
                              {params.InputProps.endAdornment}
                            </>
                          ),
                        }}
                      />
                    )}
                  />
                </Stack>

                <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2}>
                  <TextField
                    label="Invoice No"
                    required
                    sx={{ flex: 1 }}
                    value={entry.invoice_number}
                    onChange={(e) => setEntry((v) => ({ ...v, invoice_number: e.target.value }))}
                  />
                  <TextField
                    label="Invoice Date"
                    type="date"
                    required
                    sx={{ flex: 1 }}
                    InputLabelProps={{ shrink: true }}
                    value={entry.invoice_date}
                    onChange={(e) => setEntry((v) => ({ ...v, invoice_date: e.target.value }))}
                  />
                </Stack>

                <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2}>
                  <TextField
                    label="Amount (incl. VAT)"
                    type="number"
                    required
                    sx={{ flex: 1 }}
                    value={entry.amount_incl_vat}
                    onChange={(e) => setEntry((v) => ({ ...v, amount_incl_vat: e.target.value }))}
                  />
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
                  <TableCell>Cost Center</TableCell>
                  <TableCell>Vendor</TableCell>
                  <TableCell>Invoice No</TableCell>
                  <TableCell>Description</TableCell>
                  <TableCell>Invoice Date</TableCell>
                  <TableCell align="right">Amount (incl. VAT)</TableCell>
                  <TableCell>Currency</TableCell>
                  <TableCell align="right">VAT Amount</TableCell>
                  <TableCell>Recorded By</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {rows.map((row) => {
                  const cc = embedOne(row.cost_centers);
                  const vendor = embedOne(row.vendor_account);
                  const org = embedOne(row.organization);
                  return (
                    <TableRow key={row.id} hover>
                      <TableCell>{org ? `${org.company_code} — ${org.site_name}` : '—'}</TableCell>
                      <TableCell>{cc ? `${cc.project_code ?? ''} ${cc.name}`.trim() : '—'}</TableCell>
                      <TableCell>{vendor ? `${vendor.account_code} — ${vendor.name}` : '—'}</TableCell>
                      <TableCell>{row.invoice_number}</TableCell>
                      <TableCell>{row.description ?? '—'}</TableCell>
                      <TableCell>{row.invoice_date}</TableCell>
                      <TableCell align="right">{row.amount_incl_vat.toLocaleString()}</TableCell>
                      <TableCell>{row.currency}</TableCell>
                      <TableCell align="right">{row.vat_amount.toLocaleString()}</TableCell>
                      <TableCell>{embedOne(row.recorded_by_user)?.name ?? '—'}</TableCell>
                    </TableRow>
                  );
                })}
                {rows.length === 0 && (
                  <TableRow>
                    <TableCell colSpan={10} align="center" sx={{ color: 'text.secondary', py: 3 }}>
                      No supplier invoices found.
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