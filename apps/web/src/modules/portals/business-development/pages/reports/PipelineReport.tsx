import { useEffect, useState } from "react";
import { Box, Card, CardContent, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, Typography, LinearProgress, Chip } from "@mui/material";
import { supabase } from "../../../../../lib/supabaseClient";

interface Stage {
  stage: string;
  label: string;
  color: string;
  order_index: number;
  probability_default: number;
}

interface Opp {
  id: string;
  stage: string;
  estimated_value: number;
  probability: number;
  currency: string;
}

interface StageAgg {
  stage: string;
  label: string;
  color: string;
  order_index: number;
  count: number;
  total: number;
  weighted: number;
  avgProbability: number;
}

export default function PipelineReport() {
  const [aggs, setAggs] = useState<StageAgg[]>([]);
  const [loading, setLoading] = useState(true);
  const [totals, setTotals] = useState({ count: 0, total: 0, weighted: 0 });

  const fetchReport = async () => {
    setLoading(true);
    const [stagesRes, oppsRes] = await Promise.all([
      supabase.from("bd_opportunity_stages").select("*").eq("is_active", true).order("order_index"),
      supabase.from("bd_opportunities").select("stage, estimated_value, probability, currency"),
    ]);

    const stages = (stagesRes.data as Stage[]) || [];
    const opps = (oppsRes.data as Opp[]) || [];

    const map: Record<string, StageAgg> = {};
    stages.forEach(s => {
      map[s.stage] = {
        stage: s.stage,
        label: s.label,
        color: s.color,
        order_index: s.order_index,
        count: 0,
        total: 0,
        weighted: 0,
        avgProbability: s.probability_default,
      };
    });

    opps.forEach(o => {
      if (!map[o.stage]) {
        map[o.stage] = {
          stage: o.stage,
          label: o.stage,
          color: "#eee",
          order_index: 999,
          count: 0,
          total: 0,
          weighted: 0,
          avgProbability: o.probability,
        };
      }
      map[o.stage].count += 1;
      map[o.stage].total += Number(o.estimated_value);
      map[o.stage].weighted += Number(o.estimated_value) * (o.probability / 100);
    });

    // Calculate avg probability per stage
    Object.values(map).forEach(agg => {
      const stageOpps = opps.filter(o => o.stage === agg.stage);
      if (stageOpps.length > 0) {
        agg.avgProbability = Math.round(stageOpps.reduce((sum, o) => sum + o.probability, 0) / stageOpps.length);
      }
    });

    const sorted = Object.values(map).sort((a, b) => a.order_index - b.order_index);
    setAggs(sorted);
    setTotals({
      count: opps.length,
      total: opps.reduce((s, o) => s + Number(o.estimated_value), 0),
      weighted: opps.reduce((s, o) => s + Number(o.estimated_value) * (o.probability / 100), 0),
    });
    setLoading(false);
  };

  useEffect(() => { fetchReport(); }, []);

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  const currency = "USD"; // Could detect from first opp or make dynamic

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Pipeline Report</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>
        Pipeline value by stage. Weighted = total value × probability. Uses Opportunity Stages order and probability defaults.
      </Typography>

      <Box sx={{ display: "flex", gap: 2, mb: 3, flexWrap: "wrap" }}>
        <Card sx={{ minWidth: 200 }}><CardContent><Typography variant="caption" color="text.secondary">Total Opportunities</Typography><Typography variant="h5" fontWeight={700}>{totals.count}</Typography></CardContent></Card>
        <Card sx={{ minWidth: 200 }}><CardContent><Typography variant="caption" color="text.secondary">Total Value</Typography><Typography variant="h5" fontWeight={700}>{currency} {totals.total.toLocaleString()}</Typography></CardContent></Card>
        <Card sx={{ minWidth: 200, bgcolor: "primary.light", color: "primary.contrastText" }}><CardContent><Typography variant="caption" sx={{ opacity: 0.8 }}>Weighted Pipeline</Typography><Typography variant="h5" fontWeight={700}>{currency} {totals.weighted.toLocaleString()}</Typography></CardContent></Card>
      </Box>

      <Card>
        <CardContent sx={{ p: 0 }}>
          <Table>
            <TableHead>
              <TableRow>
                <TableCell>Stage</TableCell>
                <TableCell>Order</TableCell>
                <TableCell>Count</TableCell>
                <TableCell>Total Value</TableCell>
                <TableCell>Weighted Value</TableCell>
                <TableCell>Avg Probability</TableCell>
                <TableCell>Pipeline %</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {aggs.length === 0 ? (
                <TableRow><TableCell colSpan={7} sx={{ textAlign: "center", py: 4 }}><Typography color="text.secondary">No stages or opportunities yet. Seed Opportunity Stages and create opportunities.</Typography></TableCell></TableRow>
              ) : (
                aggs.map(a => {
                  const pipelinePct = totals.total > 0 ? (a.total / totals.total) * 100 : 0;
                  return (
                    <TableRow key={a.stage} hover>
                      <TableCell>
                        <Box sx={{ display: "flex", alignItems: "center", gap: 1 }}>
                          <Box sx={{ width: 12, height: 12, borderRadius: "50%", bgcolor: a.color }} />
                          <Typography fontWeight={600}>{a.label}</Typography>
                        </Box>
                      </TableCell>
                      <TableCell>{a.order_index}</TableCell>
                      <TableCell><Chip label={a.count} size="small" /></TableCell>
                      <TableCell>{currency} {a.total.toLocaleString()}</TableCell>
                      <TableCell><Typography fontWeight={600}>{currency} {a.weighted.toLocaleString()}</Typography></TableCell>
                      <TableCell>
                        <Box sx={{ display: "flex", alignItems: "center", gap: 1 }}>
                          <LinearProgress variant="determinate" value={a.avgProbability} sx={{ width: 60, height: 6, borderRadius: 1 }} />
                          <Typography variant="caption">{a.avgProbability}%</Typography>
                        </Box>
                      </TableCell>
                      <TableCell>
                        <Box sx={{ display: "flex", alignItems: "center", gap: 1 }}>
                          <LinearProgress variant="determinate" value={pipelinePct} sx={{ width: 60, height: 6, borderRadius: 1 }} color="primary" />
                          <Typography variant="caption">{pipelinePct.toFixed(1)}%</Typography>
                        </Box>
                      </TableCell>
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
