import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Dialog, DialogActions, DialogContent, DialogTitle, IconButton, Switch, Table, TableBody, TableCell, TableHead, TableRow, TextField, Typography, Chip, CircularProgress } from "@mui/material";
import { Add, Edit, Delete } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { useAuth } from "../../../../../lib/authContext";

interface ProposalType { id: string; tenant_id: string; name: string; description: string | null; is_active: boolean; created_at: string; }

export default function ProposalTypesAdmin() {
  const { session } = useAuth();
  const [types, setTypes] = useState<ProposalType[]>([]);
  const [loading, setLoading] = useState(true);
  const [open, setOpen] = useState(false);
  const [editing, setEditing] = useState<ProposalType | null>(null);
  const [form, setForm] = useState({ name: "", description: "", is_active: true });

  const fetch = async () => {
    setLoading(true);
    const { data } = await supabase.from("bd_proposal_types").select("*").order("name");
    if (data) setTypes(data as ProposalType[]);
    setLoading(false);
  };
  useEffect(() => { fetch(); }, []);

  const handleOpenNew = () => { setEditing(null); setForm({ name: "", description: "", is_active: true }); setOpen(true); };
  const handleOpenEdit = (t: ProposalType) => { setEditing(t); setForm({ name: t.name, description: t.description || "", is_active: t.is_active }); setOpen(true); };

  const handleSave = async () => {
    if (!form.name.trim()) return;
    const payload = { name: form.name.trim(), description: form.description.trim() || null, is_active: form.is_active };
    if (editing) {
      const { error } = await supabase.from("bd_proposal_types").update(payload).eq("id", editing.id);
      if (error) { alert(error.message); return; }
    } else {
      const tenant_id = (session?.user?.user_metadata as any)?.tenant_id || types[0]?.tenant_id;
      const insertPayload: any = { ...payload };
      if (tenant_id) insertPayload.tenant_id = tenant_id;
      const { error } = await supabase.from("bd_proposal_types").insert(insertPayload);
      if (error) { alert(error.message); return; }
    }
    setOpen(false); fetch();
  };

  const handleDelete = async (id: string) => {
    if (!confirm("Delete? Proposals using this type will block deletion. Deactivate instead?")) return;
    const { error } = await supabase.from("bd_proposal_types").delete().eq("id", id);
    if (error) alert(`Cannot delete: ${error.message}`); else fetch();
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 900 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3 }}>
        <Box>
          <Typography variant="h5" fontWeight={700}>Proposal Types</Typography>
          <Typography variant="body2" color="text.secondary">Backs Type dropdown on New Proposal. e.g. Technical, Financial, Combined, BOQ.</Typography>
        </Box>
        <Button variant="contained" startIcon={<Add />} onClick={handleOpenNew}>New Type</Button>
      </Box>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Name</TableCell><TableCell>Description</TableCell><TableCell>Active</TableCell><TableCell align="right">Actions</TableCell></TableRow></TableHead><TableBody>{types.length === 0 ? <TableRow><TableCell colSpan={4} sx={{ textAlign: "center", py: 4 }}><Typography color="text.secondary">No types yet. Create Technical, Financial, Combined, BOQ.</Typography></TableCell></TableRow> : types.map(t => <TableRow key={t.id} hover><TableCell><Typography fontWeight={600}>{t.name}</Typography></TableCell><TableCell><Typography variant="body2" color="text.secondary">{t.description || "-"}</Typography></TableCell><TableCell><Chip label={t.is_active ? "Active" : "Inactive"} size="small" color={t.is_active ? "success" : "default"} /></TableCell><TableCell align="right"><IconButton size="small" onClick={() => handleOpenEdit(t)}><Edit fontSize="small" /></IconButton><IconButton size="small" onClick={() => handleDelete(t.id)}><Delete fontSize="small" /></IconButton></TableCell></TableRow>)}</TableBody></Table></CardContent></Card>
      <Dialog open={open} onClose={() => setOpen(false)} maxWidth="sm" fullWidth><DialogTitle>{editing ? "Edit Type" : "New Type"}</DialogTitle><DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}><TextField label="Name *" value={form.name} onChange={e => setForm({ ...form, name: e.target.value })} fullWidth autoFocus placeholder="Technical, Financial, Combined" /><TextField label="Description" value={form.description} onChange={e => setForm({ ...form, description: e.target.value })} fullWidth multiline rows={2} /><Box sx={{ display: "flex", alignItems: "center", gap: 1 }}><Switch checked={form.is_active} onChange={e => setForm({ ...form, is_active: e.target.checked })} /><Typography variant="body2">Active</Typography></Box></DialogContent><DialogActions><Button onClick={() => setOpen(false)}>Cancel</Button><Button variant="contained" onClick={handleSave} disabled={!form.name.trim()}>{editing ? "Update" : "Create"}</Button></DialogActions></Dialog>
    </Box>
  );
}
