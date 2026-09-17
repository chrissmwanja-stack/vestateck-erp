import { useEffect, useState } from "react";
import { Box, Card, CardContent, CircularProgress, Grid, Typography, Button } from "@mui/material";
import { supabase } from "../../../../lib/supabaseClient";
import { useNavigate } from "react-router-dom";
import { PieChart, Pie, Cell, Tooltip as ReTooltip, ResponsiveContainer, Legend, LineChart, Line, XAxis, YAxis } from "recharts";

const COLORS = ["#2e7d32", "#1976d2", "#ed6c02", "#9c27b0", "#00838f", "#6d4c41"];

export default function SustainabilityDashboard() {
  const navigate = useNavigate();
  const [stats, setStats] = useState({ initiatives: 0, activeInitiatives: 0, metrics: 0, audits: 0, certifications: 0 });
  const [byStatus, setByStatus] = useState<{ name: string; value: number }[]>([]);
  const [metricsTrend, setMetricsTrend] = useState<{ month: string; carbon: number; energy: number; waste: number }[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const fetch = async () => {
      setLoading(true);
      const [initRes, metricRes, auditRes, certRes, metricsByMonthRes] = await Promise.all([
        supabase.from("sustainability_initiatives").select("id, status", { count: "exact" }),
        supabase.from("sustainability_metrics").select("id, type, value, recorded_date").limit(500),
        supabase.from("sustainability_audits").select("id", { count: "exact", head: true }),
        supabase.from("sustainability_certifications").select("id", { count: "exact", head: true }),
        supabase.from("sustainability_metrics").select("type, value, recorded_date").order("recorded_date").limit(500),
      ]);
      const initiatives = (initRes.data as any[]) || [];
      setStats({
        initiatives: initRes.count || initiatives.length,
        activeInitiatives: initiatives.filter((i: any) => i.status === 'in_progress').length,
        metrics: metricRes.count || (metricRes.data as any[])?.length || 0,
        audits: auditRes.count || 0,
        certifications: certRes.count || 0,
      });

      const statusMap: Record<string, number> = {};
      initiatives.forEach((i: any) => { statusMap[i.status] = (statusMap[i.status] || 0) + 1; });
      setByStatus(Object.entries(statusMap).map(([name, value]) => ({ name, value })));

      // metrics trend by month per type
      const metrics = (metricsByMonthRes.data as any[]) || [];
      const byMonth: Record<string, { carbon: number; energy: number; waste: number }> = {};
      metrics.forEach((m: any) => {
        const key = m.recorded_date?.slice(0,7);
        if (!key) return;
        if (!byMonth[key]) byMonth[key] = { carbon:0, energy:0, waste:0 };
        const v = Number(m.value) || 0;
        if (m.type === "carbon") byMonth[key].carbon += v;
        else if (m.type === "energy") byMonth[key].energy += v;
        else if (m.type === "waste") byMonth[key].waste += v;
      });
      const sorted = Object.entries(byMonth).sort(([a],[b])=>a.localeCompare(b)).slice(-6).map(([month, vals])=>({ month: month.slice(5), ...vals }));
      setMetricsTrend(sorted);
      setLoading(false);
    };
    fetch();
  }, []);

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Sustainability Dashboard</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>Carbon, energy, waste KPIs, initiative progress, audits, certifications. Click cards to drill.</Typography>
      <Grid container spacing={2} sx={{ mb: 3 }}>
        <Grid item xs={12} sm={6} md={3}><Card sx={{ cursor:"pointer" }} onClick={()=>navigate("/sustainability/initiatives")}><CardContent><Typography variant="caption">Initiatives</Typography><Typography variant="h4" fontWeight={700}>{stats.initiatives}</Typography><Typography variant="caption" color="success.main">{stats.activeInitiatives} active</Typography></CardContent></Card></Grid>
        <Grid item xs={12} sm={6} md={3}><Card sx={{ cursor:"pointer" }} onClick={()=>navigate("/sustainability/metrics/carbon")}><CardContent><Typography variant="caption">Metrics Recorded</Typography><Typography variant="h4" fontWeight={700}>{stats.metrics}</Typography></CardContent></Card></Grid>
        <Grid item xs={12} sm={6} md={3}><Card sx={{ cursor:"pointer" }} onClick={()=>navigate("/sustainability/audits")}><CardContent><Typography variant="caption">Audits</Typography><Typography variant="h4" fontWeight={700}>{stats.audits}</Typography></CardContent></Card></Grid>
        <Grid item xs={12} sm={6} md={3}><Card sx={{ cursor:"pointer" }} onClick={()=>navigate("/sustainability/certifications")}><CardContent><Typography variant="caption">Certifications</Typography><Typography variant="h4" fontWeight={700}>{stats.certifications}</Typography></CardContent></Card></Grid>
      </Grid>

      <Grid container spacing={2}>
        <Grid item xs={12} md={5}>
          <Card variant="outlined"><CardContent>
            <Typography variant="subtitle2" fontWeight={700} gutterBottom>Initiatives by Status</Typography>
            {byStatus.length===0 ? <Typography variant="body2" color="text.secondary" sx={{ py: 4, textAlign: "center" }}>No initiatives.</Typography> : (
              <ResponsiveContainer width="100%" height={240}>
                <PieChart>
                  <Pie data={byStatus} dataKey="value" nameKey="name" cx="50%" cy="50%" outerRadius={80} label={({name,value})=>`${name} ${value}`}>
                    {byStatus.map((_,i)=><Cell key={i} fill={COLORS[i % COLORS.length]} />)}
                  </Pie>
                  <ReTooltip /><Legend />
                </PieChart>
              </ResponsiveContainer>
            )}
          </CardContent></Card>
        </Grid>
        <Grid item xs={12} md={7}>
          <Card variant="outlined"><CardContent>
            <Typography variant="subtitle2" fontWeight={700} gutterBottom>Metrics Trend (last 6 months)</Typography>
            {metricsTrend.length===0 ? <Typography variant="body2" color="text.secondary" sx={{ py: 4, textAlign: "center" }}>No metrics yet. Add Carbon/Energy/Waste to see trend.</Typography> : (
              <ResponsiveContainer width="100%" height={240}>
                <LineChart data={metricsTrend}>
                  <XAxis dataKey="month" fontSize={12} />
                  <YAxis fontSize={12} />
                  <ReTooltip /><Legend />
                  <Line type="monotone" dataKey="carbon" stroke="#2e7d32" name="Carbon tCO2e" dot />
                  <Line type="monotone" dataKey="energy" stroke="#ed6c02" name="Energy kWh" dot />
                  <Line type="monotone" dataKey="waste" stroke="#6d4c41" name="Waste kg" dot />
                </LineChart>
              </ResponsiveContainer>
            )}
            <Box sx={{ display:"flex", gap:1, mt:1, flexWrap:"wrap" }}>
              <Button size="small" variant="outlined" onClick={()=>navigate("/sustainability/metrics/carbon")}>Carbon</Button>
              <Button size="small" variant="outlined" onClick={()=>navigate("/sustainability/metrics/energy")}>Energy</Button>
              <Button size="small" variant="outlined" onClick={()=>navigate("/sustainability/metrics/waste")}>Waste</Button>
              <Button size="small" variant="outlined" onClick={()=>navigate("/sustainability/reports/sustainability")}>Report</Button>
            </Box>
          </CardContent></Card>
        </Grid>
      </Grid>
    </Box>
  );
}
