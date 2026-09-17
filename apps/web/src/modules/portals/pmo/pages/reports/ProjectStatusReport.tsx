import { useEffect, useState, useMemo } from "react";
import {
  Box,
  Card,
  CardContent,
  Chip,
  CircularProgress,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableRow,
  Typography,
  Button,
  Alert,
  Grid,
  LinearProgress,
  TextField,
  MenuItem,
} from "@mui/material";
import { Download, FileDownload, Refresh } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { exportReportToExcel, exportReportToPdf } from "../../../../../lib/reportExport";

interface ProjectRow {
  id: string;
  name: string;
  status: string;
  start_date: string | null;
  end_date: string | null;
  pmo_tasks?: { id: string; status: string; due_date: string | null; completion_percent: number | null }[] | null;
  pmo_milestones?: { id: string; status: string; due_date: string | null; completion_percent: number }[] | null;
}

interface ComputedRow {
  id: string;
  name: string;
  status: string;
  totalTasks: number;
  completed: number;
  inProgress: number;
  todo: number;
  overdue: number;
  milestonesDone: number;
  milestonesTotal: number;
  avgCompletion: number;
  progress: number; // completed/total *100
  endDate: string | null;
  health: "on-track" | "at-risk" | "overdue" | "completed";
}



export default function ProjectStatusReport() {
  const [projects, setProjects] = useState<ProjectRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [statusFilter, setStatusFilter] = useState<string>("all");

  const fetch = async () => {
    setLoading(true);
    setError(null);
    const { data, error: err } = await supabase
      .from("pmo_projects")
      .select("id, name, status, start_date, end_date, pmo_tasks(id, status, due_date, completion_percent), pmo_milestones(id, status, due_date, completion_percent)")
      .order("end_date", { ascending: true })
      .limit(300);
    if (err) {
      setError(err.message);
      setLoading(false);
      return;
    }
    setProjects((data as ProjectRow[]) || []);
    setLoading(false);
  };

  useEffect(() => {
    fetch();
  }, []);

  const computed: ComputedRow[] = useMemo(() => {
    const now = new Date();
    now.setHours(0, 0, 0, 0);
    return projects.map((p) => {
      const tasks = (p.pmo_tasks as any[]) || [];
      const milestones = (p.pmo_milestones as any[]) || [];
      const totalTasks = tasks.length;
      const completed = tasks.filter((t: any) => t.status === "done").length;
      const inProgress = tasks.filter((t: any) => t.status === "in_progress").length;
      const todo = tasks.filter((t: any) => t.status === "todo").length;
      const overdue = tasks.filter((t: any) => {
        if (!t.due_date || t.status === "done") return false;
        const d = new Date(t.due_date);
        d.setHours(0, 0, 0, 0);
        return d.getTime() < now.getTime();
      }).length;
      const milestonesTotal = milestones.length;
      const milestonesDone = milestones.filter((m: any) => m.status === "done").length;
      const avgCompletion = totalTasks ? tasks.reduce((s: number, t: any) => s + (Number(t.completion_percent) || 0), 0) / totalTasks : milestonesTotal ? milestones.reduce((s: number, m: any) => s + (Number(m.completion_percent) || 0), 0) / milestonesTotal : 0;
      const progress = totalTasks ? (completed / totalTasks) * 100 : milestonesTotal ? (milestonesDone / milestonesTotal) * 100 : 0;

      let health: ComputedRow["health"] = "on-track";
      if (p.status === "completed") health = "completed";
      else if (overdue > 0) health = "overdue";
      else if (p.end_date && new Date(p.end_date).getTime() < now.getTime() + 14 * 24 * 60 * 60 * 1000 && progress < 80) health = "at-risk";

      return {
        id: p.id,
        name: p.name,
        status: p.status,
        totalTasks,
        completed,
        inProgress,
        todo,
        overdue,
        milestonesDone,
        milestonesTotal,
        avgCompletion,
        progress,
        endDate: p.end_date,
        health,
      };
    });
  }, [projects]);

  const filtered = useMemo(() => {
    if (statusFilter === "all") return computed;
    return computed.filter((r) => r.status === statusFilter);
  }, [computed, statusFilter]);

  const totals = useMemo(() => {
    const total = filtered.length;
    const completedP = filtered.filter((r) => r.status === "completed").length;
    const overdueP = filtered.filter((r) => r.health === "overdue").length;
    const atRisk = filtered.filter((r) => r.health === "at-risk").length;
    const totalTasks = filtered.reduce((s, r) => s + r.totalTasks, 0);
    const overdueTasks = filtered.reduce((s, r) => s + r.overdue, 0);
    const avgProgress = total ? filtered.reduce((s, r) => s + r.progress, 0) / total : 0;
    return { total, completedP, overdueP, atRisk, totalTasks, overdueTasks, avgProgress };
  }, [filtered]);

  const getHealthChip = (h: ComputedRow["health"]) => {
    if (h === "completed") return <Chip label="Completed" size="small" color="success" />;
    if (h === "overdue") return <Chip label="Overdue tasks" size="small" color="error" />;
    if (h === "at-risk") return <Chip label="At risk" size="small" color="warning" />;
    return <Chip label="On track" size="small" color="primary" variant="outlined" />;
  };

  const handleExportExcel = () => {
    const cols = [
      { header: "Project", accessor: (r: ComputedRow) => r.name },
      { header: "Status", accessor: (r: ComputedRow) => r.status },
      { header: "Health", accessor: (r: ComputedRow) => r.health },
      { header: "Total Tasks", accessor: (r: ComputedRow) => r.totalTasks },
      { header: "Completed", accessor: (r: ComputedRow) => r.completed },
      { header: "In Progress", accessor: (r: ComputedRow) => r.inProgress },
      { header: "Overdue", accessor: (r: ComputedRow) => r.overdue },
      { header: "Milestones (done/total)", accessor: (r: ComputedRow) => `${r.milestonesDone}/${r.milestonesTotal}` },
      { header: "Avg Completion %", accessor: (r: ComputedRow) => r.avgCompletion.toFixed(1) },
      { header: "Progress % (done/total)", accessor: (r: ComputedRow) => r.progress.toFixed(1) },
      { header: "End Date", accessor: (r: ComputedRow) => (r.endDate ? new Date(r.endDate).toLocaleDateString() : "-") },
    ];
    exportReportToExcel(`pmo-project-status-${new Date().toISOString().slice(0, 10)}`, "Project Status", cols as any, filtered);
  };

  const handleExportPdf = () => {
    const cols = [
      { header: "Project", accessor: (r: ComputedRow) => r.name },
      { header: "Status", accessor: (r: ComputedRow) => r.status },
      { header: "Health", accessor: (r: ComputedRow) => r.health },
      { header: "Tasks", accessor: (r: ComputedRow) => `${r.completed}/${r.totalTasks}` },
      { header: "Overdue", accessor: (r: ComputedRow) => r.overdue },
      { header: "Completion", accessor: (r: ComputedRow) => `${r.avgCompletion.toFixed(0)}%` },
      { header: "Progress", accessor: (r: ComputedRow) => `${r.progress.toFixed(0)}%` },
      { header: "End", accessor: (r: ComputedRow) => (r.endDate ? new Date(r.endDate).toLocaleDateString() : "-") },
    ];
    exportReportToPdf(
      `pmo-project-status-${new Date().toISOString().slice(0, 10)}.pdf`,
      "Project Status Report",
      cols as any,
      filtered,
      `${totals.total} projects • ${totals.completedP} completed • ${totals.overdueP} with overdue tasks • ${totals.overdueTasks} overdue tasks total • Avg progress ${totals.avgProgress.toFixed(0)}%`
    );
  };

  if (loading)
    return (
      <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}>
        <CircularProgress />
      </Box>
    );

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", mb: 2, gap: 2, flexWrap: "wrap" }}>
        <Box>
          <Typography variant="h5" fontWeight={700} gutterBottom>
            Project Status Report
          </Typography>
          <Typography variant="body2" color="text.secondary" sx={{ maxWidth: 720 }}>
            Task-driven health: <strong>Overdue</strong> = task due_date before today and not <code>done</code>. Progress = done/total tasks (fallback to milestones). Avg
            Completion = mean <code>completion_percent</code> across tasks.
          </Typography>
        </Box>
        <Box sx={{ display: "flex", gap: 1, alignItems: "center", flexWrap: "wrap" }}>
          <TextField select size="small" value={statusFilter} onChange={(e) => setStatusFilter(e.target.value)} sx={{ minWidth: 150 }}>
            <MenuItem value="all">All Statuses</MenuItem>
            <MenuItem value="not_started">Not Started</MenuItem>
            <MenuItem value="in_progress">In Progress</MenuItem>
            <MenuItem value="on_hold">On Hold</MenuItem>
            <MenuItem value="completed">Completed</MenuItem>
            <MenuItem value="cancelled">Cancelled</MenuItem>
          </TextField>
          <Button size="small" variant="outlined" startIcon={<Refresh />} onClick={fetch}>
            Refresh
          </Button>
          <Button size="small" variant="outlined" startIcon={<FileDownload />} onClick={handleExportExcel} disabled={filtered.length === 0}>
            Excel
          </Button>
          <Button size="small" variant="outlined" startIcon={<Download />} onClick={handleExportPdf} disabled={filtered.length === 0}>
            PDF
          </Button>
        </Box>
      </Box>

      {error && (
        <Alert severity="error" sx={{ mb: 2 }}>
          {error}
        </Alert>
      )}

      <Grid container spacing={2} sx={{ mb: 2 }}>
        <Grid item xs={12} sm={6} md={2}>
          <Card variant="outlined">
            <CardContent>
              <Typography variant="caption" color="text.secondary">
                Projects (filtered)
              </Typography>
              <Typography variant="h4" fontWeight={700}>
                {totals.total}
              </Typography>
            </CardContent>
          </Card>
        </Grid>
        <Grid item xs={12} sm={6} md={2}>
          <Card variant="outlined" sx={{ bgcolor: "success.light" }}>
            <CardContent>
              <Typography variant="caption">Completed</Typography>
              <Typography variant="h4" fontWeight={700}>
                {totals.completedP}
              </Typography>
            </CardContent>
          </Card>
        </Grid>
        <Grid item xs={12} sm={6} md={2}>
          <Card variant="outlined" sx={{ bgcolor: totals.overdueP > 0 ? "error.light" : "white" }}>
            <CardContent>
              <Typography variant="caption">With Overdue Tasks</Typography>
              <Typography variant="h4" fontWeight={700}>
                {totals.overdueP}
              </Typography>
            </CardContent>
          </Card>
        </Grid>
        <Grid item xs={12} sm={6} md={2}>
          <Card variant="outlined" sx={{ bgcolor: totals.atRisk > 0 ? "warning.light" : "white" }}>
            <CardContent>
              <Typography variant="caption">At Risk (&lt;80% near end)</Typography>
              <Typography variant="h4" fontWeight={700}>
                {totals.atRisk}
              </Typography>
            </CardContent>
          </Card>
        </Grid>
        <Grid item xs={12} sm={6} md={2}>
          <Card variant="outlined">
            <CardContent>
              <Typography variant="caption" color="text.secondary">
                Overdue Tasks
              </Typography>
              <Typography variant="h4" fontWeight={700}>
                {totals.overdueTasks}
              </Typography>
              <Typography variant="caption">of {totals.totalTasks} total</Typography>
            </CardContent>
          </Card>
        </Grid>
        <Grid item xs={12} sm={6} md={2}>
          <Card variant="outlined">
            <CardContent>
              <Typography variant="caption" color="text.secondary">
                Avg Progress
              </Typography>
              <Typography variant="h4" fontWeight={700}>
                {totals.avgProgress.toFixed(0)}%
              </Typography>
              <LinearProgress variant="determinate" value={totals.avgProgress} sx={{ mt: 1, height: 6 }} />
            </CardContent>
          </Card>
        </Grid>
      </Grid>

      <Card>
        <CardContent sx={{ p: 0 }}>
          <Table>
            <TableHead>
              <TableRow>
                <TableCell>Project</TableCell>
                <TableCell>Status</TableCell>
                <TableCell>Health</TableCell>
                <TableCell align="center">Tasks (done/total)</TableCell>
                <TableCell align="center">Overdue</TableCell>
                <TableCell>Progress</TableCell>
                <TableCell>Completion</TableCell>
                <TableCell>End Date</TableCell>
                <TableCell>Milestones</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {filtered.length === 0 ? (
                <TableRow>
                  <TableCell colSpan={9} sx={{ textAlign: "center", py: 5 }}>
                    <Typography color="text.secondary">No projects for this filter.</Typography>
                  </TableCell>
                </TableRow>
              ) : (
                filtered.map((p) => (
                  <TableRow key={p.id} hover>
                    <TableCell>
                      <Typography fontWeight={600}>{p.name}</Typography>
                      <Typography variant="caption" color="text.secondary" fontFamily="monospace">
                        {p.id.slice(0, 8)}
                      </Typography>
                    </TableCell>
                    <TableCell>
                      <Chip label={p.status} size="small" sx={{ textTransform: "capitalize" }} />
                    </TableCell>
                    <TableCell>{getHealthChip(p.health)}</TableCell>
                    <TableCell align="center">
                      <Typography fontWeight={600}>
                        {p.completed}/{p.totalTasks}
                      </Typography>
                      <Typography variant="caption" color="text.secondary">
                        {p.todo} todo • {p.inProgress} doing
                      </Typography>
                    </TableCell>
                    <TableCell align="center">
                      <Chip label={p.overdue} size="small" color={p.overdue > 0 ? "error" : "default"} />
                    </TableCell>
                    <TableCell sx={{ minWidth: 140 }}>
                      <Box sx={{ display: "flex", alignItems: "center", gap: 1 }}>
                        <LinearProgress variant="determinate" value={p.progress} sx={{ flex: 1, height: 6 }} color={p.overdue > 0 ? "error" : "primary"} />
                        <Typography variant="caption">{p.progress.toFixed(0)}%</Typography>
                      </Box>
                    </TableCell>
                    <TableCell sx={{ minWidth: 140 }}>
                      <Box sx={{ display: "flex", alignItems: "center", gap: 1 }}>
                        <LinearProgress variant="determinate" value={p.avgCompletion} sx={{ flex: 1, height: 6 }} color="success" />
                        <Typography variant="caption">{p.avgCompletion.toFixed(0)}%</Typography>
                      </Box>
                    </TableCell>
                    <TableCell>{p.endDate ? new Date(p.endDate).toLocaleDateString() : "-"}</TableCell>
                    <TableCell>
                      {p.milestonesDone}/{p.milestonesTotal}
                    </TableCell>
                  </TableRow>
                ))
              )}
            </TableBody>
          </Table>
        </CardContent>
      </Card>
    </Box>
  );
}
