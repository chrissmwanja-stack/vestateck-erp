import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Dialog, DialogActions, DialogContent, DialogTitle, IconButton, Switch, Table, TableBody, TableCell, TableHead, TableRow, TextField, Typography, MenuItem } from "@mui/material";
import { Add, Edit, Delete } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { useAuth } from "../../../../../lib/authContext";

interface Department { id: string; tenant_id: string; name: string; parent_department_id: string | null; is_active: boolean; created_at: string; }

export default function HRDepartmentsAdmin() {
  const { session } = useAuth();
  const [depts, setDepts] = useState<Department[]>([]);
  const [loading, setLoading] = useState(true);
  const [open, setOpen] = useState(false);
  const [editing, setEditing] = useState<Department | null>(null);
  const [form, setForm] = useState({ name: "", parent_department_id: "", is_active: true });

  const fetchDepts = async () => {
    setLoading(true);
    const { data } = await supabase.from("departments").select("*").order("name");
    if (data) setDepts(data as Department[]);
    setLoading(false);
  };

  useEffect(() => { fetchDepts(); }, []);

  const handleOpenNew = () => { setEditing(null); setForm({ name: "", parent_department_id: "", is_active: true }); setOpen(true); };
  const handleOpenEdit = (d: Department) => { setEditing(d); setForm({ name: d.name, parent_department_id: d.parent_department_id || "", is_active: d.is_active }); setOpen(true); };

  const handleSave = async () => {
    if (!form.name.trim()) return;
    const payload: any = { name: form.name.trim(), parent_department_id: form.parent_department_id || null, is_active: form.is_active };
    if (editing) {
      const { error } = await supabase.from("departments").update(payload).eq("id", editing.id);
      if (error) { alert(error.message); return; }
    } else {
      const tenant_id = (session?.user?.user_metadata as any)?.tenant_id || depts[0]?.tenant_id;
      if (tenant_id) payload.tenant_id = tenant_id;
      const { error } = await supabase.from("departments").insert(payload);
      if (error) { alert(error.message); return; }
    }
    setOpen(false); fetchDepts();
  };

  const handleDelete = async (id: string) => {
    if (!confirm("Delete department? Employees using it will have it cleared.")) return;
    const { error } = await supabase.from("departments").delete().eq("id", id);
    if (error) alert(`Cannot delete: ${error.message}. Deactivate instead.`); else fetchDepts();
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 800 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3 }}>
        <Box><Typography variant="h5" fontWeight={700}>Departments</Typography><Typography variant="body2" color="text.secondary">HR departments lookup, hierarchical with parent. Backs Department dropdown on Employee.</Typography></Box>
        <Button variant="contained" startIcon={<Add />} onClick={handleOpenNew}>New Department</Button>
      </Box>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Name</TableCell><TableCell>Parent</TableCell><TableCell>Active</TableCell><TableCell align="right">Actions</TableCell></TableRow></TableHead><TableBody>{depts.length === 0 ? <TableRow><TableCell colSpan={4} sx={{ textAlign: "center", py: 4 }}><Typography color="text.secondary">No departments yet. Create Engineering, Finance, HR, Operations etc.</Typography></TableCell></TableRow> : depts.map(d => {
        const parent = depts.find(p => p.id === d.parent_department_id);
        return <TableRow key={d.id} hover><TableCell><Typography fontWeight={600}>{d.name}</Typography></TableCell><TableCell>{parent?.name || "-"}</TableCell><TableCell><Chip label={d.is_active ? "Active" : "Inactive"} size="small" color={d.is_active ? "success" : "default"} /></TableCell><TableCell align="right"><IconButton size="small" onClick={() => handleOpenEdit(d)}><Edit fontSize="small" /></IconButton><IconButton size="small" onClick={() => handleDelete(d.id)}><Delete fontSize="small" /></IconButton></TableCell></TableRow>;
      })}</TableBody></Table></CardContent></Card>
      <Dialog open={open} onClose={() => setOpen(false)} maxWidth="sm" fullWidth><DialogTitle>{editing ? "Edit Department" : "New Department"}</DialogTitle><DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}><TextField label="Name *" value={form.name} onChange={e => setForm({ ...form, name: e.target.value })} fullWidth autoFocus /><TextField select label="Parent Department" value={form.parent_department_id} onChange={e => setForm({ ...form, parent_department_id: e.target.value })} fullWidth><MenuItem value="">-- None (top level) --</MenuItem>{depts.filter(d => !editing || d.id !== editing.id).map(d => <MenuItem key={d.id} value={d.id}>{d.name}</MenuItem>)}</TextField><Box sx={{ display: "flex", alignItems: "center", gap: 1 }}><Switch checked={form.is_active} onChange={e => setForm({ ...form, is_active: e.target.checked })} /><Typography variant="body2">Active</Typography></Box></DialogContent><DialogActions><Button onClick={() => setOpen(false)}>Cancel</Button><Button variant="contained" onClick={handleSave} disabled={!form.name.trim()}>{editing ? "Update" : "Create"}</Button></DialogActions></Dialog>
    </Box>
  );
}