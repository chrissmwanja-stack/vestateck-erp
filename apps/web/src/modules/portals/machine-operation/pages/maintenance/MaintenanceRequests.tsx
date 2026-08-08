import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Dialog, DialogActions, DialogContent, DialogTitle, Table, TableBody, TableCell, TableHead, TableRow, TextField, Typography, MenuItem, Alert } from "@mui/material";
import { Add } from "@mui/icons-material";
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

export default function MaintenanceRequests() {
  const [requests, setRequests] = useState<MaintenanceRequest[]>([]);
  const [machines, setMachines] = useState<Machine[]>([]);
  const [types, setTypes] = useState<MaintenanceType[]>([]);
  const [loading, setLoading] = useState(true);
  const [open, setOpen] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [form, setForm] = useState({ machine_id: "", type: "", description: "", status: "scheduled", scheduled_date: "" });

  const fetchData = async () => {
    setLoading(true);
    const [reqRes, machinesRes, typesRes] = await Promise.all([
      supabase.from("maintenance_requests").select("*, machines(name, machine_no)").order("created_at", { ascending: false }).limit(100),
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

  const resetForm = () => setForm({ machine_id: "", type: "", description: "", status: "scheduled", scheduled_date: "" });

  const handleSave = async () => {
    setError(null);
    if (!form.machine_id) { setError("Select a machine."); return; }
    if (!form.type) { setError("Select a maintenance type."); return; }
    setSaving(true);

    const { data: { user } } = await supabase.auth.getUser();
    if (!user) {
      setSaving(false);
      setError("You need to be signed in to file a maintenance request.");
      return;
    }

    // tenant_id is read from the requester's own app_users row, same
    // pattern used for it_tickets in NewTicket.tsx -- requested_by is the
    // auth uid directly since app_users.id === auth.uid().
    const { data: profile, error: profileError } = await supabase
      .from("app_users")
      .select("tenant_id")
      .eq("id", user.id)
      .single();

    const payload: any = {
      machine_id: form.machine_id,
      type: form.type,
      description: form.description.trim() || null,
      status: form.status,
      requested_by: user.id,
      scheduled_date: form.scheduled_date || null,
    };
    if (profile?.tenant_id) payload.tenant_id = profile.tenant_id;
    else if (profileError) {
      setSaving(false);
      setError(profileError.message);
      return;
    }

    const { error: insertError } = await supabase.from("maintenance_requests").insert(payload);
    setSaving(false);
    if (insertError) {
      setError(insertError.message);
      return;
    }
    setOpen(false);
    resetForm();
    fetchData();
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  const statusColor = (status: string | null) => {
    if (status === "completed") return "success";
    if (status === "cancelled") return "default";
    if (status === "in_progress") return "warning";
    return "info";
  };

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3 }}>
        <Box><Typography variant="h5" fontWeight={700}>Maintenance Requests</Typography><Typography variant="body2" color="text.secondary">{requests.length} requests</Typography></Box>
        <Button variant="contained" startIcon={<Add />} onClick={() => { setError(null); setOpen(true); }}>New Request</Button>
      </Box>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Machine</TableCell><TableCell>Type</TableCell><TableCell>Description</TableCell><TableCell>Status</TableCell><TableCell>Scheduled</TableCell></TableRow></TableHead><TableBody>{requests.length === 0 ? <TableRow><TableCell colSpan={5} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No maintenance requests yet. Create breakdown or preventive requests.</Typography></TableCell></TableRow> : requests.map(r => <TableRow key={r.id} hover><TableCell>{r.machines ? `${r.machines.machine_no} - ${r.machines.name}` : "-"}</TableCell><TableCell sx={{ textTransform: "capitalize" }}>{r.type}</TableCell><TableCell>{r.description?.slice(0,80) || "-"}</TableCell><TableCell><Chip label={r.status} size="small" color={statusColor(r.status) as any} sx={{ textTransform: "capitalize" }} /></TableCell><TableCell>{r.scheduled_date ? new Date(r.scheduled_date).toLocaleDateString() : "-"}</TableCell></TableRow>)}</TableBody></Table></CardContent></Card>

      <Dialog open={open} onClose={() => setOpen(false)} maxWidth="sm" fullWidth>
        <DialogTitle>New Maintenance Request</DialogTitle>
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
          <Button onClick={() => setOpen(false)}>Cancel</Button>
          <Button variant="contained" onClick={handleSave} disabled={saving || !form.machine_id || !form.type}>{saving ? "Saving..." : "Create"}</Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}