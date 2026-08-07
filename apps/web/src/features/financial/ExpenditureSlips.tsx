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

interface ExpenditureSlipRow {
  id: string;
  slip_number: string;
  slip_date: string;
  payee_name: string;
  purpose: string;
  amount: number;
  currency: string;
  created_at: string;
  petty_cash_float_id: string | null;
  cost_centers: { name: string; project_code: string | null } | { name: string; project_code: string | null }[] | null;
  organization: { company_code: string; site_name: string } | { company_code: string; site_name: string }[] | null;
  recorded_by_user: { name: string } | { name: string }[] | null;
}

interface OrganizationOption {
  id: string;
  company_code: string;
  site_name: string;
}

interface SearchFilters {
  slipNo: string;
  organizationId: string;
  dateFrom: string;
  dateTo: string;
}

const emptyFilters: SearchFilters = { slipNo: '', organizationId: '', dateFrom: '', dateTo: '' };

interface EntryState {
  cost_center_id: string;
  organization_id: string;
  slip_number: string;
  slip_date: string;
  payee_name: string;
  purpose: string;
  amount: string;
  currency: string;
  petty_cash_float_id: string;
}

const emptyEntry: EntryState = {
  cost_center_id: '',
  organization_id: '',
  slip_number: '',
  slip_date: '',
  payee_name: '',
  purpose: '',
  amount: '',
  currency: 'UGX',
  petty_cash_float_id: '',
};

interface PettyCashFloatOption {
  petty_cash_float_id: string;
  float_name: string;
  cost_center_id: string;
  ceiling_amount: number;
  current_balance: number;
  currency: string;
  is_active: boolean;
}

function embedOne<T>(value: T | T[] | null | undefined): T | null {
  if (!value) return null;
  return Array.isArray(value) ? value[0] ?? null : value;
}

export default function ExpenditureSlips() {
  const [filters, setFilters] = useState<SearchFilters>(emptyFilters);
  const [rows, setRows] = useState<ExpenditureSlipRow[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [costCenters, setCostCenters] = useState<CostCenter[]>([]);
  const [loadingCostCenters, setLoadingCostCenters] = useState(false);
  const [showEntryForm, setShowEntryForm] = useState(false);
  const [entry, setEntry] = useState<EntryState>(emptyEntry);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);

  // Loaded once on mount rather than on-demand, since the Organization
  // picker is now needed both by the search filter and the entry form.
  const [organizations, setOrganizations] = useState<OrganizationOption[]>([]);
  const [loadingOrganizations, setLoadingOrganizations] = useState(false);

  // All active petty cash floats, narrowed to the selected cost center in
  // the picker below. Balances come straight from the
  // petty_cash_float_balances view so the warning is always current.
  const [pettyCashFloats, setPettyCashFloats] = useState<PettyCashFloatOption[]>([]);
  const [loadingPettyCashFloats, setLoadingPettyCashFloats] = useState(false);

  const runSearch = useCallback(async (activeFilters: SearchFilters) => {
    setLoading(true);
    setError(null);
    try {
      let query = supabase
        .from('expenditure_slips')
        .select(
          'id, slip_number, slip_date, payee_name, purpose, amount, currency, created_at, petty_cash_float_id, cost_centers(name, project_code), organization:organizations!organization_id(company_code, site_name), recorded_by_user:app_users!recorded_by(name)'
        )
        .order('created_at', { ascending: false });

      if (activeFilters.slipNo.trim()) {
        query = query.ilike('slip_number', `%${activeFilters.slipNo.trim()}%`);
      }
      if (activeFilters.organizationId) {
        query = query.eq('organization_id', activeFilters.organizationId);
      }
      if (activeFilters.dateFrom) {
        query = query.gte('slip_date', activeFilters.dateFrom);
      }
      if (activeFilters.dateTo) {
        query = query.lte('slip_date', activeFilters.dateTo);
      }

      const { data, error: queryError } = await query;
      if (queryError) throw queryError;
      setRows((data ?? []) as unknown as ExpenditureSlipRow[]);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed to load expenditure slips');
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

  const loadPettyCashFloats = useCallback(async () => {
    setLoadingPettyCashFloats(true);
    try {
      const { data, error: pcError } = await supabase
        .from('petty_cash_float_balances')
        .select('petty_cash_float_id, float_name, cost_center_id, ceiling_amount, current_balance, currency, is_active')
        .eq('is_active', true)
        .order('float_name');
      if (pcError) throw pcError;
      setPettyCashFloats((data ?? []) as PettyCashFloatOption[]);
    } catch (e) {
      setSaveError(e instanceof Error ? e.message : 'Failed to load petty cash floats');
    } finally {
      setLoadingPettyCashFloats(false);
    }
  }, []);

  useEffect(() => {
    runSearch(emptyFilters);
    loadOrganizations();
  }, [runSearch, loadOrganizations]);

  const costCenterOptions = useMemo(
    () => costCenters.map((cc) => ({ id: cc.id, label: `${cc.project_code} — ${cc.name}` })),
    [costCenters]
  );

  const organizationOptions = useMemo(
    () => organizations.map((o) => ({ id: o.id, label: `${o.company_code} — ${o.site_name}` })),
    [organizations]
  );

  // Petty cash float picker: narrowed to whichever cost center is selected,
  // since a float is tied to one cost center. If no cost center is picked
  // yet, show none rather than every float across every project.
  const pettyCashFloatOptions = useMemo(
    () =>
      pettyCashFloats
        .filter((f) => f.cost_center_id === entry.cost_center_id)
        .map((f) => ({ id: f.petty_cash_float_id, label: `${f.float_name} — balance ${f.current_balance.toLocaleString()} ${f.currency}` })),
    [pettyCashFloats, entry.cost_center_id]
  );

  const selectedFloat = useMemo(
    () => pettyCashFloats.find((f) => f.petty_cash_float_id === entry.petty_cash_float_id) ?? null,
    [pettyCashFloats, entry.petty_cash_float_id]
  );

  // Soft warning only -- per design, petty cash floats don't hard-block
  // spend past the balance, they just flag it so the custodian/finance know
  // a replenishment is due.
  const exceedsBalance =
    selectedFloat !== null && entry.amount !== '' && Number(entry.amount) > selectedFloat.current_balance;

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
    loadCostCenters();
    loadPettyCashFloats();
    setShowEntryForm(true);
  }

  async function handleSaveEntry(e: FormEvent) {
    e.preventDefault();
    setSaveError(null);

    if (!entry.cost_center_id || !entry.slip_number || !entry.slip_date || !entry.payee_name.trim() || !entry.purpose.trim() || !entry.amount) {
      setSaveError('Cost center, slip number, date, payee, purpose, and amount are all required.');
      return;
    }

    const parsedAmount = Number(entry.amount);
    if (Number.isNaN(parsedAmount) || parsedAmount <= 0) {
      setSaveError('Amount must be a valid number greater than 0.');
      return;
    }

    setSaving(true);
    const { error: insertError } = await supabase.from('expenditure_slips').insert({
      cost_center_id: entry.cost_center_id,
      organization_id: entry.organization_id || null,
      slip_number: entry.slip_number.trim(),
      slip_date: entry.slip_date,
      payee_name: entry.payee_name.trim(),
      purpose: entry.purpose.trim(),
      amount: parsedAmount,
      currency: entry.currency,
      petty_cash_float_id: entry.petty_cash_float_id || null,
    });
    setSaving(false);

    if (insertError) {
      setSaveError(insertError.message ?? 'Could not save the expenditure slip. Try again.');
      return;
    }

    setShowEntryForm(false);
    setEntry(emptyEntry);
    runSearch(filters);
  }

  return (
    <Box>
      <Stack direction="row" justifyContent="space-between" alignItems="center" sx={{ mb: 2 }}>
        <Typography variant="h5">Expenditure Slips</Typography>
        <Button variant="contained" startIcon={<AddIcon />} onClick={handleOpenEntryForm}>
          New Expenditure Slip
        </Button>
      </Stack>

      {/* Search */}
      <Paper sx={{ p: 3, mb: 3 }} variant="outlined">
        <Typography variant="subtitle1" sx={{ fontWeight: 600, mb: 2 }}>
          Search
        </Typography>
        <Box component="form" onSubmit={handleSearchSubmit}>
          <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2} flexWrap="wrap">
            <Autocomplete
              sx={{ flex: 1, minWidth: 220 }}
              size="small"
              options={organizationOptions}
              loading={loadingOrganizations}
              onChange={(_, option) => setFilters((f) => ({ ...f, organizationId: option?.id ?? '' }))}
              value={organizationOptions.find((o) => o.id === filters.organizationId) ?? null}
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
            <TextField
              label="Slip No"
              size="small"
              sx={{ flex: 1, minWidth: 160 }}
              value={filters.slipNo}
              onChange={(e) => setFilters((f) => ({ ...f, slipNo: e.target.value }))}
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
              New Expenditure Slip
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
                  onChange={(_, option) =>
                    setEntry((v) => ({ ...v, cost_center_id: option?.id ?? '', petty_cash_float_id: '' }))
                  }
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

                <Autocomplete
                  options={pettyCashFloatOptions}
                  loading={loadingPettyCashFloats}
                  onChange={(_, option) => setEntry((v) => ({ ...v, petty_cash_float_id: option?.id ?? '' }))}
                  value={pettyCashFloatOptions.find((o) => o.id === entry.petty_cash_float_id) ?? null}
                  isOptionEqualToValue={(option, value) => option.id === value.id}
                  renderInput={(params) => (
                    <TextField
                      {...params}
                      label="Petty Cash Float (optional)"
                      helperText={
                        !entry.cost_center_id
                          ? 'Pick a cost center first to see its floats'
                          : !loadingPettyCashFloats && pettyCashFloatOptions.length === 0
                            ? 'No active petty cash float for this cost center'
                            : 'Leave blank if this is not drawn from a petty cash float'
                      }
                      InputProps={{
                        ...params.InputProps,
                        endAdornment: (
                          <>
                            {loadingPettyCashFloats ? <CircularProgress color="inherit" size={16} /> : null}
                            {params.InputProps.endAdornment}
                          </>
                        ),
                      }}
                    />
                  )}
                />

                <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2}>
                  <TextField
                    label="Slip No"
                    required
                    sx={{ flex: 1 }}
                    value={entry.slip_number}
                    onChange={(e) => setEntry((v) => ({ ...v, slip_number: e.target.value }))}
                  />
                  <TextField
                    label="Slip Date"
                    type="date"
                    required
                    sx={{ flex: 1 }}
                    InputLabelProps={{ shrink: true }}
                    value={entry.slip_date}
                    onChange={(e) => setEntry((v) => ({ ...v, slip_date: e.target.value }))}
                  />
                </Stack>

                <TextField
                  label="Payee Name"
                  required
                  fullWidth
                  value={entry.payee_name}
                  onChange={(e) => setEntry((v) => ({ ...v, payee_name: e.target.value }))}
                />

                <TextField
                  label="Purpose"
                  required
                  fullWidth
                  multiline
                  minRows={2}
                  value={entry.purpose}
                  onChange={(e) => setEntry((v) => ({ ...v, purpose: e.target.value }))}
                />

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
                </Stack>

                {exceedsBalance && selectedFloat && (
                  <Alert severity="warning">
                    This amount exceeds the float's current balance ({selectedFloat.current_balance.toLocaleString()}{' '}
                    {selectedFloat.currency}). You can still save this slip, but the float will need replenishing.
                  </Alert>
                )}

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
                  <TableCell>Slip No</TableCell>
                  <TableCell>Cost Center</TableCell>
                  <TableCell>Payee</TableCell>
                  <TableCell>Purpose</TableCell>
                  <TableCell>Date</TableCell>
                  <TableCell align="right">Amount</TableCell>
                  <TableCell>Currency</TableCell>
                  <TableCell>Recorded By</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {rows.map((row) => {
                  const cc = embedOne(row.cost_centers);
                  const org = embedOne(row.organization);
                  return (
                    <TableRow key={row.id} hover>
                      <TableCell>{org ? `${org.company_code} — ${org.site_name}` : '—'}</TableCell>
                      <TableCell>{row.slip_number}</TableCell>
                      <TableCell>{cc ? `${cc.project_code ?? ''} ${cc.name}`.trim() : '—'}</TableCell>
                      <TableCell>{row.payee_name}</TableCell>
                      <TableCell>{row.purpose}</TableCell>
                      <TableCell>{row.slip_date}</TableCell>
                      <TableCell align="right">{row.amount.toLocaleString()}</TableCell>
                      <TableCell>{row.currency}</TableCell>
                      <TableCell>{embedOne(row.recorded_by_user)?.name ?? '—'}</TableCell>
                    </TableRow>
                  );
                })}
                {rows.length === 0 && (
                  <TableRow>
                    <TableCell colSpan={9} align="center" sx={{ color: 'text.secondary', py: 3 }}>
                      No expenditure slips found.
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