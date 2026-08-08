import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Dialog, DialogActions, DialogContent, DialogTitle, IconButton, Table, TableBody, TableCell, TableHead, TableRow, TextField, Typography, MenuItem, Grid } from "@mui/material";
import { Add, Edit, Delete } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { useAuth } from "../../../../../lib/authContext";

interface MachineType { id: string; name: string; }
interface Machine {
  id: string;
  tenant_id: string;
  machine_no: string;
  name: string;
  type_id: string | null;
  model: string | null;
  status: string;
  location: string | null;
  created_at: string;
  machine_types?: { name: string } | null;
}

export default function EquipmentList() {
  const { session } = useAuth();
  const [machines, setMachines] = useState<Machine[]>([]);
  const [types, setTypes] = useState<MachineType[]>([]);
  const [loading, setLoading] = useState(true);
  const [open, setOpen] = useState(false);
  const [editing, setEditing] = useState<Machine | null>(null);
  const [form, setForm] = useState({ name: "", type_id: "", model: "", serial_number: "", status: "available", location: "" });

  const fetchData = async () => {
    setLoading(true);
    const [machinesRes, typesRes] = await Promise.all([
      supabase.from("machines").select("*, machine_types(name)").order("created_at", { ascending: false }).limit(100),
      supabase.from("machine_types").select("id, name").eq("is_active", true).order("name"),
    ]);
    if (machinesRes.data) {
      const normalized = (machinesRes.data as any[]).map((m: any) => ({
        ...m,
        machine_types: Array.isArray(m.machine_types) ? m.machine_types[0] ?? null : m.machine_types ?? null,
      }));
      setMachines(normalized as Machine[]);
    }
    if (typesRes.data) setTypes(typesRes.data as MachineType[]);
    setLoading(false);
  };

  useEffect(() => { fetchData(); }, []);

  const handleOpenNew = () => { setEditing(null); setForm({ name: "", type_id: "", model: "", serial_number: "", status: "available", location: "" }); setOpen(true); };
  const handleOpenEdit = (m: Machine) => { setEditing(m); setForm({ name: m.name, type_id: m.type_id || "", model: m.model || "", serial_number: (m as any).serial_number || "", status: m.status, location: m.location || "" }); setOpen(true); };

  const handleSave = async () => {
    if (!form.name.trim()) return;
    const payload: any = {
      name: form.name.trim(),
      type_id: form.type_id || null,
      model: form.model.trim() || null,
      serial_number: form.serial_number.trim() || null,
      status: form.status,
      location: form.location.trim() || null,
    };
    if (editing) {
      const { error } = await supabase.from("machines").update(payload).eq("id", editing.id);
      if (error) { alert(error.message); return; }
    } else {
      const tenant_id = (session?.user?.user_metadata as any)?.tenant_id || machines[0]?.tenant_id;
      if (tenant_id) payload.tenant_id = tenant_id;
      const { error } = await supabase.from("machines").insert(payload);
      if (error) { alert(error.message); return; }
    }
    setOpen(false); fetchData();
  };

  const handleDelete = async (id: string) => {
    if (!confirm("Delete machine? Assignments and logs using it will block deletion.")) return;
    const { error } = await supabase.from("machines").delete().eq("id", id);
    if (error) alert(`Cannot delete: ${error.message}`); else fetchData();
  };

  const getStatusColor = (s: string) => {
    if (s === 'available') return 'success';
    if (s === 'in_use') return 'primary';
    if (s === 'breakdown') return 'error';
    return 'warning';
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3 }}>
        <Box><Typography variant="h5" fontWeight={700}>Equipment List</Typography><Typography variant="body2" color="text.secondary">{machines.length} machines • Machine No auto generation, type lookup from Admin → Machine Types</Typography></Box>
        <Button variant="contained" startIcon={<Add />} onClick={handleOpenNew}>New Equipment</Button>
      </Box>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Machine No</TableCell><TableCell>Name</TableCell><TableCell>Type</TableCell><TableCell>Model</TableCell><TableCell>Status</TableCell><TableCell>Location</TableCell><TableCell align="right">Actions</TableCell></TableRow></TableHead><TableBody>{machines.length === 0 ? <TableRow><TableCell colSpan={7} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No machines yet. Create first via New Equipment — needs Machine Type lookup you built.</Typography></TableCell></TableRow> : machines.map(m => <TableRow key={m.id} hover><TableCell><Typography fontFamily="monospace" fontWeight={600}>{m.machine_no || m.id.slice(0,8)}</Typography></TableCell><TableCell><Typography fontWeight={600}>{m.name}</Typography></TableCell><TableCell>{m.machine_types?.name || "-"}</TableCell><TableCell>{m.model || "-"}</TableCell><TableCell><Chip label={m.status} size="small" color={getStatusColor(m.status) as any} sx={{ textTransform: "capitalize" }} /></TableCell><TableCell>{m.location || "-"}</TableCell><TableCell align="right"><IconButton size="small" onClick={() => handleOpenEdit(m)}><Edit fontSize="small" /></IconButton><IconButton size="small" onClick={() => handleDelete(m.id)}><Delete fontSize="small" /></IconButton></TableCell></TableRow>)}</TableBody></Table></CardContent></Card>

      <Dialog open={open} onClose={() => setOpen(false)} maxWidth="sm" fullWidth><DialogTitle>{editing ? "Edit Equipment" : "New Equipment"}</DialogTitle><DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}><TextField label="Name *" value={form.name} onChange={e => setForm({ ...form, name: e.target.value })} fullWidth autoFocus placeholder="e.g. CAT Excavator 320D" /><Grid container spacing={2}><Grid item xs={6}><TextField select label="Type" value={form.type_id} onChange={e => setForm({ ...form, type_id: e.target.value })} fullWidth><MenuItem value="">-- None --</MenuItem>{types.map(t => <MenuItem key={t.id} value={t.id}>{t.name}</MenuItem>)}</TextField></Grid><Grid item xs={6}><TextField select label="Status" value={form.status} onChange={e => setForm({ ...form, status: e.target.value })} fullWidth><MenuItem value="available">Available</MenuItem><MenuItem value="in_use">In Use</MenuItem><MenuItem value="maintenance">Maintenance</MenuItem><MenuItem value="breakdown">Breakdown</MenuItem><MenuItem value="retired">Retired</MenuItem></TextField></Grid></Grid><TextField label="Model" value={form.model} onChange={e => setForm({ ...form, model: e.target.value })} fullWidth placeholder="e.g. 320D" /><TextField label="Serial Number" value={form.serial_number} onChange={e => setForm({ ...form, serial_number: e.target.value })} fullWidth placeholder="e.g. SN123456" /><TextField label="Location" value={form.location} onChange={e => setForm({ ...form, location: e.target.value })} fullWidth placeholder="e.g. Kampala Site A" /></DialogContent><DialogActions><Button onClick={() => setOpen(false)}>Cancel</Button><Button variant="contained" onClick={handleSave} disabled={!form.name.trim()}>{editing ? "Update" : "Create"}</Button></DialogActions></Dialog>
    </Box>
  );
}
