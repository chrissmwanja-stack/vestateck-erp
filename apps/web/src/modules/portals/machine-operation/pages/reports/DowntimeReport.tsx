import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, Typography, Tooltip } from "@mui/material";
import { Download } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { exportReportToExcel, exportReportToPdf } from "../../../../../lib/reportExport";
import { BarChart, Bar, XAxis, YAxis, Tooltip as ReTooltip, ResponsiveContainer, Legend } from "recharts";

export default function DowntimeReport() {
  const [report, setReport] = useState<any[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const fetch = async () => {
      setLoading(true);
      const { data } = await supabase.from("maintenance_requests").select("machine_id, type, status, created_at, updated_at, machines(name, machine_no)").eq("type", "corrective").order("created_at", { ascending: false }).limit(500);
      const map: Record<string, { name: string; machine_no: string; breakdowns: number; totalDowntimeHours: number }> = {};
      (data as any[] || []).forEach((req: any) => {
        const machine = Array.isArray(req.machines) ? req.machines[0] : req.machines;
        const key = req.machine_id;
        if (!map[key]) map[key] = { name: machine?.name || "Unknown", machine_no: machine?.machine_no || key.slice(0,8), breakdowns: 0, totalDowntimeHours: 0 };
        map[key].breakdowns += 1;
        const created = new Date(req.created_at).getTime();
        const updated = req.updated_at ? new Date(req.updated_at).getTime() : created + 24*60*60*1000;
        const hours = (updated - created) / (1000*60*60);
        map[key].totalDowntimeHours += hours;
      });
      const result = Object.values(map).map((m: any) => ({
        ...m,
        mttr: m.breakdowns > 0 ? m.totalDowntimeHours / m.breakdowns : 0,
        mtbf: m.breakdowns > 0 ? (30*24 - m.totalDowntimeHours) / m.breakdowns : 0,
      }));
      setReport(result as any);
      setLoading(false);
    };
    fetch();
  }, []);

  const handleExportExcel = () => {
    const rows = report.map(r => ({ machine: `${r.machine_no} - ${r.name}`, breakdowns: r.breakdowns, downtime: Number(r.totalDowntimeHours.toFixed(1)), mttr: Number(r.mttr.toFixed(1)), mtbf: Number(r.mtbf.toFixed(1)) }));
    const cols = [
      { header: "Machine", accessor: (r: any) => r.machine },
      { header: "Breakdowns", accessor: (r: any) => r.breakdowns },
      { header: "Downtime hrs", accessor: (r: any) => r.downtime },
      { header: "MTTR", accessor: (r: any) => r.mttr },
      { header: "MTBF", accessor: (r: any) => r.mtbf },
    ];
    exportReportToExcel("downtime_report", "Downtime Report", cols, rows);
  };
  const handleExportPDF = () => {
    const rows = report.map(r => ({ machine: `${r.machine_no} - ${r.name}`, breakdowns: String(r.breakdowns), mttr: `${r.mttr.toFixed(1)} hrs` }));
    const cols = [
      { header: "Machine", accessor: (r: any) => r.machine },
      { header: "Breakdowns", accessor: (r: any) => r.breakdowns },
      { header: "MTTR", accessor: (r: any) => r.mttr },
    ];
    exportReportToPdf("downtime_report.pdf", "Downtime Report", cols, rows);
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  const chartData = report.slice(0, 10).map(r => ({ name: r.machine_no, mttr: Number(r.mttr.toFixed(1)), mtbf: Number(r.mtbf.toFixed(1)) }));

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3 }}>
        <Box><Typography variant="h5" fontWeight={700}>Downtime Report</Typography><Typography variant="body2" color="text.secondary">Corrective maintenance only — MTTR (Mean Time To Repair), MTBF (Mean Time Between Failures).</Typography></Box>
        <Box sx={{ display: "flex", gap: 1 }}><Tooltip title="Export Excel"><Button size="small" variant="outlined" onClick={handleExportExcel}>Excel</Button></Tooltip><Button size="small" variant="outlined" startIcon={<Download />} onClick={handleExportPDF}>PDF</Button></Box>
      </Box>

      {chartData.length > 0 && <Card sx={{ mb: 3 }}><CardContent><Typography variant="subtitle2" fontWeight={700} gutterBottom>MTTR vs MTBF (top 10 breakdown machines)</Typography><Box sx={{ height: 280 }}><ResponsiveContainer width="100%" height="100%"><BarChart data={chartData}><XAxis dataKey="name" tick={{ fontSize: 10 }} /><YAxis /><ReTooltip /><Legend /><Bar dataKey="mttr" fill="#d32f2f" name="MTTR hrs" /><Bar dataKey="mtbf" fill="#388e3c" name="MTBF hrs" /></BarChart></ResponsiveContainer></Box></CardContent></Card>}

      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Machine</TableCell><TableCell>Breakdowns</TableCell><TableCell>Total Downtime</TableCell><TableCell>MTTR</TableCell><TableCell>MTBF</TableCell><TableCell>Status</TableCell></TableRow></TableHead><TableBody>{report.length === 0 ? <TableRow><TableCell colSpan={6} sx={{ textAlign: "center", py: 4 }}><Typography color="text.secondary">No downtime data yet. Create corrective maintenance requests to see downtime report.</Typography></TableCell></TableRow> : report.map((r: any) => <TableRow key={r.machine_no} hover><TableCell><Typography fontWeight={600}>{r.machine_no} - {r.name}</Typography></TableCell><TableCell>{r.breakdowns}</TableCell><TableCell>{r.totalDowntimeHours.toFixed(1)} hrs</TableCell><TableCell>{r.mttr.toFixed(1)} hrs</TableCell><TableCell>{r.mtbf.toFixed(1)} hrs</TableCell><TableCell><Chip label={r.mttr > 48 ? "High downtime" : r.mttr > 24 ? "Medium" : "Low"} size="small" color={r.mttr > 48 ? "error" : r.mttr > 24 ? "warning" : "success"} /></TableCell></TableRow>)}</TableBody></Table></CardContent></Card>
    </Box>
  );
}
