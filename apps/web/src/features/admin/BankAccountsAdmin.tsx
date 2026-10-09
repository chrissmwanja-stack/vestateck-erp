import { useCallback, useEffect, useState, FormEvent } from 'react';
import type { SupabaseClient } from '@supabase/supabase-js';
import {
  Alert,
  Box,
  Button,
  Chip,
  CircularProgress,
  Dialog,
  DialogActions,
  DialogContent,
  DialogTitle,
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
import { Add as AddIcon, AccountBalance as AccountBalanceIcon, Edit as EditIcon } from '@mui/icons-material';
import { supabase } from '../../lib/supabaseClient';
import { useAuth } from '../../lib/authContext';
import { resolveTenantId } from '../../lib/ResolveTenantId';

// fin_bank_accounts and fin_unregistered_bank_accounts (D4a) are not in
// the generated database.types.ts yet, so this screen talks to them
// through an untyped handle. Move back to `supabase` once types are
// regenerated.
const db = supabase as unknown as SupabaseClient;

type Kind = 'operating' | 'client_money';

interface BankAccountRow {
  id: string;
  name: string;
  kind: Kind;
  currency: string;
  gl_account_id: string | null;
  bank_name: string | null;
  account_number: string | null;
  is_active: boolean;
}

interface GlAccountOption {
  id: string;
  account_code: string;
  name: string;
}

interface UnregisteredRow {
  name: string;
  row_count: number;
  sources: string[] | null;
  last_seen_on: string | null;
}

interface FormState {
  name: string;
  kind: Kind;
  currency: string;
  gl_account_id: string;
  bank_name: string;
  account_number: string;
}

const emptyForm: FormState = {
  name: '',
  kind: 'operating',
  currency: 'UGX',
  gl_account_id: '',
  bank_name: '',
  account_number: '',
};

const KIND_LABEL: Record<Kind, string> = { operating: 'Operating', client_money: 'Client money' };

// The guard trigger raises messages like "BANK_ACCOUNT_SEGREGATION: GL
// account 1010 is ..."; the code prefix is for logs, not for the person
// reading the dialog.
const friendlyError = (message: string | undefined, fallback: string) =>
  (message ?? fallback).replace(/^[A-Z][A-Z0-9_]+:\s*/, '');

export default function BankAccountsAdmin() {
  const { session } = useAuth();
  const [canWrite, setCanWrite] = useState<boolean | null>(null);
  const [accounts, setAccounts] = useState<BankAccountRow[]>([]);
  const [glAccounts, setGlAccounts] = useState<GlAccountOption[]>([]);
  const [unregistered, setUnregistered] = useState<UnregisteredRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [dialogOpen, setDialogOpen] = useState(false);
  const [editing, setEditing] = useState<BankAccountRow | null>(null);
  const [form, setForm] = useState<FormState>(emptyForm);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);

  useEffect(() => {
    supabase.rpc('is_finance_team_member', { p_role: 'finance' }).then(({ data, error: err }) =>
      setCanWrite(err ? false : Boolean(data))
    );
  }, []);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const [acc, gl, unreg] = await Promise.all([
      db
        .from('fin_bank_accounts')
        .select('id, name, kind, currency, gl_account_id, bank_name, account_number, is_active')
        .order('name'),
      db.from('gl_accounts').select('id, account_code, name').eq('account_type', 'asset').eq('is_active', true).order('account_code'),
      db.from('fin_unregistered_bank_accounts').select('name, row_count, sources, last_seen_on').order('name'),
    ]);
    const firstError = acc.error ?? gl.error ?? unreg.error;
    if (firstError) {
      setError(firstError.message);
    } else {
      setAccounts((acc.data ?? []) as BankAccountRow[]);
      setGlAccounts((gl.data ?? []) as GlAccountOption[]);
      setUnregistered((unreg.data ?? []) as UnregisteredRow[]);
    }
    setLoading(false);
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const glLabel = (id: string | null) => {
    if (!id) return null;
    const g = glAccounts.find((a) => a.id === id);
    return g ? `${g.account_code} — ${g.name}` : 'Mapped (inactive or non-asset account)';
  };

  function openNew(prefillName = '') {
    setSaveError(null);
    setEditing(null);
    setForm({ ...emptyForm, name: prefillName });
    setDialogOpen(true);
  }

  function openEdit(row: BankAccountRow) {
    setSaveError(null);
    setEditing(row);
    setForm({
      name: row.name,
      kind: row.kind,
      currency: row.currency,
      gl_account_id: row.gl_account_id ?? '',
      bank_name: row.bank_name ?? '',
      account_number: row.account_number ?? '',
    });
    setDialogOpen(true);
  }

  async function handleSave(e: FormEvent) {
    e.preventDefault();
    setSaveError(null);

    const name = form.name.trim();
    const currency = form.currency.trim().toUpperCase();
    if (!editing && !name) {
      setSaveError('A name is required. Use the exact text your bank statements and cash/bank transactions use.');
      return;
    }
    if (!/^[A-Z]{3}$/.test(currency)) {
      setSaveError('Currency must be a three-letter code such as UGX.');
      return;
    }
    if (form.kind === 'client_money' && !form.gl_account_id) {
      setSaveError('A client money account needs its own GL account.');
      return;
    }

    setSaving(true);

    if (editing) {
      // name, kind and a mapped GL account are immutable (guard trigger),
      // so they are never part of an update payload.
      const payload: Record<string, unknown> = {
        currency,
        bank_name: form.bank_name.trim() || null,
        account_number: form.account_number.trim() || null,
      };
      if (!editing.gl_account_id && form.gl_account_id) payload.gl_account_id = form.gl_account_id;
      const { error: err } = await db.from('fin_bank_accounts').update(payload).eq('id', editing.id);
      setSaving(false);
      if (err) {
        setSaveError(friendlyError(err.message, 'Could not save the bank account. Try again.'));
        return;
      }
    } else {
      const tenantResult = await resolveTenantId(session);
      if (!tenantResult.ok) {
        setSaveError(tenantResult.error);
        setSaving(false);
        return;
      }
      const { error: err } = await db.from('fin_bank_accounts').insert({
        tenant_id: tenantResult.tenantId,
        name,
        kind: form.kind,
        currency,
        gl_account_id: form.gl_account_id || null,
        bank_name: form.bank_name.trim() || null,
        account_number: form.account_number.trim() || null,
      });
      setSaving(false);
      if (err) {
        setSaveError(
          err.message.includes('duplicate key')
            ? `A bank account named "${name}" already exists.`
            : friendlyError(err.message, 'Could not save the bank account. Try again.')
        );
        return;
      }
    }

    setDialogOpen(false);
    setEditing(null);
    load();
  }

  async function handleToggleActive(row: BankAccountRow) {
    setError(null);
    const { error: err } = await db.from('fin_bank_accounts').update({ is_active: !row.is_active }).eq('id', row.id);
    if (err) {
      setError(friendlyError(err.message, 'Could not update the bank account.'));
      return;
    }
    load();
  }

  const mappedGlLocked = Boolean(editing?.gl_account_id);

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <Stack direction="row" alignItems="center" justifyContent="space-between" sx={{ mb: 1 }}>
        <Typography variant="h5" sx={{ display: 'flex', alignItems: 'center', gap: 1 }}>
          <AccountBalanceIcon /> Bank Accounts
        </Typography>
        <Button variant="contained" startIcon={<AddIcon />} onClick={() => openNew()} disabled={canWrite !== true}>
          Add Bank Account
        </Button>
      </Stack>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        The registry of your bank accounts. The name must match the text on your bank statements and cash/bank
        transactions exactly. Each account maps to a GL asset account, and client money and operating money never share
        one. Accounts are never deleted — deactivate them instead.
      </Typography>

      {canWrite === false && (
        <Alert severity="info" sx={{ mb: 2 }}>
          Viewing only. Adding or changing bank accounts needs the finance role.
        </Alert>
      )}
      {error && <Alert severity="error" sx={{ mb: 2 }} onClose={() => setError(null)}>{error}</Alert>}

      {loading ? (
        <Box display="flex" justifyContent="center" py={4}>
          <CircularProgress size={24} />
        </Box>
      ) : (
        <>
          {unregistered.length > 0 && (
            <Paper sx={{ p: 2, mb: 3 }} data-testid="unregistered-panel">
              <Typography variant="subtitle1" sx={{ mb: 0.5 }}>
                Names in use but not registered ({unregistered.length})
              </Typography>
              <Typography variant="body2" color="text.secondary" sx={{ mb: 1.5 }}>
                These appear on statements or cash/bank transactions. Register each so settlements and the
                reconciliation position work for it.
              </Typography>
              <Table size="small">
                <TableHead>
                  <TableRow>
                    <TableCell>Name</TableCell>
                    <TableCell align="right">Rows</TableCell>
                    <TableCell>Last seen</TableCell>
                    <TableCell />
                  </TableRow>
                </TableHead>
                <TableBody>
                  {unregistered.map((u) => (
                    <TableRow key={u.name}>
                      <TableCell>{u.name}</TableCell>
                      <TableCell align="right">{u.row_count}</TableCell>
                      <TableCell>{u.last_seen_on ?? '—'}</TableCell>
                      <TableCell align="right">
                        <Button size="small" onClick={() => openNew(u.name)} disabled={canWrite !== true}>
                          Register
                        </Button>
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </Paper>
          )}

          <TableContainer component={Paper}>
            <Table size="small">
              <TableHead>
                <TableRow>
                  <TableCell>Name</TableCell>
                  <TableCell>Type</TableCell>
                  <TableCell>Currency</TableCell>
                  <TableCell>GL account</TableCell>
                  <TableCell>Bank details</TableCell>
                  <TableCell>Status</TableCell>
                  <TableCell />
                </TableRow>
              </TableHead>
              <TableBody>
                {accounts.map((a) => (
                  <TableRow key={a.id} sx={{ opacity: a.is_active ? 1 : 0.6 }}>
                    <TableCell>{a.name}</TableCell>
                    <TableCell>
                      <Chip size="small" label={KIND_LABEL[a.kind]} color={a.kind === 'client_money' ? 'warning' : 'default'} />
                    </TableCell>
                    <TableCell>{a.currency}</TableCell>
                    <TableCell>
                      {glLabel(a.gl_account_id) ?? (
                        <Typography variant="body2" color="warning.main">
                          Not mapped
                        </Typography>
                      )}
                    </TableCell>
                    <TableCell>
                      {[a.bank_name, a.account_number].filter(Boolean).join(' · ') || '—'}
                    </TableCell>
                    <TableCell>{a.is_active ? 'Active' : 'Inactive'}</TableCell>
                    <TableCell align="right">
                      <Button size="small" startIcon={<EditIcon />} onClick={() => openEdit(a)} disabled={canWrite !== true}>
                        Edit
                      </Button>
                      <Button size="small" onClick={() => handleToggleActive(a)} disabled={canWrite !== true}>
                        {a.is_active ? 'Deactivate' : 'Activate'}
                      </Button>
                    </TableCell>
                  </TableRow>
                ))}
                {accounts.length === 0 && (
                  <TableRow>
                    <TableCell colSpan={7} align="center" sx={{ color: 'text.secondary', py: 3 }}>
                      No bank accounts registered yet.
                    </TableCell>
                  </TableRow>
                )}
              </TableBody>
            </Table>
          </TableContainer>
        </>
      )}

      <Dialog open={dialogOpen} onClose={() => !saving && setDialogOpen(false)} maxWidth="sm" fullWidth>
        <form onSubmit={handleSave}>
          <DialogTitle>{editing ? `Edit ${editing.name}` : 'Add Bank Account'}</DialogTitle>
          <DialogContent>
            <Stack spacing={2} sx={{ mt: 1 }}>
              <TextField
                label="Name"
                size="small"
                value={form.name}
                onChange={(e) => setForm({ ...form, name: e.target.value })}
                disabled={Boolean(editing)}
                helperText={
                  editing
                    ? 'The name links this account to its statements and transactions and cannot change.'
                    : 'Exactly as it appears on statements and cash/bank transactions, e.g. Stanbic-001.'
                }
                required
              />
              <TextField
                select
                label="Type"
                size="small"
                value={form.kind}
                onChange={(e) => setForm({ ...form, kind: e.target.value as Kind })}
                disabled={Boolean(editing)}
                helperText={editing ? 'The type cannot change; deactivate this account and register a new one.' : undefined}
              >
                <MenuItem value="operating">Operating</MenuItem>
                <MenuItem value="client_money">Client money</MenuItem>
              </TextField>
              <TextField
                label="Currency"
                size="small"
                value={form.currency}
                onChange={(e) => setForm({ ...form, currency: e.target.value })}
                inputProps={{ maxLength: 3 }}
              />
              <TextField
                select
                label="GL account"
                size="small"
                value={form.gl_account_id}
                onChange={(e) => setForm({ ...form, gl_account_id: e.target.value })}
                disabled={mappedGlLocked}
                helperText={
                  mappedGlLocked
                    ? 'A mapped GL account cannot be changed; deactivate this account and register a new one.'
                    : form.kind === 'client_money'
                      ? 'Required. Must be a separate asset account used by no operating bank account.'
                      : 'Asset account. Settlements cannot post to this bank account until it is mapped.'
                }
              >
                <MenuItem value="">
                  <em>Not mapped yet</em>
                </MenuItem>
                {glAccounts.map((g) => (
                  <MenuItem key={g.id} value={g.id}>
                    {g.account_code} — {g.name}
                  </MenuItem>
                ))}
              </TextField>
              <TextField
                label="Bank name"
                size="small"
                value={form.bank_name}
                onChange={(e) => setForm({ ...form, bank_name: e.target.value })}
              />
              <TextField
                label="Account number"
                size="small"
                value={form.account_number}
                onChange={(e) => setForm({ ...form, account_number: e.target.value })}
              />
              {saveError && <Alert severity="error">{saveError}</Alert>}
            </Stack>
          </DialogContent>
          <DialogActions>
            <Button onClick={() => setDialogOpen(false)} disabled={saving}>
              Cancel
            </Button>
            <Button type="submit" variant="contained" disabled={saving}>
              {saving ? 'Saving…' : 'Save'}
            </Button>
          </DialogActions>
        </form>
      </Dialog>
    </Box>
  );
}
