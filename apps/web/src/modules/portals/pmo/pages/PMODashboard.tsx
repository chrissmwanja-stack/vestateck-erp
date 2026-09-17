import { useEffect, useState } from "react";
import { Box, Card, CardContent, CircularProgress, Grid, Typography, LinearProgress, Button } from "@mui/material";
import { supabase } from "../../../../lib/supabaseClient";
import { useNavigate } from "react-router-dom";
import { PieChart, Pie, Cell, BarChart, Bar, XAxis, YAxis, Tooltip as ReTooltip, ResponsiveContainer, Legend } from "recharts";

const COLORS: Record<string, string> = {
  not_started: "#9e9e9e",
  in_progress: "#1976d2",
  completed: "#2e7d32",
  on_hold: "#ed6c02",
  cancelled: "#d32f2f",
};

export default function PMODashboard() {
  const navigate = useNavigate();
  const [stats, setStats] = useState({ total: 0, inProgress: 0, completed: 0, onHold: 0, notStarted: 0, tasksTotal: 0, tasksCompleted: 0, tasksOverdue: 0, tasksTodo: 0, tasksInProgress: 0, budgetTotal: 0, budgetActual: 0 });
  const [statusBreakdown, setStatusBreakdown] = useState<{ name: string; value: number }[]>([]);
  const [taskBreakdown, setTaskBreakdown] = useState<{ name: string; value: number }[]>([]);
  const [loading, setLoading] = useState(true);

  const fetchStats = async () => {
    setLoading(true);
    const [projectsRes, tasksRes] = await Promise.all([
      supabase.from("pmo_projects").select("id, status, budget, pmo_tasks(completion_percent)").limit(500),
      supabase.from("pmo_tasks").select("id, status, due_date, completion_percent").limit(500),
    ]);

    const projects = (projectsRes.data as any[]) || [];
    const tasks = (tasksRes.data as any[]) || [];

    const now = new Date().getTime();
    const overdue = tasks.filter((t: any) => {
      if (!t.due_date || t.status === "done") return false;
      return new Date(t.due_date).getTime() < now;
    }).length;

    // budget actual as earned value
    const budgetTotal = projects.reduce((sum: number, p: any) => sum + (Number(p.budget) || 0), 0);
    const budgetActual = projects.reduce((sum: number, p: any) => {
      const b = Number(p.budget) || 0;
      const avg = (p.pmo_tasks as any[])?.length ? (p.pmo_tasks as any[]).reduce((s: number, t: any) => s + (Number(t.completion_percent) || 0), 0) / (p.pmo_tasks as any[]).length : 0;
      return sum + b * (avg / 100);
    }, 0);

    setStats({
      total: projects.length,
      inProgress: projects.filter((p: any) => p.status === "in_progress").length,
      completed: projects.filter((p: any) => p.status === "completed").length,
      onHold: projects.filter((p: any) => p.status === "on_hold").length,
      notStarted: projects.filter((p: any) => p.status === "not_started").length,
      tasksTotal: tasks.length,
      tasksCompleted: tasks.filter((t: any) => t.status === "done").length,
      tasksTodo: tasks.filter((t: any) => t.status === "todo").length,
      tasksInProgress: tasks.filter((t: any) => t.status === "in_progress").length,
      tasksOverdue: overdue,
      budgetTotal,
      budgetActual,
    });

    const sb = [
      { name: "Not Started", value: projects.filter((p: any) => p.status === "not_started").length },
      { name: "In Progress", value: projects.filter((p: any) => p.status === "in_progress").length },
      { name: "Completed", value: projects.filter((p: any) => p.status === "completed").length },
      { name: "On Hold", value: projects.filter((p: any) => p.status === "on_hold").length },
      { name: "Cancelled", value: projects.filter((p: any) => p.status === "cancelled").length },
    ].filter((d) => d.value > 0);
    setStatusBreakdown(sb);

    const tb = [
      { name: "To Do", value: tasks.filter((t: any) => t.status === "todo").length },
      { name: "In Progress", value: tasks.filter((t: any) => t.status === "in_progress").length },
      { name: "Review", value: tasks.filter((t: any) => t.status === "review").length },
      { name: "Done", value: tasks.filter((t: any) => t.status === "done").length },
    ].filter((d) => d.value > 0);
    setTaskBreakdown(tb);

    setLoading(false);
  };

  useEffect(() => { fetchStats(); }, []);

  const taskProgress = stats.tasksTotal > 0 ? (stats.tasksCompleted / stats.tasksTotal) * 100 : 0;
  const budgetUtil = stats.budgetTotal > 0 ? (stats.budgetActual / stats.budgetTotal) * 100 : 0;

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <Typography variant="h5" fontWeight={700} gutterBottom>PMO Dashboard</Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 3 }}>Projects status, tasks progress, budget earned-value overview. Click cards to drill into reports.</Typography>

      <Grid container spacing={2} sx={{ mb: 3 }}>
        <Grid item xs={12} sm={6} md={3}>
          <Card sx={{ cursor: "pointer" }} onClick={() => navigate("/pmo/projects")}><CardContent><Typography variant="caption" color="text.secondary">Total Projects</Typography><Typography variant="h4" fontWeight={700}>{stats.total}</Typography><Typography variant="caption" color="text.secondary">{stats.inProgress} in progress • {stats.completed} completed</Typography></CardContent></Card>
        </Grid>
        <Grid item xs={12} sm={6} md={3}>
          <Card sx={{ bgcolor: stats.inProgress ? "primary.light" : "grey.50" }}><CardContent><Typography variant="caption">In Progress</Typography><Typography variant="h4" fontWeight={700}>{stats.inProgress}</Typography></CardContent></Card>
        </Grid>
        <Grid item xs={12} sm={6} md={3}>
          <Card sx={{ bgcolor: "success.light" }}><CardContent><Typography variant="caption">Completed</Typography><Typography variant="h4" fontWeight={700}>{stats.completed}</Typography></CardContent></Card>
        </Grid>
        <Grid item xs={12} sm={6} md={3}>
          <Card sx={{ bgcolor: stats.onHold ? "warning.light" : "grey.50" }}><CardContent><Typography variant="caption">On Hold</Typography><Typography variant="h4" fontWeight={700}>{stats.onHold}</Typography></CardContent></Card>
        </Grid>

        <Grid item xs={12} sm={6} md={4}>
          <Card><CardContent><Typography variant="caption">Total Tasks</Typography><Typography variant="h4" fontWeight={700}>{stats.tasksTotal}</Typography><Box sx={{ mt: 1 }}><LinearProgress variant="determinate" value={taskProgress} /><Typography variant="caption">{taskProgress.toFixed(0)}% completed ({stats.tasksCompleted}/{stats.tasksTotal}) • {stats.tasksTodo} todo • {stats.tasksInProgress} in progress</Typography></Box></CardContent></Card>
        </Grid>
        <Grid item xs={12} sm={6} md={4}>
          <Card sx={{ bgcolor: stats.tasksOverdue > 0 ? "error.light" : "grey.50", cursor: "pointer" }} onClick={() => navigate("/pmo/reports/status")}><CardContent><Typography variant="caption">Overdue Tasks</Typography><Typography variant="h4" fontWeight={700}>{stats.tasksOverdue}</Typography><Typography variant="caption">Due date before today & not done • See Project Status report</Typography></CardContent></Card>
        </Grid>
        <Grid item xs={12} sm={6} md={4}>
          <Card sx={{ cursor: "pointer" }} onClick={() => navigate("/pmo/reports/budget")}><CardContent><Typography variant="caption">Total Budget / Earned</Typography><Typography variant="h6" fontWeight={700}>UGX {stats.budgetTotal.toLocaleString()}</Typography><Typography variant="body2" color="text.secondary">Earned: UGX {Math.round(stats.budgetActual).toLocaleString()} ({budgetUtil.toFixed(0)}%)</Typography><LinearProgress variant="determinate" value={Math.min(100, budgetUtil)} sx={{ mt: 1, height: 6 }} /></CardContent></Card>
        </Grid>
      </Grid>

      <Grid container spacing={2}>
        <Grid item xs={12} md={6}>
          <Card variant="outlined"><CardContent>
            <Typography variant="subtitle2" fontWeight={700} gutterBottom>Projects by Status</Typography>
            {statusBreakdown.length === 0 ? <Typography variant="body2" color="text.secondary" sx={{ py: 4, textAlign: "center" }}>No projects yet.</Typography> : (
              <ResponsiveContainer width="100%" height={240}>
                <PieChart>
                  <Pie data={statusBreakdown} dataKey="value" nameKey="name" cx="50%" cy="50%" outerRadius={90} label={({ name, value }) => `${name} ${value}`}>
                    {statusBreakdown.map((entry, idx) => {
                      const key = entry.name.toLowerCase().replace(" ", "_");
                      return <Cell key={idx} fill={COLORS[key] || "#607d8b"} />;
                    })}
                  </Pie>
                  <ReTooltip />
                  <Legend />
                </PieChart>
              </ResponsiveContainer>
            )}
          </CardContent></Card>
        </Grid>
        <Grid item xs={12} md={6}>
          <Card variant="outlined"><CardContent>
            <Typography variant="subtitle2" fontWeight={700} gutterBottom>Tasks by Status</Typography>
            {taskBreakdown.length === 0 ? <Typography variant="body2" color="text.secondary" sx={{ py: 4, textAlign: "center" }}>No tasks yet.</Typography> : (
              <ResponsiveContainer width="100%" height={240}>
                <BarChart data={taskBreakdown}>
                  <XAxis dataKey="name" fontSize={12} />
                  <YAxis allowDecimals={false} fontSize={12} />
                  <ReTooltip />
                  <Bar dataKey="value" fill="#1976d2" radius={[8, 8, 0, 0]} />
                </BarChart>
              </ResponsiveContainer>
            )}
            <Box sx={{ display: "flex", gap: 1, mt: 2, flexWrap: "wrap" }}>
              <Button size="small" variant="outlined" onClick={() => navigate("/pmo/tasks")}>Open Tasks</Button>
              <Button size="small" variant="outlined" onClick={() => navigate("/pmo/gantt")}>Gantt Chart</Button>
              <Button size="small" variant="outlined" onClick={() => navigate("/pmo/resources/allocation")}>Allocations</Button>
              <Button size="small" variant="outlined" onClick={() => navigate("/pmo/resources/utilization")}>Utilization</Button>
            </Box>
          </CardContent></Card>
        </Grid>
      </Grid>
    </Box>
  );
}
