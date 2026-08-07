import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Dialog, DialogActions, DialogContent, DialogTitle, Table, TableBody, TableCell, TableHead, TableRow, TextField, Typography, MenuItem, Grid } from "@mui/material";
import { Add } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { useAuth } from "../../../../../lib/authContext";

interface Compliance {
  id: string;
  tenant_id: string;
  title: string;
  regulation: string | null;
  status: string;
  due_date: string | null;
  owner: string | null;
  created_at: string;
}

export default function ComplianceRegister() {
  const { session } = useAuth();
  const [items, setItems] = useState<Compliance[]>([]);
  const [loading, setLoading] = useState(true);
  const [open, setOpen] = useState(false);
  const [form, setForm] = useState({ title: "", regulation: "", status: "pending", due_date: "", owner: "" });

  const fetchData = async () => {
    setLoading(true);
    const { data } = await supabase.from("law_compliance_register").select("*").order("due_date", { ascending: true, nullsFirst: false });
    if (data) setItems(data as Compliance[]);
    setLoading(false);
  };

  useEffect(() => { fetchData(); }, []);

  const handleSave = async () => {
    if (!form.title.trim()) return;
    const tenant_id = (session?.user?.user_metadata as any)?.tenant_id || items[0]?.tenant_id;
    const payload: any = {
      title: form.title.trim(),
      regulation: form.regulation.trim() || null,
      status: form.status,
      due_date: form.due_date || null,
      owner: form.owner.trim() || null,
    };
    if (tenant_id) payload.tenant_id = tenant_id;
    const { error } = await supabase.from("law_compliance_register").insert(payload);
    if (error) alert(error.message);
    else { setOpen(false); setForm({ title: "", regulation: "", status: "pending", due_date: "", owner: "" }); fetchData(); }
  };

  const getStatusColor = (s: string) => {
    if (s === 'compliant') return 'success';
    if (s === 'non_compliant' || s === 'overdue') return 'error';
    return 'warning';
  };

  const isOverdue = (due: string | null, status: string) => {
    if (!due || status === 'compliant') return false;
    return new Date(due).getTime() < new Date().getTime();
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3 }}>
        <Box><Typography variant="h5" fontWeight={700}>Compliance Register</Typography><Typography variant="body2" color="text.secondary">{items.length} compliance items. Tracks regulatory requirements, due dates, owner.</Typography></Box>
        <Button variant="contained" startIcon={<Add />} onClick={() => setOpen(true)}>New Item</Button>
      </Box>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Title</TableCell><TableCell>Regulation</TableCell><TableCell>Status</TableCell><TableCell>Due Date</TableCell><TableCell>Owner</TableCell></TableRow></TableHead><TableBody>{items.length === 0 ? <TableRow><TableCell colSpan={5} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No compliance items yet. Create regulatory requirements to track.</Typography></TableCell></TableRow> : items.map(i => <TableRow key={i.id} hover sx={{ bgcolor: isOverdue(i.due_date, i.status) ? "error.light" : "inherit" }}><TableCell><Typography fontWeight={600}>{i.title}</Typography></TableCell><TableCell>{i.regulation || "-"}</TableCell><TableCell><Chip label={isOverdue(i.due_date, i.status) ? "overdue" : i.status} size="small" color={getStatusColor(isOverdue(i.due_date, i.status) ? "overdue" : i.status) as any} sx={{ textTransform: "capitalize" }} /></TableCell><TableCell>{i.due_date ? new Date(i.due_date).toLocaleDateString() : "-"}</TableCell><TableCell>{i.owner || "-"}</TableCell></TableRow>)}</TableBody></Table></CardContent></Card>

      <Dialog open={open} onClose={() => setOpen(false)} maxWidth="sm" fullWidth><DialogTitle>New Compliance Item</DialogTitle><DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}><TextField label="Title *" value={form.title} onChange={e => setForm({ ...form, title: e.target.value })} fullWidth autoFocus required placeholder="e.g. Annual Tax Filing" /><TextField label="Regulation" value={form.regulation} onChange={e => setForm({ ...form, regulation: e.target.value })} fullWidth placeholder="e.g. URA Income Tax Act" /><Grid container spacing={2}><Grid item xs={6}><TextField select label="Status" value={form.status} onChange={e => setForm({ ...form, status: e.target.value })} fullWidth><MenuItem value="pending">Pending</MenuItem><MenuItem value="compliant">Compliant</MenuItem><MenuItem value="non_compliant">Non Compliant</MenuItem><MenuItem value="overdue">Overdue</MenuItem></TextField></Grid><Grid item xs={6}><TextField label="Due Date" type="date" value={form.due_date} onChange={e => setForm({ ...form, due_date: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} /></Grid></Grid><TextField label="Owner" value={form.owner} onChange={e => setForm({ ...form, owner: e.target.value })} fullWidth placeholder="Person responsible" /></DialogContent><DialogActions><Button onClick={() => setOpen(false)}>Cancel</Button><Button variant="contained" onClick={handleSave} disabled={!form.title.trim()}>Create</Button></DialogActions></Dialog>
    </Box>
  );
}
