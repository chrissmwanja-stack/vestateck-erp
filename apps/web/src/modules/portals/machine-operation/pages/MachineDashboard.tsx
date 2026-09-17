import { useEffect, useState, useMemo } from "react";
import { Box, Card, CardContent, CircularProgress, Grid, Typography, Button, LinearProgress } from "@mui/material";
import { supabase } from "../../../../lib/supabaseClient";
import { useNavigate } from "react-router-dom";
import { PieChart, Pie, Cell, ResponsiveContainer, Legend, Tooltip as ReTooltip, LineChart, Line, XAxis, YAxis } from "recharts";

const STATUS_COLORS: Record<string, string> = {
  available: "#2e7d32",
  in_use: "#1976d2",
  maintenance: "#ed6c02",
  breakdown: "#d32f2f",
  retired: "#9e9e9e",
};

export default function MachineDashboard() {
  const navigate = useNavigate();
  const [stats, setStats] = useState({ total: 0, available: 0, inUse: 0, maintenance: 0, breakdown: 0 });
  const [utilAvg, setUtilAvg] = useState(0);
  const [fuelTotal, setFuelTotal] = useState(0);
  const [maintPending, setMaintPending] = useState(0);
  const [logsTrend, setLogsTrend] = useState<{ date: string; hours: number }[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const fetch = async () => {
      setLoading(true);
      const [machinesRes, logsRes, fuelRes, maintRes, opsLogsRes] = await Promise.all([
        supabase.from("machines").select("status", { count: "exact" }),
        supabase.from("operation_logs").select("hours_used").limit(500),
        supabase.from("fuel_logs").select("fuel_liters, log_date").limit(500),
        supabase.from("maintenance_requests").select("status", { count: "exact" }).in("status", ["scheduled", "in_progress"]),
        supabase.from("operation_logs").select("log_date, hours_used").order("log_date").limit(500),
      ]);
      const list = (machinesRes.data as any[]) || [];
      setStats({
        total: machinesRes.count || list.length,
        available: list.filter((m: any) => m.status === 'available').length,
        inUse: list.filter((m: any) => m.status === 'in_use').length,
        maintenance: list.filter((m: any) => m.status === 'maintenance').length,
        breakdown: list.filter((m: any) => m.status === 'breakdown').length,
      });

      const logs = (logsRes.data as any[]) || [];
      const totalHours = logs.reduce((s: number, l: any) => s + (Number(l.hours_used) || 0), 0);
      // recalc with actual total
      const actualTotal = machinesRes.count || list.length || 1;
      const util = Math.min(100, (totalHours / (actualTotal * 160)) * 100);
      setUtilAvg(util);

      const fuelLogs = (fuelRes.data as any[]) || [];
      const fuel30 = fuelLogs.filter((f: any) => {
        if (!f.log_date) return false;
        const d = new Date(f.log_date).getTime();
        return d > Date.now() - 30*24*60*60*1000;
      }).reduce((s: number, l: any) => s + (Number(l.fuel_liters) || 0), 0);
      setFuelTotal(fuel30);

      setMaintPending(maintRes.count || 0);

      const ops = (opsLogsRes.data as any[]) || [];
      const byDate: Record<string, number> = {};
      for (let i=6; i>=0; i--) {
        const d = new Date(Date.now() - i*24*60*60*1000).toISOString().slice(0,10);
        byDate[d] = 0;
      }
      ops.forEach((o: any) => {
        if (!o.log_date) return;
        const key = o.log_date.slice(0,10);
        if (key in byDate) byDate[key] += Number(o.hours_used) || 0;
      });
      setLogsTrend(Object.entries(byDate).map(([date, hours]) => ({ date: date.slice(5), hours })));

      setLoading(false);
    };
    fetch();
  }, []);

  const pieData = useMemo(() => [
    { name: "Available", value: stats.available },
    { name: "In Use", value: stats.inUse },
    { name: "Maintenance", value: stats.maintenance },
    { name: "Breakdown", value: stats.breakdown },
  ].filter(d => d.value > 0), [stats]);

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Machine Operation Dashboard</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>Utilization, downtime, fuel, maintenance overview. Click cards to drill.</Typography>
      <Grid container spacing={2} sx={{ mb: 3 }}>
        <Grid item xs={12} sm={6} md={2.4}><Card sx={{ cursor:"pointer" }} onClick={()=>navigate("/machine-operation/equipment")}><CardContent><Typography variant="caption">Total Machines</Typography><Typography variant="h4" fontWeight={700}>{stats.total}</Typography></CardContent></Card></Grid>
        <Grid item xs={12} sm={6} md={2.4}><Card sx={{ bgcolor: "success.light" }}><CardContent><Typography variant="caption">Available</Typography><Typography variant="h4" fontWeight={700}>{stats.available}</Typography></CardContent></Card></Grid>
        <Grid item xs={12} sm={6} md={2.4}><Card sx={{ bgcolor: "info.light" }}><CardContent><Typography variant="caption">In Use</Typography><Typography variant="h4" fontWeight={700}>{stats.inUse}</Typography></CardContent></Card></Grid>
        <Grid item xs={12} sm={6} md={2.4}><Card sx={{ bgcolor: "warning.light" }}><CardContent><Typography variant="caption">Maintenance</Typography><Typography variant="h4" fontWeight={700}>{stats.maintenance}</Typography></CardContent></Card></Grid>
        <Grid item xs={12} sm={6} md={2.4}><Card sx={{ bgcolor: "error.light" }}><CardContent><Typography variant="caption">Breakdown</Typography><Typography variant="h4" fontWeight={700}>{stats.breakdown}</Typography></CardContent></Card></Grid>

        <Grid item xs={12} sm={6} md={4}><Card><CardContent><Typography variant="caption">Avg Utilization</Typography><Typography variant="h6" fontWeight={700}>{utilAvg.toFixed(0)}% of 160h/month</Typography><LinearProgress variant="determinate" value={Math.min(100, utilAvg)} sx={{ mt: 1, height: 8 }} color={utilAvg > 80 ? "success" : utilAvg > 50 ? "warning" : "error"} /></CardContent></Card></Grid>
        <Grid item xs={12} sm={6} md={4}><Card><CardContent><Typography variant="caption">Fuel Last 30 Days</Typography><Typography variant="h6" fontWeight={700}>{fuelTotal.toLocaleString()} L</Typography><Typography variant="caption" color="text.secondary">From fuel_logs.fuel_liters</Typography></CardContent></Card></Grid>
        <Grid item xs={12} sm={6} md={4}><Card sx={{ bgcolor: maintPending ? "warning.light" : "white", cursor:"pointer" }} onClick={()=>navigate("/machine-operation/maintenance/schedule")}><CardContent><Typography variant="caption">Pending Maintenance</Typography><Typography variant="h4" fontWeight={700}>{maintPending}</Typography><Typography variant="caption">Scheduled / In Progress</Typography></CardContent></Card></Grid>
      </Grid>

      <Grid container spacing={2}>
        <Grid item xs={12} md={5}>
          <Card variant="outlined"><CardContent>
            <Typography variant="subtitle2" fontWeight={700} gutterBottom>Machines by Status</Typography>
            {pieData.length===0 ? <Typography variant="body2" color="text.secondary" sx={{ py: 4, textAlign:"center" }}>No machines.</Typography> : (
              <ResponsiveContainer width="100%" height={240}>
                <PieChart>
                  <Pie data={pieData} dataKey="value" nameKey="name" cx="50%" cy="50%" outerRadius={80} label={({name,value})=>`${name} ${value}`}>
                    {pieData.map((e,i)=>{ const key = e.name.toLowerCase().replace(" ", "_"); return <Cell key={i} fill={STATUS_COLORS[key] || "#607d8b"} />; })}
                  </Pie>
                  <ReTooltip /><Legend />
                </PieChart>
              </ResponsiveContainer>
            )}
          </CardContent></Card>
        </Grid>
        <Grid item xs={12} md={7}>
          <Card variant="outlined"><CardContent>
            <Typography variant="subtitle2" fontWeight={700} gutterBottom>Operation Hours — Last 7 Days</Typography>
            <ResponsiveContainer width="100%" height={240}>
              <LineChart data={logsTrend}>
                <XAxis dataKey="date" fontSize={12} />
                <YAxis fontSize={12} />
                <ReTooltip />
                <Line type="monotone" dataKey="hours" stroke="#1976d2" strokeWidth={2} name="Hours" dot />
              </LineChart>
            </ResponsiveContainer>
            <Box sx={{ display:"flex", gap:1, mt:1, flexWrap:"wrap" }}>
              <Button size="small" variant="outlined" onClick={()=>navigate("/machine-operation/logs/daily")}>Daily Logs</Button>
              <Button size="small" variant="outlined" onClick={()=>navigate("/machine-operation/logs/fuel")}>Fuel Logs</Button>
              <Button size="small" variant="outlined" onClick={()=>navigate("/machine-operation/reports/utilization")}>Utilization Report</Button>
              <Button size="small" variant="outlined" onClick={()=>navigate("/machine-operation/reports/downtime")}>Downtime Report</Button>
            </Box>
          </CardContent></Card>
        </Grid>
      </Grid>
    </Box>
  );
}
