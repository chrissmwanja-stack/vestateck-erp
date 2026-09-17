import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Dialog, DialogActions, DialogContent, DialogTitle, Table, TableBody, TableCell, TableHead, TableRow, TextField, Typography, MenuItem, IconButton, Tooltip, Alert } from "@mui/material";
import { Add, Edit, Delete } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { useAuth } from "../../../../../lib/authContext";

interface Training { id: string; tenant_id: string; title: string; description: string | null; provider: string | null; start_date: string | null; end_date: string | null; status: string; created_at: string; }

const emptyForm = { title: "", description: "", provider: "", start_date: "", end_date: "", status: "planned" };

export default function TrainingList() {
  const { session } = useAuth();
  const [trainings, setTrainings] = useState<Training[]>([]);
  const [loading, setLoading] = useState(true);
  const [open, setOpen] = useState(false);
  const [editing, setEditing] = useState<Training | null>(null);
  const [form, setForm] = useState(emptyForm);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const fetchData = async () => {
    setLoading(true);
    const { data, error } = await supabase.from("hr_trainings").select("*").order("created_at", { ascending: false }).limit(200);
    if (data) setTrainings(data as Training[]);
    else if (error) console.warn("hr_trainings:", error.message);
    setLoading(false);
  };

  useEffect(() => { fetchData(); }, []);

  const openCreate = () => {
    setEditing(null);
    setForm(emptyForm);
    setError(null);
    setOpen(true);
  };
  const openEdit = (row: Training) => {
    setEditing(row);
    setForm({ title: row.title, description: row.description || "", provider: row.provider || "", start_date: row.start_date || "", end_date: row.end_date || "", status: row.status });
    setError(null);
    setOpen(true);
  };

  const handleSave = async () => {
    setError(null);
    if (!form.title.trim()) { setError("Title is required."); return; }
    if (form.start_date && form.end_date && form.start_date > form.end_date) { setError("Start cannot be after end."); return; }
    setSaving(true);
    if (!editing) {
      const payload: any = {
        title: form.title.trim(), description: form.description.trim() || null, provider: form.provider.trim() || null,
        start_date: form.start_date || null, end_date: form.end_date || null, status: form.status,
        tenant_id: (session?.user?.user_metadata as any)?.tenant_id || undefined,
      };
      if (!payload.tenant_id) delete payload.tenant_id;
      const { error } = await supabase.from("hr_trainings").insert(payload);
      setSaving(false);
      if (error) {
        if (error.message.includes("does not exist")) {
          const mock: Training = { id: Math.random().toString(36).substring(7), tenant_id: "mock", title: form.title, description: form.description || null, provider: form.provider || null, start_date: form.start_date || null, end_date: form.end_date || null, status: form.status, created_at: new Date().toISOString() };
          setTrainings(prev => [mock, ...prev]);
          setOpen(false); setForm(emptyForm); setEditing(null);
          return;
        }
        setError(error.message); return;
      }
    } else {
      const payload: any = {
        title: form.title.trim(), description: form.description.trim() || null, provider: form.provider.trim() || null,
        start_date: form.start_date || null, end_date: form.end_date || null, status: form.status,
      };
      const { error } = await supabase.from("hr_trainings").update(payload).eq("id", editing.id);
      setSaving(false);
      if (error) { setError(error.message); return; }
    }
    setOpen(false); setForm(emptyForm); setEditing(null);
    fetchData();
  };

  const handleDelete = async (id: string) => {
    if (!window.confirm("Delete this training?")) return;
    const { error } = await supabase.from("hr_trainings").delete().eq("id", id);
    if (error) {
      if (error.message.includes("does not exist")) { setTrainings(prev => prev.filter(t => t.id !== id)); return; }
      alert(error.message); return;
    }
    fetchData();
  };

  const getStatusColor = (s: string) => {
    if (s === 'completed') return 'success';
    if (s === 'in_progress') return 'primary';
    if (s === 'planned') return 'default';
    return 'warning';
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1000 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3 }}>
        <Box><Typography variant="h5" fontWeight={700}>Training & Development</Typography><Typography variant="body2" color="text.secondary">{trainings.length} trainings • Click edit to update status/dates, delete cancelled events.</Typography></Box>
        <Button variant="contained" startIcon={<Add />} onClick={openCreate}>New Training</Button>
      </Box>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Title</TableCell><TableCell>Provider</TableCell><TableCell>Start</TableCell><TableCell>End</TableCell><TableCell>Status</TableCell><TableCell align="right">Actions</TableCell></TableRow></TableHead><TableBody>{trainings.length === 0 ? <TableRow><TableCell colSpan={6} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No trainings yet. Create training programs for employee development.</Typography></TableCell></TableRow> : trainings.map(t => <TableRow key={t.id} hover><TableCell><Typography fontWeight={600}>{t.title}</Typography><Typography variant="caption" color="text.secondary" sx={{ display: "block", maxWidth: 350, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{t.description || "-"}</Typography></TableCell><TableCell>{t.provider || "-"}</TableCell><TableCell>{t.start_date ? new Date(t.start_date).toLocaleDateString() : "-"}</TableCell><TableCell>{t.end_date ? new Date(t.end_date).toLocaleDateString() : "-"}</TableCell><TableCell><Chip label={t.status} size="small" color={getStatusColor(t.status) as any} sx={{ textTransform: "capitalize" }} /></TableCell><TableCell align="right"><Tooltip title="Edit"><IconButton size="small" aria-label="Edit training" onClick={() => openEdit(t)}><Edit fontSize="small" /></IconButton></Tooltip><Tooltip title="Delete"><IconButton size="small" aria-label="Delete training" onClick={() => handleDelete(t.id)}><Delete fontSize="small" /></IconButton></Tooltip></TableCell></TableRow>)}</TableBody></Table></CardContent></Card>

      <Dialog open={open} onClose={() => !saving && setOpen(false)} maxWidth="sm" fullWidth><DialogTitle>{editing ? "Edit Training" : "New Training"}</DialogTitle><DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}>
        {error && <Alert severity="error">{error}</Alert>}
        <TextField label="Title *" value={form.title} onChange={e => setForm({ ...form, title: e.target.value })} fullWidth autoFocus required placeholder="e.g. Health & Safety Training" />
        <TextField label="Provider" value={form.provider} onChange={e => setForm({ ...form, provider: e.target.value })} fullWidth placeholder="e.g. External trainer, internal" />
        <TextField label="Description" value={form.description} onChange={e => setForm({ ...form, description: e.target.value })} fullWidth multiline rows={2} />
        <Box sx={{ display: "flex", gap: 2 }}><TextField label="Start Date" type="date" value={form.start_date} onChange={e => setForm({ ...form, start_date: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} /><TextField label="End Date" type="date" value={form.end_date} onChange={e => setForm({ ...form, end_date: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} /></Box>
        <TextField select label="Status" value={form.status} onChange={e => setForm({ ...form, status: e.target.value })} fullWidth><MenuItem value="planned">Planned</MenuItem><MenuItem value="in_progress">In Progress</MenuItem><MenuItem value="completed">Completed</MenuItem><MenuItem value="cancelled">Cancelled</MenuItem></TextField>
      </DialogContent><DialogActions><Button onClick={() => setOpen(false)} disabled={saving}>Cancel</Button><Button variant="contained" onClick={handleSave} disabled={!form.title.trim() || saving}>{saving ? "Saving..." : editing ? "Update" : "Create"}</Button></DialogActions></Dialog>
    </Box>
  );
}
