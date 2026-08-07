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
import { Search as SearchIcon, Clear as ClearIcon, Edit as EditIcon } from '@mui/icons-material';
import { supabase } from '../../lib/supabaseClient';
import type { CostCenter } from '@erp-platform/shared';

type Source = 'supplier' | 'receivable';

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

interface UnifiedInvoiceRow {
  id: string;
  source: Source;
  invoice_number: string;
  invoice_date: string;
  account_id: string | null;
  account_label: string; // resolved account_code — name for display
  amount_incl_vat: number;
  vat_amount: number;
  currency: string;
  description: string | null;
  status: string | null; // receivable only
  invoice_type: string | null; // supplier only, generated column
  cost_center_id: string | null;
  organization_id: string | null;
  organization_label: string; // resolved company_code — site_name for display
  prf_oif_number: string; // server-generated, e.g. UGN-UG-000728 -- not editable
}

interface SearchFilters {
  source: '' | Source;
  invoiceNo: string;
  dateFrom: string;
  dateTo: string;
  organizationId: string;
  categoryId: string;
  accountId: string;
  prfOifNo: string;
}

const emptyFilters: SearchFilters = {
  source: '',
  invoiceNo: '',
  dateFrom: '',
  dateTo: '',
  organizationId: '',
  categoryId: '',
  accountId: '',
  prfOifNo: '',
};

// NOTE: organization_id intentionally has no setter in this form -- an
// invoice's organization is locked at creation (see toEditState /
// handleSaveEdit below and the lock_supplier_invoice_organization /
// lock_receivable_invoice_organization DB triggers). It's carried in
// EditState purely so the read-only display has something to render from;
// it is never sent back in the update payload.
interface EditState {
  invoice_number: string;
  invoice_date: string;
  account_id: string;
  amount_incl_vat: string;
  vat_amount: string;
  currency: string;
  description: string;
  status: string;
  cost_center_id: string;
  organization_id: string;
}

function embedOne<T>(value: T | T[] | null | undefined): T | null {
  if (!value) return null;
  return Array.isArray(value) ? value[0] ?? null : value;
}

function toEditState(row: UnifiedInvoiceRow): EditState {
  return {
    invoice_number: row.invoice_number,
    invoice_date: row.invoice_date,
    account_id: row.account_id ?? '',
    amount_incl_vat: String(row.amount_incl_vat),
    vat_amount: String(row.vat_amount),
    currency: row.currency,
    description: row.description ?? '',
    status: row.status ?? 'open',
    cost_center_id: row.cost_center_id ?? '',
    organization_id: row.organization_id ?? '',
  };
}

export default function EditInvoice() {
  const [filters, setFilters] = useState<SearchFilters>(emptyFilters);
  const [rows, setRows] = useState<UnifiedInvoiceRow[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [costCenters, setCostCenters] = useState<CostCenter[]>([]);
  const [loadingCostCenters, setLoadingCostCenters] = useState(false);

  const [organizations, setOrganizations] = useState<OrganizationOption[]>([]);
  const [loadingOrganizations, setLoadingOrganizations] = useState(false);

  const [accountCategories, setAccountCategories] = useState<AccountCategoryOption[]>([]);

  // All active accounts (vendor + client + both), used to power the search bar's
  // Account Type -> Account List cascade regardless of which Source is selected.
  const [searchAccounts, setSearchAccounts] = useState<AccountOption[]>([]);
  const [loadingSearchAccounts, setLoadingSearchAccounts] = useState(false);

  // Accounts scoped to whichever row is being edited (vendor accounts for a
  // supplier invoice, client accounts for a receivable one).
  const [accounts, setAccounts] = useState<AccountOption[]>([]);
  const [loadingAccounts, setLoadingAccounts] = useState(false);
  const [editCategoryId, setEditCategoryId] = useState('');

  const [editingRow, setEditingRow] = useState<UnifiedInvoiceRow | null>(null);
  const [edit, setEdit] = useState<EditState | null>(null);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);

  const runSearch = useCallback(async (activeFilters: SearchFilters) => {
    setLoading(true);
    setError(null);
    try {
      const wantSupplier = activeFilters.source === '' || activeFilters.source === 'supplier';
      const wantReceivable = activeFilters.source === '' || activeFilters.source === 'receivable';

      const results: UnifiedInvoiceRow[] = [];

      if (wantSupplier) {
        let q = supabase
          .from('supplier_invoices')
          .select(
            'id, invoice_number, invoice_date, amount_incl_vat, vat_amount, currency, description, invoice_type, cost_center_id, organization_id, prf_oif_number, vendor_account_id, vendor_account:accounts!vendor_account_id(name, account_code), organization:organizations!organization_id(company_code, site_name), created_at'
          )
          .order('created_at', { ascending: false });
        if (activeFilters.invoiceNo.trim()) q = q.ilike('invoice_number', `%${activeFilters.invoiceNo.trim()}%`);
        if (activeFilters.prfOifNo.trim()) q = q.ilike('prf_oif_number', `%${activeFilters.prfOifNo.trim()}%`);
        if (activeFilters.dateFrom) q = q.gte('invoice_date', activeFilters.dateFrom);
        if (activeFilters.dateTo) q = q.lte('invoice_date', activeFilters.dateTo);
        if (activeFilters.organizationId) q = q.eq('organization_id', activeFilters.organizationId);
        if (activeFilters.accountId) q = q.eq('vendor_account_id', activeFilters.accountId);
        const { data, error: qErr } = await q;
        if (qErr) throw qErr;
        (data ?? []).forEach((r: any) => {
          const acct = embedOne(r.vendor_account);
          const org = embedOne(r.organization);
          results.push({
            id: r.id,
            source: 'supplier',
            invoice_number: r.invoice_number,
            invoice_date: r.invoice_date,
            account_id: r.vendor_account_id,
            account_label: acct ? `${acct.account_code} — ${acct.name}` : '—',
            amount_incl_vat: r.amount_incl_vat,
            vat_amount: r.vat_amount,
            currency: r.currency,
            description: r.description,
            status: null,
            invoice_type: r.invoice_type,
            cost_center_id: r.cost_center_id,
            organization_id: r.organization_id,
            organization_label: org ? `${org.company_code} — ${org.site_name}` : '—',
            prf_oif_number: r.prf_oif_number,
          });
        });
      }

      if (wantReceivable) {
        let q = supabase
          .from('receivable_invoices')
          .select(
            'id, invoice_number, invoice_date, amount_incl_vat, vat_amount, currency, description, status, cost_center_id, organization_id, prf_oif_number, client_account_id, client_account:accounts!client_account_id(name, account_code), organization:organizations!organization_id(company_code, site_name), created_at'
          )
          .order('created_at', { ascending: false });
        if (activeFilters.invoiceNo.trim()) q = q.ilike('invoice_number', `%${activeFilters.invoiceNo.trim()}%`);
        if (activeFilters.prfOifNo.trim()) q = q.ilike('prf_oif_number', `%${activeFilters.prfOifNo.trim()}%`);
        if (activeFilters.dateFrom) q = q.gte('invoice_date', activeFilters.dateFrom);
        if (activeFilters.dateTo) q = q.lte('invoice_date', activeFilters.dateTo);
        if (activeFilters.organizationId) q = q.eq('organization_id', activeFilters.organizationId);
        if (activeFilters.accountId) q = q.eq('client_account_id', activeFilters.accountId);
        const { data, error: qErr } = await q;
        if (qErr) throw qErr;
        (data ?? []).forEach((r: any) => {
          const acct = embedOne(r.client_account);
          const org = embedOne(r.organization);
          results.push({
            id: r.id,
            source: 'receivable',
            invoice_number: r.invoice_number,
            invoice_date: r.invoice_date,
            account_id: r.client_account_id,
            account_label: acct ? `${acct.account_code} — ${acct.name}` : '—',
            amount_incl_vat: r.amount_incl_vat,
            vat_amount: r.vat_amount,
            currency: r.currency,
            description: r.description,
            status: r.status,
            invoice_type: null,
            cost_center_id: r.cost_center_id,
            organization_id: r.organization_id,
            organization_label: org ? `${org.company_code} — ${org.site_name}` : '—',
            prf_oif_number: r.prf_oif_number,
          });
        });
      }

      results.sort((a, b) => (a.invoice_date < b.invoice_date ? 1 : -1));
      setRows(results);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed to load invoices');
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

  const loadSearchAccounts = useCallback(async () => {
    setLoadingSearchAccounts(true);
    try {
      const { data, error: accError } = await supabase
        .from('accounts')
        .select('id, account_code, name, category_id')
        .eq('is_active', true)
        .order('name');
      if (accError) throw accError;
      setSearchAccounts(data ?? []);
    } catch (e) {
      setSaveError(e instanceof Error ? e.message : 'Failed to load accounts');
    } finally {
      setLoadingSearchAccounts(false);
    }
  }, []);

  // Loaded fresh per edit, filtered by whichever row is being edited
  // (vendor accounts for a supplier invoice, client accounts for a
  // receivable one) -- 'both'-type accounts show up for either.
  const loadAccountsFor = useCallback(async (source: Source) => {
    setLoadingAccounts(true);
    try {
      const wantedType = source === 'supplier' ? 'vendor' : 'client';
      const { data, error: accError } = await supabase
        .from('accounts')
        .select('id, account_code, name, category_id')
        .eq('is_active', true)
        .in('account_type', [wantedType, 'both'])
        .order('name');
      if (accError) throw accError;
      setAccounts(data ?? []);
    } catch (e) {
      setSaveError(e instanceof Error ? e.message : 'Failed to load accounts');
    } finally {
      setLoadingAccounts(false);
    }
  }, []);

  useEffect(() => {
    runSearch(emptyFilters);
    loadCostCenters();
    loadOrganizations();
    loadAccountCategories();
    loadSearchAccounts();
  }, [runSearch, loadCostCenters, loadOrganizations, loadAccountCategories, loadSearchAccounts]);

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

  // Search bar's Account List: narrowed to whichever Account Type is selected.
  const searchAccountOptions = useMemo(
    () =>
      searchAccounts
        .filter((a) => !filters.categoryId || a.category_id === filters.categoryId)
        .map((a) => ({ id: a.id, label: `${a.account_code} — ${a.name}` })),
    [searchAccounts, filters.categoryId]
  );

  // Edit form's Account picker: narrowed to whichever Account Type is selected there.
  const editAccountOptions = useMemo(
    () =>
      accounts
        .filter((a) => !editCategoryId || a.category_id === editCategoryId)
        .map((a) => ({ id: a.id, label: `${a.account_code} — ${a.name}` })),
    [accounts, editCategoryId]
  );

  function handleSearchSubmit(e: FormEvent) {
    e.preventDefault();
    runSearch(filters);
  }

  function handleClear() {
    setFilters(emptyFilters);
    runSearch(emptyFilters);
  }

  function handleStartEdit(row: UnifiedInvoiceRow) {
    setSaveError(null);
    setEditCategoryId('');
    setEditingRow(row);
    setEdit(toEditState(row));
    loadAccountsFor(row.source);
  }

  async function handleSaveEdit(e: FormEvent) {
    e.preventDefault();
    if (!editingRow || !edit) return;
    setSaveError(null);

    // organization_id is deliberately excluded from this check -- it's
    // locked after creation, see the read-only field below.
    if (!edit.invoice_number.trim() || !edit.invoice_date || !edit.amount_incl_vat || !edit.account_id) {
      setSaveError('Account, invoice number, date, and amount are required.');
      return;
    }
    const parsedAmount = Number(edit.amount_incl_vat);
    if (Number.isNaN(parsedAmount) || parsedAmount <= 0) {
      setSaveError('Amount must be a valid number greater than 0.');
      return;
    }

    setSaving(true);
    if (editingRow.source === 'supplier') {
      const { error: updateError } = await supabase
        .from('supplier_invoices')
        .update({
          invoice_number: edit.invoice_number.trim(),
          invoice_date: edit.invoice_date,
          vendor_account_id: edit.account_id,
          amount_incl_vat: parsedAmount,
          vat_amount: Number(edit.vat_amount || 0),
          currency: edit.currency,
          description: edit.description.trim() || null,
          cost_center_id: edit.cost_center_id || null,
          // organization_id intentionally omitted -- locked at creation,
          // enforced server-side by lock_supplier_invoice_organization.
        })
        .eq('id', editingRow.id);
      setSaving(false);
      if (updateError) {
        setSaveError(updateError.message ?? 'Could not save changes.');
        return;
      }
    } else {
      const { error: updateError } = await supabase
        .from('receivable_invoices')
        .update({
          invoice_number: edit.invoice_number.trim(),
          invoice_date: edit.invoice_date,
          client_account_id: edit.account_id,
          amount_incl_vat: parsedAmount,
          vat_amount: Number(edit.vat_amount || 0),
          currency: edit.currency,
          description: edit.description.trim() || null,
          status: edit.status,
          cost_center_id: edit.cost_center_id || null,
          // organization_id intentionally omitted -- locked at creation,
          // enforced server-side by lock_receivable_invoice_organization.
        })
        .eq('id', editingRow.id);
      setSaving(false);
      if (updateError) {
        setSaveError(updateError.message ?? 'Could not save changes.');
        return;
      }
    }

    setEditingRow(null);
    setEdit(null);
    runSearch(filters);
  }

  return (
    <Box>
      <Typography variant="h5" sx={{ mb: 2 }}>
        Edit Invoice
      </Typography>

      {/* Search */}
      <Paper sx={{ p: 3, mb: 3 }} variant="outlined">
        <Typography variant="subtitle1" sx={{ fontWeight: 600, mb: 2 }}>
          Search
        </Typography>
        <Box component="form" onSubmit={handleSearchSubmit}>
          <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2} flexWrap="wrap" sx={{ mb: 2 }}>
            <Autocomplete
              options={organizationOptions}
              loading={loadingOrganizations}
              sx={{ flex: 1, minWidth: 220 }}
              onChange={(_, option) => setFilters((f) => ({ ...f, organizationId: option?.id ?? '' }))}
              value={organizationOptions.find((o) => o.id === filters.organizationId) ?? null}
              isOptionEqualToValue={(option, value) => option.id === value.id}
              renderInput={(params) => (
                <TextField
                  {...params}
                  label="Organization"
                  size="small"
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
            <TextField
              select
              label="Account Type"
              size="small"
              sx={{ flex: 1, minWidth: 160 }}
              value={filters.categoryId}
              onChange={(e) =>
                setFilters((f) => ({ ...f, categoryId: e.target.value, accountId: '' }))
              }
            >
              <MenuItem value="">All</MenuItem>
              {accountCategoryOptions.map((c) => (
                <MenuItem key={c.id} value={c.id}>
                  {c.label}
                </MenuItem>
              ))}
            </TextField>
            <Autocomplete
              options={searchAccountOptions}
              loading={loadingSearchAccounts}
              sx={{ flex: 1, minWidth: 220 }}
              onChange={(_, option) => setFilters((f) => ({ ...f, accountId: option?.id ?? '' }))}
              value={searchAccountOptions.find((o) => o.id === filters.accountId) ?? null}
              isOptionEqualToValue={(option, value) => option.id === value.id}
              renderInput={(params) => (
                <TextField
                  {...params}
                  label="Account List"
                  size="small"
                  InputProps={{
                    ...params.InputProps,
                    endAdornment: (
                      <>
                        {loadingSearchAccounts ? <CircularProgress color="inherit" size={16} /> : null}
                        {params.InputProps.endAdornment}
                      </>
                    ),
                  }}
                />
              )}
            />
          </Stack>
          <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2} flexWrap="wrap">
            <TextField
              select
              label="Source"
              size="small"
              sx={{ flex: 1, minWidth: 160 }}
              value={filters.source}
              onChange={(e) => setFilters((f) => ({ ...f, source: e.target.value as SearchFilters['source'] }))}
            >
              <MenuItem value="">Both</MenuItem>
              <MenuItem value="supplier">Supplier Invoice</MenuItem>
              <MenuItem value="receivable">Receivable Invoice</MenuItem>
            </TextField>
            <TextField
              label="PRF / OIF No"
              size="small"
              sx={{ flex: 1, minWidth: 160 }}
              value={filters.prfOifNo}
              onChange={(e) => setFilters((f) => ({ ...f, prfOifNo: e.target.value }))}
            />
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

      {/* Edit form */}
      {editingRow && edit && (
        <Card sx={{ mb: 3 }} variant="outlined">
          <CardContent>
            <Typography variant="h6" gutterBottom>
              Edit {editingRow.source === 'supplier' ? 'Supplier' : 'Receivable'} Invoice — {editingRow.invoice_number}
            </Typography>
            <Box component="form" onSubmit={handleSaveEdit} noValidate>
              <Stack spacing={2.5}>
                <TextField
                  label="PRF / OIF No"
                  fullWidth
                  value={editingRow.prf_oif_number}
                  disabled
                  helperText="Assigned automatically when the invoice was created — not editable"
                />

                {/* Organization is locked after creation -- moving an invoice
                    to a different org would orphan its already-issued
                    PRF/OIF number (its prefix is tied to the original org's
                    company_code). To reassign, void this invoice and
                    re-enter it under the correct organization. Enforced
                    server-side too, by the lock_*_invoice_organization
                    triggers, so this is not just a UI restriction. */}
                <TextField
                  label="Organization"
                  fullWidth
                  value={editingRow.organization_label}
                  disabled
                  helperText="An invoice cannot be moved to a different organization — void and re-enter it under the correct organization instead"
                />

                <TextField
                  label="Invoice No"
                  required
                  fullWidth
                  value={edit.invoice_number}
                  onChange={(e) => setEdit((v) => v && { ...v, invoice_number: e.target.value })}
                />

                <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2}>
                  <TextField
                    select
                    label="Account Type"
                    sx={{ flex: 1 }}
                    value={editCategoryId}
                    onChange={(e) => {
                      setEditCategoryId(e.target.value);
                      setEdit((v) => v && { ...v, account_id: '' });
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
                    options={editAccountOptions}
                    loading={loadingAccounts}
                    onChange={(_, option) => setEdit((v) => v && { ...v, account_id: option?.id ?? '' })}
                    value={editAccountOptions.find((o) => o.id === edit.account_id) ?? null}
                    isOptionEqualToValue={(option, value) => option.id === value.id}
                    renderInput={(params) => (
                      <TextField
                        {...params}
                        label={editingRow.source === 'supplier' ? 'Vendor Account' : 'Client Account'}
                        required
                        InputProps={{
                          ...params.InputProps,
                          endAdornment: (
                            <>
                              {loadingAccounts ? <CircularProgress color="inherit" size={16} /> : null}
                              {params.InputProps.endAdornment}
                            </>
                          ),
                        }}
                      />
                    )}
                  />
                </Stack>

                <Autocomplete
                  options={costCenterOptions}
                  loading={loadingCostCenters}
                  onChange={(_, option) => setEdit((v) => v && { ...v, cost_center_id: option?.id ?? '' })}
                  value={costCenterOptions.find((o) => o.id === edit.cost_center_id) ?? null}
                  isOptionEqualToValue={(option, value) => option.id === value.id}
                  renderInput={(params) => (
                    <TextField
                      {...params}
                      label="Cost Center"
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
                    value={edit.invoice_date}
                    onChange={(e) => setEdit((v) => v && { ...v, invoice_date: e.target.value })}
                  />
                  <TextField
                    label="Amount (incl. VAT)"
                    type="number"
                    required
                    sx={{ flex: 1 }}
                    value={edit.amount_incl_vat}
                    onChange={(e) => setEdit((v) => v && { ...v, amount_incl_vat: e.target.value })}
                  />
                </Stack>

                <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2}>
                  <TextField
                    label="VAT Amount"
                    type="number"
                    sx={{ flex: 1 }}
                    value={edit.vat_amount}
                    onChange={(e) => setEdit((v) => v && { ...v, vat_amount: e.target.value })}
                  />
                  <TextField
                    select
                    label="Currency"
                    sx={{ flex: 1 }}
                    value={edit.currency}
                    onChange={(e) => setEdit((v) => v && { ...v, currency: e.target.value })}
                  >
                    <MenuItem value="UGX">UGX</MenuItem>
                    <MenuItem value="USD">USD</MenuItem>
                    <MenuItem value="EUR">EUR</MenuItem>
                  </TextField>
                  {editingRow.source === 'receivable' && (
                    <TextField
                      select
                      label="Status"
                      sx={{ flex: 1 }}
                      value={edit.status}
                      onChange={(e) => setEdit((v) => v && { ...v, status: e.target.value })}
                    >
                      <MenuItem value="open">Open</MenuItem>
                      <MenuItem value="paid">Paid</MenuItem>
                    </TextField>
                  )}
                </Stack>

                <TextField
                  label="Description"
                  fullWidth
                  value={edit.description}
                  onChange={(e) => setEdit((v) => v && { ...v, description: e.target.value })}
                />

                {saveError && <Alert severity="error">{saveError}</Alert>}

                <Stack direction="row" spacing={1}>
                  <Button type="submit" variant="contained" disabled={saving}>
                    {saving ? 'Saving…' : 'Save'}
                  </Button>
                  <Button
                    variant="outlined"
                    onClick={() => {
                      setEditingRow(null);
                      setEdit(null);
                    }}
                    disabled={saving}
                  >
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
                  <TableCell>Source</TableCell>
                  <TableCell>Organization</TableCell>
                  <TableCell>PRF / OIF No</TableCell>
                  <TableCell>Invoice No</TableCell>
                  <TableCell>Account</TableCell>
                  <TableCell>Date</TableCell>
                  <TableCell align="right">Amount (incl. VAT)</TableCell>
                  <TableCell>Currency</TableCell>
                  <TableCell>Status / Type</TableCell>
                  <TableCell align="right">Actions</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {rows.map((row) => (
                  <TableRow key={`${row.source}-${row.id}`} hover>
                    <TableCell>
                      <Chip
                        size="small"
                        label={row.source === 'supplier' ? 'Supplier' : 'Receivable'}
                        color={row.source === 'supplier' ? 'default' : 'info'}
                      />
                    </TableCell>
                    <TableCell>{row.organization_label}</TableCell>
                    <TableCell>{row.prf_oif_number}</TableCell>
                    <TableCell>{row.invoice_number}</TableCell>
                    <TableCell>{row.account_label}</TableCell>
                    <TableCell>{row.invoice_date}</TableCell>
                    <TableCell align="right">{row.amount_incl_vat.toLocaleString()}</TableCell>
                    <TableCell>{row.currency}</TableCell>
                    <TableCell>
                      {row.source === 'receivable' ? (
                        <Chip size="small" label={row.status} color={row.status === 'paid' ? 'success' : 'default'} />
                      ) : (
                        <Chip size="small" label={row.invoice_type === 'po_related' ? 'PO Related' : 'Non-PO'} />
                      )}
                    </TableCell>
                    <TableCell align="right">
                      <Button size="small" startIcon={<EditIcon />} onClick={() => handleStartEdit(row)}>
                        Edit
                      </Button>
                    </TableCell>
                  </TableRow>
                ))}
                {rows.length === 0 && (
                  <TableRow>
                    <TableCell colSpan={10} align="center" sx={{ color: 'text.secondary', py: 3 }}>
                      No invoices found.
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