import { useEffect, useState } from "react";
import { Box, Card, CardContent, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, Typography, Chip } from "@mui/material";
import { supabase } from "../../../../../lib/supabaseClient";

interface Opp {
  id: string;
  estimated_value: number;
  probability: number;
  expected_close_date: string | null;
  stage: string;
  currency: string;
}

interface MonthAgg {
  month: string; // YYYY-MM
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

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Revenue Forecast</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        Monthly forecast based on expected_close_date. Weighted = value × probability. Excludes Closed Lost. Uses bd_opportunities.
      </Typography>

      <Box sx={{ display: "flex", gap: 2, mb: 3, flexWrap: "wrap" }}>
        <Card sx={{ minWidth: 180 }}><CardContent><Typography variant="caption" color="text.secondary">Opportunities in Forecast</Typography><Typography variant="h5" fontWeight={700}>{totals.count}</Typography></CardContent></Card>
        <Card sx={{ minWidth: 200 }}><CardContent><Typography variant="caption" color="text.secondary">Total Raw Value</Typography><Typography variant="h5" fontWeight={700}>USD {totals.raw.toLocaleString()}</Typography></CardContent></Card>
        <Card sx={{ minWidth: 200, bgcolor: "success.light" }}><CardContent><Typography variant="caption">Weighted Forecast</Typography><Typography variant="h5" fontWeight={700}>USD {totals.weighted.toLocaleString()}</Typography></CardContent></Card>
      </Box>

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
                      <TableCell>USD {m.raw.toLocaleString()}</TableCell>
                      <TableCell><Typography fontWeight={700}>USD {m.weighted.toLocaleString()}</Typography></TableCell>
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