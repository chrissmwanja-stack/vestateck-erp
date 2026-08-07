import { useCallback, useEffect, useMemo, useState, FormEvent } from 'react';
import {
  Alert,
  Autocomplete,
  Box,
  Button,
  Chip,
  CircularProgress,
  Divider,
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
import { Search as SearchIcon } from '@mui/icons-material';
import { supabase } from '../../lib/supabaseClient';

interface PettyCashFloatOption {
  petty_cash_float_id: string;
  float_name: string;
  cost_center_id: string;
  ceiling_amount: number;
  currency: string;
  is_active: boolean;
}

interface MovementRow {
  kind: 'replenishment' | 'expenditure';
  date: string;
  amount: number; // positive for replenishment, negative for expenditure
  reference: string; // slip number, or replenishment description/funded_from
  detail: string;
  recorded_by?: string;
}

interface ReportFilters {
  floatId: string;
  dateFrom: string;
  dateTo: string;
}

const emptyFilters: ReportFilters = { floatId: '', dateFrom: '', dateTo: '' };

export default function PettyCashRegister() {
  const [floats, setFloats] = useState<PettyCashFloatOption[]>([]);
  const [loadingFloats, setLoadingFloats] = useState(false);

  const [filters, setFilters] = useState<ReportFilters>(emptyFilters);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [openingBalance, setOpeningBalance] = useState<number | null>(null);
  const [movements, setMovements] = useState<MovementRow[]>([]);
  const [hasRun, setHasRun] = useState(false);

  const loadFloats = useCallback(async () => {
    setLoadingFloats(true);
    try {
      const { data, error: qErr } = await supabase
        .from('petty_cash_float_balances')
        .select('petty_cash_float_id, float_name, cost_center_id, ceiling_amount, currency, is_active')
        .order('float_name');
      if (qErr) throw qErr;
      setFloats((data ?? []) as PettyCashFloatOption[]);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed to load petty cash floats');
    } finally {
      setLoadingFloats(false);
    }
  }, []);

  useEffect(() => {
    loadFloats();
  }, [loadFloats]);

  const floatOptions = useMemo(
    () => floats.map((f) => ({ id: f.petty_cash_float_id, label: `${f.float_name}${f.is_active ? '' : ' (inactive)'}` })),
    [floats]
  );

  const selectedFloat = useMemo(
    () => floats.find((f) => f.petty_cash_float_id === filters.floatId) ?? null,
    [floats, filters.floatId]
  );

  async function handleRunReport(e: FormEvent) {
    e.preventDefault();
    if (!filters.floatId) {
      setError('Choose a petty cash float first.');
      return;
    }
    setError(null);
    setLoading(true);
    setHasRun(true);

    try {
      // Opening balance = everything posted strictly before dateFrom (if no
      // dateFrom is given, opening balance is 0 and the register shows the
      // float's entire history).
      let openingReplenished = 0;
      let openingSpent = 0;

      if (filters.dateFrom) {
        const [{ data: priorRepl }, { data: priorSlips }] = await Promise.all([
          supabase
            .from('petty_cash_replenishments')
            .select('amount')
            .eq('petty_cash_float_id', filters.floatId)
            .lt('replenished_date', filters.dateFrom),
          supabase
            .from('expenditure_slips')
            .select('amount')
            .eq('petty_cash_float_id', filters.floatId)
            .lt('slip_date', filters.dateFrom),
        ]);
        openingReplenished = (priorRepl ?? []).reduce((sum, r) => sum + Number(r.amount), 0);
        openingSpent = (priorSlips ?? []).reduce((sum, s) => sum + Number(s.amount), 0);
      }
      setOpeningBalance(openingReplenished - openingSpent);

      // Movements within the selected range (or everything, if no range set).
      let replQuery = supabase
        .from('petty_cash_replenishments')
        .select('amount, replenished_date, funded_from, bank_account, description, recorded_by_user:app_users!recorded_by(name)')
        .eq('petty_cash_float_id', filters.floatId)
        .order('replenished_date');
      if (filters.dateFrom) replQuery = replQuery.gte('replenished_date', filters.dateFrom);
      if (filters.dateTo) replQuery = replQuery.lte('replenished_date', filters.dateTo);

      let slipQuery = supabase
        .from('expenditure_slips')
        .select('amount, slip_date, slip_number, payee_name, purpose, recorded_by_user:app_users!recorded_by(name)')
        .eq('petty_cash_float_id', filters.floatId)
        .order('slip_date');
      if (filters.dateFrom) slipQuery = slipQuery.gte('slip_date', filters.dateFrom);
      if (filters.dateTo) slipQuery = slipQuery.lte('slip_date', filters.dateTo);

      const [{ data: repls, error: replErr }, { data: slips, error: slipErr }] = await Promise.all([replQuery, slipQuery]);
      if (replErr) throw replErr;
      if (slipErr) throw slipErr;

      const embedOne = <T,>(v: T | T[] | null | undefined): T | null => (Array.isArray(v) ? v[0] ?? null : v ?? null);

      const replMovements: MovementRow[] = (repls ?? []).map((r: any) => ({
        kind: 'replenishment',
        date: r.replenished_date,
        amount: Number(r.amount),
        reference: `Replenishment (${r.funded_from}${r.bank_account ? ` — ${r.bank_account}` : ''})`,
        detail: r.description ?? '—',
        recorded_by: embedOne(r.recorded_by_user)?.name ?? '—',
      }));

      const slipMovements: MovementRow[] = (slips ?? []).map((s: any) => ({
        kind: 'expenditure',
        date: s.slip_date,
        amount: -Number(s.amount),
        reference: `Slip ${s.slip_number} — ${s.payee_name}`,
        detail: s.purpose,
        recorded_by: embedOne(s.recorded_by_user)?.name ?? '—',
      }));

      const combined = [...replMovements, ...slipMovements].sort((a, b) => (a.date < b.date ? -1 : a.date > b.date ? 1 : 0));
      setMovements(combined);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed to build the register');
    } finally {
      setLoading(false);
    }
  }

  const closingBalance = useMemo(() => {
    if (openingBalance === null) return null;
    return movements.reduce((bal, m) => bal + m.amount, openingBalance);
  }, [openingBalance, movements]);

  let running = openingBalance ?? 0;

  return (
    <Box>
      <Typography variant="h5" sx={{ mb: 2 }}>
        Petty Cash Register
      </Typography>

      <Paper sx={{ p: 3, mb: 3 }} variant="outlined">
        <Box component="form" onSubmit={handleRunReport}>
          <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2} flexWrap="wrap">
            <Autocomplete
              options={floatOptions}
              loading={loadingFloats}
              sx={{ flex: 2, minWidth: 260 }}
              onChange={(_, option) => setFilters((f) => ({ ...f, floatId: option?.id ?? '' }))}
              value={floatOptions.find((o) => o.id === filters.floatId) ?? null}
              isOptionEqualToValue={(option, value) => option.id === value.id}
              renderInput={(params) => (
                <TextField
                  {...params}
                  label="Petty Cash Float"
                  required
                  InputProps={{
                    ...params.InputProps,
                    endAdornment: (
                      <>
                        {loadingFloats ? <CircularProgress color="inherit" size={16} /> : null}
                        {params.InputProps.endAdornment}
                      </>
                    ),
                  }}
                />
              )}
            />
            <TextField
              label="From"
              type="date"
              size="small"
              sx={{ flex: 1, minWidth: 160 }}
              InputLabelProps={{ shrink: true }}
              value={filters.dateFrom}
              onChange={(e) => setFilters((f) => ({ ...f, dateFrom: e.target.value }))}
              helperText="Leave blank to show full history"
            />
            <TextField
              label="To"
              type="date"
              size="small"
              sx={{ flex: 1, minWidth: 160 }}
              InputLabelProps={{ shrink: true }}
              value={filters.dateTo}
              onChange={(e) => setFilters((f) => ({ ...f, dateTo: e.target.value }))}
            />
          </Stack>
          <Stack direction="row" spacing={1} sx={{ mt: 2 }}>
            <Button type="submit" variant="contained" startIcon={<SearchIcon />} disabled={loading}>
              {loading ? 'Running…' : 'Run Register'}
            </Button>
          </Stack>
        </Box>
      </Paper>

      {error && (
        <Alert severity="error" sx={{ mb: 3 }}>
          {error}
        </Alert>
      )}

      {hasRun && !error && selectedFloat && openingBalance !== null && (
        <Paper sx={{ p: 2 }} variant="outlined">
          <Stack direction={{ xs: 'column', sm: 'row' }} justifyContent="space-between" alignItems={{ sm: 'center' }} spacing={1} sx={{ mb: 2 }}>
            <Typography variant="subtitle1" sx={{ fontWeight: 600 }}>
              {selectedFloat.float_name}
            </Typography>
            <Stack direction="row" spacing={2}>
              <Chip label={`Opening: ${openingBalance.toLocaleString()} ${selectedFloat.currency}`} />
              <Chip
                label={`Closing: ${closingBalance?.toLocaleString()} ${selectedFloat.currency}`}
                color={closingBalance !== null && closingBalance < selectedFloat.ceiling_amount * 0.2 ? 'warning' : 'default'}
              />
              <Chip variant="outlined" label={`Ceiling: ${selectedFloat.ceiling_amount.toLocaleString()} ${selectedFloat.currency}`} />
            </Stack>
          </Stack>
          <Divider sx={{ mb: 2 }} />

          {loading ? (
            <Box sx={{ display: 'flex', justifyContent: 'center', py: 4 }}>
              <CircularProgress size={24} />
            </Box>
          ) : (
            <TableContainer>
              <Table size="small">
                <TableHead>
                  <TableRow>
                    <TableCell>Date</TableCell>
                    <TableCell>Type</TableCell>
                    <TableCell>Reference</TableCell>
                    <TableCell>Detail</TableCell>
                    <TableCell>Recorded By</TableCell>
                    <TableCell align="right">Amount</TableCell>
                    <TableCell align="right">Running Balance</TableCell>
                  </TableRow>
                </TableHead>
                <TableBody>
                  <TableRow>
                    <TableCell colSpan={6} sx={{ fontStyle: 'italic', color: 'text.secondary' }}>
                      Opening balance
                    </TableCell>
                    <TableCell align="right" sx={{ fontStyle: 'italic', color: 'text.secondary' }}>
                      {openingBalance.toLocaleString()}
                    </TableCell>
                  </TableRow>
                  {movements.map((m, idx) => {
                    running += m.amount;
                    return (
                      <TableRow key={idx} hover>
                        <TableCell>{m.date}</TableCell>
                        <TableCell>
                          <Chip
                            size="small"
                            label={m.kind === 'replenishment' ? 'Replenishment' : 'Expenditure'}
                            color={m.kind === 'replenishment' ? 'success' : 'default'}
                          />
                        </TableCell>
                        <TableCell>{m.reference}</TableCell>
                        <TableCell>{m.detail}</TableCell>
                        <TableCell>{m.recorded_by}</TableCell>
                        <TableCell align="right">
                          {m.amount >= 0 ? '+' : ''}
                          {m.amount.toLocaleString()}
                        </TableCell>
                        <TableCell align="right">{running.toLocaleString()}</TableCell>
                      </TableRow>
                    );
                  })}
                  {movements.length === 0 && (
                    <TableRow>
                      <TableCell colSpan={7} align="center" sx={{ color: 'text.secondary', py: 3 }}>
                        No movements in this period.
                      </TableCell>
                    </TableRow>
                  )}
                  <TableRow>
                    <TableCell colSpan={6} sx={{ fontWeight: 600 }}>
                      Closing balance
                    </TableCell>
                    <TableCell align="right" sx={{ fontWeight: 600 }}>
                      {closingBalance?.toLocaleString()}
                    </TableCell>
                  </TableRow>
                </TableBody>
              </Table>
            </TableContainer>
          )}
        </Paper>
      )}
    </Box>
  );
}