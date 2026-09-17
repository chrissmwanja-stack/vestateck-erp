import { useEffect, useState, useMemo } from "react";
import { Box, Button, Card, CardContent, CircularProgress, Dialog, DialogActions, DialogContent, DialogTitle, Table, TableBody, TableCell, TableHead, TableRow, TextField, Typography, MenuItem, Grid, IconButton, Tooltip, Alert, Chip } from "@mui/material";
import { Add, Edit, Delete, FileDownload, Download } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { useAuth } from "../../../../../lib/authContext";
import { exportReportToExcel, exportReportToPdf } from "../../../../../lib/reportExport";
import { LineChart, Line, XAxis, YAxis, Tooltip as ReTooltip, ResponsiveContainer, CartesianGrid, Legend } from "recharts";

interface MetricType { id: string; name: string; unit: string; }

const emptyForm = { metric_type_id: "", value: "", recorded_date: new Date().toISOString().slice(0, 10), notes: "" };

export default function CarbonMetrics() {
  const { session } = useAuth();
  const [metrics, setMetrics] = useState<any[]>([]);
  const [types, setTypes] = useState<MetricType[]>([]);
  const [loading, setLoading] = useState(true);
  const [open, setOpen] = useState(false);
  const [editing, setEditing] = useState<any | null>(null);
  const [form, setForm] = useState(emptyForm);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const fetchData = async () => {
    setLoading(true);
    const [metricsRes, typesRes] = await Promise.all([
      supabase.from("sustainability_metrics").select("*, sustainability_metric_types(name, unit)").eq("type", "carbon").order("recorded_date", { ascending: false }).limit(200),
      supabase.from("sustainability_metric_types").select("id, name, unit").eq("type", "carbon").eq("is_active", true).order("name"),
    ]);
    if (metricsRes.data) {
      const norm = (metricsRes.data as any[]).map((m: any) => ({ ...m, sustainability_metric_types: Array.isArray(m.sustainability_metric_types) ? m.sustainability_metric_types[0] ?? null : m.sustainability_metric_types ?? null }));
      setMetrics(norm);
    }
    if (typesRes.data) setTypes(typesRes.data as MetricType[]);
    setLoading(false);
  };

  useEffect(() => { fetchData(); }, []);

  const total = useMemo(() => metrics.reduce((sum, m) => sum + Number(m.value), 0), [metrics]);
  const avg = metrics.length > 0 ? total / metrics.length : 0;

  const trend = useMemo(() => {
    const byMonth: Record<string, number> = {};
    metrics.forEach((m: any) => {
      const key = m.recorded_date?.slice(0,7) || "unknown";
      byMonth[key] = (byMonth[key] || 0) + Number(m.value);
    });
    return Object.entries(byMonth).sort(([a],[b])=>a.localeCompare(b)).slice(-6).map(([month, value])=>({ month, value }));
  }, [metrics]);

  const openCreate = () => { setEditing(null); setForm(emptyForm); setError(null); setOpen(true); };
  const openEdit = (row: any) => {
    setEditing(row);
    setForm({ metric_type_id: row.metric_type_id || "", value: String(row.value), recorded_date: row.recorded_date, notes: row.notes || "" });
    setError(null);
    setOpen(true);
  };

  const handleSave = async () => {
    setError(null);
    const val = parseFloat(form.value);
    if (Number.isNaN(val)) { setError("Value must be a number."); return; }
    if (!form.recorded_date) { setError("Date is required."); return; }
    setSaving(true);
    const tenant_id = (session?.user?.user_metadata as any)?.tenant_id || metrics[0]?.tenant_id;
    const payload: any = {
      metric_type_id: form.metric_type_id || null,
      type: "carbon",
      value: val,
      recorded_date: form.recorded_date,
      notes: form.notes.trim() || null,
    };
    if (tenant_id) payload.tenant_id = tenant_id;
    let res;
    if (editing) res = await supabase.from("sustainability_metrics").update(payload).eq("id", editing.id);
    else res = await supabase.from("sustainability_metrics").insert(payload);
    setSaving(false);
    if (res.error) { setError(res.error.message); return; }
    setOpen(false);
    setEditing(null);
    setForm(emptyForm);
    fetchData();
  };

  const handleDelete = async (id: string) => {
    if (!window.confirm("Delete this metric?")) return;
    const { error } = await supabase.from("sustainability_metrics").delete().eq("id", id);
    if (error) alert(error.message);
    else fetchData();
  };

  const handleExcel = () => {
    const cols = [
      { header: "Date", accessor: (r: any) => new Date(r.recorded_date).toLocaleDateString() },
      { header: "Type", accessor: (r: any) => r.sustainability_metric_types?.name || "-" },
      { header: "Value", accessor: (r: any) => r.value },
      { header: "Unit", accessor: (r: any) => r.sustainability_metric_types?.unit || "tCO2e" },
      { header: "Notes", accessor: (r: any) => r.notes || "-" },
    ];
    exportReportToExcel(`carbon-metrics-${new Date().toISOString().slice(0,10)}`, "Carbon", cols as any, metrics);
  };
  const handlePdf = () => {
    const cols = [
      { header: "Date", accessor: (r: any) => new Date(r.recorded_date).toLocaleDateString() },
      { header: "Type", accessor: (r: any) => r.sustainability_metric_types?.name || "-" },
      { header: "Value", accessor: (r: any) => r.value },
      { header: "Unit", accessor: (r: any) => r.sustainability_metric_types?.unit || "tCO2e" },
      { header: "Notes", accessor: (r: any) => (r.notes || "-").slice(0,40) },
    ];
    exportReportToPdf(`carbon-metrics-${new Date().toISOString().slice(0,10)}.pdf`, "Carbon Footprint Report", cols as any, metrics, `Total ${total.toLocaleString()} tCO2e • Avg ${avg.toFixed(2)} • ${metrics.length} records`);
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", mb: 2, gap: 2, flexWrap: "wrap" }}>
        <Box>
          <Typography variant="h5" fontWeight={700} gutterBottom>Carbon Footprint</Typography>
          <Typography variant="body2" color="text.secondary">Scope 1,2,3 emissions tracking. Unit tCO2e. Total {total.toLocaleString()} tCO2e, Avg {avg.toFixed(2)}. Click edit to correct.</Typography>
        </Box>
        <Box sx={{ display: "flex", gap: 1, flexWrap: "wrap" }}>
          <Button size="small" variant="outlined" startIcon={<FileDownload />} onClick={handleExcel} disabled={metrics.length===0}>Excel</Button>
          <Button size="small" variant="outlined" startIcon={<Download />} onClick={handlePdf} disabled={metrics.length===0}>PDF</Button>
          <Button variant="contained" startIcon={<Add />} onClick={openCreate}>Add Metric</Button>
        </Box>
      </Box>

      <Box sx={{ display: "flex", gap: 2, mb: 2, flexWrap: "wrap" }}>
        <Card sx={{ minWidth: 150 }}><CardContent><Typography variant="caption">Total Carbon</Typography><Typography variant="h6" fontWeight={700}>{total.toLocaleString()} tCO2e</Typography></CardContent></Card>
        <Card sx={{ minWidth: 150 }}><CardContent><Typography variant="caption">Records</Typography><Typography variant="h6" fontWeight={700}>{metrics.length}</Typography></CardContent></Card>
        <Card sx={{ minWidth: 150 }}><CardContent><Typography variant="caption">Avg per Record</Typography><Typography variant="h6" fontWeight={700}>{avg.toFixed(2)}</Typography></CardContent></Card>
        {types.length===0 && <Chip label="No metric types — create in Admin → Metric Types" size="small" color="warning" sx={{ alignSelf: "center" }} />}
      </Box>

      {trend.length > 1 && (
        <Card variant="outlined" sx={{ mb: 2 }}><CardContent>
          <Typography variant="subtitle2" fontWeight={700} gutterBottom>Monthly Trend (last 6 months)</Typography>
          <ResponsiveContainer width="100%" height={200}>
            <LineChart data={trend}>
              <CartesianGrid strokeDasharray="3 3" />
              <XAxis dataKey="month" fontSize={12} />
              <YAxis fontSize={12} />
              <ReTooltip /><Legend />
              <Line type="monotone" dataKey="value" stroke="#2e7d32" strokeWidth={2} name="tCO2e" dot />
            </LineChart>
          </ResponsiveContainer>
        </CardContent></Card>
      )}

      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Date</TableCell><TableCell>Metric Type</TableCell><TableCell>Value</TableCell><TableCell>Unit</TableCell><TableCell>Notes</TableCell><TableCell align="right">Actions</TableCell></TableRow></TableHead><TableBody>{metrics.length === 0 ? <TableRow><TableCell colSpan={6} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No carbon metrics yet. Add first metric via Add Metric.</Typography></TableCell></TableRow> : metrics.map((m: any) => <TableRow key={m.id} hover><TableCell>{new Date(m.recorded_date).toLocaleDateString()}</TableCell><TableCell>{m.sustainability_metric_types?.name || "-"}</TableCell><TableCell><Typography fontWeight={600}>{Number(m.value).toLocaleString()}</Typography></TableCell><TableCell>{m.sustainability_metric_types?.unit || "tCO2e"}</TableCell><TableCell><Typography variant="body2" color="text.secondary" sx={{ maxWidth: 250, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{m.notes || "-"}</Typography></TableCell><TableCell align="right"><Tooltip title="Edit"><IconButton size="small" aria-label="Edit metric" onClick={() => openEdit(m)}><Edit fontSize="small" /></IconButton></Tooltip><Tooltip title="Delete"><IconButton size="small" aria-label="Delete metric" onClick={() => handleDelete(m.id)}><Delete fontSize="small" /></IconButton></Tooltip></TableCell></TableRow>)}</TableBody></Table></CardContent></Card>

      <Dialog open={open} onClose={() => !saving && setOpen(false)} maxWidth="sm" fullWidth><DialogTitle>{editing ? "Edit Carbon Metric" : "Add Carbon Metric"}</DialogTitle><DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}>
        {error && <Alert severity="error">{error}</Alert>}
        <TextField select label="Metric Type" value={form.metric_type_id} onChange={e => setForm({ ...form, metric_type_id: e.target.value })} fullWidth><MenuItem value="">-- None --</MenuItem>{types.map(t => <MenuItem key={t.id} value={t.id}>{t.name} ({t.unit})</MenuItem>)}</TextField>
        <Grid container spacing={2}><Grid item xs={6}><TextField label="Value *" type="number" value={form.value} onChange={e => setForm({ ...form, value: e.target.value })} fullWidth required placeholder="e.g. 12.5" /></Grid><Grid item xs={6}><TextField label="Date *" type="date" value={form.recorded_date} onChange={e => setForm({ ...form, recorded_date: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} required /></Grid></Grid>
        <TextField label="Notes" value={form.notes} onChange={e => setForm({ ...form, notes: e.target.value })} fullWidth multiline rows={2} placeholder="Source, scope, calculation method..." />
      </DialogContent><DialogActions><Button onClick={() => setOpen(false)} disabled={saving}>Cancel</Button><Button variant="contained" onClick={handleSave} disabled={!form.value || !form.recorded_date || saving}>{saving ? "Saving..." : editing ? "Update" : "Create"}</Button></DialogActions></Dialog>
    </Box>
  );
}
