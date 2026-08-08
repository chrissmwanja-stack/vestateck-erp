import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, Typography, TextField, MenuItem, Dialog, DialogActions, DialogContent, DialogTitle, Grid, Alert } from "@mui/material";
import { Add } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { useAuth } from "../../../../../lib/authContext";

interface Task {
  id: string;
  title: string;
  status: string;
  priority: string;
  due_date: string | null;
  created_at: string;
  projects?: { name: string } | null;
  task_types?: { name: string } | null;
}
interface Project { id: string; name: string; }
interface TaskType { id: string; name: string; }

export default function TasksList() {
  const { session } = useAuth();
  const [tasks, setTasks] = useState<Task[]>([]);
  const [projects, setProjects] = useState<Project[]>([]);
  const [taskTypes, setTaskTypes] = useState<TaskType[]>([]);
  const [loading, setLoading] = useState(true);
  const [statusFilter, setStatusFilter] = useState("all");
  const [open, setOpen] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [form, setForm] = useState({ project_id: "", title: "", type_id: "", status: "todo", priority: "medium", start_date: "", due_date: "" });

  const fetchTasks = async () => {
    setLoading(true);
    let query = supabase.from("pmo_tasks").select("*, projects:pmo_projects(name), task_types:pmo_task_types(name)").order("created_at", { ascending: false });
    if (statusFilter !== "all") query = query.eq("status", statusFilter);
    const { data } = await query;
    if (data) setTasks(data as Task[]);
    setLoading(false);
  };

  const fetchLookups = async () => {
    const [projRes, typesRes] = await Promise.all([
      supabase.from("pmo_projects").select("id, name").order("name"),
      supabase.from("pmo_task_types").select("id, name").eq("is_active", true).order("name"),
    ]);
    if (projRes.data) setProjects(projRes.data as Project[]);
    if (typesRes.data) setTaskTypes(typesRes.data as TaskType[]);
  };

  useEffect(() => { fetchTasks(); }, [statusFilter]);
  useEffect(() => { fetchLookups(); }, []);

  const getStatusColor = (s: string) => {
    if (s === 'done') return 'success';
    if (s === 'in_progress') return 'primary';
    if (s === 'review') return 'warning';
    return 'default';
  };

  const getPriorityColor = (p: string) => {
    if (p === 'critical') return 'error';
    if (p === 'high') return 'warning';
    if (p === 'medium') return 'info';
    return 'default';
  };

  const resetForm = () => setForm({ project_id: "", title: "", type_id: "", status: "todo", priority: "medium", start_date: "", due_date: "" });

  const handleSave = async () => {
    setError(null);
    if (!form.project_id) { setError("Select a project."); return; }
    if (!form.title.trim()) { setError("Task title is required."); return; }
    setSaving(true);

    // tenant_id has no direct column on the form -- read it off the
    // parent project (same tenant scoping used by ResourceAllocation.tsx),
    // and default assignee_id to the signed-in user like other module forms.
    const { data: projectRow } = await supabase.from("pmo_projects").select("tenant_id").eq("id", form.project_id).single();

    const payload: any = {
      project_id: form.project_id,
      title: form.title.trim(),
      type_id: form.type_id || null,
      status: form.status,
      priority: form.priority,
      start_date: form.start_date || null,
      due_date: form.due_date || null,
      assignee_id: session?.user?.id || null,
    };
    if (projectRow?.tenant_id) payload.tenant_id = projectRow.tenant_id;

    const { error: insertError } = await supabase.from("pmo_tasks").insert(payload);
    setSaving(false);
    if (insertError) {
      setError(insertError.message);
      return;
    }
    setOpen(false);
    resetForm();
    fetchTasks();
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 2 }}>
        <Box><Typography variant="h5" fontWeight={700}>Tasks</Typography><Typography variant="body2" color="text.secondary">{tasks.length} tasks across projects</Typography></Box>
        <Button variant="contained" startIcon={<Add />} onClick={() => { setError(null); setOpen(true); }}>New Task</Button>
      </Box>

      <Card sx={{ mb: 2 }}>
        <CardContent sx={{ display: "flex", gap: 2 }}>
          <TextField select label="Status" value={statusFilter} onChange={e => setStatusFilter(e.target.value)} size="small" sx={{ minWidth: 180 }}>
            <MenuItem value="all">All Statuses</MenuItem>
            <MenuItem value="todo">To Do</MenuItem>
            <MenuItem value="in_progress">In Progress</MenuItem>
            <MenuItem value="review">Review</MenuItem>
            <MenuItem value="done">Done</MenuItem>
          </TextField>
        </CardContent>
      </Card>

      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Title</TableCell><TableCell>Project</TableCell><TableCell>Type</TableCell><TableCell>Status</TableCell><TableCell>Priority</TableCell><TableCell>Due Date</TableCell></TableRow></TableHead><TableBody>{tasks.length === 0 ? <TableRow><TableCell colSpan={6} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No tasks yet. Create tasks linked to projects.</Typography></TableCell></TableRow> : tasks.map(t => <TableRow key={t.id} hover><TableCell><Typography fontWeight={600}>{t.title}</Typography></TableCell><TableCell>{t.projects?.name || "-"}</TableCell><TableCell>{t.task_types?.name || "-"}</TableCell><TableCell><Chip label={t.status} size="small" color={getStatusColor(t.status) as any} sx={{ textTransform: "capitalize" }} /></TableCell><TableCell><Chip label={t.priority} size="small" color={getPriorityColor(t.priority) as any} sx={{ textTransform: "capitalize" }} /></TableCell><TableCell>{t.due_date ? new Date(t.due_date).toLocaleDateString() : "-"}</TableCell></TableRow>)}</TableBody></Table></CardContent></Card>

      <Dialog open={open} onClose={() => setOpen(false)} maxWidth="sm" fullWidth>
        <DialogTitle>New Task</DialogTitle>
        <DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}>
          {error && <Alert severity="error">{error}</Alert>}
          <TextField select label="Project *" value={form.project_id} onChange={e => setForm({ ...form, project_id: e.target.value })} fullWidth required>
            <MenuItem value="">-- Select Project --</MenuItem>
            {projects.map(p => <MenuItem key={p.id} value={p.id}>{p.name}</MenuItem>)}
          </TextField>
          <TextField label="Title *" value={form.title} onChange={e => setForm({ ...form, title: e.target.value })} fullWidth autoFocus required placeholder="e.g. Draft foundation drawings" />
          <TextField select label="Task Type" value={form.type_id} onChange={e => setForm({ ...form, type_id: e.target.value })} fullWidth>
            <MenuItem value="">-- None --</MenuItem>
            {taskTypes.map(t => <MenuItem key={t.id} value={t.id}>{t.name}</MenuItem>)}
          </TextField>
          <Grid container spacing={2}>
            <Grid item xs={6}>
              <TextField select label="Status" value={form.status} onChange={e => setForm({ ...form, status: e.target.value })} fullWidth>
                <MenuItem value="todo">To Do</MenuItem>
                <MenuItem value="in_progress">In Progress</MenuItem>
                <MenuItem value="review">Review</MenuItem>
                <MenuItem value="done">Done</MenuItem>
              </TextField>
            </Grid>
            <Grid item xs={6}>
              <TextField select label="Priority" value={form.priority} onChange={e => setForm({ ...form, priority: e.target.value })} fullWidth>
                <MenuItem value="low">Low</MenuItem>
                <MenuItem value="medium">Medium</MenuItem>
                <MenuItem value="high">High</MenuItem>
                <MenuItem value="critical">Critical</MenuItem>
              </TextField>
            </Grid>
          </Grid>
          <Grid container spacing={2}>
            <Grid item xs={6}>
              <TextField label="Start Date" type="date" value={form.start_date} onChange={e => setForm({ ...form, start_date: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} />
            </Grid>
            <Grid item xs={6}>
              <TextField label="Due Date" type="date" value={form.due_date} onChange={e => setForm({ ...form, due_date: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} />
            </Grid>
          </Grid>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setOpen(false)}>Cancel</Button>
          <Button variant="contained" onClick={handleSave} disabled={saving || !form.project_id || !form.title.trim()}>{saving ? "Saving..." : "Create"}</Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}