import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Dialog, DialogActions, DialogContent, DialogTitle, Table, TableBody, TableCell, TableHead, TableRow, TextField, Typography, MenuItem, Grid } from "@mui/material";
import { Add } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { useAuth } from "../../../../../lib/authContext";

interface Compliance {
  id: string;
  tenant_id: string;
  item_no: string;
  title: string;
  regulation: string | null;
  status: string;
  due_date: string | null;
  owner_id: string | null;
  created_by: string;
  created_at: string;
  owner?: { id: string; name: string } | null;
}

interface StaffOption { id: string; name: string; }

export default function ComplianceRegister() {
  const { session } = useAuth();
  const [items, setItems] = useState<Compliance[]>([]);
  const [staff, setStaff] = useState<StaffOption[]>([]);
  const [loading, setLoading] = useState(true);
  const [open, setOpen] = useState(false);
  const [editing, setEditing] = useState<Compliance | null>(null);
  const [form, setForm] = useState({ title: "", regulation: "", status: "pending", due_date: "", owner_id: "" });

  const fetchData = async () => {
    setLoading(true);
    const { data } = await supabase
      .from("law_compliance_register")
      .select("*, owner:app_users!law_compliance_register_owner_id_fkey(id, name)")
      .order("due_date", { ascending: true, nullsFirst: false });
    if (data) setItems(data as unknown as Compliance[]);
    setLoading(false);
  };

  const fetchStaff = async () => {
    const { data } = await supabase.from("app_users").select("id, name").order("name");
    if (data) setStaff(data as StaffOption[]);
  };

  useEffect(() => { fetchData(); fetchStaff(); }, []);

  const handleOpenNew = () => {
    setEditing(null);
    setForm({ title: "", regulation: "", status: "pending", due_date: "", owner_id: "" });
    setOpen(true);
  };

  const handleOpenEdit = (item: Compliance) => {
    setEditing(item);
    setForm({
      title: item.title,
      regulation: item.regulation || "",
      status: item.status,
      due_date: item.due_date || "",
      owner_id: item.owner_id || "",
    });
    setOpen(true);
  };

  const handleSave = async () => {
    if (!form.title.trim()) return;

    const payload: any = {
      title: form.title.trim(),
      regulation: form.regulation.trim() || null,
      status: form.status,
      due_date: form.due_date || null,
      owner_id: form.owner_id || null,
    };

    if (editing) {
      const { error } = await supabase.from("law_compliance_register").update(payload).eq("id", editing.id);
      if (error) {
        alert(error.code === "42501" ? "You don't have permission to edit this item." : error.message);
        return;
      }
    } else {
      const userId = session?.user?.id;
      if (!userId) {
        alert("Your session has expired. Please sign in again.");
        return;
      }

      const { data: appUser, error: appUserError } = await supabase
        .from("app_users")
        .select("tenant_id")
        .eq("id", userId)
        .single();
      const tenant_id = appUser?.tenant_id;
      if (appUserError || !tenant_id) {
        alert("Could not determine your organization. Please refresh and try again.");
        return;
      }
      payload.tenant_id = tenant_id;

      const { error } = await supabase.from("law_compliance_register").insert(payload);
      if (error) {
        alert(error.code === "42501" ? "You don't have permission to create compliance items." : error.message);
        return;
      }
    }

    setOpen(false);
    setEditing(null);
    setForm({ title: "", regulation: "", status: "pending", due_date: "", owner_id: "" });
    fetchData();
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
        <Button variant="contained" startIcon={<Add />} onClick={handleOpenNew}>New Item</Button>
      </Box>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Title</TableCell><TableCell>Regulation</TableCell><TableCell>Status</TableCell><TableCell>Due Date</TableCell><TableCell>Owner</TableCell></TableRow></TableHead><TableBody>{items.length === 0 ? <TableRow><TableCell colSpan={5} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No compliance items yet. Create regulatory requirements to track.</Typography></TableCell></TableRow> : items.map(i => <TableRow key={i.id} hover onClick={() => handleOpenEdit(i)} sx={{ cursor: "pointer", bgcolor: isOverdue(i.due_date, i.status) ? "error.light" : "inherit" }}><TableCell><Typography fontWeight={600}>{i.title}</Typography></TableCell><TableCell>{i.regulation || "-"}</TableCell><TableCell><Chip label={isOverdue(i.due_date, i.status) ? "overdue" : i.status} size="small" color={getStatusColor(isOverdue(i.due_date, i.status) ? "overdue" : i.status) as any} sx={{ textTransform: "capitalize" }} /></TableCell><TableCell>{i.due_date ? new Date(i.due_date).toLocaleDateString() : "-"}</TableCell><TableCell>{i.owner?.name || "Unassigned"}</TableCell></TableRow>)}</TableBody></Table></CardContent></Card>

      <Dialog open={open} onClose={() => setOpen(false)} maxWidth="sm" fullWidth><DialogTitle>{editing ? "Edit Compliance Item" : "New Compliance Item"}</DialogTitle><DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}><TextField label="Title *" value={form.title} onChange={e => setForm({ ...form, title: e.target.value })} fullWidth autoFocus required placeholder="e.g. Annual Tax Filing" /><TextField label="Regulation" value={form.regulation} onChange={e => setForm({ ...form, regulation: e.target.value })} fullWidth placeholder="e.g. URA Income Tax Act" /><Grid container spacing={2}><Grid item xs={6}><TextField select label="Status" value={form.status} onChange={e => setForm({ ...form, status: e.target.value })} fullWidth><MenuItem value="pending">Pending</MenuItem><MenuItem value="compliant">Compliant</MenuItem><MenuItem value="non_compliant">Non Compliant</MenuItem><MenuItem value="overdue">Overdue</MenuItem></TextField></Grid><Grid item xs={6}><TextField label="Due Date" type="date" value={form.due_date} onChange={e => setForm({ ...form, due_date: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} /></Grid></Grid><TextField select label="Owner" value={form.owner_id} onChange={e => setForm({ ...form, owner_id: e.target.value })} fullWidth><MenuItem value="">Unassigned</MenuItem>{staff.map(s => <MenuItem key={s.id} value={s.id}>{s.name}</MenuItem>)}</TextField></DialogContent><DialogActions><Button onClick={() => setOpen(false)}>Cancel</Button><Button variant="contained" onClick={handleSave} disabled={!form.title.trim()}>{editing ? "Save" : "Create"}</Button></DialogActions></Dialog>
    </Box>
  );
}