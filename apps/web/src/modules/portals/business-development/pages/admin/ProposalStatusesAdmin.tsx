import { useEffect, useState } from "react";
import {
  Box,
  Button,
  Card,
  CardContent,
  Chip,
  CircularProgress,
  Dialog,
  DialogActions,
  DialogContent,
  DialogTitle,
  IconButton,
  Switch,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableRow,
  TextField,
  Typography,
  MenuItem,
} from "@mui/material";
import { Add, Edit, Delete } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { useAuth } from "../../../../../lib/authContext";

type ProposalStatusEnum = 'draft' | 'in_review' | 'pending_approval' | 'approved' | 'sent' | 'accepted' | 'rejected' | 'expired';
interface ProposalStatus { id: string; tenant_id: string; status: ProposalStatusEnum; label: string; color: string; order_index: number; is_active: boolean; }

const STATUS_OPTIONS: { value: ProposalStatusEnum; label: string; color: string }[] = [
  { value: 'draft', label: 'Draft', color: '#bdbdbd' },
  { value: 'in_review', label: 'In Review', color: '#ffcc80' },
  { value: 'pending_approval', label: 'Pending Approval', color: '#fff176' },
  { value: 'approved', label: 'Approved', color: '#81c784' },
  { value: 'sent', label: 'Sent', color: '#64b5f6' },
  { value: 'accepted', label: 'Accepted', color: '#4caf50' },
  { value: 'rejected', label: 'Rejected', color: '#e57373' },
  { value: 'expired', label: 'Expired', color: '#9e9e9e' },
];

export default function ProposalStatusesAdmin() {
  const { session } = useAuth();
  const [list, setList] = useState<ProposalStatus[]>([]);
  const [loading, setLoading] = useState(true);
  const [open, setOpen] = useState(false);
  const [editing, setEditing] = useState<ProposalStatus | null>(null);
  const [form, setForm] = useState<{ status: ProposalStatusEnum; label: string; color: string; order_index: number; is_active: boolean }>({ status: 'draft', label: 'Draft', color: '#bdbdbd', order_index: 0, is_active: true });

  const fetch = async () => {
    setLoading(true);
    const { data } = await supabase.from("bd_proposal_statuses").select("*").order("order_index");
    if (data) setList(data as ProposalStatus[]);
    setLoading(false);
  };
  useEffect(() => { fetch(); }, []);

  const handleOpenNew = () => { setEditing(null); setForm({ status: 'draft', label: 'Draft', color: '#bdbdbd', order_index: list.length, is_active: true }); setOpen(true); };
  const handleOpenEdit = (s: ProposalStatus) => { setEditing(s); setForm({ status: s.status, label: s.label, color: s.color, order_index: s.order_index, is_active: s.is_active }); setOpen(true); };

  const handleSave = async () => {
    const payload = { status: form.status, label: form.label.trim() || form.status, color: form.color, order_index: form.order_index, is_active: form.is_active };
    if (editing) {
      const { error } = await supabase.from("bd_proposal_statuses").update(payload).eq("id", editing.id);
      if (error) { alert(error.message); return; }
    } else {
      const tenant_id = (session?.user?.user_metadata as any)?.tenant_id || list[0]?.tenant_id;
      const insertPayload: any = { ...payload };
      if (tenant_id) insertPayload.tenant_id = tenant_id;
      const { error } = await supabase.from("bd_proposal_statuses").insert(insertPayload);
      if (error) { alert(error.message); return; }
    }
    setOpen(false); fetch();
  };

  const handleDelete = async (id: string) => {
    if (!confirm("Delete status?")) return;
    const { error } = await supabase.from("bd_proposal_statuses").delete().eq("id", id);
    if (error) alert(error.message); else fetch();
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 900 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3 }}>
        <Box><Typography variant="h5" fontWeight={700}>Proposal Statuses</Typography><Typography variant="body2" color="text.secondary">Workflow: draft → in_review → pending_approval → approved → sent → accepted/rejected. Drives status tracker.</Typography></Box>
        <Button variant="contained" startIcon={<Add />} onClick={handleOpenNew}>New Status</Button>
      </Box>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Enum</TableCell><TableCell>Label</TableCell><TableCell>Order</TableCell><TableCell>Color</TableCell><TableCell>Active</TableCell><TableCell align="right">Actions</TableCell></TableRow></TableHead><TableBody>{list.length === 0 ? <TableRow><TableCell colSpan={6} sx={{ textAlign: "center", py: 4 }}><Typography color="text.secondary">No statuses. Seed defaults: draft, in_review, pending_approval, approved, sent, accepted, rejected, expired.</Typography><Button sx={{ mt: 2 }} variant="outlined" onClick={async () => { for (const [idx, opt] of STATUS_OPTIONS.entries()) { await supabase.from("bd_proposal_statuses").insert({ status: opt.value, label: opt.label, color: opt.color, order_index: idx, is_active: true, tenant_id: (session?.user?.user_metadata as any)?.tenant_id || undefined }); } setTimeout(fetch, 1000); }}>Seed 8 Statuses</Button></TableCell></TableRow> : list.map(s => <TableRow key={s.id} hover><TableCell><Chip label={s.status} size="small" variant="outlined" /></TableCell><TableCell><Typography fontWeight={600}>{s.label}</Typography></TableCell><TableCell>{s.order_index}</TableCell><TableCell><Box sx={{ width: 20, height: 20, borderRadius: "50%", bgcolor: s.color, border: "1px solid #ddd" }} /></TableCell><TableCell><Chip label={s.is_active ? "Active" : "Inactive"} size="small" color={s.is_active ? "success" : "default"} /></TableCell><TableCell align="right"><IconButton size="small" onClick={() => handleOpenEdit(s)}><Edit fontSize="small" /></IconButton><IconButton size="small" onClick={() => handleDelete(s.id)}><Delete fontSize="small" /></IconButton></TableCell></TableRow>)}</TableBody></Table></CardContent></Card>
      <Dialog open={open} onClose={() => setOpen(false)} maxWidth="sm" fullWidth><DialogTitle>{editing ? "Edit Status" : "New Status"}</DialogTitle><DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}><TextField select label="Status Enum" value={form.status} onChange={e => { const opt = STATUS_OPTIONS.find(o => o.value === e.target.value); setForm({ ...form, status: e.target.value as ProposalStatusEnum, label: opt?.label || form.label, color: opt?.color || form.color }); }} fullWidth>{STATUS_OPTIONS.map(o => <MenuItem key={o.value} value={o.value}>{o.label} ({o.value})</MenuItem>)}</TextField><TextField label="Label" value={form.label} onChange={e => setForm({ ...form, label: e.target.value })} fullWidth /><TextField label="Order" type="number" value={form.order_index} onChange={e => setForm({ ...form, order_index: parseInt(e.target.value) || 0 })} fullWidth /><TextField label="Color" type="color" value={form.color} onChange={e => setForm({ ...form, color: e.target.value })} fullWidth sx={{ maxWidth: 150 }} /><Box sx={{ display: "flex", alignItems: "center", gap: 1 }}><Switch checked={form.is_active} onChange={e => setForm({ ...form, is_active: e.target.checked })} /><Typography variant="body2">Active</Typography></Box></DialogContent><DialogActions><Button onClick={() => setOpen(false)}>Cancel</Button><Button variant="contained" onClick={handleSave}>{editing ? "Update" : "Create"}</Button></DialogActions></Dialog>
    </Box>
  );
}
