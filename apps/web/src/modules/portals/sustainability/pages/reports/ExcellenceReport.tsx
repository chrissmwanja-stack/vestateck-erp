import { useEffect, useState } from "react";
import { Box, Card, CardContent, Chip, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, Typography, LinearProgress } from "@mui/material";
import { supabase } from "../../../../../lib/supabaseClient";

export default function ExcellenceReport() {
  const [initiatives, setInitiatives] = useState<any[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const fetch = async () => {
      setLoading(true);
      const { data } = await supabase.from("sustainability_initiatives").select("status, target_value, current_value");
      if (data) setInitiatives(data);
      setLoading(false);
    };
    fetch();
  }, []);

  const stats = {
    total: initiatives.length,
    completed: initiatives.filter((i: any) => i.status === 'completed').length,
    inProgress: initiatives.filter((i: any) => i.status === 'in_progress').length,
    planned: initiatives.filter((i: any) => i.status === 'planned').length,
    avgProgress: initiatives.length > 0 ? initiatives.reduce((sum: number, i: any) => {
      if (!i.target_value || i.target_value === 0 || i.current_value === null) return sum;
      return sum + Math.min(100, (i.current_value / i.target_value) * 100);
    }, 0) / initiatives.length : 0,
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1000 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>Excellence Scorecard</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>Business excellence KPIs: leadership, strategy, customers, operations, results. Based on initiatives progress.</Typography>

      <Box sx={{ display: "flex", gap: 2, mb: 3, flexWrap: "wrap" }}>
        <Card sx={{ minWidth: 150 }}><CardContent><Typography variant="caption">Total Initiatives</Typography><Typography variant="h5" fontWeight={700}>{stats.total}</Typography></CardContent></Card>
        <Card sx={{ minWidth: 150, bgcolor: "success.light" }}><CardContent><Typography variant="caption">Completed</Typography><Typography variant="h5" fontWeight={700}>{stats.completed}</Typography></CardContent></Card>
        <Card sx={{ minWidth: 150, bgcolor: "primary.light" }}><CardContent><Typography variant="caption">In Progress</Typography><Typography variant="h5" fontWeight={700}>{stats.inProgress}</Typography></CardContent></Card>
        <Card sx={{ minWidth: 200 }}><CardContent><Typography variant="caption">Avg Progress</Typography><Box sx={{ display: "flex", alignItems: "center", gap: 1, mt: 1 }}><LinearProgress variant="determinate" value={stats.avgProgress} sx={{ flex: 1, height: 8 }} /><Typography variant="body2" fontWeight={700}>{stats.avgProgress.toFixed(0)}%</Typography></Box></CardContent></Card>
      </Box>

      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Category</TableCell><TableCell>Score</TableCell><TableCell>Status</TableCell></TableRow></TableHead><TableBody>
        <TableRow><TableCell>Leadership & Strategy</TableCell><TableCell>{stats.avgProgress > 80 ? "Excellent" : stats.avgProgress > 50 ? "Good" : "Needs Improvement"}</TableCell><TableCell><Chip label={`${stats.avgProgress.toFixed(0)}%`} size="small" color={stats.avgProgress > 80 ? "success" : stats.avgProgress > 50 ? "primary" : "warning"} /></TableCell></TableRow>
        <TableRow><TableCell>Initiatives Completion</TableCell><TableCell>{stats.total > 0 ? `${stats.completed}/${stats.total}` : "No data"}</TableCell><TableCell><Chip label={stats.total > 0 ? `${((stats.completed / stats.total) * 100).toFixed(0)}%` : "0%"} size="small" /></TableCell></TableRow>
      </TableBody></Table></CardContent></Card>
    </Box>
  );
}
