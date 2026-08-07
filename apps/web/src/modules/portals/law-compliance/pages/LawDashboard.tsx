import { useEffect, useState } from "react";
import { Box, Card, CardContent, CircularProgress, Grid, Typography } from "@mui/material";
import { supabase } from "../../../../lib/supabaseClient";

export default function LawDashboard() {
  const [stats, setStats] = useState({ contracts: 0, activeContracts: 0, expiringSoon: 0, cases: 0, openCases: 0, compliancePending: 0, complianceOverdue: 0 });
  const [loading, setLoading] = useState(true);

  const fetchStats = async () => {
    setLoading(true);
    const [contractsRes, casesRes, complianceRes] = await Promise.all([
      supabase.from("law_contracts").select("id, status, end_date"),
      supabase.from("law_cases").select("id, status"),
      supabase.from("law_compliance_register").select("id, status, due_date"),
    ]);

    const contracts = (contractsRes.data as any[]) || [];
    const cases = (casesRes.data as any[]) || [];
    const compliance = (complianceRes.data as any[]) || [];

    const now = new Date().getTime();
    const thirtyDays = 30 * 24 * 60 * 60 * 1000;

    const expiringSoon = contracts.filter((c: any) => {
      if (!c.end_date || c.status !== 'active') return false;
      const diff = new Date(c.end_date).getTime() - now;
      return diff > 0 && diff < thirtyDays;
    }).length;

    const overdueCompliance = compliance.filter((c: any) => {
      if (!c.due_date || c.status === 'compliant') return false;
      return new Date(c.due_date).getTime() < now;
    }).length;

    setStats({
      contracts: contracts.length,
      activeContracts: contracts.filter((c: any) => c.status === 'active').length,
      expiringSoon,
      cases: cases.length,
      openCases: cases.filter((c: any) => c.status === 'open' || c.status === 'in_progress').length,
      compliancePending: compliance.filter((c: any) => c.status === 'pending').length,
      complianceOverdue: overdueCompliance,
    });
    setLoading(false);
  };

  useEffect(() => { fetchStats(); }, []);

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Law and Compliance Dashboard</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>KPIs: contracts, cases, compliance due, expiry tracking.</Typography>

      <Grid container spacing={2}>
        <Grid item xs={12} sm={6} md={3}><Card><CardContent><Typography variant="caption" color="text.secondary">Total Contracts</Typography><Typography variant="h4" fontWeight={700}>{stats.contracts}</Typography><Typography variant="caption" color="success.main">{stats.activeContracts} active</Typography></CardContent></Card></Grid>
        <Grid item xs={12} sm={6} md={3}><Card sx={{ bgcolor: "warning.light" }}><CardContent><Typography variant="caption">Expiring Soon (30 days)</Typography><Typography variant="h4" fontWeight={700}>{stats.expiringSoon}</Typography></CardContent></Card></Grid>
        <Grid item xs={12} sm={6} md={3}><Card><CardContent><Typography variant="caption" color="text.secondary">Total Cases</Typography><Typography variant="h4" fontWeight={700}>{stats.cases}</Typography><Typography variant="caption">{stats.openCases} open/in progress</Typography></CardContent></Card></Grid>
        <Grid item xs={12} sm={6} md={3}><Card sx={{ bgcolor: stats.complianceOverdue > 0 ? "error.light" : "grey.100" }}><CardContent><Typography variant="caption">Compliance</Typography><Typography variant="h5" fontWeight={700}>{stats.compliancePending} pending</Typography><Typography variant="caption" color="error.main">{stats.complianceOverdue} overdue</Typography></CardContent></Card></Grid>
      </Grid>
    </Box>
  );
}
