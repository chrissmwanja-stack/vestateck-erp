import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, Typography, Chip, Tooltip } from "@mui/material";
import { Download } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { exportReportToExcel, exportReportToPdf } from "../../../../../lib/reportExport";
import { Bar, XAxis, YAxis, Tooltip as ReTooltip, ResponsiveContainer, Legend, Line, ComposedChart } from "recharts";

interface Opp {
  id: string;
  estimated_value: number;
  probability: number;
  expected_close_date: string | null;
  stage: string;
  currency: string;
}

interface MonthAgg {
  month: string;
  raw: number;
  weighted: number;
  count: number;
}

export default function RevenueForecast() {
  const [months, setMonths] = useState<MonthAgg[]>([]);
  const [loading, setLoading] = useState(true);
  const [totals, setTotals] = useState({ raw: 0, weighted: 0, count: 0 });

  const fetchForecast = async () => {
    setLoading(true);
    const { data } = await supabase
      .from("bd_opportunities")
      .select("estimated_value, probability, expected_close_date, stage, currency")
      .not("expected_close_date", "is", null)
      .neq("stage", "closed_lost");

    const opps = (data as Opp[]) || [];

    const map: Record<string, MonthAgg> = {};
    opps.forEach(o => {
      if (!o.expected_close_date) return;
      const d = new Date(o.expected_close_date);
      const month = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}`;
      if (!map[month]) map[month] = { month, raw: 0, weighted: 0, count: 0 };
      map[month].raw += Number(o.estimated_value);
      map[month].weighted += Number(o.estimated_value) * (o.probability / 100);
      map[month].count += 1;
    });

    const sorted = Object.values(map).sort((a, b) => a.month.localeCompare(b.month));
    setMonths(sorted);
    setTotals({
      raw: opps.reduce((s, o) => s + Number(o.estimated_value), 0),
      weighted: opps.reduce((s, o) => s + Number(o.estimated_value) * (o.probability / 100), 0),
      count: opps.length,
    });
    setLoading(false);
  };

  useEffect(() => { fetchForecast(); }, []);

  const handleExportExcel = () => {
    const rows = months.map(m => ({ month: m.month, count: m.count, raw: m.raw, weighted: m.weighted, confidence: m.raw ? Number(((m.weighted/m.raw)*100).toFixed(1)) : 0 }));
    const cols = [
      { header: "Month", accessor: (r:any) => r.month },
      { header: "Opps", accessor: (r:any) => r.count },
      { header: "Raw Value", accessor: (r:any) => r.raw },
      { header: "Weighted", accessor: (r:any) => r.weighted },
      { header: "Confidence %", accessor: (r:any) => r.confidence },
    ];
    exportReportToExcel("revenue_forecast", "Revenue Forecast", cols, rows);
  };
  const handleExportPDF = () => {
    const rows = months.map(m => ({ month: m.month, count: String(m.count), weighted: m.weighted.toLocaleString(), raw: m.raw.toLocaleString() }));
    const cols = [
      { header: "Month", accessor: (r:any) => r.month },
      { header: "Opps", accessor: (r:any) => r.count },
      { header: "Raw", accessor: (r:any) => r.raw },
      { header: "Weighted", accessor: (r:any) => r.weighted },
    ];
    exportReportToPdf("revenue_forecast.pdf", "Revenue Forecast", cols, rows);
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3, flexWrap: "wrap", gap: 2 }}>
        <Box><Typography variant="h5" fontWeight={700}>Revenue Forecast</Typography><Typography variant="body2" color="text.secondary">Monthly forecast based on expected_close_date. Weighted = value × probability. Excludes Closed Lost.</Typography></Box>
        <Box sx={{ display: "flex", gap: 1 }}><Tooltip title="Export Excel"><Button size="small" variant="outlined" onClick={handleExportExcel}>Excel</Button></Tooltip><Button size="small" variant="outlined" startIcon={<Download />} onClick={handleExportPDF}>PDF</Button></Box>
      </Box>

      <Box sx={{ display: "flex", gap: 2, mb: 3, flexWrap: "wrap" }}>
        <Card sx={{ minWidth: 180 }}><CardContent><Typography variant="caption" color="text.secondary">Opportunities in Forecast</Typography><Typography variant="h5" fontWeight={700}>{totals.count}</Typography></CardContent></Card>
        <Card sx={{ minWidth: 200 }}><CardContent><Typography variant="caption" color="text.secondary">Total Raw Value</Typography><Typography variant="h5" fontWeight={700}>UGX {totals.raw.toLocaleString()}</Typography></CardContent></Card>
        <Card sx={{ minWidth: 200, bgcolor: "success.light" }}><CardContent><Typography variant="caption">Weighted Forecast</Typography><Typography variant="h5" fontWeight={700}>UGX {totals.weighted.toLocaleString()}</Typography></CardContent></Card>
      </Box>

      {months.length > 0 && <Card sx={{ mb: 3 }}><CardContent><Typography variant="subtitle2" fontWeight={700} gutterBottom>Forecast Trend</Typography><Box sx={{ height: 280 }}><ResponsiveContainer width="100%" height="100%"><ComposedChart data={months}><XAxis dataKey="month" tick={{ fontSize: 11 }} /><YAxis tick={{ fontSize: 11 }} /><ReTooltip /><Legend /><Bar dataKey="raw" fill="#90caf9" name="Raw Value" /><Bar dataKey="weighted" fill="#2e7d32" name="Weighted" /><Line type="monotone" dataKey="weighted" stroke="#d32f2f" strokeWidth={2} dot={false} name="Weighted Trend" /></ComposedChart></ResponsiveContainer></Box></CardContent></Card>}

      <Card>
        <CardContent sx={{ p: 0 }}>
          <Table>
            <TableHead>
              <TableRow>
                <TableCell>Month</TableCell>
                <TableCell>Opportunities</TableCell>
                <TableCell>Raw Value</TableCell>
                <TableCell>Weighted Forecast</TableCell>
                <TableCell>Confidence</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {months.length === 0 ? (
                <TableRow><TableCell colSpan={5} sx={{ textAlign: "center", py: 6 }}><Typography color="text.secondary">No opportunities with expected_close_date set (and not lost). Set close dates on opportunities to see forecast.</Typography></TableCell></TableRow>
              ) : (
                months.map(m => {
                  const confidence = m.raw > 0 ? (m.weighted / m.raw) * 100 : 0;
                  return (
                    <TableRow key={m.month} hover>
                      <TableCell><Typography fontWeight={600}>{m.month}</Typography></TableCell>
                      <TableCell><Chip label={m.count} size="small" /></TableCell>
                      <TableCell>UGX {m.raw.toLocaleString()}</TableCell>
                      <TableCell><Typography fontWeight={700}>UGX {m.weighted.toLocaleString()}</Typography></TableCell>
                      <TableCell><Chip label={`${confidence.toFixed(0)}%`} size="small" color={confidence > 70 ? "success" : confidence > 40 ? "warning" : "default"} /></TableCell>
                    </TableRow>
                  );
                })
              )}
            </TableBody>
          </Table>
        </CardContent>
      </Card>
    </Box>
  );
}
