import { Link as RouterLink } from 'react-router-dom';
import { Box, Typography, Paper, Grid, Card, CardActionArea, CardContent } from '@mui/material';
import { ReceiptLong, AccountBalance, Payments, BarChart } from '@mui/icons-material';

interface QuickLink {
  label: string;
  description: string;
  to: string;
  icon: React.ReactNode;
}

const quickLinks: QuickLink[] = [
  { label: 'Supplier Invoice (PO Related)', description: 'Enter an invoice against an existing PO', to: '/financial-management/invoices/supplier-invoice-po', icon: <ReceiptLong fontSize="large" /> },
  { label: 'Expenditure Slips', description: 'Record non-invoice expenditure', to: '/financial-management/expenditure-slips', icon: <Payments fontSize="large" /> },
  { label: 'Cash and Bank Payments', description: 'Settle invoices, slips, and receivables', to: '/financial-management/cash-bank-operations', icon: <AccountBalance fontSize="large" /> },
  { label: 'Reports Summary', description: 'Supplier invoices, receivables, and cash position at a glance', to: '/financial-management/reports', icon: <BarChart fontSize="large" /> },
];

// Placeholder landing screen for the Financial Management portal.
// Real dashboard content (outstanding invoice totals, cash position,
// pending approvals) comes later -- same pattern as PurchasingDashboard.
export default function FinancialDashboard() {
  return (
    <Box>
      <Typography variant="h5" gutterBottom>
        Financial Management and Financial Reporting
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        Dashboard content is coming soon. In the meantime, here's where you'll spend most of your time.
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
        <Typography variant="caption" color="text.secondary">
          Coming later: outstanding invoice totals, cash position, and pending approvals assigned to you.
        </Typography>
      </Paper>
    </Box>
  );
}