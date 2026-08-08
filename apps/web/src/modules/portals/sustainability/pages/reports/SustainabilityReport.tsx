import { useEffect, useState } from "react";
import { Box, Card, CardContent, Chip, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, Typography } from "@mui/material";
import { supabase } from "../../../../../lib/supabaseClient";

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
    const { data } = await supabase.from("sustainability_metrics").select("type, value, unit, sustainability_metric_types(unit)");
    const metrics = (data as any[]) || [];

    const map: Record<string, { count: number; total: number; unit: string }> = {};
    metrics.forEach((m: any) => {
      if (!map[m.type]) map[m.type] = { count: 0, total: 0, unit: m.sustainability_metric_types?.unit || m.unit || "" };
      map[m.type].count += 1;
      map[m.type].total += Number(m.value);
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

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1000 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Sustainability Report</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>Annual report: carbon, energy, water, waste totals and averages. Aggregates from sustainability_metrics by type.</Typography>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Metric Type</TableCell><TableCell>Records</TableCell><TableCell>Total Value</TableCell><TableCell>Average</TableCell><TableCell>Unit</TableCell></TableRow></TableHead><TableBody>{aggs.length === 0 ? <TableRow><TableCell colSpan={5} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No metrics yet. Add Carbon, Energy, Waste metrics to see report.</Typography></TableCell></TableRow> : aggs.map(a => <TableRow key={a.type} hover><TableCell><Chip label={a.type} size="small" variant="outlined" sx={{ textTransform: "capitalize" }} /></TableCell><TableCell>{a.count}</TableCell><TableCell><Typography fontWeight={700}>{a.total.toLocaleString()}</Typography></TableCell><TableCell>{a.avg.toFixed(2)}</TableCell><TableCell>{a.unit || "-"}</TableCell></TableRow>)}</TableBody></Table></CardContent></Card>
    </Box>
  );
}
