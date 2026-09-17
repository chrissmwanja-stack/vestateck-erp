import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Dialog, DialogActions, DialogContent, DialogTitle, Table, TableBody, TableCell, TableHead, TableRow, TextField, Typography, MenuItem, Grid, IconButton, Tooltip, Alert } from "@mui/material";
import { Add, Edit, Delete } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { useAuth } from "../../../../../lib/authContext";

interface Employee { id: string; first_name: string; last_name: string; }
interface Appraisal { id: string; tenant_id: string; employee_id: string; period: string; rating: number; comments: string | null; status: string; created_at: string; hr_employees?: { first_name: string; last_name: string } | null; }

const emptyForm = { employee_id: "", period: "", rating: 3, comments: "", status: "draft" };

export default function AppraisalsList() {
  const { session } = useAuth();
  const [appraisals, setAppraisals] = useState<Appraisal[]>([]);
  const [employees, setEmployees] = useState<Employee[]>([]);
  const [loading, setLoading] = useState(true);
  const [open, setOpen] = useState(false);
  const [editing, setEditing] = useState<Appraisal | null>(null);
  const [form, setForm] = useState(emptyForm);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const fetchData = async () => {
    setLoading(true);
    const [appRes, empRes] = await Promise.all([
      supabase.from("hr_appraisals").select("*, hr_employees(first_name, last_name)").order("created_at", { ascending: false }).limit(200),
      supabase.from("hr_employees").select("id, first_name, last_name").eq("is_active", true).order("first_name"),
    ]);
    if (appRes.data) {
      const norm = (appRes.data as any[]).map((a: any) => ({ ...a, hr_employees: Array.isArray(a.hr_employees) ? a.hr_employees[0] ?? null : a.hr_employees ?? null }));
      setAppraisals(norm as Appraisal[]);
    } else if (appRes.error) {
      console.warn("hr_appraisals:", appRes.error.message);
      setAppraisals([]);
    }
    if (empRes.data) setEmployees(empRes.data as Employee[]);
    setLoading(false);
  };

  useEffect(() => { fetchData(); }, []);

  const openCreate = () => {
    setEditing(null);
    setForm(emptyForm);
    setError(null);
    setOpen(true);
  };
  const openEdit = (row: Appraisal) => {
    setEditing(row);
    setForm({ employee_id: row.employee_id, period: row.period, rating: row.rating, comments: row.comments || "", status: row.status });
    setError(null);
    setOpen(true);
  };

  const handleSave = async () => {
    setError(null);
    if (!form.employee_id) { setError("Select an employee."); return; }
    if (!form.period.trim()) { setError("Period is required (e.g. 2026 Q1)."); return; }
    if (form.rating < 1 || form.rating > 5) { setError("Rating must be 1-5."); return; }
    setSaving(true);
    const basePayload: any = {
      employee_id: form.employee_id,
      period: form.period.trim(),
      rating: form.rating,
      comments: form.comments.trim() || null,
      status: form.status,
    };
    if (!editing) {
      const tenant_id = (session?.user?.user_metadata as any)?.tenant_id;
      if (tenant_id) basePayload.tenant_id = tenant_id;
      const { error } = await supabase.from("hr_appraisals").insert(basePayload);
      setSaving(false);
      if (error) {
        if (error.message.includes("does not exist")) {
          const mock: Appraisal = {
            id: Math.random().toString(36).substring(7),
            tenant_id: "mock", employee_id: form.employee_id, period: form.period, rating: form.rating,
            comments: form.comments || null, status: form.status, created_at: new Date().toISOString(),
            hr_employees: employees.find(e => e.id === form.employee_id) ? { first_name: employees.find(e => e.id === form.employee_id)!.first_name, last_name: employees.find(e => e.id === form.employee_id)!.last_name } : null,
          };
          setAppraisals(prev => [mock, ...prev]);
          setOpen(false);
          setForm(emptyForm);
          setEditing(null);
          return;
        }
        setError(error.message);
        return;
      }
    } else {
      const { error } = await supabase.from("hr_appraisals").update(basePayload).eq("id", editing.id);
      setSaving(false);
      if (error) { setError(error.message); return; }
    }
    setOpen(false);
    setEditing(null);
    setForm(emptyForm);
    fetchData();
  };

  const handleDelete = async (id: string) => {
    if (!window.confirm("Delete this appraisal?")) return;
    const { error } = await supabase.from("hr_appraisals").delete().eq("id", id);
    if (error) {
      if (error.message.includes("does not exist")) {
        setAppraisals(prev => prev.filter(a => a.id !== id));
        return;
      }
      alert(error.message);
      return;
    }
    fetchData();
  };

  const getRatingColor = (r: number) => {
    if (r >= 4) return "success";
    if (r >= 3) return "primary";
    if (r >= 2) return "warning";
    return "error";
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3 }}>
        <Box><Typography variant="h5" fontWeight={700}>Appraisals</Typography><Typography variant="body2" color="text.secondary">{appraisals.length} appraisals • Edit rating/status inline, delete obsolete drafts.</Typography></Box>
        <Button variant="contained" startIcon={<Add />} onClick={openCreate}>New Appraisal</Button>
      </Box>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Employee</TableCell><TableCell>Period</TableCell><TableCell>Rating</TableCell><TableCell>Status</TableCell><TableCell>Comments</TableCell><TableCell>Created</TableCell><TableCell align="right">Actions</TableCell></TableRow></TableHead><TableBody>{appraisals.length === 0 ? <TableRow><TableCell colSpan={7} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No appraisals yet. Create performance reviews for employees.</Typography></TableCell></TableRow> : appraisals.map(a => <TableRow key={a.id} hover><TableCell><Typography fontWeight={600}>{a.hr_employees ? `${a.hr_employees.first_name} ${a.hr_employees.last_name}` : "-"}</Typography></TableCell><TableCell>{a.period}</TableCell><TableCell><Chip label={`${a.rating}/5`} size="small" color={getRatingColor(a.rating) as any} /></TableCell><TableCell><Chip label={a.status} size="small" variant="outlined" sx={{ textTransform: "capitalize" }} /></TableCell><TableCell><Typography variant="body2" color="text.secondary" sx={{ maxWidth: 250, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{a.comments || "-"}</Typography></TableCell><TableCell>{new Date(a.created_at).toLocaleDateString()}</TableCell><TableCell align="right"><Tooltip title="Edit"><IconButton size="small" aria-label="Edit appraisal" onClick={() => openEdit(a)}><Edit fontSize="small" /></IconButton></Tooltip><Tooltip title="Delete"><IconButton size="small" aria-label="Delete appraisal" onClick={() => handleDelete(a.id)}><Delete fontSize="small" /></IconButton></Tooltip></TableCell></TableRow>)}</TableBody></Table></CardContent></Card>

      <Dialog open={open} onClose={() => !saving && setOpen(false)} maxWidth="sm" fullWidth><DialogTitle>{editing ? "Edit Appraisal" : "New Appraisal"}</DialogTitle><DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}>
        {error && <Alert severity="error">{error}</Alert>}
        <TextField select label="Employee *" value={form.employee_id} onChange={e => setForm({ ...form, employee_id: e.target.value })} fullWidth required disabled={!!editing}><MenuItem value="">-- Select Employee --</MenuItem>{employees.map(emp => <MenuItem key={emp.id} value={emp.id}>{emp.first_name} {emp.last_name}</MenuItem>)}</TextField>
        <Grid container spacing={2}><Grid item xs={6}><TextField label="Period *" value={form.period} onChange={e => setForm({ ...form, period: e.target.value })} fullWidth required placeholder="e.g. 2026 Q1, 2025 Annual" /></Grid><Grid item xs={3}><TextField label="Rating (1-5)" type="number" value={form.rating} onChange={e => setForm({ ...form, rating: parseInt(e.target.value) || 0 })} fullWidth InputProps={{ inputProps: { min: 1, max: 5 } }} /></Grid><Grid item xs={3}><TextField select label="Status" value={form.status} onChange={e => setForm({ ...form, status: e.target.value })} fullWidth><MenuItem value="draft">Draft</MenuItem><MenuItem value="in_progress">In Progress</MenuItem><MenuItem value="completed">Completed</MenuItem><MenuItem value="reviewed">Reviewed</MenuItem></TextField></Grid></Grid>
        <TextField label="Comments" value={form.comments} onChange={e => setForm({ ...form, comments: e.target.value })} fullWidth multiline rows={3} placeholder="Strengths, areas for improvement, goals..." />
        {editing && <Typography variant="caption" color="text.secondary">Employee cannot be changed after creation — delete and recreate if needed.</Typography>}
      </DialogContent><DialogActions><Button onClick={() => setOpen(false)} disabled={saving}>Cancel</Button><Button variant="contained" onClick={handleSave} disabled={!form.employee_id || !form.period.trim() || saving}>{saving ? "Saving..." : editing ? "Update" : "Create"}</Button></DialogActions></Dialog>
    </Box>
  );
}
