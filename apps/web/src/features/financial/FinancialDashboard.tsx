import { useEffect, useState } from 'react';
import { Link as RouterLink } from 'react-router-dom';
import {
  Box,
  Typography,
  Paper,
  Grid,
  Card,
  CardActionArea,
  CardContent,
  CircularProgress,
  Chip,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableRow,
} from '@mui/material';
import {
  ReceiptLong,
  AccountBalance,
  Payments,
  BarChart,
  RequestQuote,
  Warning,
  CheckCircle,
} from '@mui/icons-material';
import { supabase } from '../../lib/supabaseClient';

interface QuickLink {
  label: string;
  description: string;
  to: string;
  icon: React.ReactNode;
}

const quickLinks: QuickLink[] = [
  { label: 'Supplier Invoice (PO Related)', description: 'Enter an invoice against an existing PO', to: '/financial-management/invoices/supplier-invoice-po', icon: <ReceiptLong fontSize="large" /> },
  { label: 'Supplier Invoice (Non-PO)', description: 'Enter a direct supplier invoice', to: '/financial-management/invoices/supplier-invoice-non-po', icon: <ReceiptLong fontSize="large" /> },
  { label: 'Receivable Invoice', description: 'Create a customer receivable invoice', to: '/financial-management/invoices/receivable-invoice', icon: <RequestQuote fontSize="large" /> },
  { label: 'Expenditure Slips', description: 'Record non-invoice expenditure', to: '/financial-management/expenditure-slips', icon: <Payments fontSize="large" /> },
  { label: 'Cash and Bank Payments', description: 'Settle invoices, slips, and receivables', to: '/financial-management/cash-bank-operations', icon: <AccountBalance fontSize="large" /> },
  { label: 'Reports Summary', description: 'Supplier invoices, receivables, and cash position at a glance', to: '/financial-management/reports', icon: <BarChart fontSize="large" /> },
];

interface Stats {
  supplierInvoices: number;
  supplierInvoicesNonPo: number;
  receivableInvoices: number;
  expenditureSlips: number;
  pendingPayments: number;
  totalPayable: number;
  totalReceivable: number;
}

export default function FinancialDashboard() {
  const [stats, setStats] = useState<Stats>({
    supplierInvoices: 0,
    supplierInvoicesNonPo: 0,
    receivableInvoices: 0,
    expenditureSlips: 0,
    pendingPayments: 0,
    totalPayable: 0,
    totalReceivable: 0,
  });
  const [recentInvoices, setRecentInvoices] = useState<any[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const fetchDashboard = async () => {
      setLoading(true);

      // Try to fetch from financial tables, with fallback to 0 if tables don't exist or RLS blocks
      const [supplierPoRes, supplierNonPoRes, receivableRes, expenditureRes, cashBankRes] = await Promise.all([
        supabase.from("supplier_invoices").select("id, total_amount", { count: "exact" }).eq("is_po_related", true).limit(5),
        supabase.from("supplier_invoices").select("id, total_amount", { count: "exact" }).eq("is_po_related", false).limit(5),
        supabase.from("receivable_invoices").select("id, total_amount", { count: "exact" }).limit(5),
        supabase.from("expenditure_slips").select("id, amount", { count: "exact" }).limit(5),
        supabase.from("cash_bank_transactions").select("id, amount, status").eq("status", "pending").limit(100),
      ]);

      // For more accurate counts, use count from head:true queries
      const [supplierPoCount, supplierNonPoCount, receivableCount, expenditureCount] = await Promise.all([
        supabase.from("supplier_invoices").select("id", { count: "exact", head: true }).eq("is_po_related", true),
        supabase.from("supplier_invoices").select("id", { count: "exact", head: true }).eq("is_po_related", false),
        supabase.from("receivable_invoices").select("id", { count: "exact", head: true }),
        supabase.from("expenditure_slips").select("id", { count: "exact", head: true }),
      ]);

      // Fetch recent supplier invoices for table
      const { data: recent } = await supabase
        .from("supplier_invoices")
        .select("id, invoice_no, vendor_name, total_amount, status, created_at")
        .order("created_at", { ascending: false })
        .limit(5);

      const supplierInvoices = supplierPoCount.count || supplierPoRes.count || 0;
      const supplierInvoicesNonPo = supplierNonPoCount.count || supplierNonPoRes.count || 0;
      const receivableInvoices = receivableCount.count || receivableRes.count || 0;
      const expenditureSlips = expenditureCount.count || expenditureRes.count || 0;

      const pendingPayments = cashBankRes.count || (cashBankRes.data as any[])?.length || 0;

      const totalPayable =
        ((supplierPoRes.data as any[])?.reduce((sum: number, inv: any) => sum + (Number(inv.total_amount) || 0), 0) || 0) +
        ((supplierNonPoRes.data as any[])?.reduce((sum: number, inv: any) => sum + (Number(inv.total_amount) || 0), 0) || 0);

      const totalReceivable = (receivableRes.data as any[])?.reduce((sum: number, inv: any) => sum + (Number(inv.total_amount) || 0), 0) || 0;

      setStats({
        supplierInvoices,
        supplierInvoicesNonPo,
        receivableInvoices,
        expenditureSlips,
        pendingPayments,
        totalPayable,
        totalReceivable,
      });

      setRecentInvoices((recent as any[]) || []);
      setLoading(false);
    };

    fetchDashboard();
  }, []);

  if (loading) {
    return (
      <Box sx={{ display: "flex", justifyContent: "center", p: 4 }}>
        <CircularProgress />
      </Box>
    );
  }

  return (
    <Box>
      <Typography variant="h5" gutterBottom>
        Financial Management and Financial Reporting
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        Outstanding invoices, cash position, pending payments, and expenditure overview. Real data from supplier_invoices, receivable_invoices, expenditure_slips tables.
      </Typography>

      {/* KPI CARDS */}
      <Grid container spacing={2} sx={{ mb: 3 }}>
        <Grid item xs={12} sm={6} md={3}>
          <Card sx={{ bgcolor: 'primary.light', color: 'primary.contrastText' }}>
            <CardContent>
              <Box sx={{ display: 'flex', alignItems: 'center', gap: 1, mb: 1 }}>
                <ReceiptLong />
                <Typography variant="subtitle2">Supplier Invoices (PO)</Typography>
              </Box>
              <Typography variant="h4" fontWeight={700}>{stats.supplierInvoices}</Typography>
              <Typography variant="caption" sx={{ opacity: 0.8 }}>USD {stats.totalPayable.toLocaleString()} total payable (sample)</Typography>
            </CardContent>
          </Card>
        </Grid>

        <Grid item xs={12} sm={6} md={3}>
          <Card>
            <CardContent>
              <Box sx={{ display: 'flex', alignItems: 'center', gap: 1, mb: 1 }}>
                <ReceiptLong />
                <Typography variant="subtitle2">Non-PO Invoices</Typography>
              </Box>
              <Typography variant="h4" fontWeight={700}>{stats.supplierInvoicesNonPo}</Typography>
              <Typography variant="caption" color="text.secondary">Direct supplier invoices</Typography>
            </CardContent>
          </Card>
        </Grid>

        <Grid item xs={12} sm={6} md={3}>
          <Card sx={{ bgcolor: 'success.light' }}>
            <CardContent>
              <Box sx={{ display: 'flex', alignItems: 'center', gap: 1, mb: 1 }}>
                <RequestQuote />
                <Typography variant="subtitle2">Receivable Invoices</Typography>
              </Box>
              <Typography variant="h4" fontWeight={700}>{stats.receivableInvoices}</Typography>
              <Typography variant="caption">USD {stats.totalReceivable.toLocaleString()} receivable (sample)</Typography>
            </CardContent>
          </Card>
        </Grid>

        <Grid item xs={12} sm={6} md={3}>
          <Card sx={{ bgcolor: stats.pendingPayments > 0 ? 'warning.light' : 'grey.100' }}>
            <CardContent>
              <Box sx={{ display: 'flex', alignItems: 'center', gap: 1, mb: 1 }}>
                <Warning />
                <Typography variant="subtitle2">Pending Payments</Typography>
              </Box>
              <Typography variant="h4" fontWeight={700}>{stats.pendingPayments}</Typography>
              <Typography variant="caption">{stats.pendingPayments > 0 ? 'Needs settlement' : 'All settled'}</Typography>
            </CardContent>
          </Card>
        </Grid>

        <Grid item xs={6} sm={3}>
          <Card variant="outlined">
            <CardContent sx={{ p: 1.5, textAlign: 'center' }}>
              <Typography variant="h6" color="primary.main" fontWeight={700}>{stats.expenditureSlips}</Typography>
              <Typography variant="caption">Expenditure Slips</Typography>
            </CardContent>
          </Card>
        </Grid>
        <Grid item xs={6} sm={3}>
          <Card variant="outlined">
            <CardContent sx={{ p: 1.5, textAlign: 'center' }}>
              <Typography variant="h6" color="success.main" fontWeight={700}>USD {(stats.totalPayable + stats.totalReceivable).toLocaleString()}</Typography>
              <Typography variant="caption">Total Volume (sample)</Typography>
            </CardContent>
          </Card>
        </Grid>
      </Grid>

      {/* RECENT INVOICES */}
      <Card variant="outlined" sx={{ mb: 3 }}>
        <CardContent>
          <Typography variant="subtitle1" fontWeight={600} gutterBottom>
            Recent Supplier Invoices (Last 5)
          </Typography>
          {recentInvoices.length === 0 ? (
            <Typography variant="body2" color="text.secondary" sx={{ py: 2, textAlign: 'center' }}>
              No supplier invoices yet. Create via Supplier Invoice (PO Related). Table supplier_invoices with RLS tenant_id.
            </Typography>
          ) : (
            <Box sx={{ overflowX: 'auto' }}>
              <Table size="small">
                <TableHead>
                  <TableRow>
                    <TableCell>Invoice No</TableCell>
                    <TableCell>Vendor</TableCell>
                    <TableCell>Amount</TableCell>
                    <TableCell>Status</TableCell>
                    <TableCell>Created</TableCell>
                  </TableRow>
                </TableHead>
                <TableBody>
                  {recentInvoices.map((inv: any) => (
                    <TableRow key={inv.id} hover>
                      <TableCell><Typography variant="body2" fontFamily="monospace" fontWeight={600}>{inv.invoice_no || inv.id.slice(0, 8)}</Typography></TableCell>
                      <TableCell>{inv.vendor_name || "-"}</TableCell>
                      <TableCell>{inv.total_amount ? `USD ${Number(inv.total_amount).toLocaleString()}` : "-"}</TableCell>
                      <TableCell><Chip label={inv.status || "draft"} size="small" variant="outlined" sx={{ textTransform: "capitalize" }} /></TableCell>
                      <TableCell><Typography variant="caption">{inv.created_at ? new Date(inv.created_at).toLocaleDateString() : "-"}</Typography></TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </Box>
          )}
        </CardContent>
      </Card>

      {/* QUICK LINKS */}
      <Typography variant="subtitle1" fontWeight={600} gutterBottom>
        Quick Links
      </Typography>
      <Grid container spacing={2}>
        {quickLinks.map((link) => (
          <Grid item xs={12} sm={6} md={4} key={link.to}>
            <Card variant="outlined">
              <CardActionArea component={RouterLink} to={link.to} sx={{ height: '100%' }}>
                <CardContent sx={{ display: 'flex', gap: 2, alignItems: 'flex-start' }}>
                  <Box sx={{ color: 'primary.main' }}>{link.icon}</Box>
                  <Box>
                    <Typography variant="subtitle1" fontWeight={600}>
                      {link.label}
                    </Typography>
                    <Typography variant="body2" color="text.secondary">
                      {link.description}
                    </Typography>
                  </Box>
                </CardContent>
              </CardActionArea>
            </Card>
          </Grid>
        ))}
      </Grid>

      <Paper variant="outlined" sx={{ p: 2, mt: 3, bgcolor: 'action.hover' }}>
        <Typography variant="caption" color="text.secondary" sx={{ display: 'flex', alignItems: 'center', gap: 1 }}>
          <CheckCircle fontSize="small" />
          Dashboard now live: queries supplier_invoices, receivable_invoices, expenditure_slips, cash_bank_transactions for real counts. Outstanding totals are sample from first 5 rows — replace with SUM query for full totals. Next: Add chart for monthly spend (BarChart) and cash position trend.
        </Typography>
      </Paper>
    </Box>
  );
}

