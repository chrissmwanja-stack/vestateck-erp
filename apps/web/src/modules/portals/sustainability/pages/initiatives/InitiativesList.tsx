import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Dialog, DialogActions, DialogContent, DialogTitle, IconButton, LinearProgress, Table, TableBody, TableCell, TableHead, TableRow, TextField, Tooltip, Typography, MenuItem, Grid, Alert } from "@mui/material";
import { Add, Edit, Delete, FileDownload, Download } from "@mui/icons-material";
import { useNavigate } from "react-router-dom";
import { supabase } from "../../../../../lib/supabaseClient";
import { exportReportToExcel, exportReportToPdf } from "../../../../../lib/reportExport";

const emptyForm = { title: "", category_id: "", status: "planned", target_value: "", current_value: "", owner: "", start_date: "", end_date: "", description: "" };

export default function InitiativesList() {
  const navigate = useNavigate();
  const [initiatives, setInitiatives] = useState<any[]>([]);
  const [categories, setCategories] = useState<any[]>([]);
  const [loading, setLoading] = useState(true);
  const [open, setOpen] = useState(false);
  const [editing, setEditing] = useState<any | null>(null);
  const [form, setForm] = useState(emptyForm);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const fetchInitiatives = async () => {
    setLoading(true);
    const [iniRes, catRes] = await Promise.all([
      supabase.from("sustainability_initiatives").select("*, sustainability_initiative_categories(name)").order("created_at", { ascending: false }).limit(200),
      supabase.from("sustainability_initiative_categories").select("id, name").eq("is_active", true).order("name"),
    ]);
    if (iniRes.data) {
      const norm = (iniRes.data as any[]).map((r: any) => ({ ...r, sustainability_initiative_categories: Array.isArray(r.sustainability_initiative_categories) ? r.sustainability_initiative_categories[0] ?? null : r.sustainability_initiative_categories ?? null }));
      setInitiatives(norm);
    }
    if (catRes.data) setCategories(catRes.data);
    setLoading(false);
  };

  useEffect(() => { fetchInitiatives(); }, []);

  const getStatusColor = (s: string) => {
    if (s === 'completed') return 'success';
    if (s === 'in_progress') return 'primary';
    if (s === 'on_hold') return 'warning';
    return 'default';
  };
  const getProgress = (current: number | null, target: number | null) => {
    if (!target || target === 0 || current === null || current === undefined) return 0;
    return Math.min(100, (Number(current) / Number(target)) * 100);
  };

  const openCreate = () => {
    setEditing(null);
    setForm(emptyForm);
    setError(null);
    setOpen(true);
  };
  const openEdit = (row: any) => {
    setEditing(row);
    setForm({
      title: row.title || "",
      category_id: row.category_id || "",
      status: row.status || "planned",
      target_value: row.target_value != null ? String(row.target_value) : "",
      current_value: row.current_value != null ? String(row.current_value) : "",
      owner: row.owner || "",
      start_date: row.start_date || "",
      end_date: row.end_date || "",
      description: row.description || "",
    });
    setError(null);
    setOpen(true);
  };

  const handleSave = async () => {
    setError(null);
    if (!form.title.trim()) { setError("Title is required."); return; }
    if (form.target_value && isNaN(Number(form.target_value))) { setError("Target must be a number."); return; }
    if (form.current_value && isNaN(Number(form.current_value))) { setError("Current must be a number."); return; }
    if (form.start_date && form.end_date && form.start_date > form.end_date) { setError("Start cannot be after end."); return; }
    setSaving(true);
    const payload: any = {
      title: form.title.trim(),
      category_id: form.category_id || null,
      status: form.status,
      target_value: form.target_value ? parseFloat(form.target_value) : null,
      current_value: form.current_value ? parseFloat(form.current_value) : null,
      owner: form.owner.trim() || null,
      start_date: form.start_date || null,
      end_date: form.end_date || null,
      description: form.description.trim() || null,
    };
    let res;
    if (editing) res = await supabase.from("sustainability_initiatives").update(payload).eq("id", editing.id);
    else {
      const { data: tenantData } = await supabase.from("sustainability_initiative_categories").select("tenant_id").limit(1).single();
      const tenant_id = (tenantData as any)?.tenant_id || initiatives[0]?.tenant_id;
      if (tenant_id) payload.tenant_id = tenant_id;
      res = await supabase.from("sustainability_initiatives").insert(payload);
    }
    setSaving(false);
    if (res.error) { setError(res.error.message); return; }
    setOpen(false);
    setEditing(null);
    setForm(emptyForm);
    fetchInitiatives();
  };

  const handleDelete = async (id: string) => {
    if (!window.confirm("Delete this initiative?")) return;
    const { error } = await supabase.from("sustainability_initiatives").delete().eq("id", id);
    if (error) alert(error.message);
    else fetchInitiatives();
  };

  const handleExcel = () => {
    const cols = [
      { header: "Title", accessor: (r: any) => r.title },
      { header: "Category", accessor: (r: any) => r.sustainability_initiative_categories?.name || "-" },
      { header: "Status", accessor: (r: any) => r.status },
      { header: "Owner", accessor: (r: any) => r.owner || "-" },
      { header: "Target", accessor: (r: any) => r.target_value ?? "-" },
      { header: "Current", accessor: (r: any) => r.current_value ?? "-" },
      { header: "Progress %", accessor: (r: any) => getProgress(r.current_value, r.target_value).toFixed(0) },
      { header: "Start", accessor: (r: any) => r.start_date || "-" },
      { header: "End", accessor: (r: any) => r.end_date || "-" },
    ];
    exportReportToExcel(`sustainability-initiatives-${new Date().toISOString().slice(0,10)}`, "Initiatives", cols as any, initiatives);
  };
  const handlePdf = () => {
    const cols = [
      { header: "Title", accessor: (r: any) => r.title },
      { header: "Category", accessor: (r: any) => r.sustainability_initiative_categories?.name || "-" },
      { header: "Status", accessor: (r: any) => r.status },
      { header: "Target/Curr", accessor: (r: any) => `${r.current_value ?? "-"} / ${r.target_value ?? "-"}` },
      { header: "Progress", accessor: (r: any) => `${getProgress(r.current_value, r.target_value).toFixed(0)}%` },
    ];
    exportReportToPdf(`sustainability-initiatives-${new Date().toISOString().slice(0,10)}.pdf`, "Sustainability Initiatives", cols as any, initiatives);
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", mb: 2, gap: 2, flexWrap: "wrap" }}>
        <Box><Typography variant="h5" fontWeight={700}>Initiatives</Typography><Typography variant="body2" color="text.secondary">{initiatives.length} sustainability initiatives • Tracks target vs current progress. Click edit to update.</Typography></Box>
        <Box sx={{ display: "flex", gap: 1, flexWrap: "wrap" }}>
          <Button size="small" variant="outlined" startIcon={<FileDownload />} onClick={handleExcel} disabled={initiatives.length===0}>Excel</Button>
          <Button size="small" variant="outlined" startIcon={<Download />} onClick={handlePdf} disabled={initiatives.length===0}>PDF</Button>
          <Button variant="outlined" onClick={() => navigate("/sustainability/initiatives/new")}>Full Create Page</Button>
          <Button variant="contained" startIcon={<Add />} onClick={openCreate}>Quick Add</Button>
        </Box>
      </Box>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Title</TableCell><TableCell>Category</TableCell><TableCell>Status</TableCell><TableCell>Owner</TableCell><TableCell>Target / Current</TableCell><TableCell>Progress</TableCell><TableCell align="right">Actions</TableCell></TableRow></TableHead><TableBody>{initiatives.length === 0 ? <TableRow><TableCell colSpan={7} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No initiatives yet. Use Quick Add or Full Create Page — needs category lookup from Admin → Initiative Categories.</Typography></TableCell></TableRow> : initiatives.map((i: any) => {
        const progress = getProgress(i.current_value, i.target_value);
        return <TableRow key={i.id} hover><TableCell><Typography fontWeight={600}>{i.title}</Typography><Typography variant="caption" color="text.secondary" sx={{ display: "block", maxWidth: 300, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{i.description || ""}</Typography></TableCell><TableCell>{i.sustainability_initiative_categories?.name || "-"}</TableCell><TableCell><Chip label={i.status} size="small" color={getStatusColor(i.status) as any} sx={{ textTransform: "capitalize" }} /></TableCell><TableCell>{i.owner || "-"}</TableCell><TableCell>{i.current_value ?? "-"} / {i.target_value ?? "-"}</TableCell><TableCell><Box sx={{ display: "flex", alignItems: "center", gap: 1, minWidth: 120 }}><LinearProgress variant="determinate" value={progress} sx={{ flex: 1, height: 6, borderRadius: 1 }} color={progress >= 100 ? "success" : "primary"} /><Typography variant="caption">{progress.toFixed(0)}%</Typography></Box></TableCell><TableCell align="right"><Tooltip title="Edit"><IconButton size="small" aria-label="Edit initiative" onClick={() => openEdit(i)}><Edit fontSize="small" /></IconButton></Tooltip><Tooltip title="Delete"><IconButton size="small" aria-label="Delete initiative" onClick={() => handleDelete(i.id)}><Delete fontSize="small" /></IconButton></Tooltip></TableCell></TableRow>;
      })}</TableBody></Table></CardContent></Card>

      <Dialog open={open} onClose={() => !saving && setOpen(false)} maxWidth="md" fullWidth>
        <DialogTitle>{editing ? "Edit Initiative" : "Quick Add Initiative"}</DialogTitle>
        <DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}>
          {error && <Alert severity="error">{error}</Alert>}
          <TextField label="Title *" value={form.title} onChange={e => setForm({ ...form, title: e.target.value })} fullWidth required placeholder="e.g. Reduce carbon by 20% in 2026" />
          <Grid container spacing={2}>
            <Grid item xs={12} sm={6}><TextField select label="Category" value={form.category_id} onChange={e => setForm({ ...form, category_id: e.target.value })} fullWidth><MenuItem value="">-- None --</MenuItem>{categories.map(c => <MenuItem key={c.id} value={c.id}>{c.name}</MenuItem>)}</TextField></Grid>
            <Grid item xs={12} sm={6}><TextField select label="Status" value={form.status} onChange={e => setForm({ ...form, status: e.target.value })} fullWidth><MenuItem value="planned">Planned</MenuItem><MenuItem value="in_progress">In Progress</MenuItem><MenuItem value="completed">Completed</MenuItem><MenuItem value="on_hold">On Hold</MenuItem></TextField></Grid>
            <Grid item xs={4}><TextField label="Target Value" type="number" value={form.target_value} onChange={e => setForm({ ...form, target_value: e.target.value })} fullWidth /></Grid>
            <Grid item xs={4}><TextField label="Current Value" type="number" value={form.current_value} onChange={e => setForm({ ...form, current_value: e.target.value })} fullWidth helperText={form.target_value && form.current_value ? `${getProgress(Number(form.current_value), Number(form.target_value)).toFixed(0)}%` : ""} /></Grid>
            <Grid item xs={4}><TextField label="Owner" value={form.owner} onChange={e => setForm({ ...form, owner: e.target.value })} fullWidth placeholder="Person responsible" /></Grid>
            <Grid item xs={6}><TextField label="Start Date" type="date" value={form.start_date} onChange={e => setForm({ ...form, start_date: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} /></Grid>
            <Grid item xs={6}><TextField label="End Date" type="date" value={form.end_date} onChange={e => setForm({ ...form, end_date: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} /></Grid>
            <Grid item xs={12}><TextField label="Description" value={form.description} onChange={e => setForm({ ...form, description: e.target.value })} fullWidth multiline rows={3} /></Grid>
          </Grid>
        </DialogContent>
        <DialogActions><Button onClick={() => setOpen(false)} disabled={saving}>Cancel</Button><Button variant="contained" onClick={handleSave} disabled={saving || !form.title.trim()}>{saving ? "Saving..." : editing ? "Update" : "Create"}</Button></DialogActions>
      </Dialog>
    </Box>
  );
}
