import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, Typography, Tooltip } from "@mui/material";
import { Download } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { exportReportToExcel, exportReportToPdf } from "../../../../../lib/reportExport";
import { PieChart, Pie, Cell, Tooltip as ReTooltip, Legend, ResponsiveContainer, BarChart, Bar, XAxis, YAxis } from "recharts";

interface Lead {
  id: string;
  source_id: string;
  estimated_value: number | null;
  converted_opportunity_id: string | null;
  status: string;
  bd_lead_sources?: { name: string } | null;
}

interface SourceAgg {
  source_id: string;
  source_name: string;
  count: number;
  totalValue: number;
  qualified: number;
  converted: number;
  conversionRate: number;
}

const COLORS = ["#1976d2", "#2e7d32", "#ed6c02", "#9c27b0", "#00838f", "#6d4c41", "#455a64", "#c2185b"];

export default function LeadSourceReport() {
  const [aggs, setAggs] = useState<SourceAgg[]>([]);
  const [loading, setLoading] = useState(true);

  const fetchReport = async () => {
    setLoading(true);
    const { data } = await supabase.from("bd_leads").select("*, bd_lead_sources(name)");
    const leads = ((data as any[]) || []).map((l: any) => ({
      ...l,
      bd_lead_sources: Array.isArray(l.bd_lead_sources) ? l.bd_lead_sources[0] ?? null : l.bd_lead_sources ?? null,
    })) as Lead[];

    const map: Record<string, { name: string; count: number; totalValue: number; qualified: number; converted: number }> = {};

    leads.forEach(l => {
      const name = l.bd_lead_sources?.name || "Unknown";
      const key = l.source_id || "unknown";
      if (!map[key]) map[key] = { name, count: 0, totalValue: 0, qualified: 0, converted: 0 };
      map[key].count += 1;
      map[key].totalValue += Number(l.estimated_value || 0);
      if (l.status === "qualified") map[key].qualified += 1;
      if (l.converted_opportunity_id || l.status === "converted") map[key].converted += 1;
    });

    const result = Object.entries(map).map(([source_id, v]) => ({
      source_id,
      source_name: v.name,
      count: v.count,
      totalValue: v.totalValue,
      qualified: v.qualified,
      converted: v.converted,
      conversionRate: v.count > 0 ? (v.converted / v.count) * 100 : 0,
    }));

    result.sort((a, b) => b.count - a.count);
    setAggs(result);
    setLoading(false);
  };

  useEffect(() => { fetchReport(); }, []);

  const handleExportExcel = () => {
    const rows = aggs.map(a => ({ source: a.source_name, count: a.count, totalValue: a.totalValue, qualified: a.qualified, converted: a.converted, conversionRate: Number(a.conversionRate.toFixed(1)) }));
    const cols = [
      { header: "Source", accessor: (r: any) => r.source },
      { header: "Leads", accessor: (r: any) => r.count },
      { header: "Total Value", accessor: (r: any) => r.totalValue },
      { header: "Qualified", accessor: (r: any) => r.qualified },
      { header: "Converted", accessor: (r: any) => r.converted },
      { header: "Conv Rate %", accessor: (r: any) => r.conversionRate },
    ];
    exportReportToExcel("lead_source_report", "Lead Source Report", cols, rows);
  };
  const handleExportPDF = () => {
    const rows = aggs.map(a => ({ source: a.source_name, count: String(a.count), converted: String(a.converted), rate: `${a.conversionRate.toFixed(0)}%` }));
    const cols = [
      { header: "Source", accessor: (r: any) => r.source },
      { header: "Leads", accessor: (r: any) => r.count },
      { header: "Converted", accessor: (r: any) => r.converted },
      { header: "Rate", accessor: (r: any) => r.rate },
    ];
    exportReportToPdf("lead_source_report.pdf", "Lead Source Report", cols, rows);
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  const pieData = aggs.slice(0, 6).map(a => ({ name: a.source_name, value: a.count }));

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3, flexWrap: "wrap", gap: 2 }}>
        <Box><Typography variant="h5" fontWeight={700}>Lead Source Report</Typography><Typography variant="body2" color="text.secondary">Leads count and value by source, with conversion rate to opportunity.</Typography></Box>
        <Box sx={{ display: "flex", gap: 1 }}><Tooltip title="Export Excel"><Button size="small" variant="outlined" onClick={handleExportExcel}>Excel</Button></Tooltip><Button size="small" variant="outlined" startIcon={<Download />} onClick={handleExportPDF}>PDF</Button></Box>
      </Box>

      {aggs.length > 0 && <Box sx={{ display: "flex", gap: 2, mb: 3, flexWrap: "wrap" }}>
        <Card sx={{ flex: "1 1 340px" }}><CardContent><Typography variant="subtitle2" fontWeight={700} gutterBottom>Leads by Source</Typography><Box sx={{ height: 260 }}><ResponsiveContainer width="100%" height="100%"><PieChart><Pie data={pieData} dataKey="value" nameKey="name" cx="50%" cy="50%" outerRadius={85} label={({ name, percent }) => `${name} ${((percent ?? 0)*100).toFixed(0)}%`}>{pieData.map((_, i) => <Cell key={i} fill={COLORS[i % COLORS.length]} />)}</Pie><ReTooltip /><Legend /></PieChart></ResponsiveContainer></Box></CardContent></Card>
        <Card sx={{ flex: "1 1 380px" }}><CardContent><Typography variant="subtitle2" fontWeight={700} gutterBottom>Conversion Rate by Source</Typography><Box sx={{ height: 260 }}><ResponsiveContainer width="100%" height="100%"><BarChart data={aggs.slice(0, 8)}><XAxis dataKey="source_name" tick={{ fontSize: 10 }} interval={0} angle={-14} textAnchor="end" height={60} /><YAxis tick={{ fontSize: 11 }} /><ReTooltip /><Bar dataKey="conversionRate" fill="#2e7d32" name="Conv %" /></BarChart></ResponsiveContainer></Box></CardContent></Card>
      </Box>}

      <Card>
        <CardContent sx={{ p: 0 }}>
          <Table>
            <TableHead><TableRow><TableCell>Source</TableCell><TableCell>Leads Count</TableCell><TableCell>Total Estimated Value</TableCell><TableCell>Qualified</TableCell><TableCell>Converted to Opp</TableCell><TableCell>Conversion Rate</TableCell></TableRow></TableHead>
            <TableBody>
              {aggs.length === 0 ? (
                <TableRow><TableCell colSpan={6} sx={{ textAlign: "center", py: 4 }}><Typography color="text.secondary">No leads yet. Create leads via New Lead and set source from Lead Sources admin.</Typography></TableCell></TableRow>
              ) : (
                aggs.map(a => (
                  <TableRow key={a.source_id} hover>
                    <TableCell><Chip label={a.source_name} size="small" variant="outlined" /></TableCell>
                    <TableCell>{a.count}</TableCell>
                    <TableCell>UGX {a.totalValue.toLocaleString()}</TableCell>
                    <TableCell>{a.qualified}</TableCell>
                    <TableCell>{a.converted}</TableCell>
                    <TableCell><Chip label={`${a.conversionRate.toFixed(0)}%`} size="small" color={a.conversionRate > 50 ? "success" : a.conversionRate > 20 ? "warning" : "default"} /></TableCell>
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
