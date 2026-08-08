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
  Description,
  ReceiptLong,
  AssignmentTurnedIn,
  ShoppingCart,
  BarChart,
  Assignment,
  CheckCircle,
  Warning,
  Inventory2,
} from '@mui/icons-material';
import { supabase } from '../../lib/supabaseClient';
import { useAuth } from '../../lib/authContext';

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
  { label: 'New Material Request', description: 'Request new material card creation', to: '/requests/new-material', icon: <Inventory2 fontSize="large" /> },
  { label: 'Request Tracking', description: 'Search requests by status across the pipeline', to: '/procurement/request-tracking', icon: <BarChart fontSize="large" /> },
  { label: 'Material Quantity', description: 'Check material quantity and receipts', to: '/requests/material-quantity', icon: <Assignment fontSize="large" /> },
];

interface Stats {
  myRequests: number;
  openRequests: number;
  pendingApprovals: number;
  materialRequests: number;
  offersPending: number;
  totalRequests: number;
}

interface RecentRequest {
  id: string;
  item_description: string;
  quantity: number;
  status: string;
  created_at: string;
}

export default function PurchasingDashboard() {
  const { session } = useAuth();
  const [stats, setStats] = useState<Stats>({
    myRequests: 0,
    openRequests: 0,
    pendingApprovals: 0,
    materialRequests: 0,
    offersPending: 0,
    totalRequests: 0,
  });
  const [recent, setRecent] = useState<RecentRequest[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const fetchDashboard = async () => {
      setLoading(true);

      // Fetch from requests table - mirrors get_my_approval_queue RPC logic but simplified
      const [myRequestsRes, openRequestsRes, materialRequestsRes, offersRes, recentRes] = await Promise.all([
        supabase.from("requests").select("id", { count: "exact", head: true }).eq("requester_id", session?.user?.id || ""),
        supabase.from("requests").select("id", { count: "exact", head: true }).eq("status", "open"),
        supabase.from("material_requests").select("id", { count: "exact", head: true }),
        supabase.from("request_offers").select("id", { count: "exact", head: true }).is("submitted_at", null),
        supabase.from("requests").select("id, item_description, quantity, status, created_at").order("created_at", { ascending: false }).limit(5),
      ]);

      // For approval queue count, try RPC, fallback to open count
      let approvalCount = 0;
      try {
        const { data: queueData } = await supabase.rpc("get_my_approval_queue");
        approvalCount = (queueData as any[])?.length || 0;
      } catch {
        approvalCount = openRequestsRes.count || 0;
      }

      setStats({
        myRequests: myRequestsRes.count || 0,
        openRequests: openRequestsRes.count || 0,
        pendingApprovals: approvalCount,
        materialRequests: materialRequestsRes.count || 0,
        offersPending: offersRes.count || 0,
        totalRequests: openRequestsRes.count || 0,
      });

      if (recentRes.data) setRecent(recentRes.data as RecentRequest[]);
      setLoading(false);
    };

    if (session?.user?.id) fetchDashboard();
  }, [session?.user?.id]);

  const getStatusColor = (status: string) => {
    if (status === 'open') return 'primary';
    if (status === 'closed') return 'success';
    if (status === 'rejected') return 'error';
    return 'default';
  };

  if (loading) {
    return (
      <Box sx={{ display: 'flex', justifyContent: 'center', p: 4 }}>
        <CircularProgress />
      </Box>
    );
  }

  return (
    <Box>
      <Typography variant="h5" gutterBottom>
        Purchasing and Logistics
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        Overview of requests, approvals, offers and material cards. Real data from requests and material_requests tables.
      </Typography>

      {/* KPI CARDS */}
      <Grid container spacing={2} sx={{ mb: 3 }}>
        <Grid item xs={12} sm={6} md={3}>
          <Card sx={{ bgcolor: 'primary.light', color: 'primary.contrastText' }}>
            <CardContent>
              <Box sx={{ display: 'flex', alignItems: 'center', gap: 1, mb: 1 }}>
                <ReceiptLong />
                <Typography variant="subtitle2">My Requests</Typography>
              </Box>
              <Typography variant="h4" fontWeight={700}>{stats.myRequests}</Typography>
              <Typography variant="caption" sx={{ opacity: 0.8 }}>Submitted by you</Typography>
            </CardContent>
          </Card>
        </Grid>

        <Grid item xs={12} sm={6} md={3}>
          <Card sx={{ bgcolor: 'warning.light' }}>
            <CardContent>
              <Box sx={{ display: 'flex', alignItems: 'center', gap: 1, mb: 1 }}>
                <Warning />
                <Typography variant="subtitle2">Pending Approvals</Typography>
              </Box>
              <Typography variant="h4" fontWeight={700}>{stats.pendingApprovals}</Typography>
              <Typography variant="caption">Waiting on your decision</Typography>
            </CardContent>
          </Card>
        </Grid>

        <Grid item xs={12} sm={6} md={3}>
          <Card sx={{ bgcolor: 'info.light' }}>
            <CardContent>
              <Box sx={{ display: 'flex', alignItems: 'center', gap: 1, mb: 1 }}>
                <Assignment />
                <Typography variant="subtitle2">Open Requests</Typography>
              </Box>
              <Typography variant="h4" fontWeight={700}>{stats.openRequests}</Typography>
              <Typography variant="caption">In workflow</Typography>
            </CardContent>
          </Card>
        </Grid>

        <Grid item xs={12} sm={6} md={3}>
          <Card>
            <CardContent>
              <Box sx={{ display: 'flex', alignItems: 'center', gap: 1, mb: 1 }}>
                <Inventory2 />
                <Typography variant="subtitle2">Material Requests</Typography>
              </Box>
              <Typography variant="h4" fontWeight={700}>{stats.materialRequests}</Typography>
              <Typography variant="caption">New material cards</Typography>
            </CardContent>
          </Card>
        </Grid>

        <Grid item xs={6} sm={3}>
          <Card variant="outlined">
            <CardContent sx={{ p: 1.5, textAlign: 'center' }}>
              <Typography variant="h6" color="primary.main" fontWeight={700}>{stats.totalRequests}</Typography>
              <Typography variant="caption">Total Open</Typography>
            </CardContent>
          </Card>
        </Grid>
        <Grid item xs={6} sm={3}>
          <Card variant="outlined">
            <CardContent sx={{ p: 1.5, textAlign: 'center' }}>
              <Typography variant="h6" color="warning.main" fontWeight={700}>{stats.offersPending}</Typography>
              <Typography variant="caption">Offers Pending</Typography>
            </CardContent>
          </Card>
        </Grid>
      </Grid>

      {/* RECENT REQUESTS */}
      <Card variant="outlined" sx={{ mb: 3 }}>
        <CardContent>
          <Typography variant="subtitle1" fontWeight={600} gutterBottom>
            Recent Requests (Last 5)
          </Typography>
          {recent.length === 0 ? (
            <Typography variant="body2" color="text.secondary" sx={{ py: 2, textAlign: 'center' }}>
              No requests yet. Create first via New Request. Table requests with RLS tenant_id.
            </Typography>
          ) : (
            <Box sx={{ overflowX: 'auto' }}>
              <Table size="small">
                <TableHead>
                  <TableRow>
                    <TableCell>Item Description</TableCell>
                    <TableCell>Quantity</TableCell>
                    <TableCell>Status</TableCell>
                    <TableCell>Created</TableCell>
                  </TableRow>
                </TableHead>
                <TableBody>
                  {recent.map((r) => (
                    <TableRow key={r.id} hover>
                      <TableCell><Typography variant="body2" sx={{ maxWidth: 350, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{r.item_description}</Typography></TableCell>
                      <TableCell>{r.quantity}</TableCell>
                      <TableCell><Chip label={r.status} size="small" color={getStatusColor(r.status) as any} sx={{ textTransform: 'capitalize' }} /></TableCell>
                      <TableCell><Typography variant="caption">{new Date(r.created_at).toLocaleDateString()}</Typography></TableCell>
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
          Dashboard now live: queries requests table for my requests, open requests, approval queue via get_my_approval_queue RPC, material_requests count. Next: Add chart for requests by status/stage.
        </Typography>
      </Paper>
    </Box>
  );
}
