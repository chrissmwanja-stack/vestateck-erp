import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, CircularProgress, Dialog, DialogActions, DialogContent, DialogTitle, Table, TableBody, TableCell, TableHead, TableRow, TextField, Typography, MenuItem, Grid } from "@mui/material";
import { Add } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { useAuth } from "../../../../../lib/authContext";

interface MetricType { id: string; name: string; unit: string; }

export default function WasteMetrics() {
  const { session } = useAuth();
  const [metrics, setMetrics] = useState<any[]>([]);
  const [types, setTypes] = useState<MetricType[]>([]);
  const [loading, setLoading] = useState(true);
  const [open, setOpen] = useState(false);
  const [form, setForm] = useState({ metric_type_id: "", value: "", recorded_date: new Date().toISOString().slice(0, 10), notes: "" });

  const fetchData = async () => {
    setLoading(true);
    const [metricsRes, typesRes] = await Promise.all([
      supabase.from("sustainability_metrics").select("*, sustainability_metric_types(name, unit)").eq("type", "waste").order("recorded_date", { ascending: false }).limit(100),
      supabase.from("sustainability_metric_types").select("id, name, unit").eq("type", "waste").eq("is_active", true),
    ]);
    if (metricsRes.data) setMetrics(metricsRes.data);
    if (typesRes.data) setTypes(typesRes.data as MetricType[]);
    setLoading(false);
  };

  useEffect(() => { fetchData(); }, []);

  const handleSave = async () => {
    if (!form.value || !form.recorded_date) return;
    const payload: any = {
      metric_type_id: form.metric_type_id || null,
      type: "waste",
      value: parseFloat(form.value),
      recorded_date: form.recorded_date,
      notes: form.notes.trim() || null,
      tenant_id: (session?.user?.user_metadata as any)?.tenant_id || undefined,
    };
    if (!payload.tenant_id) delete payload.tenant_id;
    const { error } = await supabase.from("sustainability_metrics").insert(payload);
    if (error) alert(error.message);
    else { setOpen(false); setForm({ metric_type_id: "", value: "", recorded_date: new Date().toISOString().slice(0, 10), notes: "" }); fetchData(); }
  };

  const total = metrics.reduce((sum, m) => sum + Number(m.value), 0);
  const avg = metrics.length > 0 ? total / metrics.length : 0;

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 2 }}>
        <Box>
          <Typography variant="h5" fontWeight={700} gutterBottom>Waste Management</Typography>
          <Typography variant="body2" color="text.secondary">Waste generated, recycled, disposal tracking. Unit kg. Total {total.toLocaleString()} kg, Avg {avg.toFixed(2)}.</Typography>
        </Box>
        <Button variant="contained" startIcon={<Add />} onClick={() => setOpen(true)}>Add Metric</Button>
      </Box>

      <Box sx={{ display: "flex", gap: 2, mb: 3 }}>
        <Card sx={{ minWidth: 150 }}><CardContent><Typography variant="caption">Total Carbon</Typography><Typography variant="h6" fontWeight={700}>{total.toLocaleString()} kg</Typography></CardContent></Card>
        <Card sx={{ minWidth: 150 }}><CardContent><Typography variant="caption">Records</Typography><Typography variant="h6" fontWeight={700}>{metrics.length}</Typography></CardContent></Card>
        <Card sx={{ minWidth: 150 }}><CardContent><Typography variant="caption">Avg per Record</Typography><Typography variant="h6" fontWeight={700}>{avg.toFixed(2)}</Typography></CardContent></Card>
      </Box>

      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Date</TableCell><TableCell>Metric Type</TableCell><TableCell>Value</TableCell><TableCell>Unit</TableCell><TableCell>Notes</TableCell></TableRow></TableHead><TableBody>{metrics.length === 0 ? <TableRow><TableCell colSpan={5} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No waste metrics yet. Add first metric via Add Metric. Needs sustainability_metrics table with type=waste.</Typography></TableCell></TableRow> : metrics.map((m: any) => <TableRow key={m.id} hover><TableCell>{new Date(m.recorded_date).toLocaleDateString()}</TableCell><TableCell>{m.sustainability_metric_types?.name || "-"}</TableCell><TableCell><Typography fontWeight={600}>{Number(m.value).toLocaleString()}</Typography></TableCell><TableCell>{m.sustainability_metric_types?.unit || m.unit || "kg"}</TableCell><TableCell><Typography variant="body2" color="text.secondary" sx={{ maxWidth: 250, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{m.notes || "-"}</Typography></TableCell></TableRow>)}</TableBody></Table></CardContent></Card>

      <Dialog open={open} onClose={() => setOpen(false)} maxWidth="sm" fullWidth><DialogTitle>Add Carbon Metric</DialogTitle><DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}><TextField select label="Metric Type" value={form.metric_type_id} onChange={e => setForm({ ...form, metric_type_id: e.target.value })} fullWidth><MenuItem value="">-- None --</MenuItem>{types.map(t => <MenuItem key={t.id} value={t.id}>{t.name} ({t.unit})</MenuItem>)}</TextField><Grid container spacing={2}><Grid item xs={6}><TextField label="Value *" type="number" value={form.value} onChange={e => setForm({ ...form, value: e.target.value })} fullWidth required placeholder="e.g. 12.5" /></Grid><Grid item xs={6}><TextField label="Date *" type="date" value={form.recorded_date} onChange={e => setForm({ ...form, recorded_date: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} required /></Grid></Grid><TextField label="Notes" value={form.notes} onChange={e => setForm({ ...form, notes: e.target.value })} fullWidth multiline rows={2} placeholder="Source, scope, calculation method..." /></DialogContent><DialogActions><Button onClick={() => setOpen(false)}>Cancel</Button><Button variant="contained" onClick={handleSave} disabled={!form.value || !form.recorded_date}>Create</Button></DialogActions></Dialog>
    </Box>
  );
}
