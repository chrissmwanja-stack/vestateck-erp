import { useEffect, useState } from "react";
import { Box, Card, CardContent, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, Typography, LinearProgress } from "@mui/material";
import { supabase } from "../../../../../lib/supabaseClient";

export default function UtilizationReport() {
  const [report, setReport] = useState<any[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const fetch = async () => {
      setLoading(true);
      const { data: logs } = await supabase.from("operation_logs").select("machine_id, hours_used, machines(name, machine_no)").limit(500);
      const map: Record<string, { name: string; machine_no: string; hours: number; count: number }> = {};
      (logs as any[] || []).forEach((log: any) => {
        const machine = Array.isArray(log.machines) ? log.machines[0] : log.machines;
        const key = log.machine_id;
        if (!map[key]) map[key] = { name: machine?.name || "Unknown", machine_no: machine?.machine_no || key.slice(0,8), hours: 0, count: 0 };
        map[key].hours += Number(log.hours_used) || 0;
        map[key].count += 1;
      });
      const result = Object.entries(map).map(([id, v]) => ({
        id,
        ...v,
        utilization: Math.min(100, (v.hours / 160) * 100), // 160h/month assumed available
      }));
      setReport(result.sort((a, b) => b.hours - a.hours));
      setLoading(false);
    };
    fetch();
  }, []);

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Utilization Report</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>Utilization % by machine, based on operation_logs hours_used vs 160h/month assumed available. {report.length} machines with logs.</Typography>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Machine</TableCell><TableCell>Logs Count</TableCell><TableCell>Hours Used</TableCell><TableCell>Available (160h)</TableCell><TableCell>Utilization %</TableCell></TableRow></TableHead><TableBody>{report.length === 0 ? <TableRow><TableCell colSpan={5} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No utilization data yet. Create daily operation logs with hours_used to see report.</Typography></TableCell></TableRow> : report.map(r => <TableRow key={r.id} hover><TableCell><Typography fontWeight={600}>{r.machine_no} - {r.name}</Typography></TableCell><TableCell>{r.count}</TableCell><TableCell>{r.hours.toFixed(1)} hrs</TableCell><TableCell>160 hrs</TableCell><TableCell><Box sx={{ display: "flex", alignItems: "center", gap: 1, minWidth: 120 }}><LinearProgress variant="determinate" value={r.utilization} sx={{ flex: 1, height: 6 }} color={r.utilization > 80 ? "success" : r.utilization > 50 ? "warning" : "error"} /><Typography variant="caption">{r.utilization.toFixed(0)}%</Typography></Box></TableCell></TableRow>)}</TableBody></Table></CardContent></Card>
    </Box>
  );
}
