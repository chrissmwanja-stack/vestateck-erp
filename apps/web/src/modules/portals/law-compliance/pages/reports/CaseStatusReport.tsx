import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, Typography, Tooltip } from "@mui/material";
import { Download } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { exportReportToExcel, exportReportToPdf } from "../../../../../lib/reportExport";
import { PieChart, Pie, Cell, Tooltip as ReTooltip, Legend, ResponsiveContainer, BarChart, Bar, XAxis, YAxis } from "recharts";

interface CaseItem {
  id: string;
  status: string;
  law_case_types?: { name: string } | null;
}

interface Agg {
  type: string;
  open: number;
  inProgress: number;
  closed: number;
  onHold: number;
  total: number;
}

const COLORS = ["#1976d2", "#ed6c02", "#2e7d32", "#9c27b0", "#d32f2f", "#0288d1", "#ef6c00", "#6a1b9a"];

export default function CaseStatusReport() {
  const [byType, setByType] = useState<Agg[]>([]);
  const [totals, setTotals] = useState({ open: 0, inProgress: 0, closed: 0, onHold: 0, total: 0 });
  const [loading, setLoading] = useState(true);

  const fetchReport = async () => {
    setLoading(true);
    const { data } = await supabase.from("law_cases").select("id, status, law_case_types(name)");
    const cases: CaseItem[] = (data || []).map((row: any) => ({
     id: row.id,
     status: row.status,
    law_case_types: Array.isArray(row.law_case_types) ? row.law_case_types[0] ?? null : row.law_case_types,
   }));

    const map: Record<string, Agg> = {};
    let open = 0, inProgress = 0, closed = 0, onHold = 0;

    cases.forEach(c => {
      const typeName = c.law_case_types?.name || "Uncategorized";
      if (!map[typeName]) map[typeName] = { type: typeName, open: 0, inProgress: 0, closed: 0, onHold: 0, total: 0 };
      map[typeName].total++;
      if (c.status === 'open') { map[typeName].open++; open++; }
      else if (c.status === 'in_progress') { map[typeName].inProgress++; inProgress++; }
      else if (c.status === 'closed') { map[typeName].closed++; closed++; }
      else if (c.status === 'on_hold') { map[typeName].onHold++; onHold++; }
    });

    setByType(Object.values(map).sort((a, b) => b.total - a.total));
    setTotals({ open, inProgress, closed, onHold, total: cases.length });
    setLoading(false);
  };

  useEffect(() => { fetchReport(); }, []);

  const handleExportExcel = () => {
    const rows = byType.map(b => ({ type: b.type, open: b.open, inProgress: b.inProgress, closed: b.closed, onHold: b.onHold, total: b.total }));
    const cols = [
      { header: "Type", accessor: (r: any) => r.type },
      { header: "Open", accessor: (r: any) => r.open },
      { header: "In Progress", accessor: (r: any) => r.inProgress },
      { header: "Closed", accessor: (r: any) => r.closed },
      { header: "On Hold", accessor: (r: any) => r.onHold },
      { header: "Total", accessor: (r: any) => r.total },
    ];
    exportReportToExcel("case_status_report", "Case Status Report", cols, rows);
  };
  const handleExportPDF = () => {
    const rows = byType.map(b => ({ type: b.type, total: String(b.total), open: String(b.open), closed: String(b.closed) }));
    const cols = [
      { header: "Type", accessor: (r: any) => r.type },
      { header: "Total", accessor: (r: any) => r.total },
      { header: "Open", accessor: (r: any) => r.open },
      { header: "Closed", accessor: (r: any) => r.closed },
    ];
    exportReportToPdf("case_status_report.pdf", "Case Status Report", cols, rows);
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  const statusPie = [
    { name: "Open", value: totals.open },
    { name: "In Progress", value: totals.inProgress },
    { name: "Closed", value: totals.closed },
    { name: "On Hold", value: totals.onHold },
  ].filter(s => s.value > 0);

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3 }}>
        <Box><Typography variant="h5" fontWeight={700}>Case Status Report</Typography><Typography variant="body2" color="text.secondary">{totals.total} cases • Breakdown by type and status.</Typography></Box>
        <Box sx={{ display: "flex", gap: 1 }}><Tooltip title="Export Excel"><Button size="small" variant="outlined" onClick={handleExportExcel}>Excel</Button></Tooltip><Button size="small" variant="outlined" startIcon={<Download />} onClick={handleExportPDF}>PDF</Button></Box>
      </Box>

      <Box sx={{ display: "flex", gap: 2, mb: 3, flexWrap: "wrap" }}>
        <Chip label={`Total: ${totals.total}`} color="primary" />
        <Chip label={`Open: ${totals.open}`} variant="outlined" />
        <Chip label={`In Progress: ${totals.inProgress}`} color="warning" />
        <Chip label={`Closed: ${totals.closed}`} color="success" />
        <Chip label={`On Hold: ${totals.onHold}`} color="secondary" />
      </Box>

      {statusPie.length > 0 && <Box sx={{ display: "flex", gap: 2, mb: 3, flexWrap: "wrap" }}>
        <Card sx={{ flex: 1, minWidth: 300 }}><CardContent><Typography variant="subtitle2" fontWeight={700} gutterBottom>Status Distribution</Typography><Box sx={{ height: 260 }}><ResponsiveContainer width="100%" height="100%"><PieChart><Pie data={statusPie} dataKey="value" nameKey="name" cx="50%" cy="50%" outerRadius={90} label={({ name, percent }) => `${name} ${((percent ?? 0)*100).toFixed(0)}%`}>{statusPie.map((_, i) => <Cell key={i} fill={COLORS[i % COLORS.length]} />)}</Pie><ReTooltip /><Legend /></PieChart></ResponsiveContainer></Box></CardContent></Card>
        {byType.length > 0 && <Card sx={{ flex: 1, minWidth: 340 }}><CardContent><Typography variant="subtitle2" fontWeight={700} gutterBottom>Cases by Type</Typography><Box sx={{ height: 260 }}><ResponsiveContainer width="100%" height="100%"><BarChart data={byType.slice(0, 8)}><XAxis dataKey="type" tick={{ fontSize: 10 }} interval={0} angle={-12} textAnchor="end" height={60} /><YAxis /><ReTooltip /><Bar dataKey="total" fill="#1976d2" name="Total" /></BarChart></ResponsiveContainer></Box></CardContent></Card>}
      </Box>}

      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Type</TableCell><TableCell>Open</TableCell><TableCell>In Progress</TableCell><TableCell>Closed</TableCell><TableCell>On Hold</TableCell><TableCell>Total</TableCell></TableRow></TableHead><TableBody>{byType.length === 0 ? <TableRow><TableCell colSpan={6} sx={{ textAlign: "center", py: 4 }}><Typography color="text.secondary">No cases yet. Create cases to see breakdown.</Typography></TableCell></TableRow> : byType.map(r => <TableRow key={r.type} hover><TableCell>{r.type}</TableCell><TableCell>{r.open}</TableCell><TableCell>{r.inProgress}</TableCell><TableCell>{r.closed}</TableCell><TableCell>{r.onHold}</TableCell><TableCell><Chip label={r.total} size="small" /></TableCell></TableRow>)}</TableBody></Table></CardContent></Card>
    </Box>
  );
}
