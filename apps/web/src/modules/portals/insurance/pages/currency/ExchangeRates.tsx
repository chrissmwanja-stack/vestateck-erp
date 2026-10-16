import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Alert, Box, Button, Card, CardContent, CircularProgress, Dialog, DialogActions, DialogContent, DialogContentText,
  DialogTitle, Stack, Table, TableBody, TableCell, TableHead, TableRow, TextField, Typography, Chip,
} from '@mui/material';
import { errorText, rows, rpc, table, write } from '../../db';
import { useMyModuleAccess } from '../../../../../features/navigation/useMyModuleAccess';
import { supabase } from '../../../../../lib/supabaseClient';
import { EmptyRow, ErrorBanner, PageHeader } from '../../shared';
import {
  FX_STATUS_LABEL, canApproveFxRate, canWithdrawFxRate, formatFxRate, isValidFxWithdrawReason, localIsoDate,
  validateFxRateEntry, type FxRate, type FxRateInput,
} from '../../fx';

interface Lookup {
  currency: string;
  date: string;
  rate: FxRate | null;
  error: string | null;
}

const EMPTY_FORM: FxRateInput = { currency: '', rateDate: localIsoDate(), rate: '', source: '' };

// Exchange rates for the company. Rates are functional-currency units per 1 unit of the
// foreign currency. The server decides every rule (fx_rates_guard, fx_rate_approve,
// fx_rate_withdraw, fx_get_rate). This screen shows what each person may do and reports
// the server's refusal in plain words.
export default function ExchangeRates() {
  const access = useMyModuleAccess();
  const [userId, setUserId] = useState<string | null>(null);
  const [tenantId, setTenantId] = useState<string | null>(null);
  const [functional, setFunctional] = useState<string>('UGX');
  const [rates, setRates] = useState<FxRate[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const [form, setForm] = useState<FxRateInput>(EMPTY_FORM);
  const [formErrors, setFormErrors] = useState<Partial<Record<keyof FxRateInput, string>>>({});
  const [saving, setSaving] = useState(false);

  const [lookup, setLookup] = useState<Lookup | null>(null);
  const [lookupDate, setLookupDate] = useState(localIsoDate());
  const [lookupCurrency, setLookupCurrency] = useState('');

  const [withdrawing, setWithdrawing] = useState<FxRate | null>(null);
  const [reason, setReason] = useState('');
  const [busyId, setBusyId] = useState<string | null>(null);

  // Enter and approve: company admins and finance users. Withdraw: admins, or the enterer.
  const isCompanyAdmin = Boolean(access?.isCompanyAdmin || access?.isPlatformAdmin);
  const canEnter = isCompanyAdmin || Boolean(access?.canAccessFinance);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const [settings, list] = await Promise.all([
        rows<{ functional_currency: string }>(table('tenant_ledger_settings').select('functional_currency')),
        rows<FxRate>(table('fx_rates').select('*').order('rate_date', { ascending: false }).order('created_at', { ascending: false }).limit(200)),
      ]);
      setFunctional(settings[0]?.functional_currency ?? 'UGX');
      setRates(list);
      setError(null);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const { data } = await supabase.auth.getUser();
      const uid = data.user?.id ?? null;
      if (cancelled) return;
      setUserId(uid);
      if (uid) {
        const { data: me } = await table('app_users').select('tenant_id').eq('id', uid).maybeSingle();
        if (!cancelled) setTenantId((me as { tenant_id: string } | null)?.tenant_id ?? null);
      }
    })();
    load();
    return () => {
      cancelled = true;
    };
  }, [load]);

  const functionalUpper = functional.toUpperCase();
  const today = useMemo(() => localIsoDate(), []);

  const submit = async () => {
    const result = validateFxRateEntry(form, functional, today);
    if (!result.ok) {
      setFormErrors(result.errors);
      return;
    }
    if (!tenantId) {
      setError('Your company could not be identified. Sign out and back in, then try again.');
      return;
    }
    setSaving(true);
    try {
      await write(table('fx_rates').insert({ ...result.value, tenant_id: tenantId }));
      setForm({ ...EMPTY_FORM, rateDate: today });
      setFormErrors({});
      setNotice(`Draft rate for ${result.value.currency} saved. A different person must approve it before it is used.`);
      await load();
    } catch (e) {
      setError(errorText(e));
    } finally {
      setSaving(false);
    }
  };

  const approve = async (r: FxRate) => {
    setBusyId(r.id);
    try {
      await rpc('fx_rate_approve', { p_id: r.id });
      setNotice(`Approved ${r.currency} rate for ${r.rate_date}.`);
      await load();
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusyId(null);
    }
  };

  const confirmWithdraw = async () => {
    if (!withdrawing) return;
    setBusyId(withdrawing.id);
    try {
      await rpc('fx_rate_withdraw', { p_id: withdrawing.id, p_reason: reason.trim() });
      setNotice(`Withdrew the draft ${withdrawing.currency} rate for ${withdrawing.rate_date}.`);
      setWithdrawing(null);
      setReason('');
      await load();
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusyId(null);
    }
  };

  const runLookup = async () => {
    const currency = lookupCurrency.trim().toUpperCase();
    if (currency === functionalUpper) {
      setLookup({ currency, date: lookupDate, rate: null, error: `${currency} is the company's own currency. Its rate is always 1.` });
      return;
    }
    try {
      const rate = await rpc<FxRate>('fx_get_rate', { p_currency: currency, p_on: lookupDate });
      setLookup({ currency, date: lookupDate, rate, error: null });
    } catch (e) {
      setLookup({ currency, date: lookupDate, rate: null, error: errorText(e) });
    }
  };

  if (loading) return <Box sx={{ p: 3, display: 'flex', justifyContent: 'center' }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <PageHeader
        title="Exchange rates"
        subtitle={`Company currency: ${functionalUpper}. Rates are ${functionalUpper} per 1 unit of the foreign currency.`}
      />
      <ErrorBanner message={error} />
      {notice && <Alert severity="success" onClose={() => setNotice(null)} sx={{ mb: 2 }}>{notice}</Alert>}

      {!canEnter && (
        <Alert severity="info" sx={{ mb: 2 }}>
          Only company admins and finance users can enter or approve rates. You can look up approved rates below.
        </Alert>
      )}

      <Card sx={{ mb: 2 }}>
        <CardContent>
          <Typography variant="subtitle1" fontWeight={600} gutterBottom>Look up the rate on a date</Typography>
          <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2} alignItems="flex-start">
            <TextField
              label="Currency to look up" size="small" value={lookupCurrency} placeholder="USD"
              onChange={(e) => setLookupCurrency(e.target.value)} inputProps={{ maxLength: 3 }}
            />
            <TextField
              label="Date" type="date" size="small" value={lookupDate} InputLabelProps={{ shrink: true }}
              onChange={(e) => setLookupDate(e.target.value)} inputProps={{ max: today }}
            />
            <Button variant="outlined" onClick={runLookup} disabled={lookupCurrency.trim() === ''}>Look up</Button>
          </Stack>
          {lookup && (
            <Box sx={{ mt: 2 }}>
              {lookup.error ? (
                <Alert severity="warning">{lookup.error}</Alert>
              ) : lookup.rate ? (
                <Typography>
                  1 {lookup.currency} = <strong>{formatFxRate(lookup.rate.rate)} {functionalUpper}</strong> on {lookup.date}
                  {' '}(rate dated {lookup.rate.rate_date}, source: {lookup.rate.source}).
                </Typography>
              ) : null}
            </Box>
          )}
        </CardContent>
      </Card>

      {canEnter && (
        <Card sx={{ mb: 2 }}>
          <CardContent>
            <Typography variant="subtitle1" fontWeight={600} gutterBottom>Enter a rate</Typography>
            <Typography variant="body2" color="text.secondary" gutterBottom>
              The rate is saved as a draft. Another person approves it before any transaction uses it. Once approved or withdrawn, a rate cannot be edited; enter a correct rate instead.
            </Typography>
            <Stack direction={{ xs: 'column', md: 'row' }} spacing={2} sx={{ mt: 1 }} alignItems="flex-start">
              <TextField
                label="Currency" size="small" value={form.currency} placeholder="USD"
                error={Boolean(formErrors.currency)} helperText={formErrors.currency}
                onChange={(e) => setForm({ ...form, currency: e.target.value })} inputProps={{ maxLength: 3 }}
              />
              <TextField
                label="Rate date" type="date" size="small" value={form.rateDate} InputLabelProps={{ shrink: true }}
                error={Boolean(formErrors.rateDate)} helperText={formErrors.rateDate}
                onChange={(e) => setForm({ ...form, rateDate: e.target.value })} inputProps={{ max: today }}
              />
              <TextField
                label={`Rate (${functionalUpper} per 1 unit)`} size="small" value={form.rate}
                error={Boolean(formErrors.rate)} helperText={formErrors.rate}
                onChange={(e) => setForm({ ...form, rate: e.target.value })} inputMode="decimal"
              />
              <TextField
                label="Source" size="small" value={form.source} fullWidth
                error={Boolean(formErrors.source)} helperText={formErrors.source}
                onChange={(e) => setForm({ ...form, source: e.target.value })}
              />
              <Button variant="contained" onClick={submit} disabled={saving} sx={{ whiteSpace: 'nowrap' }}>
                {saving ? 'Saving…' : 'Save draft'}
              </Button>
            </Stack>
          </CardContent>
        </Card>
      )}

      <Card>
        <CardContent sx={{ p: 0 }}>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>Currency</TableCell>
                <TableCell>Date</TableCell>
                <TableCell align="right">Rate</TableCell>
                <TableCell>Source</TableCell>
                <TableCell>Status</TableCell>
                <TableCell>Entered by</TableCell>
                <TableCell align="right">Actions</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {rates.length === 0 ? (
                <EmptyRow colSpan={7} text="No rates yet. Enter the first rate above." />
              ) : rates.map((r) => {
                const mine = userId !== null && r.entered_by === userId;
                return (
                  <TableRow key={r.id} hover>
                    <TableCell>{r.currency}</TableCell>
                    <TableCell>{r.rate_date}</TableCell>
                    <TableCell align="right">{formatFxRate(r.rate)}</TableCell>
                    <TableCell>{r.source}</TableCell>
                    <TableCell>
                      <Chip size="small" label={FX_STATUS_LABEL[r.status]} color={r.status === 'approved' ? 'success' : r.status === 'withdrawn' ? 'default' : 'warning'} />
                      {r.status === 'withdrawn' && r.withdrawn_reason && (
                        <Typography variant="caption" display="block" color="text.secondary">{r.withdrawn_reason}</Typography>
                      )}
                    </TableCell>
                    <TableCell>{mine ? 'You' : r.entered_by ? 'Another user' : '—'}</TableCell>
                    <TableCell align="right">
                      <Stack direction="row" spacing={1} justifyContent="flex-end">
                        {canApproveFxRate(r, userId, canEnter) && (
                          <Button size="small" variant="contained" disabled={busyId === r.id} onClick={() => approve(r)}>Approve</Button>
                        )}
                        {canWithdrawFxRate(r, userId, isCompanyAdmin) && (
                          <Button size="small" color="error" disabled={busyId === r.id} onClick={() => { setWithdrawing(r); setReason(''); }}>Withdraw</Button>
                        )}
                      </Stack>
                    </TableCell>
                  </TableRow>
                );
              })}
            </TableBody>
          </Table>
        </CardContent>
      </Card>

      <Dialog open={withdrawing !== null} onClose={() => setWithdrawing(null)} fullWidth maxWidth="xs">
        <DialogTitle>Withdraw this draft rate?</DialogTitle>
        <DialogContent>
          <DialogContentText sx={{ mb: 2 }}>
            {withdrawing && `${withdrawing.currency} rate of ${formatFxRate(withdrawing.rate)} dated ${withdrawing.rate_date}. Withdrawn rates cannot be restored; enter a new one if needed.`}
          </DialogContentText>
          <TextField
            label="Reason" fullWidth size="small" value={reason} onChange={(e) => setReason(e.target.value)}
            helperText="At least five characters." autoFocus
          />
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setWithdrawing(null)}>Cancel</Button>
          <Button color="error" variant="contained" disabled={!isValidFxWithdrawReason(reason) || busyId !== null} onClick={confirmWithdraw}>
            Withdraw
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}
