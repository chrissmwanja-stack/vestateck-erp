import { useEffect, useState } from "react";
import { Box, Card, CardContent, Chip, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, Typography } from "@mui/material";
import { supabase } from "../../../../../lib/supabaseClient";

export default function DowntimeReport() {
  const [report, setReport] = useState<any[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const fetch = async () => {
      setLoading(true);
      const { data } = await supabase.from("maintenance_requests").select("machine_id, type, status, created_at, updated_at, machines(name, machine_no)").eq("type", "corrective").order("created_at", { ascending: false }).limit(200);
      const map: Record<string, { name: string; machine_no: string; breakdowns: number; totalDowntimeHours: number }> = {};
      (data as any[] || []).forEach((req: any) => {
        const machine = Array.isArray(req.machines) ? req.machines[0] : req.machines;
        const key = req.machine_id;
        if (!map[key]) map[key] = { name: machine?.name || "Unknown", machine_no: machine?.machine_no || key.slice(0,8), breakdowns: 0, totalDowntimeHours: 0 };
        map[key].breakdowns += 1;
        // Estimate downtime as time between created and updated if completed, else mock 24h
        const created = new Date(req.created_at).getTime();
        const updated = req.updated_at ? new Date(req.updated_at).getTime() : created + 24*60*60*1000;
        const hours = (updated - created) / (1000*60*60);
        map[key].totalDowntimeHours += hours;
      });
      const result = Object.values(map).map((m: any) => ({
        ...m,
        mttr: m.breakdowns > 0 ? m.totalDowntimeHours / m.breakdowns : 0,
        mtbf: m.breakdowns > 0 ? (30*24 - m.totalDowntimeHours) / m.breakdowns : 0, // 30 days assumed
      }));
      setReport(result);
      setLoading(false);
    };
    fetch();
  }, []);

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Downtime Report</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>Downtime reasons from corrective maintenance, MTTR (Mean Time To Repair), MTBF (Mean Time Between Failures).</Typography>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Machine</TableCell><TableCell>Breakdowns</TableCell><TableCell>Total Downtime</TableCell><TableCell>MTTR (hrs)</TableCell><TableCell>MTBF (hrs)</TableCell><TableCell>Status</TableCell></TableRow></TableHead><TableBody>{report.length === 0 ? <TableRow><TableCell colSpan={6} sx={{ textAlign: "center", py: 4 }}><Typography color="text.secondary">No downtime data yet. Create corrective maintenance requests to see downtime report.</Typography></TableCell></TableRow> : report.map((r: any) => <TableRow key={r.machine_no} hover><TableCell><Typography fontWeight={600}>{r.machine_no} - {r.name}</Typography></TableCell><TableCell>{r.breakdowns}</TableCell><TableCell>{r.totalDowntimeHours.toFixed(1)} hrs</TableCell><TableCell>{r.mttr.toFixed(1)} hrs</TableCell><TableCell>{r.mtbf.toFixed(1)} hrs</TableCell><TableCell><Chip label={r.mttr > 48 ? "High downtime" : r.mttr > 24 ? "Medium" : "Low"} size="small" color={r.mttr > 48 ? "error" : r.mttr > 24 ? "warning" : "success"} /></TableCell></TableRow>)}</TableBody></Table></CardContent></Card>
    </Box>
  );
}
