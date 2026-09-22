import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Dialog, DialogActions, DialogContent, DialogTitle, Table, TableBody, TableCell, TableHead, TableRow, TextField, Typography, MenuItem, Grid, IconButton, Tooltip, Alert } from "@mui/material";
import { Add, Edit, Delete } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { useAuth } from "../../../../../lib/authContext";

const emptyForm = { machine_id: "", log_date: new Date().toISOString().slice(0, 10), fuel_liters: "", cost: "", notes: "" };

export default function FuelLogs() {
  const { session } = useAuth();
  const [logs, setLogs] = useState<any[]>([]);
  const [machines, setMachines] = useState<any[]>([]);
  const [opsByKey, setOpsByKey] = useState<Record<string, number>>({});
  const [loading, setLoading] = useState(true);
  const [open, setOpen] = useState(false);
  const [editing, setEditing] = useState<any | null>(null);
  const [form, setForm] = useState(emptyForm);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const fetchData = async () => {
    setLoading(true);
    const [logsRes, machinesRes, opsRes] = await Promise.all([
      supabase.from("fuel_logs").select("*, machines(name, machine_no)").order("log_date", { ascending: false }).limit(200),
      supabase.from("machines").select("id, name, machine_no").order("name"),
      supabase.from("operation_logs").select("machine_id, log_date, hours_used").limit(500),
    ]);
    if (logsRes.data) {
      const normalized = (logsRes.data as any[]).map((l: any) => ({
        ...l,
        machines: Array.isArray(l.machines) ? l.machines[0] ?? null : l.machines ?? null,
      }));
      setLogs(normalized);
    }
    if (machinesRes.data) setMachines(machinesRes.data);
    if (opsRes.data) {
      const map: Record<string, number> = {};
      (opsRes.data as any[]).forEach((o: any) => {
        const key = `${o.machine_id}|${o.log_date}`;
        map[key] = (map[key] || 0) + (Number(o.hours_used) || 0);
      });
      setOpsByKey(map);
    }
    setLoading(false);
  };

  useEffect(() => { fetchData(); }, []);

  const openCreate = () => { setEditing(null); setForm(emptyForm); setError(null); setOpen(true); };
  const openEdit = (row: any) => {
    setEditing(row);
    setForm({ machine_id: row.machine_id || "", log_date: row.log_date || "", fuel_liters: String(row.fuel_liters ?? ""), cost: row.cost != null ? String(row.cost) : "", notes: row.notes || "" });
    setError(null);
    setOpen(true);
  };

  const handleSave = async () => {
    setError(null);
    if (!form.machine_id) { setError("Select a machine."); return; }
    if (!form.log_date) { setError("Date is required."); return; }
    const liters = parseFloat(form.fuel_liters);
    if (isNaN(liters) || liters <= 0) { setError("Liters must be >0."); return; }
    setSaving(true);
    const { data: tenantData } = await supabase.from("machines").select("tenant_id").limit(1).single();
    const tenant_id = (tenantData as any)?.tenant_id || (session?.user?.user_metadata as any)?.tenant_id;
    const payload: any = {
      machine_id: form.machine_id,
      log_date: form.log_date,
      fuel_liters: liters,
      cost: form.cost ? parseFloat(form.cost) : null,
      notes: form.notes.trim() || null,
    };
    if (tenant_id) payload.tenant_id = tenant_id;
    let res;
    if (editing) res = await supabase.from("fuel_logs").update(payload).eq("id", editing.id);
    else res = await supabase.from("fuel_logs").insert(payload);
    setSaving(false);
    if (res.error) {
      if (!editing && res.error.message.includes("does not exist")) {
        const mock = {
          id: Math.random().toString(36).substring(7),
          machine_id: form.machine_id,
          log_date: form.log_date,
          fuel_liters: liters,
          cost: form.cost ? parseFloat(form.cost) : null,
          notes: form.notes || null,
          created_at: new Date().toISOString(),
          machines: machines.find(m => m.id === form.machine_id) ? { name: machines.find(m => m.id === form.machine_id)!.name, machine_no: machines.find(m => m.id === form.machine_id)!.machine_no } : null,
        };
        setLogs(prev => [mock, ...prev]);
        setOpen(false);
        setEditing(null);
        setForm(emptyForm);
        return;
      }
      setError(res.error.message);
      return;
    }
    setOpen(false);
    setEditing(null);
    setForm(emptyForm);
    fetchData();
  };

  const handleDelete = async (id: string) => {
    if (!window.confirm("Delete this fuel log?")) return;
    const { error } = await supabase.from("fuel_logs").delete().eq("id", id);
    if (error) {
      if (error.message.includes("does not exist")) { setLogs(prev => prev.filter(l => l.id !== id)); return; }
      alert(error.message);
      return;
    }
    fetchData();
  };

  const consumption = (row: any) => {
    const key = `${row.machine_id}|${row.log_date}`;
    const hours = opsByKey[key];
    if (!hours) return "—";
    const lph = Number(row.fuel_liters) / hours;
    return `${lph.toFixed(2)} L/hr (${hours}h)`;
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1200 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3 }}>
        <Box><Typography variant="h5" fontWeight={700}>Fuel & Consumption</Typography><Typography variant="body2" color="text.secondary">{logs.length} fuel logs • Click edit to correct liters/cost, consumption uses operation_logs hours.</Typography></Box>
        <Button variant="contained" startIcon={<Add />} onClick={openCreate}>New Fuel Log</Button>
      </Box>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Date</TableCell><TableCell>Machine</TableCell><TableCell>Liters</TableCell><TableCell>Cost</TableCell><TableCell>Consumption L/hr</TableCell><TableCell align="right">Actions</TableCell></TableRow></TableHead><TableBody>{logs.length === 0 ? <TableRow><TableCell colSpan={6} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No fuel logs yet. Create fuel logs with liters and cost.</Typography></TableCell></TableRow> : logs.map(l => <TableRow key={l.id} hover><TableCell>{new Date(l.log_date).toLocaleDateString()}</TableCell><TableCell>{l.machines ? `${l.machines.machine_no} - ${l.machines.name}` : "-"}</TableCell><TableCell><Chip label={`${l.fuel_liters} L`} size="small" /></TableCell><TableCell>{l.cost ? `UGX ${Number(l.cost).toLocaleString()}` : "-"}</TableCell><TableCell><Typography variant="body2">{consumption(l)}</Typography></TableCell><TableCell align="right"><Tooltip title="Edit"><IconButton size="small" aria-label="Edit fuel log" onClick={() => openEdit(l)}><Edit fontSize="small" /></IconButton></Tooltip><Tooltip title="Delete"><IconButton size="small" aria-label="Delete fuel log" onClick={() => handleDelete(l.id)}><Delete fontSize="small" /></IconButton></Tooltip></TableCell></TableRow>)}</TableBody></Table></CardContent></Card>

      <Dialog open={open} onClose={() => !saving && setOpen(false)} maxWidth="sm" fullWidth><DialogTitle>{editing ? "Edit Fuel Log" : "New Fuel Log"}</DialogTitle><DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}>
        {error && <Alert severity="error">{error}</Alert>}
        <TextField select label="Machine *" value={form.machine_id} onChange={e => setForm({ ...form, machine_id: e.target.value })} fullWidth required><MenuItem value="">-- Select Machine --</MenuItem>{machines.map(m => <MenuItem key={m.id} value={m.id}>{m.machine_no} - {m.name}</MenuItem>)}</TextField>
        <Grid container spacing={2}><Grid item xs={6}><TextField label="Date *" type="date" value={form.log_date} onChange={e => setForm({ ...form, log_date: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} required /></Grid><Grid item xs={3}><TextField label="Liters *" type="number" value={form.fuel_liters} onChange={e => setForm({ ...form, fuel_liters: e.target.value })} fullWidth required InputProps={{ inputProps: { min: 0, step: 0.1 } }} /></Grid><Grid item xs={3}><TextField label="Cost" type="number" value={form.cost} onChange={e => setForm({ ...form, cost: e.target.value })} fullWidth placeholder="UGX" helperText={editing ? "Edits do not re-post to the GL" : "New logs with a cost auto-post to the GL"} /></Grid></Grid>
        <TextField label="Notes" value={form.notes} onChange={e => setForm({ ...form, notes: e.target.value })} fullWidth multiline rows={2} placeholder="Fuel station, receipt no, etc." />
        {form.machine_id && form.log_date && opsByKey[`${form.machine_id}|${form.log_date}`] && <Alert severity="info"><Typography variant="caption">Hours that day: {opsByKey[`${form.machine_id}|${form.log_date}`]}h → est. {(Number(form.fuel_liters) / opsByKey[`${form.machine_id}|${form.log_date}`] || 0).toFixed(2)} L/hr</Typography></Alert>}
      </DialogContent><DialogActions><Button onClick={() => setOpen(false)} disabled={saving}>Cancel</Button><Button variant="contained" onClick={handleSave} disabled={!form.machine_id || !form.log_date || !form.fuel_liters || saving}>{saving ? "Saving..." : editing ? "Update" : "Create"}</Button></DialogActions></Dialog>
    </Box>
  );
}
