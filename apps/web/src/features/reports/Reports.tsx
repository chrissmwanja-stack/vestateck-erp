import { useEffect, useState } from 'react';
import {
  Alert,
  Box,
  Card,
  CardContent,
  CircularProgress,
  Divider,
  Grid,
  Paper,
  Stack,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableRow,
  Typography,
} from '@mui/material';
import { supabase } from '../../lib/supabaseClient';

interface CurrencyTotal {
  currency: string;
  count: number;
  total: number;
}

interface ReportData {
  supplierByType: Record<'po_related' | 'non_po', CurrencyTotal[]>;
  receivableByStatus: Record<'open' | 'paid', CurrencyTotal[]>;
  expenditureTotals: CurrencyTotal[];
  cashBank: {
    receipts: CurrencyTotal[];
    payments: CurrencyTotal[];
    byMethod: { method: 'cash' | 'bank'; count: number; total: number; net: number }[];
  };
}

function groupByCurrency(rows: { currency: string; amount: number }[]): CurrencyTotal[] {
  const map = new Map<string, CurrencyTotal>();
  for (const r of rows) {
    const currency = r.currency || 'USD';
    const existing = map.get(currency) ?? { currency, count: 0, total: 0 };
    existing.count += 1;
    existing.total += Number(r.amount) || 0;
    map.set(currency, existing);
  }
  return Array.from(map.values()).sort((a, b) => a.currency.localeCompare(b.currency));
}

export default function FinancialReportsCurrency() {
  const [data, setData] = useState<ReportData | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    async function load() {
      setLoading(true);
      setError(null);
      try {
        const [supplierRes, receivableRes, expenditureRes, cashBankRes] = await Promise.all([
          supabase.from('supplier_invoices').select('currency, amount_incl_vat, invoice_type').limit(5000),
          supabase.from('receivable_invoices').select('currency, amount_incl_vat, status').limit(5000),
          supabase.from('expenditure_slips').select('currency, amount').limit(5000),
          supabase.from('cash_bank_transactions').select('currency, amount, transaction_type, payment_method').limit(5000),
        ]);
        if (supplierRes.error) throw supplierRes.error;
        if (receivableRes.error) throw receivableRes.error;
        if (expenditureRes.error) throw expenditureRes.error;
        if (cashBankRes.error) throw cashBankRes.error;

        const supplierRows = (supplierRes.data ?? []) as { currency: string; amount_incl_vat: number; invoice_type: 'po_related' | 'non_po' }[];
        const receivableRows = (receivableRes.data ?? []) as { currency: string; amount_incl_vat: number; status: 'open' | 'paid' }[];
        const expenditureRows = (expenditureRes.data ?? []) as { currency: string; amount: number }[];
        const cashBankRows = (cashBankRes.data ?? []) as {
          currency: string;
          amount: number;
          transaction_type: 'payment' | 'receipt';
          payment_method: 'cash' | 'bank';
        }[];

        const report: ReportData = {
          supplierByType: {
            po_related: groupByCurrency(
              supplierRows.filter((r) => r.invoice_type === 'po_related').map((r) => ({ currency: r.currency, amount: r.amount_incl_vat }))
            ),
            non_po: groupByCurrency(
              supplierRows.filter((r) => r.invoice_type === 'non_po').map((r) => ({ currency: r.currency, amount: r.amount_incl_vat }))
            ),
          },
          receivableByStatus: {
            open: groupByCurrency(
              receivableRows.filter((r) => r.status === 'open').map((r) => ({ currency: r.currency, amount: r.amount_incl_vat }))
            ),
            paid: groupByCurrency(
              receivableRows.filter((r) => r.status === 'paid').map((r) => ({ currency: r.currency, amount: r.amount_incl_vat }))
            ),
          },
          expenditureTotals: groupByCurrency(expenditureRows.map((r) => ({ currency: r.currency, amount: r.amount }))),
          cashBank: {
            receipts: groupByCurrency(
              cashBankRows.filter((r) => r.transaction_type === 'receipt').map((r) => ({ currency: r.currency, amount: r.amount }))
            ),
            payments: groupByCurrency(
              cashBankRows.filter((r) => r.transaction_type === 'payment').map((r) => ({ currency: r.currency, amount: r.amount }))
            ),
            byMethod: (['cash', 'bank'] as const).map((method) => {
              const matching = cashBankRows.filter((r) => r.payment_method === method);
              const receipts = matching.filter((r) => r.transaction_type === 'receipt').reduce((sum, r) => sum + Number(r.amount), 0);
              const payments = matching.filter((r) => r.transaction_type === 'payment').reduce((sum, r) => sum + Number(r.amount), 0);
              return {
                method,
                count: matching.length,
                total: receipts + payments, // gross volume
                net: receipts - payments, // net position
              };
            }),
          },
        };
        if (!cancelled) setData(report);
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : 'Failed to load financial reports');
      } finally {
        if (!cancelled) setLoading(false);
      }
    }
    load();
    return () => {
      cancelled = true;
    };
  }, []);

  function CurrencyTotalsTable({ rows }: { rows: CurrencyTotal[] }) {
    if (rows.length === 0) {
      return (
        <Typography variant="body2" color="text.secondary">
          No records.
        </Typography>
      );
    }
    return (
      <Table size="small">
        <TableHead>
          <TableRow>
            <TableCell>Currency</TableCell>
            <TableCell align="right">Count</TableCell>
            <TableCell align="right">Total</TableCell>
          </TableRow>
        </TableHead>
        <TableBody>
          {rows.map((r) => (
            <TableRow key={r.currency}>
              <TableCell>{r.currency}</TableCell>
              <TableCell align="right">{r.count}</TableCell>
              <TableCell align="right">{r.total.toLocaleString()}</TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
    );
  }

  return (
    <Box>
      <Typography variant="h5" sx={{ mb: 2 }}>
        Financial Reports — Currency View
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
        Grouped by currency (USD, UGX, EUR) — good for multi-currency. Pair with org/date filtered version for full picture. Limited to 5000 rows for performance — use RPC for full aggregation.
      </Typography>
      {error && <Alert severity="error" sx={{ mb: 2 }}>{error}</Alert>}
      {loading ? (
        <Box sx={{ display: 'flex', justifyContent: 'center', py: 6 }}>
          <CircularProgress />
        </Box>
      ) : data ? (
        <Grid container spacing={3}>
          <Grid item xs={12} md={6}>
            <Card variant="outlined">
              <CardContent>
                <Typography variant="subtitle1" sx={{ fontWeight: 600, mb: 1 }}>
                  Supplier Invoices — PO Related
                </Typography>
                <CurrencyTotalsTable rows={data.supplierByType.po_related} />
                <Divider sx={{ my: 2 }} />
                <Typography variant="subtitle1" sx={{ fontWeight: 600, mb: 1 }}>
                  Supplier Invoices — Non-PO
                </Typography>
                <CurrencyTotalsTable rows={data.supplierByType.non_po} />
              </CardContent>
            </Card>
          </Grid>
          <Grid item xs={12} md={6}>
            <Card variant="outlined">
              <CardContent>
                <Typography variant="subtitle1" sx={{ fontWeight: 600, mb: 1 }}>
                  Receivable Invoices — Open
                </Typography>
                <CurrencyTotalsTable rows={data.receivableByStatus.open} />
                <Divider sx={{ my: 2 }} />
                <Typography variant="subtitle1" sx={{ fontWeight: 600, mb: 1 }}>
                  Receivable Invoices — Paid
                </Typography>
                <CurrencyTotalsTable rows={data.receivableByStatus.paid} />
              </CardContent>
            </Card>
          </Grid>
          <Grid item xs={12} md={6}>
            <Card variant="outlined">
              <CardContent>
                <Typography variant="subtitle1" sx={{ fontWeight: 600, mb: 1 }}>
                  Expenditure Slips
                </Typography>
                <CurrencyTotalsTable rows={data.expenditureTotals} />
              </CardContent>
            </Card>
          </Grid>
          <Grid item xs={12} md={6}>
            <Card variant="outlined">
              <CardContent>
                <Typography variant="subtitle1" sx={{ fontWeight: 600, mb: 1 }}>
                  Cash and Bank — Receipts
                </Typography>
                <CurrencyTotalsTable rows={data.cashBank.receipts} />
                <Divider sx={{ my: 2 }} />
                <Typography variant="subtitle1" sx={{ fontWeight: 600, mb: 1 }}>
                  Cash and Bank — Payments
                </Typography>
                <CurrencyTotalsTable rows={data.cashBank.payments} />
                <Divider sx={{ my: 2 }} />
                <Typography variant="subtitle1" sx={{ fontWeight: 600, mb: 1 }}>
                  Net Position by Method (receipts − payments)
                </Typography>
                <Stack spacing={0.5}>
                  {data.cashBank.byMethod.map((m) => (
                    <Paper key={m.method} variant="outlined" sx={{ p: 1.5, display: 'flex', justifyContent: 'space-between' }}>
                      <Typography variant="body2" sx={{ textTransform: 'capitalize' }}>
                        {m.method} ({m.count} txns)
                      </Typography>
                      <Box sx={{ textAlign: 'right' }}>
                        <Typography variant="body2" fontWeight={600} color={m.net < 0 ? 'error.main' : 'success.main'}>
                          Net {m.net.toLocaleString()}
                        </Typography>
                        <Typography variant="caption" color="text.secondary">
                          Gross {m.total.toLocaleString()}
                        </Typography>
                      </Box>
                    </Paper>
                  ))}
                </Stack>
              </CardContent>
            </Card>
          </Grid>
        </Grid>
      ) : null}
    </Box>
  );
}
