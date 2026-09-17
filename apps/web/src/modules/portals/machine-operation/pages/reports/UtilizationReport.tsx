import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, Typography, LinearProgress, Tooltip } from "@mui/material";
import { Download } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { exportReportToExcel, exportReportToPdf } from "../../../../../lib/reportExport";
import { BarChart, Bar, XAxis, YAxis, Tooltip as ReTooltip, ResponsiveContainer, Legend } from "recharts";

export default function UtilizationReport() {
  const [report, setReport] = useState<any[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const fetch = async () => {
      setLoading(true);
      const { data: logs } = await supabase.from("operation_logs").select("machine_id, hours_used, machines(name, machine_no)").limit(1000);
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
        utilization: Math.min(100, (v.hours / 160) * 100),
      }));
      setReport(result.sort((a, b) => b.hours - a.hours));
      setLoading(false);
    };
    fetch();
  }, []);

  const handleExportExcel = () => {
    const rows = report.map(r => ({ machine: `${r.machine_no} - ${r.name}`, logs: r.count, hours: Number(r.hours.toFixed(1)), utilization: Number(r.utilization.toFixed(1)) }));
    const cols = [
      { header: "Machine", accessor: (r: any) => r.machine },
      { header: "Logs", accessor: (r: any) => r.logs },
      { header: "Hours", accessor: (r: any) => r.hours },
      { header: "Util %", accessor: (r: any) => r.utilization },
    ];
    exportReportToExcel("utilization_report", "Utilization Report", cols, rows);
  };
  const handleExportPDF = () => {
    const rows = report.map(r => ({ machine: `${r.machine_no} - ${r.name}`, hours: `${r.hours.toFixed(1)} hrs`, utilization: `${r.utilization.toFixed(0)}%` }));
    const cols = [
      { header: "Machine", accessor: (r: any) => r.machine },
      { header: "Hours", accessor: (r: any) => r.hours },
      { header: "Util %", accessor: (r: any) => r.utilization },
    ];
    exportReportToPdf("utilization_report.pdf", "Utilization Report", cols, rows);
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  const chartData = report.slice(0, 12).map(r => ({ name: r.machine_no, hours: Number(r.hours.toFixed(1)), utilization: Number(r.utilization.toFixed(0)) }));

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3 }}>
        <Box><Typography variant="h5" fontWeight={700}>Utilization Report</Typography><Typography variant="body2" color="text.secondary">Utilization % = hours_used vs 160h/month assumed available. {report.length} machines with logs.</Typography></Box>
        <Box sx={{ display: "flex", gap: 1 }}><Tooltip title="Export Excel"><Button size="small" variant="outlined" onClick={handleExportExcel}>Excel</Button></Tooltip><Button size="small" variant="outlined" startIcon={<Download />} onClick={handleExportPDF}>PDF</Button></Box>
      </Box>

      {chartData.length > 0 && <Card sx={{ mb: 3 }}><CardContent><Typography variant="subtitle2" fontWeight={700} gutterBottom>Hours by Machine (top 12)</Typography><Box sx={{ height: 280 }}><ResponsiveContainer width="100%" height="100%"><BarChart data={chartData}><XAxis dataKey="name" tick={{ fontSize: 10 }} interval={0} angle={-15} textAnchor="end" height={50} /><YAxis /><ReTooltip /><Legend /><Bar dataKey="hours" fill="#1976d2" name="Hours" /><Bar dataKey="utilization" fill="#2e7d32" name="Util %" /></BarChart></ResponsiveContainer></Box></CardContent></Card>}

      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Machine</TableCell><TableCell>Logs</TableCell><TableCell>Hours</TableCell><TableCell>Available</TableCell><TableCell>Utilization</TableCell></TableRow></TableHead><TableBody>{report.length === 0 ? <TableRow><TableCell colSpan={5} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No utilization data yet. Create daily operation logs with hours_used to see report.</Typography></TableCell></TableRow> : report.map(r => <TableRow key={r.id} hover><TableCell><Typography fontWeight={600}>{r.machine_no} - {r.name}</Typography></TableCell><TableCell>{r.count}</TableCell><TableCell>{r.hours.toFixed(1)} hrs</TableCell><TableCell>160 hrs</TableCell><TableCell><Box sx={{ display: "flex", alignItems: "center", gap: 1, minWidth: 140 }}><LinearProgress variant="determinate" value={r.utilization} sx={{ flex: 1, height: 6, borderRadius: 1 }} color={r.utilization > 80 ? "success" : r.utilization > 50 ? "warning" : "error"} /><Typography variant="caption">{r.utilization.toFixed(0)}%</Typography></Box></TableCell></TableRow>)}</TableBody></Table></CardContent></Card>
    </Box>
  );
}
