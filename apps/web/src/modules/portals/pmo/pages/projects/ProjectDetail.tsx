import { useEffect, useState } from "react";
import { useParams, useNavigate, Link as RouterLink } from "react-router-dom";
import { Box, Card, CardContent, Chip, CircularProgress, Grid, Typography, Table, TableBody, TableCell, TableHead, TableRow, LinearProgress, Button, Breadcrumbs, Link, Alert } from "@mui/material";
import { ArrowBack } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";

interface Project {
  id: string;
  project_no: string;
  name: string;
  status: string;
  budget: number | null;
  currency: string;
  client_name: string | null;
  start_date: string | null;
  end_date: string | null;
  description: string | null;
  pmo_project_categories?: { name: string } | null;
}

interface Task {
  id: string;
  title: string;
  status: string;
  priority: string;
  due_date: string | null;
  pmo_task_types?: { name: string } | null;
}

interface Milestone {
  id: string;
  title: string;
  due_date: string | null;
  completion_percent: number;
  status: string;
}

interface Allocation {
  id: string;
  allocation_percent: number;
  start_date: string | null;
  end_date: string | null;
  status: string | null;
  hr_employees?: { first_name: string; last_name: string } | null;
}

export default function ProjectDetail() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const [project, setProject] = useState<Project | null>(null);
  const [tasks, setTasks] = useState<Task[]>([]);
  const [milestones, setMilestones] = useState<Milestone[]>([]);
  const [allocations, setAllocations] = useState<Allocation[]>([]);
  const [loading, setLoading] = useState(true);
  const [notFound, setNotFound] = useState(false);

  useEffect(() => {
    if (!id) return;
    const fetchAll = async () => {
      setLoading(true);
      const [projectRes, tasksRes, milestonesRes, allocRes] = await Promise.all([
        supabase.from("pmo_projects").select("*, pmo_project_categories(name)").eq("id", id).single(),
        supabase.from("pmo_tasks").select("id, title, status, priority, due_date, pmo_task_types(name)").eq("project_id", id).order("due_date", { ascending: true }),
        supabase.from("pmo_milestones").select("id, title, due_date, completion_percent, status").eq("project_id", id).order("due_date", { ascending: true }),
        supabase.from("pmo_resource_allocations").select("id, allocation_percent, start_date, end_date, status, hr_employees(first_name, last_name)").eq("project_id", id).order("created_at", { ascending: false }),
      ]);

      if (projectRes.error || !projectRes.data) {
        setNotFound(true);
      } else {
        const normalized = {
          ...projectRes.data,
          pmo_project_categories: Array.isArray(projectRes.data.pmo_project_categories) ? projectRes.data.pmo_project_categories[0] ?? null : projectRes.data.pmo_project_categories ?? null,
        };
        setProject(normalized as Project);
      }
      if (tasksRes.data) {
        const normalizedTasks = (tasksRes.data as any[]).map(t => ({ ...t, pmo_task_types: Array.isArray(t.pmo_task_types) ? t.pmo_task_types[0] ?? null : t.pmo_task_types ?? null }));
        setTasks(normalizedTasks as Task[]);
      }
      if (milestonesRes.data) setMilestones(milestonesRes.data as Milestone[]);
      if (allocRes.data) {
        const normalizedAlloc = (allocRes.data as any[]).map(a => ({ ...a, hr_employees: Array.isArray(a.hr_employees) ? a.hr_employees[0] ?? null : a.hr_employees ?? null }));
        setAllocations(normalizedAlloc as Allocation[]);
      }
      setLoading(false);
    };
    fetchAll();
  }, [id]);

  const getStatusColor = (s: string) => {
    if (s === 'in_progress') return 'primary';
    if (s === 'completed' || s === 'done') return 'success';
    if (s === 'on_hold' || s === 'pending') return 'warning';
    if (s === 'cancelled' || s === 'missed') return 'error';
    return 'default';
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  if (notFound || !project) {
    return (
      <Box sx={{ p: 3, maxWidth: 900 }}>
        <Alert severity="error" sx={{ mb: 2 }}>Project not found.</Alert>
        <Button startIcon={<ArrowBack />} onClick={() => navigate("/pmo/projects")}>Back to Projects</Button>
      </Box>
    );
  }

  const taskProgress = tasks.length > 0 ? (tasks.filter(t => t.status === 'done').length / tasks.length) * 100 : 0;

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <Breadcrumbs sx={{ mb: 2 }}>
        <Link component={RouterLink} to="/pmo/projects" underline="hover" color="inherit">Projects</Link>
        <Typography color="text.primary">{project.name}</Typography>
      </Breadcrumbs>

      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", mb: 3 }}>
        <Box>
          <Typography variant="h5" fontWeight={700}>{project.name}</Typography>
          <Typography variant="body2" color="text.secondary" fontFamily="monospace">{project.project_no}</Typography>
        </Box>
        <Chip label={project.status} color={getStatusColor(project.status) as any} sx={{ textTransform: "capitalize" }} />
      </Box>

      <Grid container spacing={2} sx={{ mb: 3 }}>
        <Grid item xs={12} md={7}>
          <Card><CardContent>
            <Typography variant="subtitle2" color="text.secondary" gutterBottom>Project Info</Typography>
            <Grid container spacing={2}>
              <Grid item xs={6}><Typography variant="caption" color="text.secondary">Category</Typography><Typography>{project.pmo_project_categories?.name || "-"}</Typography></Grid>
              <Grid item xs={6}><Typography variant="caption" color="text.secondary">Client</Typography><Typography>{project.client_name || "-"}</Typography></Grid>
              <Grid item xs={6}><Typography variant="caption" color="text.secondary">Start Date</Typography><Typography>{project.start_date ? new Date(project.start_date).toLocaleDateString() : "-"}</Typography></Grid>
              <Grid item xs={6}><Typography variant="caption" color="text.secondary">End Date</Typography><Typography>{project.end_date ? new Date(project.end_date).toLocaleDateString() : "-"}</Typography></Grid>
              <Grid item xs={12}><Typography variant="caption" color="text.secondary">Description</Typography><Typography variant="body2">{project.description || "-"}</Typography></Grid>
            </Grid>
          </CardContent></Card>
        </Grid>
        <Grid item xs={12} md={5}>
          <Card sx={{ height: "100%" }}><CardContent>
            <Typography variant="subtitle2" color="text.secondary" gutterBottom>Budget</Typography>
            <Typography variant="h5" fontWeight={700}>{project.budget ? `${project.currency} ${Number(project.budget).toLocaleString()}` : "-"}</Typography>
            <Box sx={{ mt: 2 }}>
              <Typography variant="caption" color="text.secondary">Task Completion</Typography>
              <Box sx={{ display: "flex", alignItems: "center", gap: 1, mt: 0.5 }}>
                <LinearProgress variant="determinate" value={taskProgress} sx={{ flex: 1, height: 6 }} />
                <Typography variant="caption">{taskProgress.toFixed(0)}%</Typography>
              </Box>
            </Box>
          </CardContent></Card>
        </Grid>
      </Grid>

      <Typography variant="subtitle1" fontWeight={700} sx={{ mb: 1 }}>Tasks ({tasks.length})</Typography>
      <Card sx={{ mb: 3 }}><CardContent sx={{ p: 0 }}>
        <Table><TableHead><TableRow><TableCell>Title</TableCell><TableCell>Type</TableCell><TableCell>Status</TableCell><TableCell>Priority</TableCell><TableCell>Due Date</TableCell></TableRow></TableHead>
        <TableBody>{tasks.length === 0 ? <TableRow><TableCell colSpan={5} sx={{ textAlign: "center", py: 3 }}><Typography color="text.secondary">No tasks for this project yet.</Typography></TableCell></TableRow> : tasks.map(t => <TableRow key={t.id} hover><TableCell>{t.title}</TableCell><TableCell>{t.pmo_task_types?.name || "-"}</TableCell><TableCell><Chip label={t.status} size="small" color={getStatusColor(t.status) as any} sx={{ textTransform: "capitalize" }} /></TableCell><TableCell sx={{ textTransform: "capitalize" }}>{t.priority}</TableCell><TableCell>{t.due_date ? new Date(t.due_date).toLocaleDateString() : "-"}</TableCell></TableRow>)}</TableBody></Table>
      </CardContent></Card>

      <Typography variant="subtitle1" fontWeight={700} sx={{ mb: 1 }}>Milestones ({milestones.length})</Typography>
      <Card sx={{ mb: 3 }}><CardContent sx={{ p: 0 }}>
        <Table><TableHead><TableRow><TableCell>Milestone</TableCell><TableCell>Due Date</TableCell><TableCell>Completion</TableCell><TableCell>Status</TableCell></TableRow></TableHead>
        <TableBody>{milestones.length === 0 ? <TableRow><TableCell colSpan={4} sx={{ textAlign: "center", py: 3 }}><Typography color="text.secondary">No milestones for this project yet.</Typography></TableCell></TableRow> : milestones.map(m => <TableRow key={m.id} hover><TableCell>{m.title}</TableCell><TableCell>{m.due_date ? new Date(m.due_date).toLocaleDateString() : "-"}</TableCell><TableCell><Box sx={{ display: "flex", alignItems: "center", gap: 1, minWidth: 120 }}><LinearProgress variant="determinate" value={m.completion_percent || 0} sx={{ flex: 1, height: 6 }} /><Typography variant="caption">{m.completion_percent || 0}%</Typography></Box></TableCell><TableCell><Chip label={m.status} size="small" color={getStatusColor(m.status) as any} sx={{ textTransform: "capitalize" }} /></TableCell></TableRow>)}</TableBody></Table>
      </CardContent></Card>

      <Typography variant="subtitle1" fontWeight={700} sx={{ mb: 1 }}>Resource Allocation ({allocations.length})</Typography>
      <Card><CardContent sx={{ p: 0 }}>
        <Table><TableHead><TableRow><TableCell>Employee</TableCell><TableCell>Allocation %</TableCell><TableCell>Start</TableCell><TableCell>End</TableCell><TableCell>Status</TableCell></TableRow></TableHead>
        <TableBody>{allocations.length === 0 ? <TableRow><TableCell colSpan={5} sx={{ textAlign: "center", py: 3 }}><Typography color="text.secondary">No one allocated to this project yet.</Typography></TableCell></TableRow> : allocations.map(a => <TableRow key={a.id} hover><TableCell>{a.hr_employees ? `${a.hr_employees.first_name} ${a.hr_employees.last_name}` : "-"}</TableCell><TableCell><Chip label={`${a.allocation_percent}%`} size="small" color={a.allocation_percent > 100 ? "error" : a.allocation_percent > 80 ? "warning" : "success"} /></TableCell><TableCell>{a.start_date ? new Date(a.start_date).toLocaleDateString() : "-"}</TableCell><TableCell>{a.end_date ? new Date(a.end_date).toLocaleDateString() : "-"}</TableCell><TableCell><Chip label={a.status || "active"} size="small" variant="outlined" sx={{ textTransform: "capitalize" }} /></TableCell></TableRow>)}</TableBody></Table>
      </CardContent></Card>
    </Box>
  );
}