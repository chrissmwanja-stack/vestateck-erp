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
import { Add as AddIcon, Lock as LockIcon, LockOpen as LockOpenIcon } from '@mui/icons-material';
import type { Database } from '@erp-platform/shared';
import { supabase } from '../../lib/supabaseClient';
import { useAuth } from '../../lib/authContext';
import { resolveTenantId } from '../../lib/ResolveTenantId';

type PeriodInsert = Database['public']['Tables']['accounting_periods']['Insert'];

interface PeriodRow {
  id: string;
  period_start: string;
  period_end: string;
  status: string;
  closed_at: string | null;
  closed_by: string | null;
}

const emptyForm = { period_start: '', period_end: '' };

export default function AccountingPeriodsAdmin() {
  const { session } = useAuth();
  const [rows, setRows] = useState<PeriodRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [showForm, setShowForm] = useState(false);
  const [form, setForm] = useState(emptyForm);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);

  // Closing (and reopening) a period changes what can be posted, so it
  // gets a confirmation dialog rather than firing straight from the
  // table row -- same "closing forces a review" idea as the original
  // Workstream B plan, just as a dialog instead of a dedicated screen.
  const [confirmTarget, setConfirmTarget] = useState<PeriodRow | null>(null);
  const [confirmSaving, setConfirmSaving] = useState(false);
  const [confirmError, setConfirmError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const { data, error: err } = await supabase
      .from('accounting_periods')
      .select('id, period_start, period_end, status, closed_at, closed_by')
      .order('period_start', { ascending: false });
    if (err) setError(err.message);
    else setRows((data ?? []) as PeriodRow[]);
    setLoading(false);
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  async function handleCreate(e: FormEvent) {
    e.preventDefault();
    setSaveError(null);

    if (!form.period_start || !form.period_end) {
      setSaveError('Start and end dates are required.');
      return;
    }
    if (form.period_end < form.period_start) {
      setSaveError('End date must be on or after the start date.');
      return;
    }

    setSaving(true);
    const tenantResult = await resolveTenantId(session);
    if (!tenantResult.ok) {
      setSaveError(tenantResult.error);
      setSaving(false);
      return;
    }

    const { error: err } = await supabase.from('accounting_periods').insert({
      tenant_id: tenantResult.tenantId,
      period_start: form.period_start,
      period_end: form.period_end,
    } as PeriodInsert);
    setSaving(false);

    if (err) {
      setSaveError(
        err.message.includes('overlaps')
          ? err.message
          : err.message ?? 'Could not create the period. Try again.'
      );
      return;
    }

    setShowForm(false);
    setForm(emptyForm);
    load();
  }

  async function handleConfirmToggle() {
    if (!confirmTarget) return;
    setConfirmError(null);
    setConfirmSaving(true);

    const nextStatus = confirmTarget.status === 'open' ? 'closed' : 'open';
    const { error: err } = await supabase
      .from('accounting_periods')
      .update({ status: nextStatus })
      .eq('id', confirmTarget.id);

    setConfirmSaving(false);
    if (err) {
      setConfirmError(err.message ?? 'Could not update the period. Try again.');
      return;
    }
    setConfirmTarget(null);
    load();
  }

  return (
    <Box sx={{ maxWidth: 900 }}>
      <Stack direction="row" justifyContent="space-between" alignItems="center" sx={{ mb: 2 }}>
        <Typography variant="h5">Accounting Periods</Typography>
        <Button variant="contained" startIcon={<AddIcon />} onClick={() => setShowForm(true)}>
          New Period
        </Button>
      </Stack>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        Closing a period blocks new journal entries -- and therefore new supplier invoices, receivable
        invoices, and cash/bank transactions -- dated inside it. Reopening removes that block.
      </Typography>

      {error && <Alert severity="error" sx={{ mb: 2 }}>{error}</Alert>}

      <Paper variant="outlined">
        {loading ? (
          <Box display="flex" justifyContent="center" py={4}>
            <CircularProgress size={24} />
          </Box>
        ) : rows.length === 0 ? (
          <Box p={3}>
            <Typography variant="body2" color="text.secondary">
              No accounting periods yet. Until one exists, journal entries can post to any date.
            </Typography>
          </Box>
        ) : (
          <TableContainer>
            <Table size="small">
              <TableHead>
                <TableRow>
                  <TableCell>Period Start</TableCell>
                  <TableCell>Period End</TableCell>
                  <TableCell>Status</TableCell>
                  <TableCell align="right">Actions</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {rows.map((row) => (
                  <TableRow key={row.id} hover>
                    <TableCell>{row.period_start}</TableCell>
                    <TableCell>{row.period_end}</TableCell>
                    <TableCell>
                      <Chip
                        size="small"
                        icon={row.status === 'closed' ? <LockIcon fontSize="small" /> : <LockOpenIcon fontSize="small" />}
                        label={row.status === 'closed' ? 'Closed' : 'Open'}
                        color={row.status === 'closed' ? 'default' : 'success'}
                      />
                    </TableCell>
                    <TableCell align="right">
                      <Button size="small" onClick={() => setConfirmTarget(row)}>
                        {row.status === 'open' ? 'Close' : 'Reopen'}
                      </Button>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </TableContainer>
        )}
      </Paper>

      <Dialog open={showForm} onClose={() => !saving && setShowForm(false)} maxWidth="xs" fullWidth>
        <DialogTitle>New Accounting Period</DialogTitle>
        <Box component="form" onSubmit={handleCreate}>
          <DialogContent>
            <Stack spacing={2} sx={{ mt: 1 }}>
              {saveError && <Alert severity="error">{saveError}</Alert>}
              <TextField
                label="Period Start"
                type="date"
                value={form.period_start}
                onChange={(e) => setForm((f) => ({ ...f, period_start: e.target.value }))}
                InputLabelProps={{ shrink: true }}
                required
                fullWidth
              />
              <TextField
                label="Period End"
                type="date"
                value={form.period_end}
                onChange={(e) => setForm((f) => ({ ...f, period_end: e.target.value }))}
                InputLabelProps={{ shrink: true }}
                required
                fullWidth
              />
            </Stack>
          </DialogContent>
          <DialogActions>
            <Button onClick={() => setShowForm(false)} disabled={saving}>
              Cancel
            </Button>
            <Button type="submit" variant="contained" disabled={saving}>
              {saving ? 'Saving...' : 'Create'}
            </Button>
          </DialogActions>
        </Box>
      </Dialog>

      <Dialog open={!!confirmTarget} onClose={() => !confirmSaving && setConfirmTarget(null)} maxWidth="xs" fullWidth>
        <DialogTitle>
          {confirmTarget?.status === 'open' ? 'Close this period?' : 'Reopen this period?'}
        </DialogTitle>
        <DialogContent>
          {confirmError && <Alert severity="error" sx={{ mb: 2 }}>{confirmError}</Alert>}
          <DialogContentText>
            {confirmTarget?.status === 'open' ? (
              <>
                Closing {confirmTarget?.period_start} to {confirmTarget?.period_end} will block any new supplier
                invoice, receivable invoice, cash/bank transaction, or journal entry dated inside this range.
                Existing entries already posted are not affected.
              </>
            ) : (
              <>
                Reopening {confirmTarget?.period_start} to {confirmTarget?.period_end} will allow new entries to
                post into this range again.
              </>
            )}
          </DialogContentText>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setConfirmTarget(null)} disabled={confirmSaving}>
            Cancel
          </Button>
          <Button onClick={handleConfirmToggle} variant="contained" disabled={confirmSaving}>
            {confirmSaving ? 'Saving...' : confirmTarget?.status === 'open' ? 'Close Period' : 'Reopen Period'}
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}