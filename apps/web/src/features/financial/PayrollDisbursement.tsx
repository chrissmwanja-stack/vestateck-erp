import { useCallback, useEffect, useState, FormEvent } from 'react';
import {
  Alert,
  Box,
  Button,
  Chip,
  CircularProgress,
  Collapse,
  Dialog,
  DialogActions,
  DialogContent,
  DialogTitle,
  IconButton,
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
import {
  ExpandMore as ExpandMoreIcon,
  ExpandLess as ExpandLessIcon,
  Payments as PaymentsIcon,
} from '@mui/icons-material';
import { supabase } from '../../lib/supabaseClient';

function useFinanceAccess() {
  const [isFinance, setIsFinance] = useState<boolean | null>(null);
  useEffect(() => {
    supabase.rpc('is_finance_team_member', { p_role: 'finance' }).then(({ data, error }) =>
      setIsFinance(error ? false : Boolean(data))
    );
  }, []);
  return isFinance;
}

interface PayrollRun {
  id: string;
  period: string;
  status: string;
  approved_at: string | null;
  amount_disbursed: number;
}

interface PayrollItem {
  id: string;
  net_pay: number;
  employee_name: string;
  employee_no: string;
}

interface DisburseFormState {
  payment_method: 'cash' | 'bank';
  bank_account: string;
  transaction_date: string;
  amount: string;
  description: string;
}

const today = () => new Date().toISOString().slice(0, 10);

const emptyForm = (): DisburseFormState => ({
  payment_method: 'bank',
  bank_account: '',
  transaction_date: today(),
  amount: '',
  description: '',
});

function RunBreakdown({ runId }: { runId: string }) {
  const [items, setItems] = useState<PayrollItem[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    supabase
      .from('hr_payroll_items')
      .select('id, net_pay, hr_employees(first_name, last_name, employee_no)')
      .eq('payroll_run_id', runId)
      .order('id')
      .then(({ data }) => {
        setItems(
          ((data ?? []) as any[]).map((r) => ({
            id: r.id,
            net_pay: r.net_pay,
            employee_name: r.hr_employees ? `${r.hr_employees.first_name} ${r.hr_employees.last_name}` : '—',
            employee_no: r.hr_employees?.employee_no ?? '—',
          }))
        );
        setLoading(false);
      });
  }, [runId]);

  if (loading) {
    return (
      <Box display="flex" justifyContent="center" py={2}>
        <CircularProgress size={20} />
      </Box>
    );
  }

  return (
    <Box sx={{ px: 2, pb: 2 }}>
      <TableContainer>
        <Table size="small">
          <TableHead>
            <TableRow>
              <TableCell>Employee</TableCell>
              <TableCell align="right">Net Pay</TableCell>
            </TableRow>
          </TableHead>
          <TableBody>
            {items.map((item) => (
              <TableRow key={item.id} hover>
                <TableCell>
                  <Typography variant="body2" fontWeight={600}>{item.employee_name}</Typography>
                  <Typography variant="caption" color="text.secondary">{item.employee_no}</Typography>
                </TableCell>
                <TableCell align="right">{Number(item.net_pay).toLocaleString()}</TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </TableContainer>
    </Box>
  );
}

export default function PayrollDisbursement() {
  const isFinance = useFinanceAccess();
  const [runs, setRuns] = useState<PayrollRun[]>([]);
  const [totalsByRun, setTotalsByRun] = useState<Record<string, number>>({});
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [openId, setOpenId] = useState<string | null>(null);

  const [disburseTarget, setDisburseTarget] = useState<PayrollRun | null>(null);
  const [form, setForm] = useState<DisburseFormState>(emptyForm());
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const { data, error: err } = await supabase
      .from('hr_payroll_runs')
      .select('id, period, status, approved_at, amount_disbursed')
      .in('status', ['approved', 'disbursed'])
      .order('period', { ascending: false });

    if (err) {
      setError(err.message);
      setLoading(false);
      return;
    }

    const rows = (data ?? []) as PayrollRun[];
    setRuns(rows);

    if (rows.length > 0) {
      const { data: itemRows } = await supabase
        .from('hr_payroll_items')
        .select('payroll_run_id, net_pay')
        .in('payroll_run_id', rows.map((r) => r.id));
      const totals: Record<string, number> = {};
      (itemRows ?? []).forEach((r: any) => {
        totals[r.payroll_run_id] = (totals[r.payroll_run_id] ?? 0) + Number(r.net_pay);
      });
      setTotalsByRun(totals);
    }

    setLoading(false);
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  function openDisburse(run: PayrollRun) {
    const totalNet = totalsByRun[run.id] ?? 0;
    const remaining = totalNet - Number(run.amount_disbursed);
    setDisburseTarget(run);
    setForm({ ...emptyForm(), amount: remaining > 0 ? remaining.toFixed(2) : '' });
    setSaveError(null);
  }

  async function handleDisburse(e: FormEvent) {
    e.preventDefault();
    if (!disburseTarget) return;
    setSaveError(null);

    const parsedAmount = Number(form.amount);
    if (!form.amount || Number.isNaN(parsedAmount) || parsedAmount <= 0) {
      setSaveError('Amount must be a valid number greater than 0.');
      return;
    }
    if (form.payment_method === 'bank' && !form.bank_account.trim()) {
      setSaveError('Bank account is required for bank disbursements.');
      return;
    }
    if (!form.transaction_date) {
      setSaveError('Transaction date is required.');
      return;
    }

    setSaving(true);
    const { error: insertError } = await supabase.from('cash_bank_transactions').insert({
      transaction_type: 'payment',
      payment_method: form.payment_method,
      reference_type: 'payroll_run',
      reference_id: disburseTarget.id,
      amount: parsedAmount,
      currency: 'UGX',
      transaction_date: form.transaction_date,
      bank_account: form.payment_method === 'bank' ? form.bank_account.trim() || null : null,
      description: form.description.trim() || `Payroll disbursement — ${disburseTarget.period}`,
    });
    setSaving(false);

    if (insertError) {
      setSaveError(insertError.message ?? 'Could not record the disbursement. Try again.');
      return;
    }

    setDisburseTarget(null);
    load();
  }

  const remainingFor = (run: PayrollRun) => (totalsByRun[run.id] ?? 0) - Number(run.amount_disbursed);

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Typography variant="h5" sx={{ display: 'flex', alignItems: 'center', gap: 1, mb: 1 }}>
        <PaymentsIcon /> Payroll Disbursement
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        HR-approved payroll runs, ready for Finance to release payment.
      </Typography>

      {error && <Alert severity="error" sx={{ mb: 2 }}>{error}</Alert>}
      {isFinance === false && (
        <Alert severity="info" sx={{ mb: 2 }}>
          You're not currently listed as a finance team member for this organization.
        </Alert>
      )}

      <Paper variant="outlined">
        {loading ? (
          <Box display="flex" justifyContent="center" py={4}>
            <CircularProgress size={24} />
          </Box>
        ) : (
          <>
            {runs.map((run) => {
              const totalNet = totalsByRun[run.id] ?? 0;
              const remaining = remainingFor(run);
              const fullyDisbursed = run.status === 'disbursed' || remaining <= 0.01;
              return (
                <Box key={run.id} sx={{ borderBottom: 1, borderColor: 'divider', '&:last-of-type': { borderBottom: 0 } }}>
                  <Box
                    sx={{ p: 2, display: 'flex', alignItems: 'center', justifyContent: 'space-between', cursor: 'pointer' }}
                    onClick={() => setOpenId(openId === run.id ? null : run.id)}
                  >
                    <Stack direction="row" spacing={2} alignItems="center">
                      <Typography variant="subtitle1" fontWeight={600}>{run.period}</Typography>
                      <Chip
                        size="small"
                        label={fullyDisbursed ? 'Disbursed' : 'Approved · awaiting disbursement'}
                        color={fullyDisbursed ? 'success' : 'warning'}
                      />
                      <Typography variant="body2" color="text.secondary">
                        Total net {totalNet.toLocaleString()}
                        {run.amount_disbursed > 0 && !fullyDisbursed && ` · ${remaining.toLocaleString()} remaining`}
                      </Typography>
                    </Stack>
                    <Stack direction="row" spacing={1} alignItems="center" onClick={(e) => e.stopPropagation()}>
                      {!fullyDisbursed && (
                        <Button size="small" variant="contained" onClick={() => openDisburse(run)}>
                          Record Disbursement
                        </Button>
                      )}
                      <IconButton size="small" onClick={() => setOpenId(openId === run.id ? null : run.id)}>
                        {openId === run.id ? <ExpandLessIcon /> : <ExpandMoreIcon />}
                      </IconButton>
                    </Stack>
                  </Box>
                  <Collapse in={openId === run.id} timeout="auto" unmountOnExit>
                    <RunBreakdown runId={run.id} />
                  </Collapse>
                </Box>
              );
            })}
            {runs.length === 0 && (
              <Box sx={{ p: 4, textAlign: 'center', color: 'text.secondary' }}>
                No approved payroll runs waiting on disbursement.
              </Box>
            )}
          </>
        )}
      </Paper>

      <Dialog open={!!disburseTarget} onClose={() => setDisburseTarget(null)} maxWidth="xs" fullWidth>
        <form onSubmit={handleDisburse}>
          <DialogTitle>Disburse {disburseTarget?.period}</DialogTitle>
          <DialogContent>
            <Stack spacing={2} sx={{ mt: 1 }}>
              <TextField
                select
                label="Payment Method"
                value={form.payment_method}
                onChange={(e) => setForm((f) => ({ ...f, payment_method: e.target.value as 'cash' | 'bank' }))}
              >
                <MenuItem value="bank">Bank</MenuItem>
                <MenuItem value="cash">Cash</MenuItem>
              </TextField>
              {form.payment_method === 'bank' && (
                <TextField
                  label="Bank Account"
                  value={form.bank_account}
                  onChange={(e) => setForm((f) => ({ ...f, bank_account: e.target.value }))}
                  fullWidth
                />
              )}
              <TextField
                label="Transaction Date"
                type="date"
                value={form.transaction_date}
                onChange={(e) => setForm((f) => ({ ...f, transaction_date: e.target.value }))}
                InputLabelProps={{ shrink: true }}
              />
              <TextField
                label="Amount (UGX)"
                type="number"
                value={form.amount}
                onChange={(e) => setForm((f) => ({ ...f, amount: e.target.value }))}
                helperText={
                  disburseTarget
                    ? `Remaining balance: ${remainingFor(disburseTarget).toLocaleString()}. Partial payments are allowed.`
                    : undefined
                }
              />
              <TextField
                label="Description"
                value={form.description}
                onChange={(e) => setForm((f) => ({ ...f, description: e.target.value }))}
                multiline
                minRows={2}
                placeholder={disburseTarget ? `Payroll disbursement — ${disburseTarget.period}` : ''}
              />
              {saveError && <Alert severity="error">{saveError}</Alert>}
            </Stack>
          </DialogContent>
          <DialogActions>
            <Button onClick={() => setDisburseTarget(null)}>Cancel</Button>
            <Button type="submit" variant="contained" disabled={saving}>
              {saving ? 'Recording…' : 'Record Disbursement'}
            </Button>
          </DialogActions>
        </form>
      </Dialog>
    </Box>
  );
}
