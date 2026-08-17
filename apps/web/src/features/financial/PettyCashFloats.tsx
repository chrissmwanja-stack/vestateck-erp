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
} from '@mui/material';
import { Add as AddIcon, Edit as EditIcon, Payments as PaymentsIcon } from '@mui/icons-material';
import { supabase } from '../../lib/supabaseClient';
import type { CostCenter } from '@erp-platform/shared';

interface CostCenterOption {
  id: string;
  label: string;
}

interface CustodianOption {
  id: string;
  name: string;
}

interface FloatRow {
  petty_cash_float_id: string;
  cost_center_id: string;
  custodian_user_id: string;
  float_name: string;
  ceiling_amount: number;
  currency: string;
  is_active: boolean;
  total_replenished: number;
  total_spent: number;
  current_balance: number;
  cost_center_label?: string;
  custodian_label?: string;
}

interface FloatFormState {
  float_name: string;
  cost_center_id: string;
  custodian_user_id: string;
  ceiling_amount: string;
  currency: string;
  is_active: boolean;
}

const emptyFloatForm: FloatFormState = {
  float_name: '',
  cost_center_id: '',
  custodian_user_id: '',
  ceiling_amount: '',
  currency: 'UGX',
  is_active: true,
};

interface ReplenishFormState {
  amount: string;
  replenished_date: string;
  funded_from: 'cash' | 'bank';
  bank_account: string;
  description: string;
}

const emptyReplenishForm: ReplenishFormState = {
  amount: '',
  replenished_date: '',
  funded_from: 'bank',
  bank_account: '',
  description: '',
};

export default function PettyCashFloats() {
  const [rows, setRows] = useState<FloatRow[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [costCenters, setCostCenters] = useState<CostCenter[]>([]);
  const [loadingCostCenters, setLoadingCostCenters] = useState(false);
  const [custodians, setCustodians] = useState<CustodianOption[]>([]);
  const [loadingCustodians, setLoadingCustodians] = useState(false);

  const [showFloatForm, setShowFloatForm] = useState(false);
  const [editingFloatId, setEditingFloatId] = useState<string | null>(null);
  const [floatForm, setFloatForm] = useState<FloatFormState>(emptyFloatForm);
  const [savingFloat, setSavingFloat] = useState(false);
  const [floatSaveError, setFloatSaveError] = useState<string | null>(null);

  const [replenishingFloat, setReplenishingFloat] = useState<FloatRow | null>(null);
  const [replenishForm, setReplenishForm] = useState<ReplenishFormState>(emptyReplenishForm);
  const [savingReplenishment, setSavingReplenishment] = useState(false);
  const [replenishError, setReplenishError] = useState<string | null>(null);

  const loadRows = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const { data, error: qErr } = await supabase
        .from('petty_cash_float_balances')
        .select('*')
        .order('float_name');
      if (qErr) throw qErr;

      const floatRows = (data ?? []) as FloatRow[];

      // Resolve cost center / custodian display labels in two batched
      // lookups rather than embedding them in the view (views over a
      // left-joined aggregate get awkward with nested selects here).
      const ccIds = Array.from(new Set(floatRows.map((r) => r.cost_center_id)));
      const userIds = Array.from(new Set(floatRows.map((r) => r.custodian_user_id)));

      const [{ data: ccData }, { data: userData }] = await Promise.all([
        ccIds.length
          ? supabase.from('cost_centers').select('id, name, project_code').in('id', ccIds)
          : Promise.resolve({ data: [] as any[] }),
        userIds.length
          ? supabase.from('app_users').select('id, name').in('id', userIds)
          : Promise.resolve({ data: [] as any[] }),
      ]);

      const ccMap = new Map((ccData ?? []).map((c: any) => [c.id, `${c.project_code ?? ''} ${c.name}`.trim()]));
      const userMap = new Map((userData ?? []).map((u: any) => [u.id, u.name]));

      setRows(
        floatRows.map((r) => ({
          ...r,
          cost_center_label: ccMap.get(r.cost_center_id) ?? '—',
          custodian_label: userMap.get(r.custodian_user_id) ?? '—',
        }))
      );
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed to load petty cash floats');
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
      setFloatSaveError(e instanceof Error ? e.message : 'Failed to load cost centers');
    } finally {
      setLoadingCostCenters(false);
    }
  }, []);

  const loadCustodians = useCallback(async () => {
    setLoadingCustodians(true);
    try {
      // Any app_users row is a valid custodian -- petty cash custodianship
      // isn't gated to the finance team, since site staff often hold the
      // cash box even if they can't touch the accounting screens.
      const { data, error: userError } = await supabase.from('app_users').select('id, name').order('name');
      if (userError) throw userError;
      setCustodians(data ?? []);
    } catch (e) {
      setFloatSaveError(e instanceof Error ? e.message : 'Failed to load users');
    } finally {
      setLoadingCustodians(false);
    }
  }, []);

  useEffect(() => {
    loadRows();
  }, [loadRows]);

  const costCenterOptions = useMemo<CostCenterOption[]>(
    () => costCenters.map((cc) => ({ id: cc.id, label: `${cc.project_code} — ${cc.name}` })),
    [costCenters]
  );

  function handleOpenNewFloat() {
    setFloatSaveError(null);
    setEditingFloatId(null);
    setFloatForm(emptyFloatForm);
    loadCostCenters();
    loadCustodians();
    setShowFloatForm(true);
  }

  function handleOpenEditFloat(row: FloatRow) {
    setFloatSaveError(null);
    setEditingFloatId(row.petty_cash_float_id);
    setFloatForm({
      float_name: row.float_name,
      cost_center_id: row.cost_center_id,
      custodian_user_id: row.custodian_user_id,
      ceiling_amount: String(row.ceiling_amount),
      currency: row.currency,
      is_active: row.is_active,
    });
    loadCostCenters();
    loadCustodians();
    setShowFloatForm(true);
  }

  async function handleSaveFloat(e: FormEvent) {
    e.preventDefault();
    setFloatSaveError(null);

    if (!floatForm.float_name.trim() || !floatForm.cost_center_id || !floatForm.custodian_user_id || !floatForm.ceiling_amount) {
      setFloatSaveError('Name, cost center, custodian, and ceiling amount are required.');
      return;
    }
    const parsedCeiling = Number(floatForm.ceiling_amount);
    if (Number.isNaN(parsedCeiling) || parsedCeiling <= 0) {
      setFloatSaveError('Ceiling amount must be a valid number greater than 0.');
      return;
    }

    setSavingFloat(true);
    const payload = {
      float_name: floatForm.float_name.trim(),
      cost_center_id: floatForm.cost_center_id,
      custodian_user_id: floatForm.custodian_user_id,
      ceiling_amount: parsedCeiling,
      currency: floatForm.currency,
      is_active: floatForm.is_active,
    };

    let saveErr;
    if (editingFloatId) {
      ({ error: saveErr } = await supabase.from('petty_cash_floats').update(payload).eq('id', editingFloatId));
    } else {
      // tenant_id is overwritten server-side by set_petty_cash_defaults_trigger,
      // but the column is NOT NULL with no DB default so it must be present here for TS.
      const {
        data: { user },
      } = await supabase.auth.getUser();
      const { data: profile, error: profileError } = await supabase
        .from('app_users')
        .select('tenant_id')
        .eq('id', user?.id ?? '')
        .single();
      if (profileError || !profile) {
        setSavingFloat(false);
        setFloatSaveError(profileError?.message ?? 'Could not determine your tenant. Contact an admin.');
        return;
      }
      ({ error: saveErr } = await supabase
        .from('petty_cash_floats')
        .insert({ ...payload, tenant_id: profile.tenant_id }));
    }
    setSavingFloat(false);

    if (saveErr) {
      setFloatSaveError(saveErr.message ?? 'Could not save the float. Try again.');
      return;
    }

    setShowFloatForm(false);
    setEditingFloatId(null);
    setFloatForm(emptyFloatForm);
    loadRows();
  }

  function handleOpenReplenish(row: FloatRow) {
    setReplenishError(null);
    setReplenishingFloat(row);
    setReplenishForm(emptyReplenishForm);
  }

  async function handleSaveReplenishment(e: FormEvent) {
    e.preventDefault();
    if (!replenishingFloat) return;
    setReplenishError(null);

    if (!replenishForm.amount || !replenishForm.replenished_date) {
      setReplenishError('Amount and date are required.');
      return;
    }
    const parsedAmount = Number(replenishForm.amount);
    if (Number.isNaN(parsedAmount) || parsedAmount <= 0) {
      setReplenishError('Amount must be a valid number greater than 0.');
      return;
    }

    setSavingReplenishment(true);
    const {
      data: { user: replenishUser },
    } = await supabase.auth.getUser();
    const { data: replenishProfile, error: replenishProfileError } = await supabase
      .from('app_users')
      .select('tenant_id')
      .eq('id', replenishUser?.id ?? '')
      .single();
    if (replenishProfileError || !replenishProfile) {
      setSavingReplenishment(false);
      setReplenishError(replenishProfileError?.message ?? 'Could not determine your tenant. Contact an admin.');
      return;
    }
    const { error: insertError } = await supabase.from('petty_cash_replenishments').insert({
      tenant_id: replenishProfile.tenant_id,
      petty_cash_float_id: replenishingFloat.petty_cash_float_id,
      amount: parsedAmount,
      replenished_date: replenishForm.replenished_date,
      funded_from: replenishForm.funded_from,
      bank_account: replenishForm.funded_from === 'bank' ? replenishForm.bank_account.trim() || null : null,
      description: replenishForm.description.trim() || null,
    });
    setSavingReplenishment(false);

    if (insertError) {
      setReplenishError(insertError.message ?? 'Could not save the replenishment. Try again.');
      return;
    }

    setReplenishingFloat(null);
    setReplenishForm(emptyReplenishForm);
    loadRows();
  }

  return (
    <Box>
      <Stack direction="row" justifyContent="space-between" alignItems="center" sx={{ mb: 2 }}>
        <Typography variant="h5">Petty Cash Floats</Typography>
        <Button variant="contained" startIcon={<AddIcon />} onClick={handleOpenNewFloat}>
          New Float
        </Button>
      </Stack>

      {/* New / edit float form */}
      {showFloatForm && (
        <Card sx={{ mb: 3 }} variant="outlined">
          <CardContent>
            <Typography variant="h6" gutterBottom>
              {editingFloatId ? 'Edit Petty Cash Float' : 'New Petty Cash Float'}
            </Typography>
            <Box component="form" onSubmit={handleSaveFloat} noValidate>
              <Stack spacing={2.5}>
                <TextField
                  label="Float Name"
                  required
                  fullWidth
                  placeholder="e.g. Kampala HQ Site Office"
                  value={floatForm.float_name}
                  onChange={(e) => setFloatForm((v) => ({ ...v, float_name: e.target.value }))}
                />

                <Autocomplete
                  options={costCenterOptions}
                  loading={loadingCostCenters}
                  onChange={(_, option) => setFloatForm((v) => ({ ...v, cost_center_id: option?.id ?? '' }))}
                  value={costCenterOptions.find((o) => o.id === floatForm.cost_center_id) ?? null}
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
                  options={custodians}
                  loading={loadingCustodians}
                  getOptionLabel={(o) => o.name}
                  onChange={(_, option) => setFloatForm((v) => ({ ...v, custodian_user_id: option?.id ?? '' }))}
                  value={custodians.find((o) => o.id === floatForm.custodian_user_id) ?? null}
                  isOptionEqualToValue={(option, value) => option.id === value.id}
                  renderInput={(params) => (
                    <TextField
                      {...params}
                      label="Custodian"
                      required
                      InputProps={{
                        ...params.InputProps,
                        endAdornment: (
                          <>
                            {loadingCustodians ? <CircularProgress color="inherit" size={16} /> : null}
                            {params.InputProps.endAdornment}
                          </>
                        ),
                      }}
                    />
                  )}
                />

                <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2}>
                  <TextField
                    label="Ceiling Amount"
                    type="number"
                    required
                    sx={{ flex: 1 }}
                    helperText="The fixed imprest limit this float should be topped up to"
                    value={floatForm.ceiling_amount}
                    onChange={(e) => setFloatForm((v) => ({ ...v, ceiling_amount: e.target.value }))}
                  />
                  <TextField
                    select
                    label="Currency"
                    sx={{ flex: 1 }}
                    value={floatForm.currency}
                    onChange={(e) => setFloatForm((v) => ({ ...v, currency: e.target.value }))}
                  >
                    <MenuItem value="UGX">UGX</MenuItem>
                    <MenuItem value="USD">USD</MenuItem>
                    <MenuItem value="EUR">EUR</MenuItem>
                  </TextField>
                </Stack>

                <FormControlLabel
                  control={
                    <Switch
                      checked={floatForm.is_active}
                      onChange={(e) => setFloatForm((v) => ({ ...v, is_active: e.target.checked }))}
                    />
                  }
                  label="Active (inactive floats are hidden from expenditure slip pickers)"
                />

                {floatSaveError && <Alert severity="error">{floatSaveError}</Alert>}

                <Stack direction="row" spacing={1}>
                  <Button type="submit" variant="contained" disabled={savingFloat}>
                    {savingFloat ? 'Saving…' : 'Save'}
                  </Button>
                  <Button variant="outlined" onClick={() => setShowFloatForm(false)} disabled={savingFloat}>
                    Cancel
                  </Button>
                </Stack>
              </Stack>
            </Box>
          </CardContent>
        </Card>
      )}

      {/* Replenish form */}
      {replenishingFloat && (
        <Card sx={{ mb: 3 }} variant="outlined">
          <CardContent>
            <Typography variant="h6" gutterBottom>
              Replenish — {replenishingFloat.float_name}
            </Typography>
            <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
              Current balance: {replenishingFloat.current_balance.toLocaleString()} {replenishingFloat.currency} · Ceiling:{' '}
              {replenishingFloat.ceiling_amount.toLocaleString()} {replenishingFloat.currency}
            </Typography>
            <Box component="form" onSubmit={handleSaveReplenishment} noValidate>
              <Stack spacing={2.5}>
                <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2}>
                  <TextField
                    label="Amount"
                    type="number"
                    required
                    sx={{ flex: 1 }}
                    value={replenishForm.amount}
                    onChange={(e) => setReplenishForm((v) => ({ ...v, amount: e.target.value }))}
                  />
                  <TextField
                    label="Date"
                    type="date"
                    required
                    sx={{ flex: 1 }}
                    InputLabelProps={{ shrink: true }}
                    value={replenishForm.replenished_date}
                    onChange={(e) => setReplenishForm((v) => ({ ...v, replenished_date: e.target.value }))}
                  />
                  <TextField
                    select
                    label="Funded From"
                    sx={{ flex: 1 }}
                    value={replenishForm.funded_from}
                    onChange={(e) =>
                      setReplenishForm((v) => ({ ...v, funded_from: e.target.value as 'cash' | 'bank' }))
                    }
                  >
                    <MenuItem value="bank">Bank</MenuItem>
                    <MenuItem value="cash">Cash</MenuItem>
                  </TextField>
                </Stack>

                {replenishForm.funded_from === 'bank' && (
                  <TextField
                    label="Bank Account"
                    fullWidth
                    value={replenishForm.bank_account}
                    onChange={(e) => setReplenishForm((v) => ({ ...v, bank_account: e.target.value }))}
                  />
                )}

                <TextField
                  label="Description"
                  fullWidth
                  value={replenishForm.description}
                  onChange={(e) => setReplenishForm((v) => ({ ...v, description: e.target.value }))}
                />

                {replenishError && <Alert severity="error">{replenishError}</Alert>}

                <Stack direction="row" spacing={1}>
                  <Button type="submit" variant="contained" disabled={savingReplenishment}>
                    {savingReplenishment ? 'Saving…' : 'Record Replenishment'}
                  </Button>
                  <Button variant="outlined" onClick={() => setReplenishingFloat(null)} disabled={savingReplenishment}>
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
          Floats
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
                  <TableCell>Float Name</TableCell>
                  <TableCell>Cost Center</TableCell>
                  <TableCell>Custodian</TableCell>
                  <TableCell align="right">Ceiling</TableCell>
                  <TableCell align="right">Balance</TableCell>
                  <TableCell>Status</TableCell>
                  <TableCell align="right">Actions</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {rows.map((row) => {
                  const low = row.current_balance < row.ceiling_amount * 0.2;
                  return (
                    <TableRow key={row.petty_cash_float_id} hover>
                      <TableCell>{row.float_name}</TableCell>
                      <TableCell>{row.cost_center_label}</TableCell>
                      <TableCell>{row.custodian_label}</TableCell>
                      <TableCell align="right">
                        {row.ceiling_amount.toLocaleString()} {row.currency}
                      </TableCell>
                      <TableCell align="right">
                        <Chip
                          size="small"
                          label={`${row.current_balance.toLocaleString()} ${row.currency}`}
                          color={low ? 'warning' : 'default'}
                        />
                      </TableCell>
                      <TableCell>
                        <Chip size="small" label={row.is_active ? 'Active' : 'Inactive'} color={row.is_active ? 'success' : 'default'} />
                      </TableCell>
                      <TableCell align="right">
                        <Button size="small" startIcon={<PaymentsIcon />} onClick={() => handleOpenReplenish(row)} sx={{ mr: 1 }}>
                          Replenish
                        </Button>
                        <Button size="small" startIcon={<EditIcon />} onClick={() => handleOpenEditFloat(row)}>
                          Edit
                        </Button>
                      </TableCell>
                    </TableRow>
                  );
                })}
                {rows.length === 0 && (
                  <TableRow>
                    <TableCell colSpan={7} align="center" sx={{ color: 'text.secondary', py: 3 }}>
                      No petty cash floats set up yet.
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