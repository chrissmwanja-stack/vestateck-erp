import { useEffect, useState, useMemo } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, Typography, LinearProgress, Grid } from "@mui/material";
import { FileDownload, Download } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { exportReportToExcel, exportReportToPdf } from "../../../../../lib/reportExport";
import { PieChart, Pie, Cell, ResponsiveContainer, Legend, Tooltip as ReTooltip } from "recharts";

const COLORS = ["#2e7d32", "#1976d2", "#ed6c02", "#9e9e9e"];

export default function ExcellenceReport() {
  const [initiatives, setInitiatives] = useState<any[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const fetch = async () => {
      setLoading(true);
      const { data } = await supabase.from("sustainability_initiatives").select("status, target_value, current_value").limit(500);
      if (data) setInitiatives(data);
      setLoading(false);
    };
    fetch();
  }, []);

  const stats = useMemo(() => ({
    total: initiatives.length,
    completed: initiatives.filter((i: any) => i.status === 'completed').length,
    inProgress: initiatives.filter((i: any) => i.status === 'in_progress').length,
    planned: initiatives.filter((i: any) => i.status === 'planned').length,
    onHold: initiatives.filter((i: any) => i.status === 'on_hold').length,
    avgProgress: initiatives.length > 0 ? initiatives.reduce((sum: number, i: any) => {
      if (!i.target_value || i.target_value === 0 || i.current_value === null) return sum;
      return sum + Math.min(100, (i.current_value / i.target_value) * 100);
    }, 0) / initiatives.length : 0,
  }), [initiatives]);

  const pieData = useMemo(() => [
    { name: "Completed", value: stats.completed },
    { name: "In Progress", value: stats.inProgress },
    { name: "Planned", value: stats.planned },
    { name: "On Hold", value: stats.onHold },
  ].filter(d => d.value > 0), [stats]);

  const handleExcel = () => {
    const rows = [
      { category: "Leadership & Strategy", score: stats.avgProgress > 80 ? "Excellent" : stats.avgProgress > 50 ? "Good" : "Needs Improvement", value: `${stats.avgProgress.toFixed(0)}%` },
      { category: "Initiatives Completion", score: `${stats.completed}/${stats.total}`, value: `${stats.total ? ((stats.completed/stats.total)*100).toFixed(0):0}%` },
      { category: "In Progress", score: `${stats.inProgress} active`, value: `${stats.inProgress}` },
      { category: "Planned", score: `${stats.planned} queued`, value: `${stats.planned}` },
    ];
    const cols = [
      { header: "Category", accessor: (r: any) => r.category },
      { header: "Score", accessor: (r: any) => r.score },
      { header: "Value", accessor: (r: any) => r.value },
    ];
    exportReportToExcel(`excellence-scorecard-${new Date().toISOString().slice(0,10)}`, "Excellence", cols as any, rows);
  };
  const handlePdf = () => {
    const rows = [
      { category: "Leadership & Strategy", score: stats.avgProgress > 80 ? "Excellent" : stats.avgProgress > 50 ? "Good" : "Needs Improvement", value: `${stats.avgProgress.toFixed(0)}%` },
      { category: "Initiatives Completion", score: `${stats.completed}/${stats.total}`, value: `${stats.total ? ((stats.completed/stats.total)*100).toFixed(0):0}%` },
    ];
    const cols = [
      { header: "Category", accessor: (r: any) => r.category },
      { header: "Score", accessor: (r: any) => r.score },
      { header: "Value", accessor: (r: any) => r.value },
    ];
    exportReportToPdf(`excellence-scorecard-${new Date().toISOString().slice(0,10)}.pdf`, "Excellence Scorecard", cols as any, rows, `Avg Progress ${stats.avgProgress.toFixed(0)}% • ${stats.completed}/${stats.total} completed`);
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", mb: 2, gap: 2, flexWrap: "wrap" }}>
        <Box>
          <Typography variant="h5" fontWeight={700} gutterBottom>Excellence Scorecard</Typography>
          <Typography variant="body2" color="text.secondary">Business excellence KPIs: leadership, strategy, customers, operations, results. Based on initiatives progress.</Typography>
        </Box>
        <Box sx={{ display: "flex", gap: 1 }}>
          <Button size="small" variant="outlined" startIcon={<FileDownload />} onClick={handleExcel} disabled={initiatives.length===0}>Excel</Button>
          <Button size="small" variant="outlined" startIcon={<Download />} onClick={handlePdf} disabled={initiatives.length===0}>PDF</Button>
        </Box>
      </Box>

      <Box sx={{ display: "flex", gap: 2, mb: 3, flexWrap: "wrap" }}>
        <Card sx={{ minWidth: 150 }}><CardContent><Typography variant="caption">Total Initiatives</Typography><Typography variant="h5" fontWeight={700}>{stats.total}</Typography></CardContent></Card>
        <Card sx={{ minWidth: 150, bgcolor: "success.light" }}><CardContent><Typography variant="caption">Completed</Typography><Typography variant="h5" fontWeight={700}>{stats.completed}</Typography></CardContent></Card>
        <Card sx={{ minWidth: 150, bgcolor: "primary.light" }}><CardContent><Typography variant="caption">In Progress</Typography><Typography variant="h5" fontWeight={700}>{stats.inProgress}</Typography></CardContent></Card>
        <Card sx={{ minWidth: 200 }}><CardContent><Typography variant="caption">Avg Progress</Typography><Box sx={{ display: "flex", alignItems: "center", gap: 1, mt: 1 }}><LinearProgress variant="determinate" value={stats.avgProgress} sx={{ flex: 1, height: 8 }} /><Typography variant="body2" fontWeight={700}>{stats.avgProgress.toFixed(0)}%</Typography></Box></CardContent></Card>
      </Box>

      {initiatives.length > 0 && (
        <Grid container spacing={2} sx={{ mb: 2 }}>
          <Grid item xs={12} md={6}>
            <Card variant="outlined"><CardContent>
              <Typography variant="subtitle2" fontWeight={700} gutterBottom>Status Distribution</Typography>
              <ResponsiveContainer width="100%" height={220}>
                <PieChart>
                  <Pie data={pieData} dataKey="value" nameKey="name" cx="50%" cy="50%" outerRadius={80} label={({name,value})=>`${name} ${value}`}>
                    {pieData.map((_,i)=><Cell key={i} fill={COLORS[i % COLORS.length]} />)}
                  </Pie>
                  <ReTooltip /><Legend />
                </PieChart>
              </ResponsiveContainer>
            </CardContent></Card>
          </Grid>
          <Grid item xs={12} md={6}>
            <Card variant="outlined"><CardContent>
              <Typography variant="subtitle2" fontWeight={700} gutterBottom>Score Breakdown</Typography>
              <Box sx={{ display: "flex", flexDirection: "column", gap: 2, mt: 2 }}>
                <Box><Typography variant="caption">Avg Progress</Typography><Box sx={{ display: "flex", alignItems: "center", gap: 1 }}><LinearProgress variant="determinate" value={stats.avgProgress} sx={{ flex: 1, height: 10 }} color={stats.avgProgress > 80 ? "success" : stats.avgProgress > 50 ? "primary" : "warning"} /><Typography variant="body2" fontWeight={700}>{stats.avgProgress.toFixed(0)}%</Typography></Box></Box>
                <Box><Typography variant="caption">Completion Rate</Typography><Box sx={{ display: "flex", alignItems: "center", gap: 1 }}><LinearProgress variant="determinate" value={stats.total ? (stats.completed/stats.total)*100 : 0} sx={{ flex: 1, height: 10 }} color="success" /><Typography variant="body2" fontWeight={700}>{stats.total ? ((stats.completed/stats.total)*100).toFixed(0):0}% ({stats.completed}/{stats.total})</Typography></Box></Box>
              </Box>
            </CardContent></Card>
          </Grid>
        </Grid>
      )}

      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Category</TableCell><TableCell>Score</TableCell><TableCell>Status</TableCell></TableRow></TableHead><TableBody>
        <TableRow><TableCell>Leadership & Strategy</TableCell><TableCell>{stats.avgProgress > 80 ? "Excellent" : stats.avgProgress > 50 ? "Good" : "Needs Improvement"}</TableCell><TableCell><Chip label={`${stats.avgProgress.toFixed(0)}%`} size="small" color={stats.avgProgress > 80 ? "success" : stats.avgProgress > 50 ? "primary" : "warning"} /></TableCell></TableRow>
        <TableRow><TableCell>Initiatives Completion</TableCell><TableCell>{stats.total > 0 ? `${stats.completed}/${stats.total}` : "No data"}</TableCell><TableCell><Chip label={stats.total > 0 ? `${((stats.completed / stats.total) * 100).toFixed(0)}%` : "0%"} size="small" /></TableCell></TableRow>
      </TableBody></Table></CardContent></Card>
    </Box>
  );
}
