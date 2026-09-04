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
type PostingRuleRow = Database['public']['Tables']['gl_posting_rules']['Row'];

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

// One gl_posting_rules row per (tenant, account_role) -- the auto-posting
// triggers (supplier_invoices, receivable_invoices, cash_bank_transactions,
// hr_payroll_runs) call get_posting_account(tenant_id, role) to know which
// GL account fills each role. Nothing posts to the ledger until the
// required roles below are mapped. account_role values are enforced by a
// CHECK constraint on gl_posting_rules -- these must match it exactly.
type RequiredRole =
  | 'bank'
  | 'cash'
  | 'ap_control'
  | 'ar_control'
  | 'vat_input'
  | 'vat_output'
  | 'default_expense'
  | 'default_revenue';

type OptionalRole = 'wht_payable' | 'salaries_payable' | 'paye_payable' | 'nssf_payable' | 'salaries_expense';

const REQUIRED_ROLES: { key: RequiredRole; label: string }[] = [
  { key: 'bank', label: 'Bank' },
  { key: 'cash', label: 'Cash' },
  { key: 'ap_control', label: 'Accounts Payable Control' },
  { key: 'ar_control', label: 'Accounts Receivable Control' },
  { key: 'vat_input', label: 'VAT Input' },
  { key: 'vat_output', label: 'VAT Output' },
  { key: 'default_expense', label: 'Default Expense' },
  { key: 'default_revenue', label: 'Default Revenue' },
];

// wht_payable is deliberately excluded from REQUIRED_ROLES (and its
// required-field validation) -- it's optional because not every tenant is
// a URA-designated withholding agent. trg_post_supplier_invoice() skips
// WHT posting when this role is unmapped, same "skip, don't guess" pattern
// as no posting rules existing at all.
const WHT_ROLES: { key: 'wht_payable'; label: string }[] = [
  { key: 'wht_payable', label: 'WHT Payable (optional — only if you withhold tax on supplier invoices)' },
];

// Also excluded from REQUIRED_ROLES -- not every tenant runs payroll through
// this platform yet. trg_post_payroll_run_approval() requires all four of
// these mapped together: it posts nothing for a payroll run approval if
// even one is missing, same "skip, don't guess" pattern. (The disbursement
// leg, via trg_post_cash_bank_transaction(), then settles Salaries Payable
// when the run is paid out.)
const PAYROLL_ROLES: { key: Exclude<OptionalRole, 'wht_payable'>; label: string }[] = [
  { key: 'salaries_payable', label: 'Salaries Payable' },
  { key: 'paye_payable', label: 'PAYE Payable' },
  { key: 'nssf_payable', label: 'NSSF Payable' },
  { key: 'salaries_expense', label: 'Salaries Expense' },
];

const OPTIONAL_ROLES: { key: OptionalRole; label: string }[] = [...WHT_ROLES, ...PAYROLL_ROLES];

const ALL_ROLES: { key: RequiredRole | OptionalRole; label: string }[] = [...REQUIRED_ROLES, ...OPTIONAL_ROLES];

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

  // Map of account_role -> gl_account_id, one entry per gl_posting_rules
  // row for this tenant. Empty object (not null) means "no rules mapped
  // yet" -- there's no separate "row exists" concept to track like the old
  // single gl_control_accounts row had, since each role is its own row.
  const [postingRules, setPostingRules] = useState<Record<string, string>>({});
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

  const loadPostingRules = useCallback(async () => {
    const { data } = await supabase.from('gl_posting_rules').select('account_role, gl_account_id');
    const rows = (data ?? []) as Pick<PostingRuleRow, 'account_role' | 'gl_account_id'>[];
    const map = Object.fromEntries(rows.map((r) => [r.account_role, r.gl_account_id]));
    setPostingRules(map);
    setControlForm(Object.fromEntries(ALL_ROLES.map((f) => [f.key, map[f.key] ?? ''])));
  }, []);

  useEffect(() => {
    loadAccounts();
    loadPostingRules();
  }, [loadAccounts, loadPostingRules]);

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
    await loadPostingRules();
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

    const missing = REQUIRED_ROLES.filter((f) => !controlForm[f.key]);
    if (missing.length > 0) {
      setControlError(`Set an account for: ${missing.map((f) => f.label).join(', ')}.`);
      return;
    }

    setControlSaving(true);

    const tenantResult = await resolveTenantId(session);
    if (!tenantResult.ok) {
      setControlError(tenantResult.error);
      setControlSaving(false);
      return;
    }
    const tenant_id = tenantResult.tenantId;

    // Every role with a value set is upserted as its own gl_posting_rules
    // row (one row per role, not one row per tenant like the old
    // gl_control_accounts) -- onConflict on the (tenant_id, account_role)
    // unique constraint means re-mapping an already-mapped role just
    // updates that row instead of erroring.
    const toUpsert = ALL_ROLES.filter((f) => controlForm[f.key]).map((f) => ({
      tenant_id,
      account_role: f.key,
      gl_account_id: controlForm[f.key],
    }));

    let err;
    if (toUpsert.length > 0) {
      ({ error: err } = await supabase
        .from('gl_posting_rules')
        .upsert(toUpsert, { onConflict: 'tenant_id,account_role' }));
    }

    // An optional role that was previously mapped (present in
    // postingRules) but is now blank in the form means the user cleared
    // it -- delete that row rather than leaving a stale mapping behind.
    if (!err) {
      const toDelete = OPTIONAL_ROLES.filter((f) => postingRules[f.key] && !controlForm[f.key]).map((f) => f.key);
      if (toDelete.length > 0) {
        ({ error: err } = await supabase
          .from('gl_posting_rules')
          .delete()
          .eq('tenant_id', tenant_id)
          .in('account_role', toDelete));
      }
    }

    setControlSaving(false);

    if (err) {
      setControlError(err.message ?? 'Could not save the posting rules.');
      return;
    }

    setControlSavedAt(Date.now());
    loadPostingRules();
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
            Posting Rules
          </Typography>
          <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
            Supplier invoices, receivable invoices, and cash/bank transactions post to these accounts
            automatically. Until every field below is set, new transactions save normally but won't
            appear on the ledger.
          </Typography>
          <Divider sx={{ mb: 2 }} />
          <Box component="form" onSubmit={handleSaveControlAccounts} noValidate>
            <Stack direction="row" flexWrap="wrap" gap={2}>
              {REQUIRED_ROLES.map((f) => (
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
              {WHT_ROLES.map((f) => (
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
              {PAYROLL_ROLES.map((f) => (
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