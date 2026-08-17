import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Dialog, DialogActions, DialogContent, DialogTitle, Table, TableBody, TableCell, TableHead, TableRow, TextField, Typography, MenuItem } from "@mui/material";
import { Add } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { useAuth } from "../../../../../lib/authContext";

interface Position { id: string; title: string; }
interface Department { id: string; name: string; }
interface JobPosting {
  id: string;
  title: string;
  status: string;
  description: string | null;
  created_at: string;
  hr_positions?: { title: string } | null;
  departments?: { name: string } | null;
}

export default function JobPostingsList() {
  const { session } = useAuth();
  const [jobs, setJobs] = useState<JobPosting[]>([]);
  const [positions, setPositions] = useState<Position[]>([]);
  const [departments, setDepartments] = useState<Department[]>([]);
  const [loading, setLoading] = useState(true);
  const [open, setOpen] = useState(false);
  const [form, setForm] = useState({ title: "", position_id: "", department_id: "", description: "", status: "open" });

  const fetchData = async () => {
    setLoading(true);
    const [jobsRes, posRes, deptRes] = await Promise.all([
      supabase.from("hr_job_postings").select("*, hr_positions(title), departments(name)").order("created_at", { ascending: false }),
      supabase.from("hr_positions").select("id, title").eq("is_active", true).order("title"),
      supabase.from("departments").select("id, name").eq("is_active", true).order("name"),
    ]);
    if (jobsRes.data) setJobs(jobsRes.data as JobPosting[]);
    if (posRes.data) setPositions(posRes.data as Position[]);
    if (deptRes.data) setDepartments(deptRes.data as Department[]);
    setLoading(false);
  };

  useEffect(() => { fetchData(); }, []);

  const handleSave = async () => {
    if (!form.title.trim()) return;

    const userId = session?.user?.id;
    if (!userId) {
      alert("Your session has expired. Please sign in again.");
      return;
    }

    const { data: appUser, error: appUserError } = await supabase
      .from("app_users")
      .select("tenant_id")
      .eq("id", userId)
      .single();
    const tenant_id = appUser?.tenant_id;
    if (appUserError || !tenant_id) {
      alert("Could not determine your organization. Please refresh and try again.");
      return;
    }

    const payload: any = {
      title: form.title.trim(),
      position_id: form.position_id || null,
      department_id: form.department_id || null,
      description: form.description.trim() || null,
      status: form.status,
      tenant_id,
    };
    const { error } = await supabase.from("hr_job_postings").insert(payload);
    if (error) alert(error.message);
    else { setOpen(false); setForm({ title: "", position_id: "", department_id: "", description: "", status: "open" }); fetchData(); }
  };

  const getStatusColor = (s: string) => {
    if (s === 'open') return 'success';
    if (s === 'closed') return 'default';
    return 'warning';
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1000 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3 }}>
        <Box><Typography variant="h5" fontWeight={700}>Job Postings</Typography><Typography variant="body2" color="text.secondary">{jobs.length} postings. Recruitment funnel start.</Typography></Box>
        <Button variant="contained" startIcon={<Add />} onClick={() => setOpen(true)}>New Job Posting</Button>
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
              </TableRow>
            </TableHead>
            <TableBody>
              {jobs.length === 0 ? (
                <TableRow><TableCell colSpan={5} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No job postings yet. Create open positions for recruitment.</Typography></TableCell></TableRow>
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
                  </TableRow>
                ))
              )}
            </TableBody>
          </Table>
        </CardContent>
      </Card>

      <Dialog open={open} onClose={() => setOpen(false)} maxWidth="sm" fullWidth>
        <DialogTitle>New Job Posting</DialogTitle>
        <DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}>
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
          <Button onClick={() => setOpen(false)}>Cancel</Button>
          <Button variant="contained" onClick={handleSave} disabled={!form.title.trim()}>Create</Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}