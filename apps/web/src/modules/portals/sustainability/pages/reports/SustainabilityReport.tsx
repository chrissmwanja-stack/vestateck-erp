import { useEffect, useState, useMemo } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, Typography, Grid } from "@mui/material";
import { FileDownload, Download } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { exportReportToExcel, exportReportToPdf } from "../../../../../lib/reportExport";
import { BarChart, Bar, XAxis, YAxis, Tooltip as ReTooltip, ResponsiveContainer, Legend } from "recharts";

interface MetricAgg {
  type: string;
  count: number;
  total: number;
  avg: number;
  unit: string;
}

export default function SustainabilityReport() {
  const [aggs, setAggs] = useState<MetricAgg[]>([]);
  const [loading, setLoading] = useState(true);

  const fetchReport = async () => {
    setLoading(true);
    const { data } = await supabase.from("sustainability_metrics").select("type, value, unit, sustainability_metric_types(unit)").limit(500);
    const metrics = (data as any[]) || [];

    const map: Record<string, { count: number; total: number; unit: string }> = {};
    metrics.forEach((m: any) => {
      const unit = m.sustainability_metric_types?.unit || m.unit || "";
      if (!map[m.type]) map[m.type] = { count: 0, total: 0, unit };
      map[m.type].count += 1;
      map[m.type].total += Number(m.value);
      if (!map[m.type].unit && unit) map[m.type].unit = unit;
    });

    const result = Object.entries(map).map(([type, v]) => ({
      type,
      count: v.count,
      total: v.total,
      avg: v.count > 0 ? v.total / v.count : 0,
      unit: v.unit,
    }));

    setAggs(result);
    setLoading(false);
  };

  useEffect(() => { fetchReport(); }, []);

  const chartData = useMemo(() => aggs.map(a => ({ type: a.type, Total: a.total, Avg: Number(a.avg.toFixed(2)) })), [aggs]);

  const handleExcel = () => {
    const cols = [
      { header: "Metric Type", accessor: (r: MetricAgg) => r.type },
      { header: "Records", accessor: (r: MetricAgg) => r.count },
      { header: "Total Value", accessor: (r: MetricAgg) => r.total },
      { header: "Average", accessor: (r: MetricAgg) => r.avg.toFixed(2) },
      { header: "Unit", accessor: (r: MetricAgg) => r.unit || "-" },
    ];
    exportReportToExcel(`sustainability-report-${new Date().toISOString().slice(0,10)}`, "Sustainability Report", cols as any, aggs);
  };
  const handlePdf = () => {
    const cols = [
      { header: "Type", accessor: (r: MetricAgg) => r.type },
      { header: "Records", accessor: (r: MetricAgg) => r.count },
      { header: "Total", accessor: (r: MetricAgg) => r.total.toLocaleString() },
      { header: "Avg", accessor: (r: MetricAgg) => r.avg.toFixed(2) },
      { header: "Unit", accessor: (r: MetricAgg) => r.unit || "-" },
    ];
    exportReportToPdf(`sustainability-report-${new Date().toISOString().slice(0,10)}.pdf`, "Sustainability Report", cols as any, aggs);
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", mb: 2, gap: 2, flexWrap: "wrap" }}>
        <Box>
          <Typography variant="h5" fontWeight={700} gutterBottom>Sustainability Report</Typography>
          <Typography variant="body2" color="text.secondary">Aggregates from sustainability_metrics by type — totals, averages, counts.</Typography>
        </Box>
        <Box sx={{ display: "flex", gap: 1 }}>
          <Button size="small" variant="outlined" startIcon={<FileDownload />} onClick={handleExcel} disabled={aggs.length===0}>Excel</Button>
          <Button size="small" variant="outlined" startIcon={<Download />} onClick={handlePdf} disabled={aggs.length===0}>PDF</Button>
        </Box>
      </Box>

      {aggs.length > 0 && (
        <Grid container spacing={2} sx={{ mb: 2 }}>
          <Grid item xs={12} md={6}>
            <Card variant="outlined"><CardContent>
              <Typography variant="subtitle2" fontWeight={700} gutterBottom>Totals by Type</Typography>
              <ResponsiveContainer width="100%" height={240}>
                <BarChart data={chartData}>
                  <XAxis dataKey="type" fontSize={12} />
                  <YAxis fontSize={12} />
                  <ReTooltip /><Legend />
                  <Bar dataKey="Total" fill="#2e7d32" radius={[8,8,0,0]} />
                </BarChart>
              </ResponsiveContainer>
            </CardContent></Card>
          </Grid>
          <Grid item xs={12} md={6}>
            <Card variant="outlined"><CardContent>
              <Typography variant="subtitle2" fontWeight={700} gutterBottom>Averages by Type</Typography>
              <ResponsiveContainer width="100%" height={240}>
                <BarChart data={chartData}>
                  <XAxis dataKey="type" fontSize={12} />
                  <YAxis fontSize={12} />
                  <ReTooltip /><Legend />
                  <Bar dataKey="Avg" fill="#1976d2" radius={[8,8,0,0]} />
                </BarChart>
              </ResponsiveContainer>
            </CardContent></Card>
          </Grid>
        </Grid>
      )}

      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Metric Type</TableCell><TableCell>Records</TableCell><TableCell>Total Value</TableCell><TableCell>Average</TableCell><TableCell>Unit</TableCell></TableRow></TableHead><TableBody>{aggs.length === 0 ? <TableRow><TableCell colSpan={5} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No metrics yet. Add Carbon, Energy, Waste metrics to see report.</Typography></TableCell></TableRow> : aggs.map(a => <TableRow key={a.type} hover><TableCell><Chip label={a.type} size="small" variant="outlined" sx={{ textTransform: "capitalize" }} /></TableCell><TableCell>{a.count}</TableCell><TableCell><Typography fontWeight={700}>{a.total.toLocaleString()}</Typography></TableCell><TableCell>{a.avg.toFixed(2)}</TableCell><TableCell>{a.unit || "-"}</TableCell></TableRow>)}</TableBody></Table></CardContent></Card>
    </Box>
  );
}
