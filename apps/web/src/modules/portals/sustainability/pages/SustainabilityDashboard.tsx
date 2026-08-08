import { useEffect, useState } from "react";
import { Box, Card, CardContent, CircularProgress, Grid, Typography } from "@mui/material";
import { supabase } from "../../../../lib/supabaseClient";

export default function SustainabilityDashboard() {
  const [stats, setStats] = useState({ initiatives: 0, activeInitiatives: 0, metrics: 0, audits: 0, certifications: 0 });
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const fetch = async () => {
      setLoading(true);
      const [initRes, metricRes, auditRes, certRes] = await Promise.all([
        supabase.from("sustainability_initiatives").select("id, status", { count: "exact" }),
        supabase.from("sustainability_metrics").select("id", { count: "exact", head: true }),
        supabase.from("sustainability_audits").select("id", { count: "exact", head: true }),
        supabase.from("sustainability_certifications").select("id", { count: "exact", head: true }),
      ]);
      setStats({
        initiatives: initRes.count || initRes.data?.length || 0,
        activeInitiatives: (initRes.data as any[])?.filter((i: any) => i.status === 'in_progress').length || 0,
        metrics: metricRes.count || 0,
        audits: auditRes.count || 0,
        certifications: certRes.count || 0,
      });
      setLoading(false);
    };
    fetch();
  }, []);

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Sustainability Dashboard</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>Carbon, energy, waste KPIs, initiative progress, audits, certifications.</Typography>
      <Grid container spacing={2}>
        <Grid item xs={12} sm={6} md={3}><Card><CardContent><Typography variant="caption">Initiatives</Typography><Typography variant="h4" fontWeight={700}>{stats.initiatives}</Typography><Typography variant="caption" color="success.main">{stats.activeInitiatives} active</Typography></CardContent></Card></Grid>
        <Grid item xs={12} sm={6} md={3}><Card><CardContent><Typography variant="caption">Metrics Recorded</Typography><Typography variant="h4" fontWeight={700}>{stats.metrics}</Typography></CardContent></Card></Grid>
        <Grid item xs={12} sm={6} md={3}><Card><CardContent><Typography variant="caption">Audits</Typography><Typography variant="h4" fontWeight={700}>{stats.audits}</Typography></CardContent></Card></Grid>
        <Grid item xs={12} sm={6} md={3}><Card><CardContent><Typography variant="caption">Certifications</Typography><Typography variant="h4" fontWeight={700}>{stats.certifications}</Typography></CardContent></Card></Grid>
      </Grid>
    </Box>
  );
}
