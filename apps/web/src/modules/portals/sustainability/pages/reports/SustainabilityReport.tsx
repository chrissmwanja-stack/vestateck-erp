import { useEffect, useState, useMemo } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, TextField, Typography, Grid } from "@mui/material";
import { FileDownload, Download } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { exportReportToExcel, exportReportToPdf } from "../../../../../lib/reportExport";
import { BarChart, Bar, XAxis, YAxis, Tooltip as ReTooltip, ResponsiveContainer, Legend } from "recharts";

interface MetricAgg {
  metric: string;      // metric type name (falls back to the raw category)
  category: string;    // sustainability_metrics.type: carbon / energy / waste / ...
  count: number;
  total: number;
  avg: number;
  unit: string;
}

export default function SustainabilityReport() {
  const [aggs, setAggs] = useState<MetricAgg[]>([]);
  const [loading, setLoading] = useState(true);
  const [fromDate, setFromDate] = useState("");
  const [toDate, setToDate] = useState("");

  const fetchReport = async () => {
    setLoading(true);
    // Group by metric TYPE (Scope 1, Grid electricity, ...) inside its
    // category -- one bucket per category mixed different metrics and,
    // worse, different units, into a meaningless total.
    let query = supabase
      .from("sustainability_metrics")
      .select("type, value, recorded_date, sustainability_metric_types(name, unit)")
      .order("recorded_date", { ascending: false })
      .limit(2000);
    if (fromDate) query = query.gte("recorded_date", fromDate);
    if (toDate) query = query.lte("recorded_date", toDate);
    const { data } = await query;
    const metrics = (data as any[]) || [];

    const map: Record<string, { category: string; count: number; total: number; unit: string }> = {};
    metrics.forEach((m: any) => {
      const t = Array.isArray(m.sustainability_metric_types) ? m.sustainability_metric_types[0] ?? null : m.sustainability_metric_types ?? null;
      const metricName = t?.name || m.type || "Other";
      const unit = t?.unit || "";
      if (!map[metricName]) map[metricName] = { category: m.type, count: 0, total: 0, unit };
      map[metricName].count += 1;
      map[metricName].total += Number(m.value);
      if (!map[metricName].unit && unit) map[metricName].unit = unit;
    });

    const result = Object.entries(map)
      .map(([metric, v]) => ({ metric, category: v.category, count: v.count, total: v.total, avg: v.count > 0 ? v.total / v.count : 0, unit: v.unit }))
      .sort((a, b) => a.category.localeCompare(b.category) || a.metric.localeCompare(b.metric));

    setAggs(result);
    setLoading(false);
  };

  useEffect(() => { fetchReport(); }, [fromDate, toDate]);

  const chartData = useMemo(() => aggs.map(a => ({ metric: a.metric, Total: a.total, Avg: Number(a.avg.toFixed(2)) })), [aggs]);
  const rangeLabel = fromDate || toDate ? `${fromDate || "…"} to ${toDate || "…"}` : "all time";
  const fileTag = `${fromDate || "all"}_${toDate || "now"}`;

  const handleExcel = () => {
    const cols = [
      { header: "Metric", accessor: (r: MetricAgg) => r.metric },
      { header: "Category", accessor: (r: MetricAgg) => r.category },
      { header: "Records", accessor: (r: MetricAgg) => r.count },
      { header: "Total", accessor: (r: MetricAgg) => r.total },
      { header: "Average", accessor: (r: MetricAgg) => Number(r.avg.toFixed(2)) },
      { header: "Unit", accessor: (r: MetricAgg) => r.unit || "-" },
      { header: "Period", accessor: (_: MetricAgg) => rangeLabel },
    ];
    exportReportToExcel(`sustainability-report-${fileTag}-${new Date().toISOString().slice(0,10)}`, "Sustainability Report", cols as any, aggs);
  };
  const handlePdf = () => {
    const cols = [
      { header: "Metric", accessor: (r: MetricAgg) => r.metric },
      { header: "Category", accessor: (r: MetricAgg) => r.category },
      { header: "Records", accessor: (r: MetricAgg) => r.count },
      { header: "Total", accessor: (r: MetricAgg) => r.total.toLocaleString() },
      { header: "Avg", accessor: (r: MetricAgg) => r.avg.toFixed(2) },
      { header: "Unit", accessor: (r: MetricAgg) => r.unit || "-" },
    ];
    exportReportToPdf(`sustainability-report-${fileTag}-${new Date().toISOString().slice(0,10)}.pdf`, `Sustainability Report — ${rangeLabel}`, cols as any, aggs);
  };

  if (loading && aggs.length === 0) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", mb: 2, gap: 2, flexWrap: "wrap" }}>
        <Box>
          <Typography variant="h5" fontWeight={700} gutterBottom>Sustainability Report</Typography>
          <Typography variant="body2" color="text.secondary">
            Per-metric totals and averages from sustainability_metrics — {rangeLabel}.
          </Typography>
        </Box>
        <Box sx={{ display: "flex", gap: 1, alignItems: "center", flexWrap: "wrap" }}>
          <TextField label="From" type="date" size="small" value={fromDate} onChange={e => setFromDate(e.target.value)} InputLabelProps={{ shrink: true }} sx={{ width: 150 }} />
          <TextField label="To" type="date" size="small" value={toDate} onChange={e => setToDate(e.target.value)} InputLabelProps={{ shrink: true }} sx={{ width: 150 }} />
          {(fromDate || toDate) && <Button size="small" onClick={() => { setFromDate(""); setToDate(""); }}>Clear</Button>}
          <Button size="small" variant="outlined" startIcon={<FileDownload />} onClick={handleExcel} disabled={aggs.length===0}>Excel</Button>
          <Button size="small" variant="outlined" startIcon={<Download />} onClick={handlePdf} disabled={aggs.length===0}>PDF</Button>
        </Box>
      </Box>

      {aggs.length > 0 && (
        <Grid container spacing={2} sx={{ mb: 2 }}>
          <Grid item xs={12} md={6}>
            <Card variant="outlined"><CardContent>
              <Typography variant="subtitle2" fontWeight={700} gutterBottom>Totals by Metric</Typography>
              <ResponsiveContainer width="100%" height={240}>
                <BarChart data={chartData}>
                  <XAxis dataKey="metric" fontSize={11} interval={0} angle={-20} textAnchor="end" height={60} />
                  <YAxis fontSize={12} />
                  <ReTooltip /><Legend />
                  <Bar dataKey="Total" fill="#2e7d32" radius={[8,8,0,0]} />
                </BarChart>
              </ResponsiveContainer>
            </CardContent></Card>
          </Grid>
          <Grid item xs={12} md={6}>
            <Card variant="outlined"><CardContent>
              <Typography variant="subtitle2" fontWeight={700} gutterBottom>Averages by Metric</Typography>
              <ResponsiveContainer width="100%" height={240}>
                <BarChart data={chartData}>
                  <XAxis dataKey="metric" fontSize={11} interval={0} angle={-20} textAnchor="end" height={60} />
                  <YAxis fontSize={12} />
                  <ReTooltip /><Legend />
                  <Bar dataKey="Avg" fill="#1976d2" radius={[8,8,0,0]} />
                </BarChart>
              </ResponsiveContainer>
            </CardContent></Card>
          </Grid>
        </Grid>
      )}

      <Card><CardContent sx={{ p: 0 }}>
        <Table>
          <TableHead>
            <TableRow>
              <TableCell>Metric</TableCell>
              <TableCell>Category</TableCell>
              <TableCell>Records</TableCell>
              <TableCell>Total</TableCell>
              <TableCell>Average</TableCell>
              <TableCell>Unit</TableCell>
            </TableRow>
          </TableHead>
          <TableBody>
            {aggs.length === 0 ? (
              <TableRow><TableCell colSpan={6} sx={{ textAlign: "center", py: 5 }}>
                <Typography color="text.secondary">
                  {fromDate || toDate
                    ? "No metrics recorded in this date range — widen the filter or add metrics."
                    : "No metrics yet. Add Carbon, Energy, Waste metrics to see the report."}
                </Typography>
              </TableCell></TableRow>
            ) : aggs.map(a => (
              <TableRow key={`${a.category}|${a.metric}`} hover>
                <TableCell><Typography fontWeight={600}>{a.metric}</Typography></TableCell>
                <TableCell><Chip label={a.category} size="small" variant="outlined" sx={{ textTransform: "capitalize" }} /></TableCell>
                <TableCell>{a.count}</TableCell>
                <TableCell><Typography fontWeight={700}>{a.total.toLocaleString()}</Typography></TableCell>
                <TableCell>{a.avg.toFixed(2)}</TableCell>
                <TableCell>{a.unit || "-"}</TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </CardContent></Card>
    </Box>
  );
}
