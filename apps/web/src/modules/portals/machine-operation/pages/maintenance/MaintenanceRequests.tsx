import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Dialog, DialogActions, DialogContent, DialogTitle, Table, TableBody, TableCell, TableHead, TableRow, TextField, Typography, MenuItem, Alert, IconButton, Tooltip } from "@mui/material";
import { Add, Edit, Delete } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";

interface Machine { id: string; name: string; machine_no: string; }
interface MaintenanceType { id: string; name: string; }
interface MaintenanceRequest {
  id: string;
  tenant_id: string;
  machine_id: string;
  type: string | null;
  description: string | null;
  status: string | null;
  requested_by: string | null;
  scheduled_date: string | null;
  completed_date: string | null;
  created_at: string;
  machines?: { name: string; machine_no: string } | null;
}

const STATUS_OPTIONS = ["scheduled", "in_progress", "completed", "cancelled"] as const;
const emptyForm = { machine_id: "", type: "", description: "", status: "scheduled", scheduled_date: "" };

export default function MaintenanceRequests() {
  const [requests, setRequests] = useState<MaintenanceRequest[]>([]);
  const [machines, setMachines] = useState<Machine[]>([]);
  const [types, setTypes] = useState<MaintenanceType[]>([]);
  const [loading, setLoading] = useState(true);
  const [open, setOpen] = useState(false);
  const [editing, setEditing] = useState<MaintenanceRequest | null>(null);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [form, setForm] = useState(emptyForm);

  const fetchData = async () => {
    setLoading(true);
    const [reqRes, machinesRes, typesRes] = await Promise.all([
      supabase.from("maintenance_requests").select("*, machines(name, machine_no)").order("created_at", { ascending: false }).limit(200),
      supabase.from("machines").select("id, name, machine_no").order("name"),
      supabase.from("maintenance_types").select("id, name").eq("is_active", true).order("name"),
    ]);
    if (reqRes.data) {
      const normalized = (reqRes.data as any[]).map((r: any) => ({
        ...r,
        machines: Array.isArray(r.machines) ? r.machines[0] ?? null : r.machines ?? null,
      }));
      setRequests(normalized as MaintenanceRequest[]);
    }
    if (machinesRes.data) setMachines(machinesRes.data as Machine[]);
    if (typesRes.data) setTypes(typesRes.data as MaintenanceType[]);
    setLoading(false);
  };

  useEffect(() => { fetchData(); }, []);

  const openCreate = () => { setEditing(null); setForm(emptyForm); setError(null); setOpen(true); };
  const openEdit = (row: MaintenanceRequest) => {
    setEditing(row);
    setForm({ machine_id: row.machine_id || "", type: row.type || "", description: row.description || "", status: row.status || "scheduled", scheduled_date: row.scheduled_date || "" });
    setError(null);
    setOpen(true);
  };

  const handleSave = async () => {
    setError(null);
    if (!form.machine_id) { setError("Select a machine."); return; }
    if (!form.type) { setError("Select a maintenance type."); return; }
    setSaving(true);
    let res;
    if (editing) {
      const payload: any = { machine_id: form.machine_id, type: form.type, description: form.description.trim() || null, status: form.status, scheduled_date: form.scheduled_date || null };
      res = await supabase.from("maintenance_requests").update(payload).eq("id", editing.id);
    } else {
      const { data: { user } } = await supabase.auth.getUser();
      if (!user) { setSaving(false); setError("You need to be signed in."); return; }
      const { data: profile, error: profileError } = await supabase.from("app_users").select("tenant_id").eq("id", user.id).single();
      if (profileError || !profile?.tenant_id) { setSaving(false); setError(profileError?.message || "Could not determine organization."); return; }
      const payload: any = { machine_id: form.machine_id, type: form.type, description: form.description.trim() || null, status: form.status, requested_by: user.id, scheduled_date: form.scheduled_date || null, tenant_id: profile.tenant_id };
      res = await supabase.from("maintenance_requests").insert(payload);
    }
    setSaving(false);
    if (res.error) { setError(res.error.message); return; }
    setOpen(false);
    setEditing(null);
    setForm(emptyForm);
    fetchData();
  };

  const handleDelete = async (id: string) => {
    if (!window.confirm("Delete this request?")) return;
    const { error } = await supabase.from("maintenance_requests").delete().eq("id", id);
    if (error) alert(error.message);
    else fetchData();
  };

  const handleStatusQuick = async (row: MaintenanceRequest, newStatus: string) => {
    const { error } = await supabase.from("maintenance_requests").update({ status: newStatus }).eq("id", row.id);
    if (error) alert(error.message);
    else fetchData();
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  const statusColor = (status: string | null) => {
    if (status === "completed") return "success";
    if (status === "cancelled") return "default";
    if (status === "in_progress") return "warning";
    return "info";
  };

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3 }}>
        <Box><Typography variant="h5" fontWeight={700}>Maintenance Requests</Typography><Typography variant="body2" color="text.secondary">{requests.length} requests • Click status chip to advance, edit to correct details.</Typography></Box>
        <Button variant="contained" startIcon={<Add />} onClick={openCreate}>New Request</Button>
      </Box>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Machine</TableCell><TableCell>Type</TableCell><TableCell>Description</TableCell><TableCell>Status</TableCell><TableCell>Scheduled</TableCell><TableCell align="right">Actions</TableCell></TableRow></TableHead><TableBody>{requests.length === 0 ? <TableRow><TableCell colSpan={6} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No maintenance requests yet. Create breakdown or preventive requests.</Typography></TableCell></TableRow> : requests.map(r => <TableRow key={r.id} hover><TableCell>{r.machines ? `${r.machines.machine_no} - ${r.machines.name}` : "-"}</TableCell><TableCell sx={{ textTransform: "capitalize" }}>{r.type}</TableCell><TableCell><Typography variant="body2" sx={{ maxWidth: 300, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{r.description?.slice(0,80) || "-"}</Typography></TableCell><TableCell><Tooltip title="Click to change status"><Chip label={r.status} size="small" color={statusColor(r.status) as any} sx={{ textTransform: "capitalize", cursor: "pointer" }} onClick={() => { const next = r.status === "scheduled" ? "in_progress" : r.status === "in_progress" ? "completed" : "scheduled"; handleStatusQuick(r, next); }} /></Tooltip></TableCell><TableCell>{r.scheduled_date ? new Date(r.scheduled_date).toLocaleDateString() : "-"}</TableCell><TableCell align="right"><Tooltip title="Edit"><IconButton size="small" aria-label="Edit request" onClick={() => openEdit(r)}><Edit fontSize="small" /></IconButton></Tooltip><Tooltip title="Delete"><IconButton size="small" aria-label="Delete request" onClick={() => handleDelete(r.id)}><Delete fontSize="small" /></IconButton></Tooltip></TableCell></TableRow>)}</TableBody></Table></CardContent></Card>

      <Dialog open={open} onClose={() => !saving && setOpen(false)} maxWidth="sm" fullWidth>
        <DialogTitle>{editing ? "Edit Maintenance Request" : "New Maintenance Request"}</DialogTitle>
        <DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}>
          {error && <Alert severity="error">{error}</Alert>}
          <TextField select label="Machine *" value={form.machine_id} onChange={e => setForm({ ...form, machine_id: e.target.value })} fullWidth required>
            <MenuItem value="">-- Select Machine --</MenuItem>
            {machines.map(m => <MenuItem key={m.id} value={m.id}>{m.machine_no} - {m.name}</MenuItem>)}
          </TextField>
          <TextField select label="Type *" value={form.type} onChange={e => setForm({ ...form, type: e.target.value })} fullWidth required>
            <MenuItem value="">-- Select Type --</MenuItem>
            {types.map(t => <MenuItem key={t.id} value={t.name.toLowerCase()}>{t.name}</MenuItem>)}
          </TextField>
          <TextField label="Description" value={form.description} onChange={e => setForm({ ...form, description: e.target.value })} fullWidth multiline minRows={3} placeholder="Describe the issue or scope of work" />
          <TextField label="Scheduled Date" type="date" value={form.scheduled_date} onChange={e => setForm({ ...form, scheduled_date: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} />
          <TextField select label="Status" value={form.status} onChange={e => setForm({ ...form, status: e.target.value })} fullWidth>
            {STATUS_OPTIONS.map(s => <MenuItem key={s} value={s} sx={{ textTransform: "capitalize" }}>{s.replace("_", " ")}</MenuItem>)}
          </TextField>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setOpen(false)} disabled={saving}>Cancel</Button>
          <Button variant="contained" onClick={handleSave} disabled={saving || !form.machine_id || !form.type}>{saving ? "Saving..." : editing ? "Update" : "Create"}</Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}
