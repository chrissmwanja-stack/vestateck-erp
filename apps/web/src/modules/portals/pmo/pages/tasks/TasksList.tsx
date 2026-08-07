import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, Typography, TextField, MenuItem } from "@mui/material";
import { Add } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";

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

export default function TasksList() {
  const [tasks, setTasks] = useState<Task[]>([]);
  const [loading, setLoading] = useState(true);
  const [statusFilter, setStatusFilter] = useState("all");

  const fetchTasks = async () => {
    setLoading(true);
    let query = supabase.from("pmo_tasks").select("*, projects:pmo_projects(name), task_types:pmo_task_types(name)").order("created_at", { ascending: false });
    if (statusFilter !== "all") query = query.eq("status", statusFilter);
    const { data } = await query;
    if (data) setTasks(data as Task[]);
    setLoading(false);
  };

  useEffect(() => { fetchTasks(); }, [statusFilter]);

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

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 2 }}>
        <Box><Typography variant="h5" fontWeight={700}>Tasks</Typography><Typography variant="body2" color="text.secondary">{tasks.length} tasks across projects</Typography></Box>
        <Button variant="contained" startIcon={<Add />} disabled>New Task</Button>
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

      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Title</TableCell><TableCell>Project</TableCell><TableCell>Type</TableCell><TableCell>Status</TableCell><TableCell>Priority</TableCell><TableCell>Due Date</TableCell></TableRow></TableHead><TableBody>{tasks.length === 0 ? <TableRow><TableCell colSpan={6} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No tasks yet. Create tasks linked to projects. Needs pmo_tasks table (project_id, title, status, priority).</Typography></TableCell></TableRow> : tasks.map(t => <TableRow key={t.id} hover><TableCell><Typography fontWeight={600}>{t.title}</Typography></TableCell><TableCell>{t.projects?.name || "-"}</TableCell><TableCell>{t.task_types?.name || "-"}</TableCell><TableCell><Chip label={t.status} size="small" color={getStatusColor(t.status) as any} sx={{ textTransform: "capitalize" }} /></TableCell><TableCell><Chip label={t.priority} size="small" color={getPriorityColor(t.priority) as any} sx={{ textTransform: "capitalize" }} /></TableCell><TableCell>{t.due_date ? new Date(t.due_date).toLocaleDateString() : "-"}</TableCell></TableRow>)}</TableBody></Table></CardContent></Card>
    </Box>
  );
}
