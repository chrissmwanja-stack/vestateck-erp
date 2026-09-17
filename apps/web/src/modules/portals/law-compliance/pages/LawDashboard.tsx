import { useEffect, useState } from "react";
import { Box, Card, CardContent, CircularProgress, Grid, Typography } from "@mui/material";
import { useNavigate } from "react-router-dom";
import { supabase } from "../../../../lib/supabaseClient";
import { PieChart, Pie, Cell, Tooltip as ReTooltip, Legend, ResponsiveContainer } from "recharts";

const COLORS = ["#1976d2", "#ed6c02", "#2e7d32", "#9c27b0", "#d32f2f", "#0288d1"];

export default function LawDashboard() {
  const navigate = useNavigate();
  const [stats, setStats] = useState({ contracts: 0, activeContracts: 0, expiringSoon: 0, cases: 0, openCases: 0, compliancePending: 0, complianceOverdue: 0 });
  const [caseStatusPie, setCaseStatusPie] = useState<any[]>([]);
  const [contractStatusPie, setContractStatusPie] = useState<any[]>([]);
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

    const caseMap: Record<string, number> = {};
    cases.forEach((c: any) => { caseMap[c.status] = (caseMap[c.status] || 0) + 1; });
    setCaseStatusPie(Object.entries(caseMap).map(([name, value]) => ({ name, value })));
    const contractMap: Record<string, number> = {};
    contracts.forEach((c: any) => { contractMap[c.status] = (contractMap[c.status] || 0) + 1; });
    setContractStatusPie(Object.entries(contractMap).map(([name, value]) => ({ name, value })));
    setLoading(false);
  };

  useEffect(() => { fetchStats(); }, []);

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  const cardSx = { cursor: "pointer", transition: "transform 0.15s", "&:hover": { transform: "translateY(-2px)", boxShadow: 4 } };

  return (
    <Box sx={{ p: 3, maxWidth: 1300 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Law and Compliance Dashboard</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>Click a card to drill down • KPIs, case/contract status distribution, expiries and overdue compliance.</Typography>

      <Grid container spacing={2} sx={{ mb: 3 }}>
        <Grid item xs={12} sm={6} md={3}><Card sx={cardSx} onClick={() => navigate("/law-compliance/contracts")}><CardContent><Typography variant="caption" color="text.secondary">Total Contracts</Typography><Typography variant="h4" fontWeight={700}>{stats.contracts}</Typography><Typography variant="caption" color="success.main">{stats.activeContracts} active • {stats.expiringSoon} expiring soon</Typography></CardContent></Card></Grid>
        <Grid item xs={12} sm={6} md={3}><Card sx={{ ...cardSx, bgcolor: stats.expiringSoon > 0 ? "warning.light" : "grey.50" }} onClick={() => navigate("/law-compliance/reports/expiry")}><CardContent><Typography variant="caption">Expiring Soon (30 days)</Typography><Typography variant="h4" fontWeight={700}>{stats.expiringSoon}</Typography><Typography variant="caption">Active contracts</Typography></CardContent></Card></Grid>
        <Grid item xs={12} sm={6} md={3}><Card sx={cardSx} onClick={() => navigate("/law-compliance/cases")}><CardContent><Typography variant="caption" color="text.secondary">Total Cases</Typography><Typography variant="h4" fontWeight={700}>{stats.cases}</Typography><Typography variant="caption">{stats.openCases} open/in progress</Typography></CardContent></Card></Grid>
        <Grid item xs={12} sm={6} md={3}><Card sx={{ ...cardSx, bgcolor: stats.complianceOverdue > 0 ? "error.light" : "grey.50" }} onClick={() => navigate("/law-compliance/compliance")}><CardContent><Typography variant="caption">Compliance</Typography><Typography variant="h5" fontWeight={700}>{stats.compliancePending} pending</Typography><Typography variant="caption" color="error.main">{stats.complianceOverdue} overdue</Typography></CardContent></Card></Grid>
      </Grid>

      <Grid container spacing={2}>
        <Grid item xs={12} md={6}><Card><CardContent><Typography variant="subtitle2" fontWeight={700} gutterBottom>Cases by Status</Typography>{caseStatusPie.length === 0 ? <Typography variant="body2" color="text.secondary" sx={{ py: 4, textAlign: "center" }}>No cases yet.</Typography> : <Box sx={{ height: 280 }}><ResponsiveContainer width="100%" height="100%"><PieChart><Pie data={caseStatusPie} dataKey="value" nameKey="name" cx="50%" cy="50%" outerRadius={90} label={({ name, percent }) => `${name} ${((percent ?? 0)*100).toFixed(0)}%`}>{caseStatusPie.map((_, i) => <Cell key={i} fill={COLORS[i % COLORS.length]} />)}</Pie><ReTooltip /><Legend /></PieChart></ResponsiveContainer></Box>}</CardContent></Card></Grid>
        <Grid item xs={12} md={6}><Card><CardContent><Typography variant="subtitle2" fontWeight={700} gutterBottom>Contracts by Status</Typography>{contractStatusPie.length === 0 ? <Typography variant="body2" color="text.secondary" sx={{ py: 4, textAlign: "center" }}>No contracts yet.</Typography> : <Box sx={{ height: 280 }}><ResponsiveContainer width="100%" height="100%"><PieChart><Pie data={contractStatusPie} dataKey="value" nameKey="name" cx="50%" cy="50%" outerRadius={90} label={({ name, percent }) => `${name} ${((percent ?? 0)*100).toFixed(0)}%`}>{contractStatusPie.map((_, i) => <Cell key={i} fill={COLORS[(i+2) % COLORS.length]} />)}</Pie><ReTooltip /><Legend /></PieChart></ResponsiveContainer></Box>}</CardContent></Card></Grid>
      </Grid>
    </Box>
  );
}
