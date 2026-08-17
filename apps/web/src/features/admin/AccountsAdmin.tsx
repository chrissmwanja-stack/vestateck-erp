import { useCallback, useEffect, useMemo, useState, FormEvent } from 'react';
import {
  Alert,
  Box,
  Button,
  Card,
  CardContent,
  Chip,
  CircularProgress,
  MenuItem,
  Paper,
  Stack,
  Switch,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  TextField,
  Typography,
  FormControlLabel,
  Divider,
} from '@mui/material';
import { Search as SearchIcon, Clear as ClearIcon, Add as AddIcon, Edit as EditIcon, UploadFile as UploadFileIcon } from '@mui/icons-material';
import { supabase } from '../../lib/supabaseClient';
import { useAuth } from '../../lib/authContext';
import BulkImportDialog, { BulkImportConfig } from '../../components/bulk-import/BulkImportDialog';

type AccountType = 'vendor' | 'client' | 'both';

interface AccountCategoryOption {
  id: string;
  code: string;
  name: string;
}

interface AccountRow {
  id: string;
  account_code: string;
  name: string;
  account_type: AccountType;
  category_id: string | null;
  category: { name: string } | { name: string }[] | null;
  contact_name: string | null;
  contact_phone: string | null;
  contact_email: string | null;
  is_active: boolean;
  created_at: string;
  tax_id: string | null;
  business_registration_number: string | null;
  license_number: string | null;
  license_expiry: string | null;
  address: string | null;
  bank_name: string | null;
  bank_account_name: string | null;
  bank_account_number: string | null;
  bank_branch: string | null;
  swift_code: string | null;
}

interface SearchFilters {
  query: string;
  accountType: '' | AccountType;
  categoryId: string;
}

const emptyFilters: SearchFilters = { query: '', accountType: '', categoryId: '' };

interface FormState {
  account_code: string;
  name: string;
  account_type: AccountType;
  category_id: string;
  contact_name: string;
  contact_phone: string;
  contact_email: string;
  is_active: boolean;
  tax_id: string;
  business_registration_number: string;
  license_number: string;
  license_expiry: string;
  address: string;
  bank_name: string;
  bank_account_name: string;
  bank_account_number: string;
  bank_branch: string;
  swift_code: string;
}

const emptyForm: FormState = {
  account_code: '',
  name: '',
  account_type: 'vendor',
  category_id: '',
  contact_name: '',
  contact_phone: '',
  contact_email: '',
  is_active: true,
  tax_id: '',
  business_registration_number: '',
  license_number: '',
  license_expiry: '',
  address: '',
  bank_name: '',
  bank_account_name: '',
  bank_account_number: '',
  bank_branch: '',
  swift_code: '',
};

function embedOne<T>(value: T | T[] | null | undefined): T | null {
  if (!value) return null;
  return Array.isArray(value) ? value[0] ?? null : value;
}

function toFormState(row: AccountRow): FormState {
  return {
    account_code: row.account_code,
    name: row.name,
    account_type: row.account_type,
    category_id: row.category_id ?? '',
    contact_name: row.contact_name ?? '',
    contact_phone: row.contact_phone ?? '',
    contact_email: row.contact_email ?? '',
    is_active: row.is_active,
    tax_id: row.tax_id ?? '',
    business_registration_number: row.business_registration_number ?? '',
    license_number: row.license_number ?? '',
    license_expiry: row.license_expiry ?? '',
    address: row.address ?? '',
    bank_name: row.bank_name ?? '',
    bank_account_name: row.bank_account_name ?? '',
    bank_account_number: row.bank_account_number ?? '',
    bank_branch: row.bank_branch ?? '',
    swift_code: row.swift_code ?? '',
  };
}

export default function AccountsAdmin() {
  const { session } = useAuth();
  const [bulkOpen, setBulkOpen] = useState(false);
  const [filters, setFilters] = useState<SearchFilters>(emptyFilters);
  const [rows, setRows] = useState<AccountRow[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [categories, setCategories] = useState<AccountCategoryOption[]>([]);
  const [loadingCategories, setLoadingCategories] = useState(false);

  const [showForm, setShowForm] = useState(false);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [form, setForm] = useState<FormState>(emptyForm);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);

  const runSearch = useCallback(async (activeFilters: SearchFilters) => {
    setLoading(true);
    setError(null);
    try {
      let query = supabase
        .from('accounts')
        .select(
          'id, account_code, name, account_type, category_id, category:account_categories!category_id(name), contact_name, contact_phone, contact_email, is_active, created_at, tax_id, business_registration_number, license_number, license_expiry, address, bank_name, bank_account_name, bank_account_number, bank_branch, swift_code'
        )
        .order('account_code');

      if (activeFilters.query.trim()) {
        const needle = activeFilters.query.trim();
        query = query.or(`account_code.ilike.%${needle}%,name.ilike.%${needle}%`);
      }
      if (activeFilters.accountType) {
        query = query.eq('account_type', activeFilters.accountType);
      }
      if (activeFilters.categoryId) {
        query = query.eq('category_id', activeFilters.categoryId);
      }

      const { data, error: queryError } = await query;
      if (queryError) throw queryError;
      setRows((data ?? []) as unknown as AccountRow[]);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed to load accounts');
    } finally {
      setLoading(false);
    }
  }, []);

  const loadCategories = useCallback(async () => {
    setLoadingCategories(true);
    try {
      const { data, error: catError } = await supabase
        .from('account_categories')
        .select('id, code, name')
        .eq('is_active', true)
        .order('name');
      if (catError) throw catError;
      setCategories(data ?? []);
    } catch (e) {
      setSaveError(e instanceof Error ? e.message : 'Failed to load account categories');
    } finally {
      setLoadingCategories(false);
    }
  }, []);

  useEffect(() => {
    runSearch(emptyFilters);
    loadCategories();
  }, [runSearch, loadCategories]);

  const categoryOptions = useMemo(() => categories.map((c) => ({ id: c.id, label: c.name })), [categories]);

  function handleSearchSubmit(e: FormEvent) {
    e.preventDefault();
    runSearch(filters);
  }

  function handleClear() {
    setFilters(emptyFilters);
    runSearch(emptyFilters);
  }

  function handleOpenNew() {
    setSaveError(null);
    setEditingId(null);
    setForm(emptyForm);
    setShowForm(true);
  }

  function handleOpenEdit(row: AccountRow) {
    setSaveError(null);
    setEditingId(row.id);
    setForm(toFormState(row));
    setShowForm(true);
  }

  async function handleSave(e: FormEvent) {
    e.preventDefault();
    setSaveError(null);

    if (!form.account_code.trim() || !form.name.trim()) {
      setSaveError('Account code and name are required.');
      return;
    }

    setSaving(true);

    // account_code is manual/required/unique-per-tenant with no default or
    // trigger (unlike hr_employees.employee_no or machines.machine_no), so
    // tenant_id must be resolved and set explicitly on create -- accounts.
    // tenant_id is NOT NULL with no default, so a create without it fails
    // the constraint outright.
    let tenant_id: string | undefined;
    if (!editingId) {
      const userId = session?.user?.id;
      if (!userId) {
        setSaveError('Could not determine your session. Please refresh and try again.');
        setSaving(false);
        return;
      }
      const { data: appUser, error: appUserErr } = await supabase
        .from('app_users')
        .select('tenant_id')
        .eq('id', userId)
        .single();
      if (appUserErr || !appUser?.tenant_id) {
        setSaveError('Could not determine your organization. Please refresh and try again.');
        setSaving(false);
        return;
      }
      tenant_id = appUser.tenant_id;
    }

    const payload: Record<string, any> = {
      account_code: form.account_code.trim(),
      name: form.name.trim(),
      account_type: form.account_type,
      category_id: form.category_id || null,
      contact_name: form.contact_name.trim() || null,
      contact_phone: form.contact_phone.trim() || null,
      contact_email: form.contact_email.trim() || null,
      is_active: form.is_active,
      tax_id: form.tax_id.trim() || null,
      business_registration_number: form.business_registration_number.trim() || null,
      license_number: form.license_number.trim() || null,
      license_expiry: form.license_expiry || null,
      address: form.address.trim() || null,
      bank_name: form.bank_name.trim() || null,
      bank_account_name: form.bank_account_name.trim() || null,
      bank_account_number: form.bank_account_number.trim() || null,
      bank_branch: form.bank_branch.trim() || null,
      swift_code: form.swift_code.trim() || null,
    };
    if (!editingId && tenant_id) payload.tenant_id = tenant_id;

    const { error: saveErr } = editingId
      ? await supabase.from('accounts').update(payload as any).eq('id', editingId)
      : await supabase.from('accounts').insert(payload as any);
    setSaving(false);

    if (saveErr) {
      // account_code is unique per tenant -- surface the constraint violation plainly
      setSaveError(
        saveErr.message.includes('duplicate key')
          ? `Account code "${form.account_code}" is already in use.`
          : saveErr.message ?? 'Could not save the account. Try again.'
      );
      return;
    }

    setShowForm(false);
    setEditingId(null);
    setForm(emptyForm);
    runSearch(filters);
  }

  const showBankingFields = form.account_type === 'vendor' || form.account_type === 'both';

  // account_code is manual/required/unique-per-tenant -- unlike hr_employees
  // and machines, there is no generator trigger, so the CSV must supply it.
  const bulkImportConfig: BulkImportConfig = {
    table: 'accounts',
    entityLabel: 'Accounts',
    dedupeColumn: 'account_code',
    columns: [
      { key: 'account_code', label: 'Account Code', required: true },
      { key: 'name', label: 'Name', required: true },
      { key: 'account_type', label: 'Type', required: true, enumValues: ['vendor', 'client', 'both'] },
      { key: 'contact_name', label: 'Contact Name' },
      { key: 'contact_phone', label: 'Contact Phone' },
      { key: 'contact_email', label: 'Contact Email' },
    ],
    lookups: [
      { csvColumn: 'category', table: 'account_categories', matchColumn: 'code', payloadKey: 'category_id', label: 'Category' },
    ],
    sampleRowValues: ['VEN-0001', 'Acme Supplies Ltd', 'vendor', 'John Doe', '+256700000000', 'john@acme.com', 'GEN'],
    buildPayload: (row, resolved, tenant_id) => ({
      tenant_id,
      account_code: row.account_code,
      name: row.name,
      account_type: row.account_type.toLowerCase(),
      category_id: resolved.category_id || null,
      contact_name: row.contact_name || null,
      contact_phone: row.contact_phone || null,
      contact_email: row.contact_email || null,
      is_active: true,
    }),
  };

  return (
    <Box>
      <Stack direction="row" justifyContent="space-between" alignItems="center" sx={{ mb: 2 }}>
        <Typography variant="h5">Accounts</Typography>
        <Stack direction="row" spacing={1}>
          <Button variant="outlined" startIcon={<UploadFileIcon />} onClick={() => setBulkOpen(true)}>
            Bulk Import
          </Button>
          <Button variant="contained" startIcon={<AddIcon />} onClick={handleOpenNew}>
            New Account
          </Button>
        </Stack>
      </Stack>

      {/* Search */}
      <Paper sx={{ p: 3, mb: 3 }} variant="outlined">
        <Typography variant="subtitle1" sx={{ fontWeight: 600, mb: 2 }}>
          Search
        </Typography>
        <Box component="form" onSubmit={handleSearchSubmit}>
          <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2} flexWrap="wrap">
            <TextField
              label="Code or Name"
              size="small"
              sx={{ flex: 1, minWidth: 200 }}
              value={filters.query}
              onChange={(e) => setFilters((f) => ({ ...f, query: e.target.value }))}
            />
            <TextField
              select
              label="Role (Vendor/Client)"
              size="small"
              sx={{ flex: 1, minWidth: 160 }}
              value={filters.accountType}
              onChange={(e) => setFilters((f) => ({ ...f, accountType: e.target.value as SearchFilters['accountType'] }))}
            >
              <MenuItem value="">Any</MenuItem>
              <MenuItem value="vendor">Vendor</MenuItem>
              <MenuItem value="client">Client</MenuItem>
              <MenuItem value="both">Both</MenuItem>
            </TextField>
            <TextField
              select
              label="Category"
              size="small"
              sx={{ flex: 1, minWidth: 160 }}
              value={filters.categoryId}
              onChange={(e) => setFilters((f) => ({ ...f, categoryId: e.target.value }))}
            >
              <MenuItem value="">Any</MenuItem>
              {categoryOptions.map((c) => (
                <MenuItem key={c.id} value={c.id}>
                  {c.label}
                </MenuItem>
              ))}
            </TextField>
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

      {/* Entry / edit form */}
      {showForm && (
        <Card sx={{ mb: 3 }} variant="outlined">
          <CardContent>
            <Typography variant="h6" gutterBottom>
              {editingId ? 'Edit Account' : 'New Account'}
            </Typography>
            <Box component="form" onSubmit={handleSave} noValidate>
              <Stack spacing={2.5}>
                <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2}>
                  <TextField
                    label="Account Code"
                    required
                    sx={{ flex: 1 }}
                    value={form.account_code}
                    onChange={(e) => setForm((v) => ({ ...v, account_code: e.target.value }))}
                  />
                  <TextField
                    label="Name"
                    required
                    sx={{ flex: 2 }}
                    value={form.name}
                    onChange={(e) => setForm((v) => ({ ...v, name: e.target.value }))}
                  />
                </Stack>

                <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2}>
                  <TextField
                    select
                    label="Role (Vendor/Client)"
                    required
                    sx={{ flex: 1 }}
                    value={form.account_type}
                    onChange={(e) => setForm((v) => ({ ...v, account_type: e.target.value as AccountType }))}
                  >
                    <MenuItem value="vendor">Vendor</MenuItem>
                    <MenuItem value="client">Client</MenuItem>
                    <MenuItem value="both">Both</MenuItem>
                  </TextField>
                  <TextField
                    select
                    label="Category"
                    sx={{ flex: 1 }}
                    value={form.category_id}
                    onChange={(e) => setForm((v) => ({ ...v, category_id: e.target.value }))}
                    helperText={
                      !loadingCategories && categoryOptions.length === 0 ? 'No account categories set up yet' : undefined
                    }
                    InputProps={{
                      endAdornment: loadingCategories ? <CircularProgress color="inherit" size={16} /> : undefined,
                    }}
                  >
                    <MenuItem value="">Uncategorized</MenuItem>
                    {categoryOptions.map((c) => (
                      <MenuItem key={c.id} value={c.id}>
                        {c.label}
                      </MenuItem>
                    ))}
                  </TextField>
                </Stack>

                <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2}>
                  <TextField
                    label="Contact Name"
                    sx={{ flex: 1 }}
                    value={form.contact_name}
                    onChange={(e) => setForm((v) => ({ ...v, contact_name: e.target.value }))}
                  />
                  <TextField
                    label="Contact Phone"
                    sx={{ flex: 1 }}
                    value={form.contact_phone}
                    onChange={(e) => setForm((v) => ({ ...v, contact_phone: e.target.value }))}
                  />
                  <TextField
                    label="Contact Email"
                    type="email"
                    sx={{ flex: 1 }}
                    value={form.contact_email}
                    onChange={(e) => setForm((v) => ({ ...v, contact_email: e.target.value }))}
                  />
                </Stack>

                <TextField
                  label="Address"
                  fullWidth
                  multiline
                  minRows={2}
                  value={form.address}
                  onChange={(e) => setForm((v) => ({ ...v, address: e.target.value }))}
                />

                <FormControlLabel
                  control={
                    <Switch
                      checked={form.is_active}
                      onChange={(e) => setForm((v) => ({ ...v, is_active: e.target.checked }))}
                    />
                  }
                  label="Active (inactive accounts are hidden from invoice entry pickers)"
                />

                <Divider />

                <Typography variant="subtitle2" color="text.secondary">
                  Tax & compliance
                </Typography>

                <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2}>
                  <TextField
                    label="TIN / Tax ID"
                    sx={{ flex: 1 }}
                    value={form.tax_id}
                    onChange={(e) => setForm((v) => ({ ...v, tax_id: e.target.value }))}
                  />
                  <TextField
                    label="Business Registration No."
                    sx={{ flex: 1 }}
                    value={form.business_registration_number}
                    onChange={(e) => setForm((v) => ({ ...v, business_registration_number: e.target.value }))}
                  />
                </Stack>
                <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2}>
                  <TextField
                    label="License Number"
                    sx={{ flex: 1 }}
                    value={form.license_number}
                    onChange={(e) => setForm((v) => ({ ...v, license_number: e.target.value }))}
                  />
                  <TextField
                    label="License Expiry"
                    type="date"
                    sx={{ flex: 1 }}
                    InputLabelProps={{ shrink: true }}
                    value={form.license_expiry}
                    onChange={(e) => setForm((v) => ({ ...v, license_expiry: e.target.value }))}
                  />
                </Stack>

                {showBankingFields && (
                  <>
                    <Divider />
                    <Typography variant="subtitle2" color="text.secondary">
                      Banking details (for payments)
                    </Typography>
                    <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2}>
                      <TextField
                        label="Bank Name"
                        sx={{ flex: 1 }}
                        value={form.bank_name}
                        onChange={(e) => setForm((v) => ({ ...v, bank_name: e.target.value }))}
                      />
                      <TextField
                        label="Bank Branch"
                        sx={{ flex: 1 }}
                        value={form.bank_branch}
                        onChange={(e) => setForm((v) => ({ ...v, bank_branch: e.target.value }))}
                      />
                    </Stack>
                    <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2}>
                      <TextField
                        label="Account Name"
                        sx={{ flex: 1 }}
                        value={form.bank_account_name}
                        onChange={(e) => setForm((v) => ({ ...v, bank_account_name: e.target.value }))}
                      />
                      <TextField
                        label="Account Number"
                        sx={{ flex: 1 }}
                        value={form.bank_account_number}
                        onChange={(e) => setForm((v) => ({ ...v, bank_account_number: e.target.value }))}
                      />
                      <TextField
                        label="SWIFT / Routing Code"
                        sx={{ flex: 1 }}
                        value={form.swift_code}
                        onChange={(e) => setForm((v) => ({ ...v, swift_code: e.target.value }))}
                      />
                    </Stack>
                  </>
                )}

                {saveError && <Alert severity="error">{saveError}</Alert>}

                <Stack direction="row" spacing={1}>
                  <Button type="submit" variant="contained" disabled={saving}>
                    {saving ? 'Saving…' : 'Save'}
                  </Button>
                  <Button variant="outlined" onClick={() => setShowForm(false)} disabled={saving}>
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
                  <TableCell>Code</TableCell>
                  <TableCell>Name</TableCell>
                  <TableCell>Role</TableCell>
                  <TableCell>Category</TableCell>
                  <TableCell>Contact</TableCell>
                  <TableCell>Tax ID</TableCell>
                  <TableCell>Status</TableCell>
                  <TableCell align="right">Actions</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {rows.map((row) => {
                  const category = embedOne(row.category);
                  return (
                    <TableRow key={row.id} hover>
                      <TableCell>{row.account_code}</TableCell>
                      <TableCell>{row.name}</TableCell>
                      <TableCell>
                        <Chip size="small" label={row.account_type} />
                      </TableCell>
                      <TableCell>{category ? category.name : '—'}</TableCell>
                      <TableCell>{row.contact_name ?? row.contact_email ?? row.contact_phone ?? '—'}</TableCell>
                      <TableCell>{row.tax_id ?? '—'}</TableCell>
                      <TableCell>
                        <Chip size="small" label={row.is_active ? 'Active' : 'Inactive'} color={row.is_active ? 'success' : 'default'} />
                      </TableCell>
                      <TableCell align="right">
                        <Button size="small" startIcon={<EditIcon />} onClick={() => handleOpenEdit(row)}>
                          Edit
                        </Button>
                      </TableCell>
                    </TableRow>
                  );
                })}
                {rows.length === 0 && (
                  <TableRow>
                    <TableCell colSpan={8} align="center" sx={{ color: 'text.secondary', py: 3 }}>
                      No accounts found.
                    </TableCell>
                  </TableRow>
                )}
              </TableBody>
            </Table>
          </TableContainer>
        )}
      </Paper>

      <BulkImportDialog
        open={bulkOpen}
        onClose={() => setBulkOpen(false)}
        onImported={() => runSearch(filters)}
        config={bulkImportConfig}
      />
    </Box>
  );
}