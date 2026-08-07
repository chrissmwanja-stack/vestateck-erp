import { useEffect, useState } from "react";
import { Box, Card, CardContent, CircularProgress, Grid, Typography } from "@mui/material";
import { supabase } from "../../../../lib/supabaseClient";

export default function MachineDashboard() {
  const [stats, setStats] = useState({ total: 0, available: 0, inUse: 0, maintenance: 0, breakdown: 0 });
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const fetch = async () => {
      setLoading(true);
      const { data, count } = await supabase.from("machines").select("status", { count: "exact" });
      const list = (data as any[]) || [];
      setStats({
        total: count || list.length,
        available: list.filter((m: any) => m.status === 'available').length,
        inUse: list.filter((m: any) => m.status === 'in_use').length,
        maintenance: list.filter((m: any) => m.status === 'maintenance').length,
        breakdown: list.filter((m: any) => m.status === 'breakdown').length,
      });
      setLoading(false);
    };
    fetch();
  }, []);

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Machine Operation Dashboard</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>Utilization, downtime, fuel, maintenance overview.</Typography>
      <Grid container spacing={2}>
        <Grid item xs={12} sm={6} md={2.4}><Card><CardContent><Typography variant="caption">Total Machines</Typography><Typography variant="h4" fontWeight={700}>{stats.total}</Typography></CardContent></Card></Grid>
        <Grid item xs={12} sm={6} md={2.4}><Card sx={{ bgcolor: "success.light" }}><CardContent><Typography variant="caption">Available</Typography><Typography variant="h4" fontWeight={700}>{stats.available}</Typography></CardContent></Card></Grid>
        <Grid item xs={12} sm={6} md={2.4}><Card sx={{ bgcolor: "info.light" }}><CardContent><Typography variant="caption">In Use</Typography><Typography variant="h4" fontWeight={700}>{stats.inUse}</Typography></CardContent></Card></Grid>
        <Grid item xs={12} sm={6} md={2.4}><Card sx={{ bgcolor: "warning.light" }}><CardContent><Typography variant="caption">Maintenance</Typography><Typography variant="h4" fontWeight={700}>{stats.maintenance}</Typography></CardContent></Card></Grid>
        <Grid item xs={12} sm={6} md={2.4}><Card sx={{ bgcolor: "error.light" }}><CardContent><Typography variant="caption">Breakdown</Typography><Typography variant="h4" fontWeight={700}>{stats.breakdown}</Typography></CardContent></Card></Grid>
      </Grid>
    </Box>
  );
}
