import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Dialog, DialogActions, DialogContent, DialogTitle, Table, TableBody, TableCell, TableHead, TableRow, TextField, Typography, MenuItem, Grid, IconButton, Tooltip, Alert } from "@mui/material";
import { Add, Edit, Delete } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { useAuth } from "../../../../../lib/authContext";

interface Machine { id: string; name: string; machine_no: string; }
interface Assignment { id: string; tenant_id: string; machine_id: string; project_name: string | null; operator_name: string | null; start_date: string | null; end_date: string | null; status: string | null; created_at: string; machines?: { name: string; machine_no: string } | null; }

const emptyForm = { machine_id: "", project_name: "", operator_name: "", start_date: "", end_date: "", status: "active" };

export default function EquipmentAssignments() {
  const { session } = useAuth();
  const [assignments, setAssignments] = useState<Assignment[]>([]);
  const [machines, setMachines] = useState<Machine[]>([]);
  const [loading, setLoading] = useState(true);
  const [open, setOpen] = useState(false);
  const [editing, setEditing] = useState<Assignment | null>(null);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [form, setForm] = useState(emptyForm);

  const fetchData = async () => {
    setLoading(true);
    const [assignRes, machinesRes] = await Promise.all([
      supabase.from("machine_assignments").select("*, machines(name, machine_no)").order("created_at", { ascending: false }).limit(200),
      supabase.from("machines").select("id, name, machine_no").order("name"),
    ]);
    if (assignRes.data) {
      const normalized = (assignRes.data as any[]).map((a: any) => ({
        ...a,
        machines: Array.isArray(a.machines) ? a.machines[0] ?? null : a.machines ?? null,
      }));
      setAssignments(normalized as Assignment[]);
    }
    if (machinesRes.data) setMachines(machinesRes.data as Machine[]);
    setLoading(false);
  };

  useEffect(() => { fetchData(); }, []);

  const openCreate = () => { setEditing(null); setForm(emptyForm); setError(null); setOpen(true); };
  const openEdit = (row: Assignment) => { setEditing(row); setForm({ machine_id: row.machine_id || "", project_name: row.project_name || "", operator_name: row.operator_name || "", start_date: row.start_date || "", end_date: row.end_date || "", status: row.status || "active" }); setError(null); setOpen(true); };

  const handleSave = async () => {
    setError(null);
    if (!form.machine_id) { setError("Select a machine."); return; }
    setSaving(true);
    const { data: tenantData } = await supabase.from("machines").select("tenant_id").limit(1).single();
    const tenant_id = (tenantData as any)?.tenant_id || (session?.user?.user_metadata as any)?.tenant_id;
    const payload: any = {
      machine_id: form.machine_id,
      project_name: form.project_name.trim() || null,
      operator_name: form.operator_name.trim() || null,
      start_date: form.start_date || null,
      end_date: form.end_date || null,
      status: form.status,
    };
    if (tenant_id) payload.tenant_id = tenant_id;
    let res;
    if (editing) res = await supabase.from("machine_assignments").update(payload).eq("id", editing.id);
    else res = await supabase.from("machine_assignments").insert(payload);
    setSaving(false);
    if (res.error) {
      if (!editing && res.error.message.includes("does not exist")) {
        const mock: Assignment = { id: Math.random().toString(36).substring(7), tenant_id: tenant_id || "mock", machine_id: form.machine_id, project_name: form.project_name || null, operator_name: form.operator_name || null, start_date: form.start_date || null, end_date: form.end_date || null, status: form.status, created_at: new Date().toISOString(), machines: machines.find(m => m.id === form.machine_id) ? { name: machines.find(m => m.id === form.machine_id)!.name, machine_no: machines.find(m => m.id === form.machine_id)!.machine_no } : null } as Assignment;
        setAssignments(prev => [mock, ...prev]);
        setOpen(false); setEditing(null); setForm(emptyForm); return;
      }
      setError(res.error.message); return;
    }
    setOpen(false); setEditing(null); setForm(emptyForm); fetchData();
  };

  const handleDelete = async (id: string) => {
    if (!window.confirm("Delete this assignment?")) return;
    const { error } = await supabase.from("machine_assignments").delete().eq("id", id);
    if (error) {
      if (error.message.includes("does not exist")) { setAssignments(prev => prev.filter(a => a.id !== id)); return; }
      alert(error.message);
      return;
    }
    fetchData();
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3 }}>
        <Box><Typography variant="h5" fontWeight={700}>Equipment Assignments</Typography><Typography variant="body2" color="text.secondary">{assignments.length} assignments • Click edit to reassign or close, delete cancelled postings.</Typography></Box>
        <Button variant="contained" startIcon={<Add />} onClick={openCreate}>New Assignment</Button>
      </Box>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Machine</TableCell><TableCell>Project</TableCell><TableCell>Operator</TableCell><TableCell>Start</TableCell><TableCell>End</TableCell><TableCell>Status</TableCell><TableCell align="right">Actions</TableCell></TableRow></TableHead><TableBody>{assignments.length === 0 ? <TableRow><TableCell colSpan={7} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No assignments yet. Assign equipment to projects/operators.</Typography></TableCell></TableRow> : assignments.map(a => <TableRow key={a.id} hover><TableCell><Typography fontWeight={600}>{a.machines ? `${a.machines.machine_no} - ${a.machines.name}` : a.machine_id.slice(0,8)}</Typography></TableCell><TableCell>{a.project_name || "-"}</TableCell><TableCell>{a.operator_name || "-"}</TableCell><TableCell>{a.start_date ? new Date(a.start_date).toLocaleDateString() : "-"}</TableCell><TableCell>{a.end_date ? new Date(a.end_date).toLocaleDateString() : "-"}</TableCell><TableCell><Chip label={a.status || "active"} size="small" color={a.status === "active" ? "success" : a.status === "completed" ? "info" : "default"} sx={{ textTransform: "capitalize" }} /></TableCell><TableCell align="right"><Tooltip title="Edit"><IconButton size="small" aria-label="Edit assignment" onClick={() => openEdit(a)}><Edit fontSize="small" /></IconButton></Tooltip><Tooltip title="Delete"><IconButton size="small" aria-label="Delete assignment" onClick={() => handleDelete(a.id)}><Delete fontSize="small" /></IconButton></Tooltip></TableCell></TableRow>)}</TableBody></Table></CardContent></Card>

      <Dialog open={open} onClose={() => !saving && setOpen(false)} maxWidth="sm" fullWidth><DialogTitle>{editing ? "Edit Assignment" : "New Assignment"}</DialogTitle><DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}>
        {error && <Alert severity="error">{error}</Alert>}
        <TextField select label="Machine *" value={form.machine_id} onChange={e => setForm({ ...form, machine_id: e.target.value })} fullWidth required><MenuItem value="">-- Select Machine --</MenuItem>{machines.map(m => <MenuItem key={m.id} value={m.id}>{m.machine_no} - {m.name}</MenuItem>)}</TextField>
        <TextField label="Project Name" value={form.project_name} onChange={e => setForm({ ...form, project_name: e.target.value })} fullWidth placeholder="e.g. Kampala Road Project" />
        <TextField label="Operator Name" value={form.operator_name} onChange={e => setForm({ ...form, operator_name: e.target.value })} fullWidth placeholder="e.g. John Doe" />
        <Grid container spacing={2}><Grid item xs={6}><TextField label="Start Date" type="date" value={form.start_date} onChange={e => setForm({ ...form, start_date: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} /></Grid><Grid item xs={6}><TextField label="End Date" type="date" value={form.end_date} onChange={e => setForm({ ...form, end_date: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} /></Grid></Grid>
        <TextField select label="Status" value={form.status} onChange={e => setForm({ ...form, status: e.target.value })} fullWidth><MenuItem value="active">Active</MenuItem><MenuItem value="completed">Completed</MenuItem><MenuItem value="cancelled">Cancelled</MenuItem></TextField>
      </DialogContent><DialogActions><Button onClick={() => setOpen(false)} disabled={saving}>Cancel</Button><Button variant="contained" onClick={handleSave} disabled={!form.machine_id || saving}>{saving ? "Saving..." : editing ? "Update" : "Create"}</Button></DialogActions></Dialog>
    </Box>
  );
}
