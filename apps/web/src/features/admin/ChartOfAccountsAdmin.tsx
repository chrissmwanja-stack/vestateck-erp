import { useCallback, useEffect, useState, FormEvent } from 'react';
import {
  Alert,
  Box,
  Button,
  Card,
  CardContent,
  Chip,
  CircularProgress,
  Divider,
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
import { Add as AddIcon, Edit as EditIcon, PlaylistAdd as PlaylistAddIcon } from '@mui/icons-material';
import type { Database } from '@erp-platform/shared';
import { supabase } from '../../lib/supabaseClient';
import { useAuth } from '../../lib/authContext';
import { resolveTenantId } from '../../lib/ResolveTenantId';

type AccountType = 'asset' | 'liability' | 'equity' | 'revenue' | 'expense';
type GlAccountInsert = Database['public']['Tables']['gl_accounts']['Insert'];
type GlAccountUpdate = Database['public']['Tables']['gl_accounts']['Update'];
type ControlAccountsInsert = Database['public']['Tables']['gl_control_accounts']['Insert'];
type ControlAccountsUpdate = Database['public']['Tables']['gl_control_accounts']['Update'];

interface GlAccountRow {
  id: string;
  account_code: string;
  name: string;
  account_type: AccountType;
  is_control_account: boolean;
  is_active: boolean;
}

interface FormState {
  account_code: string;
  name: string;
  account_type: AccountType;
  is_control_account: boolean;
  is_active: boolean;
}

const emptyForm: FormState = {
  account_code: '',
  name: '',
  account_type: 'expense',
  is_control_account: false,
  is_active: true,
};

// One row per tenant -- the auto-posting triggers (supplier_invoices,
// receivable_invoices, cash_bank_transactions) read this to know which
// GL accounts to post to. Nothing posts to the ledger until this exists.
interface ControlAccountsRow {
  tenant_id: string;
  ap_control_account_id: string;
  ar_control_account_id: string;
  bank_account_id: string;
  cash_account_id: string;
  vat_input_account_id: string;
  vat_output_account_id: string;
  default_expense_account_id: string;
  default_revenue_account_id: string;
  wht_payable_account_id: string | null;
  salaries_payable_account_id: string | null;
  paye_payable_account_id: string | null;
  nssf_payable_account_id: string | null;
  salaries_expense_account_id: string | null;
}

type OptionalControlKey =
  | 'wht_payable_account_id'
  | 'salaries_payable_account_id'
  | 'paye_payable_account_id'
  | 'nssf_payable_account_id'
  | 'salaries_expense_account_id';

const CONTROL_FIELDS: { key: keyof Omit<ControlAccountsRow, 'tenant_id' | OptionalControlKey>; label: string }[] = [
  { key: 'bank_account_id', label: 'Bank' },
  { key: 'cash_account_id', label: 'Cash' },
  { key: 'ap_control_account_id', label: 'Accounts Payable Control' },
  { key: 'ar_control_account_id', label: 'Accounts Receivable Control' },
  { key: 'vat_input_account_id', label: 'VAT Input' },
  { key: 'vat_output_account_id', label: 'VAT Output' },
  { key: 'default_expense_account_id', label: 'Default Expense' },
  { key: 'default_revenue_account_id', label: 'Default Revenue' },
];

// wht_payable_account_id is deliberately excluded from CONTROL_FIELDS (and its
// required-field validation) -- it's nullable on gl_control_accounts because not
// every tenant is a URA-designated withholding agent. trg_post_supplier_invoice()
// skips WHT posting when this is unset, same "skip, don't guess" pattern as a
// missing control-accounts row entirely.
const WHT_FIELDS: { key: 'wht_payable_account_id'; label: string }[] = [
  { key: 'wht_payable_account_id', label: 'WHT Payable (optional — only if you withhold tax on supplier invoices)' },
];

// Also excluded from CONTROL_FIELDS -- not every tenant runs payroll through
// this platform yet. trg_post_payroll_run_approval() requires all four of
// these set together: it posts nothing for a payroll run approval if even one
// is missing, same "skip, don't guess" pattern as a missing control-accounts
// row entirely. (The disbursement leg, via trg_post_cash_bank_transaction(),
// then settles Salaries Payable when the run is paid out.)
const PAYROLL_FIELDS: { key: Exclude<OptionalControlKey, 'wht_payable_account_id'>; label: string }[] = [
  { key: 'salaries_payable_account_id', label: 'Salaries Payable' },
  { key: 'paye_payable_account_id', label: 'PAYE Payable' },
  { key: 'nssf_payable_account_id', label: 'NSSF Payable' },
  { key: 'salaries_expense_account_id', label: 'Salaries Expense' },
];

const OPTIONAL_CONTROL_FIELDS: { key: OptionalControlKey; label: string }[] = [...WHT_FIELDS, ...PAYROLL_FIELDS];

const ALL_CONTROL_FIELDS = [...CONTROL_FIELDS, ...OPTIONAL_CONTROL_FIELDS];

export default function ChartOfAccountsAdmin() {
  const { session } = useAuth();
  const [rows, setRows] = useState<GlAccountRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [seeding, setSeeding] = useState(false);
  const [seedError, setSeedError] = useState<string | null>(null);

  const [showForm, setShowForm] = useState(false);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [form, setForm] = useState<FormState>(emptyForm);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);

  const [controlAccounts, setControlAccounts] = useState<ControlAccountsRow | null>(null);
  const [controlForm, setControlForm] = useState<Record<string, string>>({});
  const [controlSaving, setControlSaving] = useState(false);
  const [controlError, setControlError] = useState<string | null>(null);
  const [controlSavedAt, setControlSavedAt] = useState<number | null>(null);

  const loadAccounts = useCallback(async () => {
    setLoading(true);
    setError(null);
    const { data, error: err } = await supabase
      .from('gl_accounts')
      .select('id, account_code, name, account_type, is_control_account, is_active')
      .order('account_code');
    if (err) {
      setError(err.message);
    } else {
      setRows((data ?? []) as GlAccountRow[]);
    }
    setLoading(false);
  }, []);

  const loadControlAccounts = useCallback(async () => {
    const { data } = await supabase.from('gl_control_accounts').select('*').maybeSingle();
    if (data) {
      setControlAccounts(data as ControlAccountsRow);
      setControlForm(
        Object.fromEntries(ALL_CONTROL_FIELDS.map((f) => [f.key, ((data as any)[f.key] as string) ?? '']))
      );
    } else {
      setControlAccounts(null);
      setControlForm({});
    }
  }, []);

  useEffect(() => {
    loadAccounts();
    loadControlAccounts();
  }, [loadAccounts, loadControlAccounts]);

  async function handleSeedDefaults() {
    setSeeding(true);
    setSeedError(null);
    const { error: err } = await supabase.rpc('seed_default_chart_of_accounts');
    setSeeding(false);
    if (err) {
      setSeedError(err.message);
      return;
    }
    await loadAccounts();
    await loadControlAccounts();
  }

  function handleOpenNew() {
    setSaveError(null);
    setEditingId(null);
    setForm(emptyForm);
    setShowForm(true);
  }

  function handleOpenEdit(row: GlAccountRow) {
    setSaveError(null);
    setEditingId(row.id);
    setForm({
      account_code: row.account_code,
      name: row.name,
      account_type: row.account_type,
      is_control_account: row.is_control_account,
      is_active: row.is_active,
    });
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

    // gl_accounts.tenant_id is uuid NOT NULL with no default, same
    // gap resolveTenantId exists for -- see its header comment.
    let tenant_id: string | undefined;
    if (!editingId) {
      const tenantResult = await resolveTenantId(session);
      if (!tenantResult.ok) {
        setSaveError(tenantResult.error);
        setSaving(false);
        return;
      }
      tenant_id = tenantResult.tenantId;
    }

    const payload: GlAccountUpdate = {
      account_code: form.account_code.trim(),
      name: form.name.trim(),
      account_type: form.account_type,
      is_control_account: form.is_control_account,
      is_active: form.is_active,
    };

    const { error: err } = editingId
      ? await supabase.from('gl_accounts').update(payload).eq('id', editingId)
      : await supabase.from('gl_accounts').insert({ ...payload, tenant_id } as GlAccountInsert);
    setSaving(false);

    if (err) {
      setSaveError(
        err.message.includes('duplicate key')
          ? `Account code "${form.account_code}" is already in use.`
          : err.message ?? 'Could not save the account. Try again.'
      );
      return;
    }

    setShowForm(false);
    setEditingId(null);
    setForm(emptyForm);
    loadAccounts();
  }

  async function handleSaveControlAccounts(e: FormEvent) {
    e.preventDefault();
    setControlError(null);

    const missing = CONTROL_FIELDS.filter((f) => !controlForm[f.key]);
    if (missing.length > 0) {
      setControlError(`Set an account for: ${missing.map((f) => f.label).join(', ')}.`);
      return;
    }

    setControlSaving(true);
    // Required fields are already validated non-empty above. The optional WHT
    // field sends null (not '') when unset -- gl_control_accounts.wht_payable_account_id
    // is a nullable uuid column, and an empty string would fail uuid parsing.
    const payload = Object.fromEntries(
      ALL_CONTROL_FIELDS.map((f) => [f.key, controlForm[f.key] || null])
    ) as ControlAccountsUpdate;

    let err;
    if (controlAccounts) {
      ({ error: err } = await supabase.from('gl_control_accounts').update(payload).eq('tenant_id', controlAccounts.tenant_id));
    } else {
      const tenantResult = await resolveTenantId(session);
      if (!tenantResult.ok) {
        setControlError(tenantResult.error);
        setControlSaving(false);
        return;
      }
      ({ error: err } = await supabase
        .from('gl_control_accounts')
        .insert({ ...payload, tenant_id: tenantResult.tenantId } as ControlAccountsInsert));
    }
    setControlSaving(false);

    if (err) {
      setControlError(err.message ?? 'Could not save the control account mapping.');
      return;
    }

    setControlSavedAt(Date.now());
    loadControlAccounts();
  }

  const hasAccounts = rows.length > 0;

  return (
    <Box>
      <Stack direction="row" justifyContent="space-between" alignItems="center" sx={{ mb: 2 }}>
        <Typography variant="h5">Chart of Accounts</Typography>
        <Stack direction="row" spacing={1}>
          {!hasAccounts && !loading && (
            <Button
              variant="outlined"
              startIcon={<PlaylistAddIcon />}
              onClick={handleSeedDefaults}
              disabled={seeding}
            >
              {seeding ? 'Setting up…' : 'Set Up Starter Chart of Accounts'}
            </Button>
          )}
          <Button variant="contained" startIcon={<AddIcon />} onClick={handleOpenNew}>
            New Account
          </Button>
        </Stack>
      </Stack>

      {seedError && (
        <Alert severity="error" sx={{ mb: 2 }}>
          {seedError}
        </Alert>
      )}

      {!hasAccounts && !loading && (
        <Alert severity="info" sx={{ mb: 3 }}>
          No chart of accounts yet. Postings from supplier invoices, receivable invoices, and cash/bank
          transactions won't reach the ledger until one exists — either click "Set Up Starter Chart of
          Accounts" for a standard 8-account starting point, or add accounts manually below.
        </Alert>
      )}

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
                  <TextField
                    select
                    label="Type"
                    required
                    sx={{ flex: 1 }}
                    value={form.account_type}
                    onChange={(e) => setForm((v) => ({ ...v, account_type: e.target.value as AccountType }))}
                  >
                    <MenuItem value="asset">Asset</MenuItem>
                    <MenuItem value="liability">Liability</MenuItem>
                    <MenuItem value="equity">Equity</MenuItem>
                    <MenuItem value="revenue">Revenue</MenuItem>
                    <MenuItem value="expense">Expense</MenuItem>
                  </TextField>
                </Stack>

                <Stack direction="row" spacing={3}>
                  <FormControlLabel
                    control={
                      <Switch
                        checked={form.is_control_account}
                        onChange={(e) => setForm((v) => ({ ...v, is_control_account: e.target.checked }))}
                      />
                    }
                    label="Control account (e.g. AP/AR/Bank — used by auto-posting, not a category total)"
                  />
                  <FormControlLabel
                    control={
                      <Switch
                        checked={form.is_active}
                        onChange={(e) => setForm((v) => ({ ...v, is_active: e.target.checked }))}
                      />
                    }
                    label="Active"
                  />
                </Stack>

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

      <Paper sx={{ p: 2, mb: 3 }} variant="outlined">
        <Typography variant="subtitle1" sx={{ fontWeight: 600, mb: 1 }}>
          Accounts
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
                  <TableCell>Type</TableCell>
                  <TableCell>Control?</TableCell>
                  <TableCell>Status</TableCell>
                  <TableCell align="right">Actions</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {rows.map((row) => (
                  <TableRow key={row.id} hover>
                    <TableCell>{row.account_code}</TableCell>
                    <TableCell>{row.name}</TableCell>
                    <TableCell>
                      <Chip size="small" label={row.account_type} />
                    </TableCell>
                    <TableCell>{row.is_control_account ? 'Yes' : '—'}</TableCell>
                    <TableCell>
                      <Chip size="small" label={row.is_active ? 'Active' : 'Inactive'} color={row.is_active ? 'success' : 'default'} />
                    </TableCell>
                    <TableCell align="right">
                      <Button size="small" startIcon={<EditIcon />} onClick={() => handleOpenEdit(row)}>
                        Edit
                      </Button>
                    </TableCell>
                  </TableRow>
                ))}
                {rows.length === 0 && (
                  <TableRow>
                    <TableCell colSpan={6} align="center" sx={{ color: 'text.secondary', py: 3 }}>
                      No accounts yet.
                    </TableCell>
                  </TableRow>
                )}
              </TableBody>
            </Table>
          </TableContainer>
        )}
      </Paper>

      {hasAccounts && (
        <Paper sx={{ p: 3 }} variant="outlined">
          <Typography variant="subtitle1" sx={{ fontWeight: 600, mb: 0.5 }}>
            Control Account Mapping
          </Typography>
          <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
            Supplier invoices, receivable invoices, and cash/bank transactions post to these accounts
            automatically. Until every field below is set, new transactions save normally but won't
            appear on the ledger.
          </Typography>
          <Divider sx={{ mb: 2 }} />
          <Box component="form" onSubmit={handleSaveControlAccounts} noValidate>
            <Stack direction="row" flexWrap="wrap" gap={2}>
              {CONTROL_FIELDS.map((f) => (
                <TextField
                  key={f.key}
                  select
                  label={f.label}
                  sx={{ flex: '1 1 260px' }}
                  value={controlForm[f.key] ?? ''}
                  onChange={(e) => setControlForm((v) => ({ ...v, [f.key]: e.target.value }))}
                >
                  <MenuItem value="">Not set</MenuItem>
                  {rows.map((a) => (
                    <MenuItem key={a.id} value={a.id}>
                      {a.account_code} — {a.name}
                    </MenuItem>
                  ))}
                </TextField>
              ))}
            </Stack>

            <Divider sx={{ my: 2 }} />

            <Typography variant="body2" color="text.secondary" sx={{ mb: 1.5 }}>
              Withholding tax — leave unset if you're not a URA-designated withholding agent. Supplier
              invoices with WHT withheld won't post the WHT line to the ledger until this is set.
            </Typography>
            <Stack direction="row" flexWrap="wrap" gap={2}>
              {WHT_FIELDS.map((f) => (
                <TextField
                  key={f.key}
                  select
                  label={f.label}
                  sx={{ flex: '1 1 260px' }}
                  value={controlForm[f.key] ?? ''}
                  onChange={(e) => setControlForm((v) => ({ ...v, [f.key]: e.target.value }))}
                >
                  <MenuItem value="">Not set</MenuItem>
                  {rows.map((a) => (
                    <MenuItem key={a.id} value={a.id}>
                      {a.account_code} — {a.name}
                    </MenuItem>
                  ))}
                </TextField>
              ))}
            </Stack>

            <Divider sx={{ my: 2 }} />

            <Typography variant="body2" color="text.secondary" sx={{ mb: 1.5 }}>
              Payroll — leave unset if you don't run payroll through this platform yet. All four must be
              set before a payroll run's approval posts to the ledger; disbursement (cash/bank payment)
              then settles Salaries Payable. Partial setup posts nothing rather than guessing.
            </Typography>
            <Stack direction="row" flexWrap="wrap" gap={2}>
              {PAYROLL_FIELDS.map((f) => (
                <TextField
                  key={f.key}
                  select
                  label={f.label}
                  sx={{ flex: '1 1 260px' }}
                  value={controlForm[f.key] ?? ''}
                  onChange={(e) => setControlForm((v) => ({ ...v, [f.key]: e.target.value }))}
                >
                  <MenuItem value="">Not set</MenuItem>
                  {rows.map((a) => (
                    <MenuItem key={a.id} value={a.id}>
                      {a.account_code} — {a.name}
                    </MenuItem>
                  ))}
                </TextField>
              ))}
            </Stack>

            {controlError && (
              <Alert severity="error" sx={{ mt: 2 }}>
                {controlError}
              </Alert>
            )}
            {controlSavedAt && !controlError && (
              <Alert severity="success" sx={{ mt: 2 }}>
                Control account mapping saved.
              </Alert>
            )}

            <Stack direction="row" sx={{ mt: 2 }}>
              <Button type="submit" variant="contained" disabled={controlSaving}>
                {controlSaving ? 'Saving…' : 'Save Mapping'}
              </Button>
            </Stack>
          </Box>
        </Paper>
      )}
    </Box>
  );
}