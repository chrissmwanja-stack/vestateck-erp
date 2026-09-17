import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, Typography, TextField, MenuItem, Dialog, DialogActions, DialogContent, DialogTitle, Grid, IconButton, Tooltip, Alert } from "@mui/material";
import { Add, Edit, Delete } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { useAuth } from "../../../../../lib/authContext";

interface Job { id: string; title: string; }
interface Application {
  id: string;
  tenant_id: string;
  job_posting_id: string | null;
  candidate_name: string;
  email: string | null;
  phone: string | null;
  stage: string;
  created_at: string;
  hr_job_postings?: { title: string } | null;
}

const emptyForm = { job_posting_id: "", candidate_name: "", email: "", phone: "", stage: "applied" };

export default function ApplicationsList() {
  const { session } = useAuth();
  const [apps, setApps] = useState<Application[]>([]);
  const [jobs, setJobs] = useState<Job[]>([]);
  const [loading, setLoading] = useState(true);
  const [open, setOpen] = useState(false);
  const [editing, setEditing] = useState<Application | null>(null);
  const [form, setForm] = useState(emptyForm);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const fetchData = async () => {
    setLoading(true);
    const [appsRes, jobsRes] = await Promise.all([
      supabase.from("hr_job_applications").select("*, hr_job_postings(title)").order("created_at", { ascending: false }).limit(200),
      supabase.from("hr_job_postings").select("id, title").eq("status", "open").order("title"),
    ]);
    if (appsRes.error) console.error("Failed to load applications:", appsRes.error.message);
    if (appsRes.data) {
      const norm = (appsRes.data as any[]).map((a: any) => ({ ...a, hr_job_postings: Array.isArray(a.hr_job_postings) ? a.hr_job_postings[0] ?? null : a.hr_job_postings ?? null }));
      setApps(norm as Application[]);
    }
    if (jobsRes.data) setJobs(jobsRes.data as Job[]);
    // Also fetch closed jobs for edit dropdown if editing references one
    if (editing?.job_posting_id) {
      const { data: closed } = await supabase.from("hr_job_postings").select("id, title").eq("id", editing.job_posting_id).single();
      if (closed && !jobs.find(j => j.id === closed.id)) setJobs(prev => [...prev, closed as Job]);
    }
    setLoading(false);
  };

  useEffect(() => { fetchData(); // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const openCreate = () => {
    setEditing(null);
    setForm(emptyForm);
    setError(null);
    setOpen(true);
  };
  const openEdit = async (row: Application) => {
    setEditing(row);
    setForm({ job_posting_id: row.job_posting_id || "", candidate_name: row.candidate_name, email: row.email || "", phone: row.phone || "", stage: row.stage });
    setError(null);
    // ensure job is in dropdown even if closed
    if (row.job_posting_id && !jobs.find(j => j.id === row.job_posting_id)) {
      const { data } = await supabase.from("hr_job_postings").select("id, title").eq("id", row.job_posting_id).single();
      if (data) setJobs(prev => [...prev, data as Job]);
    }
    setOpen(true);
  };

  const handleSave = async () => {
    setError(null);
    if (!form.candidate_name.trim()) { setError("Candidate name is required."); return; }
    setSaving(true);
    if (!editing) {
      const userId = session?.user?.id;
      if (!userId) { setError("Session expired. Please sign in again."); setSaving(false); return; }
      const { data: appUser, error: appUserError } = await supabase.from("app_users").select("tenant_id").eq("id", userId).single();
      const tenant_id = (appUser as any)?.tenant_id;
      if (appUserError || !tenant_id) { setError("Could not determine organization."); setSaving(false); return; }
      const payload: any = { job_posting_id: form.job_posting_id || null, candidate_name: form.candidate_name.trim(), email: form.email.trim() || null, phone: form.phone.trim() || null, stage: form.stage, tenant_id };
      const { error } = await supabase.from("hr_job_applications").insert(payload);
      setSaving(false);
      if (error) { setError(error.message); return; }
    } else {
      const payload: any = { job_posting_id: form.job_posting_id || null, candidate_name: form.candidate_name.trim(), email: form.email.trim() || null, phone: form.phone.trim() || null, stage: form.stage };
      const { error } = await supabase.from("hr_job_applications").update(payload).eq("id", editing.id);
      setSaving(false);
      if (error) { setError(error.message); return; }
    }
    setOpen(false);
    setForm(emptyForm);
    setEditing(null);
    fetchData();
  };

  const handleDelete = async (id: string) => {
    if (!window.confirm("Delete this application?")) return;
    const { error } = await supabase.from("hr_job_applications").delete().eq("id", id);
    if (error) { alert(error.message); return; }
    fetchData();
  };

  const getStageColor = (s: string) => {
    if (s === 'hired') return 'success';
    if (s === 'rejected') return 'error';
    if (s === 'interview') return 'primary';
    if (s === 'offer') return 'warning';
    return 'default';
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3 }}>
        <Box><Typography variant="h5" fontWeight={700}>Applications</Typography><Typography variant="body2" color="text.secondary">{apps.length} applications • Drag pipeline via stage edit, delete withdrawn candidates.</Typography></Box>
        <Button variant="contained" startIcon={<Add />} onClick={openCreate}>New Application</Button>
      </Box>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Candidate</TableCell><TableCell>Job Posting</TableCell><TableCell>Contact</TableCell><TableCell>Stage</TableCell><TableCell>Applied</TableCell><TableCell align="right">Actions</TableCell></TableRow></TableHead><TableBody>{apps.length === 0 ? <TableRow><TableCell colSpan={6} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No applications yet. Create candidate applications linked to job postings.</Typography></TableCell></TableRow> : apps.map(a => <TableRow key={a.id} hover><TableCell><Typography fontWeight={600}>{a.candidate_name}</Typography></TableCell><TableCell>{a.hr_job_postings?.title || "-"}</TableCell><TableCell><Typography variant="body2">{a.email || "-"}</Typography><Typography variant="caption" color="text.secondary">{a.phone || ""}</Typography></TableCell><TableCell><Chip label={a.stage} size="small" color={getStageColor(a.stage) as any} sx={{ textTransform: "capitalize" }} /></TableCell><TableCell>{new Date(a.created_at).toLocaleDateString()}</TableCell><TableCell align="right"><Tooltip title="Edit"><IconButton size="small" aria-label="Edit application" onClick={() => openEdit(a)}><Edit fontSize="small" /></IconButton></Tooltip><Tooltip title="Delete"><IconButton size="small" aria-label="Delete application" onClick={() => handleDelete(a.id)}><Delete fontSize="small" /></IconButton></Tooltip></TableCell></TableRow>)}</TableBody></Table></CardContent></Card>

      <Dialog open={open} onClose={() => !saving && setOpen(false)} maxWidth="sm" fullWidth><DialogTitle>{editing ? "Edit Application" : "New Application"}</DialogTitle><DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}>
        {error && <Alert severity="error">{error}</Alert>}
        <TextField select label="Job Posting" value={form.job_posting_id} onChange={e => setForm({ ...form, job_posting_id: e.target.value })} fullWidth><MenuItem value="">-- General application --</MenuItem>{jobs.map(j => <MenuItem key={j.id} value={j.id}>{j.title}</MenuItem>)}</TextField>
        <TextField label="Candidate Name *" value={form.candidate_name} onChange={e => setForm({ ...form, candidate_name: e.target.value })} fullWidth autoFocus required />
        <Grid container spacing={2}><Grid item xs={6}><TextField label="Email" value={form.email} onChange={e => setForm({ ...form, email: e.target.value })} fullWidth /></Grid><Grid item xs={6}><TextField label="Phone" value={form.phone} onChange={e => setForm({ ...form, phone: e.target.value })} fullWidth /></Grid></Grid>
        <TextField select label="Stage" value={form.stage} onChange={e => setForm({ ...form, stage: e.target.value })} fullWidth><MenuItem value="applied">Applied</MenuItem><MenuItem value="screening">Screening</MenuItem><MenuItem value="interview">Interview</MenuItem><MenuItem value="offer">Offer</MenuItem><MenuItem value="hired">Hired</MenuItem><MenuItem value="rejected">Rejected</MenuItem></TextField>
        {editing && <Typography variant="caption" color="text.secondary">Tip: Set to <strong>Hired</strong> when candidate becomes employee — then create the employee record in Employees page.</Typography>}
      </DialogContent><DialogActions><Button onClick={() => setOpen(false)} disabled={saving}>Cancel</Button><Button variant="contained" onClick={handleSave} disabled={!form.candidate_name.trim() || saving}>{saving ? "Saving..." : editing ? "Update" : "Create"}</Button></DialogActions></Dialog>
    </Box>
  );
}
