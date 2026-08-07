import { Link as RouterLink } from 'react-router-dom';
import { Box, Typography, Paper, Grid, Card, CardActionArea, CardContent } from '@mui/material';
import {
  ConfirmationNumber,
  ReceiptLong,
  AssignmentTurnedIn,
  Build,
} from '@mui/icons-material';

interface QuickLink {
  label: string;
  description: string;
  to: string;
  icon: React.ReactNode;
}

const quickLinks: QuickLink[] = [
  { label: 'New Ticket', description: 'Report an issue or request help', to: '/it-support/new-ticket', icon: <ConfirmationNumber fontSize="large" /> },
  { label: 'My Tickets', description: 'Track tickets you have filed', to: '/it-support/my-tickets', icon: <ReceiptLong fontSize="large" /> },
  { label: 'All Tickets', description: 'IT Support queue (staff only)', to: '/it-support/all-tickets', icon: <AssignmentTurnedIn fontSize="large" /> },
  { label: 'Ticket Approvals', description: 'Tickets waiting on sign-off', to: '/it-support/approvals', icon: <AssignmentTurnedIn fontSize="large" /> },
  { label: 'Problem Management', description: 'Recurring issues grouped by root cause', to: '/it-support/problems', icon: <Build fontSize="large" /> },
];

// Placeholder landing screen for the IT Support portal, same pattern as
// PurchasingDashboard.tsx / FinancialDashboard.tsx. Real dashboard
// content (open ticket counts, SLA status, pending approvals) comes
// later.
export default function ItSupportDashboard() {
  return (
    <Box>
      <Typography variant="h5" gutterBottom>
        IT Support
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
          Coming later: open ticket counts, SLA status, and approvals pending your decision.
        </Typography>
      </Paper>
    </Box>
  );
}