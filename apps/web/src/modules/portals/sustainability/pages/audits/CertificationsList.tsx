import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Dialog, DialogActions, DialogContent, DialogTitle, Table, TableBody, TableCell, TableHead, TableRow, TextField, Typography, MenuItem, Grid } from "@mui/material";
import { Add } from "@mui/icons-material";
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

export default function CertificationsList() {
  const { session } = useAuth();
  const [certs, setCerts] = useState<Certification[]>([]);
  const [loading, setLoading] = useState(true);
  const [open, setOpen] = useState(false);
  const [form, setForm] = useState({ name: "", standard: "", issue_date: "", expiry_date: "", status: "valid" });

  const fetchCerts = async () => {
    setLoading(true);
    const { data } = await supabase.from("sustainability_certifications").select("*").order("expiry_date", { ascending: true });
    if (data) setCerts(data as Certification[]);
    setLoading(false);
  };

  useEffect(() => { fetchCerts(); }, []);

  const handleSave = async () => {
    if (!form.name.trim()) return;
    const payload: any = {
      name: form.name.trim(),
      standard: form.standard.trim() || null,
      issue_date: form.issue_date || null,
      expiry_date: form.expiry_date || null,
      status: form.status,
      tenant_id: (session?.user?.user_metadata as any)?.tenant_id || undefined,
    };
    if (!payload.tenant_id) delete payload.tenant_id;
    const { error } = await supabase.from("sustainability_certifications").insert(payload);
    if (error) alert(error.message);
    else { setOpen(false); setForm({ name: "", standard: "", issue_date: "", expiry_date: "", status: "valid" }); fetchCerts(); }
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
        <Box><Typography variant="h5" fontWeight={700}>Certifications</Typography><Typography variant="body2" color="text.secondary">{certs.length} certifications • ISO 14001, ISO 45001, etc. expiry tracking.</Typography></Box>
        <Button variant="contained" startIcon={<Add />} onClick={() => setOpen(true)}>New Certification</Button>
      </Box>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Name</TableCell><TableCell>Standard</TableCell><TableCell>Issue Date</TableCell><TableCell>Expiry Date</TableCell><TableCell>Days Left</TableCell><TableCell>Status</TableCell></TableRow></TableHead><TableBody>{certs.length === 0 ? <TableRow><TableCell colSpan={6} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No certifications yet. Track ISO 14001, etc. expiry.</Typography></TableCell></TableRow> : certs.map(c => {
        const daysLeft = getDaysLeft(c.expiry_date);
        return <TableRow key={c.id} hover sx={{ bgcolor: daysLeft !== null && daysLeft < 0 ? "error.light" : daysLeft !== null && daysLeft <= 30 ? "warning.light" : "inherit" }}><TableCell><Typography fontWeight={600}>{c.name}</Typography></TableCell><TableCell>{c.standard || "-"}</TableCell><TableCell>{c.issue_date ? new Date(c.issue_date).toLocaleDateString() : "-"}</TableCell><TableCell>{c.expiry_date ? new Date(c.expiry_date).toLocaleDateString() : "-"}</TableCell><TableCell>{daysLeft === null ? "-" : daysLeft < 0 ? <Chip label={`${Math.abs(daysLeft)} days overdue`} size="small" color="error" /> : <Chip label={`${daysLeft} days left`} size="small" color={daysLeft <= 30 ? "warning" : "default"} />}</TableCell><TableCell><Chip label={c.status} size="small" color={getStatusColor(c.status, c.expiry_date) as any} sx={{ textTransform: "capitalize" }} /></TableCell></TableRow>;
      })}</TableBody></Table></CardContent></Card>

      <Dialog open={open} onClose={() => setOpen(false)} maxWidth="sm" fullWidth><DialogTitle>New Certification</DialogTitle><DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}><TextField label="Name *" value={form.name} onChange={e => setForm({ ...form, name: e.target.value })} fullWidth autoFocus required placeholder="e.g. ISO 14001:2015" /><TextField label="Standard" value={form.standard} onChange={e => setForm({ ...form, standard: e.target.value })} fullWidth placeholder="e.g. ISO 14001, ISO 45001" /><Grid container spacing={2}><Grid item xs={6}><TextField label="Issue Date" type="date" value={form.issue_date} onChange={e => setForm({ ...form, issue_date: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} /></Grid><Grid item xs={6}><TextField label="Expiry Date" type="date" value={form.expiry_date} onChange={e => setForm({ ...form, expiry_date: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} /></Grid></Grid><TextField select label="Status" value={form.status} onChange={e => setForm({ ...form, status: e.target.value })} fullWidth><MenuItem value="valid">Valid</MenuItem><MenuItem value="expired">Expired</MenuItem><MenuItem value="pending_renewal">Pending Renewal</MenuItem></TextField></DialogContent><DialogActions><Button onClick={() => setOpen(false)}>Cancel</Button><Button variant="contained" onClick={handleSave} disabled={!form.name.trim()}>Create</Button></DialogActions></Dialog>
    </Box>
  );
}
