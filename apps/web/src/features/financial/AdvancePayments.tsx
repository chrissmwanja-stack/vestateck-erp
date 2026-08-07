import { useEffect, useState } from 'react';
import {
  Box,
  Button,
  Chip,
  Dialog,
  DialogActions,
  DialogContent,
  DialogTitle,
  MenuItem,
  Paper,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  TextField,
  Typography,
} from '@mui/material';
import { useSearchParams } from 'react-router-dom';
import { supabase } from '../../lib/supabaseClient';

interface Account {
  id: string;
  account_code: string;
  name: string;
  account_type: 'vendor' | 'client' | 'both';
}

interface AdvanceRow {
  id: string;
  account_id: string;
  account_code: string;
  account_name: string;
  direction: 'payment' | 'receipt';
  amount: number;
  currency: string;
  payment_date: string;
  payment_method: 'cash' | 'bank';
  description: string | null;
  total_applied: number;
  remaining_amount: number;
}

interface OpenInvoice {
  id: string;
  invoice_number: string;
  amount_incl_vat: number;
}

const emptyForm = {
  accountId: '',
  direction: 'payment' as 'payment' | 'receipt',
  amount: '',
  paymentMethod: 'bank' as 'cash' | 'bank',
  bankAccount: '',
  paymentDate: new Date().toISOString().slice(0, 10),
  description: '',
};

export default function AdvancePayments() {
  const [searchParams] = useSearchParams();
  const currency = searchParams.get('ccy') === 'USD' ? 'USD' : 'UGX';

  const [accounts, setAccounts] = useState<Account[]>([]);
  const [rows, setRows] = useState<AdvanceRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [form, setForm] = useState(emptyForm);
  const [saving, setSaving] = useState(false);
  const [formError, setFormError] = useState<string | null>(null);

  // Apply-to-invoice dialog state
  const [applyTarget, setApplyTarget] = useState<AdvanceRow | null>(null);
  const [openInvoices, setOpenInvoices] = useState<OpenInvoice[]>([]);
  const [applyInvoiceId, setApplyInvoiceId] = useState('');
  const [applyAmount, setApplyAmount] = useState('');
  const [applying, setApplying] = useState(false);

  const loadAccounts = () =>
    supabase
      .from('accounts')
      .select('id, account_code, name, account_type')
      .eq('is_active', true)
      .order('name')
      .then(({ data }) => setAccounts(data ?? []));

  const loadRows = () => {
    setLoading(true);
    return supabase
      .from('v_advance_payments')
      .select('*')
      .eq('currency', currency)
      .order('payment_date', { ascending: false })
      .then(({ data, error }) => {
        setRows(error ? [] : (data as AdvanceRow[]) ?? []);
        setLoading(false);
      });
  };

  useEffect(() => {
    loadAccounts();
  }, []);

  useEffect(() => {
    loadRows();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [currency]);

  const submitAdvance = async () => {
    setFormError(null);
    if (!form.accountId || !form.amount || !form.paymentDate) {
      setFormError('Account, amount, and payment date are required.');
      return;
    }
    setSaving(true);
    const { error } = await supabase.from('advance_payments').insert({
      account_id: form.accountId,
      direction: form.direction,
      amount: Number(form.amount),
      currency,
      payment_method: form.paymentMethod,
      bank_account: form.paymentMethod === 'bank' ? form.bankAccount || null : null,
      payment_date: form.paymentDate,
      description: form.description || null,
    });
    setSaving(false);
    if (error) {
      setFormError(error.message);
      return;
    }
    setForm(emptyForm);
    loadRows();
  };

  const openApplyDialog = async (row: AdvanceRow) => {
    setApplyTarget(row);
    setApplyInvoiceId('');
    setApplyAmount('');
    const account = accounts.find((a) => a.id === row.account_id);
    const table = row.direction === 'payment' ? 'supplier_invoices' : 'receivable_invoices';
    const accountFilterCol = row.direction === 'payment' ? 'vendor_account_id' : 'client_account_id';
    const { data } = await supabase
      .from(table)
      .select('id, invoice_number, amount_incl_vat')
      .eq(accountFilterCol, row.account_id)
      .eq('currency', row.currency);
    setOpenInvoices((data as OpenInvoice[]) ?? []);
    void account;
  };

  const submitApplication = async () => {
    if (!applyTarget || !applyInvoiceId || !applyAmount) return;
    setApplying(true);
    const { error } = await supabase.from('advance_payment_applications').insert({
      advance_payment_id: applyTarget.id,
      reference_type: applyTarget.direction === 'payment' ? 'supplier_invoice' : 'receivable_invoice',
      reference_id: applyInvoiceId,
      applied_amount: Number(applyAmount),
    });
    setApplying(false);
    if (!error) {
      setApplyTarget(null);
      loadRows();
    }
  };

  return (
    <Box>
      <Typography variant="h5" gutterBottom>
        Advance Payments {currency === 'USD' && '(USD)'}
      </Typography>

      <Paper sx={{ p: 2, mb: 3 }}>
        <Typography variant="subtitle1" gutterBottom>
          Record a new advance
        </Typography>
        <Box sx={{ display: 'flex', gap: 2, flexWrap: 'wrap', alignItems: 'center' }}>
          <TextField
            select
            label="Account"
            value={form.accountId}
            onChange={(e) => setForm({ ...form, accountId: e.target.value })}
            sx={{ minWidth: 260 }}
            size="small"
          >
            {accounts.map((a) => (
              <MenuItem key={a.id} value={a.id}>
                {a.account_code} — {a.name}
              </MenuItem>
            ))}
          </TextField>
          <TextField
            select
            label="Direction"
            value={form.direction}
            onChange={(e) => setForm({ ...form, direction: e.target.value as 'payment' | 'receipt' })}
            sx={{ minWidth: 200 }}
            size="small"
          >
            <MenuItem value="payment">Payment to vendor</MenuItem>
            <MenuItem value="receipt">Receipt from client</MenuItem>
          </TextField>
          <TextField
            label="Amount"
            type="number"
            size="small"
            value={form.amount}
            onChange={(e) => setForm({ ...form, amount: e.target.value })}
          />
          <TextField
            select
            label="Method"
            value={form.paymentMethod}
            onChange={(e) => setForm({ ...form, paymentMethod: e.target.value as 'cash' | 'bank' })}
            sx={{ minWidth: 140 }}
            size="small"
          >
            <MenuItem value="cash">Cash</MenuItem>
            <MenuItem value="bank">Bank</MenuItem>
          </TextField>
          {form.paymentMethod === 'bank' && (
            <TextField
              label="Bank Account"
              size="small"
              value={form.bankAccount}
              onChange={(e) => setForm({ ...form, bankAccount: e.target.value })}
            />
          )}
          <TextField
            label="Payment Date"
            type="date"
            size="small"
            InputLabelProps={{ shrink: true }}
            value={form.paymentDate}
            onChange={(e) => setForm({ ...form, paymentDate: e.target.value })}
          />
          <TextField
            label="Description"
            size="small"
            value={form.description}
            onChange={(e) => setForm({ ...form, description: e.target.value })}
          />
          <Button variant="contained" onClick={submitAdvance} disabled={saving}>
            Record
          </Button>
        </Box>
        {formError && (
          <Typography color="error" variant="body2" sx={{ mt: 1 }}>
            {formError}
          </Typography>
        )}
      </Paper>

      <TableContainer component={Paper}>
        <Table size="small">
          <TableHead>
            <TableRow>
              <TableCell>Account</TableCell>
              <TableCell>Direction</TableCell>
              <TableCell>Date</TableCell>
              <TableCell align="right">Amount</TableCell>
              <TableCell align="right">Applied</TableCell>
              <TableCell align="right">Remaining</TableCell>
              <TableCell />
            </TableRow>
          </TableHead>
          <TableBody>
            {rows.map((r) => (
              <TableRow key={r.id}>
                <TableCell>
                  {r.account_code} — {r.account_name}
                </TableCell>
                <TableCell>
                  <Chip
                    size="small"
                    label={r.direction === 'payment' ? 'To vendor' : 'From client'}
                    color={r.direction === 'payment' ? 'default' : 'primary'}
                  />
                </TableCell>
                <TableCell>{r.payment_date}</TableCell>
                <TableCell align="right">{Number(r.amount).toLocaleString()}</TableCell>
                <TableCell align="right">{Number(r.total_applied).toLocaleString()}</TableCell>
                <TableCell align="right">
                  <strong>{Number(r.remaining_amount).toLocaleString()}</strong>
                </TableCell>
                <TableCell>
                  {r.remaining_amount > 0 && (
                    <Button size="small" onClick={() => openApplyDialog(r)}>
                      Apply
                    </Button>
                  )}
                </TableCell>
              </TableRow>
            ))}
            {rows.length === 0 && !loading && (
              <TableRow>
                <TableCell colSpan={7} align="center">
                  No advance payments recorded in {currency}.
                </TableCell>
              </TableRow>
            )}
          </TableBody>
        </Table>
      </TableContainer>

      <Dialog open={!!applyTarget} onClose={() => setApplyTarget(null)} fullWidth maxWidth="sm">
        <DialogTitle>Apply Advance to Invoice</DialogTitle>
        <DialogContent sx={{ display: 'flex', flexDirection: 'column', gap: 2, mt: 1 }}>
          <Typography variant="body2" color="text.secondary">
            Remaining balance: {applyTarget?.remaining_amount.toLocaleString()} {applyTarget?.currency}
          </Typography>
          <TextField
            select
            label="Invoice"
            value={applyInvoiceId}
            onChange={(e) => setApplyInvoiceId(e.target.value)}
            size="small"
          >
            {openInvoices.map((inv) => (
              <MenuItem key={inv.id} value={inv.id}>
                {inv.invoice_number} — {Number(inv.amount_incl_vat).toLocaleString()}
              </MenuItem>
            ))}
          </TextField>
          <TextField
            label="Amount to apply"
            type="number"
            size="small"
            value={applyAmount}
            onChange={(e) => setApplyAmount(e.target.value)}
          />
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setApplyTarget(null)}>Cancel</Button>
          <Button variant="contained" onClick={submitApplication} disabled={applying || !applyInvoiceId || !applyAmount}>
            Apply
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}