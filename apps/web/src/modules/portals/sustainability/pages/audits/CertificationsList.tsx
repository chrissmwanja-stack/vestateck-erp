import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Dialog, DialogActions, DialogContent, DialogTitle, Table, TableBody, TableCell, TableHead, TableRow, TextField, Typography, MenuItem, Grid, IconButton, Tooltip, Alert } from "@mui/material";
import { Add, Edit, Delete } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { useAuth } from "../../../../../lib/authContext";

interface Certification {
  id: string;
  tenant_id: string;
  name: string;
  standard: string | null;
  issue_date: string | null;
  expiry_date: string | null;
  status: string;
  created_at: string;
}

const emptyForm = { name: "", standard: "", issue_date: "", expiry_date: "", status: "valid" };

export default function CertificationsList() {
  const { session } = useAuth();
  const [certs, setCerts] = useState<Certification[]>([]);
  const [loading, setLoading] = useState(true);
  const [open, setOpen] = useState(false);
  const [editing, setEditing] = useState<Certification | null>(null);
  const [form, setForm] = useState(emptyForm);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const fetchCerts = async () => {
    setLoading(true);
    const { data } = await supabase.from("sustainability_certifications").select("*").order("expiry_date", { ascending: true }).limit(200);
    if (data) setCerts(data as Certification[]);
    setLoading(false);
  };

  useEffect(() => { fetchCerts(); }, []);

  const openCreate = () => { setEditing(null); setForm(emptyForm); setError(null); setOpen(true); };
  const openEdit = (row: Certification) => { setEditing(row); setForm({ name: row.name, standard: row.standard || "", issue_date: row.issue_date || "", expiry_date: row.expiry_date || "", status: row.status }); setError(null); setOpen(true); };

  const handleSave = async () => {
    setError(null);
    if (!form.name.trim()) { setError("Name is required."); return; }
    if (form.issue_date && form.expiry_date && form.issue_date > form.expiry_date) { setError("Issue cannot be after expiry."); return; }
    setSaving(true);
    const payload: any = {
      name: form.name.trim(),
      standard: form.standard.trim() || null,
      issue_date: form.issue_date || null,
      expiry_date: form.expiry_date || null,
      status: form.status,
    };
    let res;
    if (editing) res = await supabase.from("sustainability_certifications").update(payload).eq("id", editing.id);
    else {
      const tenant_id = (session?.user?.user_metadata as any)?.tenant_id || certs[0]?.tenant_id;
      if (tenant_id) payload.tenant_id = tenant_id;
      res = await supabase.from("sustainability_certifications").insert(payload);
    }
    setSaving(false);
    if (res.error) { setError(res.error.message); return; }
    setOpen(false);
    setEditing(null);
    setForm(emptyForm);
    fetchCerts();
  };

  const handleDelete = async (id: string) => {
    if (!window.confirm("Delete this certification?")) return;
    const { error } = await supabase.from("sustainability_certifications").delete().eq("id", id);
    if (error) alert(error.message);
    else fetchCerts();
  };

  const getDaysLeft = (expiry: string | null) => {
    if (!expiry) return null;
    const diff = new Date(expiry).getTime() - new Date().getTime();
    return Math.ceil(diff / (1000 * 60 * 60 * 24));
  };

  const getStatusColor = (s: string, expiry: string | null) => {
    const daysLeft = getDaysLeft(expiry);
    if (daysLeft !== null && daysLeft < 0) return 'error';
    if (s === 'valid') return 'success';
    if (s === 'expired') return 'error';
    return 'warning';
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3 }}>
        <Box><Typography variant="h5" fontWeight={700}>Certifications</Typography><Typography variant="body2" color="text.secondary">{certs.length} certifications • ISO 14001, ISO 45001, etc. expiry tracking. Edit to extend dates.</Typography></Box>
        <Button variant="contained" startIcon={<Add />} onClick={openCreate}>New Certification</Button>
      </Box>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Name</TableCell><TableCell>Standard</TableCell><TableCell>Issue Date</TableCell><TableCell>Expiry Date</TableCell><TableCell>Days Left</TableCell><TableCell>Status</TableCell><TableCell align="right">Actions</TableCell></TableRow></TableHead><TableBody>{certs.length === 0 ? <TableRow><TableCell colSpan={7} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No certifications yet. Track ISO 14001, etc. expiry.</Typography></TableCell></TableRow> : certs.map(c => {
        const daysLeft = getDaysLeft(c.expiry_date);
        return <TableRow key={c.id} hover sx={{ bgcolor: daysLeft !== null && daysLeft < 0 ? "error.light" : daysLeft !== null && daysLeft <= 30 ? "warning.light" : "inherit" }}><TableCell><Typography fontWeight={600}>{c.name}</Typography></TableCell><TableCell>{c.standard || "-"}</TableCell><TableCell>{c.issue_date ? new Date(c.issue_date).toLocaleDateString() : "-"}</TableCell><TableCell>{c.expiry_date ? new Date(c.expiry_date).toLocaleDateString() : "-"}</TableCell><TableCell>{daysLeft === null ? "-" : daysLeft < 0 ? <Chip label={`${Math.abs(daysLeft)} days overdue`} size="small" color="error" /> : <Chip label={`${daysLeft} days left`} size="small" color={daysLeft <= 30 ? "warning" : "default"} />}</TableCell><TableCell><Chip label={c.status} size="small" color={getStatusColor(c.status, c.expiry_date) as any} sx={{ textTransform: "capitalize" }} /></TableCell><TableCell align="right"><Tooltip title="Edit"><IconButton size="small" aria-label="Edit certification" onClick={() => openEdit(c)}><Edit fontSize="small" /></IconButton></Tooltip><Tooltip title="Delete"><IconButton size="small" aria-label="Delete certification" onClick={() => handleDelete(c.id)}><Delete fontSize="small" /></IconButton></Tooltip></TableCell></TableRow>;
      })}</TableBody></Table></CardContent></Card>

      <Dialog open={open} onClose={() => !saving && setOpen(false)} maxWidth="sm" fullWidth><DialogTitle>{editing ? "Edit Certification" : "New Certification"}</DialogTitle><DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}>
        {error && <Alert severity="error">{error}</Alert>}
        <TextField label="Name *" value={form.name} onChange={e => setForm({ ...form, name: e.target.value })} fullWidth autoFocus required placeholder="e.g. ISO 14001:2015" />
        <TextField label="Standard" value={form.standard} onChange={e => setForm({ ...form, standard: e.target.value })} fullWidth placeholder="e.g. ISO 14001, ISO 45001" />
        <Grid container spacing={2}><Grid item xs={6}><TextField label="Issue Date" type="date" value={form.issue_date} onChange={e => setForm({ ...form, issue_date: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} /></Grid><Grid item xs={6}><TextField label="Expiry Date" type="date" value={form.expiry_date} onChange={e => setForm({ ...form, expiry_date: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} /></Grid></Grid>
        <TextField select label="Status" value={form.status} onChange={e => setForm({ ...form, status: e.target.value })} fullWidth><MenuItem value="valid">Valid</MenuItem><MenuItem value="expired">Expired</MenuItem><MenuItem value="pending_renewal">Pending Renewal</MenuItem></TextField>
      </DialogContent><DialogActions><Button onClick={() => setOpen(false)} disabled={saving}>Cancel</Button><Button variant="contained" onClick={handleSave} disabled={!form.name.trim() || saving}>{saving ? "Saving..." : editing ? "Update" : "Create"}</Button></DialogActions></Dialog>
    </Box>
  );
}
