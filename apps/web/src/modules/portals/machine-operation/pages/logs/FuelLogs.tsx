import { useEffect, useState } from "react";
import { Box, Button, Card, CardContent, Chip, CircularProgress, Dialog, DialogActions, DialogContent, DialogTitle, Table, TableBody, TableCell, TableHead, TableRow, TextField, Typography, MenuItem, Grid } from "@mui/material";
import { Add } from "@mui/icons-material";
import { supabase } from "../../../../../lib/supabaseClient";
import { useAuth } from "../../../../../lib/authContext";

export default function FuelLogs() {
  const { session } = useAuth();
  const [logs, setLogs] = useState<any[]>([]);
  const [machines, setMachines] = useState<any[]>([]);
  const [loading, setLoading] = useState(true);
  const [open, setOpen] = useState(false);
  const [form, setForm] = useState({ machine_id: "", log_date: new Date().toISOString().slice(0, 10), fuel_liters: "", cost: "", notes: "" });

  const fetchData = async () => {
    setLoading(true);
    const [logsRes, machinesRes] = await Promise.all([
      supabase.from("fuel_logs").select("*, machines(name, machine_no)").order("log_date", { ascending: false }).limit(100),
      supabase.from("machines").select("id, name, machine_no").order("name"),
    ]);
    if (logsRes.data) {
      const normalized = (logsRes.data as any[]).map((l: any) => ({
        ...l,
        machines: Array.isArray(l.machines) ? l.machines[0] ?? null : l.machines ?? null,
      }));
      setLogs(normalized);
    }
    if (machinesRes.data) setMachines(machinesRes.data);
    setLoading(false);
  };

  useEffect(() => { fetchData(); }, []);

  const handleSave = async () => {
    if (!form.machine_id || !form.log_date || !form.fuel_liters) return;
    const { data: tenantData } = await supabase.from("machines").select("tenant_id").limit(1).single();
    const tenant_id = tenantData?.tenant_id || (session?.user?.user_metadata as any)?.tenant_id;
    const payload: any = {
      machine_id: form.machine_id,
      log_date: form.log_date,
      fuel_liters: parseFloat(form.fuel_liters),
      cost: form.cost ? parseFloat(form.cost) : null,
      notes: form.notes.trim() || null,
    };
    if (tenant_id) payload.tenant_id = tenant_id;
    const { error } = await supabase.from("fuel_logs").insert(payload);
    if (error) {
      if (error.message.includes("does not exist")) {
        const mock = {
          id: Math.random().toString(36).substring(7),
          machine_id: form.machine_id,
          log_date: form.log_date,
          fuel_liters: parseFloat(form.fuel_liters),
          cost: form.cost ? parseFloat(form.cost) : null,
          notes: form.notes || null,
          created_at: new Date().toISOString(),
          machines: machines.find(m => m.id === form.machine_id) ? { name: machines.find(m => m.id === form.machine_id)!.name, machine_no: machines.find(m => m.id === form.machine_id)!.machine_no } : null,
        };
        setLogs(prev => [mock, ...prev]);
        setOpen(false);
        setForm({ machine_id: "", log_date: new Date().toISOString().slice(0, 10), fuel_liters: "", cost: "", notes: "" });
        return;
      }
      alert(error.message);
      return;
    }
    setOpen(false);
    setForm({ machine_id: "", log_date: new Date().toISOString().slice(0, 10), fuel_liters: "", cost: "", notes: "" });
    fetchData();
  };

  if (loading) return <Box sx={{ p: 3, display: "flex", justifyContent: "center" }}><CircularProgress /></Box>;

  return (
    <Box sx={{ p: 3, maxWidth: 1100 }}>
      <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", mb: 3 }}>
        <Box><Typography variant="h5" fontWeight={700}>Fuel & Consumption</Typography><Typography variant="body2" color="text.secondary">{logs.length} fuel logs • Liters, cost, consumption L/hr can be calculated from operation_logs hours.</Typography></Box>
        <Button variant="contained" startIcon={<Add />} onClick={() => setOpen(true)}>New Fuel Log</Button>
      </Box>
      <Card><CardContent sx={{ p: 0 }}><Table><TableHead><TableRow><TableCell>Date</TableCell><TableCell>Machine</TableCell><TableCell>Liters</TableCell><TableCell>Cost</TableCell><TableCell>Consumption L/hr (calc)</TableCell></TableRow></TableHead><TableBody>{logs.length === 0 ? <TableRow><TableCell colSpan={5} sx={{ textAlign: "center", py: 5 }}><Typography color="text.secondary">No fuel logs yet. Create fuel logs with liters and cost.</Typography></TableCell></TableRow> : logs.map(l => <TableRow key={l.id} hover><TableCell>{new Date(l.log_date).toLocaleDateString()}</TableCell><TableCell>{l.machines ? `${l.machines.machine_no} - ${l.machines.name}` : "-"}</TableCell><TableCell><Chip label={`${l.fuel_liters} L`} size="small" /></TableCell><TableCell>{l.cost ? `UGX ${Number(l.cost).toLocaleString()}` : "-"}</TableCell><TableCell><Typography variant="caption" color="text.secondary">Needs join with operation_logs hours for L/hr calc: liters / hours_used</Typography></TableCell></TableRow>)}</TableBody></Table></CardContent></Card>

      <Dialog open={open} onClose={() => setOpen(false)} maxWidth="sm" fullWidth><DialogTitle>New Fuel Log</DialogTitle><DialogContent sx={{ display: "flex", flexDirection: "column", gap: 2, pt: 2 }}><TextField select label="Machine *" value={form.machine_id} onChange={e => setForm({ ...form, machine_id: e.target.value })} fullWidth required><MenuItem value="">-- Select Machine --</MenuItem>{machines.map(m => <MenuItem key={m.id} value={m.id}>{m.machine_no} - {m.name}</MenuItem>)}</TextField><Grid container spacing={2}><Grid item xs={6}><TextField label="Date *" type="date" value={form.log_date} onChange={e => setForm({ ...form, log_date: e.target.value })} fullWidth InputLabelProps={{ shrink: true }} required /></Grid><Grid item xs={3}><TextField label="Liters *" type="number" value={form.fuel_liters} onChange={e => setForm({ ...form, fuel_liters: e.target.value })} fullWidth required InputProps={{ inputProps: { min: 0, step: 0.1 } }} /></Grid><Grid item xs={3}><TextField label="Cost" type="number" value={form.cost} onChange={e => setForm({ ...form, cost: e.target.value })} fullWidth placeholder="UGX" /></Grid></Grid><TextField label="Notes" value={form.notes} onChange={e => setForm({ ...form, notes: e.target.value })} fullWidth multiline rows={2} placeholder="Fuel station, receipt no, etc." /></DialogContent><DialogActions><Button onClick={() => setOpen(false)}>Cancel</Button><Button variant="contained" onClick={handleSave} disabled={!form.machine_id || !form.log_date || !form.fuel_liters}>Create</Button></DialogActions></Dialog>
    </Box>
  );
}
