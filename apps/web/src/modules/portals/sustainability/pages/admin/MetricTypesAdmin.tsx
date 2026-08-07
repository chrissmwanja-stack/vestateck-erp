import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Dialog, DialogActions, DialogContent, DialogTitle, IconButton, Switch, Table, TableBody, TableCell, TableHead, TableRow, TextField, Typography } from "@mui/material";
import { Add, Edit, Delete } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { useAuth } from "../../../../../lib/authContext";
interface MetricType { id: string; tenant_id: string; name: string; unit: string; type: string; is_active: boolean; }
export default function MetricTypesAdmin() {
  const { session } = useAuth();
  const [types, setTypes] = useState<MetricType[]>([]);
  const [loading, setLoading] = useState(true);
  const [open, setOpen] = useState(false);
  const [editing, setEditing] = useState<MetricType | null>(null);
  const [form, setForm] = useState({ name: "", unit: "", type: "carbon", is_active: true });
  const fetchTypes = async () => { setLoading(true); const { data } = await supabase.from("sustainability_metric_types").select("*").order("name"); if (data) setTypes(data as MetricType[]); setLoading(false); };
  useEffect(() => { fetchTypes(); }, []);
  const handleOpenNew = () => { setEditing(null); setForm({ name: "", unit: "", type: "carbon", is_active: true }); setOpen(true); };
  const handleOpenEdit = (t: MetricType) => { setEditing(t); setForm({ name: t.name, unit: t.unit, type: t.type, is_active: t.is_active }); setOpen(true); };
  const handleSave = async () => {
    if (!form.name.trim()) return;
    const payload = { name: form.name.trim(), unit: form.unit.trim() || null, type: form.type, is_active: form.is_active };
    if (editing) { const { error } = await supabase.from("sustainability_metric_types").update(payload).eq("id", editing.id); if (error) { alert(error.message); return; } }
    else { const tenant_id = (session?.user?.user_metadata as any)?.tenant_id || types[0]?.tenant_id; const insertPayload: any = { ...payload }; if (tenant_id) insertPayload.tenant_id = tenant_id; const { error } = await supabase.from("sustainability_metric_types").insert(insertPayload); if (error) { alert(error.message); return; } }
    setOpen(false); fetchTypes();
  };
  const handleDelete = async (id: string) => { if (!confirm("Delete type?")) return; const { error } = await supabase.from("sustainability_metric_types").delete().eq("id", id); if (error) alert(`Cannot delete: ${error.message}`); else fetchTypes(); };
  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;
  return (
    <Box sx={{ p: 3, maxWidth: 800 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3 }}><Box><Typography variant="h5" fontWeight={700}>Metric Types</Typography><Typography variant="body2" color="text.secondary">Carbon, Energy, Water, Waste, etc.</Typography></Box><Button variant="contained" startIcon={<Add />} onClick={handleOpenNew}>New Type</Button></Box>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Name</TableCell><TableCell>Unit</TableCell><TableCell>Type</TableCell><TableCell>Active</TableCell><TableCell align="right">Actions</TableCell></TableRow></TableHead><TableBody>{types.length === 0 ? <TableRow><TableCell colSpan={5} sx={{ textAlign: "center", py: 4 }}><Typography color="text.secondary">No types yet. Create Carbon tCO2e, Energy kWh, Water m3, Waste kg.</Typography></TableCell></TableRow> : types.map(t => <TableRow key={t.id} hover><TableCell><Typography fontWeight={600}>{t.name}</Typography></TableCell><TableCell>{t.unit || "-"}</TableCell><TableCell><Chip label={t.type} size="small" variant="outlined" /></TableCell><TableCell><Chip label={t.is_active ? "Active" : "Inactive"} size="small" color={t.is_active ? "success" : "default"} /></TableCell><TableCell align="right"><IconButton size="small" onClick={() => handleOpenEdit(t)}><Edit fontSize="small" /></IconButton><IconButton size="small" onClick={() => handleDelete(t.id)}><Delete fontSize="small" /></IconButton></TableCell></TableRow>)}</TableBody></Table></CardContent></Card>
      <Dialog open={open} onClose={() => setOpen(false)} maxWidth="sm" fullWidth><DialogTitle>{editing ? "Edit Type" : "New Type"}</DialogTitle><DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}><TextField label="Name *" value={form.name} onChange={e => setForm({ ...form, name: e.target.value })} fullWidth autoFocus placeholder="Carbon, Energy, Waste" /><TextField label="Unit" value={form.unit} onChange={e => setForm({ ...form, unit: e.target.value })} fullWidth placeholder="tCO2e, kWh, kg, m3" /><TextField label="Category" value={form.type} onChange={e => setForm({ ...form, type: e.target.value })} fullWidth placeholder="carbon, energy, water, waste" /><Box sx={{ display: "flex", alignItems: "center", gap: 1 }}><Switch checked={form.is_active} onChange={e => setForm({ ...form, is_active: e.target.checked })} /><Typography variant="body2">Active</Typography></Box></DialogContent><DialogActions><Button onClick={() => setOpen(false)}>Cancel</Button><Button variant="contained" onClick={handleSave} disabled={!form.name.trim()}>{editing ? "Update" : "Create"}</Button></DialogActions></Dialog>
    </Box>
  );
}
