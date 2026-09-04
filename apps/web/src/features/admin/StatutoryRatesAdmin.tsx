import { useCallback, useEffect, useState, FormEvent } from 'react';
import {
  Alert,
  Box,
  Button,
  Chip,
  CircularProgress,
  Dialog,
  DialogActions,
  DialogContent,
  DialogContentText,
  DialogTitle,
  Divider,
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
import { Add as AddIcon, PlaylistAdd as PlaylistAddIcon } from '@mui/icons-material';
import type { Database } from '@erp-platform/shared';
import { supabase } from '../../lib/supabaseClient';
import { useAuth } from '../../lib/authContext';
import { resolveTenantId } from '../../lib/ResolveTenantId';

type RateType = 'paye' | 'nssf_employee' | 'nssf_employer';
type RateInsert = Database['public']['Tables']['statutory_rate_tables']['Insert'];

interface RateRow {
  id: string;
  rate_type: RateType;
  effective_date: string;
  band_order: number;
  lower_bound: number;
  upper_bound: number | null;
  rate: number;
  base_tax: number;
}

const RATE_TYPE_LABEL: Record<RateType, string> = {
  paye: 'PAYE',
  nssf_employee: 'NSSF (Employee)',
  nssf_employer: 'NSSF (Employer)',
};

const emptyForm = {
  rate_type: 'paye' as RateType,
  effective_date: '',
  band_order: '1',
  lower_bound: '0',
  upper_bound: '',
  rate: '',
  base_tax: '0',
};

function formatUgx(n: number) {
  return `UGX ${Math.round(n).toLocaleString()}`;
}

export default function StatutoryRatesAdmin() {
  const { session } = useAuth();
  const [rows, setRows] = useState<RateRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [seedConfirmOpen, setSeedConfirmOpen] = useState(false);
  const [seedDate, setSeedDate] = useState('');
  const [seeding, setSeeding] = useState(false);
  const [seedError, setSeedError] = useState<string | null>(null);

  const [showForm, setShowForm] = useState(false);
  const [form, setForm] = useState(emptyForm);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const { data, error: err } = await supabase
      .from('statutory_rate_tables')
      .select('id, rate_type, effective_date, band_order, lower_bound, upper_bound, rate, base_tax')
      .order('effective_date', { ascending: false })
      .order('rate_type')
      .order('band_order');
    if (err) setError(err.message);
    else setRows((data ?? []) as RateRow[]);
    setLoading(false);
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  function openSeedConfirm() {
    setSeedError(null);
    setSeedDate(new Date().toISOString().slice(0, 10));
    setSeedConfirmOpen(true);
  }

  async function handleSeed() {
    setSeeding(true);
    setSeedError(null);
    const { error: err } = await supabase.rpc('seed_statutory_rate_table', {
      p_effective_date: seedDate || undefined,
    });
    setSeeding(false);
    if (err) {
      setSeedError(err.message ?? 'Could not seed the rate table.');
      return;
    }
    setSeedConfirmOpen(false);
    load();
  }

  function openNewRow() {
    setSaveError(null);
    setForm({ ...emptyForm, effective_date: new Date().toISOString().slice(0, 10) });
    setShowForm(true);
  }

  async function handleSave(e: FormEvent) {
    e.preventDefault();
    setSaveError(null);

    if (!form.effective_date) {
      setSaveError('Effective date is required.');
      return;
    }
    if (form.rate === '' || Number.isNaN(Number(form.rate))) {
      setSaveError('Rate is required.');
      return;
    }

    setSaving(true);
    const tenantResult = await resolveTenantId(session);
    if (!tenantResult.ok) {
      setSaveError(tenantResult.error);
      setSaving(false);
      return;
    }

    const payload: RateInsert = {
      tenant_id: tenantResult.tenantId,
      rate_type: form.rate_type,
      effective_date: form.effective_date,
      band_order: Number(form.band_order) || 1,
      lower_bound: Number(form.lower_bound) || 0,
      upper_bound: form.upper_bound === '' ? null : Number(form.upper_bound),
      rate: Number(form.rate),
      base_tax: Number(form.base_tax) || 0,
    };

    const { error: err } = await supabase.from('statutory_rate_tables').insert(payload);
    setSaving(false);

    if (err) {
      setSaveError(err.message ?? 'Could not save the rate. Try again.');
      return;
    }

    setShowForm(false);
    setForm(emptyForm);
    load();
  }

  const hasRates = rows.length > 0;

  return (
    <Box sx={{ maxWidth: 1000 }}>
      <Stack direction="row" justifyContent="space-between" alignItems="center" sx={{ mb: 2 }}>
        <Typography variant="h5">Statutory Rates (PAYE / NSSF)</Typography>
        <Stack direction="row" spacing={1}>
          {!hasRates && !loading && (
            <Button variant="outlined" startIcon={<PlaylistAddIcon />} onClick={openSeedConfirm}>
              Seed Starter Rates
            </Button>
          )}
          <Button variant="contained" startIcon={<AddIcon />} onClick={openNewRow}>
            Add Rate Row
          </Button>
        </Stack>
      </Stack>

      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
        calculate_statutory_deductions() reads the row here whose effective_date is on or before a
        payslip's date, so a Finance Act change is handled by adding a new effective-dated row here --
        not a code deploy. Existing rows for past dates are left as history.
      </Typography>

      <Alert severity="warning" sx={{ mb: 3 }}>
        <strong>PAYE bands are not confirmed against an authoritative source.</strong> URA's own published
        PAYE page (ura.go.ug) and the various news/payroll-calculator write-ups of the 2026 Income Tax
        (Amendment) Act disagree with each other on the exact band boundaries and rates above the
        335,000 threshold, and on whether the effective top rate above UGX 10,000,000/month is a flat
        30% or 30%+10% surcharge (40% effective) -- this schema currently can't represent a surcharge on
        top of a band rate in one row. Confirm the enacted band structure directly with URA, or against
        the gazetted Finance Act text, before relying on this for a live payroll run. NSSF (5% employee /
        10% employer) and WHT (6% over UGX 1,000,000, tracked on supplier invoices, not here) are
        confirmed against URA's site.
      </Alert>

      {error && <Alert severity="error" sx={{ mb: 2 }}>{error}</Alert>}

      {!hasRates && !loading && (
        <Alert severity="info" sx={{ mb: 3 }}>
          No statutory rates set up yet. Payroll will still generate line items, but PAYE and NSSF will
          compute as zero until rates exist for the relevant date -- either seed a starter set (see the
          warning above before trusting the PAYE numbers) or add rows manually.
        </Alert>
      )}

      {showForm && (
        <Paper sx={{ p: 3, mb: 3 }} variant="outlined">
          <Typography variant="subtitle1" sx={{ fontWeight: 600, mb: 2 }}>
            New Rate Row
          </Typography>
          <Box component="form" onSubmit={handleSave} noValidate>
            <Stack spacing={2.5}>
              <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2}>
                <TextField
                  select
                  label="Type"
                  required
                  sx={{ flex: 1 }}
                  value={form.rate_type}
                  onChange={(e) => setForm((v) => ({ ...v, rate_type: e.target.value as RateType }))}
                >
                  <MenuItem value="paye">PAYE band</MenuItem>
                  <MenuItem value="nssf_employee">NSSF (Employee) -- flat rate</MenuItem>
                  <MenuItem value="nssf_employer">NSSF (Employer) -- flat rate</MenuItem>
                </TextField>
                <TextField
                  label="Effective Date"
                  type="date"
                  required
                  sx={{ flex: 1 }}
                  value={form.effective_date}
                  onChange={(e) => setForm((v) => ({ ...v, effective_date: e.target.value }))}
                  InputLabelProps={{ shrink: true }}
                />
                {form.rate_type === 'paye' && (
                  <TextField
                    label="Band Order"
                    type="number"
                    sx={{ flex: 1 }}
                    value={form.band_order}
                    onChange={(e) => setForm((v) => ({ ...v, band_order: e.target.value }))}
                    helperText="1 = lowest band"
                  />
                )}
              </Stack>

              {form.rate_type === 'paye' && (
                <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2}>
                  <TextField
                    label="Lower Bound (UGX)"
                    type="number"
                    sx={{ flex: 1 }}
                    value={form.lower_bound}
                    onChange={(e) => setForm((v) => ({ ...v, lower_bound: e.target.value }))}
                  />
                  <TextField
                    label="Upper Bound (UGX)"
                    type="number"
                    sx={{ flex: 1 }}
                    value={form.upper_bound}
                    onChange={(e) => setForm((v) => ({ ...v, upper_bound: e.target.value }))}
                    helperText="Blank = no upper limit (top band)"
                  />
                  <TextField
                    label="Base Tax (UGX)"
                    type="number"
                    sx={{ flex: 1 }}
                    value={form.base_tax}
                    onChange={(e) => setForm((v) => ({ ...v, base_tax: e.target.value }))}
                    helperText="Cumulative tax from lower bands"
                  />
                </Stack>
              )}

              <TextField
                label="Rate (%)"
                type="number"
                required
                sx={{ maxWidth: 240 }}
                value={form.rate}
                onChange={(e) => setForm((v) => ({ ...v, rate: e.target.value }))}
              />

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
        </Paper>
      )}

      <Paper variant="outlined">
        {loading ? (
          <Box display="flex" justifyContent="center" py={4}>
            <CircularProgress size={24} />
          </Box>
        ) : (
          <TableContainer>
            <Table size="small">
              <TableHead>
                <TableRow>
                  <TableCell>Type</TableCell>
                  <TableCell>Effective Date</TableCell>
                  <TableCell align="right">Band</TableCell>
                  <TableCell align="right">Lower Bound</TableCell>
                  <TableCell align="right">Upper Bound</TableCell>
                  <TableCell align="right">Rate</TableCell>
                  <TableCell align="right">Base Tax</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {rows.map((row) => (
                  <TableRow key={row.id} hover>
                    <TableCell>
                      <Chip size="small" label={RATE_TYPE_LABEL[row.rate_type]} />
                    </TableCell>
                    <TableCell>{row.effective_date}</TableCell>
                    <TableCell align="right">{row.rate_type === 'paye' ? row.band_order : '—'}</TableCell>
                    <TableCell align="right">
                      {row.rate_type === 'paye' ? formatUgx(row.lower_bound) : '—'}
                    </TableCell>
                    <TableCell align="right">
                      {row.rate_type === 'paye' ? (row.upper_bound === null ? 'No limit' : formatUgx(row.upper_bound)) : '—'}
                    </TableCell>
                    <TableCell align="right">{row.rate}%</TableCell>
                    <TableCell align="right">
                      {row.rate_type === 'paye' && row.base_tax > 0 ? formatUgx(row.base_tax) : '—'}
                    </TableCell>
                  </TableRow>
                ))}
                {rows.length === 0 && (
                  <TableRow>
                    <TableCell colSpan={7} align="center" sx={{ color: 'text.secondary', py: 3 }}>
                      No rate rows yet.
                    </TableCell>
                  </TableRow>
                )}
              </TableBody>
            </Table>
          </TableContainer>
        )}
      </Paper>

      <Dialog open={seedConfirmOpen} onClose={() => !seeding && setSeedConfirmOpen(false)} maxWidth="xs" fullWidth>
        <DialogTitle>Seed starter rates?</DialogTitle>
        <DialogContent>
          <DialogContentText sx={{ mb: 2 }}>
            This inserts the 4-band PAYE schedule and the NSSF 5%/10% flat rates described in the warning
            above, effective from the date you choose. <strong>The PAYE numbers are unconfirmed</strong> --
            only do this as a placeholder, or once you've verified the bands yourself.
          </DialogContentText>
          <TextField
            label="Effective Date"
            type="date"
            fullWidth
            value={seedDate}
            onChange={(e) => setSeedDate(e.target.value)}
            InputLabelProps={{ shrink: true }}
          />
          {seedError && (
            <Alert severity="error" sx={{ mt: 2 }}>
              {seedError}
            </Alert>
          )}
        </DialogContent>
        <Divider />
        <DialogActions>
          <Button onClick={() => setSeedConfirmOpen(false)} disabled={seeding}>
            Cancel
          </Button>
          <Button onClick={handleSeed} variant="contained" disabled={seeding}>
            {seeding ? 'Seeding…' : 'Seed Starter Rates'}
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}