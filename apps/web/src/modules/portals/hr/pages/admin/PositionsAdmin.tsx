import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Dialog, DialogActions, DialogContent, DialogTitle, IconButton, Switch, Table, TableBody, TableCell, TableHead, TableRow, TextField, Typography, Chip, CircularProgress } from "@mui/material";
import { Add, Edit, Delete } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { useAuth } from "../../../../../lib/authContext";

interface Position {
  id: string;
  tenant_id: string;
  title: string;
  description: string | null;
  is_active: boolean;
  created_at: string;
}

export default function PositionsAdmin() {
  const { session } = useAuth();
  const [positions, setPositions] = useState<Position[]>([]);
  const [loading, setLoading] = useState(true);
  const [open, setOpen] = useState(false);
  const [editing, setEditing] = useState<Position | null>(null);
  const [form, setForm] = useState({ title: "", description: "", is_active: true });

  const fetchPositions = async () => {
    setLoading(true);
    const { data } = await supabase.from("hr_positions").select("*").order("title");
    if (data) setPositions(data as Position[]);
    setLoading(false);
  };

  useEffect(() => { fetchPositions(); }, []);

  const handleOpenNew = () => { setEditing(null); setForm({ title: "", description: "", is_active: true }); setOpen(true); };
  const handleOpenEdit = (p: Position) => { setEditing(p); setForm({ title: p.title, description: p.description || "", is_active: p.is_active }); setOpen(true); };

  const handleSave = async () => {
    if (!form.title.trim()) return;
    const payload = { title: form.title.trim(), description: form.description.trim() || null, is_active: form.is_active };
    if (editing) {
      const { error } = await supabase.from("hr_positions").update(payload).eq("id", editing.id);
      if (error) { alert(error.message); return; }
    } else {
      const tenant_id = (session?.user?.user_metadata as any)?.tenant_id || positions[0]?.tenant_id;
      const insertPayload: any = { ...payload };
      if (tenant_id) insertPayload.tenant_id = tenant_id;
      const { error } = await supabase.from("hr_positions").insert(insertPayload);
      if (error) { alert(error.message); return; }
    }
    setOpen(false); fetchPositions();
  };

  const handleDelete = async (id: string) => {
    if (!confirm("Delete position? Employees using it will block deletion.")) return;
    const { error } = await supabase.from("hr_positions").delete().eq("id", id);
    if (error) alert(`Cannot delete: ${error.message}`); else fetchPositions();
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 900 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3 }}>
        <Box>
          <Typography variant="h5" fontWeight={700}>Positions</Typography>
          <Typography variant="body2" color="text.secondary">Job titles / positions lookup. Backs Position dropdown on New Employee.</Typography>
        </Box>
        <Button variant="contained" startIcon={<Add />} onClick={handleOpenNew}>New Position</Button>
      </Box>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Title</TableCell><TableCell>Description</TableCell><TableCell>Active</TableCell><TableCell align="right">Actions</TableCell></TableRow></TableHead><TableBody>{positions.length === 0 ? <TableRow><TableCell colSpan={4} sx={{ textAlign: "center", py: 4 }}><Typography color="text.secondary">No positions yet. Create CEO, Project Manager, Engineer, Accountant, etc.</Typography></TableCell></TableRow> : positions.map(p => <TableRow key={p.id} hover><TableCell><Typography fontWeight={600}>{p.title}</Typography></TableCell><TableCell><Typography variant="body2" color="text.secondary">{p.description || "-"}</Typography></TableCell><TableCell><Chip label={p.is_active ? "Active" : "Inactive"} size="small" color={p.is_active ? "success" : "default"} /></TableCell><TableCell align="right"><IconButton size="small" onClick={() => handleOpenEdit(p)}><Edit fontSize="small" /></IconButton><IconButton size="small" onClick={() => handleDelete(p.id)}><Delete fontSize="small" /></IconButton></TableCell></TableRow>)}</TableBody></Table></CardContent></Card>
      <Dialog open={open} onClose={() => setOpen(false)} maxWidth="sm" fullWidth><DialogTitle>{editing ? "Edit Position" : "New Position"}</DialogTitle><DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}><TextField label="Title *" value={form.title} onChange={e => setForm({ ...form, title: e.target.value })} fullWidth autoFocus placeholder="e.g. Project Manager, Site Engineer" /><TextField label="Description" value={form.description} onChange={e => setForm({ ...form, description: e.target.value })} fullWidth multiline rows={2} /><Box sx={{ display: "flex", alignItems: "center", gap: 1 }}><Switch checked={form.is_active} onChange={e => setForm({ ...form, is_active: e.target.checked })} /><Typography variant="body2">Active</Typography></Box></DialogContent><DialogActions><Button onClick={() => setOpen(false)}>Cancel</Button><Button variant="contained" onClick={handleSave} disabled={!form.title.trim()}>{editing ? "Update" : "Create"}</Button></DialogActions></Dialog>
    </Box>
  );
}
