import { Link as RouterLink } from 'react-router-dom';
import { Box, Typography, Paper, Grid, Card, CardActionArea, CardContent } from '@mui/material';
import {
  Description,
  ReceiptLong,
  AssignmentTurnedIn,
  ShoppingCart,
  BarChart,
} from '@mui/icons-material';

interface QuickLink {
  label: string;
  description: string;
  to: string;
  icon: React.ReactNode;
}

const quickLinks: QuickLink[] = [
  { label: 'New Request', description: 'Submit a new material or service request', to: '/requests/new', icon: <Description fontSize="large" /> },
  { label: 'My Requests', description: 'Track requests you have submitted', to: '/requests/my-requests', icon: <ReceiptLong fontSize="large" /> },
  { label: 'Request Approval', description: 'Review requests waiting on your decision', to: '/approvals', icon: <AssignmentTurnedIn fontSize="large" /> },
  { label: 'Offer Entry', description: 'Enter vendor quotations for a request', to: '/offers/entry', icon: <ShoppingCart fontSize="large" /> },
  { label: 'Request Tracking', description: 'Search requests by status across the pipeline', to: '/procurement/request-tracking', icon: <BarChart fontSize="large" /> },
];

// Placeholder landing screen for the Purchasing and Logistics portal.
// Real dashboard content (open request counts, pending approvals, etc.)
// comes later -- this just gives the portal a landing page with quick
// links instead of dropping the user straight onto a form.
export default function PurchasingDashboard() {
  return (
    <Box>
      <Typography variant="h5" gutterBottom>
        Purchasing and Logistics
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
          Coming later: open request counts, pending approvals assigned to you, and recent PO activity.
        </Typography>
      </Paper>
    </Box>
  );
}