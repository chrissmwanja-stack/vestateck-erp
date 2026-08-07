import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Dialog, DialogActions, DialogContent, DialogTitle, IconButton, Switch, Table, TableBody, TableCell, TableHead, TableRow, TextField, Typography, MenuItem } from "@mui/material";
import { Add, Edit, Delete } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { useAuth } from "../../../../../lib/authContext";

type LeadStatusEnum = 'new' | 'contacted' | 'qualified' | 'unqualified' | 'converted' | 'lost';
interface LeadStatus { id: string; tenant_id: string; status: LeadStatusEnum; label: string; color: string; order_index: number; is_active: boolean; }

const STATUS_OPTS: { value: LeadStatusEnum; label: string; color: string; order: number }[] = [
  { value: 'new', label: 'New', color: '#90caf9', order: 0 },
  { value: 'contacted', label: 'Contacted', color: '#fff176', order: 1 },
  { value: 'qualified', label: 'Qualified', color: '#81c784', order: 2 },
  { value: 'unqualified', label: 'Unqualified', color: '#bdbdbd', order: 3 },
  { value: 'converted', label: 'Converted', color: '#4caf50', order: 4 },
  { value: 'lost', label: 'Lost', color: '#e57373', order: 5 },
];

export default function LeadStatusesAdmin() {
  const { session } = useAuth();
  const [list, setList] = useState<LeadStatus[]>([]);
  const [loading, setLoading] = useState(true);
  const [open, setOpen] = useState(false);
  const [editing, setEditing] = useState<LeadStatus | null>(null);
  const [form, setForm] = useState<{ status: LeadStatusEnum; label: string; color: string; order_index: number; is_active: boolean }>({ status: 'new', label: 'New', color: '#90caf9', order_index: 0, is_active: true });

  const fetch = async () => {
    setLoading(true);
    const { data } = await supabase.from("bd_lead_statuses").select("*").order("order_index");
    if (data) setList(data as LeadStatus[]);
    setLoading(false);
  };
  useEffect(() => { fetch(); }, []);

  const handleOpenNew = () => { setEditing(null); setForm({ status: 'new', label: 'New', color: '#90caf9', order_index: list.length, is_active: true }); setOpen(true); };
  const handleOpenEdit = (s: LeadStatus) => { setEditing(s); setForm({ status: s.status, label: s.label, color: s.color, order_index: s.order_index, is_active: s.is_active }); setOpen(true); };

  const handleSave = async () => {
    const payload = { status: form.status, label: form.label.trim() || form.status, color: form.color, order_index: form.order_index, is_active: form.is_active };
    if (editing) {
      const { error } = await supabase.from("bd_lead_statuses").update(payload).eq("id", editing.id);
      if (error) { alert(error.message); return; }
    } else {
      const tenant_id = (session?.user?.user_metadata as any)?.tenant_id || list[0]?.tenant_id;
      const insertPayload: any = { ...payload };
      if (tenant_id) insertPayload.tenant_id = tenant_id;
      const { error } = await supabase.from("bd_lead_statuses").insert(insertPayload);
      if (error) { alert(error.message); return; }
    }
    setOpen(false); fetch();
  };

  const handleDelete = async (id: string) => {
    if (!confirm("Delete?")) return;
    const { error } = await supabase.from("bd_lead_statuses").delete().eq("id", id);
    if (error) alert(error.message); else fetch();
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 900 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3 }}>
        <Box><Typography variant="h5" fontWeight={700}>Lead Statuses</Typography><Typography variant="body2" color="text.secondary">Manage status labels, colors, order. Backs status chip in Leads list.</Typography></Box>
        <Button variant="contained" startIcon={<Add />} onClick={handleOpenNew}>New Status</Button>
      </Box>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Enum</TableCell><TableCell>Label</TableCell><TableCell>Order</TableCell><TableCell>Color</TableCell><TableCell>Active</TableCell><TableCell align="right">Actions</TableCell></TableRow></TableHead><TableBody>{list.length === 0 ? <TableRow><TableCell colSpan={6} sx={{ textAlign: "center", py: 4 }}><Typography color="text.secondary">No statuses. Seed defaults.</Typography><Button sx={{ mt: 2 }} variant="outlined" onClick={async () => { for (const opt of STATUS_OPTS) { await supabase.from("bd_lead_statuses").insert({ status: opt.value, label: opt.label, color: opt.color, order_index: opt.order, is_active: true, tenant_id: (session?.user?.user_metadata as any)?.tenant_id || undefined }); } setTimeout(fetch, 1000); }}>Seed 6 Statuses</Button></TableCell></TableRow> : list.map(s => <TableRow key={s.id} hover><TableCell><Chip label={s.status} size="small" variant="outlined" /></TableCell><TableCell><Typography fontWeight={600}>{s.label}</Typography></TableCell><TableCell>{s.order_index}</TableCell><TableCell><Box sx={{ width: 20, height: 20, borderRadius: "50%", bgcolor: s.color, border: "1px solid #ddd" }} /></TableCell><TableCell><Chip label={s.is_active ? "Active" : "Inactive"} size="small" color={s.is_active ? "success" : "default"} /></TableCell><TableCell align="right"><IconButton size="small" onClick={() => handleOpenEdit(s)}><Edit fontSize="small" /></IconButton><IconButton size="small" onClick={() => handleDelete(s.id)}><Delete fontSize="small" /></IconButton></TableCell></TableRow>)}</TableBody></Table></CardContent></Card>
      <Dialog open={open} onClose={() => setOpen(false)} maxWidth="sm" fullWidth><DialogTitle>{editing ? "Edit Status" : "New Status"}</DialogTitle><DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}><TextField select label="Status Enum" value={form.status} onChange={e => { const opt = STATUS_OPTS.find(o => o.value === e.target.value); setForm({ ...form, status: e.target.value as LeadStatusEnum, label: opt?.label || form.label, color: opt?.color || form.color }); }} fullWidth>{STATUS_OPTS.map(o => <MenuItem key={o.value} value={o.value}>{o.label} ({o.value})</MenuItem>)}</TextField><TextField label="Label" value={form.label} onChange={e => setForm({ ...form, label: e.target.value })} fullWidth /><TextField label="Order" type="number" value={form.order_index} onChange={e => setForm({ ...form, order_index: parseInt(e.target.value) || 0 })} fullWidth /><TextField label="Color" type="color" value={form.color} onChange={e => setForm({ ...form, color: e.target.value })} fullWidth sx={{ maxWidth: 150 }} /><Box sx={{ display: "flex", alignItems: "center", gap: 1 }}><Switch checked={form.is_active} onChange={e => setForm({ ...form, is_active: e.target.checked })} /><Typography variant="body2">Active</Typography></Box></DialogContent><DialogActions><Button onClick={() => setOpen(false)}>Cancel</Button><Button variant="contained" onClick={handleSave}>{editing ? "Update" : "Create"}</Button></DialogActions></Dialog>
    </Box>
  );
}
