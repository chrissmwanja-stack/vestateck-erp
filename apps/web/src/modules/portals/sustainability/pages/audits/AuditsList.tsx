import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Dialog, DialogActions, DialogContent, DialogTitle, Table, TableBody, TableCell, TableHead, TableRow, TextField, Typography, MenuItem, Grid, IconButton, Tooltip, Alert } from "@mui/material";
import { Add, Edit, Delete } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { useAuth } from "../../../../../lib/authContext";

interface Audit {
  id: string;
  tenant_id: string;
  title: string;
  type: string | null;
  status: string;
  audit_date: string | null;
  findings: string | null;
  created_at: string;
}

const emptyForm = { title: "", type: "", status: "scheduled", audit_date: "", findings: "" };

export default function AuditsList() {
  const { session } = useAuth();
  const [audits, setAudits] = useState<Audit[]>([]);
  const [loading, setLoading] = useState(true);
  const [open, setOpen] = useState(false);
  const [editing, setEditing] = useState<Audit | null>(null);
  const [form, setForm] = useState(emptyForm);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const fetchAudits = async () => {
    setLoading(true);
    const { data } = await supabase.from("sustainability_audits").select("*").order("audit_date", { ascending: false }).limit(200);
    if (data) setAudits(data as Audit[]);
    setLoading(false);
  };

  useEffect(() => { fetchAudits(); }, []);

  const openCreate = () => { setEditing(null); setForm(emptyForm); setError(null); setOpen(true); };
  const openEdit = (row: Audit) => { setEditing(row); setForm({ title: row.title, type: row.type || "", status: row.status, audit_date: row.audit_date || "", findings: row.findings || "" }); setError(null); setOpen(true); };

  const handleSave = async () => {
    setError(null);
    if (!form.title.trim()) { setError("Title is required."); return; }
    setSaving(true);
    const payload: any = {
      title: form.title.trim(),
      type: form.type.trim() || null,
      status: form.status,
      audit_date: form.audit_date || null,
      findings: form.findings.trim() || null,
    };
    if (!editing) {
      const tenant_id = (session?.user?.user_metadata as any)?.tenant_id || audits[0]?.tenant_id;
      if (tenant_id) payload.tenant_id = tenant_id;
      const { error } = await supabase.from("sustainability_audits").insert(payload);
      setSaving(false);
      if (error) { setError(error.message); return; }
    } else {
      const { error } = await supabase.from("sustainability_audits").update(payload).eq("id", editing.id);
      setSaving(false);
      if (error) { setError(error.message); return; }
    }
    setOpen(false);
    setEditing(null);
    setForm(emptyForm);
    fetchAudits();
  };

  const handleDelete = async (id: string) => {
    if (!window.confirm("Delete this audit?")) return;
    const { error } = await supabase.from("sustainability_audits").delete().eq("id", id);
    if (error) alert(error.message);
    else fetchAudits();
  };

  const getStatusColor = (s: string) => {
    if (s === 'completed') return 'success';
    if (s === 'in_progress') return 'primary';
    return 'default';
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3 }}>
        <Box><Typography variant="h5" fontWeight={700}>Audits</Typography><Typography variant="body2" color="text.secondary">{audits.length} audits • Schedule, findings, corrective actions. Click edit to update status.</Typography></Box>
        <Button variant="contained" startIcon={<Add />} onClick={openCreate}>New Audit</Button>
      </Box>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Title</TableCell><TableCell>Type</TableCell><TableCell>Date</TableCell><TableCell>Status</TableCell><TableCell>Findings</TableCell><TableCell align="right">Actions</TableCell></TableRow></TableHead><TableBody>{audits.length === 0 ? <TableRow><TableCell colSpan={6} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No audits yet. Create audit schedule.</Typography></TableCell></TableRow> : audits.map(a => <TableRow key={a.id} hover><TableCell><Typography fontWeight={600}>{a.title}</Typography></TableCell><TableCell>{a.type || "-"}</TableCell><TableCell>{a.audit_date ? new Date(a.audit_date).toLocaleDateString() : "-"}</TableCell><TableCell><Chip label={a.status} size="small" color={getStatusColor(a.status) as any} sx={{ textTransform: "capitalize" }} /></TableCell><TableCell><Typography variant="body2" color="text.secondary" sx={{ maxWidth: 250, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{a.findings || "-"}</Typography></TableCell><TableCell align="right"><Tooltip title="Edit"><IconButton size="small" aria-label="Edit audit" onClick={() => openEdit(a)}><Edit fontSize="small" /></IconButton></Tooltip><Tooltip title="Delete"><IconButton size="small" aria-label="Delete audit" onClick={() => handleDelete(a.id)}><Delete fontSize="small" /></IconButton></Tooltip></TableCell></TableRow>)}</TableBody></Table></CardContent></Card>

      <Dialog open={open} onClose={() => !saving && setOpen(false)} maxWidth="sm" fullWidth><DialogTitle>{editing ? "Edit Audit" : "New Audit"}</DialogTitle><DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}>
        {error && <Alert severity="error">{error}</Alert>}
        <TextField label="Title *" value={form.title} onChange={e => setForm({ ...form, title: e.target.value })} fullWidth autoFocus required placeholder="e.g. ISO 14001 Internal Audit" />
        <Grid container spacing={2}><Grid item xs={6}><TextField label="Type" value={form.type} onChange={e => setForm({ ...form, type: e.target.value })} fullWidth placeholder="Internal, External, Certification" /></Grid><Grid item xs={6}><TextField label="Audit Date" type="date" value={form.audit_date} onChange={e => setForm({ ...form, audit_date: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} /></Grid></Grid>
        <TextField select label="Status" value={form.status} onChange={e => setForm({ ...form, status: e.target.value })} fullWidth><MenuItem value="scheduled">Scheduled</MenuItem><MenuItem value="in_progress">In Progress</MenuItem><MenuItem value="completed">Completed</MenuItem></TextField>
        <TextField label="Findings" value={form.findings} onChange={e => setForm({ ...form, findings: e.target.value })} fullWidth multiline rows={3} placeholder="Findings, observations, non-conformities..." />
      </DialogContent><DialogActions><Button onClick={() => setOpen(false)} disabled={saving}>Cancel</Button><Button variant="contained" onClick={handleSave} disabled={!form.title.trim() || saving}>{saving ? "Saving..." : editing ? "Update" : "Create"}</Button></DialogActions></Dialog>
    </Box>
  );
}
