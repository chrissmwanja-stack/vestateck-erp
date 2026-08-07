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

interface PurchaseOrderOption {
  id: string;
  po_number: string;
  vendor_name: string; // display-only reference from the PO itself, not linked to accounts
  amount: number;
}

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
  due_date: string | null;
  amount_incl_vat: number;
  vat_amount: number;
  currency: string;
  description: string | null;
  created_at: string;
  purchase_orders: { po_number: string } | { po_number: string }[] | null;
  vendor_account: { name: string; account_code: string } | { name: string; account_code: string }[] | null;
  organization: { company_code: string; site_name: string } | { company_code: string; site_name: string }[] | null;
  recorded_by_user: { name: string } | { name: string }[] | null;
}

interface SearchFilters {
  invoiceNo: string;
  poNumber: string;
  dateFrom: string;
  dateTo: string;
}

const emptyFilters: SearchFilters = { invoiceNo: '', poNumber: '', dateFrom: '', dateTo: '' };

interface EntryState {
  purchase_order_id: string;
  vendor_account_id: string;
  organization_id: string;
  invoice_number: string;
  invoice_date: string;
  due_date: string;
  amount_incl_vat: string;
  vat_amount: string;
  currency: string;
  description: string;
}

const emptyEntry: EntryState = {
  purchase_order_id: '',
  vendor_account_id: '',
  organization_id: '',
  invoice_number: '',
  invoice_date: '',
  due_date: '',
  amount_incl_vat: '',
  vat_amount: '0',
  currency: 'UGX',
  description: '',
};

function embedOne<T>(value: T | T[] | null | undefined): T | null {
  if (!value) return null;
  return Array.isArray(value) ? value[0] ?? null : value;
}

export default function SupplierInvoices() {
  const [filters, setFilters] = useState<SearchFilters>(emptyFilters);
  const [rows, setRows] = useState<SupplierInvoiceRow[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [openPOs, setOpenPOs] = useState<PurchaseOrderOption[]>([]);
  const [loadingPOs, setLoadingPOs] = useState(false);
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
          'id, invoice_number, invoice_date, due_date, amount_incl_vat, vat_amount, currency, description, created_at, purchase_orders(po_number), vendor_account:accounts!vendor_account_id(name, account_code), organization:organizations!organization_id(company_code, site_name), recorded_by_user:app_users!recorded_by(name)'
        )
        .eq('invoice_type', 'po_related')
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

      let result = (data ?? []) as unknown as SupplierInvoiceRow[];

      if (activeFilters.poNumber.trim()) {
        const needle = activeFilters.poNumber.trim().toLowerCase();
        result = result.filter((r) => embedOne(r.purchase_orders)?.po_number?.toLowerCase().includes(needle));
      }

      setRows(result);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed to load supplier invoices');
    } finally {
      setLoading(false);
    }
  }, []);

  const loadOpenPOs = useCallback(async () => {
    setLoadingPOs(true);
    try {
      const { data: invoiced, error: invoicedError } = await supabase
        .from('supplier_invoices')
        .select('purchase_order_id');
      if (invoicedError) throw invoicedError;
      const invoicedIds = new Set((invoiced ?? []).map((r) => r.purchase_order_id));

      const { data: pos, error: poError } = await supabase
        .from('purchase_orders')
        .select('id, po_number, vendor_name, amount')
        .order('generated_at', { ascending: false });
      if (poError) throw poError;

      setOpenPOs((pos ?? []).filter((po) => !invoicedIds.has(po.id)));
    } catch (e) {
      setSaveError(e instanceof Error ? e.message : 'Failed to load open purchase orders');
    } finally {
      setLoadingPOs(false);
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

  const poOptions = useMemo(
    () => openPOs.map((po) => ({ id: po.id, label: `${po.po_number} — ${po.vendor_name}` })),
    [openPOs]
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
    loadOpenPOs();
    loadVendorAccounts();
    loadOrganizations();
    loadAccountCategories();
    setShowEntryForm(true);
  }

  async function handleSaveEntry(e: FormEvent) {
    e.preventDefault();
    setSaveError(null);

    if (!entry.purchase_order_id || !entry.vendor_account_id || !entry.invoice_number || !entry.invoice_date || !entry.amount_incl_vat) {
      setSaveError('PO, vendor account, invoice number, invoice date, and amount are required.');
      return;
    }

    const parsedAmount = Number(entry.amount_incl_vat);
    if (Number.isNaN(parsedAmount) || parsedAmount <= 0) {
      setSaveError('Amount must be a valid number greater than 0.');
      return;
    }

    setSaving(true);
    const { error: insertError } = await supabase.from('supplier_invoices').insert({
      purchase_order_id: entry.purchase_order_id,
      vendor_account_id: entry.vendor_account_id,
      organization_id: entry.organization_id || null,
      invoice_number: entry.invoice_number.trim(),
      invoice_date: entry.invoice_date,
      due_date: entry.due_date || null,
      amount_incl_vat: parsedAmount,
      vat_amount: Number(entry.vat_amount || 0),
      currency: entry.currency,
      description: entry.description.trim() || null,
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
        <Typography variant="h5">Supplier Invoice (PO Related)</Typography>
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
              label="PO No"
              size="small"
              sx={{ flex: 1, minWidth: 160 }}
              value={filters.poNumber}
              onChange={(e) => setFilters((f) => ({ ...f, poNumber: e.target.value }))}
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
                  options={poOptions}
                  loading={loadingPOs}
                  onChange={(_, option) => setEntry((v) => ({ ...v, purchase_order_id: option?.id ?? '' }))}
                  value={poOptions.find((o) => o.id === entry.purchase_order_id) ?? null}
                  isOptionEqualToValue={(option, value) => option.id === value.id}
                  renderInput={(params) => (
                    <TextField
                      {...params}
                      label="Purchase Order"
                      required
                      helperText={!loadingPOs && poOptions.length === 0 ? 'No open POs available' : undefined}
                      InputProps={{
                        ...params.InputProps,
                        endAdornment: (
                          <>
                            {loadingPOs ? <CircularProgress color="inherit" size={16} /> : null}
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
                  <TextField
                    label="Due Date"
                    type="date"
                    sx={{ flex: 1 }}
                    InputLabelProps={{ shrink: true }}
                    helperText="Optional — powers the Payment Plan Report"
                    value={entry.due_date}
                    onChange={(e) => setEntry((v) => ({ ...v, due_date: e.target.value }))}
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
                  <TableCell>PO No</TableCell>
                  <TableCell>Vendor</TableCell>
                  <TableCell>Invoice No</TableCell>
                  <TableCell>Description</TableCell>
                  <TableCell>Invoice Date</TableCell>
                  <TableCell>Due Date</TableCell>
                  <TableCell align="right">Amount (incl. VAT)</TableCell>
                  <TableCell>Currency</TableCell>
                  <TableCell align="right">VAT Amount</TableCell>
                  <TableCell>Recorded By</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {rows.map((row) => {
                  const vendor = embedOne(row.vendor_account);
                  const org = embedOne(row.organization);
                  return (
                    <TableRow key={row.id} hover>
                      <TableCell>{org ? `${org.company_code} — ${org.site_name}` : '—'}</TableCell>
                      <TableCell>{embedOne(row.purchase_orders)?.po_number ?? '—'}</TableCell>
                      <TableCell>{vendor ? `${vendor.account_code} — ${vendor.name}` : '—'}</TableCell>
                      <TableCell>{row.invoice_number}</TableCell>
                      <TableCell>{row.description ?? '—'}</TableCell>
                      <TableCell>{row.invoice_date}</TableCell>
                      <TableCell>{row.due_date ?? '—'}</TableCell>
                      <TableCell align="right">{row.amount_incl_vat.toLocaleString()}</TableCell>
                      <TableCell>{row.currency}</TableCell>
                      <TableCell align="right">{row.vat_amount.toLocaleString()}</TableCell>
                      <TableCell>{embedOne(row.recorded_by_user)?.name ?? '—'}</TableCell>
                    </TableRow>
                  );
                })}
                {rows.length === 0 && (
                  <TableRow>
                    <TableCell colSpan={11} align="center" sx={{ color: 'text.secondary', py: 3 }}>
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