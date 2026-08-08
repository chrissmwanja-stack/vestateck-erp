import { Box, Card, CardContent, Table, TableBody, TableCell, TableHead, TableRow, Typography, CircularProgress } from "@mui/material";
import { useEffect, useState } from "react";
import { supabase } from "../../../../../lib/supabaseClient";

export default function BudgetVsActualReport() {
  const [projects, setProjects] = useState<any[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const fetch = async () => {
      setLoading(true);
      const { data } = await supabase.from("pmo_projects").select("id, name, budget, currency");
      if (data) setProjects(data);
      setLoading(false);
    };
    fetch();
  }, []);

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1000 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Budget vs Actual</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>Budget consumption, variance, forecast. Needs cost tracking integration with Financial Management.</Typography>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Project</TableCell><TableCell>Budget</TableCell><TableCell>Actual Cost</TableCell><TableCell>Variance</TableCell><TableCell>Utilization %</TableCell></TableRow></TableHead><TableBody>{projects.length === 0 ? <TableRow><TableCell colSpan={5} sx={{ textAlign: "center", py: 4 }}><Typography color="text.secondary">No budget data yet. Set budget on New Project.</Typography></TableCell></TableRow> : projects.map((p: any) => {
        const budget = Number(p.budget) || 0;
        const actual = 0; // Would come from financial cost transactions
        const variance = budget - actual;
        const util = budget > 0 ? (actual / budget) * 100 : 0;
        return <TableRow key={p.id} hover><TableCell><Typography fontWeight={600}>{p.name}</Typography></TableCell><TableCell>{p.currency} {budget.toLocaleString()}</TableCell><TableCell>{p.currency} {actual.toLocaleString()}</TableCell><TableCell sx={{ color: variance < 0 ? "error.main" : "success.main" }}>{p.currency} {variance.toLocaleString()}</TableCell><TableCell>{util.toFixed(1)}%</TableCell></TableRow>;
      })}</TableBody></Table></CardContent></Card>
    </Box>
  );
}
