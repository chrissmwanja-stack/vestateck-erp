import { useEffect, useState } from "react";
import { useParams, useNavigate, Link as RouterLink } from "react-router-dom";
import {
  Box,
  Card,
  CardContent,
  Chip,
  CircularProgress,
  Grid,
  Typography,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableRow,
  LinearProgress,
  Button,
  Breadcrumbs,
  Link,
  Alert,
  IconButton,
  Tooltip,
  Dialog,
  DialogTitle,
  DialogContent,
  DialogActions,
  TextField,
  MenuItem,
  InputAdornment,
} from "@mui/material";
import { ArrowBack, Edit, Delete, Add } from "@mui/icons-material";
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
  category_id: string | null;
  pmo_project_categories?: { name: string } | null;
}

interface Task {
  id: string;
  title: string;
  status: string;
  priority: string;
  due_date: string | null;
  completion_percent: number;
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

  // edit project dialog
  const [editOpen, setEditOpen] = useState(false);
  const [editSaving, setEditSaving] = useState(false);
  const [editError, setEditError] = useState<string | null>(null);
  const [categories, setCategories] = useState<{ id: string; name: string }[]>([]);
  const [editForm, setEditForm] = useState({ name: "", category_id: "", client_name: "", status: "not_started", budget: "", currency: "UGX", start_date: "", end_date: "", description: "" });

  // allocation dialog (create from detail)
  const [allocOpen, setAllocOpen] = useState(false);
  const [allocEmployees, setAllocEmployees] = useState<{ id: string; first_name: string; last_name: string }[]>([]);
  const [allocForm, setAllocForm] = useState({ employee_id: "", allocation_percent: 100, start_date: "", end_date: "", status: "active" });
  const [allocSaving, setAllocSaving] = useState(false);
  const [allocError, setAllocError] = useState<string | null>(null);

  const fetchAll = async () => {
    if (!id) return;
    setLoading(true);
    const [projectRes, tasksRes, milestonesRes, allocRes, catRes, empRes] = await Promise.all([
      supabase.from("pmo_projects").select("*, pmo_project_categories(name)").eq("id", id).single(),
      supabase.from("pmo_tasks").select("id, title, status, priority, due_date, completion_percent, pmo_task_types(name)").eq("project_id", id).order("due_date", { ascending: true }),
      supabase.from("pmo_milestones").select("id, title, due_date, completion_percent, status").eq("project_id", id).order("due_date", { ascending: true }),
      supabase.from("pmo_resource_allocations").select("id, allocation_percent, start_date, end_date, status, hr_employees(first_name, last_name)").eq("project_id", id).order("created_at", { ascending: false }),
      supabase.from("pmo_project_categories").select("id, name").eq("is_active", true).order("name"),
      supabase.from("hr_employees").select("id, first_name, last_name").eq("is_active", true).order("first_name").limit(100),
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
      const normalizedTasks = (tasksRes.data as any[]).map((t) => ({ ...t, pmo_task_types: Array.isArray(t.pmo_task_types) ? t.pmo_task_types[0] ?? null : t.pmo_task_types ?? null }));
      setTasks(normalizedTasks as Task[]);
    }
    if (milestonesRes.data) setMilestones(milestonesRes.data as Milestone[]);
    if (allocRes.data) {
      const normalizedAlloc = (allocRes.data as any[]).map((a) => ({ ...a, hr_employees: Array.isArray(a.hr_employees) ? a.hr_employees[0] ?? null : a.hr_employees ?? null }));
      setAllocations(normalizedAlloc as Allocation[]);
    }
    if (catRes.data) setCategories(catRes.data as any[]);
    if (empRes.data) setAllocEmployees(empRes.data as any[]);
    setLoading(false);
  };

  useEffect(() => {
    fetchAll();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id]);

  const getStatusColor = (s: string) => {
    if (s === "in_progress") return "primary";
    if (s === "completed" || s === "done") return "success";
    if (s === "on_hold" || s === "pending") return "warning";
    if (s === "cancelled" || s === "missed") return "error";
    return "default";
  };

  const openEdit = () => {
    if (!project) return;
    setEditForm({
      name: project.name || "",
      category_id: project.category_id || "",
      client_name: project.client_name || "",
      status: project.status || "not_started",
      budget: project.budget != null ? String(project.budget) : "",
      currency: project.currency || "UGX",
      start_date: project.start_date || "",
      end_date: project.end_date || "",
      description: project.description || "",
    });
    setEditError(null);
    setEditOpen(true);
  };

  const handleEditSave = async () => {
    if (!project || !id) return;
    if (!editForm.name.trim()) { setEditError("Project name is required."); return; }
    if (editForm.start_date && editForm.end_date && editForm.start_date > editForm.end_date) { setEditError("Start date cannot be after end date."); return; }
    setEditSaving(true);
    setEditError(null);
    const payload: any = {
      name: editForm.name.trim(),
      category_id: editForm.category_id || null,
      client_name: editForm.client_name.trim() || null,
      status: editForm.status,
      budget: editForm.budget ? parseFloat(editForm.budget) : null,
      currency: editForm.currency,
      start_date: editForm.start_date || null,
      end_date: editForm.end_date || null,
      description: editForm.description.trim() || null,
    };
    const { error } = await supabase.from("pmo_projects").update(payload).eq("id", id);
    setEditSaving(false);
    if (error) { setEditError(error.message); return; }
    setEditOpen(false);
    fetchAll();
  };

  const handleDeleteAllocation = async (allocId: string) => {
    if (!window.confirm("Remove this allocation?")) return;
    const { error } = await supabase.from("pmo_resource_allocations").delete().eq("id", allocId);
    if (error) { alert(error.message); return; }
    setAllocations((prev) => prev.filter((a) => a.id !== allocId));
  };

  const openAllocCreate = () => {
    setAllocForm({ employee_id: "", allocation_percent: 100, start_date: "", end_date: "", status: "active" });
    setAllocError(null);
    setAllocOpen(true);
  };

  const handleAllocSave = async () => {
    if (!id) return;
    if (!allocForm.employee_id) { setAllocError("Select an employee."); return; }
    const pct = Number(allocForm.allocation_percent);
    if (Number.isNaN(pct) || pct < 0 || pct > 200) { setAllocError("Allocation % must be 0-200."); return; }
    setAllocSaving(true);
    setAllocError(null);
    // tenant_id via existing project or dummy
    const { data: projTenant } = await supabase.from("pmo_projects").select("tenant_id").eq("id", id).single();
    const tenant_id = (projTenant as any)?.tenant_id;
    const payload: any = {
      project_id: id,
      employee_id: allocForm.employee_id,
      allocation_percent: pct,
      start_date: allocForm.start_date || null,
      end_date: allocForm.end_date || null,
      status: allocForm.status,
    };
    if (tenant_id) payload.tenant_id = tenant_id;
    const { error } = await supabase.from("pmo_resource_allocations").insert(payload);
    setAllocSaving(false);
    if (error) { setAllocError(error.message); return; }
    setAllocOpen(false);
    fetchAll();
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

  const taskProgress = tasks.length > 0 ? (tasks.filter((t) => t.status === "done").length / tasks.length) * 100 : 0;

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <Breadcrumbs sx={{ mb: 2 }}>
        <Link component={RouterLink} to="/pmo/projects" underline="hover" color="inherit">Projects</Link>
        <Typography color="text.primary">{project.name}</Typography>
      </Breadcrumbs>

      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", mb: 3, gap: 2 }}>
        <Box>
          <Typography variant="h5" fontWeight={700}>{project.name}</Typography>
          <Typography variant="body2" color="text.secondary" fontFamily="monospace">{project.project_no}</Typography>
        </Box>
        <Box sx={{ display: "flex", gap: 1, alignItems: "center" }}>
          <Chip label={project.status} color={getStatusColor(project.status) as any} sx={{ textTransform: "capitalize" }} />
          <Button variant="outlined" startIcon={<Edit />} onClick={openEdit}>Edit Project</Button>
          <Button variant="outlined" startIcon={<ArrowBack />} onClick={() => navigate("/pmo/projects")}>Back</Button>
        </Box>
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
              <Typography variant="caption" color="text.secondary">Task Completion (done / total)</Typography>
              <Box sx={{ display: "flex", alignItems: "center", gap: 1, mt: 0.5 }}>
                <LinearProgress variant="determinate" value={taskProgress} sx={{ flex: 1, height: 6 }} />
                <Typography variant="caption">{taskProgress.toFixed(0)}%</Typography>
              </Box>
            </Box>
          </CardContent></Card>
        </Grid>
      </Grid>

      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 1 }}>
        <Typography variant="subtitle1" fontWeight={700}>Tasks ({tasks.length})</Typography>
        <Button size="small" onClick={() => navigate("/pmo/tasks")} sx={{ textTransform: "none" }}>Manage in Tasks List →</Button>
      </Box>
      <Card sx={{ mb: 3 }}><CardContent sx={{ p: 0 }}>
        <Table><TableHead><TableRow><TableCell>Title</TableCell><TableCell>Type</TableCell><TableCell>Status</TableCell><TableCell>Priority</TableCell><TableCell>Progress</TableCell><TableCell>Due Date</TableCell></TableRow></TableHead>
        <TableBody>{tasks.length === 0 ? <TableRow><TableCell colSpan={6} sx={{ textAlign: "center", py: 3 }}><Typography color="text.secondary">No tasks for this project yet. Create in Tasks List with this project selected.</Typography></TableCell></TableRow> : tasks.map((t) => <TableRow key={t.id} hover><TableCell>{t.title}</TableCell><TableCell>{t.pmo_task_types?.name || "-"}</TableCell><TableCell><Chip label={t.status} size="small" color={getStatusColor(t.status) as any} sx={{ textTransform: "capitalize" }} /></TableCell><TableCell sx={{ textTransform: "capitalize" }}>{t.priority}</TableCell><TableCell><Box sx={{ display: "flex", alignItems: "center", gap: 1, minWidth: 120 }}><LinearProgress variant="determinate" value={t.completion_percent || 0} sx={{ flex: 1, height: 6 }} /><Typography variant="caption">{t.completion_percent || 0}%</Typography></Box></TableCell><TableCell>{t.due_date ? new Date(t.due_date).toLocaleDateString() : "-"}</TableCell></TableRow>)}</TableBody></Table>
      </CardContent></Card>

      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 1 }}>
        <Typography variant="subtitle1" fontWeight={700}>Milestones ({milestones.length})</Typography>
        <Button size="small" onClick={() => navigate("/pmo/milestones")} sx={{ textTransform: "none" }}>Manage Milestones →</Button>
      </Box>
      <Card sx={{ mb: 3 }}><CardContent sx={{ p: 0 }}>
        <Table><TableHead><TableRow><TableCell>Milestone</TableCell><TableCell>Due Date</TableCell><TableCell>Completion</TableCell><TableCell>Status</TableCell></TableRow></TableHead>
        <TableBody>{milestones.length === 0 ? <TableRow><TableCell colSpan={4} sx={{ textAlign: "center", py: 3 }}><Typography color="text.secondary">No milestones for this project yet.</Typography></TableCell></TableRow> : milestones.map((m) => <TableRow key={m.id} hover><TableCell>{m.title}</TableCell><TableCell>{m.due_date ? new Date(m.due_date).toLocaleDateString() : "-"}</TableCell><TableCell><Box sx={{ display: "flex", alignItems: "center", gap: 1, minWidth: 120 }}><LinearProgress variant="determinate" value={m.completion_percent || 0} sx={{ flex: 1, height: 6 }} /><Typography variant="caption">{m.completion_percent || 0}%</Typography></Box></TableCell><TableCell><Chip label={m.status} size="small" color={getStatusColor(m.status) as any} sx={{ textTransform: "capitalize" }} /></TableCell></TableRow>)}</TableBody></Table>
      </CardContent></Card>

      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 1 }}>
        <Typography variant="subtitle1" fontWeight={700}>Resource Allocation ({allocations.length})</Typography>
        <Button size="small" variant="outlined" startIcon={<Add />} onClick={openAllocCreate}>Add Allocation</Button>
      </Box>
      <Card><CardContent sx={{ p: 0 }}>
        <Table><TableHead><TableRow><TableCell>Employee</TableCell><TableCell>Allocation %</TableCell><TableCell>Start</TableCell><TableCell>End</TableCell><TableCell>Status</TableCell><TableCell align="right">Actions</TableCell></TableRow></TableHead>
        <TableBody>{allocations.length === 0 ? <TableRow><TableCell colSpan={6} sx={{ textAlign: "center", py: 3 }}><Typography color="text.secondary">No one allocated to this project yet. Click Add Allocation.</Typography></TableCell></TableRow> : allocations.map((a) => <TableRow key={a.id} hover><TableCell>{a.hr_employees ? `${a.hr_employees.first_name} ${a.hr_employees.last_name}` : "-"}</TableCell><TableCell><Chip label={`${a.allocation_percent}%`} size="small" color={a.allocation_percent > 100 ? "error" : a.allocation_percent > 80 ? "warning" : "success"} /></TableCell><TableCell>{a.start_date ? new Date(a.start_date).toLocaleDateString() : "-"}</TableCell><TableCell>{a.end_date ? new Date(a.end_date).toLocaleDateString() : "-"}</TableCell><TableCell><Chip label={a.status || "active"} size="small" variant="outlined" sx={{ textTransform: "capitalize" }} /></TableCell><TableCell align="right"><Tooltip title="Remove"><IconButton size="small" aria-label="Delete allocation" onClick={() => handleDeleteAllocation(a.id)}><Delete fontSize="small" /></IconButton></Tooltip></TableCell></TableRow>)}</TableBody></Table>
      </CardContent></Card>

      {/* Edit Project Dialog */}
      <Dialog open={editOpen} onClose={() => !editSaving && setEditOpen(false)} maxWidth="md" fullWidth>
        <DialogTitle>Edit Project</DialogTitle>
        <DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}>
          {editError && <Alert severity="error">{editError}</Alert>}
          <TextField label="Project Name *" value={editForm.name} onChange={(e) => setEditForm({ ...editForm, name: e.target.value })} fullWidth required />
          <Grid container spacing={2}>
            <Grid item xs={12} sm={6}>
              <TextField select label="Category" value={editForm.category_id} onChange={(e) => setEditForm({ ...editForm, category_id: e.target.value })} fullWidth>
                <MenuItem value="">-- None --</MenuItem>
                {categories.map((c) => <MenuItem key={c.id} value={c.id}>{c.name}</MenuItem>)}
              </TextField>
            </Grid>
            <Grid item xs={12} sm={6}><TextField label="Client Name" value={editForm.client_name} onChange={(e) => setEditForm({ ...editForm, client_name: e.target.value })} fullWidth /></Grid>
            <Grid item xs={12} sm={4}>
              <TextField select label="Status" value={editForm.status} onChange={(e) => setEditForm({ ...editForm, status: e.target.value })} fullWidth>
                <MenuItem value="not_started">Not Started</MenuItem>
                <MenuItem value="in_progress">In Progress</MenuItem>
                <MenuItem value="on_hold">On Hold</MenuItem>
                <MenuItem value="completed">Completed</MenuItem>
                <MenuItem value="cancelled">Cancelled</MenuItem>
              </TextField>
            </Grid>
            <Grid item xs={12} sm={4}>
              <TextField label="Budget" type="number" value={editForm.budget} onChange={(e) => setEditForm({ ...editForm, budget: e.target.value })} fullWidth InputProps={{ startAdornment: <InputAdornment position="start">{editForm.currency}</InputAdornment> }} />
            </Grid>
            <Grid item xs={12} sm={4}>
              <TextField select label="Currency" value={editForm.currency} onChange={(e) => setEditForm({ ...editForm, currency: e.target.value })} fullWidth>
                <MenuItem value="UGX">UGX</MenuItem><MenuItem value="USD">USD</MenuItem><MenuItem value="EUR">EUR</MenuItem>
              </TextField>
            </Grid>
            <Grid item xs={12} sm={6}><TextField label="Start Date" type="date" value={editForm.start_date} onChange={(e) => setEditForm({ ...editForm, start_date: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} /></Grid>
            <Grid item xs={12} sm={6}><TextField label="End Date" type="date" value={editForm.end_date} onChange={(e) => setEditForm({ ...editForm, end_date: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} /></Grid>
            <Grid item xs={12}><TextField label="Description" value={editForm.description} onChange={(e) => setEditForm({ ...editForm, description: e.target.value })} fullWidth multiline rows={3} /></Grid>
          </Grid>
          <Typography variant="caption" color="text.secondary">Project No {project.project_no} cannot be changed (auto via trigger).</Typography>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setEditOpen(false)} disabled={editSaving}>Cancel</Button>
          <Button variant="contained" onClick={handleEditSave} disabled={editSaving}>{editSaving ? "Saving..." : "Update"}</Button>
        </DialogActions>
      </Dialog>

      {/* Add Allocation Dialog */}
      <Dialog open={allocOpen} onClose={() => !allocSaving && setAllocOpen(false)} maxWidth="sm" fullWidth>
        <DialogTitle>Add Allocation to {project.name}</DialogTitle>
        <DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}>
          {allocError && <Alert severity="error">{allocError}</Alert>}
          <TextField select label="Employee *" value={allocForm.employee_id} onChange={(e) => setAllocForm({ ...allocForm, employee_id: e.target.value })} fullWidth required>
            <MenuItem value="">-- Select Employee --</MenuItem>
            {allocEmployees.map((emp) => <MenuItem key={emp.id} value={emp.id}>{emp.first_name} {emp.last_name}</MenuItem>)}
          </TextField>
          <Grid container spacing={2}>
            <Grid item xs={6}><TextField label="Allocation %" type="number" value={allocForm.allocation_percent} onChange={(e) => setAllocForm({ ...allocForm, allocation_percent: parseInt(e.target.value) || 0 })} fullWidth InputProps={{ inputProps: { min: 0, max: 200 } }} /></Grid>
            <Grid item xs={6}><TextField select label="Status" value={allocForm.status} onChange={(e) => setAllocForm({ ...allocForm, status: e.target.value })} fullWidth><MenuItem value="active">Active</MenuItem><MenuItem value="planned">Planned</MenuItem><MenuItem value="completed">Completed</MenuItem></TextField></Grid>
            <Grid item xs={6}><TextField label="Start Date" type="date" value={allocForm.start_date} onChange={(e) => setAllocForm({ ...allocForm, start_date: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} /></Grid>
            <Grid item xs={6}><TextField label="End Date" type="date" value={allocForm.end_date} onChange={(e) => setAllocForm({ ...allocForm, end_date: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} /></Grid>
          </Grid>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setAllocOpen(false)} disabled={allocSaving}>Cancel</Button>
          <Button variant="contained" onClick={handleAllocSave} disabled={!allocForm.employee_id || allocSaving}>{allocSaving ? "Saving..." : "Add"}</Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}
