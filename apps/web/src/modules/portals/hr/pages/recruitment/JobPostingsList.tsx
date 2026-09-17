import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Dialog, DialogActions, DialogContent, DialogTitle, Table, TableBody, TableCell, TableHead, TableRow, TextField, Typography, MenuItem, IconButton, Tooltip, Alert } from "@mui/material";
import { Add, Edit, Delete } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { useAuth } from "../../../../../lib/authContext";

interface Position { id: string; title: string; }
interface Department { id: string; name: string; }
interface JobPosting {
  id: string;
  title: string;
  status: string;
  description: string | null;
  position_id: string | null;
  department_id: string | null;
  created_at: string;
  hr_positions?: { title: string } | null;
  departments?: { name: string } | null;
}

const emptyForm = { title: "", position_id: "", department_id: "", description: "", status: "open" };

export default function JobPostingsList() {
  const { session } = useAuth();
  const [jobs, setJobs] = useState<JobPosting[]>([]);
  const [positions, setPositions] = useState<Position[]>([]);
  const [departments, setDepartments] = useState<Department[]>([]);
  const [loading, setLoading] = useState(true);
  const [open, setOpen] = useState(false);
  const [editing, setEditing] = useState<JobPosting | null>(null);
  const [form, setForm] = useState(emptyForm);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const fetchData = async () => {
    setLoading(true);
    const [jobsRes, posRes, deptRes] = await Promise.all([
      supabase.from("hr_job_postings").select("*, hr_positions(title), departments(name)").order("created_at", { ascending: false }).limit(200),
      supabase.from("hr_positions").select("id, title").eq("is_active", true).order("title"),
      supabase.from("departments").select("id, name").eq("is_active", true).order("name"),
    ]);
    if (jobsRes.data) {
      const norm = (jobsRes.data as any[]).map((j: any) => ({
        ...j,
        hr_positions: Array.isArray(j.hr_positions) ? j.hr_positions[0] ?? null : j.hr_positions ?? null,
        departments: Array.isArray(j.departments) ? j.departments[0] ?? null : j.departments ?? null,
      }));
      setJobs(norm as JobPosting[]);
    }
    if (posRes.data) setPositions(posRes.data as Position[]);
    if (deptRes.data) setDepartments(deptRes.data as Department[]);
    setLoading(false);
  };

  useEffect(() => { fetchData(); }, []);

  const openCreate = () => {
    setEditing(null);
    setForm(emptyForm);
    setError(null);
    setOpen(true);
  };
  const openEdit = (row: JobPosting) => {
    setEditing(row);
    setForm({ title: row.title, position_id: row.position_id || "", department_id: row.department_id || "", description: row.description || "", status: row.status });
    setError(null);
    setOpen(true);
  };

  const handleSave = async () => {
    setError(null);
    if (!form.title.trim()) { setError("Title is required."); return; }
    setSaving(true);
    let tenant_id: string | undefined;
    if (!editing) {
      const userId = session?.user?.id;
      if (!userId) { setError("Session expired. Please sign in again."); setSaving(false); return; }
      const { data: appUser, error: appUserError } = await supabase.from("app_users").select("tenant_id").eq("id", userId).single();
      tenant_id = (appUser as any)?.tenant_id;
      if (appUserError || !tenant_id) { setError("Could not determine organization."); setSaving(false); return; }
    }

    const payload: any = {
      title: form.title.trim(),
      position_id: form.position_id || null,
      department_id: form.department_id || null,
      description: form.description.trim() || null,
      status: form.status,
    };
    if (tenant_id) payload.tenant_id = tenant_id;

    let res;
    if (editing) res = await supabase.from("hr_job_postings").update(payload).eq("id", editing.id);
    else res = await supabase.from("hr_job_postings").insert(payload);

    setSaving(false);
    if (res.error) { setError(res.error.message); return; }
    setOpen(false);
    setEditing(null);
    setForm(emptyForm);
    fetchData();
  };

  const handleDelete = async (id: string) => {
    if (!window.confirm("Delete this job posting? Applications linked to it will remain but show '-'. ")) return;
    const { error } = await supabase.from("hr_job_postings").delete().eq("id", id);
    if (error) { alert(error.message); return; }
    fetchData();
  };

  const getStatusColor = (s: string) => {
    if (s === 'open') return 'success';
    if (s === 'closed') return 'default';
    return 'warning';
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3 }}>
        <Box><Typography variant="h5" fontWeight={700}>Job Postings</Typography><Typography variant="body2" color="text.secondary">{jobs.length} postings • Click edit to update status/title, delete closed roles.</Typography></Box>
        <Button variant="contained" startIcon={<Add />} onClick={openCreate}>New Job Posting</Button>
      </Box>
      <Card>
        <CardContent sx={{ p: 0 }}>
          <Table>
            <TableHead>
              <TableRow>
                <TableCell>Title</TableCell>
                <TableCell>Department</TableCell>
                <TableCell>Position</TableCell>
                <TableCell>Status</TableCell>
                <TableCell>Created</TableCell>
                <TableCell align="right">Actions</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {jobs.length === 0 ? (
                <TableRow><TableCell colSpan={6} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No job postings yet. Create open positions for recruitment.</Typography></TableCell></TableRow>
              ) : (
                jobs.map(j => (
                  <TableRow key={j.id} hover>
                    <TableCell>
                      <Typography fontWeight={600}>{j.title}</Typography>
                      <Typography variant="caption" color="text.secondary" sx={{ display: "block", maxWidth: 400, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{j.description || "-"}</Typography>
                    </TableCell>
                    <TableCell>{j.departments?.name || "-"}</TableCell>
                    <TableCell>{j.hr_positions?.title || "-"}</TableCell>
                    <TableCell><Chip label={j.status} size="small" color={getStatusColor(j.status) as any} sx={{ textTransform: "capitalize" }} /></TableCell>
                    <TableCell>{new Date(j.created_at).toLocaleDateString()}</TableCell>
                    <TableCell align="right">
                      <Tooltip title="Edit"><IconButton size="small" aria-label="Edit job" onClick={() => openEdit(j)}><Edit fontSize="small" /></IconButton></Tooltip>
                      <Tooltip title="Delete"><IconButton size="small" aria-label="Delete job" onClick={() => handleDelete(j.id)}><Delete fontSize="small" /></IconButton></Tooltip>
                    </TableCell>
                  </TableRow>
                ))
              )}
            </TableBody>
          </Table>
        </CardContent>
      </Card>

      <Dialog open={open} onClose={() => !saving && setOpen(false)} maxWidth="sm" fullWidth>
        <DialogTitle>{editing ? "Edit Job Posting" : "New Job Posting"}</DialogTitle>
        <DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}>
          {error && <Alert severity="error">{error}</Alert>}
          <TextField label="Title *" value={form.title} onChange={e => setForm({ ...form, title: e.target.value })} fullWidth autoFocus placeholder="e.g. Senior Site Engineer" />
          <TextField select label="Department" value={form.department_id} onChange={e => setForm({ ...form, department_id: e.target.value })} fullWidth>
            <MenuItem value="">-- None --</MenuItem>
            {departments.map(d => <MenuItem key={d.id} value={d.id}>{d.name}</MenuItem>)}
          </TextField>
          <TextField select label="Position" value={form.position_id} onChange={e => setForm({ ...form, position_id: e.target.value })} fullWidth>
            <MenuItem value="">-- None --</MenuItem>
            {positions.map(p => <MenuItem key={p.id} value={p.id}>{p.title}</MenuItem>)}
          </TextField>
          <TextField select label="Status" value={form.status} onChange={e => setForm({ ...form, status: e.target.value })} fullWidth>
            <MenuItem value="open">Open</MenuItem>
            <MenuItem value="on_hold">On Hold</MenuItem>
            <MenuItem value="closed">Closed</MenuItem>
          </TextField>
          <TextField label="Description" value={form.description} onChange={e => setForm({ ...form, description: e.target.value })} fullWidth multiline rows={4} placeholder="Job description, requirements, benefits..." />
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setOpen(false)} disabled={saving}>Cancel</Button>
          <Button variant="contained" onClick={handleSave} disabled={!form.title.trim() || saving}>{saving ? "Saving..." : editing ? "Update" : "Create"}</Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}
