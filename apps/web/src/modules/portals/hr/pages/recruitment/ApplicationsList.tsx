import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Table, TableBody, TableCell, TableHead, TableRow, Typography, TextField, MenuItem, Dialog, DialogActions, DialogContent, DialogTitle, Grid } from "@mui/material";
import { Add } from "@mui/icons-material";
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

export default function ApplicationsList() {
  const { session } = useAuth();
  const [apps, setApps] = useState<Application[]>([]);
  const [jobs, setJobs] = useState<Job[]>([]);
  const [loading, setLoading] = useState(true);
  const [open, setOpen] = useState(false);
  const [form, setForm] = useState({ job_posting_id: "", candidate_name: "", email: "", phone: "", stage: "applied" });

  const fetchData = async () => {
    setLoading(true);
    const [appsRes, jobsRes] = await Promise.all([
      supabase.from("hr_job_applications").select("*, hr_job_postings(title)").order("created_at", { ascending: false }),
      supabase.from("hr_job_postings").select("id, title").eq("status", "open").order("title"),
    ]);
    if (appsRes.error) console.error("Failed to load applications:", appsRes.error.message);
    if (appsRes.data) setApps(appsRes.data as Application[]);
    if (jobsRes.data) setJobs(jobsRes.data as Job[]);
    setLoading(false);
  };

  useEffect(() => { fetchData(); }, []);

  const handleSave = async () => {
    if (!form.candidate_name.trim()) return;

    const { data: appUser, error: appUserError } = await supabase
      .from("app_users")
      .select("tenant_id")
      .eq("id", session?.user?.id)
      .single();
    const tenant_id = appUser?.tenant_id;
    if (appUserError || !tenant_id) {
      alert("Could not determine your organization. Please refresh and try again.");
      return;
    }

    const payload: any = {
      job_posting_id: form.job_posting_id || null,
      candidate_name: form.candidate_name.trim(),
      email: form.email.trim() || null,
      phone: form.phone.trim() || null,
      stage: form.stage,
      tenant_id,
    };

    const { error } = await supabase.from("hr_job_applications").insert(payload);
    if (error) { alert(error.message); return; }
    setOpen(false);
    setForm({ job_posting_id: "", candidate_name: "", email: "", phone: "", stage: "applied" });
    fetchData();
  };

  const getStageColor = (s: string) => {
    if (s === 'hired') return 'success';
    if (s === 'rejected') return 'error';
    if (s === 'interview') return 'primary';
    return 'default';
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3 }}>
        <Box><Typography variant="h5" fontWeight={700}>Applications</Typography><Typography variant="body2" color="text.secondary">{apps.length} applications. Candidate pipeline for open jobs.</Typography></Box>
        <Button variant="contained" startIcon={<Add />} onClick={() => setOpen(true)}>New Application</Button>
      </Box>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Candidate</TableCell><TableCell>Job Posting</TableCell><TableCell>Contact</TableCell><TableCell>Stage</TableCell><TableCell>Applied</TableCell></TableRow></TableHead><TableBody>{apps.length === 0 ? <TableRow><TableCell colSpan={5} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No applications yet. Create candidate applications linked to job postings.</Typography></TableCell></TableRow> : apps.map(a => <TableRow key={a.id} hover><TableCell><Typography fontWeight={600}>{a.candidate_name}</Typography></TableCell><TableCell>{a.hr_job_postings?.title || "-"}</TableCell><TableCell><Typography variant="body2">{a.email || "-"}</Typography><Typography variant="caption" color="text.secondary">{a.phone || ""}</Typography></TableCell><TableCell><Chip label={a.stage} size="small" color={getStageColor(a.stage) as any} sx={{ textTransform: "capitalize" }} /></TableCell><TableCell>{new Date(a.created_at).toLocaleDateString()}</TableCell></TableRow>)}</TableBody></Table></CardContent></Card>

      <Dialog open={open} onClose={() => setOpen(false)} maxWidth="sm" fullWidth><DialogTitle>New Application</DialogTitle><DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}><TextField select label="Job Posting" value={form.job_posting_id} onChange={e => setForm({ ...form, job_posting_id: e.target.value })} fullWidth><MenuItem value="">-- General application --</MenuItem>{jobs.map(j => <MenuItem key={j.id} value={j.id}>{j.title}</MenuItem>)}</TextField><TextField label="Candidate Name *" value={form.candidate_name} onChange={e => setForm({ ...form, candidate_name: e.target.value })} fullWidth autoFocus required /><Grid container spacing={2}><Grid item xs={6}><TextField label="Email" value={form.email} onChange={e => setForm({ ...form, email: e.target.value })} fullWidth /></Grid><Grid item xs={6}><TextField label="Phone" value={form.phone} onChange={e => setForm({ ...form, phone: e.target.value })} fullWidth /></Grid></Grid><TextField select label="Stage" value={form.stage} onChange={e => setForm({ ...form, stage: e.target.value })} fullWidth><MenuItem value="applied">Applied</MenuItem><MenuItem value="screening">Screening</MenuItem><MenuItem value="interview">Interview</MenuItem><MenuItem value="offer">Offer</MenuItem><MenuItem value="hired">Hired</MenuItem><MenuItem value="rejected">Rejected</MenuItem></TextField></DialogContent><DialogActions><Button onClick={() => setOpen(false)}>Cancel</Button><Button variant="contained" onClick={handleSave} disabled={!form.candidate_name.trim()}>Create</Button></DialogActions></Dialog>
    </Box>
  );
}