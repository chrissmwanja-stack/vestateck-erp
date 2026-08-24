import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, Typography, LinearProgress, TextField, MenuItem, Dialog, DialogActions, DialogContent, DialogTitle, Grid, Alert } from "@mui/material";
import { Add } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";

interface Milestone {
  id: string;
  title: string;
  due_date: string | null;
  completion_percent: number;
  status: string;
  pmo_projects?: { name: string } | null;
}
interface Project { id: string; name: string; }

export default function MilestonesList() {
  const [milestones, setMilestones] = useState<Milestone[]>([]);
  const [projects, setProjects] = useState<Project[]>([]);
  const [loading, setLoading] = useState(true);
  const [open, setOpen] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [form, setForm] = useState({ project_id: "", title: "", status: "pending", due_date: "", completion_percent: "0" });

  const fetchMilestones = async () => {
    setLoading(true);
    const { data } = await supabase.from("pmo_milestones").select("*, pmo_projects(name)").order("due_date", { ascending: true });
    if (data) setMilestones(data as Milestone[]);
    setLoading(false);
  };

  const fetchProjects = async () => {
    const { data } = await supabase.from("pmo_projects").select("id, name").order("name");
    if (data) setProjects(data as Project[]);
  };

  useEffect(() => { fetchMilestones(); fetchProjects(); }, []);

  const resetForm = () => setForm({ project_id: "", title: "", status: "pending", due_date: "", completion_percent: "0" });

  const handleSave = async () => {
    setError(null);
    if (!form.project_id) { setError("Select a project."); return; }
    if (!form.title.trim()) { setError("Milestone title is required."); return; }
    setSaving(true);

    // tenant_id has no direct column on the form -- read it off the
    // parent project, same pattern TasksList.tsx uses.
    const { data: projectRow } = await supabase.from("pmo_projects").select("tenant_id").eq("id", form.project_id).single();

    const payload: any = {
      project_id: form.project_id,
      title: form.title.trim(),
      status: form.status,
      due_date: form.due_date || null,
      completion_percent: form.completion_percent ? Number(form.completion_percent) : 0,
    };
    if (projectRow?.tenant_id) payload.tenant_id = projectRow.tenant_id;

    const { error: insertError } = await supabase.from("pmo_milestones").insert(payload);
    setSaving(false);
    if (insertError) {
      setError(insertError.message);
      return;
    }
    setOpen(false);
    resetForm();
    fetchMilestones();
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 2 }}>
        <Box>
          <Typography variant="h5" fontWeight={700}>Milestones</Typography>
          <Typography variant="body2" color="text.secondary">Milestone tracking per project, due date, completion %.</Typography>
        </Box>
        <Button variant="contained" startIcon={<Add />} onClick={() => { setError(null); setOpen(true); }}>New Milestone</Button>
      </Box>

      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Project</TableCell><TableCell>Milestone</TableCell><TableCell>Due Date</TableCell><TableCell>Completion</TableCell><TableCell>Status</TableCell></TableRow></TableHead><TableBody>{milestones.length === 0 ? <TableRow><TableCell colSpan={5} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No milestones yet. Create one via New Milestone.</Typography></TableCell></TableRow> : milestones.map(m => <TableRow key={m.id} hover><TableCell>{m.pmo_projects?.name || "-"}</TableCell><TableCell><Typography fontWeight={600}>{m.title}</Typography></TableCell><TableCell>{m.due_date ? new Date(m.due_date).toLocaleDateString() : "-"}</TableCell><TableCell><Box sx={{ display: "flex", alignItems: "center", gap: 1, minWidth: 120 }}><LinearProgress variant="determinate" value={m.completion_percent || 0} sx={{ flex: 1, height: 6 }} /><Typography variant="caption">{m.completion_percent || 0}%</Typography></Box></TableCell><TableCell><Chip label={m.status || "pending"} size="small" /></TableCell></TableRow>)}</TableBody></Table></CardContent></Card>

      <Dialog open={open} onClose={() => setOpen(false)} maxWidth="sm" fullWidth>
        <DialogTitle>New Milestone</DialogTitle>
        <DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}>
          {error && <Alert severity="error">{error}</Alert>}
          <TextField select label="Project *" value={form.project_id} onChange={e => setForm({ ...form, project_id: e.target.value })} fullWidth required>
            <MenuItem value="">-- Select Project --</MenuItem>
            {projects.map(p => <MenuItem key={p.id} value={p.id}>{p.name}</MenuItem>)}
          </TextField>
          <TextField label="Title *" value={form.title} onChange={e => setForm({ ...form, title: e.target.value })} fullWidth autoFocus required placeholder="e.g. Foundation complete" />
          <Grid container spacing={2}>
            <Grid item xs={6}>
              <TextField select label="Status" value={form.status} onChange={e => setForm({ ...form, status: e.target.value })} fullWidth>
                <MenuItem value="pending">Pending</MenuItem>
                <MenuItem value="in_progress">In Progress</MenuItem>
                <MenuItem value="done">Done</MenuItem>
                <MenuItem value="missed">Missed</MenuItem>
              </TextField>
            </Grid>
            <Grid item xs={6}>
              <TextField label="Due Date" type="date" value={form.due_date} onChange={e => setForm({ ...form, due_date: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} />
            </Grid>
          </Grid>
          <TextField label="Completion %" type="number" value={form.completion_percent} onChange={e => setForm({ ...form, completion_percent: e.target.value })} fullWidth inputProps={{ min: 0, max: 100 }} />
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setOpen(false)}>Cancel</Button>
          <Button variant="contained" onClick={handleSave} disabled={saving || !form.project_id || !form.title.trim()}>{saving ? "Saving..." : "Create"}</Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}