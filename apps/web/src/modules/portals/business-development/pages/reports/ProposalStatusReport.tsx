import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, Typography, Tooltip } from "@mui/material";
import { Download } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { exportReportToExcel, exportReportToPdf } from "../../../../../lib/reportExport";
import { PieChart, Pie, Cell, Tooltip as ReTooltip, Legend, ResponsiveContainer, BarChart, Bar, XAxis, YAxis } from "recharts";

const COLORS = ["#1976d2", "#ed6c02", "#2e7d32", "#9c27b0", "#d32f2f", "#00838f", "#5d4037", "#455a64"];

export default function ProposalStatusReport() {
  const [rows, setRows] = useState<any[]>([]);
  const [loading, setLoading] = useState(true);

  const fetchReport = async () => {
    setLoading(true);
    const { data } = await supabase.from("bd_proposals").select("status, total_value, created_at, updated_at");
    const proposals = (data as any[]) || [];
    const map: Record<string, { count: number; totalValue: number; totalDays: number }> = {};
    proposals.forEach(p => {
      if (!map[p.status]) map[p.status] = { count: 0, totalValue: 0, totalDays: 0 };
      map[p.status].count += 1;
      map[p.status].totalValue += Number(p.total_value) || 0;
      const created = new Date(p.created_at).getTime();
      const updated = p.updated_at ? new Date(p.updated_at).getTime() : Date.now();
      map[p.status].totalDays += (updated - created) / (1000*60*60*24);
    });
    const result = Object.entries(map).map(([status, v]) => ({
      status,
      label: status.replace(/_/g, " "),
      count: v.count,
      totalValue: v.totalValue,
      avgValue: v.count ? v.totalValue / v.count : 0,
      avgDays: v.count ? v.totalDays / v.count : 0,
    }));
    result.sort((a,b) => b.count - a.count);
    setRows(result);
    setLoading(false);
  };

  useEffect(() => { fetchReport(); }, []);

  const handleExportExcel = () => {
    const r = rows.map(a => ({ status: a.label, count: a.count, totalValue: a.totalValue, avgValue: Number(a.avgValue.toFixed(0)), avgDays: Number(a.avgDays.toFixed(1)) }));
    const cols = [
      { header: "Status", accessor: (x:any) => x.status },
      { header: "Count", accessor: (x:any) => x.count },
      { header: "Total Value", accessor: (x:any) => x.totalValue },
      { header: "Avg Value", accessor: (x:any) => x.avgValue },
      { header: "Avg Days", accessor: (x:any) => x.avgDays },
    ];
    exportReportToExcel("proposal_status_report", "Proposal Status Report", cols, r);
  };
  const handleExportPDF = () => {
    const r = rows.map(a => ({ status: a.label, count: String(a.count), total: a.totalValue.toLocaleString(), avgDays: a.avgDays.toFixed(1) }));
    const cols = [
      { header: "Status", accessor: (x:any) => x.status },
      { header: "Count", accessor: (x:any) => x.count },
      { header: "Total", accessor: (x:any) => x.total },
      { header: "Avg Days", accessor: (x:any) => x.avgDays },
    ];
    exportReportToPdf("proposal_status_report.pdf", "Proposal Status Report", cols, r);
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  const pieData = rows.map(r => ({ name: r.label, value: r.count }));

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3, flexWrap: "wrap", gap: 2 }}>
        <Box><Typography variant="h5" fontWeight={700}>Proposal Status Report</Typography><Typography variant="body2" color="text.secondary">{rows.reduce((s,r)=>s+r.count,0)} proposals • breakdown by status, value and time in status.</Typography></Box>
        <Box sx={{ display: "flex", gap: 1 }}><Tooltip title="Export Excel"><Button size="small" variant="outlined" onClick={handleExportExcel}>Excel</Button></Tooltip><Button size="small" variant="outlined" startIcon={<Download />} onClick={handleExportPDF}>PDF</Button></Box>
      </Box>

      {rows.length > 0 && <Box sx={{ display: "flex", gap: 2, mb: 3, flexWrap: "wrap" }}>
        <Card sx={{ flex: "1 1 320px" }}><CardContent><Typography variant="subtitle2" fontWeight={700} gutterBottom>Proposals by Status</Typography><Box sx={{ height: 260 }}><ResponsiveContainer width="100%" height="100%"><PieChart><Pie data={pieData} dataKey="value" nameKey="name" cx="50%" cy="50%" outerRadius={85} label={({ name, percent }) => `${name} ${((percent ?? 0)*100).toFixed(0)}%`}>{pieData.map((_, i) => <Cell key={i} fill={COLORS[i % COLORS.length]} />)}</Pie><ReTooltip /><Legend /></PieChart></ResponsiveContainer></Box></CardContent></Card>
        <Card sx={{ flex: "1 1 380px" }}><CardContent><Typography variant="subtitle2" fontWeight={700} gutterBottom>Value by Status</Typography><Box sx={{ height: 260 }}><ResponsiveContainer width="100%" height="100%"><BarChart data={rows.slice(0,8)}><XAxis dataKey="label" tick={{ fontSize: 10 }} interval={0} angle={-14} textAnchor="end" height={60} /><YAxis tick={{ fontSize: 11 }} /><ReTooltip /><Bar dataKey="totalValue" fill="#1976d2" name="Total Value" /></BarChart></ResponsiveContainer></Box></CardContent></Card>
      </Box>}

      <Card>
        <CardContent sx={{ p: 0 }}>
          <Table>
            <TableHead><TableRow><TableCell>Status</TableCell><TableCell>Count</TableCell><TableCell>Total Value</TableCell><TableCell>Avg Value</TableCell><TableCell>Avg Days in Status</TableCell></TableRow></TableHead>
            <TableBody>
              {rows.length === 0 ? (
                <TableRow><TableCell colSpan={5} sx={{ textAlign: "center", py: 4 }}><Typography color="text.secondary">No proposals yet. Create proposals via New Proposal.</Typography></TableCell></TableRow>
              ) : (
                rows.map(a => (
                  <TableRow key={a.status} hover>
                    <TableCell><Chip label={a.label} size="small" variant="outlined" sx={{ textTransform: "capitalize" }} /></TableCell>
                    <TableCell>{a.count}</TableCell>
                    <TableCell>UGX {a.totalValue.toLocaleString()}</TableCell>
                    <TableCell>UGX {a.avgValue.toLocaleString(undefined, { maximumFractionDigits: 0 })}</TableCell>
                    <TableCell>{a.avgDays.toFixed(1)} days</TableCell>
                  </TableRow>
                ))
              )}
            </TableBody>
          </Table>
        </CardContent>
      </Card>
    </Box>
  );
}
