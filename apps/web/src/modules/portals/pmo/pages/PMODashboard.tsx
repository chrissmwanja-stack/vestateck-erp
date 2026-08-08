import { useEffect, useState } from "react";
import { Box, Card, CardContent, CircularProgress, Grid, Typography, LinearProgress } from "@mui/material";
import { supabase } from "../../../../lib/supabaseClient";

export default function PMODashboard() {
  const [stats, setStats] = useState({ total: 0, inProgress: 0, completed: 0, onHold: 0, tasksTotal: 0, tasksCompleted: 0, tasksOverdue: 0, budgetTotal: 0, budgetActual: 0 });
  const [loading, setLoading] = useState(true);

  const fetchStats = async () => {
    setLoading(true);
    const [projectsRes, tasksRes] = await Promise.all([
      supabase.from("pmo_projects").select("id, status, budget"),
      supabase.from("pmo_tasks").select("id, status, due_date"),
    ]);

    const projects = (projectsRes.data as any[]) || [];
    const tasks = (tasksRes.data as any[]) || [];

    const now = new Date().getTime();
    const overdue = tasks.filter((t: any) => {
      if (!t.due_date || t.status === 'done') return false;
      return new Date(t.due_date).getTime() < now;
    }).length;

    setStats({
      total: projects.length,
      inProgress: projects.filter((p: any) => p.status === 'in_progress').length,
      completed: projects.filter((p: any) => p.status === 'completed').length,
      onHold: projects.filter((p: any) => p.status === 'on_hold').length,
      tasksTotal: tasks.length,
      tasksCompleted: tasks.filter((t: any) => t.status === 'done').length,
      tasksOverdue: overdue,
      budgetTotal: projects.reduce((sum: number, p: any) => sum + (Number(p.budget) || 0), 0),
      budgetActual: 0, // Would need actual cost tracking table
    });
    setLoading(false);
  };

  useEffect(() => { fetchStats(); }, []);

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  const taskProgress = stats.tasksTotal > 0 ? (stats.tasksCompleted / stats.tasksTotal) * 100 : 0;

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>PMO Dashboard</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>Projects status, tasks progress, budget overview, milestone slipping.</Typography>
      
      <Grid container spacing={2}>
        <Grid item xs={12} sm={6} md={3}><Card><CardContent><Typography variant="caption" color="text.secondary">Total Projects</Typography><Typography variant="h4" fontWeight={700}>{stats.total}</Typography></CardContent></Card></Grid>
        <Grid item xs={12} sm={6} md={3}><Card sx={{ bgcolor: "success.light" }}><CardContent><Typography variant="caption">In Progress</Typography><Typography variant="h4" fontWeight={700}>{stats.inProgress}</Typography></CardContent></Card></Grid>
        <Grid item xs={12} sm={6} md={3}><Card sx={{ bgcolor: "primary.light" }}><CardContent><Typography variant="caption">Completed</Typography><Typography variant="h4" fontWeight={700}>{stats.completed}</Typography></CardContent></Card></Grid>
        <Grid item xs={12} sm={6} md={3}><Card sx={{ bgcolor: "warning.light" }}><CardContent><Typography variant="caption">On Hold</Typography><Typography variant="h4" fontWeight={700}>{stats.onHold}</Typography></CardContent></Card></Grid>

        <Grid item xs={12} sm={6} md={4}><Card><CardContent><Typography variant="caption">Total Tasks</Typography><Typography variant="h4" fontWeight={700}>{stats.tasksTotal}</Typography><Box sx={{ mt: 1 }}><LinearProgress variant="determinate" value={taskProgress} /><Typography variant="caption">{taskProgress.toFixed(0)}% completed ({stats.tasksCompleted}/{stats.tasksTotal})</Typography></Box></CardContent></Card></Grid>
        <Grid item xs={12} sm={6} md={4}><Card sx={{ bgcolor: stats.tasksOverdue > 0 ? "error.light" : "grey.50" }}><CardContent><Typography variant="caption">Overdue Tasks</Typography><Typography variant="h4" fontWeight={700}>{stats.tasksOverdue}</Typography></CardContent></Card></Grid>
        <Grid item xs={12} sm={6} md={4}><Card><CardContent><Typography variant="caption">Total Budget</Typography><Typography variant="h4" fontWeight={700}>UGX {stats.budgetTotal.toLocaleString()}</Typography></CardContent></Card></Grid>
      </Grid>
    </Box>
  );
}
